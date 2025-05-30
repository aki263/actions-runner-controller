# Firecracker Complete - GitHub Actions Runner

**One script to rule them all** - Build kernel, filesystem, VMs, and manage everything.

## 🚀 Quick Start

```bash
# 1. Build custom kernel with Ubuntu 24.04 support
./firecracker-complete.sh build-kernel

# 2. Build filesystem with GitHub Actions runner
./firecracker-complete.sh build-fs  

# 3. Create snapshot
./firecracker-complete.sh snapshot prod-v1

# 4. Launch runner VM
./firecracker-complete.sh launch \
  --snapshot prod-v1 \
  --github-url https://github.com/your-org/your-repo \
  --github-token ghp_your_token_here
```

## 📁 Clean Structure

```
firecracker-poc/
├── firecracker-complete.sh      # 🎯 Main script (everything!)
├── working-kernel-config        # 🐧 Kernel configuration
├── enable-ubuntu-features.patch # 🔧 Ubuntu 24.04 patches
├── ubuntu-24-packages.md        # 📦 Package reference
└── firecracker-data/           # 📂 Working directory
    ├── kernels/                 # Built kernels
    ├── images/                  # Filesystem images
    ├── snapshots/               # VM snapshots
    └── instances/               # Running VMs
```

## 💡 What It Does

1. **Build Kernel**: Custom kernel with Ubuntu 24.04 package support (USB, Graphics, Sound, etc.)
2. **Build Filesystem**: Ubuntu 24.04 + Docker CE + GitHub Actions runner + development tools
3. **Manage VMs**: Launch with cloud-init networking, SSH access, automatic runner registration
4. **Networking**: Shared bridge (172.16.0.1/24) with unique VM IPs, NAT for internet access

## 🔧 Features

- **Single TAP/Bridge**: All VMs share `firecracker-br0` bridge  
- **Cloud-Init Networking**: No conflicts - networking via systemd-networkd
- **Docker CE**: Official Docker from docker.com (not ubuntu docker.io)
- **Auto SSH**: Generated keys, immediate SSH access
- **Package Support**: 300+ development packages (browsers, databases, languages)

## 📋 Commands

```bash
# Build
./firecracker-complete.sh build-kernel    # Build custom kernel
./firecracker-complete.sh build-fs        # Build filesystem  
./firecracker-complete.sh snapshot [name] # Create snapshot

# Manage
./firecracker-complete.sh launch [options] # Launch VM
./firecracker-complete.sh list            # List all resources
./firecracker-complete.sh stop [pattern]  # Stop VMs
./firecracker-complete.sh cleanup         # Stop all + cleanup
```

## 🎛️ Launch Options

```bash
--snapshot <name>      # Use specific snapshot
--github-url <url>     # GitHub repo/org URL  
--github-token <token> # GitHub token
--name <name>          # VM name
--labels <labels>      # Runner labels
--memory <mb>          # VM memory (default: 2048)
--cpus <count>         # VM CPUs (default: 2)
--kernel <path>        # Custom kernel
--no-cloud-init       # Disable cloud-init (testing)
```

## 🔗 Requirements

- **Ubuntu 24.04** or compatible Linux
- **KVM support** (`/dev/kvm` access)
- **Firecracker** installed
- **Dependencies**: `build-essential curl wget git bc flex bison libssl-dev libelf-dev qemu-utils debootstrap jq openssh-client genisoimage`

## 📊 Size Reference

- **Kernel**: ~15MB (custom with Ubuntu support)
- **Filesystem**: ~8GB (Ubuntu + Docker + runner + dev tools)
- **Snapshot**: ~8GB (copy of filesystem)
- **VM Memory**: 2GB default (configurable)

---

**That's it!** One script, four commands, infinite GitHub Actions runners. 🎉 