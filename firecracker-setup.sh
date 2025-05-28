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
VM_IP="172.20.0.2"
HOST_IP="172.20.0.1"
ROOTFS_SIZE="10G"
SSH_KEY_PATH="${WORK_DIR}/vm_key"

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

check_dependencies() {
    print_header "Checking Dependencies"
    
    local deps=("curl" "qemu-img" "debootstrap" "firecracker" "ssh-keygen")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Install them with:"
        print_info "  Ubuntu/Debian: sudo apt update && sudo apt install -y curl qemu-utils debootstrap openssh-client"
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
    print_header "Downloading Kernel"
    
    local kernel_file="vmlinux-${KERNEL_VERSION}"
    
    if [ ! -f "${kernel_file}" ]; then
        print_info "Downloading Firecracker kernel ${KERNEL_VERSION}..."
        
        # Download the appropriate kernel based on version
        case "${KERNEL_VERSION}" in
            "6.1.128")
                curl -fsSL -o "${kernel_file}" \
                    "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.12/x86_64/vmlinux-6.1.128"
                    
                ;;
            "6.1.55"|"6.1")
                curl -fsSL -o "${kernel_file}" \
                    "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.7/x86_64/vmlinux-6.1.55"
                ;;
            "5.10")
                curl -fsSL -o "${kernel_file}" \
                    "https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin"
                ;;
            *)
                print_error "Unsupported kernel version: ${KERNEL_VERSION}"
                print_info "Supported versions: 5.10, 6.1.55, 6.1.128"
                print_info "You can also manually place a kernel file at ${kernel_file}"
                exit 1
                ;;
        esac
        
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
        sudo debootstrap --include=openssh-server,curl,wget,vim,htop,net-tools,iputils-ping,systemd,init,udev,kmod,sudo,bash-completion,ca-certificates,gnupg,lsb-release \
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
Address=${VM_IP}/24
Gateway=${HOST_IP}
DNS=8.8.8.8
DNS=8.8.4.4
EOF
        
        # Enable systemd-networkd
        sudo chroot "${mount_dir}" systemctl enable systemd-networkd
        
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
        
        # Configure SSH server
        sudo tee "${mount_dir}/etc/ssh/sshd_config.d/firecracker.conf" > /dev/null <<EOF
PermitRootLogin yes
PasswordAuthentication no
PubkeyAuthentication yes
EOF
        
        # Enable SSH service
        sudo chroot "${mount_dir}" systemctl enable ssh
        
        # Set up console auto-login for root
        sudo mkdir -p "${mount_dir}/etc/systemd/system/serial-getty@ttyS0.service.d"
        sudo tee "${mount_dir}/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" > /dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root -o '-p -- \\u' --keep-baud 115200,38400,9600 %I \$TERM
EOF
        
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
    
    # Check if tap device already exists
    if ip link show "${TAP_DEVICE}" &> /dev/null; then
        print_info "TAP device ${TAP_DEVICE} already exists"
        return
    fi
    
    print_info "Creating TAP device: ${TAP_DEVICE}"
    
    # Create TAP device
    sudo ip tuntap add dev "${TAP_DEVICE}" mode tap user "$(whoami)"
    
    # Configure TAP device
    sudo ip addr add "${HOST_IP}/24" dev "${TAP_DEVICE}"
    sudo ip link set dev "${TAP_DEVICE}" up
    
    # Enable IP forwarding
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
    
    # Set up iptables rules for NAT
    sudo iptables -t nat -A POSTROUTING -s "${HOST_IP%.*}.0/24" ! -o "${TAP_DEVICE}" -j MASQUERADE
    sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -A FORWARD -i "${TAP_DEVICE}" -o "${TAP_DEVICE}" -j ACCEPT
    
    print_info "Networking configured"
    print_info "Host IP: ${HOST_IP}"
    print_info "VM IP: ${VM_IP}"
}

create_vm_config() {
    print_header "Creating VM Configuration"
    
    local config_file="vm-config-${VM_ID}.json"
    
    cat > "${config_file}" <<EOF
{
  "boot-source": {
    "kernel_image_path": "${WORK_DIR}/vmlinux-${KERNEL_VERSION}",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off nomodules rw ip=${VM_IP}::${HOST_IP}:255.255.255.0::eth0:off"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "${WORK_DIR}/ubuntu-24.04-rootfs.ext4",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "guest_mac": "AA:FC:00:00:00:01",
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
            \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off nomodules rw ip=${VM_IP}::${HOST_IP}:255.255.255.0::eth0:off\"
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
    
    # Configure network interface
    curl -X PUT \
        --unix-socket "${SOCKET_PATH}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{
            \"iface_id\": \"eth0\",
            \"guest_mac\": \"AA:FC:00:00:00:01\",
            \"host_dev_name\": \"${TAP_DEVICE}\"
        }" \
        http://localhost/network-interfaces/eth0 > /dev/null
    
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
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if ssh -i "${SSH_KEY_PATH}" -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@"${VM_IP}" 'echo "SSH is ready"' &> /dev/null; then
            print_info "SSH is ready!"
            return 0
        fi
        
        print_info "Attempt ${attempt}/${max_attempts}: Waiting for SSH..."
        sleep 2
        ((attempt++))
    done
    
    print_warning "SSH did not become ready within the timeout period"
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
    
    check_dependencies
    setup_workspace
    download_kernel
    create_ubuntu_rootfs
    setup_networking
    create_vm_config
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