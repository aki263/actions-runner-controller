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
- **Flexible Kernel Config**: Use any kernel config file
- **Rebuild Options**: Force rebuild kernels and filesystems
- **Smart Validation**: Prevents conflicts and validates inputs

## 📋 Commands

```bash
# Build
./firecracker-complete.sh build-kernel [options]  # Build custom kernel
./firecracker-complete.sh build-fs [options]      # Build filesystem  
./firecracker-complete.sh snapshot [name]         # Create snapshot

# Manage
./firecracker-complete.sh launch [options]        # Launch VM
./firecracker-complete.sh list                    # List all resources
./firecracker-complete.sh stop [pattern]          # Stop VMs
./firecracker-complete.sh cleanup                 # Stop all + cleanup
./firecracker-complete.sh version                 # Show version info
```

## ⚙️ Build Options

### Kernel Building
```bash
--config <path>        # Custom kernel config (default: working-kernel-config)
--rebuild-kernel       # Force rebuild even if kernel exists
--rebuild              # Same as --rebuild-kernel
```

### Filesystem Building  
```bash
--rebuild-fs           # Force rebuild even if filesystem exists
--rebuild              # Same as --rebuild-fs
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
--kernel <path>        # Custom kernel path
--no-cloud-init       # Disable cloud-init (testing)
```

## 📝 Usage Examples

### Kernel Building
```bash
# Build with default config
./firecracker-complete.sh build-kernel

# Build with custom config
./firecracker-complete.sh build-kernel --config my-custom.config

# Force rebuild existing kernel
./firecracker-complete.sh build-kernel --rebuild-kernel

# Custom config + rebuild
./firecracker-complete.sh build-kernel --config ./configs/production.config --rebuild
```

### Filesystem & Snapshots
```bash
# Build filesystem (first time)
./firecracker-complete.sh build-fs

# Force rebuild filesystem
./firecracker-complete.sh build-fs --rebuild-fs

# Create named snapshot
./firecracker-complete.sh snapshot production-v2.1

# List all resources
./firecracker-complete.sh list
```

### VM Deployment
```bash
# Launch with GitHub integration
./firecracker-complete.sh launch \
  --snapshot production-v2.1 \
  --name "prod-runner-1" \
  --github-url "https://github.com/myorg/myrepo" \
  --github-token "ghp_your_token_here" \
  --labels "production,firecracker,fast" \
  --memory 4096 \
  --cpus 4

# Quick test VM (no GitHub)
./firecracker-complete.sh launch --no-cloud-init --name test-vm

# Custom kernel VM
./firecracker-complete.sh launch \
  --kernel ./my-custom-vmlinux \
  --snapshot production-v2.1 \
  --github-url "https://github.com/myorg/myrepo" \
  --github-token "ghp_your_token_here"
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

## 🛠️ Advanced Usage

### Workflow Examples
```bash
# Development cycle
./firecracker-complete.sh build-kernel --config dev.config
./firecracker-complete.sh build-fs
./firecracker-complete.sh snapshot dev-latest
./firecracker-complete.sh launch --snapshot dev-latest --no-cloud-init

# Production deployment
./firecracker-complete.sh build-kernel --config production.config
./firecracker-complete.sh build-fs
./firecracker-complete.sh snapshot prod-v$(date +%Y%m%d)
for i in {1..5}; do
  ./firecracker-complete.sh launch \
    --snapshot prod-v$(date +%Y%m%d) \
    --name "runner-$i" \
    --github-url "$GITHUB_URL" \
    --github-token "$GITHUB_TOKEN" \
    --labels "production,cluster-$i" &
done
```

### Resource Management
```bash
# Show detailed status
./firecracker-complete.sh list

# Stop specific runners
./firecracker-complete.sh stop "runner-[1-3]"

# Clean everything
./firecracker-complete.sh cleanup
```

---

**That's it!** One script, comprehensive options, infinite GitHub Actions runners. 🎉 