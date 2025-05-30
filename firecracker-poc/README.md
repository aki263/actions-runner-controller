# Firecracker Complete - GitHub Actions Runner

**One script to rule them all** - Build kernel, filesystem, VMs, and manage everything securely.

## 🚀 Quick Start

```bash
# 1. Build custom kernel with all networking modules
./firecracker-complete.sh build-kernel --rebuild-kernel

# 2. Build filesystem with GitHub Actions runner
./firecracker-complete.sh build-fs --rebuild-fs

# 3. Create snapshot
./firecracker-complete.sh snapshot prod-v1

# 4. Launch secure ephemeral runner VM
./firecracker-complete.sh launch \
  --snapshot prod-v1 \
  --ephemeral-mode \
  --github-url https://github.com/your-org/your-repo \
  --github-pat ghp_your_token_here

# 5. Monitor ephemeral VMs (auto-cleanup after jobs)
./firecracker-complete.sh monitor-ephemeral
```

## 📁 Clean Structure

```
firecracker-poc/
├── firecracker-complete.sh      # 🎯 Main script (everything!)
├── working-kernel-config        # 🐧 Kernel configuration with all modules
├── ubuntu-24-packages.md        # 📦 Package reference
├── README.md                    # 📖 This documentation
└── firecracker-data/           # 📂 Working directory
    ├── kernels/                 # Built kernels
    ├── images/                  # Filesystem images  
    ├── snapshots/               # VM snapshots
    └── instances/               # Running VMs
```

## 🔒 Security Model

**PAT tokens stay on host** - following GitHub Actions Runner Controller (ARC) security best practices:

- ✅ **Host**: Long-lived PAT tokens with broad permissions (never exposed to VMs)
- ✅ **VMs**: Short-lived registration tokens (~1 hour, limited permissions)
- ✅ **Process**: Host generates registration token using PAT, passes only registration token to VM
- ✅ **Isolation**: VMs cannot access PAT tokens or generate new tokens

```bash
# Secure token flow:
# 1. PAT (ghp_xxx) stays on host
# 2. Host calls GitHub API: /actions/runners/registration-token
# 3. GitHub returns registration token (ABCD1234)
# 4. Only registration token passed to VM environment
# 5. VM uses registration token to self-register
```

## 💡 What It Does

1. **Build Kernel**: Custom kernel with Docker networking, USB, Graphics, Sound support
2. **Build Filesystem**: Ubuntu 24.04 + Docker CE + GitHub Actions runner + 300+ dev packages
3. **Manage VMs**: Launch with cloud-init networking, SSH access, automatic runner registration
4. **Networking**: Shared bridge (172.16.0.1/24) with Docker networking fully functional
5. **Security**: PAT tokens never exposed to VMs, registration tokens only
6. **Ephemeral**: Auto-shutdown VMs after job completion with proper cleanup

## 🔧 Features

- **Single TAP/Bridge**: All VMs share `firecracker-br0` bridge  
- **Docker Networking**: Full Docker support with bridge/overlay/iptables
- **Ephemeral VMs**: Auto-destroy after job completion
- **ARC Integration**: Compatible with Actions Runner Controller
- **Job Monitoring**: Real-time job completion detection
- **Auto SSH**: Generated keys, immediate SSH access
- **Package Support**: 300+ development packages (browsers, databases, languages)
- **Smart Validation**: Prevents conflicts and validates inputs

## 📋 Commands

```bash
# Build
./firecracker-complete.sh build-kernel [options]  # Build custom kernel
./firecracker-complete.sh build-fs [options]      # Build filesystem  
./firecracker-complete.sh snapshot [name]         # Create snapshot

# VM Management
./firecracker-complete.sh launch [options]        # Launch VM
./firecracker-complete.sh list                    # List all resources
./firecracker-complete.sh stop [pattern]          # Stop VMs
./firecracker-complete.sh status                  # Check VM health
./firecracker-complete.sh monitor-ephemeral       # Monitor job completion
./firecracker-complete.sh cleanup                 # Stop all + cleanup
```

## ⚙️ Build Options

```bash
--config <path>        # Custom kernel config (default: working-kernel-config)
--rebuild-kernel       # Force rebuild kernel
--rebuild-fs           # Force rebuild filesystem
--skip-deps            # Skip dependency checks
```

## 🎛️ Launch Options

```bash
--snapshot <name>         # Use specific snapshot
--github-url <url>        # GitHub repo/org/enterprise URL
--github-pat <pat>        # GitHub PAT (generates registration token securely)
--name <name>             # VM name
--labels <labels>         # Runner labels (default: firecracker)
--memory <mb>             # VM memory (default: 2048)
--cpus <count>            # VM CPUs (default: 2)
--kernel <path>           # Custom kernel path
--no-cloud-init          # Disable cloud-init (testing only)
--use-host-bridge        # Use host bridge networking with DHCP
--docker-mode            # Run as Docker container (foreground)
--arc-mode               # Enable ARC integration
--ephemeral-mode         # Auto-shutdown after job completion
```

## 📝 Usage Examples

### Secure Production Deployment
```bash
# Build components
./firecracker-complete.sh build-kernel --rebuild-kernel
./firecracker-complete.sh build-fs --rebuild-fs
./firecracker-complete.sh snapshot prod-$(date +%Y%m%d)

# Launch ephemeral runners (auto-cleanup after jobs)
./firecracker-complete.sh launch \
  --snapshot prod-$(date +%Y%m%d) \
  --ephemeral-mode \
  --github-url "https://github.com/myorg/myrepo" \
  --github-pat "ghp_your_secure_token" \
  --labels "production,firecracker,ephemeral" \
  --memory 4096 \
  --cpus 4

# Monitor and auto-cleanup (run in separate terminal)
./firecracker-complete.sh monitor-ephemeral
```

### ARC Integration
```bash
# ARC-compatible runners
./firecracker-complete.sh launch \
  --arc-mode \
  --ephemeral-mode \
  --github-url "https://github.com/enterprise/repo" \
  --github-pat "$ARC_GITHUB_PAT" \
  --labels "arc,firecracker,autoscale"
```

### Development & Testing
```bash
# Quick development VM
./firecracker-complete.sh launch --no-cloud-init --name dev-vm

# Docker-mode (foreground like container)
./firecracker-complete.sh launch \
  --docker-mode \
  --github-url "https://github.com/myorg/myrepo" \
  --github-pat "$GITHUB_PAT"
```

## 🚨 Docker Networking

The kernel config includes all required Docker networking modules:

✅ **Bridge networking** (`CONFIG_BRIDGE=y`, `CONFIG_BRIDGE_NETFILTER=y`)  
✅ **Container networking** (`CONFIG_VETH=y`, `CONFIG_MACVLAN=y`, `CONFIG_IPVLAN=y`)  
✅ **iptables/netfilter** (`CONFIG_NETFILTER=y`, `CONFIG_NF_CONNTRACK=y`)  
✅ **NAT/masquerading** (`CONFIG_IP_NF_TARGET_MASQUERADE=y`)  
✅ **Overlay filesystems** (`CONFIG_OVERLAY_FS=y`)  

Docker multi-stage builds, container networking, and all Docker features work out of the box.

## 🔄 Ephemeral VM Workflow

1. **Launch**: VM starts with `--ephemeral-mode`
2. **Register**: Runner self-registers with GitHub using registration token
3. **Monitor**: Job monitoring service tracks runner worker process
4. **Detect**: When `Runner.Worker` process ends, job is complete
5. **Signal**: VM creates `/tmp/ephemeral-cleanup` completion signal
6. **Cleanup**: Monitor detects signal and destroys VM
7. **Repeat**: New ephemeral VMs can be launched for new jobs

```bash
# Example ephemeral workflow
./firecracker-complete.sh launch --ephemeral-mode --github-pat "$PAT" --github-url "$URL" &
./firecracker-complete.sh monitor-ephemeral &

# VM auto-destroys after job completion
# Monitor continues watching for new ephemeral VMs
```

## 🔗 Requirements

- **Ubuntu 24.04** or compatible Linux
- **KVM support** (`/dev/kvm` access)
- **Firecracker** installed
- **Dependencies**: `build-essential curl wget git bc flex bison libssl-dev libelf-dev qemu-utils debootstrap jq openssh-client genisoimage`

## 📊 Size Reference

- **Kernel**: ~15MB (custom with full Docker networking)
- **Filesystem**: ~8GB (Ubuntu + Docker + runner + dev tools)
- **Snapshot**: ~8GB (copy of filesystem)
- **VM Memory**: 2GB default (configurable)

## 🛠️ Troubleshooting

### Check VM Status
```bash
./firecracker-complete.sh status          # Overall health check
./firecracker-complete.sh list            # List all resources
```

### Debug Networking
```bash
# SSH into VM
ssh -i firecracker-data/instances/vm-*/ssh_key runner@<vm-ip>

# Check Docker in VM
sudo docker run hello-world
sudo docker network ls
```

### Monitor Logs
```bash
# Job monitoring logs
tail -f /var/log/job-monitor.log

# Runner logs (in VM)
tail -f /opt/runner/_diag/Runner_*.log
```

### Security Validation
```bash
# Verify PAT tokens don't leak to VMs
./firecracker-complete.sh launch --github-pat "$PAT" --github-url "$URL"
ssh -i firecracker-data/instances/vm-*/ssh_key runner@<vm-ip> 'env | grep -i github'
# Should only show RUNNER_TOKEN, never GITHUB_TOKEN or PAT
```

---

**Production-ready GitHub Actions runners with enterprise security! 🚀🔒** 