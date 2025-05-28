# Firecracker VM Setup for Actions Runner Controller

This document describes how to set up and configure Firecracker VMs to replace Kubernetes pods for running GitHub Actions runners.

## Prerequisites

1. **Firecracker Binary**: Install Firecracker on the host system
   ```bash
   # Download and install Firecracker
   wget https://github.com/firecracker-microvm/firecracker/releases/download/v1.6.0/firecracker-v1.6.0-x86_64.tgz
   tar -xzf firecracker-v1.6.0-x86_64.tgz
   sudo cp release-v1.6.0-x86_64/firecracker-v1.6.0-x86_64 /usr/local/bin/firecracker
   sudo chmod +x /usr/local/bin/firecracker
   ```

2. **genisoimage**: Required for creating cloud-init ISOs
   ```bash
   sudo apt-get update
   sudo apt-get install genisoimage
   ```

3. **Network Setup**: Configure TAP networking
   ```bash
   # Create TAP interface
   sudo ip tuntap add dev tap0 mode tap
   sudo ip addr add 172.16.0.1/24 dev tap0
   sudo ip link set dev tap0 up
   
   # Enable IP forwarding
   sudo sysctl net.ipv4.ip_forward=1
   
   # Setup iptables for NAT
   sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
   sudo iptables -A FORWARD -i tap0 -o eth0 -j ACCEPT
   sudo iptables -A FORWARD -i eth0 -o tap0 -j ACCEPT
   ```

## Rootfs Image Preparation

### Option 1: Build Custom Ubuntu Image

1. **Create base Ubuntu image**:
   ```bash
   # Download Ubuntu cloud image
   wget https://cloud-images.ubuntu.com/releases/20.04/release/ubuntu-20.04-server-cloudimg-amd64.img
   
   # Convert to raw format and resize
   qemu-img convert -f qcow2 -O raw ubuntu-20.04-server-cloudimg-amd64.img ubuntu-20.04.raw
   qemu-img resize ubuntu-20.04.raw 10G
   
   # Convert to ext4 filesystem
   sudo losetup /dev/loop0 ubuntu-20.04.raw
   sudo resize2fs /dev/loop0
   sudo losetup -d /dev/loop0
   
   # Copy to Firecracker images directory
   sudo mkdir -p /var/lib/firecracker/images
   sudo cp ubuntu-20.04.raw /var/lib/firecracker/images/ubuntu-20.04.ext4
   ```

2. **Download kernel image**:
   ```bash
   # Download kernel compatible with Firecracker
   wget https://github.com/firecracker-microvm/firecracker/releases/download/v1.6.0/vmlinux.bin
   sudo cp vmlinux.bin /var/lib/firecracker/images/
   ```

### Option 2: Pre-configure Runner Dependencies

To avoid downloading and configuring GitHub Actions runner at boot time, you can pre-install it in the rootfs:

1. **Mount the image and chroot**:
   ```bash
   # Mount the image
   sudo mkdir /mnt/firecracker-root
   sudo mount -o loop /var/lib/firecracker/images/ubuntu-20.04.ext4 /mnt/firecracker-root
   
   # Bind mount system directories
   sudo mount --bind /dev /mnt/firecracker-root/dev
   sudo mount --bind /proc /mnt/firecracker-root/proc
   sudo mount --bind /sys /mnt/firecracker-root/sys
   
   # Chroot into the image
   sudo chroot /mnt/firecracker-root
   ```

2. **Install dependencies inside chroot**:
   ```bash
   # Update package lists
   apt-get update
   
   # Install required packages
   apt-get install -y curl jq git docker.io cloud-init
   
   # Create runner user
   useradd -m -s /bin/bash runner
   usermod -aG sudo runner
   echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
   
   # Pre-download GitHub Actions runner
   cd /home/runner
   curl -o actions-runner-linux-x64-2.311.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.311.0/actions-runner-linux-x64-2.311.0.tar.gz
   tar xzf ./actions-runner-linux-x64-2.311.0.tar.gz
   rm actions-runner-linux-x64-2.311.0.tar.gz
   chown -R runner:runner /home/runner
   
   # Install runner dependencies
   cd /home/runner
   ./bin/installdependencies.sh
   
   # Enable cloud-init services
   systemctl enable cloud-init
   systemctl enable cloud-init-local
   systemctl enable cloud-config
   systemctl enable cloud-final
   
   # Exit chroot
   exit
   ```

3. **Unmount the image**:
   ```bash
   sudo umount /mnt/firecracker-root/sys
   sudo umount /mnt/firecracker-root/proc
   sudo umount /mnt/firecracker-root/dev
   sudo umount /mnt/firecracker-root
   ```

## VM Configuration

The Firecracker VM controller expects the following paths to be available:

- **Rootfs**: `/var/lib/firecracker/images/ubuntu-20.04.ext4`
- **Kernel**: `/var/lib/firecracker/images/vmlinux.bin`
- **Network Interface**: `tap0`

### Controller Configuration

Update the controller configuration to include Firecracker defaults:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: firecracker-config
  namespace: arc-systems
data:
  rootfs-path: "/var/lib/firecracker/images/ubuntu-20.04.ext4"
  kernel-path: "/var/lib/firecracker/images/vmlinux.bin"
  default-memory-mib: "1024"
  default-vcpus: "2"
  network-interface: "tap0"
  subnet-cidr: "172.16.0.0/24"
  gateway: "172.16.0.1"
  base-ip-address: "172.16.0.10"
```

## Cloud-Init Configuration

The VM controller dynamically generates cloud-init configuration that:

1. **Installs Dependencies**: Updates packages and installs required tools
2. **Creates Runner User**: Sets up the runner user with sudo privileges
3. **Downloads GitHub Actions Runner**: Fetches the latest runner binary
4. **Configures Runner**: Sets up the runner with provided token and configuration
5. **Starts Runner Service**: Enables and starts the runner as a systemd service

### Sample Cloud-Init Script

The controller generates cloud-init data similar to this:

```yaml
#cloud-config
package_update: true
packages:
  - curl
  - jq
  - git

write_files:
  - path: /home/runner/setup-runner.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e
      
      # Create runner user if it doesn't exist
      if ! id -u runner &>/dev/null; then
        useradd -m -s /bin/bash runner
        usermod -aG sudo runner
        echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
      fi
      
      # Configure and start GitHub Actions runner
      su - runner -c "
        cd /home/runner
        export RUNNER_ALLOW_RUNASROOT=1
        export RUNNER_NAME='${VM_NAME}'
        export RUNNER_TOKEN='${GITHUB_TOKEN}'
        export RUNNER_URL='${GITHUB_URL}'
        export RUNNER_LABELS='${RUNNER_LABELS}'
        export RUNNER_GROUP='${RUNNER_GROUP}'
        export RUNNER_WORKDIR='/home/runner/_work'
        export RUNNER_EPHEMERAL='true'
        
        ./config.sh --url \$RUNNER_URL --token \$RUNNER_TOKEN --name \$RUNNER_NAME --labels \$RUNNER_LABELS --runnergroup \$RUNNER_GROUP --work \$RUNNER_WORKDIR --ephemeral --unattended
        sudo ./svc.sh install
        sudo ./svc.sh start
      "

runcmd:
  - /home/runner/setup-runner.sh

final_message: "GitHub Actions runner setup complete"
```

## VM Lifecycle

1. **Creation**: Controller creates FirecrackerVM resource
2. **IP Assignment**: VM gets assigned an IP from the configured range
3. **Cloud-Init ISO**: Generated with runner configuration and GitHub token
4. **VM Startup**: Firecracker starts with rootfs, kernel, and cloud-init ISO
5. **Runner Registration**: Cloud-init script configures and starts the runner
6. **Ready State**: VM reports ready when runner is registered and active
7. **Job Execution**: VM handles GitHub Actions workflow jobs
8. **Cleanup**: VM is terminated after job completion (ephemeral mode)

## Monitoring and Troubleshooting

### Check VM Status

```bash
# Check FirecrackerVM resources
kubectl get firecrackervm -n <namespace>

# Describe a specific VM
kubectl describe firecrackervm <vm-name> -n <namespace>

# Check VM logs (if available)
sudo journalctl -u firecracker-<vm-name>
```

### Network Connectivity

```bash
# Check TAP interface
ip addr show tap0

# Test VM connectivity
ping 172.16.0.10  # Replace with VM IP

# Check iptables rules
sudo iptables -t nat -L POSTROUTING
sudo iptables -L FORWARD
```

### Common Issues

1. **VM fails to start**: Check if kernel and rootfs paths exist
2. **Network not working**: Verify TAP interface and iptables rules
3. **Runner not registering**: Check GitHub token and organization/repo permissions
4. **Cloud-init failures**: Examine cloud-init logs in the VM

## Security Considerations

1. **Isolation**: Each VM runs in its own isolated environment
2. **Networking**: VMs use isolated TAP interfaces with controlled routing
3. **Resource Limits**: Memory and CPU limits prevent resource exhaustion
4. **Ephemeral**: VMs are destroyed after job completion
5. **Token Management**: GitHub tokens are injected securely via cloud-init

## Performance Optimization

1. **Pre-built Images**: Use images with pre-installed dependencies
2. **Copy-on-Write**: Use COW filesystems for faster VM creation
3. **Memory Optimization**: Tune memory allocation based on workload requirements
4. **Network Performance**: Use multiple TAP interfaces for parallel VM execution 