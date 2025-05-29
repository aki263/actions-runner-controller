# GitHub Actions Runner Workflow with Firecracker VMs

This guide walks you through the complete workflow for building, snapshotting, and launching GitHub Actions runners using Firecracker VMs.

## Overview

The workflow consists of three main phases:

1. **Build Phase**: Create a VM image with GitHub Actions runner pre-installed
2. **Snapshot Phase**: Create reusable snapshots for fast deployment
3. **Launch Phase**: Deploy runner VMs from snapshots with cloud-init configuration

## Prerequisites

- Ubuntu 24.04 or compatible Linux with KVM support
- Root/sudo access
- At least 10GB free disk space
- GitHub repository or organization access
- GitHub Personal Access Token with appropriate permissions

## Phase 1: Build Runner Image

### 1.1 Build the Runner Image

Create a VM image with GitHub Actions runner and all dependencies pre-installed:

```bash
# Basic build (uses latest runner version)
./build-runner-image.sh

# Custom build with specific versions
./build-runner-image.sh \
    --runner-version 2.311.0 \
    --docker-version 24.0.7 \
    --rootfs-size 30G
```

**What this creates:**
- `runner-image/actions-runner-ubuntu-24.04.ext4` - VM image with runner pre-installed
- Ubuntu 24.04 base system
- GitHub Actions Runner v2.311.0 (or specified version)
- Docker v24.0.7 (or specified version)
- All runner dependencies and tools

**Build time:** ~15-30 minutes (depending on internet speed)

### 1.2 Verify the Build

Check what was created:

```bash
ls -la runner-image/
du -h runner-image/actions-runner-ubuntu-24.04.ext4
```

## Phase 2: Create Snapshots

### 2.1 Create a Snapshot

Create a reusable snapshot from the built image:

```bash
# Create snapshot with auto-generated name
./snapshot-runner-image.sh create

# Create snapshot with custom name
./snapshot-runner-image.sh create my-runner-v1.0
```

**What this creates:**
- `snapshots/<snapshot-name>/` directory containing:
  - `rootfs.ext4` - Copy of the runner image
  - `vmlinux` - Kernel binary (if available)
  - `snapshot-info.json` - Metadata
  - `launch-template.json` - VM configuration template
  - `cloud-init-template.yaml` - Cloud-init configuration template
  - `launch.sh` - Quick launch script

### 2.2 List Available Snapshots

```bash
./snapshot-runner-image.sh list
```

### 2.3 Delete Snapshots (if needed)

```bash
./snapshot-runner-image.sh delete <snapshot-name>
```

## Phase 3: Launch Runner VMs

### 3.1 Basic Runner Launch

Launch a runner VM with minimal configuration:

```bash
./launch-runner-vm.sh \
    --github-url https://github.com/your-org/your-repo \
    --github-token ghp_your_token_here
```

### 3.2 Advanced Runner Launch

Launch with custom configuration:

```bash
./launch-runner-vm.sh \
    --github-url https://github.com/your-org/your-repo \
    --github-token ghp_your_token_here \
    --runner-name my-custom-runner \
    --runner-labels firecracker,ubuntu-24.04,docker \
    --memory 4096 \
    --cpus 4 \
    --work-dir /opt/runner-work
```

### 3.3 Launch from Specific Snapshot

```bash
./launch-runner-vm.sh \
    --snapshot ./snapshots/my-runner-v1.0 \
    --github-url https://github.com/your-org/your-repo \
    --github-token ghp_your_token_here \
    --runner-name production-runner
```

### 3.4 Quick Launch from Snapshot

Each snapshot includes a quick launch script:

```bash
cd snapshots/my-runner-v1.0
./launch.sh my-runner https://github.com/your-org/your-repo ghp_your_token_here
```

## GitHub Token Setup

### Required Permissions

Your GitHub Personal Access Token needs these permissions:

**For Repository Runners:**
- `repo` (Full control of private repositories)
- `admin:org` > `read:org` (Read org membership)

**For Organization Runners:**
- `admin:org` (Full control of orgs and teams)
- `repo` (if accessing private repos)

### Create a Token

1. Go to GitHub Settings → Developer settings → Personal access tokens
2. Click "Generate new token (classic)"
3. Select required scopes
4. Copy the token (starts with `ghp_`)

## VM Management

### Check Runner Status

```bash
# SSH into the runner VM
ssh -i runner-instances/runner_key_<vm-id> runner@172.16.0.2

# Check runner service status
sudo systemctl status actions-runner

# View runner logs
sudo journalctl -u actions-runner -f
```

### Stop Runner VMs

```bash
# Stop specific VM
./firecracker-manage.sh stop <vm-id>

# Stop all VMs
./firecracker-manage.sh cleanup
```

### List Running VMs

```bash
./firecracker-manage.sh list
```

## Cloud-Init Configuration

### Default Configuration

The launcher automatically configures:
- Hostname set to runner name
- SSH keys for runner user
- Network configuration (172.16.0.2/30)
- Environment variables for GitHub integration
- Automatic runner service startup

### Custom Cloud-Init

You can modify the cloud-init template in snapshots:

```bash
# Edit the template
nano snapshots/<snapshot-name>/cloud-init-template.yaml

# The template supports these variables:
# ${RUNNER_NAME} - Runner name
# ${GITHUB_TOKEN} - GitHub token
# ${GITHUB_URL} - GitHub repository/org URL
# ${RUNNER_LABELS} - Comma-separated labels
# ${SSH_PUBLIC_KEY} - SSH public key
# ${RUNNER_WORK_DIR} - Runner work directory
```

## Workflow Examples

### Development Workflow

```bash
# 1. Build image once
./build-runner-image.sh

# 2. Create snapshot
./snapshot-runner-image.sh create dev-snapshot

# 3. Launch runners as needed
./launch-runner-vm.sh \
    --github-url https://github.com/myorg/myrepo \
    --github-token $GITHUB_TOKEN \
    --runner-name dev-runner-$(date +%H%M%S)
```

### Production Workflow

```bash
# 1. Build production image
./build-runner-image.sh \
    --runner-version 2.311.0 \
    --rootfs-size 50G

# 2. Create production snapshot
./snapshot-runner-image.sh create prod-v1.0

# 3. Launch production runners
./launch-runner-vm.sh \
    --snapshot ./snapshots/prod-v1.0 \
    --github-url https://github.com/myorg \
    --github-token $GITHUB_TOKEN \
    --runner-name prod-runner-$(hostname)-$(date +%Y%m%d-%H%M%S) \
    --runner-labels production,firecracker,ubuntu-24.04 \
    --memory 8192 \
    --cpus 8
```

### Multiple Runners

```bash
# Launch multiple runners for scale
for i in {1..5}; do
    ./launch-runner-vm.sh \
        --github-url https://github.com/myorg/myrepo \
        --github-token $GITHUB_TOKEN \
        --runner-name batch-runner-$i \
        --memory 2048 \
        --cpus 2 &
done
wait
```

## File Structure

After running the complete workflow:

```
firecracker-poc/
├── build-runner-image.sh          # Build runner image
├── snapshot-runner-image.sh       # Manage snapshots
├── launch-runner-vm.sh            # Launch runner VMs
├── runner-image/                  # Built images
│   └── actions-runner-ubuntu-24.04.ext4
├── snapshots/                     # VM snapshots
│   ├── registry.json             # Snapshot registry
│   └── <snapshot-name>/
│       ├── rootfs.ext4           # Snapshot rootfs
│       ├── vmlinux               # Kernel
│       ├── launch.sh             # Quick launcher
│       └── cloud-init-template.yaml
└── runner-instances/              # Running VM instances
    ├── rootfs-<vm-id>.ext4       # Instance rootfs
    ├── runner_key_<vm-id>        # SSH keys
    ├── firecracker-<vm-id>.pid   # Process IDs
    └── cloud-init-<vm-id>/       # Cloud-init configs
```

## Monitoring and Metrics

### Runner Health Check

```bash
# Check if runner is registered and ready
ssh -i runner-instances/runner_key_<vm-id> runner@172.16.0.2 \
    'cd /runnertmp && ./run.sh --check'

# View GitHub Actions runner status
curl -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/OWNER/REPO/actions/runners"
```

### VM Resource Usage

```bash
# Check VM resource usage
ssh -i runner-instances/runner_key_<vm-id> runner@172.16.0.2 \
    'htop -n 1 && df -h && free -h'
```

## Troubleshooting

### Common Issues

1. **Runner not registering:**
   - Check GitHub token permissions
   - Verify network connectivity: `ping github.com`
   - Check runner service logs: `journalctl -u actions-runner`

2. **VM won't start:**
   - Check KVM permissions: `ls -la /dev/kvm`
   - Verify networking: `./debug-networking.sh`
   - Check Firecracker logs

3. **SSH connection issues:**
   - Check VM IP: `ping 172.16.0.2`
   - Verify SSH key path
   - Check cloud-init logs: `cloud-init status --long`

### Debug Commands

```bash
# Debug networking
./debug-networking.sh

# Check VM status
./firecracker-manage.sh status <vm-id>

# View cloud-init logs in VM
ssh -i runner-instances/runner_key_<vm-id> root@172.16.0.2 \
    'cloud-init status --long'
```

## Performance Considerations

### VM Sizing Guidelines

- **Light workloads:** 1 CPU, 1GB RAM
- **Standard builds:** 2 CPUs, 2GB RAM  
- **Heavy builds:** 4+ CPUs, 4+ GB RAM
- **Docker builds:** 4+ CPUs, 8+ GB RAM

### Storage Recommendations

- **Base image:** 20GB minimum
- **With Docker:** 30GB+ recommended
- **Heavy builds:** 50GB+ for build artifacts

### Scaling Considerations

- Each VM needs unique IP (currently limited to one per /30 subnet)
- Consider implementing IP pool management for multiple VMs
- Monitor host resources when running multiple VMs

## Security Best Practices

1. **Token Management:**
   - Use environment variables for tokens
   - Rotate tokens regularly
   - Use fine-grained personal access tokens when available

2. **VM Security:**
   - VMs are isolated by Firecracker's microVM technology
   - Network isolation via TAP devices
   - Consider implementing VM-level firewalls

3. **SSH Access:**
   - SSH keys are generated per VM instance
   - Keys are automatically configured via cloud-init
   - Consider disabling SSH after runner setup for production

## Next Steps

1. **Automation:** Integrate with CI/CD pipelines for automatic runner provisioning
2. **Orchestration:** Build Kubernetes operator for managing runner pools
3. **Monitoring:** Implement Prometheus metrics for runner and VM health
4. **Scaling:** Implement auto-scaling based on GitHub Actions queue length 