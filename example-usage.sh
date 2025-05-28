#!/bin/bash

# Example usage script for Firecracker VM setup
# This script demonstrates basic VM operations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_header() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================${NC}"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        print_error "This example is designed to run on Linux/Ubuntu, not macOS"
        print_info "You are currently on macOS. Please run this on your Linux machine."
        print_info "Firecracker requires KVM which is only available on Linux."
        exit 1
    fi
}

main() {
    check_os
    
    print_header "Firecracker VM Example Usage"
    
    print_info "This script demonstrates how to:"
    print_info "1. Create a basic Firecracker VM"
    print_info "2. Check VM status"
    print_info "3. SSH into the VM"
    print_info "4. Stop the VM"
    echo ""
    
    print_header "Step 1: Create a Basic VM"
    print_info "Creating VM with 2GB RAM, 4 CPUs, and 15GB disk..."
    
    if ! "${SCRIPT_DIR}/firecracker-setup.sh" --memory 2048 --cpus 4 --rootfs-size 15G; then
        print_error "Failed to create VM"
        exit 1
    fi
    
    echo ""
    print_header "Step 2: List VMs"
    "${SCRIPT_DIR}/firecracker-manage.sh" list
    
    echo ""
    print_header "Step 3: VM Operations"
    print_info "You can now:"
    echo "  • Check status: ${SCRIPT_DIR}/firecracker-manage.sh status <vm_id>"
    echo "  • SSH into VM: ${SCRIPT_DIR}/firecracker-manage.sh ssh <vm_id>"
    echo "  • Stop VM: ${SCRIPT_DIR}/firecracker-manage.sh stop <vm_id>"
    echo "  • Resize disk: ${SCRIPT_DIR}/firecracker-manage.sh resize <vm_id> 20G"
    echo ""
    
    print_header "Step 4: Custom Kernel Example"
    print_info "To build and use a custom kernel with container support:"
    echo "  1. Build kernel: ${SCRIPT_DIR}/build-firecracker-kernel.sh"
    echo "  2. Use custom kernel: ${SCRIPT_DIR}/firecracker-setup.sh --custom-kernel ./firecracker-vm/vmlinux-custom"
    echo ""
    
    print_header "Example Complete!"
    print_info "VM is ready for use. Check the management script for more operations."
}

# Run main function
main "$@" 