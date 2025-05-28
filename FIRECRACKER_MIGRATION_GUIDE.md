# Firecracker VM Migration Guide for Actions Runner Controller

This document provides a comprehensive guide for migrating the Actions Runner Controller from creating Kubernetes pods to creating Firecracker VMs for running GitHub Actions workflows.

## Overview

The migration involves:

1. **New API Types**: Define FirecrackerVM resource types
2. **Controller Updates**: Modify the runner controller to create VMs instead of pods
3. **VM Controller**: Implement a new controller to manage Firecracker VM lifecycle
4. **Environment Setup**: Configure the host system for Firecracker operations
5. **Cloud-Init Integration**: Dynamic configuration injection via cloud-init

## Architecture Changes

### Before (Pod-based)
```
Runner Resource → Pod Creation → Container with GitHub Actions runner
```

### After (VM-based)
```
Runner Resource → FirecrackerVM Creation → VM with cloud-init → GitHub Actions runner
```

## Implementation Steps

### 1. New API Types (`apis/actions.summerwind.net/v1alpha1/firecracker_vm_types.go`)

Created new Kubernetes custom resource definitions:

- `FirecrackerVM`: Main VM resource type
- `FirecrackerVMSpec`: VM configuration (memory, CPU, rootfs, etc.)
- `FirecrackerVMStatus`: VM runtime status and health
- `FirecrackerNetworkConfig`: Network configuration for VMs

Key features:
- Integration with existing `RunnerConfig` types
- Configurable VM resources (memory, vCPUs)
- Network configuration with IP assignment
- Cloud-init data injection
- Status tracking (Creating, Ready, Running, Failed)

### 2. Firecracker VM Controller (`controllers/actions.summerwind.net/firecracker_vm_controller.go`)

New controller that manages the complete VM lifecycle:

**Core Functions:**
- `Reconcile()`: Main reconciliation loop
- `createFirecrackerVM()`: VM creation and configuration
- `generateCloudInit()`: Dynamic cloud-init script generation
- `assignIPAddress()`: VM IP address management
- `updateVMStatus()`: Status updates based on VM state

**Cloud-Init Generation:**
- GitHub runner download and installation
- Token injection from GitHub API
- Network configuration
- Service setup and startup scripts

**VM Management:**
- Firecracker process lifecycle
- Resource allocation and limits
- Network interface setup
- Monitoring and health checks

### 3. Runner Controller Modifications (`controllers/actions.summerwind.net/runner_controller.go`)

Updated the existing runner controller:

**Changes in `processRunnerCreation()`:**
- Replaced `newPod()` with `newFirecrackerVM()`
- Removed pod-specific configurations (ServiceAccount, RBAC)
- Added VM-specific configuration
- Updated error handling for VM creation

**Changes in `Reconcile()`:**
- Query for `FirecrackerVM` instead of `Pod`
- Update status based on VM state
- Handle VM-specific lifecycle events

**New RBAC Permissions:**
```yaml
# +kubebuilder:rbac:groups=actions.summerwind.dev,resources=firecrackervm,verbs=get;list;watch;create;update;patch;delete
# +kubebuilder:rbac:groups=actions.summerwind.dev,resources=firecrackervm/status,verbs=get;update;patch
```

### 4. Environment Setup Script (`scripts/setup-firecracker-environment.sh`)

Comprehensive setup script that:

**System Dependencies:**
- Installs Firecracker binary
- Configures TAP networking
- Sets up iptables for NAT
- Enables IP forwarding

**Rootfs Preparation:**
- Downloads Ubuntu cloud image
- Converts and resizes for Firecracker
- Pre-installs GitHub Actions runner
- Configures cloud-init support
- Sets up runner user and permissions

**Helper Scripts:**
- Cloud-init ISO creation
- VM management service
- Network configuration utilities

### 5. Documentation (`docs/firecracker-vm-setup.md`)

Complete setup and configuration guide covering:

- Prerequisites and dependencies
- Rootfs image preparation
- Network configuration
- Cloud-init scripting
- Troubleshooting procedures
- Security considerations
- Performance optimization

## Key Configuration Changes

### VM Resource Defaults

```go
type RunnerPodDefaults struct {
    // ... existing fields ...
    
    // Firecracker VM defaults
    DefaultMemoryMiB int
    DefaultVCPUs     int
    RootfsPath       string
    KernelPath       string
}
```

### Expected File Paths

The controller expects these files to be present on the host:

- **Rootfs**: `/var/lib/firecracker/images/ubuntu-20.04.ext4`
- **Kernel**: `/var/lib/firecracker/images/vmlinux.bin`
- **TAP Interface**: `tap0` configured with `172.16.0.0/24`

### Cloud-Init Template

The controller generates cloud-init data that:

1. Updates packages and installs dependencies
2. Creates runner user with sudo privileges
3. Downloads GitHub Actions runner if not pre-installed
4. Configures runner with injected token and settings
5. Starts runner as a systemd service

## VM Configuration in Rootfs

### Required Steps in VM

The rootfs image should be prepared with:

1. **Base OS**: Ubuntu 20.04 with cloud-init support
2. **Runner User**: Pre-created with sudo privileges
3. **Dependencies**: curl, jq, git, docker pre-installed
4. **GitHub Runner**: Pre-downloaded and configured
5. **Cloud-Init**: Enabled services for bootstrap

### Runtime Configuration via Cloud-Init

The controller injects these configurations:

```yaml
#cloud-config
write_files:
  - path: /home/runner/setup-runner.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      export RUNNER_NAME='{{.VMName}}'
      export RUNNER_TOKEN='{{.GitHubToken}}'
      export RUNNER_URL='{{.GitHubURL}}'
      export RUNNER_LABELS='{{.RunnerLabels}}'
      
      ./config.sh --url $RUNNER_URL --token $RUNNER_TOKEN \
        --name $RUNNER_NAME --labels $RUNNER_LABELS \
        --ephemeral --unattended
      
      sudo ./svc.sh install
      sudo ./svc.sh start

runcmd:
  - /home/runner/setup-runner.sh
```

## Migration Steps

### 1. Prepare Host Environment

```bash
# Run as root
sudo ./scripts/setup-firecracker-environment.sh
```

### 2. Deploy Updated Controller

```bash
# Build and deploy with new FirecrackerVM support
make docker-build docker-push IMG=your-registry/actions-runner-controller:firecracker
make deploy IMG=your-registry/actions-runner-controller:firecracker
```

### 3. Update RBAC and CRDs

```bash
# Apply new CustomResourceDefinitions
kubectl apply -f config/crd/bases/

# Update RBAC permissions
kubectl apply -f config/rbac/
```

### 4. Test VM Creation

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: Runner
metadata:
  name: test-runner
spec:
  repository: your-org/your-repo
  labels:
    - "firecracker-vm"
```

### 5. Monitor VM Status

```bash
# Check FirecrackerVM resources
kubectl get firecrackervm

# Describe specific VM
kubectl describe firecrackervm test-runner

# Check runner registration
kubectl get runner test-runner -o yaml
```

## Security Considerations

1. **VM Isolation**: Each runner runs in an isolated Firecracker VM
2. **Network Segmentation**: VMs use isolated TAP interfaces
3. **Resource Limits**: Memory and CPU limits prevent resource exhaustion
4. **Token Security**: GitHub tokens injected securely via cloud-init
5. **Ephemeral VMs**: VMs destroyed after job completion

## Performance Benefits

1. **Better Isolation**: VMs provide stronger isolation than containers
2. **Resource Control**: Fine-grained resource allocation
3. **Fast Startup**: Pre-configured rootfs reduces startup time
4. **Parallel Execution**: Multiple VMs can run simultaneously
5. **Clean State**: Each job starts with a fresh VM

## Troubleshooting

### Common Issues

1. **VM Creation Fails**
   - Check if Firecracker binary is installed
   - Verify rootfs and kernel paths exist
   - Ensure TAP interface is configured

2. **Network Connectivity Issues**
   - Verify TAP interface and IP configuration
   - Check iptables rules for NAT
   - Test VM connectivity with ping

3. **Runner Registration Fails**
   - Verify GitHub token permissions
   - Check organization/repository access
   - Examine cloud-init logs in VM

### Debug Commands

```bash
# Check Firecracker installation
firecracker --version

# Verify network setup
ip addr show tap0
ping 172.16.0.10

# Check VM processes
ps aux | grep firecracker

# Monitor controller logs
kubectl logs -n arc-systems deployment/actions-runner-controller
```

## Future Enhancements

1. **Dynamic Resource Allocation**: Adjust VM resources based on job requirements
2. **VM Pooling**: Pre-create VMs for faster job startup
3. **Advanced Networking**: Support for multiple network interfaces
4. **Storage Management**: Persistent volumes for caching
5. **Monitoring Integration**: Prometheus metrics for VM performance

## Conclusion

This migration replaces Kubernetes pod creation with Firecracker VM creation, providing:

- **Enhanced Security**: VM-level isolation
- **Better Resource Control**: Dedicated VM resources
- **Improved Performance**: Optimized for CI/CD workloads
- **Flexible Configuration**: Cloud-init based setup
- **Seamless Integration**: Maintains existing GitHub Actions compatibility

The implementation maintains backward compatibility with existing Runner resources while adding new capabilities for VM-based execution. 