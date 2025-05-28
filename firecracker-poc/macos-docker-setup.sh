#!/bin/bash

# macOS Development Script - Use Docker for Container Testing
# Since Firecracker requires Linux/KVM, this provides an alternative for macOS development

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

print_header() {
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed or not in PATH"
        print_info "Please install Docker Desktop for macOS:"
        print_info "  https://docs.docker.com/desktop/install/mac-install/"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        print_error "Docker is not running"
        print_info "Please start Docker Desktop"
        exit 1
    fi
    
    print_info "✅ Docker is available and running"
}

run_ubuntu_container() {
    print_header "Starting Ubuntu 24.04 Container for Firecracker Development"
    
    local container_name="firecracker-dev"
    
    # Stop and remove existing container if it exists
    if docker ps -a | grep -q "$container_name"; then
        print_info "Removing existing container..."
        docker rm -f "$container_name" || true
    fi
    
    print_info "Starting Ubuntu 24.04 container with privileged access..."
    print_info "This container can run Firecracker and KVM operations"
    
    # Mount the current directory to access scripts
    docker run -it --rm --privileged \
        --name "$container_name" \
        -v "$(pwd):/workspace" \
        -w /workspace \
        ubuntu:24.04 bash -c "
            echo 'Setting up Firecracker environment...'
            apt-get update
            apt-get install -y curl qemu-utils debootstrap openssh-client build-essential
            
            echo 'Installing Firecracker...'
            curl -LOJ https://github.com/firecracker-microvm/firecracker/releases/latest/download/firecracker-v*-x86_64.tgz
            tar -xzf firecracker-*.tgz
            mv release-*/firecracker-* /usr/local/bin/firecracker
            
            echo ''
            echo '================================================================'
            echo 'Firecracker Development Environment Ready!'
            echo '================================================================'
            echo 'You can now run:'
            echo '  ./firecracker-setup.sh -k /workspace/firecracker-vm/vmlinux-6.1.128-custom'
            echo '  ./build-firecracker-kernel.sh'
            echo '  ./firecracker-manage.sh list'
            echo ''
            echo 'Note: KVM may not be available in Docker, but you can test scripts'
            echo 'Files in /workspace are your local firecracker-poc directory'
            echo '================================================================'
            echo ''
            
            bash
        "
}

create_test_container() {
    print_header "Creating Test Container for Container Workloads"
    
    print_info "Since Firecracker isn't available on macOS, here's a test container"
    print_info "that demonstrates the same container capabilities your custom kernel enables"
    
    cat > test-container-features.sh << 'EOF'
#!/bin/bash

echo "Testing Container Features (similar to what your Firecracker kernel enables):"
echo ""

echo "1. Testing Namespaces:"
unshare --help | grep -E "mount|uts|ipc|net|pid|user" | head -3 || echo "  unshare command available"

echo ""
echo "2. Testing Cgroups:"
if [ -d "/sys/fs/cgroup" ]; then
    echo "  ✅ Cgroups filesystem available"
    ls /sys/fs/cgroup/ | head -5
else
    echo "  ❌ Cgroups not available"
fi

echo ""
echo "3. Testing Network Features:"
if command -v iptables &> /dev/null; then
    echo "  ✅ iptables available"
else
    echo "  ❌ iptables not available"
fi

echo ""
echo "4. Testing Overlay Filesystem:"
if grep -q overlay /proc/filesystems; then
    echo "  ✅ Overlay filesystem supported"
else
    echo "  ❌ Overlay filesystem not supported"
fi

echo ""
echo "5. Running a simple Docker container:"
if command -v docker &> /dev/null; then
    docker run --rm hello-world
else
    echo "  Docker not available in this environment"
fi
EOF

    chmod +x test-container-features.sh
    
    docker run -it --rm --privileged \
        -v "$(pwd):/workspace" \
        -w /workspace \
        ubuntu:24.04 bash -c "
            apt-get update
            apt-get install -y curl iptables util-linux
            ./test-container-features.sh
        "
}

show_macos_instructions() {
    print_header "macOS Development Instructions"
    
    echo -e "${GREEN}For Firecracker Development on macOS:${NC}"
    echo ""
    echo "1. ${YELLOW}Use this script for container testing:${NC}"
    echo "   ./macos-docker-setup.sh container"
    echo ""
    echo "2. ${YELLOW}Use this script for Ubuntu environment:${NC}"
    echo "   ./macos-docker-setup.sh ubuntu"
    echo ""
    echo "3. ${YELLOW}For production Firecracker:${NC}"
    echo "   - Deploy to Ubuntu 24.04 server/VM"
    echo "   - Copy your built kernel: vmlinux-6.1.128-custom"
    echo "   - Run: ./firecracker-setup.sh -k /path/to/custom-kernel"
    echo ""
    echo "4. ${YELLOW}Alternative virtualization for macOS:${NC}"
    echo "   - UTM (QEMU-based): https://mac.getutm.app/"
    echo "   - Parallels Desktop with Linux VM"
    echo "   - VMware Fusion with Ubuntu VM"
    echo ""
    echo -e "${BLUE}Files created:${NC}"
    echo "  - test-container-features.sh (test script)"
    echo ""
}

main() {
    print_header "Firecracker Development Helper for macOS"
    
    print_warning "Firecracker requires Linux with KVM support"
    print_warning "This script provides alternatives for macOS development"
    echo ""
    
    case "${1:-help}" in
        ubuntu)
            check_docker
            run_ubuntu_container
            ;;
        container|test)
            check_docker
            create_test_container
            ;;
        help|--help|-h)
            show_macos_instructions
            ;;
        *)
            show_macos_instructions
            ;;
    esac
}

main "$@" 