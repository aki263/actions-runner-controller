# Firecracker GitHub Actions Runner

## Overview

A streamlined, all-in-one solution for running GitHub Actions runners on Firecracker VMs. This provides fast, isolated, and secure CI/CD execution with minimal overhead.

## Features

- **Single Script**: One command for build, snapshot, launch, and manage
- **Shared Bridge Networking**: All VMs connect to a single bridge with static IPs
- **No Cloud-Init Network Conflicts**: Network configuration handled via systemd-networkd
- **Fast Snapshots**: Pre-built images with instant VM deployment
- **Docker Support**: Full Docker CE with safe kernel module handling
- **SSH Access**: Automatic SSH key generation and configuration

## Quick Start

```bash
# 1. Build runner image (Ubuntu 24.04 + Docker + GitHub Actions runner)
./firecracker-runner.sh build

# 2. Create snapshot
./firecracker-runner.sh snapshot production

# 3. Launch runner VM
./firecracker-runner.sh launch \
  --github-url https://github.com/your-org/your-repo \
  --github-token ghp_your_token_here \
  --labels "firecracker,fast"

# 4. Check status
./firecracker-runner.sh list

# 5. SSH into VM (optional)
ssh -i firecracker-data/instances/*/ssh_key runner@<vm-ip>
```

## Networking Architecture

### Shared Bridge Design
- **Bridge**: `firecracker-br0` with gateway `172.16.0.1/24`
- **TAP Device**: `firecracker-tap0` (shared by all VMs)
- **VM IPs**: Static assignment `172.16.0.10-254`
- **DNS**: Google DNS (8.8.8.8, 8.8.4.4)
- **NAT**: Automatic forwarding to host interface

### Benefits
- **No Per-VM TAP devices**: Single shared infrastructure
- **No DHCP complexity**: Static IP assignment with collision avoidance
- **No Cloud-Init networking**: Eliminates boot-time network conflicts
- **Consistent connectivity**: Reliable VM-to-host and VM-to-internet access

## Commands

### Core Operations
```bash
# Build base image with GitHub Actions runner + Docker
./firecracker-runner.sh build

# Create snapshot for fast deployment
./firecracker-runner.sh snapshot [name]

# Launch VM from snapshot
./firecracker-runner.sh launch [options]

# List all resources (images, snapshots, running VMs)
./firecracker-runner.sh list

# Stop specific instances (supports regex patterns)
./firecracker-runner.sh stop [pattern]

# Clean up everything (stop VMs, remove networking)
./firecracker-runner.sh cleanup
```

### Launch Options
```bash
--snapshot <name>         Use specific snapshot (default: latest)
--name <name>             VM name (default: runner-HHMMSS)
--github-url <url>        GitHub repository or organization URL
--github-token <token>    GitHub personal access token
--labels <labels>         Runner labels (default: "firecracker")
--memory <mb>             VM memory in MB (default: 2048)
--cpus <count>            VM CPU count (default: 2)
--kernel <path>           Custom kernel path (default: download)
--no-cloud-init           Disable cloud-init for testing
```

## Testing

### Test Networking
```bash
# Test both cloud-init and no-cloud-init VMs
./test-networking.sh
```

### Manual Testing
```bash
# Launch test VM without cloud-init
./firecracker-runner.sh launch --snapshot <name> --no-cloud-init --name test-vm

# SSH into test VM
ssh -i firecracker-data/instances/*/ssh_key runner@<vm-ip>

# Test Docker inside VM
docker run --rm hello-world
```

## Directory Structure

```
consolidated/
├── firecracker-runner.sh    # Main script (all-in-one)
├── test-networking.sh       # Network testing script
├── README.md               # This file
└── firecracker-data/       # Working directory
    ├── images/             # Base images
    ├── snapshots/          # VM snapshots
    └── instances/          # Running VM data
```

## Network Configuration Details

### Host Side (Bridge + TAP)
- Bridge `firecracker-br0` created once with IP `172.16.0.1/24`
- TAP device `firecracker-tap0` attached to bridge
- iptables rules for NAT and forwarding
- IP forwarding enabled

### VM Side (systemd-networkd)
- Static IP configuration via `/etc/systemd/network/10-eth0.network`
- Gateway: `172.16.0.1`
- DNS: `8.8.8.8, 8.8.4.4`
- No cloud-init networking (prevents conflicts)

### IP Assignment
- VM IPs generated from VM ID hash: `172.16.0.10-254`
- Collision avoidance (skips gateway IP)
- Deterministic but distributed allocation

## Troubleshooting

### VM Not Reachable
```bash
# Check bridge and TAP
ip addr show firecracker-br0
ip addr show firecracker-tap0

# Check VM assignment
./firecracker-runner.sh list

# Test connectivity
ping <vm-ip>
```

### SSH Connection Issues
```bash
# Find correct SSH key and IP
./firecracker-runner.sh list
ssh -i firecracker-data/instances/<vm-id>/ssh_key runner@<vm-ip>

# Check VM boot logs (if accessible)
```

### Docker Issues Inside VM
```bash
# SSH into VM and check Docker
ssh -i firecracker-data/instances/*/ssh_key runner@<vm-ip>
sudo systemctl status docker
docker info
```

## Requirements

- Ubuntu 24.04 or compatible Linux with KVM support
- Firecracker binary in PATH
- Standard tools: `curl`, `qemu-img`, `debootstrap`, `jq`, `genisoimage`
- Root/sudo access for network configuration

## Examples

### Production Deployment
```bash
# Build and snapshot
./firecracker-runner.sh build
./firecracker-runner.sh snapshot prod-v1.0

# Launch multiple runners
for i in {1..5}; do
  ./firecracker-runner.sh launch \
    --snapshot prod-v1.0 \
    --name "runner-$i" \
    --github-url "https://github.com/myorg/myrepo" \
    --github-token "$GITHUB_TOKEN" \
    --labels "firecracker,prod,runner-$i"
done
```

### Development Testing
```bash
# Quick test without GitHub setup
./firecracker-runner.sh launch --snapshot test --no-cloud-init --name dev-test
ssh -i firecracker-data/instances/*/ssh_key runner@<vm-ip>
```

### Custom Kernel
```bash
# Use custom kernel
./firecracker-runner.sh launch \
  --kernel ./my-custom-vmlinux \
  --snapshot prod-v1.0 \
  --github-url "https://github.com/myorg/myrepo" \
  --github-token "$GITHUB_TOKEN"
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
- ✅ **GitHub Actions runner**: Pre-installed with Docker CE support
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

## Technical Details

- **Docker Installation**: Uses official Docker CE repository (latest stable)
- **GitHub Actions Runner**: Latest version from GitHub releases
- **Ubuntu Base**: 24.04 LTS with cloud-init support
- **Kernel**: Firecracker-optimized kernel from official releases
- **Networking**: TAP devices with NAT for internet access

## Testing Your Runners

After deploying runners, test them with the included GitHub workflows:

### 1. Test Firecracker Runners Workflow
- **Location**: `.github/workflows/test-firecracker-runners.yml`
- **Purpose**: Comprehensive runner testing with system specs, Docker tests, and performance benchmarks
- **Usage**: GitHub Actions → "Test Firecracker Runners" → Run workflow
- **Configure**: Runner labels (e.g., `firecracker`), test level, enable Docker/performance tests

### 2. Deploy and Test Runner Workflow  
- **Location**: `.github/workflows/deploy-test-runner.yml`
- **Purpose**: Deployment guidance and connection verification
- **Usage**: GitHub Actions → "Deploy and Test Firecracker Runner" → Run workflow
- **Configure**: Runner name, memory, CPUs, auto-test option

**Example workflow usage**:
```bash
# 1. Deploy runner
./firecracker-runner.sh launch \
  --name "test-runner" \
  --github-url "https://github.com/your-org/repo" \
  --github-token "$GITHUB_TOKEN" \
  --labels "firecracker,test"

# 2. Go to GitHub Actions → "Test Firecracker Runners"
# 3. Set runner labels to: "firecracker,test"
# 4. Run workflow and see detailed specs!
```

See [`.github/workflows/README.md`](../.github/workflows/README.md) for detailed testing instructions.

---

**This replaces all the separate scripts with one unified tool.** 🚀 