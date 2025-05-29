# Firecracker GitHub Actions Runner

Build, snapshot, and deploy GitHub Actions runners on Firecracker VMs with one script.

## 🚀 Quick Start (Consolidated Version)

**Use the all-in-one script for the simplest experience:**

```bash
cd consolidated/
chmod +x firecracker-runner.sh

# Interactive demo (recommended for first time)
./firecracker-runner.sh demo

# Or manual workflow
./firecracker-runner.sh build
./firecracker-runner.sh snapshot
./firecracker-runner.sh launch --github-url <url> --github-token <token>
```

See [`consolidated/README.md`](consolidated/README.md) for full documentation.

## File Organization

```
firecracker-poc/
├── consolidated/                   # ⭐ NEW: All-in-one solution
│   ├── firecracker-runner.sh      # Single script for everything
│   └── README.md                   # Complete documentation
├── firecracker-setup.sh           # Original VM setup script
├── firecracker-manage.sh          # VM management utilities
├── build-firecracker-kernel.sh    # Custom kernel building
├── debug-networking.sh            # Network troubleshooting
├── FIRECRACKER_README.md          # Original documentation
└── archive/                       # Old multi-script approach
    ├── build-runner-image.sh
    ├── snapshot-runner-image.sh
    ├── launch-runner-vm.sh
    └── ...
```

## Options

### 1. Consolidated (Recommended)
- **Single script** for everything
- **Simplified workflow**
- **Better error handling**
- **Cleaner file organization**

### 2. Original Scripts
- Multiple specialized scripts
- More granular control
- Original complex workflow
- Files moved to `archive/`

### 3. Basic Firecracker
- Use `firecracker-setup.sh` for basic VMs
- No GitHub Actions runner integration
- Manual configuration required

## Requirements

- **Ubuntu 24.04** (Linux with KVM support)
- **Root/sudo access** 
- **GitHub Personal Access Token**

## Features

- ✅ **Fast deployment**: Boot from snapshots in ~30 seconds
- ✅ **GitHub Actions runner**: Pre-installed with Docker
- ✅ **Isolation**: Firecracker microVMs for security
- ✅ **Cloud-init**: Dynamic configuration
- ✅ **Networking**: Full internet access
- ✅ **Management**: Easy start/stop/cleanup

---

**Start with the consolidated version for the best experience!** 🎯 