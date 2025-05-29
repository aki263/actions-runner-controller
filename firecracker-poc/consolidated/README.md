# Firecracker GitHub Actions Runner

**One script to build, snapshot, and deploy GitHub Actions runners on Firecracker VMs.**

## Quick Start

```bash
# Make executable
chmod +x firecracker-runner.sh

# Interactive demo (walks you through everything)
./firecracker-runner.sh demo

# Or manual workflow:
./firecracker-runner.sh build                    # Build runner image (~15 min)
./firecracker-runner.sh snapshot                 # Create snapshot
./firecracker-runner.sh launch \                 # Launch runner VM
    --github-url https://github.com/your-org/repo \
    --github-token ghp_your_token_here
```

## Requirements

- **Ubuntu 24.04** (or compatible Linux with KVM)
- **Root/sudo access**
- **GitHub Personal Access Token** with `repo` permissions

## Commands

| Command | Description |
|---------|-------------|
| `build` | Build runner image with GitHub Actions runner + Docker |
| `snapshot [name]` | Create reusable snapshot from image |
| `launch [options]` | Launch runner VM from snapshot |
| `list` | Show all images, snapshots, and running VMs |
| `stop [pattern]` | Stop running VMs (optional regex pattern) |
| `cleanup` | Stop all VMs and clean up |
| `demo` | Interactive walkthrough |

## Launch Options

```bash
./firecracker-runner.sh launch \
    --github-url <repo-or-org-url> \
    --github-token <token> \
    --name <runner-name> \
    --labels <comma-separated> \
    --memory <MB> \
    --cpus <count> \
    --snapshot <snapshot-name>
```

## File Structure

```
firecracker-data/
├── images/                          # Built VM images
├── snapshots/                       # VM snapshots for fast deployment
│   ├── registry.json               # Snapshot registry
│   └── <snapshot-name>/
│       ├── rootfs.ext4             # VM filesystem
│       ├── info.json               # Metadata
│       └── launch.sh               # Quick launcher
└── instances/                      # Running VM instances
    └── <vm-id>/
        ├── rootfs.ext4             # Instance filesystem
        ├── ssh_key                 # SSH private key
        ├── firecracker.pid         # Process ID
        └── info.json               # Instance metadata
```

## GitHub Token Setup

1. Go to GitHub Settings → Developer settings → Personal access tokens
2. Create token with `repo` scope (and `admin:org` for organization runners)
3. Copy the token (starts with `ghp_`)

## Examples

```bash
# Build and launch in one demo
./firecracker-runner.sh demo

# Production workflow
./firecracker-runner.sh build
./firecracker-runner.sh snapshot prod-v1
./firecracker-runner.sh launch \
    --snapshot prod-v1 \
    --github-url https://github.com/myorg \
    --github-token $GITHUB_TOKEN \
    --name prod-runner-1 \
    --labels production,firecracker \
    --memory 4096 --cpus 4

# Multiple runners
for i in {1..3}; do
    ./firecracker-runner.sh launch \
        --github-url https://github.com/myorg/repo \
        --github-token $GITHUB_TOKEN \
        --name batch-runner-$i &
done

# Management
./firecracker-runner.sh list          # Show all resources
./firecracker-runner.sh stop runner-  # Stop specific runners
./firecracker-runner.sh cleanup       # Stop everything
```

## Features

- ✅ **Fast deployment**: Boot VMs from snapshots in ~30 seconds
- ✅ **GitHub Actions runner**: Pre-installed with Docker support
- ✅ **Cloud-init**: Dynamic configuration (hostname, SSH keys, environment)
- ✅ **Isolation**: Each runner in separate Firecracker microVM
- ✅ **Networking**: Full internet access via TAP/NAT
- ✅ **Management**: List, stop, and clean up VMs easily

## Troubleshooting

- **OS Check**: Script only runs on Linux (requires KVM)
- **Dependencies**: Install with `sudo apt install curl qemu-utils debootstrap jq openssh-client genisoimage`
- **Firecracker**: Download from [releases page](https://github.com/firecracker-microvm/firecracker/releases)
- **KVM Access**: Run `sudo usermod -a -G kvm $USER && newgrp kvm`
- **Build hanging**: Check internet connection, try different Ubuntu mirror
- **VM not starting**: Check `/dev/kvm` permissions, verify networking

## Performance

- **Build time**: ~15-30 minutes (one-time)
- **Snapshot time**: ~30 seconds
- **Boot time**: ~30 seconds from snapshot
- **VM resources**: 2GB RAM, 2 CPU (configurable)
- **Disk usage**: ~3-5GB per image/snapshot

---

**This replaces all the separate scripts with one unified tool.** 🚀 