/*
Copyright 2020 The actions-runner-controller authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package actionssummerwindnet

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/go-logr/logr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/actions/actions-runner-controller/apis/actions.summerwind.net/v1alpha1"
)

const (
	FirecrackerWorkDir       = "/opt/firecracker/data"
	FirecrackerKernelDir     = "/opt/firecracker/kernels"
	FirecrackerImagesDir     = "/opt/firecracker/images" 
	FirecrackerSnapshotsDir  = "/opt/firecracker/snapshots"
	FirecrackerInstancesDir  = "/opt/firecracker/instances"
	DefaultKernelVersion     = "6.1.128"
	DefaultKernel            = "vmlinux-6.1.128-ubuntu24"
	DefaultRootfsImage       = "actions-runner-ubuntu-24.04.ext4"
	FirecrackerSocketTimeout = 30 * time.Second
)

// FirecrackerVMManager manages Firecracker VMs for GitHub Actions runners
type FirecrackerVMManager struct {
	client.Client
	Log              logr.Logger
	WorkDir          string
	ARCControllerURL string // URL for status reporting back to ARC controller
}

// VMInfo represents information about a running Firecracker VM
type VMInfo struct {
	Name               string    `json:"name"`
	VMID               string    `json:"vm_id"`
	IP                 string    `json:"ip"`
	MAC                string    `json:"mac"`
	Networking         string    `json:"networking"`
	Bridge             string    `json:"bridge"`
	TAP                string    `json:"tap"`
	GitHubURL          string    `json:"github_url"`
	Labels             string    `json:"labels"`
	Created            time.Time `json:"created"`
	PID                int       `json:"pid"`
	EphemeralMode      bool      `json:"ephemeral_mode"`
	ARCMode            bool      `json:"arc_mode"`
	ARCControllerURL   string    `json:"arc_controller_url"`
	DockerMode         bool      `json:"docker_mode"`
	SocketPath         string    `json:"socket_path"`
	SnapshotUsed       string    `json:"snapshot_used"`
	KernelUsed         string    `json:"kernel_used"`
}

// NewFirecrackerVMManager creates a new Firecracker VM manager
func NewFirecrackerVMManager(client client.Client, log logr.Logger, arcControllerURL string) *FirecrackerVMManager {
	workDir := FirecrackerWorkDir
	if wd := os.Getenv("FIRECRACKER_WORK_DIR"); wd != "" {
		workDir = wd
	}

	return &FirecrackerVMManager{
		Client:           client,
		Log:              log,
		WorkDir:          workDir,
		ARCControllerURL: arcControllerURL,
	}
}

// CreateVM creates a new Firecracker VM for the given runner
func (m *FirecrackerVMManager) CreateVM(ctx context.Context, runner *v1alpha1.Runner, registrationToken string) (*VMInfo, error) {
	log := m.Log.WithValues("runner", runner.Name, "namespace", runner.Namespace)

	// Validate runtime configuration
	if runner.Spec.Runtime == nil || runner.Spec.Runtime.Type != "firecracker" {
		return nil, fmt.Errorf("runner does not have Firecracker runtime configuration")
	}

	fcConfig := runner.Spec.Runtime.Firecracker
	if fcConfig == nil {
		return nil, fmt.Errorf("Firecracker configuration is missing")
	}

	// Setup directories
	if err := m.setupDirectories(); err != nil {
		return nil, fmt.Errorf("failed to setup directories: %w", err)
	}

	// Generate VM ID and configuration
	vmID := m.generateVMID(runner.Name)
	instanceDir := filepath.Join(m.WorkDir, "instances", vmID)
	if err := os.MkdirAll(instanceDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create instance directory: %w", err)
	}

	log.Info("Creating Firecracker VM", "vmID", vmID, "instanceDir", instanceDir)

	// Prepare filesystem
	rootfsPath, snapshotUsed, err := m.prepareFilesystem(fcConfig, instanceDir)
	if err != nil {
		return nil, fmt.Errorf("failed to prepare filesystem: %w", err)
	}

	// Prepare kernel
	kernelPath, kernelUsed, err := m.prepareKernel(fcConfig, instanceDir)
	if err != nil {
		return nil, fmt.Errorf("failed to prepare kernel: %w", err)
	}

	// Generate SSH key
	sshKeyPath := filepath.Join(instanceDir, "ssh_key")
	if err := m.generateSSHKey(sshKeyPath); err != nil {
		return nil, fmt.Errorf("failed to generate SSH key: %w", err)
	}

	// Setup networking
	vmInfo, err := m.setupNetworking(vmID, fcConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to setup networking: %w", err)
	}

	// Create cloud-init configuration
	if err := m.createCloudInit(instanceDir, runner, registrationToken, vmInfo, fcConfig); err != nil {
		return nil, fmt.Errorf("failed to create cloud-init: %w", err)
	}

	// Start Firecracker VM
	socketPath := filepath.Join(instanceDir, "firecracker.socket")
	pid, err := m.startFirecracker(socketPath)
	if err != nil {
		return nil, fmt.Errorf("failed to start Firecracker: %w", err)
	}

	// Configure and start the VM
	if err := m.configureVM(socketPath, kernelPath, rootfsPath, instanceDir, vmInfo, fcConfig); err != nil {
		// Cleanup on failure
		if pid > 0 {
			exec.Command("kill", strconv.Itoa(pid)).Run()
		}
		return nil, fmt.Errorf("failed to configure VM: %w", err)
	}

	// Update VM info with final details
	vmInfo.Name = runner.Name
	vmInfo.VMID = vmID
	vmInfo.GitHubURL = m.getGitHubURL(runner)
	vmInfo.Labels = strings.Join(runner.Spec.Labels, ",")
	vmInfo.Created = time.Now()
	vmInfo.PID = pid
	vmInfo.EphemeralMode = fcConfig.EphemeralMode
	vmInfo.ARCMode = fcConfig.ARCMode
	vmInfo.ARCControllerURL = fcConfig.ARCControllerURL
	vmInfo.DockerMode = fcConfig.DockerMode
	vmInfo.SocketPath = socketPath
	vmInfo.SnapshotUsed = snapshotUsed
	vmInfo.KernelUsed = kernelUsed

	// Save VM info
	if err := m.saveVMInfo(instanceDir, vmInfo); err != nil {
		log.Error(err, "Failed to save VM info", "vmID", vmID)
		// Don't fail the creation for this
	}

	log.Info("Firecracker VM created successfully", 
		"vmID", vmID, 
		"ip", vmInfo.IP, 
		"pid", pid,
		"ephemeral", fcConfig.EphemeralMode,
		"arcMode", fcConfig.ARCMode)

	return vmInfo, nil
}

// DeleteVM deletes a Firecracker VM
func (m *FirecrackerVMManager) DeleteVM(ctx context.Context, runner *v1alpha1.Runner) error {
	log := m.Log.WithValues("runner", runner.Name, "namespace", runner.Namespace)

	vmID := m.generateVMID(runner.Name)
	instanceDir := filepath.Join(m.WorkDir, "instances", vmID)
	
	// Load VM info if available
	vmInfo, err := m.loadVMInfo(instanceDir)
	if err != nil {
		log.V(1).Info("Could not load VM info", "error", err)
	}

	// Stop Firecracker process
	if vmInfo != nil && vmInfo.PID > 0 {
		log.Info("Stopping Firecracker VM", "vmID", vmID, "pid", vmInfo.PID)
		if err := exec.Command("kill", strconv.Itoa(vmInfo.PID)).Run(); err != nil {
			log.V(1).Info("Failed to send TERM signal", "error", err)
		}
		
		// Wait a bit then force kill
		time.Sleep(2 * time.Second)
		exec.Command("kill", "-9", strconv.Itoa(vmInfo.PID)).Run()
	}

	// Cleanup networking based on mode
	if vmInfo != nil {
		if err := m.cleanupNetworking(vmInfo, log); err != nil {
			log.V(1).Info("Failed to cleanup networking", "error", err)
		}
	}

	// Remove instance directory
	if err := os.RemoveAll(instanceDir); err != nil {
		log.Error(err, "Failed to remove instance directory", "instanceDir", instanceDir)
		return err
	}

	log.Info("Firecracker VM deleted", "vmID", vmID)
	return nil
}

func (m *FirecrackerVMManager) cleanupNetworking(vmInfo *VMInfo, log logr.Logger) error {
	switch vmInfo.Networking {
	case "macvlan":
		return m.cleanupMacvlanNetworking(vmInfo, log)
	case "nat":
		return m.cleanupNATNetworking(vmInfo, log)
	case "host":
		return m.cleanupHostNetworking(vmInfo, log)
	case "dhcp", "static":
		fallthrough
	default:
		return m.cleanupBridgeNetworking(vmInfo, log)
	}
}

func (m *FirecrackerVMManager) cleanupMacvlanNetworking(vmInfo *VMInfo, log logr.Logger) error {
	// Cleanup TAP device
	if vmInfo.TAP != "" {
		if err := exec.Command("sudo", "ip", "link", "del", vmInfo.TAP).Run(); err != nil {
			log.V(1).Info("Failed to cleanup TAP device", "tap", vmInfo.TAP, "error", err)
		}
	}

	// Cleanup macvlan interface (stored in Bridge field)
	if vmInfo.Bridge != "" && strings.HasPrefix(vmInfo.Bridge, "mv-") {
		if err := exec.Command("sudo", "ip", "link", "del", vmInfo.Bridge).Run(); err != nil {
			log.V(1).Info("Failed to cleanup macvlan interface", "macvlan", vmInfo.Bridge, "error", err)
		}
	}

	return nil
}

func (m *FirecrackerVMManager) cleanupNATNetworking(vmInfo *VMInfo, log logr.Logger) error {
	// Cleanup TAP device
	if vmInfo.TAP != "" {
		if err := exec.Command("sudo", "ip", "link", "del", vmInfo.TAP).Run(); err != nil {
			log.V(1).Info("Failed to cleanup TAP device", "tap", vmInfo.TAP, "error", err)
		}
	}

	// Note: We don't cleanup iptables rules here as they might be shared
	// In production, you might want to track rules per VM and cleanup accordingly
	log.V(1).Info("NAT networking cleanup complete", "tap", vmInfo.TAP)
	return nil
}

func (m *FirecrackerVMManager) cleanupHostNetworking(vmInfo *VMInfo, log logr.Logger) error {
	// Cleanup TAP device
	if vmInfo.TAP != "" {
		if err := exec.Command("sudo", "ip", "link", "del", vmInfo.TAP).Run(); err != nil {
			log.V(1).Info("Failed to cleanup TAP device", "tap", vmInfo.TAP, "error", err)
		}
	}

	return nil
}

func (m *FirecrackerVMManager) cleanupBridgeNetworking(vmInfo *VMInfo, log logr.Logger) error {
	// Original bridge cleanup logic
	if vmInfo.TAP != "" && strings.Contains(vmInfo.TAP, "tap-") {
		if err := exec.Command("sudo", "ip", "link", "del", vmInfo.TAP).Run(); err != nil {
			log.V(1).Info("Failed to cleanup TAP device", "tap", vmInfo.TAP, "error", err)
		}
	}

	return nil
}

// GetVMStatus gets the status of a Firecracker VM
func (m *FirecrackerVMManager) GetVMStatus(ctx context.Context, runner *v1alpha1.Runner) (*VMInfo, error) {
	vmID := m.generateVMID(runner.Name)
	instanceDir := filepath.Join(m.WorkDir, "instances", vmID)
	
	vmInfo, err := m.loadVMInfo(instanceDir)
	if err != nil {
		return nil, fmt.Errorf("failed to load VM info: %w", err)
	}

	// Check if process is still running
	if vmInfo.PID > 0 {
		if err := exec.Command("kill", "-0", strconv.Itoa(vmInfo.PID)).Run(); err != nil {
			// Process not running
			vmInfo.PID = 0
		}
	}

	return vmInfo, nil
}

// Helper methods

func (m *FirecrackerVMManager) setupDirectories() error {
	dirs := []string{
		filepath.Join(m.WorkDir, "kernels"),
		filepath.Join(m.WorkDir, "images"),
		filepath.Join(m.WorkDir, "snapshots"),
		filepath.Join(m.WorkDir, "instances"),
	}

	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return fmt.Errorf("failed to create directory %s: %w", dir, err)
		}
	}

	return nil
}

func (m *FirecrackerVMManager) generateVMID(runnerName string) string {
	// Create a short, unique ID from runner name + random bytes
	b := make([]byte, 4)
	rand.Read(b)
	return fmt.Sprintf("%.8s-%x", strings.ReplaceAll(runnerName, "_", "-"), b)
}

func (m *FirecrackerVMManager) generateRandomMAC() string {
	b := make([]byte, 5)
	rand.Read(b)
	return fmt.Sprintf("06:%02x:%02x:%02x:%02x:%02x", b[0], b[1], b[2], b[3], b[4])
}

func (m *FirecrackerVMManager) prepareFilesystem(fcConfig *v1alpha1.FirecrackerRuntime, instanceDir string) (string, string, error) {
	rootfsPath := filepath.Join(instanceDir, "rootfs.ext4")
	var sourceUsed string

	if fcConfig.SnapshotName != "" {
		// Use snapshot
		snapshotPath := filepath.Join(m.WorkDir, "snapshots", fcConfig.SnapshotName, "rootfs.ext4")
		if _, err := os.Stat(snapshotPath); err != nil {
			return "", "", fmt.Errorf("snapshot not found: %s", snapshotPath)
		}
		
		// Copy snapshot to instance directory
		if err := exec.Command("cp", snapshotPath, rootfsPath).Run(); err != nil {
			return "", "", fmt.Errorf("failed to copy snapshot: %w", err)
		}
		sourceUsed = fcConfig.SnapshotName
	} else if fcConfig.RootfsImagePath != "" {
		// Use specified rootfs image
		if _, err := os.Stat(fcConfig.RootfsImagePath); err != nil {
			return "", "", fmt.Errorf("rootfs image not found: %s", fcConfig.RootfsImagePath)
		}
		
		if err := exec.Command("cp", fcConfig.RootfsImagePath, rootfsPath).Run(); err != nil {
			return "", "", fmt.Errorf("failed to copy rootfs image: %w", err)
		}
		sourceUsed = fcConfig.RootfsImagePath
	} else {
		// Use default image
		defaultImage := filepath.Join(m.WorkDir, "images", DefaultRootfsImage)
		if _, err := os.Stat(defaultImage); err != nil {
			return "", "", fmt.Errorf("default rootfs image not found: %s", defaultImage)
		}
		
		if err := exec.Command("cp", defaultImage, rootfsPath).Run(); err != nil {
			return "", "", fmt.Errorf("failed to copy default rootfs image: %w", err)
		}
		sourceUsed = DefaultRootfsImage
	}

	return rootfsPath, sourceUsed, nil
}

func (m *FirecrackerVMManager) prepareKernel(fcConfig *v1alpha1.FirecrackerRuntime, instanceDir string) (string, string, error) {
	kernelPath := filepath.Join(instanceDir, "vmlinux")
	var kernelUsed string

	if fcConfig.KernelImagePath != "" {
		// Use specified kernel
		if _, err := os.Stat(fcConfig.KernelImagePath); err != nil {
			return "", "", fmt.Errorf("kernel image not found: %s", fcConfig.KernelImagePath)
		}
		
		if err := exec.Command("cp", fcConfig.KernelImagePath, kernelPath).Run(); err != nil {
			return "", "", fmt.Errorf("failed to copy kernel image: %w", err)
		}
		kernelUsed = fcConfig.KernelImagePath
	} else {
		// Use default kernel
		defaultKernel := filepath.Join(m.WorkDir, "kernels", DefaultKernel)
		if _, err := os.Stat(defaultKernel); err != nil {
			return "", "", fmt.Errorf("default kernel not found: %s", defaultKernel)
		}
		
		if err := exec.Command("cp", defaultKernel, kernelPath).Run(); err != nil {
			return "", "", fmt.Errorf("failed to copy default kernel: %w", err)
		}
		kernelUsed = DefaultKernel
	}

	return kernelPath, kernelUsed, nil
}

func (m *FirecrackerVMManager) generateSSHKey(keyPath string) error {
	return exec.Command("ssh-keygen", "-t", "rsa", "-b", "4096", "-f", keyPath, "-N", "", "-C", "arc-firecracker").Run()
}

func (m *FirecrackerVMManager) setupNetworking(vmID string, fcConfig *v1alpha1.FirecrackerRuntime) (*VMInfo, error) {
	vmInfo := &VMInfo{
		MAC: m.generateRandomMAC(),
	}

	// Set default network mode if not specified
	networkMode := "bridge"
	if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.NetworkMode != "" {
		networkMode = fcConfig.NetworkConfig.NetworkMode
	}

	switch networkMode {
	case "macvlan":
		return m.setupMacvlanNetworking(vmID, fcConfig, vmInfo)
	case "host":
		return m.setupHostNetworking(vmID, fcConfig, vmInfo)
	case "nat":
		return m.setupNATNetworking(vmID, fcConfig, vmInfo)
	case "bridge":
		fallthrough
	default:
		return m.setupBridgeNetworking(vmID, fcConfig, vmInfo)
	}
}

func (m *FirecrackerVMManager) setupMacvlanNetworking(vmID string, fcConfig *v1alpha1.FirecrackerRuntime, vmInfo *VMInfo) (*VMInfo, error) {
	// Macvlan mode - create macvlan interface on top of host interface
	parentInterface := "eth0" // default
	if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.ParentInterface != "" {
		parentInterface = fcConfig.NetworkConfig.ParentInterface
	}

	macvlanMode := "bridge"
	if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.MacvlanMode != "" {
		macvlanMode = fcConfig.NetworkConfig.MacvlanMode
	}

	// Create macvlan interface
	macvlanName := fmt.Sprintf("mv-%s", vmID)
	if err := exec.Command("sudo", "ip", "link", "add", "link", parentInterface, "name", macvlanName, "type", "macvlan", "mode", macvlanMode).Run(); err != nil {
		return nil, fmt.Errorf("failed to create macvlan interface: %w", err)
	}

	// Bring up the interface
	if err := exec.Command("sudo", "ip", "link", "set", "dev", macvlanName, "up").Run(); err != nil {
		return nil, fmt.Errorf("failed to bring up macvlan interface: %w", err)
	}

	// Create TAP device and attach to macvlan
	tapName := fmt.Sprintf("tap-%s", vmID)
	if err := exec.Command("sudo", "ip", "tuntap", "add", "dev", tapName, "mode", "tap").Run(); err != nil {
		return nil, fmt.Errorf("failed to create TAP device: %w", err)
	}

	// Use tc to redirect traffic between TAP and macvlan
	if err := exec.Command("sudo", "ip", "link", "set", "dev", tapName, "up").Run(); err != nil {
		return nil, fmt.Errorf("failed to bring up TAP device: %w", err)
	}

	vmInfo.Networking = "macvlan"
	vmInfo.Bridge = macvlanName
	vmInfo.TAP = tapName

	// Setup DHCP or static IP
	if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.DHCPEnabled {
		vmInfo.IP = "dhcp"
	} else {
		vmInfo.IP = m.generateStaticIP(vmID)
	}

	m.Log.Info("Setup macvlan networking", "parent", parentInterface, "macvlan", macvlanName, "tap", tapName, "mode", macvlanMode)
	return vmInfo, nil
}

func (m *FirecrackerVMManager) setupHostNetworking(vmID string, fcConfig *v1alpha1.FirecrackerRuntime, vmInfo *VMInfo) (*VMInfo, error) {
	// Host networking - VM shares host network namespace
	// This is simplest but provides no network isolation
	
	// Create a simple TAP device for Firecracker
	tapName := fmt.Sprintf("tap-%s", vmID)
	if err := exec.Command("sudo", "ip", "tuntap", "add", "dev", tapName, "mode", "tap").Run(); err != nil {
		return nil, fmt.Errorf("failed to create TAP device: %w", err)
	}

	if err := exec.Command("sudo", "ip", "link", "set", "dev", tapName, "up").Run(); err != nil {
		return nil, fmt.Errorf("failed to bring up TAP device: %w", err)
	}

	vmInfo.Networking = "host"
	vmInfo.Bridge = "host"
	vmInfo.TAP = tapName
	vmInfo.IP = "host-network"

	m.Log.Info("Setup host networking", "tap", tapName)
	return vmInfo, nil
}

func (m *FirecrackerVMManager) setupNATNetworking(vmID string, fcConfig *v1alpha1.FirecrackerRuntime, vmInfo *VMInfo) (*VMInfo, error) {
	// NAT mode - create isolated network with NAT to host interface
	parentInterface := "eth0" // default
	if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.ParentInterface != "" {
		parentInterface = fcConfig.NetworkConfig.ParentInterface
	}

	// Create TAP device
	tapName := fmt.Sprintf("tap-%s", vmID)
	if err := exec.Command("sudo", "ip", "tuntap", "add", "dev", tapName, "mode", "tap").Run(); err != nil {
		return nil, fmt.Errorf("failed to create TAP device: %w", err)
	}

	// Assign IP to TAP (host side)
	gatewayIP := "172.16.0.1"
	if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.Gateway != "" {
		gatewayIP = fcConfig.NetworkConfig.Gateway
	}

	if err := exec.Command("sudo", "ip", "addr", "add", gatewayIP+"/24", "dev", tapName).Run(); err != nil {
		return nil, fmt.Errorf("failed to assign IP to TAP: %w", err)
	}

	if err := exec.Command("sudo", "ip", "link", "set", "dev", tapName, "up").Run(); err != nil {
		return nil, fmt.Errorf("failed to bring up TAP device: %w", err)
	}

	// Setup NAT rules
	vmSubnet := "172.16.0.0/24"
	if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.SubnetCIDR != "" {
		vmSubnet = fcConfig.NetworkConfig.SubnetCIDR
	}

	// Enable IP forwarding
	exec.Command("sudo", "sysctl", "-w", "net.ipv4.ip_forward=1").Run()

	// Setup iptables NAT
	exec.Command("sudo", "iptables", "-t", "nat", "-A", "POSTROUTING", "-s", vmSubnet, "-o", parentInterface, "-j", "MASQUERADE").Run()
	exec.Command("sudo", "iptables", "-A", "FORWARD", "-i", tapName, "-o", parentInterface, "-j", "ACCEPT").Run()
	exec.Command("sudo", "iptables", "-A", "FORWARD", "-i", parentInterface, "-o", tapName, "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT").Run()

	vmInfo.Networking = "nat"
	vmInfo.Bridge = fmt.Sprintf("nat-%s", parentInterface)
	vmInfo.TAP = tapName
	vmInfo.IP = m.generateStaticIP(vmID)

	m.Log.Info("Setup NAT networking", "parent", parentInterface, "tap", tapName, "subnet", vmSubnet)
	return vmInfo, nil
}

func (m *FirecrackerVMManager) setupBridgeNetworking(vmID string, fcConfig *v1alpha1.FirecrackerRuntime, vmInfo *VMInfo) (*VMInfo, error) {
	// Original bridge networking logic
	if fcConfig.UseHostBridge {
		// Use host bridge networking with DHCP
		vmInfo.Networking = "dhcp"
		vmInfo.Bridge = "br0" // Assuming host bridge is br0
		vmInfo.TAP = fmt.Sprintf("tap-%s", vmID)
		vmInfo.IP = "dhcp"

		// Create TAP device
		if err := exec.Command("sudo", "ip", "tuntap", "add", "dev", vmInfo.TAP, "mode", "tap").Run(); err != nil {
			return nil, fmt.Errorf("failed to create TAP device: %w", err)
		}

		if err := exec.Command("sudo", "ip", "link", "set", "dev", vmInfo.TAP, "master", vmInfo.Bridge).Run(); err != nil {
			return nil, fmt.Errorf("failed to attach TAP to bridge: %w", err)
		}

		if err := exec.Command("sudo", "ip", "link", "set", "dev", vmInfo.TAP, "up").Run(); err != nil {
			return nil, fmt.Errorf("failed to bring up TAP device: %w", err)
		}
	} else {
		// Use static IP networking
		vmInfo.Networking = "static"
		
		if fcConfig.NetworkConfig != nil {
			vmInfo.Bridge = fcConfig.NetworkConfig.BridgeName
			vmInfo.TAP = fcConfig.NetworkConfig.TAPDeviceName
		}
		
		if vmInfo.Bridge == "" {
			vmInfo.Bridge = "fc-br0"
		}
		if vmInfo.TAP == "" {
			vmInfo.TAP = "fc-tap0"
		}

		// Generate static IP
		vmInfo.IP = m.generateStaticIP(vmID)

		// Setup bridge and TAP if they don't exist
		if err := m.ensureNetworkDevices(vmInfo.Bridge, vmInfo.TAP); err != nil {
			return nil, fmt.Errorf("failed to setup network devices: %w", err)
		}
	}

	return vmInfo, nil
}

func (m *FirecrackerVMManager) generateStaticIP(vmID string) string {
	// Generate IP based on VM ID hash (simple approach)
	hash := 0
	for _, c := range vmID {
		hash = (hash + int(c)) % 200
	}
	ip := 10 + hash
	if ip == 1 {
		ip = 10
	}
	return fmt.Sprintf("172.16.0.%d", ip)
}

func (m *FirecrackerVMManager) ensureNetworkDevices(bridge, tap string) error {
	// Create bridge if it doesn't exist
	if err := exec.Command("ip", "link", "show", bridge).Run(); err != nil {
		m.Log.Info("Creating bridge device", "bridge", bridge)
		if err := exec.Command("sudo", "ip", "link", "add", "name", bridge, "type", "bridge").Run(); err != nil {
			return fmt.Errorf("failed to create bridge: %w", err)
		}
		
		if err := exec.Command("sudo", "ip", "addr", "add", "172.16.0.1/24", "dev", bridge).Run(); err != nil {
			return fmt.Errorf("failed to assign IP to bridge: %w", err)
		}
		
		if err := exec.Command("sudo", "ip", "link", "set", "dev", bridge, "up").Run(); err != nil {
			return fmt.Errorf("failed to bring up bridge: %w", err)
		}
	}

	// Create TAP if it doesn't exist
	if err := exec.Command("ip", "link", "show", tap).Run(); err != nil {
		m.Log.Info("Creating TAP device", "tap", tap)
		if err := exec.Command("sudo", "ip", "tuntap", "add", "dev", tap, "mode", "tap").Run(); err != nil {
			return fmt.Errorf("failed to create TAP device: %w", err)
		}
		
		if err := exec.Command("sudo", "ip", "link", "set", "dev", tap, "master", bridge).Run(); err != nil {
			return fmt.Errorf("failed to attach TAP to bridge: %w", err)
		}
		
		if err := exec.Command("sudo", "ip", "link", "set", "dev", tap, "up").Run(); err != nil {
			return fmt.Errorf("failed to bring up TAP device: %w", err)
		}
	}

	return nil
}

func (m *FirecrackerVMManager) createCloudInit(instanceDir string, runner *v1alpha1.Runner, token string, vmInfo *VMInfo, fcConfig *v1alpha1.FirecrackerRuntime) error {
	cloudInitDir := filepath.Join(instanceDir, "cloud-init")
	if err := os.MkdirAll(cloudInitDir, 0755); err != nil {
		return err
	}

	// Read SSH public key
	pubKeyBytes, err := ioutil.ReadFile(filepath.Join(instanceDir, "ssh_key.pub"))
	if err != nil {
		return fmt.Errorf("failed to read SSH public key: %w", err)
	}
	pubKey := strings.TrimSpace(string(pubKeyBytes))

	// Create user-data
	userData := fmt.Sprintf(`#cloud-config
hostname: %s

users:
  - name: runner
    ssh_authorized_keys:
      - %s
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

write_files:
  - path: /etc/environment
    content: |
      GITHUB_TOKEN=%s
      GITHUB_URL=%s
      RUNNER_NAME=%s
      RUNNER_LABELS=%s
      RUNNER_TOKEN=%s
  - path: /etc/systemd/network/10-eth0.network
    content: |
      [Match]
      Name=eth0
      
      [Network]%s

runcmd:
  - systemctl enable systemd-networkd
  - systemctl restart systemd-networkd
  - /usr/local/bin/setup-runner.sh

ssh_pwauth: false
`, runner.Name, pubKey, token, m.getGitHubURL(runner), runner.Name, strings.Join(runner.Spec.Labels, ","), token, m.getNetworkConfig(vmInfo, fcConfig))

	if err := ioutil.WriteFile(filepath.Join(cloudInitDir, "user-data"), []byte(userData), 0644); err != nil {
		return err
	}

	// Create meta-data
	metaData := fmt.Sprintf("instance-id: %s\n", vmInfo.VMID)
	if err := ioutil.WriteFile(filepath.Join(cloudInitDir, "meta-data"), []byte(metaData), 0644); err != nil {
		return err
	}

	// Create network-config
	if err := ioutil.WriteFile(filepath.Join(cloudInitDir, "network-config"), []byte("{}"), 0644); err != nil {
		return err
	}

	// Create ISO
	isoPath := filepath.Join(instanceDir, "cloud-init.iso")
	if err := exec.Command("genisoimage", "-output", isoPath, "-volid", "cidata", "-joliet", "-rock", cloudInitDir).Run(); err != nil {
		return fmt.Errorf("failed to create cloud-init ISO: %w", err)
	}

	return nil
}

func (m *FirecrackerVMManager) getNetworkConfig(vmInfo *VMInfo, fcConfig *v1alpha1.FirecrackerRuntime) string {
	switch vmInfo.Networking {
	case "dhcp", "macvlan":
		if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.DHCPEnabled {
			return `
      DHCP=yes
      DNS=8.8.8.8
      DNS=8.8.4.4`
		}
		// For macvlan with static IP, fall through to static config
		fallthrough
	case "static", "nat":
		gateway := "172.16.0.1"
		if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.Gateway != "" {
			gateway = fcConfig.NetworkConfig.Gateway
		}

		return fmt.Sprintf(`
      Address=%s/24
      Gateway=%s
      DNS=8.8.8.8
      DNS=8.8.4.4`, vmInfo.IP, gateway)
	case "host":
		return `
      DHCP=yes
      DNS=8.8.8.8
      DNS=8.8.4.4`
	default:
		// Original bridge logic
		if vmInfo.Networking == "dhcp" {
			return `
      DHCP=yes
      DNS=8.8.8.8
      DNS=8.8.4.4`
		}

		gateway := "172.16.0.1"
		if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.Gateway != "" {
			gateway = fcConfig.NetworkConfig.Gateway
		}

		return fmt.Sprintf(`
      Address=%s/24
      Gateway=%s
      DNS=8.8.8.8
      DNS=8.8.4.4`, vmInfo.IP, gateway)
	}
}

func (m *FirecrackerVMManager) getGitHubURL(runner *v1alpha1.Runner) string {
	if runner.Spec.Enterprise != "" {
		return fmt.Sprintf("https://github.com/enterprises/%s", runner.Spec.Enterprise)
	}
	if runner.Spec.Organization != "" {
		return fmt.Sprintf("https://github.com/%s", runner.Spec.Organization)
	}
	if runner.Spec.Repository != "" {
		return fmt.Sprintf("https://github.com/%s", runner.Spec.Repository)
	}
	return ""
}

func (m *FirecrackerVMManager) startFirecracker(socketPath string) (int, error) {
	// Remove existing socket
	os.Remove(socketPath)

	// Start Firecracker
	cmd := exec.Command("firecracker", "--api-sock", socketPath)
	if err := cmd.Start(); err != nil {
		return 0, fmt.Errorf("failed to start Firecracker: %w", err)
	}

	// Wait for socket to be ready
	for i := 0; i < 30; i++ {
		if _, err := os.Stat(socketPath); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	return cmd.Process.Pid, nil
}

func (m *FirecrackerVMManager) configureVM(socketPath, kernelPath, rootfsPath, instanceDir string, vmInfo *VMInfo, fcConfig *v1alpha1.FirecrackerRuntime) error {
	client := &http.Client{Timeout: FirecrackerSocketTimeout}
	baseURL := "http://localhost"

	// Helper function to make API calls
	makeAPICall := func(method, endpoint string, data interface{}) error {
		var body []byte
		if data != nil {
			var err error
			body, err = json.Marshal(data)
			if err != nil {
				return err
			}
		}

		req, err := http.NewRequest(method, baseURL+endpoint, strings.NewReader(string(body)))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()

		if resp.StatusCode >= 400 {
			respBody, _ := ioutil.ReadAll(resp.Body)
			return fmt.Errorf("API call failed: %s %s -> %d: %s", method, endpoint, resp.StatusCode, string(respBody))
		}

		return nil
	}

	// Set memory and CPU count
	memory := 2048
	if fcConfig.MemoryMiB > 0 {
		memory = fcConfig.MemoryMiB
	}
	
	vcpus := 2
	if fcConfig.VCPUs > 0 {
		vcpus = fcConfig.VCPUs
	}

	if err := makeAPICall("PUT", "/machine-config", map[string]interface{}{
		"vcpu_count":   vcpus,
		"mem_size_mib": memory,
	}); err != nil {
		return fmt.Errorf("failed to set machine config: %w", err)
	}

	// Set kernel
	if err := makeAPICall("PUT", "/boot-source", map[string]interface{}{
		"kernel_image_path": kernelPath,
		"boot_args":         "console=ttyS0 reboot=k panic=1 root=/dev/vda rw",
	}); err != nil {
		return fmt.Errorf("failed to set boot source: %w", err)
	}

	// Set rootfs drive
	if err := makeAPICall("PUT", "/drives/rootfs", map[string]interface{}{
		"drive_id":        "rootfs",
		"path_on_host":    rootfsPath,
		"is_root_device":  true,
		"is_read_only":    false,
	}); err != nil {
		return fmt.Errorf("failed to set rootfs drive: %w", err)
	}

	// Set cloud-init drive
	cloudInitPath := filepath.Join(instanceDir, "cloud-init.iso")
	if err := makeAPICall("PUT", "/drives/cloudinit", map[string]interface{}{
		"drive_id":        "cloudinit",
		"path_on_host":    cloudInitPath,
		"is_root_device":  false,
		"is_read_only":    true,
	}); err != nil {
		return fmt.Errorf("failed to set cloud-init drive: %w", err)
	}

	// Set network interface
	if err := makeAPICall("PUT", "/network-interfaces/eth0", map[string]interface{}{
		"iface_id":       "eth0",
		"guest_mac":      vmInfo.MAC,
		"host_dev_name":  vmInfo.TAP,
	}); err != nil {
		return fmt.Errorf("failed to set network interface: %w", err)
	}

	// Start the VM
	if err := makeAPICall("PUT", "/actions", map[string]interface{}{
		"action_type": "InstanceStart",
	}); err != nil {
		return fmt.Errorf("failed to start VM: %w", err)
	}

	return nil
}

func (m *FirecrackerVMManager) saveVMInfo(instanceDir string, vmInfo *VMInfo) error {
	data, err := json.MarshalIndent(vmInfo, "", "  ")
	if err != nil {
		return err
	}
	
	return ioutil.WriteFile(filepath.Join(instanceDir, "info.json"), data, 0644)
}

func (m *FirecrackerVMManager) loadVMInfo(instanceDir string) (*VMInfo, error) {
	data, err := ioutil.ReadFile(filepath.Join(instanceDir, "info.json"))
	if err != nil {
		return nil, err
	}
	
	var vmInfo VMInfo
	if err := json.Unmarshal(data, &vmInfo); err != nil {
		return nil, err
	}
	
	return &vmInfo, nil
} 