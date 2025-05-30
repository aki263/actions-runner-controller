#!/bin/bash

# Firecracker Complete - All-in-One GitHub Actions Runner Solution
# Builds kernel, filesystem, and manages Firecracker VMs with cloud-init

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/firecracker-data"
VERSION="2.0.0"

# Default configuration
RUNNER_VERSION="2.324.0"
DOCKER_VERSION="latest" 
ROOTFS_SIZE="20G"
VM_MEMORY="2048"
VM_CPUS="2"
RUNNER_LABELS="firecracker,ubuntu-24.04"
KERNEL_VERSION="6.1.128"

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
    echo "  Firecracker Complete v${VERSION}"
    echo "  Kernel → Filesystem → VM → Manager"
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
        exit 1
    fi
    
    if [[ "$(uname -s)" != "Linux" ]]; then
        print_error "This script requires Ubuntu 24.04 or compatible Linux distribution."
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "wget" "git" "make" "gcc" "bc" "flex" "bison" "libssl-dev" "libelf-dev" "qemu-img" "debootstrap" "jq" "firecracker" "ssh-keygen")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null && ! dpkg -l | grep -q "^ii.*$dep"; then
            missing_deps+=("$dep")
        fi
    done
    
    # Check for ISO creation tools
    if ! command -v genisoimage &> /dev/null && ! command -v mkisofs &> /dev/null; then
        missing_deps+=("genisoimage")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Install with: sudo apt update && sudo apt install -y build-essential curl wget git bc flex bison libssl-dev libelf-dev qemu-utils debootstrap jq openssh-client genisoimage"
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
    mkdir -p "${WORK_DIR}"/{kernels,images,snapshots,instances}
    cd "${WORK_DIR}"
}

# Build custom kernel with Ubuntu 24.04 package support
build_kernel() {
    local kernel_config="${1:-${SCRIPT_DIR}/working-kernel-config}"
    local kernel_patch="${SCRIPT_DIR}/enable-ubuntu-features.patch"
    
    print_header "Building Custom Firecracker Kernel"
    
    if [ ! -f "$kernel_config" ]; then
        print_error "Kernel config not found: $kernel_config"
        print_info "Expected: working-kernel-config in script directory"
        exit 1
    fi
    
    local kernel_dir="kernels/linux-${KERNEL_VERSION}"
    local kernel_output="kernels/vmlinux-${KERNEL_VERSION}-ubuntu24"
    
    if [ -f "$kernel_output" ]; then
        print_warning "Kernel already exists: $kernel_output"
        print_info "Use --rebuild-kernel to recreate"
        return 0
    fi
    
    print_info "Downloading Linux kernel ${KERNEL_VERSION}..."
    if [ ! -d "$kernel_dir" ]; then
        wget -q "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz" -O "linux-${KERNEL_VERSION}.tar.xz"
        tar -xf "linux-${KERNEL_VERSION}.tar.xz" -C kernels/
        rm "linux-${KERNEL_VERSION}.tar.xz"
    fi
    
    cd "$kernel_dir"
    
    print_info "Applying kernel configuration..."
    cp "$kernel_config" .config
    
    # Apply Ubuntu 24.04 package support patches
    if [ -f "$kernel_patch" ]; then
        print_info "Applying Ubuntu 24.04 feature patches..."
        # Process patch file and apply to .config
        while IFS= read -r line; do
            if [[ "$line" =~ ^CONFIG_.*=.*$ ]]; then
                config_name=$(echo "$line" | cut -d'=' -f1)
                # Remove existing config line and add new one
                sed -i "/^${config_name}=/d" .config
                sed -i "/^# ${config_name} is not set/d" .config
                echo "$line" >> .config
            fi
        done < "$kernel_patch"
    fi
    
    # Resolve config dependencies
    print_info "Resolving kernel configuration dependencies..."
    make olddefconfig
    
    print_info "Building kernel (this may take 30-60 minutes)..."
    make -j$(nproc) vmlinux
    
    # Copy built kernel
    cp vmlinux "../../${kernel_output}"
    cd ../..
    
    local size=$(du -h "${kernel_output}" | cut -f1)
    print_info "✅ Kernel built: ${kernel_output} (${size})"
}

# Build Ubuntu 24.04 runner filesystem with all packages
build_filesystem() {
    print_header "Building Ubuntu 24.04 GitHub Actions Runner Filesystem"
    
    local image_file="images/actions-runner-ubuntu-24.04.ext4"
    
    if [ -f "${image_file}" ]; then
        print_warning "Filesystem already exists. Use --rebuild-fs to recreate."
        return 0
    fi
    
    print_info "Creating ${ROOTFS_SIZE} filesystem image..."
    
    # Create and format image
    qemu-img create -f raw "${image_file}" "${ROOTFS_SIZE}"
    mkfs.ext4 "${image_file}"
    
    # Mount and setup
    local mount_dir="tmp_mount"
    mkdir -p "${mount_dir}"
    sudo mount "${image_file}" "${mount_dir}"
    
    print_info "Installing Ubuntu 24.04 base system..."
    
    # Install comprehensive package set for GitHub Actions compatibility
    local packages="openssh-server,curl,wget,vim,htop,systemd,init,sudo,ca-certificates,cloud-init,jq,unzip,zip,git,iptables"
    packages+=",build-essential,python3,python3-pip,nodejs,npm,openjdk-17-jdk"
    packages+=",libsqlite3-dev,libssl-dev,pkg-config,autoconf,automake,libtool"
    packages+=",bison,flex,make,gcc,g++,binutils,file,gnupg2,lsb-release"
    packages+=",software-properties-common,apt-transport-https,gpg-agent"
    
    sudo debootstrap --include="$packages" \
        noble "${mount_dir}" http://archive.ubuntu.com/ubuntu/
    
    print_info "Configuring GitHub Actions runner environment..."
    
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
    
    # Update and install Docker
    sudo chroot "${mount_dir}" apt-get update
    sudo chroot "${mount_dir}" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo chroot "${mount_dir}" usermod -aG docker runner
    
    # Download and install GitHub Actions runner
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
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=runner
WorkingDirectory=/opt/runner
ExecStart=/opt/runner/run.sh
Restart=always
RestartSec=10
Environment=RUNNER_ALLOW_RUNASROOT=1

[Install]
WantedBy=multi-user.target
EOF
    
    # Configure Docker for Firecracker environment
    sudo mkdir -p "${mount_dir}/etc/docker"
    sudo tee "${mount_dir}/etc/docker/daemon.json" > /dev/null <<'EOF'
{
  "storage-driver": "overlay2",
  "iptables": false,
  "ip6tables": false,
  "bridge": "none",
  "userland-proxy": false,
  "features": {
    "buildkit": true
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    
    # Setup script for runner configuration
    sudo tee "${mount_dir}/usr/local/bin/setup-runner.sh" > /dev/null <<'EOF'
#!/bin/bash
if [ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_URL" ]; then
    echo "Missing GITHUB_TOKEN or GITHUB_URL environment variables"
    exit 1
fi

# Start Docker
systemctl start docker
sleep 5

# Configure runner
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
    sudo chroot "${mount_dir}" systemctl enable ssh docker systemd-networkd
    
    # Install additional tools from ubuntu-24-packages.md
    print_info "Installing additional development tools..."
    sudo chroot "${mount_dir}" apt-get install -y \
        ansible bazel cmake git-lfs kubectl helm \
        python3-dev python-is-python3 ruby nodejs \
        openjdk-8-jdk openjdk-11-jdk openjdk-21-jdk \
        postgresql-client mysql-client sqlite3 \
        firefox-esr chromium-browser \
        xvfb mediainfo parallel rsync \
        2>/dev/null || true
    
    # Cleanup
    sudo chroot "${mount_dir}" apt-get clean
    sudo chroot "${mount_dir}" rm -rf /var/lib/apt/lists/*
    sudo umount "${mount_dir}"
    rmdir "${mount_dir}"
    
    local size=$(du -h "${image_file}" | cut -f1)
    print_info "✅ Filesystem created: ${image_file} (${size})"
}

# Create VM snapshot
create_snapshot() {
    local snapshot_name="${1:-runner-$(date +%Y%m%d-%H%M%S)}"
    local image_file="images/actions-runner-ubuntu-24.04.ext4"
    
    print_header "Creating Snapshot: ${snapshot_name}"
    
    if [ ! -f "$image_file" ]; then
        print_error "No filesystem image found. Run: $0 build-fs"
        exit 1
    fi
    
    local snapshot_dir="snapshots/${snapshot_name}"
    mkdir -p "$snapshot_dir"
    
    print_info "Creating snapshot..."
    cp "$image_file" "${snapshot_dir}/rootfs.ext4"
    
    # Create metadata
    cat > "${snapshot_dir}/info.json" <<EOF
{
  "name": "${snapshot_name}",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "runner_version": "${RUNNER_VERSION}",
  "docker_version": "${DOCKER_VERSION}",
  "kernel_version": "${KERNEL_VERSION}"
}
EOF
    
    local size=$(du -h "$snapshot_dir" | cut -f1)
    print_info "✅ Snapshot created: ${snapshot_dir} (${size})"
}

# Launch VM with cloud-init networking
launch_vm() {
    local snapshot_name=""
    local runner_name="runner-$(date +%H%M%S)"
    local github_url=""
    local github_token=""
    local labels="firecracker"
    local use_cloud_init=true
    local custom_kernel=""
    
    # Parse arguments
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
            --no-cloud-init) use_cloud_init=false; shift ;;
            *) print_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    
    if [ "$use_cloud_init" = true ] && ([ -z "$github_url" ] || [ -z "$github_token" ]); then
        print_error "GitHub URL and token are required (or use --no-cloud-init for testing)"
        exit 1
    fi
    
    # Find snapshot
    if [ -z "$snapshot_name" ]; then
        if [ ! -d "snapshots" ] || [ -z "$(ls -A snapshots 2>/dev/null)" ]; then
            print_error "No snapshots found. Run: $0 snapshot"
            exit 1
        fi
        snapshot_name=$(ls -t snapshots/ | head -1)
    fi
    
    local snapshot_dir="snapshots/${snapshot_name}"
    if [ ! -d "$snapshot_dir" ]; then
        print_error "Snapshot not found: $snapshot_name"
        exit 1
    fi
    
    print_header "Launching VM: ${runner_name}"
    
    # Setup instance
    local vm_id=$(echo "$runner_name" | tr '[:upper:]' '[:lower:]' | head -c 8)
    local instance_dir="instances/${vm_id}"
    mkdir -p "$instance_dir"
    cd "$instance_dir"
    
    # Copy snapshot
    cp "${snapshot_dir}/rootfs.ext4" "rootfs.ext4"
    
    # Generate SSH key
    ssh-keygen -t rsa -b 4096 -f "ssh_key" -N "" -C "$runner_name" >/dev/null 2>&1
    
    # Setup shared bridge networking
    local bridge="firecracker-br0"
    local tap="firecracker-tap0"
    local gateway_ip="172.16.0.1"
    local ip_suffix=$((16#$(echo "$vm_id" | sha256sum | head -c 2) % 200 + 10))
    if [ $ip_suffix -eq 1 ]; then ip_suffix=10; fi
    local vm_ip="172.16.0.${ip_suffix}"
    
    print_info "Setting up networking: $vm_ip via $bridge"
    
    # Create bridge if needed
    if ! ip link show "$bridge" >/dev/null 2>&1; then
        sudo ip link add name "$bridge" type bridge
        sudo ip addr add "${gateway_ip}/24" dev "$bridge"
        sudo ip link set dev "$bridge" up
    fi
    
    # Create shared TAP if needed
    if ! ip link show "$tap" >/dev/null 2>&1; then
        sudo ip tuntap add dev "$tap" mode tap
        sudo ip link set dev "$tap" master "$bridge"
        sudo ip link set dev "$tap" up
    fi
    
    # Enable NAT
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
    local host_iface=$(ip route | grep default | awk '{print $5}' | head -1)
    sudo iptables -t nat -A POSTROUTING -s 172.16.0.0/24 -o "$host_iface" -j MASQUERADE 2>/dev/null || true
    
    # Setup cloud-init
    if [ "$use_cloud_init" = true ]; then
        mkdir -p cloud-init
        
        cat > cloud-init/user-data <<EOF
#cloud-config
hostname: ${runner_name}

users:
  - name: runner
    ssh_authorized_keys:
      - $(cat ssh_key.pub)
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

write_files:
  - path: /etc/environment
    content: |
      GITHUB_TOKEN=${github_token}
      GITHUB_URL=${github_url}
      RUNNER_NAME=${runner_name}
      RUNNER_LABELS=${labels}
  - path: /etc/systemd/network/10-eth0.network
    content: |
      [Match]
      Name=eth0
      
      [Network]
      Address=${vm_ip}/24
      Gateway=${gateway_ip}
      DNS=8.8.8.8
      DNS=8.8.4.4

runcmd:
  - systemctl enable systemd-networkd
  - systemctl restart systemd-networkd
  - /usr/local/bin/setup-runner.sh

ssh_pwauth: false
EOF
        
        echo "{}" > cloud-init/network-config
        echo "instance-id: ${vm_id}" > cloud-init/meta-data
        
        genisoimage -output cloud-init.iso -volid cidata -joliet -rock cloud-init/ >/dev/null 2>&1
    fi
    
    # Setup kernel
    if [ -n "$custom_kernel" ]; then
        if [ ! -f "$custom_kernel" ]; then
            print_error "Custom kernel not found: $custom_kernel"
            exit 1
        fi
        cp "$custom_kernel" "vmlinux"
    else
        # Use built kernel if available
        local built_kernel="../../kernels/vmlinux-${KERNEL_VERSION}-ubuntu24"
        if [ -f "$built_kernel" ]; then
            cp "$built_kernel" "vmlinux"
        else
            # Download default kernel
            if [ ! -f "vmlinux" ]; then
                print_info "Downloading default kernel..."
                curl -fsSL -o vmlinux "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.12/x86_64/vmlinux-6.1.128"
            fi
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
    
    if [ "$use_cloud_init" = true ]; then
        curl -X PUT --unix-socket "$socket_path" \
            -H "Content-Type: application/json" \
            -d "{\"drive_id\": \"cloudinit\", \"path_on_host\": \"$(pwd)/cloud-init.iso\", \"is_root_device\": false, \"is_read_only\": true}" \
            http://localhost/drives/cloudinit >/dev/null
    fi
    
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d "{\"iface_id\": \"eth0\", \"guest_mac\": \"06:00:AC:10:00:02\", \"host_dev_name\": \"$tap\"}" \
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
    
    cd ../..
    
    # Wait for VM
    print_info "Waiting for VM to be ready..."
    for i in {1..30}; do
        if ping -c 1 -W 2 "$vm_ip" >/dev/null 2>&1; then
            if ssh -i "instances/${vm_id}/ssh_key" -o ConnectTimeout=3 -o StrictHostKeyChecking=no runner@"$vm_ip" 'echo ready' >/dev/null 2>&1; then
                print_info "✅ VM is ready and accessible"
                return 0
            fi
        fi
        sleep 2
    done
    
    print_warning "VM may still be starting up"
}

# List and manage VMs
list_vms() {
    print_header "Firecracker Resources"
    
    echo -e "${GREEN}Kernels:${NC}"
    if [ -d "kernels" ] && ls kernels/vmlinux-* &>/dev/null; then
        for kernel in kernels/vmlinux-*; do
            [ -f "$kernel" ] && echo "  $(basename "$kernel") - $(du -h "$kernel" | cut -f1)"
        done
    else
        echo "  None"
    fi
    echo
    
    echo -e "${GREEN}Images:${NC}"
    if [ -d "images" ] && ls images/*.ext4 &>/dev/null; then
        for img in images/*.ext4; do
            [ -f "$img" ] && echo "  $(basename "$img") - $(du -h "$img" | cut -f1)"
        done
    else
        echo "  None" 
    fi
    echo
    
    echo -e "${GREEN}Snapshots:${NC}"
    if [ -d "snapshots" ] && [ "$(ls -A snapshots 2>/dev/null)" ]; then
        for snap in snapshots/*/info.json; do
            if [ -f "$snap" ]; then
                local name=$(jq -r '.name' "$snap")
                local created=$(jq -r '.created' "$snap")
                echo "  $name - $created"
            fi
        done
    else
        echo "  None"
    fi
    echo
    
    echo -e "${GREEN}Running VMs:${NC}"
    if [ -d "instances" ] && [ "$(ls -A instances 2>/dev/null)" ]; then
        for inst in instances/*/info.json; do
            if [ -f "$inst" ]; then
                local name=$(jq -r '.name' "$inst")
                local ip=$(jq -r '.ip' "$inst") 
                local pid=$(jq -r '.pid' "$inst")
                if kill -0 "$pid" 2>/dev/null; then
                    echo "  $name - $ip (PID: $pid) ✅"
                else
                    echo "  $name - $ip (stopped) ❌"
                fi
            fi
        done
    else
        echo "  None"
    fi
}

# Stop VMs
stop_vms() {
    local pattern="${1:-.*}"
    
    if [ ! -d "instances" ]; then
        print_info "No instances found"
        return
    fi
    
    local stopped=0
    for inst in instances/*/info.json; do
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
            fi
        fi
    done
    
    [ $stopped -eq 0 ] && print_info "No matching VMs to stop" || print_info "Stopped $stopped VM(s)"
}

# Cleanup everything  
cleanup() {
    print_header "Cleaning Up"
    
    stop_vms
    
    # Cleanup networking
    print_info "Cleaning up networking..."
    sudo ip link del "firecracker-tap0" 2>/dev/null || true
    sudo ip link del "firecracker-br0" 2>/dev/null || true
    sudo iptables -t nat -D POSTROUTING -s 172.16.0.0/24 -j MASQUERADE 2>/dev/null || true
    
    # Remove instances
    if [ -d "instances" ]; then
        rm -rf instances/*
        print_info "Cleaned up instance data"
    fi
    
    print_info "✅ Cleanup complete"
}

# Usage
usage() {
    echo "Firecracker Complete v${VERSION} - All-in-One GitHub Actions Runner"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Build Commands:"
    echo "  build-kernel              Build custom kernel with Ubuntu 24.04 support"
    echo "  build-fs                  Build filesystem with GitHub Actions runner"
    echo "  snapshot [name]           Create snapshot from filesystem"
    echo ""
    echo "VM Management:"
    echo "  launch [options]          Launch runner VM"
    echo "  list                      List all resources"
    echo "  stop [pattern]            Stop VMs (optional regex pattern)" 
    echo "  cleanup                   Stop all VMs and cleanup"
    echo ""
    echo "Launch Options:"
    echo "  --snapshot <name>         Use specific snapshot"
    echo "  --name <name>             VM name"
    echo "  --github-url <url>        GitHub repo/org URL"
    echo "  --github-token <token>    GitHub token"
    echo "  --labels <labels>         Runner labels"
    echo "  --memory <mb>             VM memory (default: 2048)" 
    echo "  --cpus <count>            VM CPU count (default: 2)"
    echo "  --kernel <path>           Custom kernel path"
    echo "  --no-cloud-init           Disable cloud-init"
    echo ""
    echo "Examples:"
    echo "  $0 build-kernel           # Build kernel with Ubuntu 24.04 support"
    echo "  $0 build-fs               # Build filesystem with GitHub Actions runner"  
    echo "  $0 snapshot prod-v1       # Create production snapshot"
    echo "  $0 launch --github-url https://github.com/org/repo --github-token ghp_xxx"
    echo "  $0 list                   # Show all resources"
    echo "  $0 cleanup                # Stop everything"
}

# Main function
main() {
    local cmd="${1:-help}"
    shift || true
    
    case "$cmd" in
        build-kernel)
            check_os
            check_dependencies
            setup_workspace
            build_kernel "$@"
            ;;
        build-fs)
            check_os
            check_dependencies  
            setup_workspace
            build_filesystem "$@"
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
            list_vms
            ;;
        stop)
            setup_workspace
            stop_vms "$@" 
            ;;
        cleanup)
            setup_workspace
            cleanup
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

# Run
main "$@" 