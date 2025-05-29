#!/bin/bash

# Quick Start: Custom Firecracker Kernel
# This script provides a quick way to build and test a custom kernel

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_header() {
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

show_menu() {
    print_header "Firecracker Custom Kernel Quick Start"
    echo ""
    echo "Choose an option:"
    echo ""
    echo "1) 🚀 Quick VM with downloaded kernel (fast, basic features)"
    echo "2) 🔧 Build custom kernel and create VM (slower, full container support)"
    echo "3) 📋 Compare kernel features"
    echo "4) 🧹 Clean up all VMs and build artifacts"
    echo "5) ❌ Exit"
    echo ""
}

quick_vm() {
    print_header "Option 1: Quick VM with Downloaded Kernel"
    print_info "Creating VM with pre-built Firecracker kernel..."
    print_warning "Note: This kernel has limited container support"
    echo ""
    
    ./firecracker-setup.sh --memory 1024 --cpus 2 --rootfs-size 15G
    
    print_info "✅ VM created! Limited container features available."
    print_info "SSH: ssh -i ./firecracker-vm/vm_key root@172.20.0.2"
}

custom_kernel_vm() {
    print_header "Option 2: Custom Kernel with Full Container Support"
    print_info "This will take 15-45 minutes but provides full container support..."
    echo ""
    
    # Ask user for confirmation
    read -p "Do you want to proceed with kernel build? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Kernel build cancelled"
        return
    fi
    
    print_info "Building custom kernel with container support..."
    ./build-firecracker-kernel.sh --kernel-version 6.1.128
    
    if [ ! -f "./firecracker-vm/vmlinux-6.1.128-custom" ]; then
        print_info "❌ Kernel build failed"
        return
    fi
    
    print_info "Creating VM with custom kernel..."
    ./firecracker-setup.sh \
        --custom-kernel ./firecracker-vm/vmlinux-6.1.128-custom \
        --memory 2048 \
        --cpus 4 \
        --rootfs-size 25G
    
    print_info "✅ VM created with full container support!"
    print_info "SSH: ssh -i ./firecracker-vm/vm_key root@172.20.0.2"
    
    echo ""
    print_info "Testing container features..."
    sleep 5
    
    # Quick test
    ssh -i ./firecracker-vm/vm_key -o StrictHostKeyChecking=no root@172.20.0.2 \
        'echo "Testing container features..." && \
         unshare --mount --uts --ipc --net --pid --fork --mount-proc echo "✅ Namespaces work!" || echo "❌ Namespaces failed" && \
         ls /sys/fs/cgroup/ > /dev/null && echo "✅ Cgroups available!" || echo "❌ Cgroups failed" && \
         iptables -V > /dev/null && echo "✅ iptables works!" || echo "❌ iptables failed"'
}

compare_features() {
    print_header "Option 3: Kernel Feature Comparison"
    
    cat << 'EOF'
┌─────────────────────────────────────────────────────────────────┐
│                    KERNEL FEATURE COMPARISON                   │
├─────────────────────────────────────────────────────────────────┤
│ Feature                │ Downloaded Kernel │ Custom Kernel      │
├────────────────────────┼───────────────────┼────────────────────┤
│ Boot Time              │ ⚡ Fast (~5s)     │ 🐌 Fast (~5s)      │
│ Size                   │ 📦 Small (~8MB)   │ 📦 Medium (~12MB)  │
│ Build Time             │ ⚡ None           │ 🕐 15-45 minutes   │
│                        │                   │                    │
│ Container Support:     │                   │                    │
│ - Docker/Podman        │ ❌ Limited        │ ✅ Full support    │
│ - Namespaces           │ ⚠️  Partial       │ ✅ Complete        │
│ - Cgroups              │ ⚠️  Basic         │ ✅ Full features   │
│ - iptables/netfilter   │ ❌ Missing        │ ✅ Full support    │
│ - Overlay filesystem   │ ❌ No             │ ✅ Yes             │
│ - Bridge networking    │ ❌ Limited        │ ✅ Full support    │
│                        │                   │                    │
│ Use Cases:             │                   │                    │
│ - Simple apps          │ ✅ Great          │ ✅ Great           │
│ - Static binaries      │ ✅ Perfect        │ ✅ Perfect         │
│ - Container workloads  │ ❌ Not suitable   │ ✅ Excellent       │
│ - Kubernetes           │ ❌ Won't work     │ ✅ Works well      │
│ - Development          │ ⚠️  Limited       │ ✅ Full featured   │
│                        │                   │                    │
│ Recommendation:        │ Quick testing     │ Production use     │
│                        │ Static workloads  │ Container apps     │
└────────────────────────┴───────────────────┴────────────────────┘

Performance Impact of Custom Kernel:
• Slightly larger size (+4MB)
• Same boot performance
• Better runtime performance for containers
• Full compatibility with container ecosystems

Build Time Breakdown:
• Download kernel source: ~2 minutes
• Configure kernel: ~1 minute  
• Compile kernel: ~15-40 minutes (depends on CPU)
• Total: ~20-45 minutes

EOF
}

cleanup_all() {
    print_header "Option 4: Cleanup"
    
    print_info "Cleaning up VMs..."
    if [ -f "./firecracker-manage.sh" ]; then
        ./firecracker-manage.sh cleanup
    fi
    
    print_info "Cleaning up build artifacts..."
    if [ -d "./kernel-build" ]; then
        rm -rf ./kernel-build
        print_info "Removed kernel build directory"
    fi
    
    if [ -d "./firecracker-vm" ]; then
        read -p "Remove VM directory (./firecracker-vm)? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf ./firecracker-vm
            print_info "Removed VM directory"
        fi
    fi
    
    print_info "✅ Cleanup completed"
}

main() {
    while true; do
        show_menu
        read -p "Enter your choice [1-5]: " choice
        echo ""
        
        case $choice in
            1)
                quick_vm
                ;;
            2)
                custom_kernel_vm
                ;;
            3)
                compare_features
                ;;
            4)
                cleanup_all
                ;;
            5)
                print_info "Goodbye!"
                exit 0
                ;;
            *)
                print_warning "Invalid option. Please choose 1-5."
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
        echo ""
    done
}

# Check if required scripts exist
if [ ! -f "./firecracker-setup.sh" ]; then
    echo "❌ firecracker-setup.sh not found in current directory"
    exit 1
fi

if [ ! -f "./build-firecracker-kernel.sh" ]; then
    echo "❌ build-firecracker-kernel.sh not found in current directory"
    exit 1
fi

# Run main menu
main 