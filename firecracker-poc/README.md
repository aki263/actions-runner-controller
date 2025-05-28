# Firecracker Proof of Concept

This directory contains scripts and documentation for quickly building and running Firecracker VMs with Ubuntu 24.04, SSH access, and custom kernel support for containers.

## 🚀 Quick Start

### Option 1: Interactive Menu
```bash
./quick-start-custom-kernel.sh
```

### Option 2: Direct Commands

**Basic VM (downloaded kernel):**
```bash
./firecracker-setup.sh
```

**VM with custom kernel (full container support):**
```bash
# Build custom kernel (15-45 minutes)
./build-firecracker-kernel.sh

# Create VM with custom kernel
./firecracker-setup.sh --custom-kernel ./firecracker-vm/vmlinux-6.1.128-custom
```

**Complete example workflow:**
```bash
./example-kernel-build.sh
```

## 📁 Files Overview

### 🔧 Main Scripts
- **`firecracker-setup.sh`** - Main VM creation script
- **`firecracker-manage.sh`** - VM management (list, stop, cleanup, etc.)
- **`build-firecracker-kernel.sh`** - Custom kernel builder with container support

### 🎯 Quick Start Scripts
- **`quick-start-custom-kernel.sh`** - Interactive menu system
- **`example-kernel-build.sh`** - Complete workflow demonstration
- **`example-usage.sh`** - Basic usage examples

### 📚 Documentation
- **`FIRECRACKER_README.md`** - Comprehensive documentation
- **`KERNEL_BUILD_GUIDE.md`** - Detailed kernel building guide
- **`FIRECRACKER_FIXES.md`** - Bug fixes and API configuration details

### 🧪 Testing
- **`test-api-config.sh`** - API configuration format testing

## ✨ Key Features

- **🚀 Fast Setup**: One command to create and start VMs
- **🔑 SSH Access**: Automatic SSH key generation and configuration
- **🌐 Networking**: TAP device setup with internet access
- **📦 Ubuntu 24.04**: Latest Ubuntu LTS with essential packages
- **💾 Expandable Storage**: Easy rootfs resizing
- **🐳 Container Support**: Custom kernels with Docker/Kubernetes support
- **🛠️ Management Tools**: Complete VM lifecycle management

## 🔄 Usage Patterns

### Development Workflow
1. **Quick testing**: Use downloaded kernel for basic workloads
2. **Container development**: Build custom kernel for Docker/K8s
3. **Multiple VMs**: Create several VMs with different configurations
4. **Easy cleanup**: Stop and remove VMs when done

### Example Commands
```bash
# Create basic VM
./firecracker-setup.sh --memory 2048 --cpus 4

# Create high-spec VM with custom kernel
./firecracker-setup.sh \
    --custom-kernel ./firecracker-vm/vmlinux-6.1.128-custom \
    --memory 8192 --cpus 8 --rootfs-size 50G

# List all VMs
./firecracker-manage.sh list

# SSH into VM
ssh -i ./firecracker-vm/vm_key root@172.20.0.2

# Stop specific VM
./firecracker-manage.sh stop <vm_id>

# Clean up everything
./firecracker-manage.sh cleanup
```

## 📖 Documentation

- **[FIRECRACKER_README.md](FIRECRACKER_README.md)** - Complete setup guide, usage examples, and troubleshooting
- **[KERNEL_BUILD_GUIDE.md](KERNEL_BUILD_GUIDE.md)** - Detailed kernel building documentation
- **[FIRECRACKER_FIXES.md](FIRECRACKER_FIXES.md)** - Technical fixes and API configuration details

## 🛠️ Requirements

- Linux host with KVM support
- Root/sudo access for networking
- 2GB+ free disk space
- For kernel building: build tools, 4GB+ RAM, 20GB+ disk space

## 🎯 Use Cases

- **Container Development**: Full Docker/Kubernetes support with custom kernels
- **Microservice Testing**: Isolated environments for testing
- **CI/CD Pipelines**: Ephemeral build environments
- **Learning**: Experiment with Firecracker and containerization
- **Development**: Safe, isolated development environments

## 📚 References

- [Firecracker Documentation](https://github.com/firecracker-microvm/firecracker/tree/main/docs)
- [Felipe Cruz's Blog Post](https://www.felipecruz.es/exploring-firecracker-microvms-for-multi-tenant-dagger-ci-cd-pipelines/)
- [Firecracker Getting Started](https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md)

---

**Need help?** Start with `./quick-start-custom-kernel.sh` for an interactive guide! 