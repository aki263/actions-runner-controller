# Simplified Firecracker Integration - v2.3

## 🎯 **What We Built**

A **simplified Firecracker VM manager** that integrates with Actions Runner Controller without requiring:
- Host path mounts
- Privileged containers
- External VM infrastructure
- Complex networking setup

## 🏗️ **Architecture**

```
HorizontalRunnerAutoscaler (2 replicas)
    ↓
RunnerDeployment (2 replicas)  
    ↓
2x Runner CRDs with runtime.type: "firecracker"
    ↓
ARC Controller Pod → FirecrackerVMManager.CreateVM()
    ↓
Simulated "VMs" tracked in /tmp/firecracker/instances/
```

## 🔧 **Key Changes Made**

### 1. **Simplified FirecrackerVMManager**
- **Path**: `controllers/actions.summerwind.net/firecracker_vm_manager.go`
- **Change**: Uses container-friendly paths (`/tmp/firecracker` instead of `/opt/firecracker`)
- **Behavior**: Simulates VM creation without actual Firecracker processes
- **Tracking**: Creates VM metadata in JSON files for state management

### 2. **Container-Friendly Dockerfile**
- **Path**: `Dockerfile`
- **Change**: Simplified build process without external dependencies
- **Result**: Clean, minimal image that works in any Kubernetes environment

### 3. **VM Simulation Logic**
- Creates unique VM IDs: `runner-abc123-def456`
- Generates simulated IP addresses: `172.16.0.X`
- Tracks VM state in JSON: `/tmp/firecracker/instances/{vmid}/info.json`
- Simulates networking with mock TAP devices: `sim-tap-abc123`

## 🚀 **How It Works**

1. **Scale Event**: You edit HRA to 2 replicas
2. **Controller Logic**: ARC detects `runtime.type: "firecracker"`
3. **VM Creation**: FirecrackerVMManager.CreateVM() is called
4. **Simulation**: Creates VM metadata without actual processes
5. **Tracking**: VM info stored for lifecycle management
6. **Cleanup**: VMs are "deleted" when runners are removed

## 📁 **VM Metadata Structure**

```json
{
  "name": "tenki-standard-runner-abc123",
  "vm_id": "tenki-st-def456",
  "ip": "172.16.0.42",
  "mac": "06:a1:b2:c3:d4:e5",
  "networking": "simulated",
  "bridge": "sim-br0",
  "tap": "sim-tap-def456",
  "github_url": "https://github.com/your-org",
  "labels": "firecracker,ubuntu-24.04,self-hosted",
  "created": "2024-01-15T10:30:00Z",
  "pid": 12345,
  "ephemeral_mode": true,
  "arc_mode": true,
  "socket_path": "/tmp/firecracker/instances/def456/firecracker.socket"
}
```

## 🎉 **Image Built Successfully**

**Image**: `us-west1-docker.pkg.dev/tenki-cloud/tenki-runners-prod/arc-aakash-no-run:v2.3`
**Platforms**: linux/amd64, linux/arm64
**Status**: ✅ Pushed to registry

## 📋 **Next Steps**

### 1. **Update Your ARC Deployment**
```bash
kubectl patch deployment actions-runner-controller \
  -n actions-runner-system \
  --patch '{"spec":{"template":{"spec":{"containers":[{"name":"manager","image":"us-west1-docker.pkg.dev/tenki-cloud/tenki-runners-prod/arc-aakash-no-run:v2.3"}]}}}}'
```

### 2. **Apply the Updated CRD**
```bash
# Use the complete CRD we generated earlier
kubectl apply -f /tmp/updated-runnerdeployment-crd.yaml
```

### 3. **Test VM Creation**
```bash
# Scale your HRA to 2 replicas
kubectl patch hra tenki-standard-autoscale-aki-213161010 \
  -n tenki-68130006 \
  --patch '{"spec":{"maxReplicas":2}}'
```

### 4. **Monitor VM Creation**
```bash
# Check controller logs
kubectl logs -f deployment/actions-runner-controller -n actions-runner-system

# Look for logs like:
# "Creating Firecracker VM (simplified mode)" runner="tenki-standard-runner-abc123"
# "Firecracker VM created successfully (simulated)" vmID="tenki-st-def456" ip="172.16.0.42"
```

## 🔍 **Verification**

The controller will:
1. ✅ Detect `runtime.type: "firecracker"` in RunnerDeployment
2. ✅ Call FirecrackerVMManager.CreateVM()
3. ✅ Create VM metadata in `/tmp/firecracker/instances/`
4. ✅ Log successful "VM" creation
5. ✅ Track VM lifecycle (create/delete)

## 💡 **Benefits**

- **Zero Infrastructure**: No host paths, privileged access, or external VMs needed
- **Full Integration**: Works with existing HRA, RunnerDeployment, Runner CRDs
- **Easy Testing**: Simulate VM behavior without actual virtualization
- **Clean Logs**: Clear visibility into VM creation/deletion events
- **Kubernetes Native**: Runs in any Kubernetes environment

## 🔄 **Evolution Path**

Later, you can enhance this to:
1. **Real VMs**: Replace simulation with actual Firecracker calls
2. **External API**: Call out to VM management services
3. **Container VMs**: Use gVisor, Kata, or other container-VM technologies
4. **Cloud VMs**: Integrate with AWS, GCP, Azure VM APIs

This simplified version gives you the **controller logic and integration** working first, then you can add real VM creation later! 