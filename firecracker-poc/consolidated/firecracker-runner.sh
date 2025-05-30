#!/bin/bash

# Firecracker GitHub Actions Runner - All-in-One Script
# Builds, snapshots, and launches GitHub Actions runners on Firecracker VMs

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/firecracker-data"
VERSION="1.0.0"

# Default configuration
RUNNER_VERSION="2.324.0"
DOCKER_VERSION="latest"
ROOTFS_SIZE="20G"
VM_MEMORY="2048"
VM_CPUS="2"
RUNNER_LABELS="firecracker,ubuntu-24.04"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_banner() {
    echo -e "${CYAN}"
    echo "================================================================"
    echo "  Firecracker GitHub Actions Runner v${VERSION}"
    echo "  Build → Snapshot → Deploy → Manage"
    echo "================================================================"
    echo -e "${NC}"
}

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
        print_info "To run this:"
        print_info "1. Use a Linux VM (VMware Fusion, Parallels, VirtualBox)"
        print_info "2. Use a cloud Linux instance (AWS EC2, Google Cloud, etc.)"
        print_info "3. Use Docker Desktop with Linux containers"
        exit 1
    fi
    
    if [[ "$(uname -s)" != "Linux" ]]; then
        print_error "This script requires Ubuntu 24.04 or compatible Linux distribution."
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "qemu-img" "debootstrap" "jq" "firecracker" "ssh-keygen")
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
        print_info "Install with: sudo apt update && sudo apt install -y curl qemu-utils debootstrap jq openssh-client genisoimage"
        print_info "For Firecracker: see https://github.com/firecracker-microvm/firecracker/releases"
        exit 1
    fi
    
    # Check KVM access
    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        print_error "Cannot access /dev/kvm. Run: sudo usermod -a -G kvm \$USER && newgrp kvm"
        exit 1
    fi
}

setup_workspace() {
    mkdir -p "${WORK_DIR}"/{images,snapshots,instances}
    cd "${WORK_DIR}"
}

# Build runner image
build_image() {
    print_header "Building GitHub Actions Runner Image"
    
    local image_file="images/actions-runner-ubuntu-24.04.ext4"
    
    if [ -f "${image_file}" ]; then
        print_warning "Image already exists. Use --rebuild to recreate."
        return 0
    fi
    
    print_info "Creating ${ROOTFS_SIZE} runner image..."
    
    # Create and format image
    qemu-img create -f raw "${image_file}" "${ROOTFS_SIZE}"
    mkfs.ext4 "${image_file}"
    
    # Mount and setup
    local mount_dir="tmp_mount"
    mkdir -p "${mount_dir}"
    sudo mount "${image_file}" "${mount_dir}"
    
    print_info "Installing Ubuntu 24.04 with runner dependencies..."
    
    # Install base system with all needed packages
    sudo debootstrap --include=openssh-server,curl,wget,vim,htop,systemd,init,sudo,ca-certificates,cloud-init,jq,unzip,zip,git,iptables \
        noble "${mount_dir}" http://archive.ubuntu.com/ubuntu/
    
    # Configure runner environment
    print_info "Configuring GitHub Actions runner..."
    
    # Create runner user
    sudo chroot "${mount_dir}" useradd -m -s /bin/bash runner
    sudo chroot "${mount_dir}" usermod -aG sudo runner
    echo "runner ALL=(ALL) NOPASSWD:ALL" | sudo tee "${mount_dir}/etc/sudoers.d/runner" > /dev/null
    
    # Install Docker CE (official Docker repository)
    print_info "Installing Docker CE from official repository..."
    
    # Add Docker's official GPG key
    sudo chroot "${mount_dir}" install -m 0755 -d /etc/apt/keyrings
    sudo chroot "${mount_dir}" curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chroot "${mount_dir}" chmod a+r /etc/apt/keyrings/docker.asc
    
    # Add the repository to Apt sources
    sudo chroot "${mount_dir}" bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
    
    # Update package list and install Docker
    sudo chroot "${mount_dir}" apt-get update
    sudo chroot "${mount_dir}" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Add runner user to docker group
    sudo chroot "${mount_dir}" usermod -aG docker runner
    
    # Download and install runner
    local runner_arch="x64"
    [[ "$(uname -m)" == "aarch64" ]] && runner_arch="arm64"
    
    sudo mkdir -p "${mount_dir}/opt/runner"
    sudo curl -fLo "${mount_dir}/tmp/runner.tar.gz" \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz"
    
    sudo chroot "${mount_dir}" bash -c "cd /opt/runner && tar xzf /tmp/runner.tar.gz && rm /tmp/runner.tar.gz"
    sudo chroot "${mount_dir}" bash -c "cd /opt/runner && ./bin/installdependencies.sh"
    sudo chroot "${mount_dir}" chown -R runner:runner /opt/runner
    
    # Create runner service
    sudo tee "${mount_dir}/etc/systemd/system/github-runner.service" > /dev/null <<'EOF'
[Unit]
Description=GitHub Actions Runner
After=network.target

[Service]
Type=simple
User=runner
WorkingDirectory=/opt/runner
ExecStart=/opt/runner/run.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Setup script
    sudo tee "${mount_dir}/usr/local/bin/setup-runner.sh" > /dev/null <<'EOF'
#!/bin/bash
if [ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_URL" ]; then
    echo "Missing GITHUB_TOKEN or GITHUB_URL environment variables"
    exit 1
fi

cd /opt/runner
sudo -u runner ./config.sh \
    --url "$GITHUB_URL" \
    --token "$GITHUB_TOKEN" \
    --name "${RUNNER_NAME:-$(hostname)}" \
    --labels "${RUNNER_LABELS:-firecracker}" \
    --work "/tmp/runner-work" \
    --unattended --replace

systemctl enable github-runner
systemctl start github-runner
EOF
    
    sudo chmod +x "${mount_dir}/usr/local/bin/setup-runner.sh"
    
    # Enable services
    sudo chroot "${mount_dir}" systemctl enable ssh docker
    
    # Cleanup and unmount
    sudo chroot "${mount_dir}" apt-get clean
    sudo umount "${mount_dir}"
    rmdir "${mount_dir}"
    
    local size=$(du -h "${image_file}" | cut -f1)
    print_info "✅ Runner image created: ${image_file} (${size})"
}

# Create snapshot
create_snapshot() {
    local snapshot_name="${1:-runner-$(date +%Y%m%d-%H%M%S)}"
    local image_file="images/actions-runner-ubuntu-24.04.ext4"
    
    print_header "Creating Snapshot: ${snapshot_name}"
    
    if [ ! -f "$image_file" ]; then
        print_error "No runner image found. Run: $0 build"
        exit 1
    fi
    
    local snapshot_dir="${WORK_DIR}/snapshots/${snapshot_name}"
    mkdir -p "$snapshot_dir"
    
    # Copy image
    print_info "Creating snapshot..."
    cp "$image_file" "${snapshot_dir}/rootfs.ext4"
    
    # Create metadata
    cat > "${snapshot_dir}/info.json" <<EOF
{
  "name": "${snapshot_name}",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "runner_version": "${RUNNER_VERSION}",
  "docker_version": "${DOCKER_VERSION}"
}
EOF
    
    # Quick launch script
    cat > "${snapshot_dir}/launch.sh" <<'EOF'
#!/bin/bash
if [ $# -lt 3 ]; then
    echo "Usage: $0 <runner-name> <github-url> <github-token> [labels]"
    exit 1
fi

exec "$(dirname "$(dirname "$0")")/../firecracker-runner.sh" launch \
    --snapshot "$(basename "$(dirname "$0")")" \
    --name "$1" \
    --github-url "$2" \
    --github-token "$3" \
    --labels "${4:-firecracker}"
EOF
    chmod +x "${snapshot_dir}/launch.sh"
    
    local size=$(du -h "$snapshot_dir" | cut -f1)
    print_info "✅ Snapshot created: ${snapshot_dir} (${size})"
    
    # Update registry
    local registry="snapshots/registry.json"
    [ ! -f "$registry" ] && echo '{"snapshots": []}' > "$registry"
    
    local temp=$(mktemp)
    jq --arg name "$snapshot_name" --arg path "$snapshot_dir" \
       '.snapshots += [{"name": $name, "path": $path, "created": "'$(date -u +'%Y-%m-%dT%H:%M:%SZ')'"}]' \
       "$registry" > "$temp" && mv "$temp" "$registry"
}

# Launch VM
launch_vm() {
    local snapshot_name=""
    local runner_name="runner-$(date +%H%M%S)"
    local github_url=""
    local github_token=""
    local labels="firecracker"
    local use_cloud_init=true
    local custom_kernel=""
    local use_dhcp=false
    
    # Parse launch arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --snapshot) snapshot_name="$2"; shift 2 ;;
            --name) runner_name="$2"; shift 2 ;;
            --github-url) github_url="$2"; shift 2 ;;
            --github-token) github_token="$2"; shift 2 ;;
            --labels) labels="$2"; shift 2 ;;
            --memory) VM_MEMORY="$2"; shift 2 ;;
            --cpus) VM_CPUS="$2"; shift 2 ;;
            --kernel) custom_kernel="$2"; shift 2 ;;
            --dhcp) use_dhcp=true; shift ;;
            --no-cloud-init) use_cloud_init=false; shift ;;
            *) print_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    
    if [ "$use_cloud_init" = true ] && ([ -z "$github_url" ] || [ -z "$github_token" ]); then
        print_error "GitHub URL and token are required (or use --no-cloud-init for testing)"
        print_info "Usage: $0 launch --github-url <url> --github-token <token> [options]"
        print_info "   Or: $0 launch --snapshot <name> --no-cloud-init"
        exit 1
    fi
    
    # Find snapshot
    if [ -z "$snapshot_name" ]; then
        local registry="snapshots/registry.json"
        if [ ! -f "$registry" ]; then
            print_error "No snapshots found. Run: $0 snapshot"
            exit 1
        fi
        snapshot_name=$(jq -r '.snapshots | sort_by(.created) | last | .name' "$registry")
    fi
    
    local snapshot_dir="${WORK_DIR}/snapshots/${snapshot_name}"
    if [ ! -d "$snapshot_dir" ]; then
        print_error "Snapshot not found: $snapshot_name"
        exit 1
    fi
    
    print_header "Launching Runner VM: ${runner_name}"
    
    # Setup instance
    local vm_id=$(echo "$runner_name" | tr '[:upper:]' '[:lower:]' | head -c 8)
    local instance_dir="${WORK_DIR}/instances/${vm_id}"
    mkdir -p "$instance_dir"
    cd "$instance_dir"
    
    # Copy snapshot
    cp "${snapshot_dir}/rootfs.ext4" "rootfs.ext4"
    
    # Generate SSH key
    ssh-keygen -t rsa -b 4096 -f "ssh_key" -N "" -C "$runner_name" >/dev/null 2>&1
    
    # Setup networking
    local tap_device="tap-${vm_id}"
    local vm_ip=""
    local host_ip=""
    local subnet_mask="24"
    
    if [ "$use_dhcp" = true ]; then
        print_info "Setting up DHCP networking..."
        
        # Use broader subnet for DHCP
        local network_base="172.16.0"
        host_ip="${network_base}.1"
        
        # Setup TAP device
        sudo ip tuntap add dev "$tap_device" mode tap 2>/dev/null || true
        sudo ip addr add "${host_ip}/${subnet_mask}" dev "$tap_device" 2>/dev/null || true
        sudo ip link set dev "$tap_device" up
        
        # Check if dnsmasq is available for DHCP
        if command -v dnsmasq &> /dev/null; then
            # Kill any existing dnsmasq for this interface
            sudo pkill -f "dnsmasq.*${tap_device}" 2>/dev/null || true
            
            # Start DHCP server (IP range .100-.200)
            sudo dnsmasq \
                --interface="$tap_device" \
                --dhcp-range="${network_base}.100,${network_base}.200,12h" \
                --dhcp-option=3,"$host_ip" \
                --dhcp-option=6,8.8.8.8,8.8.4.4 \
                --pid-file="/tmp/dnsmasq-${tap_device}.pid" \
                --log-dhcp &
            
            vm_ip="dhcp"  # Will be assigned dynamically
            print_info "DHCP server started on ${tap_device} (range: ${network_base}.100-200)"
        else
            print_warning "dnsmasq not found, falling back to static IP"
            use_dhcp=false
        fi
    fi
    
    if [ "$use_dhcp" = false ]; then
        print_info "Setting up static IP networking..."
        
        # Generate unique IP based on VM ID hash
        local ip_suffix=$((16#$(echo "$vm_id" | sha256sum | head -c 2) % 200 + 10))
        if [ $ip_suffix -eq 1 ]; then ip_suffix=10; fi  # Avoid gateway IP
        
        vm_ip="172.16.0.${ip_suffix}"
        host_ip="172.16.0.1"
        
        print_info "Assigned static IP: $vm_ip"
        
        # Setup TAP device
        sudo ip tuntap add dev "$tap_device" mode tap 2>/dev/null || true
        sudo ip addr add "${host_ip}/30" dev "$tap_device" 2>/dev/null || true
        sudo ip link set dev "$tap_device" up
    fi
    
    # Enable forwarding
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
    local host_iface=$(ip route | grep default | awk '{print $5}' | head -1)
    sudo iptables -t nat -A POSTROUTING -o "$host_iface" -j MASQUERADE 2>/dev/null || true
    
    # Configure cloud-init or manual setup
    if [ "$use_cloud_init" = true ]; then
        # Create cloud-init config with network configuration
        mkdir -p cloud-init
        
        if [ "$use_dhcp" = true ]; then
            # DHCP network config
            cat > cloud-init/user-data <<EOF
#cloud-config
hostname: ${runner_name}

# Network configuration (DHCP)
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4

users:
  - name: runner
    ssh_authorized_keys:
      - $(cat ssh_key.pub)
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

# Disable automatic package updates during boot
package_update: false
package_upgrade: false

write_files:
  - path: /etc/environment
    content: |
      GITHUB_TOKEN=${github_token}
      GITHUB_URL=${github_url}
      RUNNER_NAME=${runner_name}
      RUNNER_LABELS=${labels}

runcmd:
  - /usr/local/bin/setup-runner.sh

ssh_pwauth: false
disable_root: false
EOF

            cat > cloud-init/network-config <<EOF
version: 2
ethernets:
  eth0:
    dhcp4: true
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
EOF
        else
            # Static IP network config
            cat > cloud-init/user-data <<EOF
#cloud-config
hostname: ${runner_name}

# Network configuration (Static IP)
network:
  version: 2
  ethernets:
    eth0:
      addresses:
        - ${vm_ip}/30
      routes:
        - to: default
          via: ${host_ip}
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4

users:
  - name: runner
    ssh_authorized_keys:
      - $(cat ssh_key.pub)
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

# Disable automatic package updates during boot
package_update: false
package_upgrade: false

write_files:
  - path: /etc/environment
    content: |
      GITHUB_TOKEN=${github_token}
      GITHUB_URL=${github_url}
      RUNNER_NAME=${runner_name}
      RUNNER_LABELS=${labels}
  - path: /etc/systemd/system/setup-network.service
    content: |
      [Unit]
      Description=Setup Network
      Before=ssh.service
      After=network.target

      [Service]
      Type=oneshot
      ExecStart=/bin/bash -c 'ip addr add ${vm_ip}/30 dev eth0 || true; ip route add default via ${host_ip} || true'
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl enable setup-network
  - systemctl start setup-network
  - /usr/local/bin/setup-runner.sh

ssh_pwauth: false
disable_root: false
EOF

            cat > cloud-init/network-config <<EOF
version: 2
ethernets:
  eth0:
    addresses:
      - ${vm_ip}/30
    routes:
      - to: default
        via: ${host_ip}
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
EOF
        fi
        
        cat > cloud-init/meta-data <<EOF
instance-id: ${vm_id}
local-hostname: ${runner_name}
EOF
        
        # Create cloud-init ISO
        genisoimage -output cloud-init.iso -volid cidata -joliet -rock cloud-init/user-data cloud-init/meta-data cloud-init/network-config >/dev/null 2>&1
        
        print_info "Cloud-init enabled - runner will auto-configure"
    else
        # No cloud-init - create minimal user setup
        print_info "Cloud-init disabled - manual SSH access only"
        
        # Mount and add SSH key manually
        local mount_dir="rootfs_mount"
        mkdir -p "$mount_dir"
        sudo mount -o loop rootfs.ext4 "$mount_dir"
        
        # Create runner user if it doesn't exist
        sudo chroot "$mount_dir" useradd -m -s /bin/bash runner 2>/dev/null || true
        sudo chroot "$mount_dir" usermod -aG sudo runner
        
        # Add SSH key
        sudo mkdir -p "${mount_dir}/home/runner/.ssh"
        sudo cp ssh_key.pub "${mount_dir}/home/runner/.ssh/authorized_keys"
        sudo chroot "$mount_dir" chown -R runner:runner /home/runner/.ssh
        sudo chroot "$mount_dir" chmod 700 /home/runner/.ssh
        sudo chroot "$mount_dir" chmod 600 /home/runner/.ssh/authorized_keys
        
        if [ "$use_dhcp" = true ]; then
            # Configure DHCP
            sudo tee "${mount_dir}/etc/systemd/network/10-eth0.network" > /dev/null <<EOF
[Match]
Name=eth0

[Network]
DHCP=yes
DNS=8.8.8.8
DNS=8.8.4.4
EOF
        else
            # Configure static IP
            sudo tee "${mount_dir}/etc/systemd/network/10-eth0.network" > /dev/null <<EOF
[Match]
Name=eth0

[Network]
Address=${vm_ip}/30
Gateway=${host_ip}
DNS=8.8.8.8
DNS=8.8.4.4
EOF
        fi
        
        # Enable systemd-networkd
        sudo chroot "$mount_dir" systemctl enable systemd-networkd
        sudo chroot "$mount_dir" systemctl enable ssh
        
        sudo umount "$mount_dir"
        rmdir "$mount_dir"
        
        # Create empty cloud-init ISO to satisfy Firecracker
        mkdir -p cloud-init
        echo "{}" > cloud-init/user-data
        echo "instance-id: ${vm_id}" > cloud-init/meta-data
        genisoimage -output cloud-init.iso -volid cidata -joliet -rock cloud-init/user-data cloud-init/meta-data >/dev/null 2>&1
    fi
    
    # Setup kernel
    if [ -n "$custom_kernel" ]; then
        if [ ! -f "$custom_kernel" ]; then
            print_error "Custom kernel not found: $custom_kernel"
            exit 1
        fi
        print_info "Using custom kernel: $custom_kernel"
        cp "$custom_kernel" "vmlinux"
    else
        # Download kernel if needed
        if [ ! -f "vmlinux" ]; then
            print_info "Downloading default kernel..."
            curl -fsSL -o vmlinux "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.12/x86_64/vmlinux-6.1.128"
        fi
    fi
    
    # Start Firecracker
    local socket_path="firecracker.socket"
    rm -f "$socket_path"
    
    firecracker --api-sock "$socket_path" &
    local fc_pid=$!
    echo "$fc_pid" > firecracker.pid
    sleep 2
    
    # Configure VM
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d "{\"vcpu_count\": $VM_CPUS, \"mem_size_mib\": $VM_MEMORY}" \
        http://localhost/machine-config >/dev/null
    
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d "{\"kernel_image_path\": \"$(pwd)/vmlinux\", \"boot_args\": \"console=ttyS0 reboot=k panic=1 root=/dev/vda rw\"}" \
        http://localhost/boot-source >/dev/null
    
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d "{\"drive_id\": \"rootfs\", \"path_on_host\": \"$(pwd)/rootfs.ext4\", \"is_root_device\": true, \"is_read_only\": false}" \
        http://localhost/drives/rootfs >/dev/null
    
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d "{\"drive_id\": \"cloudinit\", \"path_on_host\": \"$(pwd)/cloud-init.iso\", \"is_root_device\": false, \"is_read_only\": true}" \
        http://localhost/drives/cloudinit >/dev/null
    
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d "{\"iface_id\": \"eth0\", \"guest_mac\": \"06:00:AC:10:00:02\", \"host_dev_name\": \"$tap_device\"}" \
        http://localhost/network-interfaces/eth0 >/dev/null
    
    # Start VM
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d '{"action_type": "InstanceStart"}' \
        http://localhost/actions >/dev/null
    
    print_info "✅ VM started: $runner_name"
    print_info "   VM ID: $vm_id"
    print_info "   IP: $vm_ip"
    print_info "   SSH: ssh -i $(pwd)/ssh_key runner@$vm_ip"
    
    # Save instance info
    cat > info.json <<EOF
{
  "name": "$runner_name",
  "vm_id": "$vm_id",
  "ip": "$vm_ip",
  "github_url": "$github_url",
  "labels": "$labels",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pid": $fc_pid
}
EOF
    
    # Wait for SSH
    print_info "Waiting for VM to be ready..."
    for i in {1..30}; do
        if ping -c 1 -W 2 "$vm_ip" >/dev/null 2>&1; then
            if ssh -i ssh_key -o ConnectTimeout=3 -o StrictHostKeyChecking=no runner@"$vm_ip" 'echo ready' >/dev/null 2>&1; then
                print_info "✅ VM is ready and accessible via SSH"
                return 0
            fi
        fi
        sleep 2
    done
    
    print_warning "VM may still be starting up. Try SSH manually: ssh -i $(pwd)/ssh_key runner@$vm_ip"
}

# List resources
list_resources() {
    print_header "Firecracker Resources"
    
    # Images
    echo -e "${GREEN}Images:${NC}"
    if [ -d "images" ] && [ "$(ls -A images 2>/dev/null)" ]; then
        for img in images/*.ext4; do
            [ -f "$img" ] && echo "  $(basename "$img") - $(du -h "$img" | cut -f1)"
        done
    else
        echo "  None"
    fi
    echo
    
    # Snapshots
    echo -e "${GREEN}Snapshots:${NC}"
    if [ -f "snapshots/registry.json" ]; then
        jq -r '.snapshots[] | "  \(.name) - \(.created)"' snapshots/registry.json 2>/dev/null || echo "  None"
    else
        echo "  None"
    fi
    echo
    
    # Running instances
    echo -e "${GREEN}Running Instances:${NC}"
    if [ -d "instances" ] && [ "$(ls -A instances 2>/dev/null)" ]; then
        for inst in "${WORK_DIR}"/instances/*/info.json; do
            if [ -f "$inst" ]; then
                local name=$(jq -r '.name' "$inst")
                local ip=$(jq -r '.ip' "$inst")
                local pid=$(jq -r '.pid' "$inst")
                if kill -0 "$pid" 2>/dev/null; then
                    echo "  $name - $ip (PID: $pid)"
                else
                    echo "  $name - $ip (stopped)"
                fi
            fi
        done
    else
        echo "  None"
    fi
}

# Stop instances
stop_instances() {
    local pattern="${1:-.*}"
    
    if [ ! -d "instances" ]; then
        print_info "No instances directory found"
        return
    fi
    
    local stopped=0
    for inst in "${WORK_DIR}"/instances/*/info.json; do
        if [ -f "$inst" ]; then
            local name=$(jq -r '.name' "$inst")
            local pid=$(jq -r '.pid' "$inst")
            
            if [[ "$name" =~ $pattern ]]; then
                if kill -0 "$pid" 2>/dev/null; then
                    print_info "Stopping $name (PID: $pid)..."
                    kill "$pid" 2>/dev/null || true
                    sleep 1
                    kill -9 "$pid" 2>/dev/null || true
                    ((stopped++))
                fi
                
                # Cleanup TAP device
                local vm_id=$(dirname "$inst" | xargs basename)
                sudo ip link del "tap-${vm_id}" 2>/dev/null || true
            fi
        fi
    done
    
    [ $stopped -eq 0 ] && print_info "No matching instances to stop" || print_info "Stopped $stopped instance(s)"
}

# Clean up everything
cleanup() {
    print_header "Cleaning Up"
    
    # Stop all instances
    stop_instances
    
    # Clean up DHCP servers
    print_info "Stopping DHCP servers..."
    sudo pkill -f "dnsmasq.*tap-" 2>/dev/null || true
    rm -f /tmp/dnsmasq-tap-*.pid 2>/dev/null || true
    
    # Clean up TAP devices
    for tap in $(ip link show | grep -o 'tap-[a-f0-9]*' || true); do
        print_info "Removing TAP device: $tap"
        sudo ip link del "$tap" 2>/dev/null || true
    done
    
    # Remove instances
    if [ -d "instances" ]; then
        rm -rf "${WORK_DIR}"/instances/*
        print_info "Cleaned up instance data"
    fi
    
    print_info "✅ Cleanup complete"
}

# Usage
usage() {
    echo "Firecracker GitHub Actions Runner v${VERSION}"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  build                     Build runner image"
    echo "  snapshot [name]           Create snapshot from image"
    echo "  launch [options]          Launch runner VM from snapshot"
    echo "  list                      List all resources"
    echo "  stop [pattern]            Stop instances (optional pattern)"
    echo "  cleanup                   Stop all instances and cleanup"
    echo "  demo                      Interactive demo"
    echo ""
    echo "Launch options:"
    echo "  --snapshot <name>         Use specific snapshot"
    echo "  --name <name>             Runner name"
    echo "  --github-url <url>        GitHub repo/org URL"
    echo "  --github-token <token>    GitHub token"
    echo "  --labels <labels>         Runner labels (comma-separated)"
    echo "  --memory <mb>             VM memory (default: 2048)"
    echo "  --cpus <count>            VM CPUs (default: 2)"
    echo "  --kernel <path>           Use custom kernel (default: download official)"
    echo "  --dhcp                    Use DHCP for IP assignment (default: static)"
    echo "  --no-cloud-init           Disable cloud-init for manual testing"
    echo ""
    echo "Examples:"
    echo "  $0 build"
    echo "  $0 snapshot prod-v1"
    echo "  $0 launch --github-url https://github.com/org/repo --github-token ghp_xxx"
    echo "  $0 launch --snapshot prod-v1 --no-cloud-init --name test-vm"
    echo "  $0 launch --kernel ./custom-vmlinux --snapshot prod-v1 --no-cloud-init"
    echo "  $0 launch --dhcp --snapshot prod-v1 --no-cloud-init --name dhcp-test"
    echo "  $0 stop test-vm"
    echo "  $0 stop runner-.*"
    echo "  $0 cleanup"
    echo ""
    echo "Networking options:"
    echo "  Static IP: Each VM gets unique IP (172.16.0.10-210)"
    echo "  DHCP:      Requires dnsmasq, IPs assigned dynamically (172.16.0.100-200)"
    echo ""
    echo "Testing without cloud-init:"
    echo "  $0 launch --snapshot <name> --no-cloud-init"
    echo "  # Then SSH: ssh -i /path/to/instance/ssh_key runner@<vm-ip>"
}

# Interactive demo
demo() {
    print_banner
    echo "Welcome to the interactive demo!"
    echo ""
    
    read -p "GitHub URL (repo or org): " github_url
    read -p "GitHub Token: " -s github_token
    echo ""
    read -p "Runner name (default: demo-runner): " runner_name
    runner_name=${runner_name:-demo-runner}
    
    echo ""
    print_info "Starting demo..."
    
    # Build if needed
    if [ ! -f "images/actions-runner-ubuntu-24.04.ext4" ]; then
        print_info "Building runner image..."
        build_image
    fi
    
    # Create snapshot
    local snapshot_name="demo-$(date +%H%M%S)"
    create_snapshot "$snapshot_name"
    
    # Launch VM
    launch_vm --snapshot "$snapshot_name" --name "$runner_name" --github-url "$github_url" --github-token "$github_token"
    
    print_info "✅ Demo complete! Your runner should be visible in GitHub."
}

# Main
main() {
    local cmd="${1:-help}"
    shift || true
    
    case "$cmd" in
        build)
            check_os
            check_dependencies
            setup_workspace
            build_image "$@"
            ;;
        snapshot)
            check_os
            setup_workspace
            create_snapshot "$@"
            ;;
        launch)
            check_os
            check_dependencies
            setup_workspace
            launch_vm "$@"
            ;;
        list)
            setup_workspace
            list_resources
            ;;
        stop)
            setup_workspace
            stop_instances "$@"
            ;;
        cleanup)
            setup_workspace
            cleanup
            ;;
        demo)
            check_os
            check_dependencies
            setup_workspace
            demo
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            print_error "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@" 