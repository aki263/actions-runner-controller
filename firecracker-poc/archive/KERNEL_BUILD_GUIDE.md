# Firecracker Kernel Building Guide

This guide explains how to build custom Firecracker kernels with enhanced container support based on the official Firecracker documentation and community best practices.

## Overview

The default Firecracker kernel is optimized for minimal size and fast boot times, but it lacks many features required for running containers. Building a custom kernel enables:

- **Full container support**: Docker, Podman, containerd
- **Complete networking**: iptables, bridge networks, advanced routing
- **Modern features**: BPF, seccomp, advanced cgroups
- **Container orchestration**: Kubernetes, Docker Compose, etc.

## Quick Start

```bash
# Build custom kernel with defaults
./build-firecracker-kernel.sh

# Use custom kernel in VM
./firecracker-setup.sh --custom-kernel ./firecracker-vm/vmlinux-6.1.128-custom

# Interactive menu
./quick-start-custom-kernel.sh
```

## Kernel Features Comparison

| Feature | Default Kernel | Custom Kernel |
|---------|----------------|---------------|
| **Size** | ~8MB | ~12MB |
| **Boot Time** | ~5 seconds | ~5 seconds |
| **Build Time** | None | 15-45 minutes |
| **Namespaces** | Partial | Complete |
| **Cgroups** | Basic | Full |
| **Netfilter/iptables** | Limited | Complete |
| **Container Runtime** | Won't work | Full support |
| **Kubernetes** | No | Yes |
| **Overlay FS** | No | Yes |
| **BPF/eBPF** | No | Yes |

## Build Process Details

### 1. Download Kernel Source

The script downloads the official Linux kernel source from kernel.org:

```bash
# Example for kernel 6.1.128
curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.128.tar.xz" -o linux-6.1.128.tar.xz
tar -xf linux-6.1.128.tar.xz
```

### 2. Base Configuration

Downloads the Firecracker base configuration and applies container-friendly modifications:

```bash
# Base config from Firecracker repository
curl -fsSL "https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-x86_64-6.1.config"
```

### 3. Container Features Added

The build process enables these kernel features:

#### Core Container Support
```bash
CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y  
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_USER_NS=y
```

#### Cgroups Support  
```bash
CONFIG_CGROUPS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_SCHED=y
CONFIG_MEMCG=y
```

#### Networking Features
```bash
CONFIG_NETFILTER=y
CONFIG_NETFILTER_ADVANCED=y
CONFIG_NF_CONNTRACK=y
CONFIG_NETFILTER_XTABLES=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP_NF_NAT=y
CONFIG_BRIDGE=y
CONFIG_VETH=y
```

#### Filesystem Support
```bash
CONFIG_OVERLAY_FS=y
```

#### Security Features
```bash
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
```

### 4. Build Kernel

Compiles the kernel using the configured settings:

```bash
make -j$(nproc) vmlinux
```

## Usage Examples

### Basic Custom Kernel Build

```bash
# Build with defaults (kernel 6.1.128, auto-detect CPU cores)
./build-firecracker-kernel.sh

# Build specific version with custom job count
./build-firecracker-kernel.sh --kernel-version 6.1.55 --jobs 8

# Show all options
./build-firecracker-kernel.sh --help
```

### VM Creation with Custom Kernel

```bash
# Create VM with custom kernel
./firecracker-setup.sh --custom-kernel ./firecracker-vm/vmlinux-6.1.128-custom

# High-spec VM for container workloads
./firecracker-setup.sh \
    --custom-kernel ./firecracker-vm/vmlinux-6.1.128-custom \
    --memory 4096 \
    --cpus 8 \
    --rootfs-size 50G
```

### Testing Container Support

After VM creation, test the container features:

```bash
# SSH into VM
ssh -i ./firecracker-vm/vm_key root@172.20.0.2

# Inside VM: Test namespaces
unshare --mount --uts --ipc --net --pid --fork --mount-proc echo "Namespaces work!"

# Test cgroups
ls /sys/fs/cgroup/

# Test iptables
iptables -V

# Install and test Docker
curl -fsSL https://get.docker.com | sh
systemctl start docker
docker run hello-world
```

## Build Environment Requirements

### System Requirements
- Linux host with KVM support
- At least 4GB RAM (8GB recommended)
- 20GB free disk space
- Multi-core CPU (recommended for parallel builds)

### Dependencies

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install -y build-essential curl flex bison bc libssl-dev libelf-dev
```

**RHEL/CentOS/Fedora:**
```bash
sudo yum groupinstall "Development Tools"
sudo yum install curl flex bison bc openssl-devel elfutils-libelf-devel
```

## Performance Optimization

### Build Performance

```bash
# Use all CPU cores
./build-firecracker-kernel.sh --jobs $(nproc)

# Use specific number of jobs
./build-firecracker-kernel.sh --jobs 8

# Use ccache for repeated builds (if installed)
export CC="ccache gcc"
./build-firecracker-kernel.sh
```

### Runtime Performance

The custom kernel has minimal runtime overhead:
- **Boot time**: Same as default (~5 seconds)
- **Memory overhead**: ~4MB additional RAM usage
- **CPU overhead**: Negligible
- **I/O performance**: Slightly better due to optimized scheduling

## Troubleshooting

### Build Issues

**Missing dependencies:**
```bash
# Error: missing libssl-dev
sudo apt install libssl-dev libelf-dev

# Error: missing build tools
sudo apt install build-essential
```

**Out of memory during build:**
```bash
# Reduce parallel jobs
./build-firecracker-kernel.sh --jobs 2

# Or add swap space
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

**Config download fails:**
```bash
# Manual config download
curl -L -o microvm-kernel-x86_64-6.1.config \
  https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-x86_64-6.1.config
```

### Runtime Issues

**Container features not working:**
```bash
# Check kernel config
ssh -i ./firecracker-vm/vm_key root@172.20.0.2 'cat /proc/config.gz | gunzip | grep -i namespace'

# Check if custom kernel was used
ssh -i ./firecracker-vm/vm_key root@172.20.0.2 'uname -r'
```

**iptables not working:**
```bash
# Check netfilter modules
ssh -i ./firecracker-vm/vm_key root@172.20.0.2 'lsmod | grep netfilter'

# Test basic iptables
ssh -i ./firecracker-vm/vm_key root@172.20.0.2 'iptables -L'
```

## Advanced Configuration

### Custom Kernel Features

To add additional features, modify the `customize_kernel_config()` function in `build-firecracker-kernel.sh`:

```bash
# Example: Add IPv6 support
sed -i 's/^# CONFIG_IPV6.*/CONFIG_IPV6=y/' .config || echo "CONFIG_IPV6=y" >> .config

# Example: Add wireless support
sed -i 's/^# CONFIG_WIRELESS.*/CONFIG_WIRELESS=y/' .config || echo "CONFIG_WIRELESS=y" >> .config
```

### Multiple Kernel Versions

Build different kernel versions for different use cases:

```bash
# Build multiple versions
./build-firecracker-kernel.sh --kernel-version 6.1.55
./build-firecracker-kernel.sh --kernel-version 6.1.128

# Use specific version
./firecracker-setup.sh --custom-kernel ./firecracker-vm/vmlinux-6.1.55-custom
```

### Kernel Size Optimization

To reduce kernel size while keeping container support:

```bash
# Disable debugging symbols
sed -i 's/^CONFIG_DEBUG_INFO.*/# CONFIG_DEBUG_INFO is not set/' .config

# Disable unused drivers
sed -i 's/^CONFIG_SOUND.*/# CONFIG_SOUND is not set/' .config
sed -i 's/^CONFIG_USB.*/# CONFIG_USB is not set/' .config
```

## Container Ecosystem Support

### Docker

Full Docker support with custom kernel:

```bash
# Install Docker in VM
ssh -i ./firecracker-vm/vm_key root@172.20.0.2 << 'EOF'
curl -fsSL https://get.docker.com | sh
systemctl start docker
systemctl enable docker

# Test Docker
docker run --rm hello-world
docker run --rm -it alpine:latest /bin/sh
EOF
```

### Kubernetes

Install lightweight Kubernetes distributions:

```bash
# K3s (recommended for VMs)
ssh -i ./firecracker-vm/vm_key root@172.20.0.2 << 'EOF'
curl -sfL https://get.k3s.io | sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
EOF

# MicroK8s
ssh -i ./firecracker-vm/vm_key root@172.20.0.2 << 'EOF'
snap install microk8s --classic
microk8s status --wait-ready
EOF
```

### Container Runtimes

Test different container runtimes:

```bash
# containerd
ssh -i ./firecracker-vm/vm_key root@172.20.0.2 << 'EOF'
apt install -y containerd
systemctl start containerd
ctr version
EOF

# Podman
ssh -i ./firecracker-vm/vm_key root@172.20.0.2 << 'EOF'
apt install -y podman
podman run --rm hello-world
EOF
```

## File Structure

After building a custom kernel:

```
firecracker-vm/
├── vmlinux-6.1.128-custom      # Built custom kernel
├── vmlinux-custom              # Symlink to latest
├── ubuntu-24.04-rootfs.ext4    # Root filesystem
├── vm_key                      # SSH private key
└── vm_key.pub                  # SSH public key

kernel-build/
├── linux-6.1.128/             # Kernel source tree
├── linux-6.1.128.tar.xz       # Downloaded source
└── microvm-kernel-x86_64-6.1.config  # Base config
```

## Best Practices

### Development Workflow

1. **Start with downloaded kernel** for quick testing
2. **Build custom kernel** for container workloads
3. **Test features incrementally** (namespaces → cgroups → containers)
4. **Use version control** for kernel configs
5. **Document custom modifications** for reproducibility

### Production Considerations

- **Security**: Regular kernel updates for CVE patches
- **Testing**: Validate all required features before deployment
- **Backup**: Keep working kernel versions
- **Monitoring**: Watch for kernel performance metrics
- **Documentation**: Document why specific features were enabled

### Resource Management

- **Build once, use many**: Build kernel on powerful machine, copy to others
- **Parallel builds**: Use multiple CPU cores for faster builds
- **Disk space**: Clean up build artifacts after successful builds
- **Network**: Download sources during off-peak hours

## References

- [Firecracker Kernel Setup Documentation](https://github.com/firecracker-microvm/firecracker/blob/main/docs/rootfs-and-kernel-setup.md)
- [Felipe Cruz's Container Guide](https://www.felipecruz.es/exploring-firecracker-microvms-for-multi-tenant-dagger-ci-cd-pipelines/)
- [Linux Kernel Documentation](https://www.kernel.org/doc/html/latest/)
- [Container Runtime Specification](https://github.com/opencontainers/runtime-spec)
- [Firecracker GitHub Issues](https://github.com/firecracker-microvm/firecracker/issues)

## Contributing

To improve the kernel build process:

1. Test with different kernel versions
2. Add support for new container features
3. Optimize build performance
4. Improve error handling and documentation
5. Submit issues and pull requests

## License

This guide and associated scripts are provided under the MIT License. 