#!/bin/bash

# Firecracker Kernel Builder for Ubuntu 24.04
# Based on official Firecracker devtool: https://github.com/firecracker-microvm/firecracker/blob/main/tools/devtool
# Adapted for direct Ubuntu execution (not containerized)

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/kernel-build"
KERNEL_VERSION="${KERNEL_VERSION:-6.1.128}"
KERNEL_MAJOR_VERSION="${KERNEL_VERSION%.*.*}"
OUTPUT_DIR="${SCRIPT_DIR}/firecracker-vm"
JOBS="${JOBS:-$(nproc)}"

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
    print_header "Checking Operating System"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        print_error "This script is designed to run on Ubuntu 24.04, not macOS"
        print_info "You are currently on macOS. Please run this script on your Ubuntu 24.04 machine."
        print_info "Transfer this script to your Ubuntu machine and run it there."
        exit 1
    fi
    
    if [[ ! -f /etc/os-release ]]; then
        print_warning "Cannot detect OS version, proceeding anyway..."
        return
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        print_warning "This script is optimized for Ubuntu 24.04, you're running $PRETTY_NAME"
        print_info "Proceeding anyway, but you may need to adjust package names..."
    else
        print_info "Running on $PRETTY_NAME - good!"
    fi
}

check_dependencies() {
    print_header "Checking Dependencies for Kernel Build on Ubuntu"
    
    local deps=("curl" "tar" "make" "gcc" "flex" "bison" "bc" "git")
    local missing_deps=()
    
    # Check basic tools
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    # Check development packages
    local dev_packages=("libssl-dev" "libelf-dev" "build-essential" "pkg-config")
    for pkg in "${dev_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$pkg" 2>/dev/null; then
            missing_deps+=("$pkg")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Install them with:"
        print_info "  sudo apt update"
        print_info "  sudo apt install -y build-essential curl flex bison bc libssl-dev libelf-dev pkg-config git"
        exit 1
    fi
    
    print_info "All dependencies satisfied"
}

setup_build_environment() {
    print_header "Setting Up Build Environment"
    
    # Create build directory
    mkdir -p "${BUILD_DIR}"
    mkdir -p "${OUTPUT_DIR}"
    cd "${BUILD_DIR}"
    
    print_info "Build directory: ${BUILD_DIR}"
    print_info "Output directory: ${OUTPUT_DIR}"
}

clone_firecracker_repo() {
    print_header "Getting Firecracker Repository"
    
    local firecracker_dir="firecracker"
    
    if [ ! -d "${firecracker_dir}" ]; then
        print_info "Cloning Firecracker repository..."
        git clone --depth 1 https://github.com/firecracker-microvm/firecracker.git
        print_info "Firecracker repository cloned"
    else
        print_info "Firecracker repository already exists"
        cd "${firecracker_dir}"
        git pull origin main || print_warning "Could not update repository"
        cd ..
    fi
}

download_kernel_source() {
    print_header "Downloading Kernel Source"
    
    local kernel_dir="linux-${KERNEL_VERSION}"
    local kernel_archive="linux-${KERNEL_VERSION}.tar.xz"
    
    if [ -d "${kernel_dir}" ]; then
        print_info "Kernel source already exists: ${kernel_dir}"
        return 0
    fi
    
    if [ ! -f "${kernel_archive}" ]; then
        print_info "Downloading Linux kernel ${KERNEL_VERSION}..."
        curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR_VERSION}.x/${kernel_archive}" -o "${kernel_archive}"
        print_info "Downloaded: ${kernel_archive}"
    fi
    
    print_info "Extracting kernel source..."
    tar -xf "${kernel_archive}"
    
    print_info "Kernel source ready: ${kernel_dir}"
}

get_firecracker_config() {
    print_header "Getting Firecracker Kernel Configuration"
    
    local config_file="microvm-kernel-x86_64-${KERNEL_MAJOR_VERSION}.config"
    local firecracker_config_path="firecracker/resources/guest_configs/${config_file}"
    
    # Try to get config from cloned repo first
    if [ -f "${firecracker_config_path}" ]; then
        print_info "Using kernel config from Firecracker repo: ${config_file}"
        cp "${firecracker_config_path}" "${config_file}"
    else
        # Fallback to downloading from GitHub
        print_info "Downloading base kernel config for ${KERNEL_MAJOR_VERSION}..."
        
        local config_urls=(
            "https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/${config_file}"
            "https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-x86_64-6.1.config"
            "https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-x86_64-5.10.config"
        )
        
        local downloaded=false
        for url in "${config_urls[@]}"; do
            if curl -fsSL "$url" -o "${config_file}" 2>/dev/null; then
                print_info "Downloaded base config from: $url"
                downloaded=true
                break
            fi
        done
        
        if [ "$downloaded" = false ]; then
            print_error "Failed to download base kernel config"
            exit 1
        fi
    fi
    
    echo "${config_file}"
}

customize_kernel_config() {
    print_header "Customizing Kernel Configuration for Containers"
    
    local kernel_dir="linux-${KERNEL_VERSION}"
    local base_config="$1"
    
    cd "${kernel_dir}"
    
    # Copy base config
    cp "../${base_config}" .config
    
    print_info "Applying container-friendly kernel modifications..."
    
    # Core container support (namespaces)
    echo "CONFIG_NAMESPACES=y" >> .config
    echo "CONFIG_UTS_NS=y" >> .config
    echo "CONFIG_IPC_NS=y" >> .config
    echo "CONFIG_PID_NS=y" >> .config
    echo "CONFIG_NET_NS=y" >> .config
    echo "CONFIG_USER_NS=y" >> .config
    
    # Cgroups support
    echo "CONFIG_CGROUPS=y" >> .config
    echo "CONFIG_CGROUP_FREEZER=y" >> .config
    echo "CONFIG_CGROUP_DEVICE=y" >> .config
    echo "CONFIG_CGROUP_CPUACCT=y" >> .config
    echo "CONFIG_CGROUP_SCHED=y" >> .config
    echo "CONFIG_MEMCG=y" >> .config
    echo "CONFIG_CGROUP_PIDS=y" >> .config
    
    # Networking features for containers
    echo "CONFIG_NETFILTER=y" >> .config
    echo "CONFIG_NETFILTER_ADVANCED=y" >> .config
    echo "CONFIG_NF_CONNTRACK=y" >> .config
    echo "CONFIG_NETFILTER_XTABLES=y" >> .config
    echo "CONFIG_IP_NF_IPTABLES=y" >> .config
    echo "CONFIG_IP_NF_FILTER=y" >> .config
    echo "CONFIG_IP_NF_NAT=y" >> .config
    echo "CONFIG_IP_NF_TARGET_MASQUERADE=y" >> .config
    echo "CONFIG_IP6_NF_IPTABLES=y" >> .config
    
    # Bridge and veth support for container networking
    echo "CONFIG_BRIDGE=y" >> .config
    echo "CONFIG_VETH=y" >> .config
    echo "CONFIG_MACVLAN=y" >> .config
    echo "CONFIG_IPVLAN=y" >> .config
    
    # Overlay filesystem for containers
    echo "CONFIG_OVERLAY_FS=y" >> .config
    
    # BPF and eBPF support
    echo "CONFIG_BPF=y" >> .config
    echo "CONFIG_BPF_SYSCALL=y" >> .config
    echo "CONFIG_BPF_JIT=y" >> .config
    echo "CONFIG_CGROUP_BPF=y" >> .config
    
    # Security features
    echo "CONFIG_SECCOMP=y" >> .config
    echo "CONFIG_SECCOMP_FILTER=y" >> .config
    echo "CONFIG_SECURITY=y" >> .config
    
    # Additional container features
    echo "CONFIG_DEVPTS_MULTIPLE_INSTANCES=y" >> .config
    echo "CONFIG_FHANDLE=y" >> .config
    echo "CONFIG_EVENTFD=y" >> .config
    echo "CONFIG_EPOLL=y" >> .config
    echo "CONFIG_SIGNALFD=y" >> .config
    echo "CONFIG_TIMERFD=y" >> .config
    
    print_info "Kernel configuration customized for container support"
    
    # Resolve configuration dependencies
    print_info "Resolving configuration dependencies..."
    make olddefconfig
    
    # Verify some key configs are enabled
    print_info "Verifying container features are enabled..."
    if grep -q "CONFIG_NAMESPACES=y" .config; then
        print_info "✅ Namespaces enabled"
    else
        print_warning "⚠️ Namespaces might not be enabled"
    fi
    
    if grep -q "CONFIG_CGROUPS=y" .config; then
        print_info "✅ Cgroups enabled"
    else
        print_warning "⚠️ Cgroups might not be enabled"
    fi
    
    cd ..
}

build_kernel() {
    print_header "Building Kernel"
    
    local kernel_dir="linux-${KERNEL_VERSION}"
    
    cd "${kernel_dir}"
    
    print_info "Starting kernel build with ${JOBS} parallel jobs..."
    print_info "This may take 15-45 minutes depending on your system..."
    
    # Clean any previous builds
    make clean
    
    # Build the kernel
    make -j"${JOBS}" vmlinux
    
    # Check if build was successful
    if [ ! -f "vmlinux" ]; then
        print_error "Kernel build failed - vmlinux not found"
        exit 1
    fi
    
    print_info "Kernel build completed successfully!"
    
    # Copy to output directory
    local output_kernel="${OUTPUT_DIR}/vmlinux-${KERNEL_VERSION}-custom"
    cp vmlinux "${output_kernel}"
    
    print_info "Kernel copied to: ${output_kernel}"
    
    # Create a symlink for easy reference
    ln -sf "vmlinux-${KERNEL_VERSION}-custom" "${OUTPUT_DIR}/vmlinux-custom"
    
    # Save the config used
    cp .config "${OUTPUT_DIR}/config-${KERNEL_VERSION}-custom"
    
    cd ..
    
    echo "${output_kernel}"
}

show_kernel_info() {
    local kernel_path="$1"
    
    print_header "Kernel Build Summary"
    
    echo -e "${GREEN}Custom Kernel Details:${NC}"
    echo "  Version: ${KERNEL_VERSION}"
    echo "  Location: ${kernel_path}"
    echo "  Size: $(du -h "${kernel_path}" | cut -f1)"
    echo "  Config: ${OUTPUT_DIR}/config-${KERNEL_VERSION}-custom"
    echo ""
    
    echo -e "${GREEN}Container Features Enabled:${NC}"
    echo "  ✅ Namespaces (UTS, IPC, PID, NET, USER)"
    echo "  ✅ Cgroups (CPU, Memory, Devices, Freezer, PIDs)"
    echo "  ✅ Netfilter/iptables (IPv4 and IPv6)"
    echo "  ✅ Bridge and veth networking"
    echo "  ✅ Overlay filesystem"
    echo "  ✅ BPF and seccomp support"
    echo "  ✅ Container security features"
    echo ""
    
    echo -e "${GREEN}Usage with firecracker-setup.sh:${NC}"
    echo "  ./firecracker-setup.sh --custom-kernel ${kernel_path}"
    echo ""
    
    echo -e "${GREEN}Verify kernel features:${NC}"
    echo "  # Check config"
    echo "  grep -E '(NAMESPACES|CGROUPS|OVERLAY_FS|BPF_SYSCALL)' ${OUTPUT_DIR}/config-${KERNEL_VERSION}-custom"
}

cleanup_build() {
    print_header "Cleanup Options"
    
    local kernel_dir="linux-${KERNEL_VERSION}"
    
    if [ -d "${kernel_dir}" ]; then
        print_info "Cleaning build artifacts in ${kernel_dir}..."
        cd "${kernel_dir}"
        make clean
        cd ..
        print_info "Build artifacts cleaned"
    fi
    
    print_info "Build directory: ${BUILD_DIR}"
    print_info "You can remove source files with: rm -rf ${BUILD_DIR}/linux-${KERNEL_VERSION}"
    print_info "You can remove the entire build directory with: rm -rf ${BUILD_DIR}"
}

main() {
    print_header "Firecracker Custom Kernel Builder for Ubuntu 24.04"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --kernel-version|-v)
                KERNEL_VERSION="$2"
                KERNEL_MAJOR_VERSION="${KERNEL_VERSION%.*.*}"
                shift 2
                ;;
            --jobs|-j)
                JOBS="$2"
                shift 2
                ;;
            --clean)
                if [ -d "${BUILD_DIR}" ]; then
                    print_info "Removing build directory: ${BUILD_DIR}"
                    rm -rf "${BUILD_DIR}"
                fi
                exit 0
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo ""
                echo "This script builds a custom Firecracker kernel with container support on Ubuntu 24.04"
                echo ""
                echo "Options:"
                echo "  --kernel-version, -v <version>  Kernel version to build (default: ${KERNEL_VERSION})"
                echo "  --jobs, -j <count>              Number of parallel jobs (default: $(nproc))"
                echo "  --clean                         Clean build directory and exit"
                echo "  --help, -h                      Show this help"
                echo ""
                echo "Examples:"
                echo "  $0                              # Build kernel ${KERNEL_VERSION}"
                echo "  $0 -v 6.1.55 -j 8             # Build kernel 6.1.55 with 8 jobs"
                echo "  $0 --clean                     # Clean build directory"
                echo ""
                echo "Requirements:"
                echo "  - Ubuntu 24.04 (or compatible Linux)"
                echo "  - build-essential, curl, flex, bison, bc, libssl-dev, libelf-dev"
                echo "  - At least 4GB RAM and 20GB free disk space"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    print_info "Building kernel version: ${KERNEL_VERSION}"
    print_info "Using ${JOBS} parallel jobs"
    print_info "Build directory: ${BUILD_DIR}"
    print_info "Output directory: ${OUTPUT_DIR}"
    echo ""
    
    check_os
    check_dependencies
    setup_build_environment
    clone_firecracker_repo
    download_kernel_source
    
    local base_config
    base_config=$(get_firecracker_config)
    
    customize_kernel_config "${base_config}"
    
    local kernel_path
    kernel_path=$(build_kernel)
    
    show_kernel_info "${kernel_path}"
    
    echo ""
    read -p "Do you want to clean build artifacts? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cleanup_build
    fi
    
    print_info "🎉 Custom kernel build completed!"
    print_info "You can now use this kernel with: ./firecracker-setup.sh --custom-kernel ${kernel_path}"
}

# Run main function
main "$@" 