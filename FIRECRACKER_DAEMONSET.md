# Firecracker DaemonSet Implementation

## Overview

This implementation provides a host-based Firecracker VM management system for Actions Runner Controller (ARC) using Kubernetes DaemonSets. Instead of managing VMs through pods, this approach runs a privileged daemon on each node that can directly manage Firecracker VMs using the host's KVM capabilities and bridge networking.

## Architecture

### Components

1. **DaemonSet**: Runs on each target node with privileged access
2. **Python VM Daemon**: HTTP API server that manages VM lifecycle  
3. **Firecracker Scripts**: Shell scripts for VM operations
4. **Host VM Manager**: Go controller that communicates with the daemon
5. **Bridge Networking**: Uses host `br0` bridge for better performance

### Key Benefits

- **Better Performance**: Direct host access to KVM and networking
- **Bridge Networking**: VMs get direct access to host bridge interface
- **Resource Efficiency**: No pod overhead for VM management
- **Scalability**: One daemon per node can manage multiple VMs

## Prerequisites

### Host Requirements

1. **KVM Support**: Node must have KVM enabled
   ```bash
   # Check KVM availability
   ls /dev/kvm
   cat /proc/cpuinfo | grep vmx  # Intel
   cat /proc/cpuinfo | grep svm  # AMD
   ```

2. **Bridge Interface**: Host should have a bridge interface `br0`
   ```bash
   # Create bridge interface (example)
   ip link add name br0 type bridge
   ip link set br0 up
   # Add physical interface to bridge if needed
   ip link set eth0 master br0
   ```

3. **TUN/TAP Support**: Required for VM networking
   ```bash
   ls /dev/net/tun
   ```

### Kubernetes Requirements

1. **Privileged Pod Security**: DaemonSet needs privileged access
2. **Host Network Access**: For bridge networking
3. **Node Labeling**: Nodes must be labeled for DaemonSet scheduling

## Deployment

### 1. Quick Deployment

```bash
# Deploy all components
./deploy-firecracker-daemon.sh

# Label nodes for Firecracker support
kubectl label node <NODE_NAME> arc.actions/firecracker-capable=true
```

### 2. Manual Deployment

```bash
# Create namespace
kubectl create namespace arc-systems

# Deploy ConfigMap with scripts
kubectl apply -f firecracker-scripts-configmap.yaml

# Deploy DaemonSet
kubectl apply -f firecracker-vm-daemonset.yaml

# Label target nodes
kubectl label node <NODE_NAME> arc.actions/firecracker-capable=true
```

### 3. Verify Deployment

```bash
# Check DaemonSet status
kubectl get daemonset firecracker-vm-daemon -n arc-systems

# Check pod logs
kubectl logs -n arc-systems -l app=firecracker-vm-daemon

# Test API endpoint
curl http://<NODE_IP>:30090/health
```

## Configuration

### Environment Variables

The DaemonSet supports several environment variables:

- `DAEMON_PORT`: API server port (default: 8090)
- `FIRECRACKER_WORK_DIR`: Working directory (default: /opt/firecracker)
- `FIRECRACKER_SCRIPT`: Script path (default: /app/firecracker-complete.sh)

### ARC Controller Configuration

Enable Firecracker support in your ARC controller:

```bash
# Environment variables for ARC controller
export ENABLE_FIRECRACKER=true
export FIRECRACKER_DAEMON_URL=http://<NODE_IP>:30090
```

### Runner Configuration

Configure runners to use Firecracker runtime:

```yaml
apiVersion: actions.summerwind.net/v1alpha1
kind: Runner
metadata:
  name: firecracker-runner
spec:
  repository: your-org/your-repo
  runtime:
    type: firecracker
    firecracker:
      memoryMiB: 8192
      vcpus: 4
      ephemeralMode: true
      arcMode: true
```

## API Endpoints

The VM daemon exposes a REST API:

- `GET /health` - Health check
- `GET /vms` - List all VMs
- `POST /vms` - Create a new VM
- `GET /vms/{vm_id}` - Get VM status
- `DELETE /vms/{vm_id}` - Delete VM

### Example API Usage

```bash
# Health check
curl http://node-ip:30090/health

# List VMs
curl http://node-ip:30090/vms

# Create VM
curl -X POST http://node-ip:30090/vms \
  -H "Content-Type: application/json" \
  -d '{
    "vm_id": "test-vm",
    "github_url": "https://github.com/user/repo",
    "github_token": "ghp_xxx",
    "memory_mb": 4096,
    "vcpus": 2,
    "ephemeral": true
  }'

# Delete VM
curl -X DELETE http://node-ip:30090/vms/test-vm
```

## Networking

### Bridge Networking (Default)

VMs connect to host bridge `br0`:
- VMs get DHCP-assigned IPs from host network
- Direct connectivity to host network
- Better performance than NAT

### Network Setup

Ensure bridge interface exists on host:

```bash
# Check existing bridges
ip link show type bridge

# Create bridge if needed
ip link add name br0 type bridge
ip link set br0 up

# Add physical interface to bridge (optional)
ip link set eth0 master br0
```

## Troubleshooting

### Common Issues

1. **DaemonSet pods not starting**
   ```bash
   # Check node labels
   kubectl get nodes --show-labels | grep firecracker-capable
   
   # Check pod events
   kubectl describe pod -n arc-systems -l app=firecracker-vm-daemon
   ```

2. **VM creation fails**
   ```bash
   # Check daemon logs
   kubectl logs -n arc-systems -l app=firecracker-vm-daemon
   
   # Check KVM access
   kubectl exec -n arc-systems <POD_NAME> -- ls -la /dev/kvm
   ```

3. **Network connectivity issues**
   ```bash
   # Check bridge interface
   kubectl exec -n arc-systems <POD_NAME> -- ip link show br0
   
   # Check TAP interfaces
   kubectl exec -n arc-systems <POD_NAME> -- ip link show type tun
   ```

### Debug Commands

```bash
# Access daemon pod
kubectl exec -it -n arc-systems <POD_NAME> -- bash

# Check firecracker installation
kubectl exec -n arc-systems <POD_NAME> -- firecracker --version

# Test script execution
kubectl exec -n arc-systems <POD_NAME> -- /app/firecracker-complete.sh list

# Check working directory
kubectl exec -n arc-systems <POD_NAME> -- ls -la /opt/firecracker/
```

## Security Considerations

1. **Privileged Access**: DaemonSet runs with privileged access
2. **Host Network**: Direct access to host networking
3. **KVM Access**: Direct access to hardware virtualization
4. **Node Selection**: Use node labels to restrict deployment

## Monitoring

### Health Checks

The daemon provides health endpoints:

```bash
# Basic health check
curl http://node-ip:30090/health

# VM status monitoring
curl http://node-ip:30090/vms
```

### Logs

Monitor daemon logs:

```bash
# Follow logs
kubectl logs -f -n arc-systems -l app=firecracker-vm-daemon

# Search for errors
kubectl logs -n arc-systems -l app=firecracker-vm-daemon | grep ERROR
```

## Limitations

1. **Node-specific**: VMs are tied to specific nodes
2. **Bridge dependency**: Requires host bridge interface
3. **Privileged access**: Security implications
4. **KVM requirement**: Host must support hardware virtualization

## Migration from Pod-based VMs

To migrate from the existing pod-based VM implementation:

1. Deploy the DaemonSet on target nodes
2. Update ARC controller configuration
3. Test with new runners
4. Gradually migrate existing runners
5. Remove old VM management components

## Contributing

When contributing to this implementation:

1. Test on different node configurations
2. Verify bridge networking setup
3. Check resource cleanup
4. Update documentation
5. Add appropriate logging 