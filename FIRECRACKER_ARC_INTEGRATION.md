# Firecracker Integration for Actions Runner Controller (ARC)

This document explains how to use Firecracker VMs as runtime for GitHub Actions runners in Actions Runner Controller (ARC).

## Overview

The Firecracker integration allows you to run GitHub Actions runners in lightweight VMs instead of Kubernetes pods, providing:

- **Better Isolation**: Complete kernel isolation between jobs
- **Improved Security**: Reduced attack surface compared to shared kernel containers  
- **Consistent Environment**: Each runner gets a fresh VM with predictable state
- **Networking**: VMs can communicate with ARC controller and GitHub

## Prerequisites

1. **Firecracker Setup**: The firecracker-complete.sh script must be available on the ARC controller node
2. **Kernel & Root Filesystem**: Pre-built kernel and rootfs images for GitHub Actions runners
3. **Networking**: Bridge network configuration for VM communication

## Quick Start

### 1. Prepare Firecracker Components

Build the kernel and filesystem using the firecracker-poc tools:

```bash
# Build custom kernel with networking support
./firecracker-complete.sh build-kernel --rebuild-kernel

# Build filesystem with GitHub Actions runner
./firecracker-complete.sh build-fs --rebuild-fs

# Create a snapshot for faster VM startup
./firecracker-complete.sh snapshot production-v1
```

### 2. Create GitHub PAT Secret

```bash
kubectl create secret generic github-pat-secret \
  --from-literal=github_token=ghp_your_personal_access_token_here \
  -n actions-runner-system
```

### 3. Deploy Firecracker RunnerDeployment

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: firecracker-runners
  namespace: actions-runner-system
  annotations:
    # Enable Firecracker runtime
    runner.summerwind.dev/runtime: "firecracker"
    runner.summerwind.dev/firecracker-kernel: "/opt/firecracker/kernels/vmlinux-5.10"
    runner.summerwind.dev/firecracker-rootfs: "/opt/firecracker/images/ubuntu-runner.ext4"
    runner.summerwind.dev/firecracker-memory: "4096"
    runner.summerwind.dev/firecracker-vcpus: "4"
    runner.summerwind.dev/firecracker-network: '{"interface":"eth0","subnetCIDR":"172.16.0.0/24","gateway":"172.16.0.1"}'
spec:
  replicas: 3
  template:
    spec:
      organization: "your-github-org"  # or repository: "your-org/your-repo"
      ephemeral: true
      githubAPICredentialsFrom:
        secretRef:
          name: github-pat-secret
      labels:
        - self-hosted
        - firecracker
        - linux
        - x64
```

Apply the configuration:

```bash
kubectl apply -f firecracker-runnerdeployment.yaml
```

## Configuration Options

### Annotations

The Firecracker controller uses annotations to configure VM parameters:

| Annotation | Description | Default | Example |
|------------|-------------|---------|---------|
| `runner.summerwind.dev/runtime` | Enable Firecracker runtime | `kubernetes` | `firecracker` |
| `runner.summerwind.dev/firecracker-kernel` | Path to kernel image | - | `/opt/firecracker/kernels/vmlinux-5.10` |
| `runner.summerwind.dev/firecracker-rootfs` | Path to root filesystem | - | `/opt/firecracker/images/ubuntu-runner.ext4` |
| `runner.summerwind.dev/firecracker-memory` | VM memory in MiB | `2048` | `4096` |
| `runner.summerwind.dev/firecracker-vcpus` | Number of vCPUs | `2` | `4` |
| `runner.summerwind.dev/firecracker-network` | Network configuration JSON | Default bridge | See example above |

### Firecracker Script Path

The controller expects the `firecracker-complete.sh` script at `/opt/firecracker/firecracker-complete.sh` by default. This can be changed in the main.go configuration.

## Architecture

```
GitHub Actions → ARC Controller → Firecracker VMs
                      ↓               ↓
                Registration Token → VM Startup
                      ↓               ↓
               VM Status Monitoring ← Runner Registration
```

### Communication Flow

1. **RunnerDeployment Created**: ARC detects Firecracker annotation
2. **VM Creation**: Controller calls `firecracker-complete.sh create-runner-vm`
3. **Token Generation**: Uses existing ARC GitHub client to generate registration tokens
4. **VM Startup**: Firecracker VM boots with cloud-init containing runner setup
5. **Runner Registration**: VM automatically registers as GitHub Actions runner
6. **Job Execution**: GitHub schedules jobs to the runner
7. **Cleanup**: Ephemeral VMs auto-destroy after job completion

## Security Model

### Token Management

- **PAT Tokens**: Remain on ARC controller (Kubernetes secret)
- **Registration Tokens**: Short-lived, passed to VMs via cloud-init
- **No Persistent Secrets**: VMs cannot access long-lived GitHub credentials

### Network Isolation

- VMs communicate through bridge network (172.16.0.0/24 by default)
- Controller accessible from VMs for status reporting
- Internet access for GitHub API and package downloads

## Networking

### Bridge Configuration

The Firecracker integration uses a shared bridge network:

- **Bridge**: `firecracker-br0` (172.16.0.1/24)
- **VM IPs**: Auto-assigned from the subnet
- **DNS**: Configured via cloud-init
- **Internet**: NAT through host

### Firewall Considerations

Ensure these connections are allowed:

- VMs → ARC Controller (Kubernetes API)
- VMs → GitHub API (443/tcp)
- VMs → Package repositories (80/443/tcp)

## Monitoring and Debugging

### Check Controller Logs

```bash
kubectl logs -n actions-runner-system deployment/controller-manager -c manager | grep firecracker
```

### List Running VMs

```bash
# On the controller node
/opt/firecracker/firecracker-complete.sh list-arc-vms
```

### VM Status

```bash
/opt/firecracker/firecracker-complete.sh get-arc-vm-status <vm-name>
```

### Manual VM Creation (Testing)

```bash
/opt/firecracker/firecracker-complete.sh create-runner-vm \
  --vm-id test-vm-001 \
  --registration-token ABCD1234... \
  --github-url https://github.com/your-org \
  --memory 2048 \
  --cpus 2 \
  --ephemeral-mode
```

## Troubleshooting

### Common Issues

1. **VMs Not Starting**
   - Check kernel and rootfs paths in annotations
   - Verify firecracker-complete.sh script permissions
   - Check controller logs for error messages

2. **Runner Registration Fails**
   - Verify GitHub PAT token has correct permissions
   - Check VM can reach GitHub API (network connectivity)
   - Ensure organization/repository exists and is accessible

3. **Network Issues**
   - Verify bridge network configuration on host
   - Check firewall rules for VM connectivity
   - Ensure DNS resolution works in VMs

### Performance Tuning

- **Memory**: Increase VM memory for resource-intensive builds
- **vCPUs**: Match VM vCPUs to expected job parallelism
- **Disk**: Use SSD storage for kernel and rootfs images
- **Network**: Optimize bridge network for high throughput

## Migration from Kubernetes Pods

To migrate existing RunnerDeployments to Firecracker:

1. **Prepare**: Build Firecracker kernel and rootfs
2. **Annotate**: Add Firecracker annotations to existing RunnerDeployment
3. **Scale**: Controller automatically handles the transition
4. **Verify**: Check runner registration and job execution

## Limitations

1. **Host Dependencies**: Requires Firecracker support on nodes
2. **Storage**: Stateful storage not currently supported
3. **Service Mesh**: Limited integration with service mesh technologies
4. **Windows**: Linux VMs only (no Windows runner support)

## Contributing

To improve the Firecracker integration:

1. Test with different kernel configurations
2. Optimize VM startup time
3. Add support for persistent storage
4. Implement advanced networking features

## References

- [Firecracker Documentation](https://firecracker-microvm.github.io/)
- [GitHub Actions Runner Documentation](https://docs.github.com/en/actions/hosting-your-own-runners)
- [Actions Runner Controller](https://github.com/actions/actions-runner-controller) 