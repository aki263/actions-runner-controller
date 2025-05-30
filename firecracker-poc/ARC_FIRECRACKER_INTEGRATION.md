# ARC Firecracker Integration Design

## Overview

This document describes how to integrate Firecracker VMs into the Summerwind Actions Runner Controller (ARC) as an alternative to Kubernetes pods for running GitHub Actions runners.

## Current ARC Architecture

```
GitHub Actions → ARC Webhook Server → RunnerDeployment → RunnerReplicaSet → Runner → Pod
                                  ↓
                            HorizontalRunnerAutoscaler
```

**Key Components:**
- **RunnerDeployment**: Manages desired replica count and template
- **RunnerReplicaSet**: Creates/manages individual Runner resources
- **Runner**: Maps to a single Kubernetes pod running GitHub Actions runner
- **Webhook Server**: Receives GitHub workflow events for autoscaling
- **Pod**: Kubernetes pod with GitHub Actions runner binary

## Proposed Firecracker Integration

### 1. Enhanced RunnerDeployment Spec

Add a new field to toggle between pod and Firecracker mode:

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: firecracker-runners
spec:
  replicas: 2
  # NEW: Runtime configuration
  runtime:
    type: "firecracker"  # Options: "kubernetes" (default), "firecracker"
    firecracker:
      vmConfig:
        vcpuCount: 2
        memSizeMib: 2048
        kernelImagePath: "/opt/firecracker/vmlinux"
        rootfsImagePath: "/opt/firecracker/ubuntu.ext4"
        socketPath: "/tmp/firecracker-{runner-name}.socket"
      networking:
        hostInterface: "eth0"
        vmInterface: "tap0"
        subnet: "172.16.0.0/24"
      security:
        patTokenSecret: "github-pat-secret"  # PAT token stays on host
        sshKeySecret: "vm-ssh-key"          # For VM communication
  template:
    spec:
      repository: actions/actions-runner-controller
      # Standard runner config remains the same
```

### 2. Modified Controller Logic

#### RunnerDeployment Controller Changes

```go
// In runnerdeployment_controller.go
func (r *RunnerDeploymentReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // ... existing logic ...
    
    // Check runtime type
    if rd.Spec.Runtime != nil && rd.Spec.Runtime.Type == "firecracker" {
        return r.reconcileFirecrackerRunners(ctx, &rd)
    }
    
    // Default Kubernetes behavior
    return r.reconcileKubernetesRunners(ctx, &rd)
}

func (r *RunnerDeploymentReconciler) reconcileFirecrackerRunners(ctx context.Context, rd *v1alpha1.RunnerDeployment) (ctrl.Result, error) {
    // Create FirecrackerRunnerReplicaSet instead of RunnerReplicaSet
    return r.createFirecrackerReplicaSet(ctx, rd)
}
```

#### New FirecrackerRunner CRD

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: firecrackerrunners.actions.summerwind.dev
spec:
  group: actions.summerwind.dev
  names:
    kind: FirecrackerRunner
    plural: firecrackerrunners
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              runnerConfig:
                # Standard runner config (repo, labels, etc.)
              vmConfig:
                type: object
                properties:
                  vcpuCount: {type: integer}
                  memSizeMib: {type: integer}
                  socketPath: {type: string}
              networking:
                type: object
                properties:
                  ipAddress: {type: string}
                  sshPort: {type: integer}
          status:
            type: object
            properties:
              phase: {type: string}  # Pending, Running, Succeeded, Failed
              vmId: {type: string}
              registration:
                type: object
                properties:
                  token: {type: string}
                  expiresAt: {type: string}
```

#### FirecrackerRunner Controller

```go
type FirecrackerRunnerReconciler struct {
    client.Client
    Log           logr.Logger
    Scheme        *runtime.Scheme
    GitHubClient  *github.Client
    FirecrackerManager FirecrackerVMManager
}

func (r *FirecrackerRunnerReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    var runner v1alpha1.FirecrackerRunner
    if err := r.Get(ctx, req.NamespacedName, &runner); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    switch runner.Status.Phase {
    case "":
        return r.createVM(ctx, &runner)
    case "Pending":
        return r.checkVMStatus(ctx, &runner)
    case "Running":
        return r.monitorVM(ctx, &runner)
    default:
        return r.cleanupVM(ctx, &runner)
    }
}

func (r *FirecrackerRunnerReconciler) createVM(ctx context.Context, runner *v1alpha1.FirecrackerRunner) (ctrl.Result, error) {
    // 1. Generate registration token using GitHub client
    token, err := r.generateRegistrationToken(ctx, runner)
    if err != nil {
        return ctrl.Result{}, err
    }

    // 2. Create VM via Firecracker manager
    vmID, err := r.FirecrackerManager.CreateVM(ctx, FirecrackerVMSpec{
        Name:           runner.Name,
        VCPUCount:      runner.Spec.VMConfig.VCPUCount,
        MemSizeMiB:     runner.Spec.VMConfig.MemSizeMiB,
        SocketPath:     runner.Spec.VMConfig.SocketPath,
        RegistrationToken: token,
        Repository:     runner.Spec.RunnerConfig.Repository,
        Labels:         runner.Spec.RunnerConfig.Labels,
    })
    if err != nil {
        return ctrl.Result{}, err
    }

    // 3. Update status
    runner.Status.Phase = "Pending"
    runner.Status.VMId = vmID
    runner.Status.Registration.Token = token
    
    return ctrl.Result{RequeueAfter: 30 * time.Second}, r.Status().Update(ctx, runner)
}
```

### 3. Firecracker VM Manager

#### Interface

```go
type FirecrackerVMManager interface {
    CreateVM(ctx context.Context, spec FirecrackerVMSpec) (string, error)
    GetVMStatus(ctx context.Context, vmID string) (VMStatus, error)
    DeleteVM(ctx context.Context, vmID string) error
    GetVMIP(ctx context.Context, vmID string) (string, error)
}

type FirecrackerVMSpec struct {
    Name              string
    VCPUCount         int
    MemSizeMiB        int
    SocketPath        string
    RegistrationToken string
    Repository        string
    Labels            []string
    ArcWebhookURL     string  // For VM to communicate back to ARC
}

type VMStatus struct {
    State     string  // "Starting", "Running", "Stopped"
    IPAddress string
    SSHPort   int
}
```

#### Implementation

```go
type FirecrackerManagerImpl struct {
    Config FirecrackerConfig
    Logger logr.Logger
}

func (f *FirecrackerManagerImpl) CreateVM(ctx context.Context, spec FirecrackerVMSpec) (string, error) {
    // 1. Generate unique VM ID
    vmID := fmt.Sprintf("runner-%s-%d", spec.Name, time.Now().Unix())
    
    // 2. Prepare cloud-init with runner configuration
    cloudInit := f.generateCloudInit(spec)
    
    // 3. Call our firecracker-complete.sh script
    cmd := exec.Command("./firecracker-complete.sh", "create-runner-vm",
        "--vm-id", vmID,
        "--vcpu-count", strconv.Itoa(spec.VCPUCount),
        "--memory", strconv.Itoa(spec.MemSizeMiB),
        "--registration-token", spec.RegistrationToken,
        "--repository", spec.Repository,
        "--labels", strings.Join(spec.Labels, ","),
        "--arc-webhook-url", spec.ArcWebhookURL,
        "--ephemeral",
    )
    
    output, err := cmd.CombinedOutput()
    if err != nil {
        return "", fmt.Errorf("failed to create VM: %v, output: %s", err, output)
    }
    
    return vmID, nil
}

func (f *FirecrackerManagerImpl) generateCloudInit(spec FirecrackerVMSpec) string {
    return fmt.Sprintf(`#cloud-config
packages:
  - curl
  - jq

write_files:
  - path: /etc/github-runner/config
    content: |
      REGISTRATION_TOKEN=%s
      REPOSITORY=%s
      LABELS=%s
      ARC_WEBHOOK_URL=%s
      RUNNER_NAME=%s

runcmd:
  - /opt/actions-runner/setup-github-runner.sh
  - systemctl enable github-runner
  - systemctl start github-runner
`, spec.RegistrationToken, spec.Repository, strings.Join(spec.Labels, ","), spec.ArcWebhookURL, spec.Name)
}
```

### 4. VM-to-ARC Communication

#### ARC Webhook Endpoint for VMs

Add new endpoints to the ARC webhook server:

```go
// In webhook server
func (r *WebhookServer) setupVMEndpoints(mux *http.ServeMux) {
    mux.HandleFunc("/vm/status", r.handleVMStatus)
    mux.HandleFunc("/vm/job-completed", r.handleVMJobCompleted)
    mux.HandleFunc("/vm/heartbeat", r.handleVMHeartbeat)
}

func (r *WebhookServer) handleVMStatus(w http.ResponseWriter, req *http.Request) {
    var statusUpdate VMStatusUpdate
    if err := json.NewDecoder(req.Body).Decode(&statusUpdate); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }
    
    // Update FirecrackerRunner status in Kubernetes
    r.updateRunnerStatus(statusUpdate.VMId, statusUpdate.Status)
    
    w.WriteHeader(http.StatusOK)
}

func (r *WebhookServer) handleVMJobCompleted(w http.ResponseWriter, req *http.Request) {
    var completion VMJobCompletion
    if err := json.NewDecoder(req.Body).Decode(&completion); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }
    
    // Mark VM for cleanup (ephemeral mode)
    r.scheduleVMCleanup(completion.VMId)
    
    w.WriteHeader(http.StatusOK)
}

type VMStatusUpdate struct {
    VMId     string `json:"vm_id"`
    Status   string `json:"status"`
    IPAddress string `json:"ip_address,omitempty"`
}

type VMJobCompletion struct {
    VMId       string `json:"vm_id"`
    JobId      string `json:"job_id"`
    Status     string `json:"status"`
    CompletedAt time.Time `json:"completed_at"`
}
```

#### VM-side Agent

Extend our `firecracker-complete.sh` to include ARC communication:

```bash
# In VM startup script
setup_arc_communication() {
    local arc_webhook_url="$1"
    local vm_id="$2"
    
    # Send initial status
    curl -X POST "$arc_webhook_url/vm/status" \
        -H "Content-Type: application/json" \
        -d "{\"vm_id\":\"$vm_id\",\"status\":\"starting\"}"
    
    # Setup job completion monitoring
    setup_job_completion_monitoring "$arc_webhook_url" "$vm_id"
    
    # Setup heartbeat
    setup_heartbeat "$arc_webhook_url" "$vm_id"
}

setup_job_completion_monitoring() {
    local arc_webhook_url="$1"
    local vm_id="$2"
    
    cat > /etc/systemd/system/arc-job-monitor.service << EOF
[Unit]
Description=ARC Job Completion Monitor
After=github-runner.service

[Service]
Type=simple
ExecStart=/opt/scripts/monitor-job-completion.sh $arc_webhook_url $vm_id
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable arc-job-monitor
    systemctl start arc-job-monitor
}

# monitor-job-completion.sh
#!/bin/bash
ARC_WEBHOOK_URL="$1"
VM_ID="$2"

while true; do
    # Check if job completed (similar to our existing logic)
    if [ -f /tmp/ephemeral-cleanup ]; then
        job_id=$(cat /tmp/job-id 2>/dev/null || echo "unknown")
        
        # Notify ARC
        curl -X POST "$ARC_WEBHOOK_URL/vm/job-completed" \
            -H "Content-Type: application/json" \
            -d "{\"vm_id\":\"$VM_ID\",\"job_id\":\"$job_id\",\"status\":\"completed\",\"completed_at\":\"$(date -Iseconds)\"}"
        
        # Shutdown VM
        sudo shutdown -h now
        break
    fi
    
    sleep 10
done
```

### 5. Enhanced firecracker-complete.sh

Add ARC integration commands:

```bash
# New command: create-runner-vm
create_runner_vm() {
    local vm_id="$1"
    local vcpu_count="$2"
    local memory="$3"
    local registration_token="$4"
    local repository="$5"
    local labels="$6"
    local arc_webhook_url="$7"
    local ephemeral="$8"
    
    # Create cloud-init with ARC integration
    cat > "firecracker-data/cloud-init-${vm_id}.yml" << EOF
#cloud-config
packages:
  - curl
  - jq

write_files:
  - path: /etc/github-runner/config
    content: |
      REGISTRATION_TOKEN=${registration_token}
      REPOSITORY=${repository}
      LABELS=${labels}
      ARC_WEBHOOK_URL=${arc_webhook_url}
      VM_ID=${vm_id}
      EPHEMERAL=${ephemeral}

runcmd:
  - /opt/setup-github-runner.sh
  - /opt/setup-arc-communication.sh "${arc_webhook_url}" "${vm_id}"
EOF

    # Launch VM with our standard process
    launch_vm "$vm_id" \
        --vcpus "$vcpu_count" \
        --memory "$memory" \
        --cloud-init "firecracker-data/cloud-init-${vm_id}.yml"
}

# New command: list-vms (for ARC to query)
list_vms() {
    find firecracker-data -name "*.socket" -type s | while read socket; do
        vm_id=$(basename "$socket" .socket)
        status=$(get_vm_status "$vm_id")
        echo "$vm_id:$status"
    done
}

# New command: delete-vm (for ARC cleanup)
delete_vm() {
    local vm_id="$1"
    
    # Send shutdown signal
    curl --unix-socket "firecracker-data/${vm_id}.socket" \
         -X PUT "http://localhost/actions" \
         -H "Content-Type: application/json" \
         -d '{"action_type": "SendCtrlAltDel"}'
    
    # Wait a bit then force cleanup
    sleep 10
    cleanup_vm "$vm_id"
}
```

### 6. Networking Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Kubernetes Cluster                                          │
│                                                             │
│ ┌─────────────────┐     ┌─────────────────┐                │
│ │ ARC Controller  │────▶│ Firecracker VMs │                │
│ │                 │     │                 │                │
│ │ - Pod Management│     │ - VM Management │                │
│ │ - Webhook Server│     │ - Registration  │                │
│ └─────────────────┘     └─────────────────┘                │
│          │                       │                          │
│          │                       │                          │
└──────────┼───────────────────────┼──────────────────────────┘
           │                       │
           │                       │
    ┌──────▼───────┐         ┌─────▼─────┐
    │ GitHub       │         │ VM Host   │
    │ Actions      │         │           │
    │              │         │ firecracker-poc/
    │              │         │ ├── VMs   │
    │              │         │ └── Scripts
    └──────────────┘         └───────────┘
```

**Communication Flow:**
1. **ARC → VM Creation**: ARC calls `firecracker-complete.sh create-runner-vm`
2. **VM → ARC Status**: VM sends status updates to ARC webhook endpoints
3. **GitHub → VM**: Standard GitHub Actions runner communication
4. **VM → ARC Completion**: VM notifies ARC when job completes (ephemeral mode)

### 7. Security Model

**Maintained Security:**
- PAT tokens stay on ARC controller (Kubernetes host)
- Only short-lived registration tokens sent to VMs
- VMs cannot access long-lived credentials
- SSH keys for VM management stored in Kubernetes secrets

**VM Authentication:**
- VMs authenticate to ARC webhook using shared secrets
- IP-based allow listing for VM communication
- TLS for all VM-to-ARC communication

### 8. Configuration Example

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: firecracker-runners
  namespace: actions-runner-system
spec:
  replicas: 5
  runtime:
    type: "firecracker"
    firecracker:
      vmConfig:
        vcpuCount: 4
        memSizeMib: 4096
        kernelImagePath: "/opt/firecracker/vmlinux"
        rootfsImagePath: "/opt/firecracker/ubuntu.ext4"
      networking:
        subnet: "172.16.0.0/24"
        bridge: "br0"
      storage:
        workspaceSize: "10GB"
      security:
        patTokenSecret: "github-pat-secret"
        vmSSHKeySecret: "firecracker-ssh-key"
        webhookSecret: "arc-webhook-secret"
  template:
    spec:
      repository: "myorg/myrepo"
      labels: ["self-hosted", "firecracker", "linux"]
      group: "production"
      ephemeral: true
---
apiVersion: actions.summerwind.dev/v1alpha1
kind: HorizontalRunnerAutoscaler
metadata:
  name: firecracker-runner-autoscaler
spec:
  scaleTargetRef:
    kind: RunnerDeployment
    name: firecracker-runners
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: TotalNumberOfQueuedAndInProgressWorkflowRuns
    repositoryNames: ["myorg/myrepo"]
```

### 9. Implementation Roadmap

#### Phase 1: Core Integration (Current)
- [x] Enhanced firecracker-complete.sh with all VM management
- [x] VM lifecycle management and networking
- [x] Ephemeral runner support with job completion detection
- [ ] RunnerDeployment CRD extensions
- [ ] FirecrackerRunner CRD creation
- [ ] Basic VM manager implementation

#### Phase 2: ARC Integration
- [ ] FirecrackerRunner controller
- [ ] ARC webhook endpoints for VM communication
- [ ] Modified RunnerDeployment controller
- [ ] VM-to-ARC status reporting

#### Phase 3: Production Features
- [ ] Horizontal autoscaling support
- [ ] Advanced networking (multiple interfaces, VLANs)
- [ ] VM snapshotting for faster startup
- [ ] Resource monitoring and metrics
- [ ] Multi-tenant support

#### Phase 4: Advanced Features
- [ ] GPU passthrough support
- [ ] Custom VM images
- [ ] Persistent storage volumes
- [ ] VM migration capabilities

### 10. Benefits

**Performance:**
- Faster startup than container pulls (snapshot support)
- Better isolation than containers
- Direct hardware access for demanding workloads

**Security:**
- Complete kernel isolation
- Controlled networking environment
- No shared kernel vulnerabilities

**Flexibility:**
- Custom kernel configurations
- Support for different Linux distributions
- Direct hardware device access

**Cost Optimization:**
- More efficient resource utilization
- Faster scale-down (immediate VM termination)
- No container image storage overhead

This design maintains backward compatibility with existing ARC deployments while adding powerful Firecracker VM capabilities for users who need stronger isolation or performance characteristics. 