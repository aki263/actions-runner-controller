#!/bin/bash

set -euo pipefail

# Configuration variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/firecracker-vm"
KERNEL_VERSION="6.1.128"
VM_MEMORY="1024"
VM_CPUS="2"
VM_ID="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)"
SOCKET_PATH="${WORK_DIR}/firecracker-${VM_ID}.socket"
TAP_DEVICE="tap-${VM_ID}"
VM_IP="172.16.0.2"
HOST_IP="172.16.0.1"
MASK_SHORT="/30"
FC_MAC="06:00:AC:10:00:02"
ROOTFS_SIZE="10G"
SSH_KEY_PATH="${WORK_DIR}/vm_key"
CUSTOM_KERNEL=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_os() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        print_error "This script requires Ubuntu 24.04 or compatible Linux distribution with KVM support."
        print_error "macOS is not supported as Firecracker requires Linux KVM."
        print_info ""
        print_info "Options for macOS users:"
        print_info "1. Use a Linux VM (VMware Fusion, Parallels, VirtualBox)"
        print_info "2. Use Docker Desktop with Linux containers"
        print_info "3. Use a cloud Linux instance (AWS EC2, Google Cloud, etc.)"
        print_info "4. Use the provided Docker setup: ./macos-docker-setup.sh"
        print_info ""
        print_info "For Docker option, run: ./macos-docker-setup.sh"
        exit 1
    fi
    
    if [[ "$(uname -s)" != "Linux" ]]; then
        print_error "This script requires Ubuntu 24.04 or compatible Linux distribution."
        print_error "Detected OS: $(uname -s)"
        exit 1
    fi
    
    # Check if running on Ubuntu (optional warning)
    if command -v lsb_release &> /dev/null; then
        local distro
        distro=$(lsb_release -si 2>/dev/null)
        if [[ "$distro" != "Ubuntu" ]]; then
            print_warning "This script is designed for Ubuntu 24.04. Detected: $distro"
            print_warning "Some commands may need adjustment for your distribution."
        fi
    fi
}

check_dependencies() {
    print_header "Checking Dependencies"
    
    local deps=("curl" "qemu-img" "debootstrap" "firecracker" "ssh-keygen")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    # Check for ISO creation tools
    if ! command -v genisoimage &> /dev/null && ! command -v mkisofs &> /dev/null; then
        missing_deps+=("genisoimage")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Install them with:"
        print_info "  Ubuntu/Debian: sudo apt update && sudo apt install -y curl qemu-utils debootstrap openssh-client genisoimage"
        print_info "  Firecracker: curl -LOJ https://github.com/firecracker-microvm/firecracker/releases/latest/download/firecracker-v*-x86_64.tgz && tar -xzf firecracker-*.tgz && sudo mv release-*/firecracker-* /usr/local/bin/firecracker"
        exit 1
    fi
    
    # Check KVM access
    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        print_error "Cannot access /dev/kvm. Make sure KVM is enabled and you have permissions."
        print_info "Run: sudo usermod -a -G kvm \$USER && newgrp kvm"
        exit 1
    fi
    
    print_info "All dependencies are satisfied"
}

setup_workspace() {
    print_header "Setting Up Workspace"
    
    mkdir -p "${WORK_DIR}"
    cd "${WORK_DIR}"
    
    print_info "Workspace created at: ${WORK_DIR}"
}

download_kernel() {
    print_header "Setting Up Kernel"
    
    local kernel_file="vmlinux-${KERNEL_VERSION}"
    
    # If custom kernel is specified, use it
    if [ -n "${CUSTOM_KERNEL}" ]; then
        if [ ! -f "${CUSTOM_KERNEL}" ]; then
            print_error "Custom kernel file not found: ${CUSTOM_KERNEL}"
            exit 1
        fi
        
        print_info "Using custom kernel: ${CUSTOM_KERNEL}"
        
        # Copy custom kernel to work directory with expected name
        cp "${CUSTOM_KERNEL}" "${kernel_file}"
        print_info "Custom kernel copied to: ${kernel_file}"
        return 0
    fi
    
    # Download kernel if not using custom one
    if [ ! -f "${kernel_file}" ]; then
        print_info "Downloading Firecracker kernel ${KERNEL_VERSION}..."
        
        curl -fsSL -o "${kernel_file}" \
            "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.12/x86_64/vmlinux-6.1.128"
        
        print_info "Kernel downloaded: ${kernel_file}"
    else
        print_info "Kernel already exists: ${kernel_file}"
    fi
}

create_ubuntu_rootfs() {
    print_header "Creating Ubuntu 24.04 Root Filesystem"
    
    local rootfs_file="ubuntu-24.04-rootfs.ext4"
    
    if [ ! -f "${rootfs_file}" ]; then
        print_info "Creating ${ROOTFS_SIZE} Ubuntu 24.04 rootfs..."
        
        # Create raw disk image
        qemu-img create -f raw "${rootfs_file}" "${ROOTFS_SIZE}"
        
        # Format with ext4
        mkfs.ext4 "${rootfs_file}"
        
        # Create mount point
        local mount_dir="rootfs_mount"
        mkdir -p "${mount_dir}"
        
        print_info "Mounting rootfs for setup..."
        sudo mount "${rootfs_file}" "${mount_dir}"
        
        # Create Ubuntu 24.04 rootfs using debootstrap
        print_info "Installing Ubuntu 24.04 base system (this may take a while)..."
        sudo debootstrap --include=openssh-server,curl,wget,vim,htop,net-tools,iputils-ping,systemd,init,udev,kmod,sudo,bash-completion,ca-certificates,gnupg,lsb-release,cloud-init \
            noble "${mount_dir}" http://archive.ubuntu.com/ubuntu/
        
        # Configure the rootfs
        print_info "Configuring the rootfs..."
        
        # Set hostname
        echo "firecracker-vm" | sudo tee "${mount_dir}/etc/hostname" > /dev/null
        
        # Configure network
        sudo tee "${mount_dir}/etc/systemd/network/eth0.network" > /dev/null <<EOF
[Match]
Name=eth0

[Network]
Address=${VM_IP}/30
Gateway=${HOST_IP}
DNS=8.8.8.8
DNS=8.8.4.4

[Route]
Destination=0.0.0.0/0
Gateway=${HOST_IP}
EOF
        
        # Enable systemd-networkd and disable NetworkManager
        sudo chroot "${mount_dir}" systemctl enable systemd-networkd
        sudo chroot "${mount_dir}" systemctl enable systemd-resolved
        sudo chroot "${mount_dir}" systemctl disable NetworkManager 2>/dev/null || true
        
        # Create resolv.conf symlink for systemd-resolved
        sudo chroot "${mount_dir}" ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        
        # Configure SSH
        sudo mkdir -p "${mount_dir}/root/.ssh"
        sudo chmod 700 "${mount_dir}/root/.ssh"
        
        # Generate SSH key if it doesn't exist
        if [ ! -f "${SSH_KEY_PATH}" ]; then
            ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N "" -C "firecracker-vm"
            print_info "SSH key generated: ${SSH_KEY_PATH}"
        fi
        
        # Copy public key to VM
        sudo cp "${SSH_KEY_PATH}.pub" "${mount_dir}/root/.ssh/authorized_keys"
        sudo chmod 600 "${mount_dir}/root/.ssh/authorized_keys"
        sudo chown root:root "${mount_dir}/root/.ssh/authorized_keys"
        
        # Configure SSH server
        sudo tee "${mount_dir}/etc/ssh/sshd_config.d/firecracker.conf" > /dev/null <<EOF
PermitRootLogin yes
PasswordAuthentication no
PubkeyAuthentication yes
Port 22
AddressFamily inet
ListenAddress 0.0.0.0
EOF
        
        # Enable SSH service
        sudo chroot "${mount_dir}" systemctl enable ssh
        
        # Create a network startup script to ensure networking is ready
        sudo tee "${mount_dir}/etc/systemd/system/firecracker-network.service" > /dev/null <<EOF
[Unit]
Description=Firecracker Network Setup
After=systemd-networkd.service
Wants=systemd-networkd.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ip link set eth0 up && systemctl restart systemd-networkd'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        
        sudo chroot "${mount_dir}" systemctl enable firecracker-network.service
        
        # Set up console auto-login for root (for debugging)
        sudo mkdir -p "${mount_dir}/etc/systemd/system/serial-getty@ttyS0.service.d"
        sudo tee "${mount_dir}/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" > /dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root -o '-p -- \\u' --keep-baud 115200,38400,9600 %I \$TERM
EOF
        
        # Create a network debugging script
        sudo tee "${mount_dir}/root/debug-network.sh" > /dev/null <<'EOF'
#!/bin/bash
echo "=== Network Debug Information ==="
echo "Date: $(date)"
echo ""
echo "Network interfaces:"
ip addr show
echo ""
echo "Routing table:"
ip route show
echo ""
echo "DNS configuration:"
cat /etc/resolv.conf
echo ""
echo "SSH service status:"
systemctl status ssh --no-pager
echo ""
echo "Network service status:"
systemctl status systemd-networkd --no-pager
echo ""
echo "Testing connectivity:"
echo "  Ping gateway (${HOST_IP}):"
ping -c 3 172.20.0.1 || echo "  Gateway ping failed"
echo "  Ping DNS (8.8.8.8):"
ping -c 3 8.8.8.8 || echo "  DNS ping failed"
echo "================================="
EOF
        
        sudo chmod +x "${mount_dir}/root/debug-network.sh"
        
        # Create a simple welcome script
        sudo tee "${mount_dir}/root/welcome.sh" > /dev/null <<'EOF'
#!/bin/bash
echo "=============================================="
echo "Welcome to Firecracker Ubuntu 24.04 VM!"
echo "=============================================="
echo "VM IP: $(ip addr show eth0 | grep -oP 'inet \K[\d.]+')"
echo "SSH: ssh -i /path/to/vm_key root@$(ip addr show eth0 | grep -oP 'inet \K[\d.]+')"
echo "=============================================="
echo "To install packages:"
echo "  apt update && apt install <package>"
echo "=============================================="
EOF
        
        sudo chmod +x "${mount_dir}/root/welcome.sh"
        
        # Add welcome script to bashrc
        echo "/root/welcome.sh" | sudo tee -a "${mount_dir}/root/.bashrc" > /dev/null
        
        # Clean up
        sudo umount "${mount_dir}"
        rmdir "${mount_dir}"
        
        print_info "Ubuntu 24.04 rootfs created: ${rootfs_file}"
    else
        print_info "Rootfs already exists: ${rootfs_file}"
    fi
}

setup_networking() {
    print_header "Setting Up Networking"
    
    # Remove existing TAP device if it exists
    sudo ip link del "${TAP_DEVICE}" 2> /dev/null || true
    
    print_info "Creating TAP device: ${TAP_DEVICE}"
    
    # Create TAP device (following official guide)
    sudo ip tuntap add dev "${TAP_DEVICE}" mode tap
    sudo ip addr add "${HOST_IP}${MASK_SHORT}" dev "${TAP_DEVICE}"
    sudo ip link set dev "${TAP_DEVICE}" up
    
    # Enable IP forwarding
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
    
    # Make IP forwarding persistent
    echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf > /dev/null || true
    
    # Set up iptables rules (following official guide)
    print_info "Setting up iptables rules for internet access..."
    
    # Accept forwarding
    sudo iptables -P FORWARD ACCEPT
    
    # Determine host network interface for internet access
    local host_iface
    host_iface=$(ip -j route list default | jq -r '.[0].dev' 2>/dev/null || ip route | grep default | awk '{print $5}' | head -1)
    
    if [ -z "$host_iface" ]; then
        print_warning "Could not determine host network interface. Using eth0 as fallback."
        host_iface="eth0"
    fi
    
    print_info "Using host interface: ${host_iface}"
    
    # Remove existing MASQUERADE rule if it exists
    sudo iptables -t nat -D POSTROUTING -o "$host_iface" -j MASQUERADE 2>/dev/null || true
    
    # Add MASQUERADE rule for internet access
    sudo iptables -t nat -A POSTROUTING -o "$host_iface" -j MASQUERADE
    
    print_info "Networking configured"
    print_info "Host IP: ${HOST_IP}${MASK_SHORT}"
    print_info "VM IP: ${VM_IP}"
    print_info "TAP device: ${TAP_DEVICE}"
    print_info "Host interface: ${host_iface}"
}

create_vm_config() {
    print_header "Creating VM Configuration"
    
    local config_file="vm-config-${VM_ID}.json"
    
    cat > "${config_file}" <<EOF
{
  "boot-source": {
    "kernel_image_path": "${WORK_DIR}/vmlinux-${KERNEL_VERSION}",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off nomodules rw root=/dev/vda rootfstype=ext4 ip=${VM_IP}::${HOST_IP}:255.255.255.0::eth0:on"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "${WORK_DIR}/ubuntu-24.04-rootfs.ext4",
      "is_root_device": true,
      "is_read_only": false
    },
    {
      "drive_id": "cloudinit",
      "path_on_host": "${WORK_DIR}/cloud-init.iso",
      "is_root_device": false,
      "is_read_only": true
    }
  ],
  "network-interfaces": [
    {
      "iface_id": "net1",
      "guest_mac": "${FC_MAC}",
      "host_dev_name": "${TAP_DEVICE}"
    }
  ],
  "machine-config": {
    "vcpu_count": ${VM_CPUS},
    "mem_size_mib": ${VM_MEMORY}
  }
}
EOF
    
    print_info "VM configuration created: ${config_file}"
}

start_firecracker() {
    print_header "Starting Firecracker VM"
    
    local config_file="vm-config-${VM_ID}.json"
    
    # Remove existing socket if it exists
    rm -f "${SOCKET_PATH}"
    
    print_info "Starting Firecracker process..."
    firecracker --api-sock "${SOCKET_PATH}" &
    local firecracker_pid=$!
    
    # Wait a moment for Firecracker to start
    sleep 2
    
    print_info "Configuring VM via API..."
    
    # Configure machine settings
    curl -X PUT \
        --unix-socket "${SOCKET_PATH}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{
            \"vcpu_count\": ${VM_CPUS},
            \"mem_size_mib\": ${VM_MEMORY}
        }" \
        http://localhost/machine-config > /dev/null
    
    # Configure boot source
    curl -X PUT \
        --unix-socket "${SOCKET_PATH}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{
            \"kernel_image_path\": \"${WORK_DIR}/vmlinux-${KERNEL_VERSION}\",
            \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off nomodules rw root=/dev/vda rootfstype=ext4 ip=${VM_IP}::${HOST_IP}:255.255.255.0::eth0:on\"
        }" \
        http://localhost/boot-source > /dev/null
    
    # Configure rootfs drive
    curl -X PUT \
        --unix-socket "${SOCKET_PATH}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{
            \"drive_id\": \"rootfs\",
            \"path_on_host\": \"${WORK_DIR}/ubuntu-24.04-rootfs.ext4\",
            \"is_root_device\": true,
            \"is_read_only\": false
        }" \
        http://localhost/drives/rootfs > /dev/null
    
    # Configure cloud-init drive
    curl -X PUT \
        --unix-socket "${SOCKET_PATH}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{
            \"drive_id\": \"cloudinit\",
            \"path_on_host\": \"${WORK_DIR}/cloud-init.iso\",
            \"is_root_device\": false,
            \"is_read_only\": true
        }" \
        http://localhost/drives/cloudinit > /dev/null
    
    # Configure network interface
    curl -X PUT \
        --unix-socket "${SOCKET_PATH}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{
            \"iface_id\": \"net1\",
            \"guest_mac\": \"${FC_MAC}\",
            \"host_dev_name\": \"${TAP_DEVICE}\"
        }" \
        http://localhost/network-interfaces/net1 > /dev/null
    
    # Start the VM
    print_info "Booting the VM..."
    curl -X PUT \
        --unix-socket "${SOCKET_PATH}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d '{"action_type": "InstanceStart"}' \
        http://localhost/actions > /dev/null
    
    echo "${firecracker_pid}" > "firecracker-${VM_ID}.pid"
    
    print_info "Firecracker VM started!"
    print_info "VM ID: ${VM_ID}"
    print_info "PID: ${firecracker_pid}"
}

wait_for_ssh() {
    print_header "Waiting for SSH to be Ready"
    
    local max_attempts=3
    local attempt=1
    
    print_info "Testing network connectivity first..."
    
    # Wait for VM to boot and network to be ready
    sleep 10
    
    while [ $attempt -le $max_attempts ]; do
        # Test basic connectivity first
        if ping -c 1 -W 2 "${VM_IP}" &> /dev/null; then
            print_info "VM is reachable via ping"
            
            # Test SSH connectivity
            if ssh -i "${SSH_KEY_PATH}" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${VM_IP}" 'echo "SSH is ready"' &> /dev/null; then
                print_info "SSH is ready!"
                return 0
            else
                print_info "VM is pingable but SSH not ready yet..."
            fi
        else
            print_info "VM not yet reachable via ping..."
        fi
        
        print_info "Attempt ${attempt}/${max_attempts}: Waiting for SSH..."
        sleep 3
        ((attempt++))
    done
    
    print_warning "SSH did not become ready within the timeout period"
    print_info "Debugging information:"
    print_info "  VM IP: ${VM_IP}"
    print_info "  Host IP: ${HOST_IP}"
    print_info "  TAP device: ${TAP_DEVICE}"
    
    # Show network status
    if ip link show "${TAP_DEVICE}" &> /dev/null; then
        print_info "  TAP device status: UP"
        ip addr show "${TAP_DEVICE}" | grep inet || true
    else
        print_warning "  TAP device not found!"
    fi
    
    # Test manual ping
    print_info "Testing manual ping to VM..."
    ping -c 3 "${VM_IP}" || print_warning "Ping failed"
    
    return 1
}

show_connection_info() {
    print_header "Connection Information"
    
    echo -e "${GREEN}VM Details:${NC}"
    echo "  VM ID: ${VM_ID}"
    echo "  VM IP: ${VM_IP}"
    echo "  Host IP: ${HOST_IP}"
    echo "  Memory: ${VM_MEMORY} MB"
    echo "  CPUs: ${VM_CPUS}"
    echo "  Rootfs Size: ${ROOTFS_SIZE}"
    echo ""
    
    echo -e "${GREEN}SSH Connection:${NC}"
    echo "  ssh -i \"${SSH_KEY_PATH}\" root@${VM_IP}"
    echo ""
    
    echo -e "${GREEN}VM Management:${NC}"
    echo "  Stop VM: ${SCRIPT_DIR}/firecracker-manage.sh stop ${VM_ID}"
    echo "  VM status: ${SCRIPT_DIR}/firecracker-manage.sh status ${VM_ID}"
    echo "  Resize rootfs: ${SCRIPT_DIR}/firecracker-manage.sh resize ${VM_ID} <new_size>"
    echo ""
    
    echo -e "${GREEN}Files Created:${NC}"
    echo "  SSH private key: ${SSH_KEY_PATH}"
    echo "  SSH public key: ${SSH_KEY_PATH}.pub"
    echo "  VM config: ${WORK_DIR}/vm-config-${VM_ID}.json"
    echo "  Rootfs: ${WORK_DIR}/ubuntu-24.04-rootfs.ext4"
    echo "  PID file: ${WORK_DIR}/firecracker-${VM_ID}.pid"
}

increase_rootfs_size() {
    local new_size="${1:-20G}"
    print_header "Increasing Rootfs Size to ${new_size}"
    
    local rootfs_file="ubuntu-24.04-rootfs.ext4"
    
    if [ ! -f "${rootfs_file}" ]; then
        print_error "Rootfs file not found: ${rootfs_file}"
        return 1
    fi
    
    print_info "Resizing ${rootfs_file} to ${new_size}..."
    qemu-img resize "${rootfs_file}" "${new_size}"
    
    print_info "Expanding filesystem..."
    e2fsck -f "${rootfs_file}" || true
    resize2fs "${rootfs_file}"
    
    print_info "Rootfs resized to ${new_size}"
}

create_cloud_init_config() {
    print_header "Creating Cloud-Init Configuration"
    
    local cloud_init_dir="${WORK_DIR}/cloud-init"
    mkdir -p "${cloud_init_dir}"
    
    # Generate SSH key if it doesn't exist
    if [ ! -f "${SSH_KEY_PATH}" ]; then
        ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N "" -C "firecracker-vm"
        print_info "SSH key generated: ${SSH_KEY_PATH}"
    fi
    
    local ssh_public_key
    ssh_public_key=$(cat "${SSH_KEY_PATH}.pub")
    
    # Create user-data (cloud-config)
    cat > "${cloud_init_dir}/user-data" <<EOF
#cloud-config

# Set hostname
hostname: firecracker-vm
fqdn: firecracker-vm.local

# Configure users
users:
  - name: root
    ssh_authorized_keys:
      - ${ssh_public_key}
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
  - name: ubuntu
    ssh_authorized_keys:
      - ${ssh_public_key}
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    lock_passwd: false
    passwd: \$6\$rounds=4096\$saltsalt\$L9.LKkHxeed8Kn9.Qa1ykj7LMEqKVYxf1XkN1H2xKcNlKjY1K2K3K4K5K6K7K8K9K0

# SSH configuration
ssh_pwauth: false
disable_root: false

# Package updates and installs
package_update: true
package_upgrade: false
packages:
  - htop
  - curl
  - wget
  - vim
  - net-tools
  - iputils-ping

# Network configuration
network:
  version: 2
  ethernets:
    eth0:
      addresses:
        - ${VM_IP}/30
      routes:
        - to: default
          via: ${HOST_IP}
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4

# Write files
write_files:
  - path: /root/welcome.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      echo "=============================================="
      echo "Welcome to Firecracker Ubuntu 24.04 VM!"
      echo "=============================================="
      echo "VM IP: \$(ip addr show eth0 | grep -oP 'inet \\K[\\d.]+')"
      echo "SSH: ssh -i /path/to/vm_key root@\$(ip addr show eth0 | grep -oP 'inet \\K[\\d.]+')"
      echo "=============================================="
      echo "To install packages:"
      echo "  apt update && apt install <package>"
      echo "=============================================="
  
  - path: /root/debug-network.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      echo "=== Network Debug Information ==="
      echo "Date: \$(date)"
      echo ""
      echo "Network interfaces:"
      ip addr show
      echo ""
      echo "Routing table:"
      ip route show
      echo ""
      echo "DNS configuration:"
      cat /etc/resolv.conf
      echo ""
      echo "SSH service status:"
      systemctl status ssh --no-pager
      echo ""
      echo "Cloud-init status:"
      cloud-init status
      echo ""
      echo "Testing connectivity:"
      echo "  Ping gateway (${HOST_IP}):"
      ping -c 3 ${HOST_IP} || echo "  Gateway ping failed"
      echo "  Ping DNS (8.8.8.8):"
      ping -c 3 8.8.8.8 || echo "  DNS ping failed"
      echo "================================="

  - path: /root/setup-network.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Post-boot network setup as per Firecracker official guide
      echo "Setting up network routes and DNS..."
      
      # Add default route (as per official guide)
      ip route add default via ${HOST_IP} dev eth0 2>/dev/null || echo "Default route already exists"
      
      # Setup DNS resolution (as per official guide)
      echo 'nameserver 8.8.8.8' > /etc/resolv.conf
      echo 'nameserver 8.8.4.4' >> /etc/resolv.conf
      
      # Test connectivity
      echo "Testing connectivity:"
      ping -c 2 ${HOST_IP} && echo "Gateway reachable" || echo "Gateway unreachable"
      ping -c 2 8.8.8.8 && echo "Internet reachable" || echo "Internet unreachable"

# Run commands
runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  - systemctl enable systemd-networkd
  - systemctl start systemd-networkd
  - echo '/root/welcome.sh' >> /root/.bashrc
  - /root/setup-network.sh

# Final message
final_message: "Firecracker VM is ready! SSH: ssh -i /path/to/vm_key root@${VM_IP}"
EOF

    # Create meta-data
    cat > "${cloud_init_dir}/meta-data" <<EOF
instance-id: firecracker-vm-${VM_ID}
local-hostname: firecracker-vm
EOF

    # Create network-config (optional, as we're using user-data network config)
    cat > "${cloud_init_dir}/network-config" <<EOF
version: 2
ethernets:
  eth0:
    addresses:
      - ${VM_IP}/30
    gateway4: ${HOST_IP}
    routes:
      - to: default
        via: ${HOST_IP}
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
EOF

    print_info "Cloud-init configuration created in: ${cloud_init_dir}"
}

create_cloud_init_iso() {
    print_header "Creating Cloud-Init ISO"
    
    local cloud_init_dir="${WORK_DIR}/cloud-init"
    local cloud_init_iso="${WORK_DIR}/cloud-init.iso"
    
    if [ ! -d "${cloud_init_dir}" ]; then
        print_error "Cloud-init directory not found. Run create_cloud_init_config first."
        exit 1
    fi
    
    # Check if genisoimage or mkisofs is available
    if command -v genisoimage &> /dev/null; then
        local iso_cmd="genisoimage"
    elif command -v mkisofs &> /dev/null; then
        local iso_cmd="mkisofs"
    else
        print_error "Neither genisoimage nor mkisofs found. Install with: sudo apt install genisoimage"
        exit 1
    fi
    
    print_info "Creating cloud-init ISO with ${iso_cmd}..."
    
    # Create ISO with cloud-init data
    ${iso_cmd} -output "${cloud_init_iso}" \
        -volid cidata \
        -joliet \
        -rock \
        "${cloud_init_dir}/user-data" \
        "${cloud_init_dir}/meta-data" \
        "${cloud_init_dir}/network-config"
    
    print_info "Cloud-init ISO created: ${cloud_init_iso}"
    print_info "ISO size: $(du -h "${cloud_init_iso}" | cut -f1)"
}

main() {
    print_header "Firecracker VM Setup"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --memory|-m)
                VM_MEMORY="$2"
                shift 2
                ;;
            --cpus|-c)
                VM_CPUS="$2"
                shift 2
                ;;
            --rootfs-size|-s)
                ROOTFS_SIZE="$2"
                shift 2
                ;;
            --custom-kernel|-k)
                CUSTOM_KERNEL="$2"
                shift 2
                ;;
            --resize-only)
                increase_rootfs_size "$2"
                exit 0
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --memory, -m <size>     VM memory in MB (default: 1024)"
                echo "  --cpus, -c <count>      Number of CPUs (default: 2)"
                echo "  --rootfs-size, -s <size> Root filesystem size (default: 10G)"
                echo "  --custom-kernel, -k <path> Use custom kernel instead of downloading"
                echo "  --resize-only <size>    Only resize existing rootfs"
                echo "  --help, -h              Show this help"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    check_os
    check_dependencies
    setup_workspace
    download_kernel
    create_ubuntu_rootfs
    setup_networking
    create_vm_config
    create_cloud_init_config
    create_cloud_init_iso
    start_firecracker
    
    sleep 5  # Give the VM time to boot
    
    if wait_for_ssh; then
        show_connection_info
        print_info "VM is ready! You can now SSH into it."
    else
        show_connection_info
        print_warning "VM started but SSH is not ready yet. Try connecting manually."
    fi
}

# Run main function
main "$@" 