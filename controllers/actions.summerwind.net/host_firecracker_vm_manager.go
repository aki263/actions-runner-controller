package actionssummerwindnet

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"net/http"
	"time"

	"github.com/go-logr/logr"
	v1alpha1 "github.com/actions/actions-runner-controller/apis/actions.summerwind.net/v1alpha1"
)

// VMManager interface for different VM management implementations
type VMManager interface {
	CreateVM(ctx context.Context, runner *v1alpha1.Runner, registrationToken string) (*VMInfo, error)
	DeleteVM(ctx context.Context, runner *v1alpha1.Runner) error
	GetVMStatus(ctx context.Context, runner *v1alpha1.Runner) (*VMInfo, error)
}

// VMManagerAdapter adapts HostFirecrackerVMManager to the VMManager interface
type VMManagerAdapter struct {
	HostManager *HostFirecrackerVMManager
	Log         logr.Logger
}

const (
	// Annotation to store the VM ID for this runner
	AnnotationVMID = "firecracker.arc/vm-id"
)

// CreateVM adapts the host manager call to the expected interface
func (a *VMManagerAdapter) CreateVM(ctx context.Context, runner *v1alpha1.Runner, registrationToken string) (*VMInfo, error) {
	if runner.Spec.Runtime == nil || runner.Spec.Runtime.Firecracker == nil {
		return nil, fmt.Errorf("runner does not have Firecracker runtime configuration")
	}

	fcConfig := runner.Spec.Runtime.Firecracker
	githubURL := getGitHubURLFromRunner(runner)
	
	// Generate a deterministic VM ID and store it in annotations
	vmID := generateDeterministicVMID(runner.Name)
	
	// Call the host manager with the VM ID
	vmInfo, err := a.HostManager.CreateVM(ctx, runner.Name, vmID, fcConfig, registrationToken, githubURL)
	if err != nil {
		return nil, err
	}
	
	// Store the VM ID in runner annotations for future reference
	// Note: This should be done by the caller (runner controller) to avoid circular dependencies
	a.Log.Info("VM created with ID", "vmID", vmID, "runner", runner.Name)
	
	return vmInfo, nil
}

// DeleteVM adapts the host manager call to the expected interface
func (a *VMManagerAdapter) DeleteVM(ctx context.Context, runner *v1alpha1.Runner) error {
	vmID := getVMIDFromRunner(runner)
	return a.HostManager.DeleteVM(ctx, vmID)
}

// GetVMStatus adapts the host manager call to the expected interface
func (a *VMManagerAdapter) GetVMStatus(ctx context.Context, runner *v1alpha1.Runner) (*VMInfo, error) {
	vmID := getVMIDFromRunner(runner)
	return a.HostManager.GetVMStatus(ctx, vmID)
}

// getVMIDFromRunner gets the VM ID from runner annotations or generates a deterministic one
func getVMIDFromRunner(runner *v1alpha1.Runner) string {
	// First try to get stored VM ID from annotations
	if runner.Annotations != nil {
		if vmID, exists := runner.Annotations[AnnotationVMID]; exists && vmID != "" {
			return vmID
		}
	}
	
	// Fallback to deterministic generation
	return generateDeterministicVMID(runner.Name)
}

// generateDeterministicVMID creates a deterministic VM ID from runner name
func generateDeterministicVMID(runnerName string) string {
	// Use a hash of the runner name to make it deterministic but unique
	h := fnv.New32a()
	h.Write([]byte(runnerName))
	hashValue := h.Sum32()
	
	// Extract meaningful part and add hash for uniqueness
	prefix := runnerName
	if len(prefix) > 20 {
		prefix = prefix[:20]
	}
	
	return fmt.Sprintf("%s-%d", prefix, hashValue)
}

// getGitHubURLFromRunner extracts GitHub URL from runner spec
func getGitHubURLFromRunner(runner *v1alpha1.Runner) string {
	if runner.Spec.Repository != "" {
		return fmt.Sprintf("https://github.com/%s", runner.Spec.Repository)
	}
	if runner.Spec.Organization != "" {
		return fmt.Sprintf("https://github.com/%s", runner.Spec.Organization)
	}
	if runner.Spec.Enterprise != "" {
		return fmt.Sprintf("https://github.com/enterprises/%s", runner.Spec.Enterprise)
	}
	return "https://github.com"
}

// HostFirecrackerVMManager manages Firecracker VMs via host-based DaemonSet API
type HostFirecrackerVMManager struct {
	Log           logr.Logger
	DaemonAPIURL  string
	HTTPClient    *http.Client
}

// VMSpec represents the VM specification for the daemon API
type VMSpec struct {
	VMID       string `json:"vm_id"`
	GitHubURL  string `json:"github_url"`
	GitHubToken string `json:"github_token"`
	Labels     string `json:"labels"`
	MemoryMB   int    `json:"memory_mb"`
	VCPUs      int    `json:"vcpus"`
	Ephemeral  bool   `json:"ephemeral"`
}

// VMResponse represents the response from daemon API
type VMResponse struct {
	VMID    string `json:"vm_id"`
	Success bool   `json:"success"`
	Message string `json:"message"`
	Details interface{} `json:"details,omitempty"`
}

// VMListResponse represents the list VMs response
type VMListResponse struct {
	Success    bool                   `json:"success"`
	VMs        map[string]interface{} `json:"vms"`
	HostStatus string                 `json:"host_status"`
}

// NewHostFirecrackerVMManager creates a new host-based VM manager
func NewHostFirecrackerVMManager(log logr.Logger, daemonURL string) *HostFirecrackerVMManager {
	if daemonURL == "" {
		daemonURL = "http://localhost:30090" // Default DaemonSet NodePort
	}
	
	return &HostFirecrackerVMManager{
		Log:          log,
		DaemonAPIURL: daemonURL,
		HTTPClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// CreateVM creates a Firecracker VM via the host daemon API
func (m *HostFirecrackerVMManager) CreateVM(ctx context.Context, runnerName string, vmID string, fcConfig *v1alpha1.FirecrackerRuntime, registrationToken, githubURL string) (*VMInfo, error) {
	m.Log.Info("Creating Firecracker VM via host daemon", 
		"runner", runnerName,
		"githubURL", githubURL,
		"daemonURL", m.DaemonAPIURL)

	// Build VM specification
	vmSpec := VMSpec{
		VMID:        vmID,
		GitHubURL:   githubURL,
		GitHubToken: registrationToken,
		Labels:      "firecracker,host-based",
		MemoryMB:    fcConfig.MemoryMiB,
		VCPUs:       fcConfig.VCPUs,
		Ephemeral:   fcConfig.EphemeralMode,
	}
	
	// Convert to JSON
	jsonData, err := json.Marshal(vmSpec)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal VM spec: %w", err)
	}
	
	// Make API call to daemon
	url := fmt.Sprintf("%s/vms", m.DaemonAPIURL)
	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	
	req.Header.Set("Content-Type", "application/json")
	
	m.Log.Info("Calling host daemon API", "url", url, "vmID", vmID)
	
	resp, err := m.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to call daemon API: %w", err)
	}
	defer resp.Body.Close()
	
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}
	
	var vmResponse VMResponse
	if err := json.Unmarshal(body, &vmResponse); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}
	
	if !vmResponse.Success {
		return nil, fmt.Errorf("daemon failed to create VM: %s", vmResponse.Message)
	}
	
	m.Log.Info("VM created successfully via host daemon", 
		"vmID", vmResponse.VMID,
		"message", vmResponse.Message)
	
	// Return VM info using existing VMInfo struct fields
	return &VMInfo{
		Name:       runnerName,
		VMID:       vmResponse.VMID,
		IP:         "dhcp", // Will be assigned by host bridge DHCP
		Networking: "host-bridge-br0",
		Bridge:     "br0",
		TAP:        fmt.Sprintf("tap-%s", vmID[:8]),
		Created:    time.Now(),
		MemoryMB:   vmSpec.MemoryMB,
		VCPUs:      vmSpec.VCPUs,
		GitHubURL:  vmSpec.GitHubURL,
		Labels:     vmSpec.Labels,
		EphemeralMode: vmSpec.Ephemeral,
	}, nil
}

// DeleteVM deletes a Firecracker VM via the host daemon API
func (m *HostFirecrackerVMManager) DeleteVM(ctx context.Context, vmID string) error {
	m.Log.Info("Deleting Firecracker VM via host daemon", "vmID", vmID)
	
	url := fmt.Sprintf("%s/vms/%s", m.DaemonAPIURL, vmID)
	req, err := http.NewRequestWithContext(ctx, "DELETE", url, nil)
	if err != nil {
		return fmt.Errorf("failed to create delete request: %w", err)
	}
	
	resp, err := m.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to call daemon delete API: %w", err)
	}
	defer resp.Body.Close()
	
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read delete response: %w", err)
	}
	
	var vmResponse VMResponse
	if err := json.Unmarshal(body, &vmResponse); err != nil {
		return fmt.Errorf("failed to parse delete response: %w", err)
	}
	
	if !vmResponse.Success {
		return fmt.Errorf("daemon failed to delete VM: %s", vmResponse.Message)
	}
	
	m.Log.Info("VM deleted successfully via host daemon", "vmID", vmID)
	return nil
}

// GetVMStatus gets the status of a Firecracker VM via the host daemon API
func (m *HostFirecrackerVMManager) GetVMStatus(ctx context.Context, vmID string) (*VMInfo, error) {
	m.Log.Info("Getting Firecracker VM status via host daemon", "vmID", vmID)
	
	url := fmt.Sprintf("%s/vms/%s", m.DaemonAPIURL, vmID)
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create status request: %w", err)
	}
	
	resp, err := m.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to call daemon API: %w", err)
	}
	defer resp.Body.Close()
	
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}
	
	var vmResponse VMResponse
	if err := json.Unmarshal(body, &vmResponse); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}
	
	if !vmResponse.Success {
		return nil, fmt.Errorf("daemon failed to get VM status: %s", vmResponse.Message)
	}
	
	// Convert to VMInfo using existing struct fields
	return &VMInfo{
		VMID:       vmID,
		IP:         "dhcp",
		Networking: "host-bridge-br0",
		Bridge:     "br0",
		TAP:        fmt.Sprintf("tap-%s", vmID[:8]),
		Created:    time.Now(), // We don't have exact creation time from daemon
	}, nil
}

// ListVMs lists all VMs via the host daemon API
func (m *HostFirecrackerVMManager) ListVMs(ctx context.Context) ([]VMInfo, error) {
	url := fmt.Sprintf("%s/vms", m.DaemonAPIURL)
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create list request: %w", err)
	}
	
	resp, err := m.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to call daemon list API: %w", err)
	}
	defer resp.Body.Close()
	
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read list response: %w", err)
	}
	
	var listResponse VMListResponse
	if err := json.Unmarshal(body, &listResponse); err != nil {
		return nil, fmt.Errorf("failed to parse list response: %w", err)
	}
	
	// Convert to VMInfo slice
	var vms []VMInfo
	for vmID := range listResponse.VMs {
		vms = append(vms, VMInfo{
			VMID:       vmID,
			IP:         "dhcp",
			Networking: "host-bridge-br0",
			Bridge:     "br0",
		})
	}
	
	m.Log.Info("Listed VMs from host daemon", "count", len(vms))
	return vms, nil
}

// CheckDaemonHealth checks if the host daemon is healthy
func (m *HostFirecrackerVMManager) CheckDaemonHealth(ctx context.Context) error {
	url := fmt.Sprintf("%s/health", m.DaemonAPIURL)
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return fmt.Errorf("failed to create health request: %w", err)
	}
	
	resp, err := m.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("daemon health check failed: %w", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != 200 {
		return fmt.Errorf("daemon unhealthy: status %d", resp.StatusCode)
	}
	
	return nil
} 