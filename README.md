# Actions Runner Controller (ARC)

[![CII Best Practices](https://bestpractices.coreinfrastructure.org/projects/6061/badge)](https://bestpractices.coreinfrastructure.org/projects/6061)
[![awesome-runners](https://img.shields.io/badge/listed%20on-awesome--runners-blue.svg)](https://github.com/jonico/awesome-runners)
[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/actions-runner-controller)](https://artifacthub.io/packages/search?repo=actions-runner-controller)

## About

Actions Runner Controller (ARC) is a Kubernetes operator that orchestrates and scales self-hosted runners for GitHub Actions.

With ARC, you can create runner scale sets that automatically scale based on the number of workflows running in your repository, organization, or enterprise. Because controlled runners can be ephemeral and based on containers, new runner instances can scale up or down rapidly and cleanly. For more information about autoscaling, see ["Autoscaling with self-hosted runners."](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners)

You can set up ARC on Kubernetes using Helm, then create and run a workflow that uses runner scale sets. For more information about runner scale sets, see ["Deploying runner scale sets with Actions Runner Controller."](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/deploying-runner-scale-sets-with-actions-runner-controller#runner-scale-set)
## People

Actions Runner Controller (ARC) is an open-source project currently developed and maintained in collaboration with the GitHub Actions team, external maintainers @mumoshu and @toast-gear, various [contributors](https://github.com/actions/actions-runner-controller/graphs/contributors), and the [awesome community](https://github.com/actions/actions-runner-controller/discussions).

If you think the project is awesome and is adding value to your business, please consider directly sponsoring [community maintainers](https://github.com/sponsors/actions-runner-controller) and individual contributors via GitHub Sponsors.

In case you are already the employer of one of contributors, sponsoring via GitHub Sponsors might not be an option. Just support them in other means!

See [the sponsorship dashboard](https://github.com/sponsors/actions-runner-controller) for the former and the current sponsors.

## Getting Started

To give ARC a try with just a handful of commands, Please refer to the [Quickstart guide](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/quickstart-for-actions-runner-controller).

For an overview of ARC, please refer to [About ARC](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/about-actions-runner-controller)

With the introduction of [autoscaling runner scale sets](https://github.com/actions/actions-runner-controller/discussions/2775), the existing [autoscaling modes](./docs/automatically-scaling-runners.md) are now legacy. The legacy modes have certain use cases and will continue to be maintained by the community only.

For further information on what is supported by GitHub and what's managed by the community, please refer to [this announcement discussion.](https://github.com/actions/actions-runner-controller/discussions/2775)

### Documentation

ARC documentation is available on [docs.github.com](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/quickstart-for-actions-runner-controller).

### Legacy documentation

The following documentation is for the legacy autoscaling modes that continue to be maintained by the community

- [Quickstart guide](/docs/quickstart.md)
- [About ARC](/docs/about-arc.md)
- [Installing ARC](/docs/installing-arc.md)
- [Authenticating to the GitHub API](/docs/authenticating-to-the-github-api.md)
- [Deploying ARC runners](/docs/deploying-arc-runners.md)
- [Adding ARC runners to a repository, organization, or enterprise](/docs/choosing-runner-destination.md)
- [Automatically scaling runners](/docs/automatically-scaling-runners.md)
- [Using custom volumes](/docs/using-custom-volumes.md)
- [Using ARC runners in a workflow](/docs/using-arc-runners-in-a-workflow.md)
- [Managing access with runner groups](/docs/managing-access-with-runner-groups.md)
- [Configuring Windows runners](/docs/configuring-windows-runners.md)
- [Using ARC across organizations](/docs/using-arc-across-organizations.md)
- [Using entrypoint features](/docs/using-entrypoint-features.md)
- [Deploying alternative runners](/docs/deploying-alternative-runners.md)
- [Monitoring and troubleshooting](/docs/monitoring-and-troubleshooting.md)

## Contributing

We welcome contributions from the community. For more details on contributing to the project (including requirements), please refer to "[Getting Started with Contributing](https://github.com/actions/actions-runner-controller/blob/master/CONTRIBUTING.md)."

## Troubleshooting

We are very happy to help you with any issues you have. Please refer to the "[Troubleshooting](https://github.com/actions/actions-runner-controller/blob/master/TROUBLESHOOTING.md)" section for common issues.

# Firecracker VM Setup with Ubuntu 24.04

This repository provides scripts to quickly set up and manage Firecracker VMs running Ubuntu 24.04 with SSH access and expandable root filesystems.

## Features

- 🚀 **Quick Setup**: One command to create and start a VM
- 🔑 **SSH Access**: Automatic SSH key generation and configuration
- 🌐 **Networking**: TAP device setup with internet access
- 📦 **Ubuntu 24.04**: Latest Ubuntu LTS with essential packages
- 💾 **Expandable Storage**: Easy rootfs resizing
- 🛠️ **Management Tools**: Stop, status, and cleanup commands

## Prerequisites

### System Requirements

- Linux host with KVM support
- Root/sudo access for network configuration
- At least 2GB free disk space

### Dependencies

The setup script will check for dependencies, but you can install them manually:

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install -y curl qemu-utils debootstrap openssh-client e2fsprogs jq
```

**Install Firecracker:**
```bash
# Download latest release
curl -LOJ https://github.com/firecracker-microvm/firecracker/releases/latest/download/firecracker-v*-x86_64.tgz
tar -xzf firecracker-*.tgz
sudo mv release-*/firecracker-* /usr/local/bin/firecracker
sudo chmod +x /usr/local/bin/firecracker

# Set up KVM permissions
sudo usermod -a -G kvm $USER
newgrp kvm
```

## Quick Start

1. **Clone or download the scripts:**
   ```bash
   curl -O https://raw.githubusercontent.com/your-repo/firecracker-setup.sh
   curl -O https://raw.githubusercontent.com/your-repo/firecracker-manage.sh
   chmod +x firecracker-setup.sh firecracker-manage.sh
   ```

2. **Create and start a VM:**
   ```bash
   ./firecracker-setup.sh
   ```

3. **Connect via SSH:**
   ```bash
   ssh -i ./firecracker-vm/vm_key root@172.20.0.2
   ```

## Usage

### Creating VMs

**Basic VM (default: 2 CPUs, 1GB RAM, 10GB disk):**
```bash
./firecracker-setup.sh
```

**Custom VM configuration:**
```bash
# 4 CPUs, 4GB RAM, 20GB disk
./firecracker-setup.sh --cpus 4 --memory 4096 --rootfs-size 20G
```

**Available options:**
```bash
./firecracker-setup.sh --help
```

### Managing VMs

**List all VMs:**
```bash
./firecracker-manage.sh list
```

**Check VM status:**
```bash
./firecracker-manage.sh status <vm_id>
```

**Stop a VM:**
```bash
./firecracker-manage.sh stop <vm_id>
```

**Show SSH connection info:**
```bash
./firecracker-manage.sh ssh <vm_id>
```

**Clean up all VMs:**
```bash
./firecracker-manage.sh cleanup
```

### Resizing Root Filesystem

**Resize rootfs (VM must be stopped):**
```bash
# Resize to 50GB
./firecracker-manage.sh resize <vm_id> 50G

# Or use the setup script
./firecracker-setup.sh --resize-only 50G
```

The resize operation:
1. Expands the disk image file
2. Extends the ext4 filesystem
3. Makes the additional space immediately available when the VM starts

## Network Configuration

The setup creates a TAP device with the following configuration:

- **Host IP:** 172.20.0.1/24
- **VM IP:** 172.20.0.2/24
- **Internet Access:** Via NAT through the host

### Port Forwarding

Forward host ports to the VM:
```bash
# Forward host port 8080 to VM port 80
ssh -i ./firecracker-vm/vm_key -L 8080:localhost:80 root@172.20.0.2
```

### Multiple VMs

Each VM gets a unique ID and network configuration. You can run multiple VMs simultaneously.

## File Structure

After running the setup script:

```
firecracker-vm/
├── vmlinux-6.1.128                 # Kernel binary
├── ubuntu-24.04-rootfs.ext4        # Root filesystem
├── vm_key                          # SSH private key
├── vm_key.pub                      # SSH public key
├── vm-config-<vm_id>.json          # VM configuration
├── firecracker-<vm_id>.pid         # Process ID file
└── firecracker-<vm_id>.socket      # API socket
```

## Inside the VM

The Ubuntu 24.04 VM includes:

- **Base system:** Ubuntu 24.04 LTS (Noble)
- **Pre-installed packages:** SSH server, curl, wget, vim, htop, net-tools
- **User:** root (passwordless, SSH key authentication)
- **Network:** Configured with systemd-networkd
- **Auto-login:** Console auto-login as root

### Installing Additional Packages

```bash
# Update package list
apt update

# Install packages
apt install -y docker.io nodejs python3 build-essential

# Example: Install development tools
apt install -y git make gcc g++ python3-pip
```

### Package Management Tips

The VM uses standard Ubuntu package management:

- `apt update` - Update package lists
- `apt upgrade` - Upgrade packages
- `apt install <package>` - Install packages
- `apt search <term>` - Search for packages
- `apt remove <package>` - Remove packages

## Troubleshooting

### Common Issues

**1. Permission denied on /dev/kvm:**
```bash
sudo usermod -a -G kvm $USER
newgrp kvm
```

**2. VM won't start:**
- Check if Firecracker binary is in PATH: `which firecracker`
- Verify KVM is available: `ls -la /dev/kvm`
- Check system logs: `dmesg | grep kvm`

**3. SSH connection refused:**
- Wait a few more seconds for VM to boot completely
- Check VM status: `./firecracker-manage.sh status <vm_id>`
- Verify network: `ping 172.20.0.2`

**4. Network issues:**
- Check TAP device: `ip addr show tap-<vm_id>`
- Verify iptables rules: `sudo iptables -t nat -L`
- Check IP forwarding: `cat /proc/sys/net/ipv4/ip_forward`

### Manual Network Setup

If automatic network setup fails:

```bash
# Create TAP device manually
sudo ip tuntap add dev tap0 mode tap user $USER
sudo ip addr add 172.20.0.1/24 dev tap0
sudo ip link set dev tap0 up

# Enable forwarding
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward

# Set up NAT
sudo iptables -t nat -A POSTROUTING -s 172.20.0.0/24 ! -o tap0 -j MASQUERADE
sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i tap0 -o tap0 -j ACCEPT
```

## Advanced Usage

### Custom Kernel

To use a custom kernel, replace the downloaded kernel file:

```bash
# Place your kernel binary
cp /path/to/your/vmlinux ./firecracker-vm/vmlinux-6.1.128
```

### Custom Rootfs Modifications

Mount and modify the rootfs before starting the VM:

```bash
# Mount rootfs
sudo mkdir -p /mnt/rootfs
sudo mount ./firecracker-vm/ubuntu-24.04-rootfs.ext4 /mnt/rootfs

# Make modifications
sudo chroot /mnt/rootfs apt update
sudo chroot /mnt/rootfs apt install -y your-package

# Unmount
sudo umount /mnt/rootfs
```

### API Access

The Firecracker API socket is available for direct API calls:

```bash
# Get VM information
curl -X GET --unix-socket ./firecracker-vm/firecracker-<vm_id>.socket \
     http://localhost/machine-config
```

## Performance Tuning

### Fast Boot Options

For faster boot times, add these kernel parameters:
```
i8042.noaux i8042.nomux i8042.nopnp i8042.nokbd random.trust_cpu=on
```

### Memory and CPU

Adjust based on your workload:
```bash
# Lightweight development
./firecracker-setup.sh --cpus 1 --memory 512

# Heavy compilation/development
./firecracker-setup.sh --cpus 8 --memory 8192
```

## Security Considerations

- The VM runs with root access for simplicity
- SSH is configured for key-based authentication only
- Consider creating non-root users for production use
- Network isolation is provided by the VM boundary
- Host firewall rules may need adjustment for external access

## Contributing

Feel free to submit issues and enhancement requests!

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## References

- [Firecracker Documentation](https://github.com/firecracker-microvm/firecracker/tree/main/docs)
- [Firecracker Getting Started](https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md)
- [Ubuntu Cloud Images](https://cloud-images.ubuntu.com/)
- [Felipe Cruz's Blog Post](https://www.felipecruz.es/exploring-firecracker-microvms-for-multi-tenant-dagger-ci-cd-pipelines/)
