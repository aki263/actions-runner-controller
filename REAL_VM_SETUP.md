# 🔥 Real Firecracker VM Setup

## ✅ **What's Fixed in v2.4**

### 1. **Real VM Creation** 
- ✅ No more simulation - creates actual Firecracker VMs
- ✅ Uses br0 bridge networking as specified
- ✅ Creates TAP devices and attaches to bridge
- ✅ Starts actual firecracker processes

### 2. **Automatic Field Propagation** 
- ✅ Runtime field should now propagate automatically: RunnerDeployment → RunnerReplicaSet → Runner
- ✅ No manual CRD patching needed (we updated the CRDs)

## 🚀 **Deployment Steps**

### Step 1: Update ARC Controller Image
```bash
# Update your ARC deployment to use the new image
kubectl patch deployment arc-gha-rs-controller-actions-runner-controller \
  -n arc-systems \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"manager","image":"us-west1-docker.pkg.dev/tenki-cloud/tenki-runners-prod/arc-aakash-no-run:v2.4"}]}}}}'
```

### Step 2: Enable Firecracker Mode
```bash
# Add environment variable to enable Firecracker
kubectl patch deployment arc-gha-rs-controller-actions-runner-controller \
  -n arc-systems \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"manager","env":[{"name":"ENABLE_FIRECRACKER","value":"true"}]}]}}}}'
```

### Step 3: Install Firecracker on Node
On your node `tenki-staging-runner-2`:
```bash
# Install Firecracker
curl -L -o firecracker https://github.com/firecracker-microvm/firecracker/releases/latest/download/firecracker-v1.4.1-x86_64.tgz
tar -xzf firecracker-v1.4.1-x86_64.tgz
sudo mv release-v1.4.1-x86_64/firecracker-v1.4.1-x86_64 /usr/local/bin/firecracker
sudo chmod +x /usr/local/bin/firecracker

# Create required directories
sudo mkdir -p /opt/firecracker/{kernels,images,snapshots}

# Download kernel (example)
sudo curl -L -o /opt/firecracker/kernels/vmlinux-6.1.128-ubuntu24 \
  https://github.com/firecracker-microvm/firecracker/releases/download/v1.4.1/vmlinux.bin

# Create a simple rootfs (or use your custom one)
sudo curl -L -o /opt/firecracker/images/actions-runner-ubuntu-24.04.ext4 \
  https://example.com/your-rootfs.ext4
```

### Step 4: Test VM Creation
```bash
# Delete existing RunnerDeployment to trigger recreation
kubectl delete runnerdeployment tenki-standard-autoscale-aki-213161010 -n tenki-68130006

# Create new RunnerDeployment with Firecracker runtime
kubectl apply -f - <<EOF
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: tenki-standard-autoscale-aki-213161010
  namespace: tenki-68130006
  annotations:
    tenki/environment: staging
    tenki/installationId: "68130006"
    tenki/offeringId: 0197010e-1aed-7458-be4e-5446634f56ae
    tenki/repositoryId: "213161010"
    tenki/workspaceId: 0197010e-1a98-7ebb-a4b7-134dec5d4800
spec:
  replicas: 1
  template:
    metadata:
      annotations:
        tenki/environment: staging
        tenki/installationId: "68130006"
        tenki/offeringId: 0197010e-1aed-7458-be4e-5446634f56ae
        tenki/repositoryId: "213161010"
        tenki/workspaceId: 0197010e-1a98-7ebb-a4b7-134dec5d4800
      labels:
        tenki: runner
    spec:
      organization: aakash-test-workflow
      labels:
      - tenki-standard-autoscale-aki
      group: Default
      ephemeral: true
      githubAPICredentialsFrom:
        secretRef:
          name: github-app-runner-secret
      runtime:
        type: firecracker
        firecracker:
          memoryMiB: 16384
          vcpus: 4
          kernelImagePath: "/opt/firecracker/kernels/vmlinux-6.1.128-ubuntu24"
          rootfsImagePath: "/opt/firecracker/images/actions-runner-ubuntu-24.04.ext4"
          networkConfig:
            networkMode: "bridge"
            bridgeName: "br0"
            dhcpEnabled: true
          ephemeralMode: true
          arcMode: true
          arcControllerURL: "http://tenki-staging-runner-2:30080"
      nodeSelector:
        kubernetes.io/hostname: tenki-staging-runner-2
      imagePullSecrets:
      - name: tenki-regcred
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                - tenki-staging-runner-2
EOF
```

## 🔍 **Verification**

### Check Controller Logs
```bash
kubectl logs deployment/arc-gha-rs-controller-actions-runner-controller -n arc-systems -c manager --since=5m | grep -i firecracker
```

### Check VM Processes on Node
```bash
# SSH to tenki-staging-runner-2
ssh tenki-staging-runner-2

# Check for firecracker processes
ps aux | grep firecracker

# Check TAP devices
ip link show | grep tap-

# Check bridge configuration
ip link show br0
bridge link show br0
```

### Check VM Files
```bash
# Check VM instance directories
ls -la /tmp/firecracker/instances/

# Check VM info files
find /tmp/firecracker/instances/ -name "info.json" -exec cat {} \;
```

## 🐛 **Troubleshooting**

### If VMs Don't Start:
1. **Check firecracker binary**: `which firecracker && firecracker --version`
2. **Check kernel/rootfs files exist**: `ls -la /opt/firecracker/kernels/ /opt/firecracker/images/`
3. **Check bridge exists**: `ip link show br0`
4. **Check permissions**: TAP device creation requires root or CAP_NET_ADMIN

### If Runtime Field Not Propagating:
1. **Verify CRDs**: `kubectl get crd runners.actions.summerwind.dev -o yaml | grep -A 10 runtime`
2. **Check controller version**: Ensure using v2.4 image
3. **Check logs**: Look for "Firecracker VM Manager initialized"

## 🎯 **Expected Results**

After deployment, you should see:
- ✅ Real firecracker processes running on the node
- ✅ TAP devices created and attached to br0
- ✅ VM instances in `/tmp/firecracker/instances/`
- ✅ VMs getting IP addresses via DHCP from br0 network
- ✅ Controller logs showing "Firecracker VM created successfully"
- ✅ No more "simulated" messages in logs

## 📊 **Scaling Test**

Scale to 2 replicas:
```bash
kubectl patch runnerdeployment tenki-standard-autoscale-aki-213161010 -n tenki-68130006 --type='merge' -p '{"spec":{"replicas":2}}'

# Verify 2 firecracker processes
ps aux | grep firecracker | grep -v grep | wc -l
```

This should create 2 real Firecracker VMs with br0 networking! 🔥 