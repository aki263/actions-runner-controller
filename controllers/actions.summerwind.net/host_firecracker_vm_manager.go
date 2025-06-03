package actionssummerwindnet

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"net/http"
	"strings"
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
	// Get Firecracker configuration from spec.runtime or fallback to annotations
	var fcConfig *v1alpha1.FirecrackerRuntime
	var arcControllerURL string
	
	if runner.Spec.Runtime != nil && runner.Spec.Runtime.Firecracker != nil {
		// Use spec.runtime configuration (preferred)
		fcConfig = runner.Spec.Runtime.Firecracker
		arcControllerURL = fcConfig.ARCControllerURL
	} else {
		// Fallback to annotation-based configuration
		fcConfig = getFirecrackerConfigFromAnnotations(runner)
		if fcConfig == nil {
			return nil, fmt.Errorf("runner does not have Firecracker runtime configuration")
		}
		arcControllerURL = fcConfig.ARCControllerURL
	}
	
	githubURL := getGitHubURLFromRunner(runner)
	
	// Use runner name directly instead of generating a separate VM ID
	runnerName := runner.Name
	
	// Call the host manager with the runner name
	vmInfo, err := a.HostManager.CreateVM(ctx, runnerName, runnerName, fcConfig, registrationToken, githubURL, arcControllerURL)
	if err != nil {
		return nil, err
	}
	
	// Store the runner name in runner annotations for future reference
	// Note: This should be done by the caller (runner controller) to avoid circular dependencies
	a.Log.Info("VM created with name", "runnerName", runnerName, "runner", runner.Name)
	
	return vmInfo, nil
}

// DeleteVM adapts the host manager call to the expected interface
func (a *VMManagerAdapter) DeleteVM(ctx context.Context, runner *v1alpha1.Runner) error {
	// Use runner name directly for deletion instead of generated VM ID
	runnerName := runner.Name
	arcControllerURL := ""
	
	if runner.Spec.Runtime != nil && runner.Spec.Runtime.Firecracker != nil {
		arcControllerURL = runner.Spec.Runtime.Firecracker.ARCControllerURL
	} else {
		// Fallback to annotation-based configuration
		if fcConfig := getFirecrackerConfigFromAnnotations(runner); fcConfig != nil {
			arcControllerURL = fcConfig.ARCControllerURL
		}
	}
	
	return a.HostManager.DeleteVM(ctx, runnerName, arcControllerURL)
}

// GetVMStatus adapts the host manager call to the expected interface
func (a *VMManagerAdapter) GetVMStatus(ctx context.Context, runner *v1alpha1.Runner) (*VMInfo, error) {
	// Use runner name directly for status checking instead of generated VM ID
	runnerName := runner.Name
	arcControllerURL := ""
	
	if runner.Spec.Runtime != nil && runner.Spec.Runtime.Firecracker != nil {
		arcControllerURL = runner.Spec.Runtime.Firecracker.ARCControllerURL
	} else {
		// Fallback to annotation-based configuration
		if fcConfig := getFirecrackerConfigFromAnnotations(runner); fcConfig != nil {
			arcControllerURL = fcConfig.ARCControllerURL
		}
	}
	
	return a.HostManager.GetVMStatus(ctx, runnerName, arcControllerURL)
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
	DaemonAPIURLs []string  // Support multiple URLs for failover
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

// NewHostFirecrackerVMManager creates a new host-based VM manager with failover support
func NewHostFirecrackerVMManager(log logr.Logger, daemonURL string) *HostFirecrackerVMManager {
	var daemonURLs []string
	
	if daemonURL == "" {
		// Default to HA URLs if no specific daemonURL is provided globally
		daemonURLs = []string{
			"http://199.180.135.32:30090",
			"http://192.168.21.32:30090",
		}
		log.Info("No global daemonURL provided. Using default HA daemon URLs.", "urls", daemonURLs)
	} else {
		// Parse multiple URLs from environment variable (comma-separated)
		urls := strings.Split(daemonURL, ",")
		for _, url := range urls {
			url = strings.TrimSpace(url)
			if url != "" {
				daemonURLs = append(daemonURLs, url)
			}
		}
		log.Info("Using configured daemon URLs", "urls", daemonURLs)
	}
	
	return &HostFirecrackerVMManager{
		Log:           log,
		DaemonAPIURLs: daemonURLs,
		HTTPClient: &http.Client{
			Timeout: 5 * time.Second, // Set timeout to 5 seconds
		},
	}
}

// makeRequestWithFailover attempts the request with multiple daemon URLs
func (m *HostFirecrackerVMManager) makeRequestWithFailover(ctx context.Context, method, specificArcURL, endpoint string, body io.Reader) (*http.Response, error) {
	var lastErr error
	
	urlsToTry := m.DaemonAPIURLs
	if specificArcURL != "" {
		urlsToTry = []string{specificArcURL}
		m.Log.V(1).Info("Using specific ARCControllerURL for request", "targetURL", specificArcURL)
	} else if len(m.DaemonAPIURLs) == 0 {
		return nil, fmt.Errorf("no daemon API URLs configured and no specific ARCControllerURL provided for request to endpoint %s", endpoint)
	}

	for i, baseURL := range urlsToTry {
		url := fmt.Sprintf("%s%s", baseURL, endpoint)
		
		m.Log.V(1).Info("Attempting request", 
			"attempt", i+1,
			"url", url,
			"method", method)
		
		// Create fresh request for each attempt (body can only be read once)
		var requestBody io.Reader
		if body != nil {
			// Convert body to bytes so we can reuse it
			if bytesBody, ok := body.(*bytes.Buffer); ok {
				requestBody = bytes.NewBuffer(bytesBody.Bytes())
			} else {
				bodyBytes, err := io.ReadAll(body)
				if err != nil {
					lastErr = fmt.Errorf("failed to read request body: %w", err)
					continue
				}
				requestBody = bytes.NewBuffer(bodyBytes)
			}
		}
		
		req, err := http.NewRequestWithContext(ctx, method, url, requestBody)
		if err != nil {
			lastErr = fmt.Errorf("failed to create request for %s: %w", url, err)
			m.Log.V(1).Info("Request creation failed", "url", url, "error", err)
			continue
		}
		
		req.Header.Set("Content-Type", "application/json")
		
		resp, err := m.HTTPClient.Do(req)
		if err != nil {
			lastErr = fmt.Errorf("request to %s failed: %w", url, err)
			m.Log.V(1).Info("Request failed", "url", url, "error", err)
			continue
		}
		
		// Success!
		m.Log.Info("Request succeeded", "url", url, "status", resp.Status)
		return resp, nil
	}
	
	// All attempts failed
	return nil, fmt.Errorf("all daemon URLs failed, last error: %w", lastErr)
}

// CreateVM creates a Firecracker VM via the host daemon API
func (m *HostFirecrackerVMManager) CreateVM(ctx context.Context, runnerName string, vmID string, fcConfig *v1alpha1.FirecrackerRuntime, registrationToken, githubURL, arcControllerURL string) (*VMInfo, error) {
	m.Log.Info("Creating Firecracker VM via host daemon", 
		"runner", runnerName,
		"vmID", vmID,
		"githubURL", githubURL,
		"arcControllerURL", arcControllerURL, // This will be passed to the VM for status reporting
		"daemonURLs", m.DaemonAPIURLs, // These are the actual API endpoints we'll call
		"memory", fcConfig.MemoryMiB,
		"vcpus", fcConfig.VCPUs,
		"ephemeral", fcConfig.EphemeralMode)

	// Build VM specification - match the expected format from host-install-improved.sh
	vmSpec := map[string]interface{}{
		"name":        runnerName,     // Use actual runner name, not generated vmID
		"memory":      fcConfig.MemoryMiB,
		"cpus":        fcConfig.VCPUs,
		"github_url":  githubURL,
		"github_token": registrationToken,
		"snapshot":    fcConfig.SnapshotName, // Use snapshot from config
	}
	
	// Convert to JSON
	jsonData, err := json.Marshal(vmSpec)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal VM spec: %w", err)
	}
	
	m.Log.Info("VM specification prepared", 
		"vmSpec", string(jsonData),
		"tokenLength", len(registrationToken))
	
	// Make API call to daemon with failover - use /api/vms endpoint
	// Use empty string for specificArcURL to use the configured daemon URLs
	resp, err := m.makeRequestWithFailover(ctx, "POST", "", "/api/vms", bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("failed to create VM via daemon API (tried URLs: %v): %w", m.DaemonAPIURLs, err)
	}
	defer resp.Body.Close()
	
	// Read response
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}
	
	m.Log.Info("Daemon response received", 
		"status", resp.Status,
		"responseBody", string(respBody))
	
	// Parse response - the daemon returns {"vm_name": "...", "status": "creating", ...}
	var vmResponse map[string]interface{}
	if err := json.Unmarshal(respBody, &vmResponse); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}
	
	// Check if there's an error in the response
	if errorMsg, exists := vmResponse["error"]; exists {
		return nil, fmt.Errorf("daemon reported VM creation failure: %v", errorMsg)
	}
	
	// Extract VM info from response
	vmInfo := &VMInfo{
		VMID:   runnerName,  // Use runner name as VMID for consistency
		Name:   runnerName,  // Set the name
		IP:     "", // Will be populated when VM starts
		PID:    0,  // Will be populated when VM starts
		Status: "creating",
	}
	
	// Try to extract more details from response
	if vmName, ok := vmResponse["vm_name"].(string); ok {
		vmInfo.Name = vmName
		vmInfo.VMID = vmName  // Use actual VM name from daemon
	}
	if status, ok := vmResponse["status"].(string); ok {
		vmInfo.Status = status
	}
	if message, ok := vmResponse["message"].(string); ok {
		m.Log.Info("VM creation message", "message", message)
	}
	
	m.Log.Info("VM creation initiated successfully", 
		"vmID", vmInfo.VMID,
		"status", vmInfo.Status)
	
	return vmInfo, nil
}

// DeleteVM deletes a Firecracker VM via the host daemon API
func (m *HostFirecrackerVMManager) DeleteVM(ctx context.Context, runnerName string, arcControllerURL string) error {
	m.Log.Info("Deleting Firecracker VM via host daemon", "runnerName", runnerName, "daemonURLs", m.DaemonAPIURLs)
	
	resp, err := m.makeRequestWithFailover(ctx, "DELETE", "", fmt.Sprintf("/api/vms/%s", runnerName), nil)
	if err != nil {
		// If the endpoint doesn't exist yet, just log it and continue
		m.Log.Info("VM deletion endpoint not available, assuming VM will be cleaned up automatically", "runnerName", runnerName, "error", err)
		return nil
	}
	defer resp.Body.Close()
	
	// Read response
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read response: %w", err)
	}
	
	m.Log.Info("Delete VM response", "status", resp.Status, "body", string(respBody))
	
	if resp.StatusCode >= 400 {
		// Don't fail deletion if the endpoint doesn't exist
		m.Log.Info("VM deletion endpoint returned error, but continuing", "runnerName", runnerName, "status", resp.StatusCode, "body", string(respBody))
		return nil
	}
	
	m.Log.Info("VM deleted successfully", "runnerName", runnerName)
	return nil
}

// GetVMStatus gets the status of a Firecracker VM via the host daemon API
func (m *HostFirecrackerVMManager) GetVMStatus(ctx context.Context, runnerName string, arcControllerURL string) (*VMInfo, error) {
	m.Log.Info("Getting Firecracker VM status via host daemon", "runnerName", runnerName, "daemonURLs", m.DaemonAPIURLs)
	
	resp, err := m.makeRequestWithFailover(ctx, "GET", "", fmt.Sprintf("/api/vms/%s", runnerName), nil)
	if err != nil {
		// If the endpoint doesn't exist yet, return a basic status since VM was created
		m.Log.V(1).Info("VM status endpoint not available, returning basic status", "runnerName", runnerName, "error", err)
		return &VMInfo{
			VMID:   runnerName,
			Status: "running", // Assume running if we can't check
		}, nil
	}
	defer resp.Body.Close()
	
	// Read response
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}
	
	m.Log.V(1).Info("VM status response", "status", resp.Status, "body", string(respBody))
	
	if resp.StatusCode == 404 {
		return nil, fmt.Errorf("VM not found: %s", runnerName)
	}
	
	if resp.StatusCode >= 400 {
		// If the endpoint doesn't exist, return basic status
		m.Log.V(1).Info("VM status endpoint returned error, assuming VM is running", "runnerName", runnerName, "status", resp.StatusCode)
		return &VMInfo{
			VMID:   runnerName,
			Status: "running",
		}, nil
	}
	
	// Parse the response to extract VM info
	vmInfo := &VMInfo{
		VMID:   runnerName,
		Status: "running", // Default to running
	}
	
	// Try to parse the response for more details
	var statusResponse map[string]interface{}
	if err := json.Unmarshal(respBody, &statusResponse); err == nil {
		if errorMsg, exists := statusResponse["error"]; exists {
			return nil, fmt.Errorf("daemon reported VM status check failure: %v", errorMsg)
		}
		
		// Extract VM information if available
		if status, ok := statusResponse["status"].(string); ok {
			vmInfo.Status = status
		}
		if vmName, ok := statusResponse["vm_name"].(string); ok {
			vmInfo.Name = vmName
		}
		// Extract PID if available 
		if pid, ok := statusResponse["pid"].(float64); ok {
			vmInfo.PID = int(pid)
		}
		// Extract IP if available
		if ip, ok := statusResponse["ip"].(string); ok {
			vmInfo.IP = ip
		}
	}
	
	m.Log.Info("VM status retrieved", "runnerName", runnerName, "status", vmInfo.Status, "pid", vmInfo.PID)
	return vmInfo, nil
}

// ListVMs lists all VMs via the host daemon API with failover
// Note: ListVMs might still need to use the global DaemonAPIURLs if it's not specific to one runner's node.
// For now, it will use the first available global URL if specificArcURL is empty.
// This behavior might need refinement based on how ListVMs is used.
func (m *HostFirecrackerVMManager) ListVMs(ctx context.Context, specificArcURL string) ([]VMInfo, error) {
	log := m.Log
	if specificArcURL != "" {
		log = log.WithValues("arcControllerURL", specificArcURL)
	}
	log.Info("Listing VMs via host daemon API")

	resp, err := m.makeRequestWithFailover(ctx, "GET", specificArcURL, "/api/vms", nil)
	if err != nil {
		errMsg := "failed to list VMs via daemon API"
		if specificArcURL != "" {
			errMsg = fmt.Sprintf("%s (tried URL: %s)", errMsg, specificArcURL)
		}
		return nil, fmt.Errorf("%s: %w", errMsg, err)
	}
	defer resp.Body.Close()
	
	// Read response
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}
	
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("daemon API returned error status %d: %s", resp.StatusCode, string(respBody))
	}
	
	// Parse response
	var listResponse VMListResponse
	if err := json.Unmarshal(respBody, &listResponse); err != nil {
		return nil, fmt.Errorf("failed to parse list response: %w", err)
	}
	
	if !listResponse.Success {
		return nil, fmt.Errorf("daemon reported list VMs failure")
	}
	
	// Convert to VMInfo array
	var vms []VMInfo
	for vmID, vmData := range listResponse.VMs {
		vmInfo := VMInfo{
			VMID: vmID,
		}
		
		// Extract more details if available
		if vmMap, ok := vmData.(map[string]interface{}); ok {
			if status, ok := vmMap["status"].(string); ok {
				vmInfo.Status = status
			}
		}
		
		vms = append(vms, vmInfo)
	}
	
	m.Log.Info("Listed VMs", "count", len(vms))
	return vms, nil
}

// CheckDaemonHealth checks if the host daemon is healthy with failover
// This method might need to iterate through all known daemon URLs or accept a specific one.
// For now, it will use the specificArcURL if provided, otherwise the global list.
func (m *HostFirecrackerVMManager) CheckDaemonHealth(ctx context.Context, specificArcURL string) error {
	log := m.Log
	targetDescription := "configured/default daemons"
	if specificArcURL != "" {
		log = log.WithValues("arcControllerURL", specificArcURL)
		targetDescription = fmt.Sprintf("daemon at %s", specificArcURL)
	}
	log.Info("Checking daemon health", "target", targetDescription)

	resp, err := m.makeRequestWithFailover(ctx, "GET", specificArcURL, "/health", nil)
	if err != nil {
		return fmt.Errorf("failed to check daemon health for %s: %w", targetDescription, err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != 200 {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("daemon health check failed with status %d: %s", resp.StatusCode, string(respBody))
	}
	
	m.Log.V(1).Info("Daemon health check passed")
	return nil
} 