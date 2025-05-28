#!/bin/bash

# Firecracker Environment Setup Script for Actions Runner Controller
# This script sets up the complete Firecracker environment for GitHub Actions runners

set -e

# Configuration
FIRECRACKER_VERSION="v1.6.0"
IMAGES_DIR="/var/lib/firecracker/images"
WORK_DIR="/tmp/firecracker-setup"
UBUNTU_VERSION="20.04"
TAP_INTERFACE="tap0"
VM_SUBNET="172.16.0.0/24"
VM_GATEWAY="172.16.0.1"
PRIMARY_INTERFACE="eth0"  # Change this to your primary network interface

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Install required packages
install_dependencies() {
    log_info "Installing required packages..."
    apt-get update
    apt-get install -y curl wget tar qemu-utils genisoimage bridge-utils iptables-persistent
}

# Download and install Firecracker
install_firecracker() {
    log_info "Installing Firecracker ${FIRECRACKER_VERSION}..."
    
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # Download Firecracker
    if [[ ! -f "firecracker-${FIRECRACKER_VERSION}-x86_64.tgz" ]]; then
        wget -q "https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_VERSION}/firecracker-${FIRECRACKER_VERSION}-x86_64.tgz"
    fi
    
    # Extract and install
    tar -xzf "firecracker-${FIRECRACKER_VERSION}-x86_64.tgz"
    cp "release-${FIRECRACKER_VERSION}-x86_64/firecracker-${FIRECRACKER_VERSION}-x86_64" /usr/local/bin/firecracker
    chmod +x /usr/local/bin/firecracker
    
    log_info "Firecracker installed successfully: $(firecracker --version)"
}

# Setup network configuration
setup_networking() {
    log_info "Setting up TAP networking..."
    
    # Create TAP interface
    if ! ip link show "$TAP_INTERFACE" &>/dev/null; then
        ip tuntap add dev "$TAP_INTERFACE" mode tap
        log_info "Created TAP interface: $TAP_INTERFACE"
    else
        log_warn "TAP interface $TAP_INTERFACE already exists"
    fi
    
    # Configure IP and bring up
    ip addr add "$VM_GATEWAY/24" dev "$TAP_INTERFACE" 2>/dev/null || true
    ip link set dev "$TAP_INTERFACE" up
    
    # Enable IP forwarding
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-firecracker.conf
    sysctl -p /etc/sysctl.d/99-firecracker.conf
    
    # Setup iptables rules for NAT
    iptables -t nat -C POSTROUTING -o "$PRIMARY_INTERFACE" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$PRIMARY_INTERFACE" -j MASQUERADE
    
    iptables -C FORWARD -i "$TAP_INTERFACE" -o "$PRIMARY_INTERFACE" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$TAP_INTERFACE" -o "$PRIMARY_INTERFACE" -j ACCEPT
    
    iptables -C FORWARD -i "$PRIMARY_INTERFACE" -o "$TAP_INTERFACE" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$PRIMARY_INTERFACE" -o "$TAP_INTERFACE" -j ACCEPT
    
    # Save iptables rules
    netfilter-persistent save
    
    log_info "Network configuration completed"
}

# Download kernel image
download_kernel() {
    log_info "Downloading Firecracker kernel..."
    
    mkdir -p "$IMAGES_DIR"
    cd "$WORK_DIR"
    
    if [[ ! -f "$IMAGES_DIR/vmlinux.bin" ]]; then
        wget -q "https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_VERSION}/vmlinux.bin"
        cp vmlinux.bin "$IMAGES_DIR/"
        log_info "Kernel downloaded to $IMAGES_DIR/vmlinux.bin"
    else
        log_warn "Kernel already exists at $IMAGES_DIR/vmlinux.bin"
    fi
}

# Create rootfs image
create_rootfs() {
    log_info "Creating Ubuntu ${UBUNTU_VERSION} rootfs image..."
    
    cd "$WORK_DIR"
    
    # Download Ubuntu cloud image
    UBUNTU_IMAGE="ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
    if [[ ! -f "$UBUNTU_IMAGE" ]]; then
        log_info "Downloading Ubuntu cloud image..."
        wget -q "https://cloud-images.ubuntu.com/releases/${UBUNTU_VERSION}/release/${UBUNTU_IMAGE}"
    fi
    
    # Convert and resize
    if [[ ! -f "$IMAGES_DIR/ubuntu-${UBUNTU_VERSION}.ext4" ]]; then
        log_info "Converting and resizing image..."
        qemu-img convert -f qcow2 -O raw "$UBUNTU_IMAGE" ubuntu-raw.img
        qemu-img resize ubuntu-raw.img 20G
        
        # Setup loop device and resize filesystem
        LOOP_DEVICE=$(losetup -f)
        losetup "$LOOP_DEVICE" ubuntu-raw.img
        resize2fs "$LOOP_DEVICE"
        losetup -d "$LOOP_DEVICE"
        
        # Copy to final location
        cp ubuntu-raw.img "$IMAGES_DIR/ubuntu-${UBUNTU_VERSION}.ext4"
        log_info "Rootfs created at $IMAGES_DIR/ubuntu-${UBUNTU_VERSION}.ext4"
    else
        log_warn "Rootfs already exists at $IMAGES_DIR/ubuntu-${UBUNTU_VERSION}.ext4"
    fi
}

# Customize rootfs with GitHub Actions runner
customize_rootfs() {
    log_info "Customizing rootfs with GitHub Actions runner..."
    
    local MOUNT_POINT="/mnt/firecracker-root"
    local ROOTFS_IMAGE="$IMAGES_DIR/ubuntu-${UBUNTU_VERSION}.ext4"
    
    # Create mount point
    mkdir -p "$MOUNT_POINT"
    
    # Mount the image
    mount -o loop "$ROOTFS_IMAGE" "$MOUNT_POINT"
    
    # Bind mount system directories
    mount --bind /dev "$MOUNT_POINT/dev"
    mount --bind /proc "$MOUNT_POINT/proc"
    mount --bind /sys "$MOUNT_POINT/sys"
    mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
    
    # Copy resolv.conf for internet access
    cp /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf"
    
    # Create customization script
    cat > "$MOUNT_POINT/tmp/customize.sh" << 'EOF'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

# Update package lists
apt-get update

# Install required packages
apt-get install -y \
    curl \
    jq \
    git \
    docker.io \
    cloud-init \
    sudo \
    systemd \
    openssh-server \
    ca-certificates \
    gnupg \
    lsb-release \
    build-essential \
    libssl-dev \
    libffi-dev \
    python3-dev \
    python3-pip

# Create runner user
if ! id -u runner &>/dev/null; then
    useradd -m -s /bin/bash runner
    usermod -aG sudo,docker runner
    echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
fi

# Pre-download GitHub Actions runner
cd /home/runner
RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/v//')
curl -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz -L \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
tar xzf actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz
rm actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz
chown -R runner:runner /home/runner

# Install runner dependencies
./bin/installdependencies.sh

# Configure cloud-init
cat > /etc/cloud/cloud.cfg.d/99-firecracker.cfg << 'EOL'
# Firecracker VM configuration
datasource_list: [NoCloud]
datasource:
  NoCloud:
    seedfrom: /dev/vdb
cloud_init_modules:
 - migrator
 - seed_random
 - bootcmd
 - write-files
 - growpart
 - resizefs
 - disk_setup
 - mounts
 - set_hostname
 - update_hostname
 - update_etc_hosts
 - ca-certs
 - rsyslog
 - users-groups
cloud_config_modules:
 - emit_upstart
 - ssh-import-id
 - locale
 - set-passwords
 - grub-dpkg
 - apt-pipelining
 - apt-configure
 - ubuntu-advantage
 - ntp
 - timezone
 - disable-ec2-metadata
 - runcmd
 - byobu
cloud_final_modules:
 - package-update-upgrade-install
 - fan
 - landscape
 - lxd
 - ubuntu-drivers
 - puppet
 - chef
 - mcollective
 - salt-minion
 - rightscale_userdata
 - scripts-vendor
 - scripts-per-once
 - scripts-per-boot
 - scripts-per-instance
 - scripts-user
 - ssh-authkey-fingerprints
 - keys-to-console
 - phone-home
 - final-message
 - power-state-change
EOL

# Enable cloud-init services
systemctl enable cloud-init
systemctl enable cloud-init-local
systemctl enable cloud-config
systemctl enable cloud-final

# Enable and start Docker
systemctl enable docker

# Create runner service template
cat > /etc/systemd/system/actions-runner.service.template << 'EOL'
[Unit]
Description=GitHub Actions Runner
After=network.target
Wants=network.target

[Service]
Type=simple
User=runner
WorkingDirectory=/home/runner
ExecStart=/home/runner/run.sh
Restart=always
RestartSec=30
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min

[Install]
WantedBy=multi-user.target
EOL

# Clean up
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*
rm -rf /var/tmp/*

echo "Rootfs customization completed successfully"
EOF

    # Execute customization script in chroot
    chmod +x "$MOUNT_POINT/tmp/customize.sh"
    chroot "$MOUNT_POINT" /tmp/customize.sh
    
    # Clean up mount points
    umount "$MOUNT_POINT/dev/pts" || true
    umount "$MOUNT_POINT/sys" || true
    umount "$MOUNT_POINT/proc" || true
    umount "$MOUNT_POINT/dev" || true
    umount "$MOUNT_POINT"
    
    log_info "Rootfs customization completed"
}

# Create systemd service for VM management
create_vm_service() {
    log_info "Creating VM management service..."
    
    cat > /etc/systemd/system/firecracker-vm-manager.service << 'EOF'
[Unit]
Description=Firecracker VM Manager
After=network.target
Wants=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/firecracker-vm-manager.sh start
ExecStop=/usr/local/bin/firecracker-vm-manager.sh stop
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

    # Create VM manager script
    cat > /usr/local/bin/firecracker-vm-manager.sh << 'EOF'
#!/bin/bash

TAP_INTERFACE="tap0"
VM_SUBNET="172.16.0.0/24"
VM_GATEWAY="172.16.0.1"

case "$1" in
    start)
        echo "Setting up Firecracker VM environment..."
        
        # Ensure TAP interface exists
        if ! ip link show $TAP_INTERFACE &>/dev/null; then
            ip tuntap add dev $TAP_INTERFACE mode tap
            ip addr add $VM_GATEWAY/24 dev $TAP_INTERFACE
            ip link set dev $TAP_INTERFACE up
        fi
        
        # Ensure IP forwarding is enabled
        sysctl -w net.ipv4.ip_forward=1
        
        echo "Firecracker VM environment ready"
        ;;
    stop)
        echo "Cleaning up Firecracker VM environment..."
        
        # Stop all VMs (implementation depends on VM tracking)
        # This would be handled by the Kubernetes controller
        
        echo "Firecracker VM environment stopped"
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac
EOF

    chmod +x /usr/local/bin/firecracker-vm-manager.sh
    systemctl daemon-reload
    systemctl enable firecracker-vm-manager.service
    
    log_info "VM management service created"
}

# Create cloud-init helper script
create_cloudinit_helper() {
    log_info "Creating cloud-init helper script..."
    
    cat > /usr/local/bin/create-cloudinit-iso.sh << 'EOF'
#!/bin/bash

# Create cloud-init ISO for Firecracker VM
# Usage: create-cloudinit-iso.sh <vm-name> <output-path> <cloud-init-yaml>

VM_NAME="$1"
OUTPUT_PATH="$2"
CLOUDINIT_YAML="$3"

if [[ -z "$VM_NAME" || -z "$OUTPUT_PATH" || -z "$CLOUDINIT_YAML" ]]; then
    echo "Usage: $0 <vm-name> <output-path> <cloud-init-yaml>"
    exit 1
fi

TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Create meta-data
cat > meta-data << EOL
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOL

# Write user-data
echo "$CLOUDINIT_YAML" > user-data

# Create ISO
genisoimage -output "$OUTPUT_PATH" -volid cidata -joliet -rock user-data meta-data

# Clean up
rm -rf "$TEMP_DIR"

echo "Cloud-init ISO created: $OUTPUT_PATH"
EOF

    chmod +x /usr/local/bin/create-cloudinit-iso.sh
    log_info "Cloud-init helper script created"
}

# Main installation function
main() {
    log_info "Starting Firecracker environment setup..."
    
    check_root
    install_dependencies
    install_firecracker
    setup_networking
    download_kernel
    create_rootfs
    customize_rootfs
    create_vm_service
    create_cloudinit_helper
    
    log_info "Firecracker environment setup completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Deploy the modified Actions Runner Controller"
    log_info "2. Create a Runner resource - it will now create Firecracker VMs instead of pods"
    log_info "3. Monitor VM creation with: kubectl get firecrackervm"
    log_info ""
    log_info "Configuration files location:"
    log_info "  - Rootfs: $IMAGES_DIR/ubuntu-${UBUNTU_VERSION}.ext4"
    log_info "  - Kernel: $IMAGES_DIR/vmlinux.bin"
    log_info "  - TAP interface: $TAP_INTERFACE"
    log_info "  - VM subnet: $VM_SUBNET"
}

# Run if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 