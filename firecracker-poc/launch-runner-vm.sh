#!/bin/bash

# Launch GitHub Actions Runner VM from Snapshot
# Uses cloud-init to configure runner with GitHub token, runner name, etc.

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/runner-instances"
SNAPSHOTS_DIR="${SCRIPT_DIR}/snapshots"

# VM Configuration defaults
VM_MEMORY="2048"
VM_CPUS="2"
VM_ID="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)"
SOCKET_PATH="${WORK_DIR}/firecracker-${VM_ID}.socket"
TAP_DEVICE="tap-${VM_ID}"
VM_IP="172.16.0.2"
HOST_IP="172.16.0.1"
MASK_SHORT="/30"
FC_MAC="06:00:AC:10:00:02"

# Runner configuration
RUNNER_NAME="runner-${VM_ID}"
GITHUB_URL=""
GITHUB_TOKEN=""
RUNNER_LABELS="firecracker,ubuntu-24.04"
RUNNER_WORK_DIR="/home/runner/_work"
SSH_KEY_PATH="${WORK_DIR}/runner_key_${VM_ID}"
SNAPSHOT_PATH=""

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
        exit 1
    fi
}

check_dependencies() {
    print_header "Checking Dependencies"
    
    local deps=("curl" "qemu-img" "firecracker" "ssh-keygen" "jq")
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
    
    # Check KVM access
    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        print_error "Cannot access /dev/kvm. Make sure KVM is enabled and you have permissions."
        exit 1
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi
    
    print_info "All dependencies are satisfied"
}

setup_workspace() {
    print_header "Setting Up VM Instance Workspace"
    
    mkdir -p "${WORK_DIR}"
    cd "${WORK_DIR}"
    
    print_info "Instance workspace: ${WORK_DIR}"
    print_info "VM ID: ${VM_ID}"
}

find_snapshot() {
    print_header "Locating Runner Snapshot"
    
    if [ -n "$SNAPSHOT_PATH" ]; then
        if [ -d "$SNAPSHOT_PATH" ]; then
            print_info "Using specified snapshot: $SNAPSHOT_PATH"
            return 0
        else
            print_error "Specified snapshot not found: $SNAPSHOT_PATH"
            exit 1
        fi
    fi
    
    # Find latest snapshot
    local registry_file="${SNAPSHOTS_DIR}/registry.json"
    
    if [ ! -f "$registry_file" ]; then
        print_error "No snapshots found. Create one with: ./snapshot-runner-image.sh create"
        exit 1
    fi
    
    local latest_snapshot
    latest_snapshot=$(jq -r '.snapshots | sort_by(.created_at) | last | .path' "$registry_file")
    
    if [ "$latest_snapshot" = "null" ] || [ ! -d "$latest_snapshot" ]; then
        print_error "No valid snapshots found"
        exit 1
    fi
    
    SNAPSHOT_PATH="$latest_snapshot"
    print_info "Using latest snapshot: $SNAPSHOT_PATH"
}

prepare_vm_image() {
    print_header "Preparing VM Instance Image"
    
    local snapshot_rootfs="${SNAPSHOT_PATH}/rootfs.ext4"
    local instance_rootfs="rootfs-${VM_ID}.ext4"
    
    if [ ! -f "$snapshot_rootfs" ]; then
        print_error "Snapshot rootfs not found: $snapshot_rootfs"
        exit 1
    fi
    
    print_info "Creating instance copy from snapshot..."
    cp "$snapshot_rootfs" "$instance_rootfs"
    
    print_info "Instance rootfs ready: $instance_rootfs"
}

prepare_kernel() {
    print_header "Preparing Kernel"
    
    local kernel_file="vmlinux-${VM_ID}"
    
    # Try snapshot kernel first
    if [ -f "${SNAPSHOT_PATH}/vmlinux" ]; then
        print_info "Using kernel from snapshot..."
        cp "${SNAPSHOT_PATH}/vmlinux" "$kernel_file"
        return 0
    fi
    
    # Try existing kernels
    for kernel_path in "${SCRIPT_DIR}/firecracker-vm/vmlinux-6.1.128-custom" "${SCRIPT_DIR}/firecracker-vm/vmlinux-6.1.128"; do
        if [ -f "$kernel_path" ]; then
            print_info "Using kernel: $kernel_path"
            cp "$kernel_path" "$kernel_file"
            return 0
        fi
    done
    
    # Download kernel as fallback
    print_info "Downloading Firecracker kernel..."
    curl -fsSL -o "$kernel_file" \
        "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.12/x86_64/vmlinux-6.1.128"
    
    print_info "Kernel ready: $kernel_file"
}

generate_ssh_key() {
    print_header "Generating SSH Key"
    
    if [ ! -f "${SSH_KEY_PATH}" ]; then
        ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N "" -C "runner-${VM_ID}"
        print_info "SSH key generated: ${SSH_KEY_PATH}"
    else
        print_info "SSH key already exists: ${SSH_KEY_PATH}"
    fi
}

create_cloud_init_config() {
    print_header "Creating Cloud-Init Configuration"
    
    local cloud_init_dir="cloud-init-${VM_ID}"
    mkdir -p "$cloud_init_dir"
    
    local ssh_public_key
    ssh_public_key=$(cat "${SSH_KEY_PATH}.pub")
    
    # Create user-data from template with variable substitution
    print_info "Generating cloud-init user-data..."
    
    # Use template if available, otherwise create basic config
    if [ -f "${SNAPSHOT_PATH}/cloud-init-template.yaml" ]; then
        # Substitute variables in template
        sed -e "s/\${RUNNER_NAME}/${RUNNER_NAME}/g" \
            -e "s/\${SSH_PUBLIC_KEY}/${ssh_public_key}/g" \
            -e "s/\${GITHUB_TOKEN}/${GITHUB_TOKEN}/g" \
            -e "s|\${GITHUB_URL}|${GITHUB_URL}|g" \
            -e "s/\${RUNNER_LABELS}/${RUNNER_LABELS}/g" \
            -e "s|\${RUNNER_WORK_DIR}|${RUNNER_WORK_DIR}|g" \
            "${SNAPSHOT_PATH}/cloud-init-template.yaml" > "${cloud_init_dir}/user-data"
    else
        # Create basic cloud-init config
        cat > "${cloud_init_dir}/user-data" <<EOF
#cloud-config
hostname: ${RUNNER_NAME}
fqdn: ${RUNNER_NAME}.local

users:
  - name: runner
    ssh_authorized_keys:
      - ${ssh_public_key}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

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

write_files:
  - path: /etc/environment
    permissions: '0644'
    content: |
      GITHUB_TOKEN=${GITHUB_TOKEN}
      GITHUB_URL=${GITHUB_URL}
      RUNNER_NAME=${RUNNER_NAME}
      RUNNER_LABELS=${RUNNER_LABELS}
      RUNNER_WORK_DIR=${RUNNER_WORK_DIR}

runcmd:
  - systemctl daemon-reload
  - systemctl enable actions-runner
  - systemctl start actions-runner

final_message: "GitHub Actions Runner ${RUNNER_NAME} is ready!"
EOF
    fi
    
    # Create meta-data
    cat > "${cloud_init_dir}/meta-data" <<EOF
instance-id: ${RUNNER_NAME}
local-hostname: ${RUNNER_NAME}
EOF
    
    # Create network-config
    cat > "${cloud_init_dir}/network-config" <<EOF
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
EOF
    
    print_info "Cloud-init configuration created"
}

create_cloud_init_iso() {
    print_header "Creating Cloud-Init ISO"
    
    local cloud_init_dir="cloud-init-${VM_ID}"
    local cloud_init_iso="cloud-init-${VM_ID}.iso"
    
    # Check for ISO creation tools
    if command -v genisoimage &> /dev/null; then
        local iso_cmd="genisoimage"
    elif command -v mkisofs &> /dev/null; then
        local iso_cmd="mkisofs"
    else
        print_error "Neither genisoimage nor mkisofs found"
        exit 1
    fi
    
    print_info "Creating cloud-init ISO..."
    
    ${iso_cmd} -output "${cloud_init_iso}" \
        -volid cidata \
        -joliet \
        -rock \
        "${cloud_init_dir}/user-data" \
        "${cloud_init_dir}/meta-data" \
        "${cloud_init_dir}/network-config"
    
    print_info "Cloud-init ISO created: ${cloud_init_iso}"
}

setup_networking() {
    print_header "Setting Up Networking"
    
    # Remove existing TAP device if it exists
    sudo ip link del "${TAP_DEVICE}" 2> /dev/null || true
    
    print_info "Creating TAP device: ${TAP_DEVICE}"
    
    # Create TAP device
    sudo ip tuntap add dev "${TAP_DEVICE}" mode tap
    sudo ip addr add "${HOST_IP}${MASK_SHORT}" dev "${TAP_DEVICE}"
    sudo ip link set dev "${TAP_DEVICE}" up
    
    # Enable IP forwarding
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
    
    # Set up iptables rules
    print_info "Setting up iptables rules..."
    
    # Accept forwarding
    sudo iptables -P FORWARD ACCEPT
    
    # Determine host network interface
    local host_iface
    host_iface=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [ -z "$host_iface" ]; then
        print_warning "Could not determine host network interface. Using eth0 as fallback."
        host_iface="eth0"
    fi
    
    print_info "Using host interface: ${host_iface}"
    
    # Remove existing MASQUERADE rule if it exists
    sudo iptables -t nat -D POSTROUTING -o "$host_iface" -j MASQUERADE 2>/dev/null || true
    
    # Add MASQUERADE rule
    sudo iptables -t nat -A POSTROUTING -o "$host_iface" -j MASQUERADE
    
    print_info "Networking configured"
}

start_firecracker_vm() {
    print_header "Starting Firecracker VM"
    
    local kernel_file="vmlinux-${VM_ID}"
    local rootfs_file="rootfs-${VM_ID}.ext4"
    local cloud_init_iso="cloud-init-${VM_ID}.iso"
    
    # Remove existing socket if it exists
    rm -f "${SOCKET_PATH}"
    
    print_info "Starting Firecracker process..."
    firecracker --api-sock "${SOCKET_PATH}" &
    local firecracker_pid=$!
    
    # Wait for Firecracker to start
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
            \"kernel_image_path\": \"${WORK_DIR}/${kernel_file}\",
            \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off nomodules rw root=/dev/vda rootfstype=ext4 ip=${VM_IP}::${HOST_IP}:255.255.255.192::eth0:on\"
        }" \
        http://localhost/boot-source > /dev/null
    
    # Configure rootfs drive
    curl -X PUT \
        --unix-socket "${SOCKET_PATH}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{
            \"drive_id\": \"rootfs\",
            \"path_on_host\": \"${WORK_DIR}/${rootfs_file}\",
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
            \"path_on_host\": \"${WORK_DIR}/${cloud_init_iso}\",
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

wait_for_runner() {
    print_header "Waiting for Runner to be Ready"
    
    local max_attempts=60
    local attempt=1
    
    print_info "Waiting for VM to boot and runner to configure..."
    
    while [ $attempt -le $max_attempts ]; do
        if ping -c 1 -W 2 "${VM_IP}" &> /dev/null; then
            print_info "VM is reachable via ping"
            
            # Check if SSH is ready
            if ssh -i "${SSH_KEY_PATH}" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null runner@"${VM_IP}" 'echo "SSH ready"' &> /dev/null; then
                print_info "SSH is ready!"
                
                # Check runner service status
                if ssh -i "${SSH_KEY_PATH}" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null runner@"${VM_IP}" 'systemctl is-active actions-runner' &> /dev/null; then
                    print_info "GitHub Actions Runner is active!"
                    return 0
                else
                    print_info "Runner service not yet active..."
                fi
            else
                print_info "SSH not yet ready..."
            fi
        else
            print_info "VM not yet reachable..."
        fi
        
        print_info "Attempt ${attempt}/${max_attempts}: Waiting for runner..."
        sleep 5
        ((attempt++))
    done
    
    print_warning "Runner service did not become ready within the timeout period"
    return 1
}

show_connection_info() {
    print_header "Runner VM Information"
    
    echo -e "${GREEN}VM Details:${NC}"
    echo "  VM ID: ${VM_ID}"
    echo "  Runner Name: ${RUNNER_NAME}"
    echo "  VM IP: ${VM_IP}"
    echo "  Memory: ${VM_MEMORY} MB"
    echo "  CPUs: ${VM_CPUS}"
    echo "  Labels: ${RUNNER_LABELS}"
    echo ""
    
    echo -e "${GREEN}GitHub Integration:${NC}"
    echo "  GitHub URL: ${GITHUB_URL}"
    echo "  Work Directory: ${RUNNER_WORK_DIR}"
    echo ""
    
    echo -e "${GREEN}SSH Access:${NC}"
    echo "  Runner user: ssh -i \"${SSH_KEY_PATH}\" runner@${VM_IP}"
    echo "  Root user: ssh -i \"${SSH_KEY_PATH}\" root@${VM_IP}"
    echo ""
    
    echo -e "${GREEN}Management:${NC}"
    echo "  Stop VM: ${SCRIPT_DIR}/firecracker-manage.sh stop ${VM_ID}"
    echo "  VM status: ${SCRIPT_DIR}/firecracker-manage.sh status ${VM_ID}"
    echo ""
    
    echo -e "${GREEN}Files Created:${NC}"
    echo "  SSH key: ${SSH_KEY_PATH}"
    echo "  VM rootfs: ${WORK_DIR}/rootfs-${VM_ID}.ext4"
    echo "  PID file: ${WORK_DIR}/firecracker-${VM_ID}.pid"
    echo "  Socket: ${SOCKET_PATH}"
}

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Required options:"
    echo "  --github-url <url>        GitHub repository or organization URL"
    echo "  --github-token <token>    GitHub personal access token"
    echo ""
    echo "Optional options:"
    echo "  --runner-name <name>      Runner name (default: runner-<vm-id>)"
    echo "  --runner-labels <labels>  Comma-separated runner labels (default: firecracker,ubuntu-24.04)"
    echo "  --memory <mb>             VM memory in MB (default: 2048)"
    echo "  --cpus <count>            Number of CPUs (default: 2)"
    echo "  --snapshot <path>         Path to specific snapshot (default: latest)"
    echo "  --work-dir <path>         Runner work directory (default: /home/runner/_work)"
    echo "  --help, -h                Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --github-url https://github.com/myorg/myrepo --github-token ghp_xxxxxxxxxxxx"
    echo "  $0 --github-url https://github.com/myorg --github-token ghp_xxxxxxxxxxxx --runner-name my-runner"
    echo "  $0 --github-url https://github.com/myorg/myrepo --github-token ghp_xxxxxxxxxxxx --memory 4096 --cpus 4"
}

main() {
    print_header "GitHub Actions Runner VM Launcher"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --github-url)
                GITHUB_URL="$2"
                shift 2
                ;;
            --github-token)
                GITHUB_TOKEN="$2"
                shift 2
                ;;
            --runner-name)
                RUNNER_NAME="$2"
                shift 2
                ;;
            --runner-labels)
                RUNNER_LABELS="$2"
                shift 2
                ;;
            --memory)
                VM_MEMORY="$2"
                shift 2
                ;;
            --cpus)
                VM_CPUS="$2"
                shift 2
                ;;
            --snapshot)
                SNAPSHOT_PATH="$2"
                shift 2
                ;;
            --work-dir)
                RUNNER_WORK_DIR="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Validate required parameters
    if [ -z "$GITHUB_URL" ] || [ -z "$GITHUB_TOKEN" ]; then
        print_error "GitHub URL and token are required"
        usage
        exit 1
    fi
    
    check_os
    check_dependencies
    setup_workspace
    find_snapshot
    prepare_vm_image
    prepare_kernel
    generate_ssh_key
    create_cloud_init_config
    create_cloud_init_iso
    setup_networking
    start_firecracker_vm
    
    sleep 10  # Give the VM time to boot
    
    if wait_for_runner; then
        show_connection_info
        print_info "GitHub Actions Runner VM is ready and configured!"
    else
        show_connection_info
        print_warning "VM started but runner may not be fully configured yet. Check manually."
    fi
}

# Run main function
main "$@" 