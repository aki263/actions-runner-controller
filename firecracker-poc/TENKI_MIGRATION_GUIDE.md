# Tenki Platform: Container to Firecracker VM Migration Guide

This guide helps you migrate your existing container-based runners to Firecracker VMs while preserving all your Tenki platform configurations.

## 🔍 **Current Setup Analysis**

Your existing RunnerDeployment uses:
- **Image**: `us-west1-docker.pkg.dev/tenki-cloud/tenki-apps/actions-runner:ubuntu-22.04`
- **Resources**: 4 CPU, 16Gi memory
- **Node**: Must run on `tenki-staging-runner-2`
- **Tenki Integration**: Complete with annotations and secrets

## 🛠 **Migration Steps**

### Step 1: Convert Container Image to VM Filesystem

You'll need to convert your container image to a Firecracker-compatible filesystem:

```bash
# Option A: Extract from your existing container image
docker pull us-west1-docker.pkg.dev/tenki-cloud/tenki-apps/actions-runner:ubuntu-22.04

# Create container without running it
CONTAINER_ID=$(docker create us-west1-docker.pkg.dev/tenki-cloud/tenki-apps/actions-runner:ubuntu-22.04)

# Export filesystem
docker export $CONTAINER_ID > tenki-runner.tar

# Create ext4 filesystem (on tenki-staging-runner-2)
sudo su -
cd /opt/firecracker/images/
dd if=/dev/zero of=tenki-runner-ubuntu-22.04.ext4 bs=1M count=8192  # 8GB filesystem
mkfs.ext4 tenki-runner-ubuntu-22.04.ext4

# Mount and extract
mkdir -p /mnt/tenki-runner
mount -o loop tenki-runner-ubuntu-22.04.ext4 /mnt/tenki-runner
cd /mnt/tenki-runner
tar -xf /path/to/tenki-runner.tar

# Essential VM setup
echo 'tenki-runner-vm' > etc/hostname
echo '127.0.0.1 localhost tenki-runner-vm' > etc/hosts

# Ensure runner service is enabled
systemctl --root=/mnt/tenki-runner enable actions.runner.aakash-test-workflow.service || true

# Cleanup and unmount
cd /
umount /mnt/tenki-runner
chown $(logname):$(logname) tenki-runner-ubuntu-22.04.ext4

# Cleanup container
docker rm $CONTAINER_ID
```

### Step 2: Prepare Node (tenki-staging-runner-2)

Ensure your target node has Firecracker support:

```bash
# On tenki-staging-runner-2
sudo apt update && sudo apt install -y firecracker

# Setup Firecracker directories
sudo mkdir -p /opt/firecracker/{data,kernels,images,snapshots,instances}
sudo chown -R $(whoami):$(whoami) /opt/firecracker

# Verify KVM access
ls -la /dev/kvm
# Should show: crw-rw---- 1 root kvm ... /dev/kvm

# Add your user to kvm group if needed
sudo usermod -a -G kvm $USER
```

### Step 3: Label the Node (Optional but Recommended)

```bash
kubectl label node tenki-staging-runner-2 tenki/firecracker-ready=true
kubectl label node tenki-staging-runner-2 tenki/runner-type=firecracker
```

### Step 4: Deploy Updated RunnerDeployment

```bash
# Apply the new Firecracker-based RunnerDeployment
kubectl apply -f firecracker-poc/tenki-firecracker-runnerdeployment.yaml

# Monitor the deployment
kubectl get runners -n tenki-68130006 -w
kubectl describe runner -n tenki-68130006 <runner-name>
```

## 🔧 **Alternative Configurations**

### Option A: Use Pre-built Snapshot (Recommended)

If you want faster VM startup, create a snapshot:

```yaml
runtime:
  type: firecracker
  firecracker:
    snapshotName: "tenki-runner-v1"  # Instead of rootfsImagePath
    memoryMiB: 16384
    vcpus: 4
```

### Option B: Host Networking (Simplest)

If you want to avoid networking complexity:

```yaml
runtime:
  type: firecracker
  firecracker:
    networkConfig:
      networkMode: "host"  # VM shares host network
    arcControllerURL: "http://localhost:30080"
```

### Option C: NAT Networking (More Isolated)

For better security isolation:

```yaml
runtime:
  type: firecracker
  firecracker:
    networkConfig:
      networkMode: "nat"
      parentInterface: "eth0"
      subnetCIDR: "10.100.0.0/24"
      gateway: "10.100.0.1"
    arcControllerURL: "http://10.100.0.1:30080"
```

## 🚀 **Deployment Commands**

```bash
# Deploy your Firecracker-enabled ARC controller
kubectl set image deployment/actions-runner-controller-controller-manager \
  manager=us-west1-docker.pkg.dev/tenki-cloud/tenki-runners-prod/arc-aakash-no-run:v2.2 \
  -n actions-runner-system

# Apply Firecracker service
kubectl apply -f controllers/actions.summerwind.net/arc_firecracker_service.yaml

# Deploy your updated RunnerDeployment
kubectl apply -f firecracker-poc/tenki-firecracker-runnerdeployment.yaml

# Verify deployment
kubectl get runnerdeployment tenki-standard-autoscale-213161010 -n tenki-68130006
kubectl get runners -n tenki-68130006
```

## 🔍 **Monitoring & Troubleshooting**

```bash
# Check runner status
kubectl describe runners -n tenki-68130006

# Check VM processes on the node
ssh tenki-staging-runner-2
ps aux | grep firecracker
ip link show | grep -E "(mv-|tap-)"

# Check ARC controller logs
kubectl logs -n actions-runner-system deployment/actions-runner-controller-controller-manager

# Verify VMs are on correct node
kubectl get runners -n tenki-68130006 -o wide
```

## ⚡ **Performance Comparison**

| Aspect | Container (Current) | Firecracker VM (New) |
|---------|-------------------|---------------------|
| **Startup Time** | ~10-30 seconds | ~15-45 seconds |
| **Security** | Container isolation | Hardware-level isolation |
| **Resource Usage** | Lower overhead | Slightly higher overhead |
| **Network** | Shared host network | Dedicated VM network |
| **Persistence** | Ephemeral | Ephemeral (same) |

## 🎯 **Migration Checklist**

- [ ] Convert container image to VM filesystem
- [ ] Setup Firecracker on tenki-staging-runner-2
- [ ] Deploy updated ARC controller image
- [ ] Apply Firecracker service configuration  
- [ ] Update RunnerDeployment with Firecracker runtime
- [ ] Test runner creation and job execution
- [ ] Monitor VM performance and resource usage
- [ ] Update HorizontalRunnerAutoscaler if using auto-scaling

## 🚨 **Important Notes**

1. **Image Conversion**: Your container image needs to be converted to a bootable VM filesystem
2. **Node Resources**: Ensure `tenki-staging-runner-2` has sufficient CPU/memory for VMs
3. **Networking**: Macvlan mode provides best performance but requires network configuration
4. **Compatibility**: All your Tenki annotations, secrets, and integrations are preserved
5. **Scaling**: This works seamlessly with HorizontalRunnerAutoscaler if you're using it

Your Tenki platform integration remains unchanged - only the runtime switches from containers to VMs! 🚀 