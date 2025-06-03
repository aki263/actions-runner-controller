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
	"net"
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
	
	// Strict resource limits
	MaxConcurrentVMs         = 5   // Maximum concurrent VMs to prevent resource exhaustion
	MinFreeDiskGB           = 30   // Minimum free disk space required (GB) 
	MaxVMMemoryMB           = 8192 // Maximum memory per VM
	DefaultVMMemoryMB       = 2048 // Default memory per VM
	MaxVMCPUs               = 4    // Maximum CPUs per VM
	DefaultVMCPUs           = 2    // Default CPUs per VM
)

// FirecrackerVMManager manages Firecracker VMs for GitHub Actions runners
type FirecrackerVMManager struct {
	client.Client
	Log              logr.Logger
	WorkDir          string
	ARCControllerURL string // URL for status reporting back to ARC controller
	activeVMs        map[string]*VMInfo // Track active VMs for resource management
}

// VMInfo represents information about a running Firecracker VM
type VMInfo struct {
	Name               string    `json:"name"`
	VMID               string    `json:"vm_id"`
	IP                 string    `json:"ip"`
	MAC                string    `json:"mac"`
	Status             string    `json:"status"`
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
	ConsoleLogPath     string    `json:"console_log_path"`
	MemoryMB           int       `json:"memory_mb"`
	VCPUs              int       `json:"vcpus"`
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
		activeVMs:        make(map[string]*VMInfo),
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

	// STRICT RESOURCE CHECKS - Prevent resource exhaustion
	if err := m.checkResourceLimits(fcConfig); err != nil {
		return nil, fmt.Errorf("resource limit check failed: %w", err)
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

	log.Info("Creating Firecracker VM with strict resource controls", 
		"vmID", vmID, 
		"instanceDir", instanceDir,
		"activeVMs", len(m.activeVMs),
		"maxConcurrent", MaxConcurrentVMs)

	// Prepare filesystem with copy-on-write to save space
	rootfsPath, snapshotUsed, err := m.prepareFilesystemCOW(fcConfig, instanceDir)
	if err != nil {
		os.RemoveAll(instanceDir)
		return nil, fmt.Errorf("failed to prepare filesystem: %w", err)
	}

	// Prepare kernel (symlink instead of copy to save space)
	kernelPath, kernelUsed, err := m.prepareKernelLink(fcConfig, instanceDir)
	if err != nil {
		os.RemoveAll(instanceDir)
		return nil, fmt.Errorf("failed to prepare kernel: %w", err)
	}

	// Generate SSH key
	sshKeyPath := filepath.Join(instanceDir, "ssh_key")
	if err := m.generateSSHKey(sshKeyPath); err != nil {
		os.RemoveAll(instanceDir)
		return nil, fmt.Errorf("failed to generate SSH key: %w", err)
	}

	// Setup networking with proper bridge connectivity
	vmInfo, err := m.setupNetworking(vmID, fcConfig)
	if err != nil {
		os.RemoveAll(instanceDir)
		return nil, fmt.Errorf("failed to setup networking: %w", err)
	}

	// Set resource limits
	memory := DefaultVMMemoryMB
	if fcConfig.MemoryMiB > 0 && fcConfig.MemoryMiB <= MaxVMMemoryMB {
		memory = fcConfig.MemoryMiB
	}
	
	vcpus := DefaultVMCPUs
	if fcConfig.VCPUs > 0 && fcConfig.VCPUs <= MaxVMCPUs {
		vcpus = fcConfig.VCPUs
	}

	vmInfo.MemoryMB = memory
	vmInfo.VCPUs = vcpus

	// Create cloud-init configuration
	if err := m.createCloudInit(instanceDir, runner, registrationToken, vmInfo, fcConfig); err != nil {
		m.cleanupNetworking(vmInfo, log)
		os.RemoveAll(instanceDir)
		return nil, fmt.Errorf("failed to create cloud-init: %w", err)
	}

	// Start Firecracker VM with console logging
	socketPath := filepath.Join(instanceDir, "firecracker.socket")
	consoleLogPath := filepath.Join(instanceDir, "console.log")
	pid, err := m.startFirecrackerWithLogging(socketPath, consoleLogPath)
	if err != nil {
		m.cleanupNetworking(vmInfo, log)
		os.RemoveAll(instanceDir)
		return nil, fmt.Errorf("failed to start Firecracker: %w", err)
	}

	// Configure and start the VM
	if err := m.configureVM(socketPath, kernelPath, rootfsPath, instanceDir, vmInfo, fcConfig); err != nil {
		// Cleanup on failure
		if pid > 0 {
			exec.Command("kill", strconv.Itoa(pid)).Run()
		}
		m.cleanupNetworking(vmInfo, log)
		os.RemoveAll(instanceDir)
		return nil, fmt.Errorf("failed to configure VM: %w", err)
	}

	// Update VM info with final details
	vmInfo.Name = runner.Name
	vmInfo.VMID = vmID
	vmInfo.Status = "running"  // Set status to running after successful creation
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
	vmInfo.ConsoleLogPath = consoleLogPath

	// Save VM info
	if err := m.saveVMInfo(instanceDir, vmInfo); err != nil {
		log.Error(err, "Failed to save VM info", "vmID", vmID)
		// Don't fail the creation for this
	}

	// Track active VM
	m.activeVMs[vmID] = vmInfo

	log.Info("Firecracker VM created successfully with resource controls", 
		"vmID", vmID, 
		"ip", vmInfo.IP, 
		"pid", pid,
		"memory", memory,
		"vcpus", vcpus,
		"consoleLog", consoleLogPath,
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

	// Remove from active VMs tracking
	delete(m.activeVMs, vmID)

	// Remove instance directory
	if err := os.RemoveAll(instanceDir); err != nil {
		log.Error(err, "Failed to remove instance directory", "instanceDir", instanceDir)
		return err
	}

	log.Info("Firecracker VM deleted", "vmID", vmID, "activeVMs", len(m.activeVMs))
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
		if err := exec.Command("ip", "link", "del", vmInfo.TAP).Run(); err != nil {
			log.V(1).Info("Failed to cleanup TAP device", "tap", vmInfo.TAP, "error", err)
		}
	}

	// Cleanup macvlan interface (stored in Bridge field)
	if vmInfo.Bridge != "" && strings.HasPrefix(vmInfo.Bridge, "mv-") {
		if err := exec.Command("ip", "link", "del", vmInfo.Bridge).Run(); err != nil {
			log.V(1).Info("Failed to cleanup macvlan interface", "macvlan", vmInfo.Bridge, "error", err)
		}
	}

	return nil
}

func (m *FirecrackerVMManager) cleanupNATNetworking(vmInfo *VMInfo, log logr.Logger) error {
	// Cleanup TAP device
	if vmInfo.TAP != "" {
		if err := exec.Command("ip", "link", "del", vmInfo.TAP).Run(); err != nil {
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
		if err := exec.Command("ip", "link", "del", vmInfo.TAP).Run(); err != nil {
			log.V(1).Info("Failed to cleanup TAP device", "tap", vmInfo.TAP, "error", err)
		}
	}

	return nil
}

func (m *FirecrackerVMManager) cleanupBridgeNetworking(vmInfo *VMInfo, log logr.Logger) error {
	// Original bridge cleanup logic
	if vmInfo.TAP != "" && strings.Contains(vmInfo.TAP, "tap-") {
		if err := exec.Command("ip", "link", "del", vmInfo.TAP).Run(); err != nil {
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

	// Check if process is still running and update status
	if vmInfo.PID > 0 {
		if err := exec.Command("kill", "-0", strconv.Itoa(vmInfo.PID)).Run(); err != nil {
			// Process not running
			vmInfo.PID = 0
			vmInfo.Status = "stopped"
		} else {
			// Process is running
			vmInfo.Status = "running"
		}
	} else {
		vmInfo.Status = "stopped"
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

func (m *FirecrackerVMManager) prepareFilesystemCOW(fcConfig *v1alpha1.FirecrackerRuntime, instanceDir string) (string, string, error) {
	rootfsPath := filepath.Join(instanceDir, "rootfs.ext4")
	var sourceUsed string

	if fcConfig.SnapshotName != "" {
		// Use snapshot
		snapshotPath := filepath.Join(FirecrackerSnapshotsDir, fcConfig.SnapshotName, "rootfs.ext4")
		if _, err := os.Stat(snapshotPath); err != nil {
			return "", "", fmt.Errorf("snapshot not found: %s", snapshotPath)
		}
		
		// Create sparse copy (copy-on-write) to save space
		if err := exec.Command("cp", "--sparse=always", snapshotPath, rootfsPath).Run(); err != nil {
			return "", "", fmt.Errorf("failed to create sparse copy of snapshot: %w", err)
		}
		sourceUsed = fcConfig.SnapshotName
	} else if fcConfig.RootfsImagePath != "" {
		// Use specified rootfs image
		if _, err := os.Stat(fcConfig.RootfsImagePath); err != nil {
			return "", "", fmt.Errorf("rootfs image not found: %s", fcConfig.RootfsImagePath)
		}
		
		// Create sparse copy to save space
		if err := exec.Command("cp", "--sparse=always", fcConfig.RootfsImagePath, rootfsPath).Run(); err != nil {
			return "", "", fmt.Errorf("failed to create sparse copy of rootfs image: %w", err)
		}
		sourceUsed = fcConfig.RootfsImagePath
	} else {
		// Use default image
		defaultImage := filepath.Join(FirecrackerImagesDir, DefaultRootfsImage)
		if _, err := os.Stat(defaultImage); err != nil {
			return "", "", fmt.Errorf("default rootfs image not found: %s", defaultImage)
		}
		
		// Create sparse copy to save space
		if err := exec.Command("cp", "--sparse=always", defaultImage, rootfsPath).Run(); err != nil {
			return "", "", fmt.Errorf("failed to create sparse copy of default rootfs image: %w", err)
		}
		sourceUsed = DefaultRootfsImage
	}

	return rootfsPath, sourceUsed, nil
}

func (m *FirecrackerVMManager) prepareKernelLink(fcConfig *v1alpha1.FirecrackerRuntime, instanceDir string) (string, string, error) {
	kernelPath := filepath.Join(instanceDir, "vmlinux")
	var kernelUsed string

	if fcConfig.KernelImagePath != "" {
		// Use specified kernel
		if _, err := os.Stat(fcConfig.KernelImagePath); err != nil {
			return "", "", fmt.Errorf("kernel image not found: %s", fcConfig.KernelImagePath)
		}
		
		// Create symlink instead of copy to save space
		if err := os.Symlink(fcConfig.KernelImagePath, kernelPath); err != nil {
			return "", "", fmt.Errorf("failed to create kernel symlink: %w", err)
		}
		kernelUsed = fcConfig.KernelImagePath
	} else {
		// Use default kernel
		defaultKernel := filepath.Join(FirecrackerKernelDir, DefaultKernel)
		if _, err := os.Stat(defaultKernel); err != nil {
			return "", "", fmt.Errorf("default kernel not found: %s", defaultKernel)
		}
		
		// Create symlink instead of copy to save space
		if err := os.Symlink(defaultKernel, kernelPath); err != nil {
			return "", "", fmt.Errorf("failed to create default kernel symlink: %w", err)
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
		MAC:    m.generateRandomMAC(),
		Status: "creating",  // Set initial status
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
	if err := exec.Command("ip", "link", "add", "link", parentInterface, "name", macvlanName, "type", "macvlan", "mode", macvlanMode).Run(); err != nil {
		return nil, fmt.Errorf("failed to create macvlan interface: %w", err)
	}

	// Bring up the interface
	if err := exec.Command("ip", "link", "set", "dev", macvlanName, "up").Run(); err != nil {
		return nil, fmt.Errorf("failed to bring up macvlan interface: %w", err)
	}

	// Create TAP device
	tapName := m.generateTAPName(vmID)
	if err := exec.Command("ip", "tuntap", "add", "dev", tapName, "mode", "tap").Run(); err != nil {
		return nil, fmt.Errorf("failed to create TAP device: %w", err)
	}

	// Use tc to redirect traffic between TAP and macvlan
	if err := exec.Command("ip", "link", "set", "dev", tapName, "up").Run(); err != nil {
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
	tapName := m.generateTAPName(vmID)
	if err := exec.Command("ip", "tuntap", "add", "dev", tapName, "mode", "tap").Run(); err != nil {
		return nil, fmt.Errorf("failed to create TAP device: %w", err)
	}

	if err := exec.Command("ip", "link", "set", "dev", tapName, "up").Run(); err != nil {
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
	tapName := fmt.Sprintf("tap-%s", vmID[:8]) // Truncate vmID to fit 15-char limit
	if err := exec.Command("ip", "tuntap", "add", "dev", tapName, "mode", "tap").Run(); err != nil {
		return nil, fmt.Errorf("failed to create TAP device: %w", err)
	}

	// Assign IP to TAP (host side)
	gatewayIP := "172.16.0.1"
	if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.Gateway != "" {
		gatewayIP = fcConfig.NetworkConfig.Gateway
	}

	if err := exec.Command("ip", "addr", "add", gatewayIP+"/24", "dev", tapName).Run(); err != nil {
		return nil, fmt.Errorf("failed to assign IP to TAP: %w", err)
	}

	if err := exec.Command("ip", "link", "set", "dev", tapName, "up").Run(); err != nil {
		return nil, fmt.Errorf("failed to bring up TAP device: %w", err)
	}

	// Setup NAT rules
	vmSubnet := "172.16.0.0/24"
	if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.SubnetCIDR != "" {
		vmSubnet = fcConfig.NetworkConfig.SubnetCIDR
	}

	// Enable IP forwarding
	exec.Command("sysctl", "-w", "net.ipv4.ip_forward=1").Run()

	// Setup iptables NAT
	exec.Command("iptables", "-t", "nat", "-A", "POSTROUTING", "-s", vmSubnet, "-o", parentInterface, "-j", "MASQUERADE").Run()
	exec.Command("iptables", "-A", "FORWARD", "-i", tapName, "-o", parentInterface, "-j", "ACCEPT").Run()
	exec.Command("iptables", "-A", "FORWARD", "-i", parentInterface, "-o", tapName, "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT").Run()

	vmInfo.Networking = "nat"
	vmInfo.Bridge = fmt.Sprintf("nat-%s", parentInterface)
	vmInfo.TAP = tapName
	vmInfo.IP = m.generateStaticIP(vmID)

	m.Log.Info("Setup NAT networking", "parent", parentInterface, "tap", tapName, "subnet", vmSubnet)
	return vmInfo, nil
}

func (m *FirecrackerVMManager) setupBridgeNetworking(vmID string, fcConfig *v1alpha1.FirecrackerRuntime, vmInfo *VMInfo) (*VMInfo, error) {
	// Use host bridge networking with DHCP for proper connectivity
	bridgeName := "br0" // Default host bridge
	if fcConfig.NetworkConfig != nil && fcConfig.NetworkConfig.BridgeName != "" {
		bridgeName = fcConfig.NetworkConfig.BridgeName
	}

	// Verify bridge exists
	if err := exec.Command("ip", "link", "show", bridgeName).Run(); err != nil {
		return nil, fmt.Errorf("bridge %s not found on host - please ensure host bridge networking is configured", bridgeName)
	}

	// Create unique TAP device name
	tapName := m.generateTAPName(vmID)
	
	m.Log.Info("Setting up bridge networking for DHCP", 
		"bridge", bridgeName, 
		"tap", tapName,
		"vmID", vmID)

	// Create TAP device
	if err := exec.Command("ip", "tuntap", "add", "dev", tapName, "mode", "tap").Run(); err != nil {
		return nil, fmt.Errorf("failed to create TAP device %s: %w", tapName, err)
	}

	// Attach TAP to bridge
	if err := exec.Command("ip", "link", "set", "dev", tapName, "master", bridgeName).Run(); err != nil {
		// Cleanup TAP on failure
		exec.Command("ip", "link", "del", tapName).Run()
		return nil, fmt.Errorf("failed to attach TAP %s to bridge %s: %w", tapName, bridgeName, err)
	}

	// Bring up TAP device
	if err := exec.Command("ip", "link", "set", "dev", tapName, "up").Run(); err != nil {
		// Cleanup on failure
		exec.Command("ip", "link", "del", tapName).Run()
		return nil, fmt.Errorf("failed to bring up TAP device %s: %w", tapName, err)
	}

	// Set promiscuous mode for bridge connectivity
	exec.Command("ip", "link", "set", "dev", tapName, "promisc", "on").Run()

	vmInfo.Networking = "dhcp"
	vmInfo.Bridge = bridgeName
	vmInfo.TAP = tapName
	vmInfo.IP = "dhcp" // Will be assigned by DHCP

	m.Log.Info("Bridge networking setup complete", 
		"bridge", bridgeName, 
		"tap", tapName,
		"networking", "dhcp")
	
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
		if err := exec.Command("ip", "link", "add", "name", bridge, "type", "bridge").Run(); err != nil {
			return fmt.Errorf("failed to create bridge: %w", err)
		}
		
		if err := exec.Command("ip", "addr", "add", "172.16.0.1/24", "dev", bridge).Run(); err != nil {
			return fmt.Errorf("failed to assign IP to bridge: %w", err)
		}
		
		if err := exec.Command("ip", "link", "set", "dev", bridge, "up").Run(); err != nil {
			return fmt.Errorf("failed to bring up bridge: %w", err)
		}
	}

	// Create TAP if it doesn't exist
	if err := exec.Command("ip", "link", "show", tap).Run(); err != nil {
		m.Log.Info("Creating TAP device", "tap", tap)
		if err := exec.Command("ip", "tuntap", "add", "dev", tap, "mode", "tap").Run(); err != nil {
			return fmt.Errorf("failed to create TAP device: %w", err)
		}
		
		if err := exec.Command("ip", "link", "set", "dev", tap, "master", bridge).Run(); err != nil {
			return fmt.Errorf("failed to attach TAP to bridge: %w", err)
		}
		
		if err := exec.Command("ip", "link", "set", "dev", tap, "up").Run(); err != nil {
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

packages:
  - curl
  - jq
  - git

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
  - path: /home/runner/setup-runner.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e
      
      # Create actions-runner directory
      mkdir -p /home/runner/actions-runner
      cd /home/runner/actions-runner
      
      # Download the latest runner package
      RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/v//')
      curl -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz
      
      # Extract the installer
      tar xzf ./actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz
      
      # Configure the runner
      ./config.sh --url %s --token %s --name %s --labels %s --unattended --ephemeral
      
      # Install and start the service
      sudo ./svc.sh install runner
      sudo ./svc.sh start
  - path: /etc/systemd/system/github-runner.service
    content: |
      [Unit]
      Description=GitHub Actions Runner
      After=network.target

      [Service]
      Type=simple
      User=runner
      WorkingDirectory=/home/runner/actions-runner
      ExecStart=/home/runner/actions-runner/run.sh
      Restart=always
      RestartSec=10

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl enable systemd-networkd
  - systemctl restart systemd-networkd
  - sleep 10
  - chown -R runner:runner /home/runner
  - sudo -u runner /home/runner/setup-runner.sh
  - systemctl enable github-runner
  - systemctl start github-runner

ssh_pwauth: false
`, runner.Name, pubKey, token, m.getGitHubURL(runner), runner.Name, strings.Join(runner.Spec.Labels, ","), token, m.getNetworkConfig(vmInfo, fcConfig), m.getGitHubURL(runner), token, runner.Name, strings.Join(runner.Spec.Labels, ","))

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

func (m *FirecrackerVMManager) startFirecrackerWithLogging(socketPath, consoleLogPath string) (int, error) {
	// Remove existing socket
	os.Remove(socketPath)
	
	// Create console log file
	consoleLog, err := os.Create(consoleLogPath)
	if err != nil {
		return 0, fmt.Errorf("failed to create console log file: %w", err)
	}
	defer consoleLog.Close()

	// Write initial log entry
	fmt.Fprintf(consoleLog, "=== Firecracker Console Log Started at %s ===\n", time.Now().Format(time.RFC3339))

	// Start Firecracker with console output redirected to log file
	cmd := exec.Command("firecracker", "--api-sock", socketPath)
	
	// Create new log file for this session
	logFile, err := os.OpenFile(consoleLogPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return 0, fmt.Errorf("failed to open console log for writing: %w", err)
	}
	
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	
	if err := cmd.Start(); err != nil {
		logFile.Close()
		return 0, fmt.Errorf("failed to start Firecracker: %w", err)
	}

	// Wait for socket to be ready
	for i := 0; i < 30; i++ {
		if _, err := os.Stat(socketPath); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	m.Log.Info("Firecracker started with console logging", 
		"pid", cmd.Process.Pid,
		"socket", socketPath,
		"consoleLog", consoleLogPath)

	return cmd.Process.Pid, nil
}

// GetVMConsoleLog returns the console log content for a VM
func (m *FirecrackerVMManager) GetVMConsoleLog(ctx context.Context, runner *v1alpha1.Runner) (string, error) {
	vmID := m.generateVMID(runner.Name)
	instanceDir := filepath.Join(m.WorkDir, "instances", vmID)
	consoleLogPath := filepath.Join(instanceDir, "console.log")
	
	if _, err := os.Stat(consoleLogPath); err != nil {
		return "", fmt.Errorf("console log not found: %w", err)
	}
	
	content, err := ioutil.ReadFile(consoleLogPath)
	if err != nil {
		return "", fmt.Errorf("failed to read console log: %w", err)
	}
	
	return string(content), nil
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

func (m *FirecrackerVMManager) generateTAPName(vmID string) string {
	// Generate a short unique TAP name that fits in 15 chars
	// Use hash of vmID to ensure uniqueness
	hash := 0
	for _, c := range vmID {
		hash = (hash*31 + int(c)) % 999999
	}
	return fmt.Sprintf("tap-%06d", hash)
}

func (m *FirecrackerVMManager) checkResourceLimits(fcConfig *v1alpha1.FirecrackerRuntime) error {
	// Check concurrent VM limit
	if len(m.activeVMs) >= MaxConcurrentVMs {
		return fmt.Errorf("maximum concurrent VMs reached (%d/%d)", len(m.activeVMs), MaxConcurrentVMs)
	}

	// Check available disk space
	if err := m.checkDiskSpace(); err != nil {
		return fmt.Errorf("insufficient disk space: %w", err)
	}

	// Validate memory limits
	if fcConfig.MemoryMiB > MaxVMMemoryMB {
		return fmt.Errorf("requested memory %d MB exceeds maximum %d MB", fcConfig.MemoryMiB, MaxVMMemoryMB)
	}

	// Validate CPU limits
	if fcConfig.VCPUs > MaxVMCPUs {
		return fmt.Errorf("requested vCPUs %d exceeds maximum %d", fcConfig.VCPUs, MaxVMCPUs)
	}

	return nil
}

func (m *FirecrackerVMManager) checkDiskSpace() error {
	// Use standard df command with human-readable output
	cmd := exec.Command("df", "-h", m.WorkDir)
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to check disk space: %w", err)
	}

	lines := strings.Split(string(output), "\n")
	if len(lines) < 2 {
		return fmt.Errorf("unexpected df output")
	}

	fields := strings.Fields(lines[1])
	if len(fields) < 4 {
		return fmt.Errorf("unexpected df output format")
	}

	// Parse available space (4th field, format like "30G", "500M", etc.)
	availableStr := fields[3]
	var availableGB float64
	
	if strings.HasSuffix(availableStr, "G") {
		availableGB, err = strconv.ParseFloat(strings.TrimSuffix(availableStr, "G"), 64)
		if err != nil {
			return fmt.Errorf("failed to parse available disk space: %w", err)
		}
	} else if strings.HasSuffix(availableStr, "M") {
		availableMB, err := strconv.ParseFloat(strings.TrimSuffix(availableStr, "M"), 64)
		if err != nil {
			return fmt.Errorf("failed to parse available disk space: %w", err)
		}
		availableGB = availableMB / 1024
	} else if strings.HasSuffix(availableStr, "T") {
		availableTB, err := strconv.ParseFloat(strings.TrimSuffix(availableStr, "T"), 64)
		if err != nil {
			return fmt.Errorf("failed to parse available disk space: %w", err)
		}
		availableGB = availableTB * 1024
	} else {
		// Assume bytes if no suffix
		availableBytes, err := strconv.ParseFloat(availableStr, 64)
		if err != nil {
			return fmt.Errorf("failed to parse available disk space: %w", err)
		}
		availableGB = availableBytes / 1024 / 1024 / 1024
	}

	if availableGB < float64(MinFreeDiskGB) {
		return fmt.Errorf("insufficient disk space: %.1fG available, %dG required", availableGB, MinFreeDiskGB)
	}

	return nil
}

func (m *FirecrackerVMManager) configureVM(socketPath, kernelPath, rootfsPath, instanceDir string, vmInfo *VMInfo, fcConfig *v1alpha1.FirecrackerRuntime) error {
	// Create HTTP client that connects to Unix socket
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return net.Dial("unix", socketPath)
		},
	}
	client := &http.Client{
		Transport: transport,
		Timeout:   FirecrackerSocketTimeout,
	}
	baseURL := "http://unix"

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

	// Set memory and CPU count from vmInfo (already validated)
	if err := makeAPICall("PUT", "/machine-config", map[string]interface{}{
		"vcpu_count":   vmInfo.VCPUs,
		"mem_size_mib": vmInfo.MemoryMB,
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