#!/bin/bash

# Custom Cloud-Init Configuration Script for Firecracker VMs
# Allows users to provide their own cloud-init YAML file

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    echo "Usage: $0 <cloud-init-yaml-file> [vm-id]"
    echo ""
    echo "This script creates a cloud-init ISO from your custom YAML file"
    echo "and updates an existing Firecracker VM configuration to use it."
    echo ""
    echo "Arguments:"
    echo "  cloud-init-yaml-file  Path to your cloud-init YAML configuration"
    echo "  vm-id                 Optional VM ID (if not provided, will use latest)"
    echo ""
    echo "Example:"
    echo "  $0 my-cloud-init.yaml"
    echo "  $0 my-cloud-init.yaml b6092fbc"
    echo ""
    echo "Your YAML file should contain cloud-init configuration like:"
    echo "  #cloud-config"
    echo "  hostname: my-vm"
    echo "  users:"
    echo "    - name: ubuntu"
    echo "      ssh_authorized_keys:"
    echo "        - ssh-rsa AAAA..."
    echo "  packages:"
    echo "    - htop"
    echo "    - curl"
}

create_cloud_init_from_yaml() {
    local yaml_file="$1"
    local vm_id="$2"
    local work_dir="./firecracker-vm"
    
    if [ ! -f "$yaml_file" ]; then
        print_error "Cloud-init YAML file not found: $yaml_file"
        exit 1
    fi
    
    if [ ! -d "$work_dir" ]; then
        print_error "Firecracker work directory not found: $work_dir"
        print_info "Please run firecracker-setup.sh first"
        exit 1
    fi
    
    print_info "Creating cloud-init configuration from: $yaml_file"
    
    local cloud_init_dir="${work_dir}/cloud-init"
    mkdir -p "$cloud_init_dir"
    
    # Copy user's YAML as user-data
    cp "$yaml_file" "${cloud_init_dir}/user-data"
    
    # Create meta-data
    cat > "${cloud_init_dir}/meta-data" <<EOF
instance-id: firecracker-vm-${vm_id}
local-hostname: firecracker-vm
EOF
    
    # Create basic network-config (can be overridden in user-data)
    cat > "${cloud_init_dir}/network-config" <<EOF
version: 2
ethernets:
  eth0:
    addresses:
      - 172.16.0.2/30
    routes:
      - to: default
        via: 172.16.0.1
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
EOF
    
    # Create ISO
    local cloud_init_iso="${work_dir}/cloud-init.iso"
    
    if command -v genisoimage &> /dev/null; then
        local iso_cmd="genisoimage"
    elif command -v mkisofs &> /dev/null; then
        local iso_cmd="mkisofs"
    else
        print_error "Neither genisoimage nor mkisofs found. Install with: sudo apt install genisoimage"
        exit 1
    fi
    
    print_info "Creating cloud-init ISO with ${iso_cmd}..."
    
    ${iso_cmd} -output "${cloud_init_iso}" \
        -volid cidata \
        -joliet \
        -rock \
        "${cloud_init_dir}/user-data" \
        "${cloud_init_dir}/meta-data" \
        "${cloud_init_dir}/network-config"
    
    print_info "Cloud-init ISO created: ${cloud_init_iso}"
    print_info "ISO size: $(du -h "${cloud_init_iso}" | cut -f1)"
    
    # Show what was included
    print_info "Cloud-init configuration includes:"
    echo "  - User data: $(wc -l < "${cloud_init_dir}/user-data") lines"
    echo "  - Meta data: VM ID ${vm_id}"
    echo "  - Network config: 172.16.0.2/30 with gateway 172.16.0.1"
    
    print_info "To use this configuration, restart your Firecracker VM"
    print_info "The VM will automatically apply your cloud-init configuration on boot"
}

get_latest_vm_id() {
    local work_dir="./firecracker-vm"
    
    if [ ! -d "$work_dir" ]; then
        echo ""
        return
    fi
    
    # Find the most recent VM ID from PID files
    local latest_pid_file
    latest_pid_file=$(find "$work_dir" -name "firecracker-*.pid" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    
    if [ -n "$latest_pid_file" ]; then
        basename "$latest_pid_file" .pid | sed 's/firecracker-//'
    else
        echo ""
    fi
}

main() {
    if [ $# -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        usage
        exit 0
    fi
    
    local yaml_file="$1"
    local vm_id="${2:-}"
    
    # If no VM ID provided, try to find the latest one
    if [ -z "$vm_id" ]; then
        vm_id=$(get_latest_vm_id)
        if [ -z "$vm_id" ]; then
            print_error "No VM ID provided and no existing VMs found"
            print_info "Please provide a VM ID or run firecracker-setup.sh first"
            exit 1
        fi
        print_info "Using latest VM ID: $vm_id"
    fi
    
    create_cloud_init_from_yaml "$yaml_file" "$vm_id"
}

main "$@" 