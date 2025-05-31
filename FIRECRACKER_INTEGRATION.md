# Firecracker Integration for Actions Runner Controller

This document describes the Firecracker VM runtime integration for the summerwind Actions Runner Controller, enabling GitHub Actions runners to execute inside secure, lightweight virtual machines.

## Overview

The Firecracker integration adds VM-based runner support to ARC while maintaining full backward compatibility with container-based runners. This provides enhanced security isolation, better resource control, and the ability to run workflows that require kernel-level access or specific OS configurations.

## Features

- **VM-based GitHub Actions runners** using Firecracker microVMs
- **Multiple networking modes**: static IP assignment and host bridge with DHCP
- **Flexible VM configuration**: customizable memory, CPU, kernel, and rootfs
- **Snapshot support** for faster VM startup times
- **ARC integration** with automated VM-to-controller communication
- **Ephemeral mode** with automatic cleanup after job completion
- **Full backward compatibility** with existing container-based runners

## Quick Start

### 1. Build the Firecracker-enabled Controller Image

```bash
# Build using the Makefile (recommended)
make docker-build-firecracker

# Or build the optimized version
make docker-build-firecracker-optimized

# For multi-architecture builds
make docker-buildx-firecracker

# View all available targets
make help
```

### 2. Prepare Firecracker Assets

Use the provided `firecracker-complete.sh` script to build kernel and rootfs:

```bash
# Build Ubuntu 24.04 kernel and rootfs with GitHub Actions runner
./firecracker-complete.sh

# This creates:
# - /opt/firecracker/kernels/vmlinux-6.1.128-ubuntu24
# - /opt/firecracker/images/actions-runner-ubuntu-24.04.ext4
```

### 3. Deploy the Enhanced Controller

```bash
# Apply the Firecracker-enabled deployment
kubectl apply -f firecracker-controller-deployment.yaml

# Ensure nodes are labeled for Firecracker support
kubectl label nodes <node-name> firecracker.io/enabled=true
```

### 4. Create Firecracker Runners

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: firecracker-runners
spec:
  replicas: 2
  template:
    spec:
      organization: your-org
      labels: ["firecracker"]
      runtime:
        type: firecracker
        firecracker:
          memoryMiB: 4096
          vcpus: 2
          kernelImagePath: "/opt/firecracker/kernels/vmlinux-6.1.128-ubuntu24"
          rootfsImagePath: "/opt/firecracker/images/actions-runner-ubuntu-24.04.ext4"
          networkConfig:
            networkMode: "static"
          ephemeralMode: true
          arcMode: true
```

## Docker Image Components

### Base Image Changes

The Firecracker-enabled image includes:

- **Ubuntu 22.04 base** (replacing distroless for system utility support)
- **Firecracker binary** and runtime dependencies
- **Network utilities**: `iproute2`, `bridge-utils`, `iptables`, `dnsmasq`
- **Cloud-init tools** for VM configuration
- **File system utilities**: `util-linux`, `e2fsprogs`

### Security Context

The controller runs with elevated privileges required for VM management:

```yaml
securityContext:
  privileged: true
  allowPrivilegeEscalation: true
  capabilities:
    add:
    - NET_ADMIN
    - SYS_ADMIN
    - SYS_RESOURCE
```

### Volume Mounts

Required host directories:

- `/opt/firecracker/kernels` - VM kernel images
- `/opt/firecracker/images` - VM rootfs images
- `/opt/firecracker/snapshots` - VM snapshots
- `/var/lib/firecracker/vms` - Runtime VM data

## Configuration Options

### Runtime Configuration

```yaml
runtime:
  type: firecracker  # or "container" for backward compatibility
  firecracker:
    # VM Resources
    memoryMiB: 4096        # VM memory allocation
    vcpus: 2               # Virtual CPU count
    
    # VM Images
    kernelImagePath: "/path/to/kernel"
    rootfsImagePath: "/path/to/rootfs"
    snapshotName: "my-snapshot"  # Alternative to image paths
    
    # Networking
    networkConfig:
      networkMode: "static"      # or "bridge"
      bridgeName: "br0"          # for bridge mode
      dhcpEnabled: true          # for bridge mode
    
    # Behavior
    ephemeralMode: true          # Delete VM after job completion
    useHostBridge: false         # Use existing host bridge
    dockerMode: false            # Enable Docker inside VM
    
    # ARC Integration
    arcMode: true                # Enable ARC communication
    arcControllerURL: "http://controller:30080"
```

### Network Modes

#### Static IP Mode (Default)
- Assigns static IPs from 172.16.0.0/24 range
- Automatic routing configuration
- No external DHCP dependencies

#### Bridge Mode with DHCP
- Uses existing network bridges
- DHCP-assigned IP addresses
- Better integration with existing infrastructure

### Environment Variables

Configure the controller with:

```yaml
env:
- name: FIRECRACKER_KERNEL_PATH
  value: "/opt/firecracker/kernels"
- name: FIRECRACKER_ROOTFS_PATH
  value: "/opt/firecracker/images"
- name: FIRECRACKER_SNAPSHOTS_PATH
  value: "/opt/firecracker/snapshots"
- name: FIRECRACKER_VM_PATH
  value: "/var/lib/firecracker/vms"
```

## Deployment Considerations

### Node Requirements

Nodes running Firecracker VMs must:

1. **Support KVM virtualization**
   ```bash
   # Check KVM support
   lsmod | grep kvm
   ls -la /dev/kvm
   ```

2. **Have Firecracker directories**
   ```bash
   sudo mkdir -p /opt/firecracker/{kernels,images,snapshots}
   sudo mkdir -p /var/lib/firecracker/vms
   ```

3. **Enable IP forwarding**
   ```bash
   echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
   sudo sysctl -p
   ```

4. **Load bridge modules**
   ```bash
   sudo modprobe bridge
   sudo modprobe br_netfilter
   ```

### Node Labeling

Label nodes that support Firecracker:

```bash
kubectl label nodes <node-name> firecracker.io/enabled=true

# Optional: Taint nodes for Firecracker-only workloads
kubectl taint nodes <node-name> firecracker.io/node=true:NoSchedule
```

### Resource Planning

Firecracker VMs consume:
- **Memory**: VM allocation + ~100MB overhead per VM
- **CPU**: Configurable vCPUs + controller overhead
- **Storage**: Kernel (~10MB) + rootfs (~2-8GB) + snapshots per VM

## Monitoring and Observability

### Metrics

The controller exposes additional Firecracker metrics:

- `firecracker_vms_running` - Currently running VMs
- `firecracker_vms_created_total` - Total VMs created
- `firecracker_vms_failed_total` - Failed VM creations
- `firecracker_vm_startup_duration` - VM startup time histogram

### Logging

Enhanced logging for Firecracker operations:

```bash
# View controller logs
kubectl logs -n actions-runner-system deployment/actions-runner-controller-firecracker

# View VM-specific logs
kubectl logs -n actions-runner-system <runner-pod> -c manager
```

### Events

Kubernetes events track VM lifecycle:

```bash
# View runner events
kubectl get events --field-selector involvedObject.kind=Runner

# Common events:
# - VMCreationStarted
# - VMCreationSucceeded/VMCreationFailed
# - VMNetworkConfigured
# - VMDeleted
```

## Troubleshooting

### Common Issues

#### 1. VM Creation Failures

**Symptoms**: Pods stuck in Pending, events show VM creation errors

**Solutions**:
```bash
# Check node KVM support
kubectl exec -it <controller-pod> -- ls -la /dev/kvm

# Verify kernel/rootfs paths
kubectl exec -it <controller-pod> -- ls -la /opt/firecracker/

# Check controller logs
kubectl logs <controller-pod> | grep -i firecracker
```

#### 2. Network Connectivity Issues

**Symptoms**: VMs created but can't reach ARC controller

**Solutions**:
```bash
# Check bridge configuration
kubectl exec -it <controller-pod> -- ip link show

# Verify IP forwarding
kubectl exec -it <controller-pod> -- sysctl net.ipv4.ip_forward

# Test controller reachability
kubectl exec -it <controller-pod> -- curl http://localhost:30080/metrics
```

#### 3. Permission Errors

**Symptoms**: "Permission denied" errors in logs

**Solutions**:
```bash
# Verify security context
kubectl get pod <controller-pod> -o jsonpath='{.spec.securityContext}'

# Check file permissions
kubectl exec -it <controller-pod> -- ls -la /opt/firecracker/
```

### Debug Commands

```bash
# Check VM status
kubectl exec -it <controller-pod> -- ps aux | grep firecracker

# View network configuration
kubectl exec -it <controller-pod> -- ip addr show

# Check disk usage
kubectl exec -it <controller-pod> -- df -h /opt/firecracker/

# Monitor VM creation
kubectl logs -f <controller-pod> | grep -E "(VM|firecracker)"
```

## Migration from Container Runners

The Firecracker integration is fully backward compatible. Existing `RunnerDeployment` resources without `runtime.type` specification continue to use container-based runners.

To migrate gradually:

1. **Deploy Firecracker controller** alongside existing controller
2. **Create new RunnerDeployments** with `runtime.type: firecracker`
3. **Gradually migrate workflows** by updating runner labels
4. **Scale down container runners** once migration is complete

## Performance Considerations

### VM Startup Time
- **Cold start**: 2-5 seconds for VM boot + application initialization
- **Snapshot start**: 500ms-1s for snapshot restore
- **Optimization**: Use snapshots for frequently used configurations

### Resource Efficiency
- **Memory overhead**: ~100MB per VM vs ~50MB per container
- **CPU overhead**: Minimal additional overhead for virtualization
- **Network overhead**: <5% additional latency vs containers

### Scaling Recommendations
- **Maximum VMs per node**: Based on memory availability (typically 10-50 VMs)
- **Resource reservations**: Reserve 20% additional memory for VM overhead
- **Storage planning**: ~2-8GB per concurrent VM for rootfs images

## Security Benefits

1. **Strong isolation**: Complete kernel-level isolation between runners
2. **Attack surface reduction**: VMs provide additional security boundaries
3. **Resource constraints**: Hard limits on VM resources prevent resource exhaustion
4. **Network isolation**: Separate network namespaces per VM
5. **Snapshot consistency**: Reproducible VM states across runs

## Future Enhancements

Planned improvements include:
- **Multi-architecture support** (ARM64, x86_64)
- **Custom VM images** via OCI registry integration
- **Persistent storage** for workflow artifacts
- **GPU passthrough** for ML/AI workloads
- **Advanced networking** with VLAN support 