#!/bin/bash

# Build GitHub Actions Runner Firecracker VM Image
# Similar to actions-runner-dind.ubuntu-22.04.dockerfile but for Firecracker

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/runner-image"
KERNEL_VERSION="6.1.128"
ROOTFS_SIZE="20G"  # Larger size for runner dependencies
CUSTOM_KERNEL=""

# GitHub Actions Runner configuration (similar to Dockerfile)
RUNNER_VERSION="${RUNNER_VERSION:-2.311.0}"
RUNNER_CONTAINER_HOOKS_VERSION="${RUNNER_CONTAINER_HOOKS_VERSION:-0.5.1}"
DOCKER_VERSION="${DOCKER_VERSION:-24.0.7}"
DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-v2.23.0}"
DUMB_INIT_VERSION="${DUMB_INIT_VERSION:-1.2.5}"
RUNNER_USER_UID="${RUNNER_USER_UID:-1001}"
DOCKER_GROUP_GID="${DOCKER_GROUP_GID:-121}"

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
        print_error "macOS is not supported as Firecracker requires Linux KVM."
        print_info ""
        print_info "Options for macOS users:"
        print_info "1. Use a Linux VM (VMware Fusion, Parallels, VirtualBox)"
        print_info "2. Use Docker Desktop with Linux containers"
        print_info "3. Use a cloud Linux instance (AWS EC2, Google Cloud, etc.)"
        exit 1
    fi
    
    if [[ "$(uname -s)" != "Linux" ]]; then
        print_error "This script requires Ubuntu 24.04 or compatible Linux distribution."
        print_error "Detected OS: $(uname -s)"
        exit 1
    fi
}

check_dependencies() {
    print_header "Checking Dependencies"
    
    local deps=("curl" "qemu-img" "debootstrap" "jq" "unzip")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Install them with:"
        print_info "  Ubuntu/Debian: sudo apt update && sudo apt install -y curl qemu-utils debootstrap jq unzip"
        exit 1
    fi
    
    print_info "All dependencies are satisfied"
}

setup_workspace() {
    print_header "Setting Up Workspace"
    
    mkdir -p "${WORK_DIR}"
    cd "${WORK_DIR}"
    
    print_info "Workspace created at: ${WORK_DIR}"
}

create_runner_rootfs() {
    print_header "Creating GitHub Actions Runner Root Filesystem"
    
    local rootfs_file="actions-runner-ubuntu-24.04.ext4"
    
    if [ -f "${rootfs_file}" ]; then
        print_warning "Rootfs already exists: ${rootfs_file}"
        read -p "Do you want to rebuild it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Using existing rootfs"
            return
        fi
        rm -f "${rootfs_file}"
    fi
    
    print_info "Creating ${ROOTFS_SIZE} GitHub Actions Runner rootfs..."
    
    # Create raw disk image
    qemu-img create -f raw "${rootfs_file}" "${ROOTFS_SIZE}"
    
    # Format with ext4
    mkfs.ext4 "${rootfs_file}"
    
    # Create mount point
    local mount_dir="rootfs_mount"
    mkdir -p "${mount_dir}"
    
    print_info "Mounting rootfs for setup..."
    sudo mount "${rootfs_file}" "${mount_dir}"
    
    # Create Ubuntu 24.04 rootfs with runner dependencies
    print_info "Installing Ubuntu 24.04 base system with runner dependencies..."
    sudo debootstrap --include=openssh-server,curl,wget,vim,htop,net-tools,iputils-ping,systemd,init,udev,kmod,sudo,bash-completion,ca-certificates,gnupg,lsb-release,cloud-init,software-properties-common,jq,unzip,zip,git,git-lfs,iptables \
        noble "${mount_dir}" http://archive.ubuntu.com/ubuntu/
    
    # Configure the rootfs for GitHub Actions runner
    print_info "Configuring GitHub Actions runner environment..."
    
    # Set hostname
    echo "actions-runner" | sudo tee "${mount_dir}/etc/hostname" > /dev/null
    
    # Add git-core PPA and install latest git
    sudo chroot "${mount_dir}" add-apt-repository -y ppa:git-core/ppa
    sudo chroot "${mount_dir}" apt-get update
    
    # Install git-lfs
    sudo chroot "${mount_dir}" bash -c 'curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | bash'
    sudo chroot "${mount_dir}" apt-get install -y git-lfs
    
    # Create runner user (similar to Dockerfile)
    sudo chroot "${mount_dir}" adduser --disabled-password --gecos "" --uid $RUNNER_USER_UID runner
    sudo chroot "${mount_dir}" groupadd docker --gid $DOCKER_GROUP_GID
    sudo chroot "${mount_dir}" usermod -aG sudo runner
    sudo chroot "${mount_dir}" usermod -aG docker runner
    
    # Configure sudo without password
    echo "%sudo   ALL=(ALL:ALL) NOPASSWD:ALL" | sudo tee "${mount_dir}/etc/sudoers.d/sudo-nopasswd" > /dev/null
    echo "Defaults env_keep += \"DEBIAN_FRONTEND\"" | sudo tee -a "${mount_dir}/etc/sudoers.d/sudo-nopasswd" > /dev/null
    
    # Install dumb-init
    print_info "Installing dumb-init..."
    local arch="x86_64"
    if [[ "$(uname -m)" == "aarch64" ]]; then
        arch="aarch64"
    fi
    
    sudo curl -fLo "${mount_dir}/usr/bin/dumb-init" \
        "https://github.com/Yelp/dumb-init/releases/download/v${DUMB_INIT_VERSION}/dumb-init_${DUMB_INIT_VERSION}_${arch}"
    sudo chmod +x "${mount_dir}/usr/bin/dumb-init"
    
    # Download and install GitHub Actions runner
    print_info "Installing GitHub Actions runner v${RUNNER_VERSION}..."
    local runner_arch="x64"
    if [[ "$(uname -m)" == "aarch64" ]]; then
        runner_arch="arm64"
    fi
    
    sudo mkdir -p "${mount_dir}/runnertmp"
    sudo curl -fLo "${mount_dir}/runnertmp/runner.tar.gz" \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz"
    
    sudo chroot "${mount_dir}" bash -c "cd /runnertmp && tar xzf runner.tar.gz && rm -f runner.tar.gz"
    sudo chroot "${mount_dir}" bash -c "cd /runnertmp && ./bin/installdependencies.sh"
    
    # Install libyaml-dev for ruby/setup-ruby action
    sudo chroot "${mount_dir}" apt-get install -y libyaml-dev
    
    # Create tool cache directory
    sudo mkdir -p "${mount_dir}/opt/hostedtoolcache"
    sudo chroot "${mount_dir}" chgrp docker /opt/hostedtoolcache
    sudo chroot "${mount_dir}" chmod g+rwx /opt/hostedtoolcache
    
    # Install runner container hooks
    print_info "Installing runner container hooks v${RUNNER_CONTAINER_HOOKS_VERSION}..."
    sudo curl -fLo "${mount_dir}/runnertmp/runner-container-hooks.zip" \
        "https://github.com/actions/runner-container-hooks/releases/download/v${RUNNER_CONTAINER_HOOKS_VERSION}/actions-runner-hooks-k8s-${RUNNER_CONTAINER_HOOKS_VERSION}.zip"
    
    sudo chroot "${mount_dir}" bash -c "cd /runnertmp && unzip runner-container-hooks.zip -d k8s && rm -f runner-container-hooks.zip"
    
    # Install Docker
    print_info "Installing Docker v${DOCKER_VERSION}..."
    local docker_arch="x86_64"
    if [[ "$(uname -m)" == "aarch64" ]]; then
        docker_arch="aarch64"
    fi
    
    sudo curl -fLo "${mount_dir}/tmp/docker.tgz" \
        "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_VERSION}.tgz"
    
    sudo chroot "${mount_dir}" bash -c "cd /tmp && tar zxvf docker.tgz && install -o root -g root -m 755 docker/* /usr/bin/ && rm -rf docker docker.tgz"
    
    # Install Docker Compose
    print_info "Installing Docker Compose ${DOCKER_COMPOSE_VERSION}..."
    sudo mkdir -p "${mount_dir}/usr/libexec/docker/cli-plugins"
    sudo curl -fLo "${mount_dir}/usr/libexec/docker/cli-plugins/docker-compose" \
        "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${docker_arch}"
    sudo chmod +x "${mount_dir}/usr/libexec/docker/cli-plugins/docker-compose"
    sudo chroot "${mount_dir}" ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/bin/docker-compose
    
    # Configure environment
    print_info "Configuring runner environment..."
    
    # Set environment variables
    sudo tee "${mount_dir}/etc/environment" > /dev/null <<EOF
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/runner/.local/bin
HOME=/home/runner
RUNNER_ASSETS_DIR=/runnertmp
RUNNER_TOOL_CACHE=/opt/hostedtoolcache
ImageOS=ubuntu24
DEBIAN_FRONTEND=noninteractive
EOF
    
    # Create runner startup script
    sudo tee "${mount_dir}/usr/local/bin/start-runner.sh" > /dev/null <<'EOF'
#!/bin/bash
set -euo pipefail

# GitHub Actions Runner startup script for Firecracker VM

RUNNER_ASSETS_DIR=${RUNNER_ASSETS_DIR:-/runnertmp}
RUNNER_WORK_DIR=${RUNNER_WORK_DIR:-/home/runner/_work}
GITHUB_TOKEN=${GITHUB_TOKEN:-}
GITHUB_URL=${GITHUB_URL:-}
RUNNER_NAME=${RUNNER_NAME:-$(hostname)}
RUNNER_LABELS=${RUNNER_LABELS:-firecracker}

echo "Starting GitHub Actions Runner..."
echo "Runner Name: $RUNNER_NAME"
echo "Labels: $RUNNER_LABELS"
echo "GitHub URL: $GITHUB_URL"

# Ensure runner user owns the assets directory
sudo chown -R runner:runner $RUNNER_ASSETS_DIR
sudo mkdir -p $RUNNER_WORK_DIR
sudo chown -R runner:runner $RUNNER_WORK_DIR

# Switch to runner user and configure the runner
cd $RUNNER_ASSETS_DIR
sudo -u runner bash -c "
    if [ ! -f .runner ]; then
        echo 'Configuring runner...'
        ./config.sh --url $GITHUB_URL --token $GITHUB_TOKEN --name $RUNNER_NAME --labels $RUNNER_LABELS --work $RUNNER_WORK_DIR --unattended --replace
    fi
    
    echo 'Starting runner...'
    ./run.sh
"
EOF
    
    sudo chmod +x "${mount_dir}/usr/local/bin/start-runner.sh"
    
    # Create systemd service for runner
    sudo tee "${mount_dir}/etc/systemd/system/actions-runner.service" > /dev/null <<EOF
[Unit]
Description=GitHub Actions Runner
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/start-runner.sh
Restart=always
RestartSec=10
Environment=RUNNER_ALLOW_RUNASROOT=1

[Install]
WantedBy=multi-user.target
EOF
    
    # Create cloud-init ready marker
    sudo tee "${mount_dir}/etc/runner-image-info" > /dev/null <<EOF
# GitHub Actions Runner Image Information
RUNNER_VERSION=${RUNNER_VERSION}
DOCKER_VERSION=${DOCKER_VERSION}
IMAGE_BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
IMAGE_TYPE=firecracker-actions-runner
UBUNTU_VERSION=24.04
EOF
    
    # Create welcome script for runner
    sudo tee "${mount_dir}/root/welcome.sh" > /dev/null <<'EOF'
#!/bin/bash
echo "=============================================="
echo "GitHub Actions Runner - Firecracker VM"
echo "=============================================="
echo "VM IP: $(ip addr show eth0 | grep -oP 'inet \K[\d.]+')"
echo "Runner Status: $(systemctl is-active actions-runner || echo 'Not configured')"
echo "=============================================="
echo "To configure runner:"
echo "  export GITHUB_TOKEN=<your-token>"
echo "  export GITHUB_URL=<repo-or-org-url>"
echo "  export RUNNER_NAME=<unique-name>"
echo "  systemctl start actions-runner"
echo "=============================================="
cat /etc/runner-image-info
echo "=============================================="
EOF
    
    sudo chmod +x "${mount_dir}/root/welcome.sh"
    echo "/root/welcome.sh" | sudo tee -a "${mount_dir}/root/.bashrc" > /dev/null
    
    # Configure SSH for both root and runner user
    sudo mkdir -p "${mount_dir}/root/.ssh" "${mount_dir}/home/runner/.ssh"
    sudo chmod 700 "${mount_dir}/root/.ssh" "${mount_dir}/home/runner/.ssh"
    sudo chroot "${mount_dir}" chown runner:runner /home/runner/.ssh
    
    # Configure SSH server
    sudo tee "${mount_dir}/etc/ssh/sshd_config.d/runner.conf" > /dev/null <<EOF
PermitRootLogin yes
PasswordAuthentication no
PubkeyAuthentication yes
Port 22
AddressFamily inet
ListenAddress 0.0.0.0
EOF
    
    # Enable SSH service
    sudo chroot "${mount_dir}" systemctl enable ssh
    
    # Clean up
    sudo chroot "${mount_dir}" rm -rf /var/lib/apt/lists/*
    sudo umount "${mount_dir}"
    rmdir "${mount_dir}"
    
    print_info "GitHub Actions Runner rootfs created: ${rootfs_file}"
    
    # Show image info
    local image_size=$(du -h "${rootfs_file}" | cut -f1)
    print_info "Image size: ${image_size}"
    print_info "Runner version: ${RUNNER_VERSION}"
    print_info "Docker version: ${DOCKER_VERSION}"
}

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --runner-version <version>    GitHub Actions runner version (default: ${RUNNER_VERSION})"
    echo "  --docker-version <version>    Docker version (default: ${DOCKER_VERSION})"
    echo "  --rootfs-size <size>          Root filesystem size (default: ${ROOTFS_SIZE})"
    echo "  --custom-kernel <path>        Use custom kernel instead of downloading"
    echo "  --help, -h                    Show this help"
    echo ""
    echo "Example:"
    echo "  $0 --runner-version 2.311.0 --rootfs-size 30G"
}

main() {
    print_header "GitHub Actions Runner Image Builder"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --runner-version)
                RUNNER_VERSION="$2"
                shift 2
                ;;
            --docker-version)
                DOCKER_VERSION="$2"
                shift 2
                ;;
            --rootfs-size)
                ROOTFS_SIZE="$2"
                shift 2
                ;;
            --custom-kernel)
                CUSTOM_KERNEL="$2"
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
    
    check_os
    check_dependencies
    setup_workspace
    create_runner_rootfs
    
    print_header "Build Complete!"
    print_info "Runner image ready at: ${WORK_DIR}/actions-runner-ubuntu-24.04.ext4"
    print_info ""
    print_info "Next steps:"
    print_info "1. Create a snapshot: ./snapshot-runner-image.sh"
    print_info "2. Launch runner VM: ./launch-runner-vm.sh --github-url <url> --token <token>"
}

# Run main function
main "$@" 