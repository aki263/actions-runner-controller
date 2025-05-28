# Firecracker VM Scripts for Ubuntu 24.04

**⚠️ IMPORTANT: These scripts are designed to run on Ubuntu 24.04 (or compatible Linux), not macOS. Firecracker requires KVM which is only available on Linux.**

This collection provides scripts to quickly set up and manage Firecracker microVMs with Ubuntu 24.04, SSH access, and expandable rootfs. It includes custom kernel building capabilities for container support.

## 🖥️ System Requirements

- **Operating System**: Ubuntu 24.04 (or compatible Linux distribution)
- **Architecture**: x86_64
- **Virtualization**: KVM support required
- **Memory**: At least 4GB RAM (8GB+ recommended for kernel building)
- **Storage**: 20GB+ free disk space
- **Network**: Internet connection for package downloads

**Note**: macOS is not supported as Firecracker requires KVM, which is Linux-specific.

## 📋 Quick Start

### Prerequisites

```bash
# Install dependencies on Ubuntu 24.04
sudo apt update
sudo apt install -y curl qemu-utils debootstrap openssh-client build-essential

# Install Firecracker
curl -LOJ https://github.com/firecracker-microvm/firecracker/releases/latest/download/firecracker-v*-x86_64.tgz
tar -xzf firecracker-*.tgz
sudo mv release-*/firecracker-* /usr/local/bin/

# Add user to KVM group
sudo usermod -a -G kvm $USER
newgrp kvm
```

### Basic VM Creation

```bash
# Create a basic VM (1GB RAM, 2 CPUs, 10GB disk)
./firecracker-setup.sh

# Create a custom VM (2GB RAM, 4 CPUs, 20GB disk)
./firecracker-setup.sh --memory 2048 --cpus 4 --rootfs-size 20G

# List all VMs
./firecracker-manage.sh list

# SSH into a VM
./firecracker-manage.sh ssh <vm_id>
```

## 🚀 Scripts Overview

### Core Scripts

1. **`firecracker-setup.sh`** - Main VM creation script
   - Creates Ubuntu 24.04 VMs with SSH access
   - Configurable CPU, memory, and disk size
   - TAP networking with internet access
   - Supports custom kernels

2. **`firecracker-manage.sh`** - VM lifecycle management
   - List, start, stop, and resize VMs
   - SSH connection management
   - Cleanup utilities

3. **`build-firecracker-kernel.sh`** - Custom kernel builder
   - Builds kernels with container support
   - Based on official Firecracker configurations
   - Adds Docker/Kubernetes compatibility

4. **`example-usage.sh`** - Demonstration script
   - Shows basic workflow
   - Good starting point for new users

## 🔧 Detailed Usage

### VM Creation Options

```bash
./firecracker-setup.sh [options]

Options:
  --memory, -m <size>         VM memory in MB (default: 1024)
  --cpus, -c <count>          Number of CPUs (default: 2)
  --rootfs-size, -s <size>    Root filesystem size (default: 10G)
  --custom-kernel, -k <path>  Use custom kernel instead of downloading
  --resize-only <size>        Only resize existing rootfs
  --help, -h                  Show help

Examples:
  ./firecracker-setup.sh                     # Default VM
  ./firecracker-setup.sh -m 4096 -c 8        # High-spec VM
  ./firecracker-setup.sh -k ./vmlinux-custom # Custom kernel
```

### VM Management

```bash
./firecracker-manage.sh <command> [arguments]

Commands:
  list                    List all VMs
  status <vm_id>          Show VM status
  stop <vm_id>            Stop a VM
  ssh <vm_id>             SSH into a VM
  resize <vm_id> <size>   Resize VM rootfs
  cleanup                 Clean up all stopped VMs

Examples:
  ./firecracker-manage.sh list
  ./firecracker-manage.sh status a1b2c3d4
  ./firecracker-manage.sh ssh a1b2c3d4
  ./firecracker-manage.sh resize a1b2c3d4 30G
```

### Custom Kernel Building

```bash
./build-firecracker-kernel.sh [options]

Options:
  --kernel-version, -v <version>  Kernel version to build (default: 6.1.128)
  --jobs, -j <count>              Number of parallel jobs (default: nproc)
  --clean                         Clean build directory and exit
  --help, -h                      Show help

Examples:
  ./build-firecracker-kernel.sh                # Build default kernel
  ./build-firecracker-kernel.sh -v 6.1.55      # Build specific version
  ./build-firecracker-kernel.sh -j 8           # Use 8 parallel jobs
```

## 🌐 Networking

The scripts set up TAP networking with the following configuration:

- **Host IP**: 172.20.0.1/24
- **VM IP**: 172.20.0.2/24
- **Internet Access**: NAT through host
- **SSH Access**: Key-based authentication

Each VM gets its own TAP device (`tap-<vm_id>`) for network isolation.

## 🔑 SSH Access

SSH keys are automatically generated and configured:

```bash
# SSH into a VM
ssh -i ./firecracker-vm/vm_key root@172.20.0.2

# Or use the management script
./firecracker-manage.sh ssh <vm_id>
```

## 📦 Container Support

The custom kernel builder enables full container support by including:

- **Namespaces**: UTS, IPC, PID, NET, USER
- **Cgroups**: CPU, Memory, Devices, Freezer, PIDs
- **Networking**: Netfilter, iptables, bridge, veth
- **Filesystems**: Overlay FS for container layers
- **Security**: BPF, seccomp, CAPABILITIES
- **Additional**: All features needed for Docker/Kubernetes

### Using Custom Kernel for Containers

```bash
# Build custom kernel with container support
./build-firecracker-kernel.sh

# Create VM with custom kernel
./firecracker-setup.sh --custom-kernel ./firecracker-vm/vmlinux-custom

# SSH in and install Docker
./firecracker-manage.sh ssh <vm_id>
# Inside VM:
apt update && apt install -y docker.io
systemctl start docker
docker run hello-world
```

## 🛠️ Troubleshooting

### Common Issues

1. **macOS Compatibility**
   ```
   Error: This script is designed to run on Linux/Ubuntu, not macOS
   ```
   **Solution**: Transfer scripts to your Ubuntu machine and run there.

2. **KVM Access Denied**
   ```
   Error: Cannot access /dev/kvm
   ```
   **Solution**: 
   ```bash
   sudo usermod -a -G kvm $USER
   newgrp kvm
   ```

3. **Missing Dependencies**
   ```
   Error: Missing dependencies: firecracker debootstrap
   ```
   **Solution**: Install required packages as shown in prerequisites.

4. **Network Issues**
   ```
   Error: TAP device creation failed
   ```
   **Solution**: Ensure you have sudo access and try cleaning up:
   ```bash
   ./firecracker-manage.sh cleanup
   ```

### Debugging

- Check VM logs: `dmesg` or kernel messages
- Monitor Firecracker process: `ps aux | grep firecracker`
- Check network: `ip link show` and `ip route`
- Verify KVM: `lsmod | grep kvm`

## 📁 File Structure

```
firecracker-poc/
├── firecracker-setup.sh       # Main VM creation script
├── firecracker-manage.sh      # VM management script
├── build-firecracker-kernel.sh # Custom kernel builder
├── example-usage.sh           # Example workflow
├── FIRECRACKER_README.md      # This documentation
├── KERNEL_BUILD_GUIDE.md      # Detailed kernel building guide
├── FIRECRACKER_FIXES.md       # Technical fixes documentation
└── firecracker-vm/            # VM workspace (created automatically)
    ├── vmlinux-*               # Kernel files
    ├── ubuntu-24.04-rootfs.ext4 # VM root filesystem
    ├── vm_key                  # SSH private key
    ├── vm_key.pub              # SSH public key
    ├── vm-config-*.json        # VM configuration files
    ├── firecracker-*.pid       # VM process IDs
    └── firecracker-*.socket    # VM API sockets
```

## 🔗 Related Resources

- [Firecracker Official Documentation](https://github.com/firecracker-microvm/firecracker)
- [Ubuntu 24.04 Documentation](https://ubuntu.com/server/docs)
- [KVM Documentation](https://www.linux-kvm.org/page/Documents)
- [Container Runtime Interface](https://kubernetes.io/docs/concepts/architecture/cri/)

## 🤝 Contributing

This is a proof-of-concept implementation. For production use, consider:

- Adding more robust error handling
- Implementing VM state persistence
- Adding network isolation between VMs
- Implementing resource limits and quotas
- Adding monitoring and logging

## ⚖️ License

These scripts are provided as-is for educational and development purposes. Please review and test thoroughly before any production use.

## 🎯 Platform Compatibility

| Operating System | Support Status | Notes |
|-----------------|----------------|--------|
| Ubuntu 24.04 | ✅ Fully Supported | Primary target platform |
| Ubuntu 22.04 | ✅ Compatible | Should work with minor adjustments |
| Debian 12+ | ⚠️ Mostly Compatible | Package names may differ |
| RHEL/CentOS 9+ | ⚠️ Requires Adaptation | Different package manager |
| macOS | ❌ Not Supported | No KVM support |
| Windows | ❌ Not Supported | Use WSL2 with Ubuntu |

**Recommendation**: Use Ubuntu 24.04 for the best experience and full compatibility. 