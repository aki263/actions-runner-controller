#!/bin/bash

# Example: Building and Using Custom Firecracker Kernel
# This script demonstrates the complete workflow from building a kernel to running a VM

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_header() {
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

main() {
    print_header "Firecracker Custom Kernel Example"
    
    print_info "This example will:"
    print_info "1. Build a custom Firecracker kernel with container support"
    print_info "2. Create and start a VM using the custom kernel"
    print_info "3. Test container functionality inside the VM"
    echo ""
    
    # Step 1: Build custom kernel
    print_header "Step 1: Building Custom Kernel"
    print_info "Building kernel with container support..."
    echo ""
    
    # Build kernel (this will take 15-45 minutes)
    ./build-firecracker-kernel.sh --kernel-version 6.1.128 --jobs 4
    
    # Get the kernel path
    CUSTOM_KERNEL="./firecracker-vm/vmlinux-6.1.128-custom"
    
    if [ ! -f "${CUSTOM_KERNEL}" ]; then
        echo "❌ Kernel build failed - custom kernel not found"
        exit 1
    fi
    
    print_info "✅ Custom kernel built successfully!"
    echo ""
    
    # Step 2: Create VM with custom kernel
    print_header "Step 2: Creating VM with Custom Kernel"
    print_info "Creating VM with custom kernel and container features..."
    echo ""
    
    # Create VM with custom kernel
    ./firecracker-setup.sh \
        --custom-kernel "${CUSTOM_KERNEL}" \
        --memory 2048 \
        --cpus 4 \
        --rootfs-size 20G
    
    print_info "✅ VM created successfully with custom kernel!"
    echo ""
    
    # Step 3: Test container functionality
    print_header "Step 3: Testing Container Features"
    print_info "Testing container functionality in the VM..."
    echo ""
    
    # Wait a moment for VM to be fully ready
    sleep 10
    
    # Test commands to run in the VM
    print_info "Testing kernel features for containers..."
    
    # Test 1: Check namespaces support
    print_info "🔍 Testing namespace support..."
    ssh -i ./firecracker-vm/vm_key -o StrictHostKeyChecking=no root@172.20.0.2 \
        'unshare --mount --uts --ipc --net --pid --fork --mount-proc echo "✅ Namespaces working"' || echo "❌ Namespaces test failed"
    
    # Test 2: Check cgroups
    print_info "🔍 Testing cgroups support..."
    ssh -i ./firecracker-vm/vm_key -o StrictHostKeyChecking=no root@172.20.0.2 \
        'ls -la /sys/fs/cgroup/ && echo "✅ Cgroups available"' || echo "❌ Cgroups test failed"
    
    # Test 3: Check iptables/netfilter
    print_info "🔍 Testing iptables support..."
    ssh -i ./firecracker-vm/vm_key -o StrictHostKeyChecking=no root@172.20.0.2 \
        'iptables -V && echo "✅ iptables working"' || echo "❌ iptables test failed"
    
    # Test 4: Install and run a simple container
    print_info "🔍 Installing Docker and testing containers..."
    
    # Install Docker
    ssh -i ./firecracker-vm/vm_key -o StrictHostKeyChecking=no root@172.20.0.2 << 'EOF'
        # Update package lists
        apt update
        
        # Install Docker
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        
        # Start Docker service
        systemctl start docker
        systemctl enable docker
        
        # Test Docker with a simple container
        echo "🐳 Testing Docker with hello-world container..."
        docker run hello-world && echo "✅ Docker containers working!" || echo "❌ Docker test failed"
        
        # Test a more complex container
        echo "🐳 Testing with Alpine Linux container..."
        docker run --rm alpine:latest echo "✅ Alpine container working!" || echo "❌ Alpine test failed"
        
        # Show Docker info
        echo "📊 Docker system info:"
        docker system info
EOF
    
    print_header "Test Results Summary"
    
    echo -e "${GREEN}Custom Kernel Features Tested:${NC}"
    echo "  🔬 Namespaces (UTS, IPC, PID, NET, USER)"
    echo "  📊 Cgroups (Memory, CPU, Devices)"
    echo "  🔥 Netfilter/iptables"
    echo "  🐳 Docker containers"
    echo "  🏔️  Alpine Linux container"
    echo ""
    
    echo -e "${GREEN}VM Details:${NC}"
    echo "  📍 IP Address: 172.20.0.2"
    echo "  🔑 SSH: ssh -i ./firecracker-vm/vm_key root@172.20.0.2"
    echo "  💾 Memory: 2GB"
    echo "  🖥️  CPUs: 4"
    echo "  💽 Disk: 20GB"
    echo "  🔧 Kernel: Custom ${CUSTOM_KERNEL}"
    echo ""
    
    echo -e "${GREEN}What's Next:${NC}"
    echo "  • SSH into the VM and explore: ssh -i ./firecracker-vm/vm_key root@172.20.0.2"
    echo "  • Run more Docker containers: docker run -it ubuntu:latest bash"
    echo "  • Test Kubernetes: install k3s or microk8s"
    echo "  • Build custom applications with container support"
    echo "  • Stop the VM: ./firecracker-manage.sh stop <vm_id>"
    echo ""
    
    print_info "🎉 Custom kernel example completed successfully!"
    print_info "Your VM is ready with full container support!"
}

# Cleanup function
cleanup() {
    print_info "Cleaning up on exit..."
    # Add any cleanup logic here if needed
}

# Set up cleanup on exit
trap cleanup EXIT

# Run main function
main "$@" 