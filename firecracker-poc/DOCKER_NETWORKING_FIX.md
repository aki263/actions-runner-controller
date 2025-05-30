# Docker Networking Fix for Firecracker VMs

## **🐛 Issue Description**

The GitHub Actions workflow test failed with Docker networking errors:

```
WARNING: IPv4 forwarding is disabled. Networking will not work.
ERROR: failed to solve: process "/bin/sh -c echo \"Build stage\" > /build.txt" did not complete successfully: network bridge not found
```

## **🔍 Root Cause Analysis**

1. **IPv4 Forwarding Disabled**: Required for Docker container networking
2. **Missing Bridge Netfilter**: Kernel module `br_netfilter` not loaded
3. **Missing Kernel Modules**: Container networking modules not available
4. **Docker Configuration**: Docker daemon wasn't configured for Firecracker environment

## **🛠️ Fixes Applied**

### **1. Kernel Configuration Updates**

Updated `enable-ubuntu-features.patch` with Docker networking modules:

```bash
# Added to kernel config:
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_NETFILTER=y
CONFIG_NF_CONNTRACK=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_VETH=y
CONFIG_MACVLAN=y
CONFIG_IPVLAN=y
# ... and more networking modules
```

### **2. Filesystem Build Enhancements**

Added automatic kernel module loading:

```bash
# /etc/modules-load.d/docker.conf
overlay
br_netfilter
xt_conntrack
nf_nat
nf_conntrack
bridge
veth
```

Added persistent sysctl configuration:

```bash
# /etc/sysctl.d/99-docker.conf  
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
```

### **3. Runtime Setup Script Updates**

Enhanced all runner modes (Systemd, Docker, ARC) with networking fixes:

```bash
# Enable IPv4 forwarding
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
sysctl -p

# Load required kernel modules
modprobe br_netfilter 2>/dev/null || true
modprobe xt_conntrack 2>/dev/null || true
modprobe overlay 2>/dev/null || true

# Restart Docker with updated networking
systemctl restart docker
```

## **🧪 Testing & Validation**

### **Automated Test Script**

Created `test-docker-networking.sh` to validate fixes:

```bash
# Run inside VM to test networking
./test-docker-networking.sh
```

Tests include:
- ✅ Kernel module availability
- ✅ Sysctl networking settings
- ✅ Docker service status
- ✅ Container networking
- ✅ Multi-stage Docker builds
- ✅ Network connectivity

### **Manual Testing Commands**

```bash
# Check IPv4 forwarding
cat /proc/sys/net/ipv4/ip_forward  # Should be 1

# Check required modules
lsmod | grep -E "(bridge|br_netfilter|overlay)"

# Test Docker build (the failing operation)
docker build -t test - <<EOF
FROM alpine:latest as builder
RUN echo "test" > /build.txt
FROM alpine:latest
COPY --from=builder /build.txt /app/
EOF
```

## **📋 What Changed in `firecracker-complete.sh`**

### **Build Filesystem Section**
- Added `/etc/modules-load.d/docker.conf` for automatic module loading
- Added `/etc/sysctl.d/99-docker.conf` for persistent networking settings

### **All Runner Setup Scripts**
- Added IPv4 forwarding enablement
- Added kernel module loading (`br_netfilter`, `xt_conntrack`, `overlay`)
- Added Docker restart after networking configuration
- Added networking validation tests

## **🚀 How to Apply the Fix**

### **For New VMs**

1. **Rebuild kernel** (if using custom kernel):
   ```bash
   ./firecracker-complete.sh build-kernel --rebuild-kernel
   ```

2. **Rebuild filesystem** (to get updated configuration):
   ```bash
   ./firecracker-complete.sh build-fs --rebuild-fs
   ```

3. **Create new snapshot**:
   ```bash
   ./firecracker-complete.sh snapshot fixed-networking
   ```

4. **Launch VM with fix**:
   ```bash
   ./firecracker-complete.sh launch \
     --snapshot fixed-networking \
     --github-url https://github.com/org/repo \
     --github-pat ghp_xxxx
   ```

### **For Existing VMs**

SSH into the VM and apply fixes manually:

```bash
# Enable IPv4 forwarding
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1

# Load kernel modules
sudo modprobe br_netfilter
sudo modprobe xt_conntrack
sudo modprobe overlay

# Restart Docker
sudo systemctl restart docker

# Test the fix
docker run --rm alpine:latest echo "Docker networking test"
```

## **📊 Expected Results**

After applying the fix:

- ✅ **No more IPv4 forwarding warnings**
- ✅ **Docker builds work properly** (including multi-stage builds)
- ✅ **Container networking functions correctly**
- ✅ **GitHub Actions workflows can use Docker** without issues

## **🔍 Troubleshooting**

### **If Docker Build Still Fails**

```bash
# Check kernel modules
lsmod | grep br_netfilter

# Check sysctl settings
sysctl net.ipv4.ip_forward

# Check Docker networks
docker network ls
docker network inspect bridge

# Manual Docker daemon restart
sudo systemctl restart docker
```

### **Log Locations for Debugging**

```bash
# Docker daemon logs
sudo journalctl -u docker -f

# Setup script logs
tail -f /var/log/setup-runner.log

# Kernel messages
dmesg | grep -i "bridge\|netfilter"
```

## **🎯 GitHub Actions Workflow Testing**

The fix should resolve the workflow error. You can test with:

```yaml
- name: Test Docker Build
  run: |
    docker build -t test - <<EOF
    FROM alpine:latest as builder
    RUN echo "Build stage works!" > /build.txt
    
    FROM alpine:latest
    COPY --from=builder /build.txt /app/
    CMD cat /app/build.txt
    EOF
    
    docker run --rm test
```

## **📝 Summary**

The Docker networking issues were caused by missing kernel networking modules and disabled IPv4 forwarding. The fix:

1. **Added networking modules** to kernel configuration
2. **Enabled persistent networking settings** in filesystem
3. **Added runtime networking configuration** to all setup scripts
4. **Created validation tests** to verify the fix

This ensures Docker builds and container networking work correctly in Firecracker VMs, making them suitable for GitHub Actions workflows that require Docker functionality. 