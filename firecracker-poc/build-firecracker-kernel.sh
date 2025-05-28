#!/bin/bash

# Firecracker Kernel Builder
# Based on: https://github.com/firecracker-microvm/firecracker/blob/main/docs/rootfs-and-kernel-setup.md
# and: https://www.felipecruz.es/exploring-firecracker-microvms-for-multi-tenant-dagger-ci-cd-pipelines/

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

check_dependencies() {
    print_header "Checking Dependencies for Kernel Build"
    
    local deps=("curl" "tar" "make" "gcc" "flex" "bison" "bc" "libssl-dev" "libelf-dev")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if [[ "$dep" == "libssl-dev" ]] || [[ "$dep" == "libelf-dev" ]]; then
            # Check for development libraries
            if ! dpkg -l | grep -q "$dep" 2>/dev/null && ! rpm -qa | grep -q "${dep/-dev/-devel}" 2>/dev/null; then
                missing_deps+=("$dep")
            fi
        elif ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Install them with:"
        print_info "  Ubuntu/Debian: sudo apt update && sudo apt install -y build-essential curl flex bison bc libssl-dev libelf-dev"
        print_info "  RHEL/CentOS: sudo yum groupinstall 'Development Tools' && sudo yum install curl flex bison bc openssl-devel elfutils-libelf-devel"
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

download_base_config() {
    print_header "Downloading Base Firecracker Config"
    
    local config_file="microvm-kernel-x86_64-${KERNEL_MAJOR_VERSION}.config"
    
    if [ ! -f "${config_file}" ]; then
        print_info "Downloading base kernel config for ${KERNEL_MAJOR_VERSION}..."
        
        # Try different config file locations
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
            print_info "You can manually download a config file and place it at: ${BUILD_DIR}/${config_file}"
            exit 1
        fi
    else
        print_info "Base config already exists: ${config_file}"
    fi
    
    echo "${config_file}"
}

customize_kernel_config() {
    print_header "Customizing Kernel Configuration"
    
    local kernel_dir="linux-${KERNEL_VERSION}"
    local base_config="$1"
    
    cd "${kernel_dir}"
    
    # Copy base config
    cp "../${base_config}" .config
    
    print_info "Applying container-friendly kernel modifications..."
    
    # Enable container and networking features based on Felipe Cruz's blog
    # Reference: https://www.felipecruz.es/exploring-firecracker-microvms-for-multi-tenant-dagger-ci-cd-pipelines/
    
    # Core container support
    sed -i 's/^# CONFIG_NAMESPACES.*/CONFIG_NAMESPACES=y/' .config || echo "CONFIG_NAMESPACES=y" >> .config
    sed -i 's/^# CONFIG_UTS_NS.*/CONFIG_UTS_NS=y/' .config || echo "CONFIG_UTS_NS=y" >> .config
    sed -i 's/^# CONFIG_IPC_NS.*/CONFIG_IPC_NS=y/' .config || echo "CONFIG_IPC_NS=y" >> .config
    sed -i 's/^# CONFIG_PID_NS.*/CONFIG_PID_NS=y/' .config || echo "CONFIG_PID_NS=y" >> .config
    sed -i 's/^# CONFIG_NET_NS.*/CONFIG_NET_NS=y/' .config || echo "CONFIG_NET_NS=y" >> .config
    sed -i 's/^# CONFIG_USER_NS.*/CONFIG_USER_NS=y/' .config || echo "CONFIG_USER_NS=y" >> .config
    
    # Cgroups support
    sed -i 's/^# CONFIG_CGROUPS.*/CONFIG_CGROUPS=y/' .config || echo "CONFIG_CGROUPS=y" >> .config
    sed -i 's/^# CONFIG_CGROUP_FREEZER.*/CONFIG_CGROUP_FREEZER=y/' .config || echo "CONFIG_CGROUP_FREEZER=y" >> .config
    sed -i 's/^# CONFIG_CGROUP_DEVICE.*/CONFIG_CGROUP_DEVICE=y/' .config || echo "CONFIG_CGROUP_DEVICE=y" >> .config
    sed -i 's/^# CONFIG_CGROUP_CPUACCT.*/CONFIG_CGROUP_CPUACCT=y/' .config || echo "CONFIG_CGROUP_CPUACCT=y" >> .config
    sed -i 's/^# CONFIG_CGROUP_SCHED.*/CONFIG_CGROUP_SCHED=y/' .config || echo "CONFIG_CGROUP_SCHED=y" >> .config
    sed -i 's/^# CONFIG_MEMCG.*/CONFIG_MEMCG=y/' .config || echo "CONFIG_MEMCG=y" >> .config
    
    # Networking features for containers
    sed -i 's/^# CONFIG_NETFILTER.*/CONFIG_NETFILTER=y/' .config || echo "CONFIG_NETFILTER=y" >> .config
    sed -i 's/^# CONFIG_NETFILTER_ADVANCED.*/CONFIG_NETFILTER_ADVANCED=y/' .config || echo "CONFIG_NETFILTER_ADVANCED=y" >> .config
    sed -i 's/^# CONFIG_NF_CONNTRACK.*/CONFIG_NF_CONNTRACK=y/' .config || echo "CONFIG_NF_CONNTRACK=y" >> .config
    sed -i 's/^# CONFIG_NETFILTER_XTABLES.*/CONFIG_NETFILTER_XTABLES=y/' .config || echo "CONFIG_NETFILTER_XTABLES=y" >> .config
    
    # iptables support (as mentioned in Felipe's blog)
    sed -i 's/^# CONFIG_IP_NF_IPTABLES.*/CONFIG_IP_NF_IPTABLES=y/' .config || echo "CONFIG_IP_NF_IPTABLES=y" >> .config
    sed -i 's/^# CONFIG_IP_NF_FILTER.*/CONFIG_IP_NF_FILTER=y/' .config || echo "CONFIG_IP_NF_FILTER=y" >> .config
    sed -i 's/^# CONFIG_IP_NF_TARGET_REJECT.*/CONFIG_IP_NF_TARGET_REJECT=y/' .config || echo "CONFIG_IP_NF_TARGET_REJECT=y" >> .config
    sed -i 's/^# CONFIG_IP_NF_NAT.*/CONFIG_IP_NF_NAT=y/' .config || echo "CONFIG_IP_NF_NAT=y" >> .config
    sed -i 's/^# CONFIG_IP_NF_TARGET_MASQUERADE.*/CONFIG_IP_NF_TARGET_MASQUERADE=y/' .config || echo "CONFIG_IP_NF_TARGET_MASQUERADE=y" >> .config
    
    # IPv6 netfilter support
    sed -i 's/^# CONFIG_IP6_NF_IPTABLES.*/CONFIG_IP6_NF_IPTABLES=y/' .config
    sed -i 's/^# CONFIG_NETFILTER_XT_MARK.*/CONFIG_NETFILTER_XT_MARK=y/' .config
    sed -i 's/^# CONFIG_NETFILTER_XT_MATCH_COMMENT.*/CONFIG_NETFILTER_XT_MATCH_COMMENT=y/' .config
    sed -i 's/^# CONFIG_NETFILTER_XT_MATCH_MULTIPORT.*/CONFIG_NETFILTER_XT_MATCH_MULTIPORT=y/' .config
    
    # Bridge and veth support for container networking
    sed -i 's/^# CONFIG_BRIDGE.*/CONFIG_BRIDGE=y/' .config || echo "CONFIG_BRIDGE=y" >> .config
    sed -i 's/^# CONFIG_VETH.*/CONFIG_VETH=y/' .config || echo "CONFIG_VETH=y" >> .config
    
    # Overlay filesystem for containers
    sed -i 's/^# CONFIG_OVERLAY_FS.*/CONFIG_OVERLAY_FS=y/' .config || echo "CONFIG_OVERLAY_FS=y" >> .config
    
    # Crypto support (from Felipe's blog)
    sed -i 's/^# CONFIG_CRYPTO_CRC32_PCLMUL.*/CONFIG_CRYPTO_CRC32_PCLMUL=y/' .config
    sed -i 's/^# CONFIG_CRYPTO_CRC32C_INTEL.*/CONFIG_CRYPTO_CRC32C_INTEL=y/' .config
    sed -i 's/^# CONFIG_CRYPTO_GHASH_CLMUL_NI_INTEL.*/CONFIG_CRYPTO_GHASH_CLMUL_NI_INTEL=y/' .config
    sed -i 's/^# CONFIG_CRYPTO_AES_NI_INTEL.*/CONFIG_CRYPTO_AES_NI_INTEL=y/' .config
    sed -i 's/^# CONFIG_CRYPTO_CRYPTD.*/CONFIG_CRYPTO_CRYPTD=y/' .config
    
    # Additional useful features
    sed -i 's/^# CONFIG_INPUT_EVDEV.*/CONFIG_INPUT_EVDEV=y/' .config
    sed -i 's/^# CONFIG_NET_SCH_FQ_CODEL.*/CONFIG_NET_SCH_FQ_CODEL=y/' .config
    sed -i 's/^# CONFIG_AUTOFS4_FS.*/CONFIG_AUTOFS4_FS=y/' .config
    
    # Enable BPF for advanced container features
    sed -i 's/^# CONFIG_BPF_SYSCALL.*/CONFIG_BPF_SYSCALL=y/' .config || echo "CONFIG_BPF_SYSCALL=y" >> .config
    sed -i 's/^# CONFIG_BPF_JIT.*/CONFIG_BPF_JIT=y/' .config || echo "CONFIG_BPF_JIT=y" >> .config
    
    # Security features
    sed -i 's/^# CONFIG_SECCOMP.*/CONFIG_SECCOMP=y/' .config || echo "CONFIG_SECCOMP=y" >> .config
    sed -i 's/^# CONFIG_SECCOMP_FILTER.*/CONFIG_SECCOMP_FILTER=y/' .config || echo "CONFIG_SECCOMP_FILTER=y" >> .config
    
    print_info "Kernel configuration customized for container support"
    
    # Update config to resolve dependencies
    print_info "Resolving configuration dependencies..."
    make olddefconfig
    
    cd ..
}

build_kernel() {
    print_header "Building Kernel"
    
    local kernel_dir="linux-${KERNEL_VERSION}"
    
    cd "${kernel_dir}"
    
    print_info "Starting kernel build with ${JOBS} parallel jobs..."
    print_info "This may take 15-45 minutes depending on your system..."
    
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
    echo ""
    
    echo -e "${GREEN}Container Features Enabled:${NC}"
    echo "  ✅ Namespaces (UTS, IPC, PID, NET, USER)"
    echo "  ✅ Cgroups (CPU, Memory, Devices, Freezer)"
    echo "  ✅ Netfilter/iptables (IPv4 and IPv6)"
    echo "  ✅ Bridge and veth networking"
    echo "  ✅ Overlay filesystem"
    echo "  ✅ BPF and seccomp support"
    echo "  ✅ Crypto acceleration"
    echo ""
    
    echo -e "${GREEN}Usage with firecracker-setup.sh:${NC}"
    echo "  ./firecracker-setup.sh --custom-kernel ${kernel_path}"
    echo ""
    
    echo -e "${GREEN}Manual usage:${NC}"
    echo "  # Replace the downloaded kernel in firecracker-setup.sh"
    echo "  # with your custom kernel path"
}

cleanup_build() {
    print_header "Cleanup"
    
    local kernel_dir="linux-${KERNEL_VERSION}"
    
    if [ -d "${kernel_dir}" ]; then
        print_info "Cleaning build artifacts..."
        cd "${kernel_dir}"
        make clean
        cd ..
        print_info "Build artifacts cleaned"
    fi
    
    print_info "Build directory preserved at: ${BUILD_DIR}"
    print_info "You can remove it manually if needed: rm -rf ${BUILD_DIR}"
}

main() {
    print_header "Firecracker Custom Kernel Builder"
    
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
    
    check_dependencies
    setup_build_environment
    download_kernel_source
    
    local base_config
    base_config=$(download_base_config)
    
    customize_kernel_config "${base_config}"
    
    local kernel_path
    kernel_path=$(build_kernel)
    
    show_kernel_info "${kernel_path}"
    
    read -p "Do you want to clean build artifacts? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cleanup_build
    fi
    
    print_info "Custom kernel build completed!"
    print_info "You can now use this kernel with: ./firecracker-setup.sh --custom-kernel ${kernel_path}"
}

# Run main function
main "$@" 