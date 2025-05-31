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
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/go-logr/logr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/actions/actions-runner-controller/apis/actions.summerwind.net/v1alpha1"
)

const (
	// Use container-friendly paths instead of host paths
	FirecrackerWorkDir       = "/tmp/firecracker"
	FirecrackerKernelDir     = "/usr/local/share/firecracker/kernels"
	FirecrackerImagesDir     = "/usr/local/share/firecracker/images" 
	FirecrackerSnapshotsDir  = "/usr/local/share/firecracker/snapshots"
	FirecrackerInstancesDir  = "/tmp/firecracker/instances"
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

	// For simplified version, create a mock VM that simulates the behavior
	// This allows testing the controller logic without requiring actual VM creation
	log.Info("Creating Firecracker VM (simplified mode)", "runner", runner.Name)

	// Generate VM ID and configuration
	vmID := m.generateVMID(runner.Name)
	instanceDir := filepath.Join(m.WorkDir, "instances", vmID)
	if err := os.MkdirAll(instanceDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create instance directory: %w", err)
	}

	log.Info("Creating Firecracker VM", "vmID", vmID, "instanceDir", instanceDir)

	// Setup directories for temporary files
	if err := m.setupDirectories(); err != nil {
		return nil, fmt.Errorf("failed to setup directories: %w", err)
	}

	// Generate VM info for this runner
	vmInfo := &VMInfo{
		Name:               runner.Name,
		VMID:               vmID,
		MAC:                m.generateRandomMAC(),
		Networking:         "simulated",
		Bridge:             "sim-br0",
		TAP:                fmt.Sprintf("sim-tap-%s", vmID[:8]),
		GitHubURL:          m.getGitHubURL(runner),
		Labels:             strings.Join(runner.Spec.Labels, ","),
		Created:            time.Now(),
		PID:                os.Getpid() + int(time.Now().Unix())%1000, // Simulate a process ID
		EphemeralMode:      fcConfig.EphemeralMode,
		ARCMode:            fcConfig.ARCMode,
		ARCControllerURL:   fcConfig.ARCControllerURL,
		DockerMode:         fcConfig.DockerMode,
		SocketPath:         filepath.Join(instanceDir, "firecracker.socket"),
		SnapshotUsed:       fcConfig.SnapshotName,
		KernelUsed:         "embedded-kernel",
		IP:                 m.generateStaticIP(vmID),
	}

	// Create a mock socket file to simulate Firecracker process
	socketPath := filepath.Join(instanceDir, "firecracker.socket")
	if err := ioutil.WriteFile(socketPath, []byte("mock-socket"), 0644); err != nil {
		log.V(1).Info("Failed to create mock socket", "error", err)
	}

	// Save VM info
	if err := m.saveVMInfo(instanceDir, vmInfo); err != nil {
		log.Error(err, "Failed to save VM info", "vmID", vmID)
		// Don't fail the creation for this
	}

	log.Info("Firecracker VM created successfully (simulated)", 
		"vmID", vmID, 
		"ip", vmInfo.IP, 
		"pid", vmInfo.PID,
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

	// Log VM deletion (simulated)
	if vmInfo != nil {
		log.Info("Stopping Firecracker VM (simulated)", "vmID", vmID, "pid", vmInfo.PID)
	}

	// Remove instance directory
	if err := os.RemoveAll(instanceDir); err != nil {
		log.Error(err, "Failed to remove instance directory", "instanceDir", instanceDir)
		return err
	}

	log.Info("Firecracker VM deleted (simulated)", "vmID", vmID)
	return nil
}

// GetVMStatus returns the status of a Firecracker VM
func (m *FirecrackerVMManager) GetVMStatus(ctx context.Context, runner *v1alpha1.Runner) (*VMInfo, error) {
	vmID := m.generateVMID(runner.Name)
	instanceDir := filepath.Join(m.WorkDir, "instances", vmID)
	
	vmInfo, err := m.loadVMInfo(instanceDir)
	if err != nil {
		return nil, fmt.Errorf("failed to load VM info: %w", err)
	}

	// Simulate that the VM is running if the info file exists
	vmInfo.PID = os.Getpid() + int(time.Now().Unix())%1000

	return vmInfo, nil
}

// Helper methods

func (m *FirecrackerVMManager) setupDirectories() error {
	dirs := []string{
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