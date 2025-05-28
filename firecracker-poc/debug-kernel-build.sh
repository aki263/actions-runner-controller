#!/bin/bash

# Debug version of the kernel build script
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/kernel-build"
KERNEL_VERSION="6.1.128"
KERNEL_MAJOR_VERSION="${KERNEL_VERSION%.*.*}"
OUTPUT_DIR="${SCRIPT_DIR}/firecracker-vm"

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

debug_step() {
    echo -e "${YELLOW}[DEBUG]${NC} $1"
    read -p "Press Enter to continue..."
}

check_dependencies() {
    print_header "Checking Dependencies (Debug Mode)"
    
    local deps=("curl" "tar" "make" "gcc" "flex" "bison" "bc" "git")
    local missing_deps=()
    
    # Check basic tools
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
            print_error "Missing: $dep"
        else
            print_info "Found: $dep"
        fi
    done
    
    # Check development packages
    local dev_packages=("libssl-dev" "libelf-dev" "build-essential" "pkg-config")
    for pkg in "${dev_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$pkg" 2>/dev/null; then
            missing_deps+=("$pkg")
            print_error "Missing package: $pkg"
        else
            print_info "Found package: $pkg"
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
    debug_step "Dependencies check completed"
}

setup_build_environment() {
    print_header "Setting Up Build Environment (Debug Mode)"
    
    # Create build directory
    mkdir -p "${BUILD_DIR}"
    mkdir -p "${OUTPUT_DIR}"
    
    print_info "Build directory: ${BUILD_DIR}"
    print_info "Output directory: ${OUTPUT_DIR}"
    
    cd "${BUILD_DIR}"
    print_info "Current directory: $(pwd)"
    
    debug_step "Build environment setup completed"
}

clone_firecracker_repo() {
    print_header "Getting Firecracker Repository (Debug Mode)"
    
    local firecracker_dir="firecracker"
    
    print_info "Checking if Firecracker repo exists: ${firecracker_dir}"
    
    if [ ! -d "${firecracker_dir}" ]; then
        print_info "Cloning Firecracker repository..."
        print_info "Running: git clone --depth 1 https://github.com/firecracker-microvm/firecracker.git"
        
        if git clone --depth 1 https://github.com/firecracker-microvm/firecracker.git; then
            print_info "✅ Firecracker repository cloned successfully"
        else
            print_error "❌ Failed to clone Firecracker repository"
            exit 1
        fi
    else
        print_info "Firecracker repository already exists"
        cd "${firecracker_dir}"
        if git pull origin main; then
            print_info "✅ Repository updated"
        else
            print_warning "⚠️ Could not update repository"
        fi
        cd ..
    fi
    
    # Verify the directory and check for config files
    if [ -d "${firecracker_dir}" ]; then
        print_info "✅ Firecracker directory exists"
        print_info "Directory contents:"
        ls -la "${firecracker_dir}" | head -10
        
        print_info "Checking for guest configs..."
        if [ -d "${firecracker_dir}/resources/guest_configs" ]; then
            print_info "✅ Guest configs directory found"
            print_info "Available config files:"
            ls -la "${firecracker_dir}/resources/guest_configs/"
        else
            print_error "❌ Guest configs directory not found"
            exit 1
        fi
    else
        print_error "❌ Firecracker directory does not exist after clone"
        exit 1
    fi
    
    debug_step "Firecracker repo setup completed"
}

get_firecracker_config() {
    print_header "Getting Firecracker Kernel Configuration (Debug Mode)"
    
    local config_file="microvm-kernel-x86_64-${KERNEL_MAJOR_VERSION}.config"
    local firecracker_config_path="firecracker/resources/guest_configs/${config_file}"
    
    print_info "Looking for config file: ${config_file}"
    print_info "Full path: ${firecracker_config_path}"
    
    # Try to get config from cloned repo first
    if [ -f "${firecracker_config_path}" ]; then
        print_info "✅ Using kernel config from Firecracker repo: ${config_file}"
        cp "${firecracker_config_path}" "${config_file}"
        print_info "Config file size: $(du -h "${config_file}" | cut -f1)"
    else
        print_warning "⚠️ Config file not found in repo, trying to download..."
        
        # Fallback to downloading from GitHub
        print_info "Downloading base kernel config for ${KERNEL_MAJOR_VERSION}..."
        
        local config_urls=(
            "https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/${config_file}"
            "https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-x86_64-6.1.config"
            "https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-x86_64-5.10.config"
        )
        
        local downloaded=false
        for url in "${config_urls[@]}"; do
            print_info "Trying URL: $url"
            if curl -fsSL "$url" -o "${config_file}" 2>/dev/null; then
                print_info "✅ Downloaded base config from: $url"
                print_info "Downloaded file size: $(du -h "${config_file}" | cut -f1)"
                downloaded=true
                break
            else
                print_warning "⚠️ Failed to download from: $url"
            fi
        done
        
        if [ "$downloaded" = false ]; then
            print_error "❌ Failed to download base kernel config"
            exit 1
        fi
    fi
    
    # Verify the config file
    if [ -f "${config_file}" ]; then
        print_info "✅ Config file ready: ${config_file}"
        print_info "First few lines of config:"
        head -5 "${config_file}"
    else
        print_error "❌ Config file not found after processing"
        exit 1
    fi
    
    debug_step "Config file acquisition completed"
    echo "${config_file}"
}

main() {
    print_header "Firecracker Kernel Build - Debug Mode"
    
    print_info "This debug version will help identify where the build process fails"
    print_info "Kernel version: ${KERNEL_VERSION}"
    print_info "Build directory: ${BUILD_DIR}"
    print_info "Output directory: ${OUTPUT_DIR}"
    echo ""
    
    debug_step "Starting debug process"
    
    check_dependencies
    setup_build_environment
    clone_firecracker_repo
    
    local base_config
    base_config=$(get_firecracker_config)
    
    print_header "Debug Complete"
    print_info "✅ All steps completed successfully up to config acquisition"
    print_info "Base config file: ${base_config}"
    print_info "Ready to proceed with kernel customization and build"
    print_info ""
    print_info "To continue with the full build, run:"
    print_info "  ./build-firecracker-kernel.sh"
}

# Run main function
main "$@" 