#!/bin/bash

# Firecracker Complete - All-in-One GitHub Actions Runner Solution
# Builds kernel, filesystem, and manages Firecracker VMs with cloud-init

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/firecracker-data"
VERSION="2.0.0"

# Default configuration
RUNNER_VERSION="2.324.0"
DOCKER_VERSION="latest" 
ROOTFS_SIZE="20G"
VM_MEMORY="2048"
VM_CPUS="2"
RUNNER_LABELS="firecracker,ubuntu-24.04"
KERNEL_VERSION="6.1.128"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_banner() {
    echo -e "${CYAN}"
    echo "================================================================"
    echo "  Firecracker Complete v${VERSION}"
    echo "  Kernel → Filesystem → VM → Manager"
    echo "================================================================"
    echo -e "${NC}"
}

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
        exit 1
    fi
    
    if [[ "$(uname -s)" != "Linux" ]]; then
        print_error "This script requires Ubuntu 24.04 or compatible Linux distribution."
        exit 1
    fi
}

check_dependencies() {
    # Allow skipping dependency checks via environment variable
    if [[ "${SKIP_DEPS:-false}" == "true" ]]; then
        print_warning "Skipping dependency checks (SKIP_DEPS=true)"
        return 0
    fi
    
    local command_deps=("curl" "wget" "git" "make" "gcc" "bc" "flex" "bison" "qemu-img" "debootstrap" "jq" "firecracker" "ssh-keygen")
    local library_deps=("libssl-dev" "libelf-dev")
    local missing_deps=()
    
    # Check command dependencies
    for dep in "${command_deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    # Check library dependencies (Ubuntu/Debian packages)
    if command -v dpkg &> /dev/null; then
        for dep in "${library_deps[@]}"; do
            if ! dpkg -l "$dep" 2>/dev/null | grep -q "^ii"; then
                missing_deps+=("$dep")
            fi
        done
    else
        # If not on Debian/Ubuntu, assume libraries are available
        print_warning "Cannot check library dependencies on non-Debian system"
    fi
    
    # Check for ISO creation tools
    if ! command -v genisoimage &> /dev/null && ! command -v mkisofs &> /dev/null; then
        missing_deps+=("genisoimage")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Install with: sudo apt update && sudo apt install -y build-essential curl wget git bc flex bison libssl-dev libelf-dev qemu-utils debootstrap jq openssh-client genisoimage"
        print_info "For Firecracker: see https://github.com/firecracker-microvm/firecracker/releases"
        exit 1
    fi
    
    # Check KVM access
    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        print_error "Cannot access /dev/kvm. Run: sudo usermod -a -G kvm \$USER && newgrp kvm"
        exit 1
    fi
}

setup_workspace() {
    mkdir -p "${WORK_DIR}"/{kernels,images,snapshots,instances}
    print_info "Debug: Changing to work directory: ${WORK_DIR}"
    cd "${WORK_DIR}"
    print_info "Debug: Now in: $(pwd)"
}

# Build custom kernel with Ubuntu 24.04 package support
build_kernel() {
    local kernel_config="${SCRIPT_DIR}/working-kernel-config"
    local rebuild_kernel=false
    local skip_deps=false
    
    # Parse build-kernel arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config) kernel_config="$2"; shift 2 ;;
            --rebuild-kernel) rebuild_kernel=true; shift ;;
            --rebuild) rebuild_kernel=true; shift ;;  # Alternative flag
            --skip-deps) skip_deps=true; shift ;;
            *) print_error "Unknown build-kernel option: $1"; exit 1 ;;
        esac
    done
    
    print_header "Building Custom Firecracker Kernel"
    
    # Resolve config file path
    if [[ ! "$kernel_config" = /* ]]; then
        # Relative path - make it relative to script directory
        kernel_config="${SCRIPT_DIR}/${kernel_config}"
    fi
    
    if [ ! -f "$kernel_config" ]; then
        print_error "Kernel config not found: $kernel_config"
        print_info "Expected: working-kernel-config in script directory or specify with --config"
        exit 1
    fi
    
    local kernel_dir="kernels/linux-${KERNEL_VERSION}"
    local kernel_output="kernels/vmlinux-${KERNEL_VERSION}-ubuntu24"
    
    # Check if kernel exists and handle rebuild
    if [ -f "$kernel_output" ] && [ "$rebuild_kernel" = false ]; then
        print_warning "Kernel already exists: $kernel_output"
        print_info "Use --rebuild-kernel to recreate"
        return 0
    elif [ -f "$kernel_output" ] && [ "$rebuild_kernel" = true ]; then
        print_info "Rebuilding kernel (--rebuild-kernel specified)"
        rm -f "$kernel_output"
    fi
    
    print_info "Using kernel config: $(basename "$kernel_config")"
    
    print_info "Downloading Linux kernel ${KERNEL_VERSION}..."
    if [ ! -d "$kernel_dir" ]; then
        wget -q "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz" -O "linux-${KERNEL_VERSION}.tar.xz"
        tar -xf "linux-${KERNEL_VERSION}.tar.xz" -C kernels/
        rm "linux-${KERNEL_VERSION}.tar.xz"
    fi
    
    cd "$kernel_dir"
    
    # Clean previous build if rebuilding
    if [ "$rebuild_kernel" = true ]; then
        print_info "Cleaning previous build..."
        make clean 2>/dev/null || true
    fi
    
    print_info "Applying kernel configuration..."
    cp "$kernel_config" .config
    
    # Resolve config dependencies
    print_info "Resolving kernel configuration dependencies..."
    make olddefconfig
    
    print_info "Building kernel (this may take 30-60 minutes)..."
    make -j$(nproc) vmlinux
    
    # Copy built kernel
    cp vmlinux "../../${kernel_output}"
    cd ../..
    
    local size=$(du -h "${kernel_output}" | cut -f1)
    print_info "✅ Kernel built: ${kernel_output} (${size})"
    
    # Show kernel info
    print_info "Kernel details:"
    print_info "  Version: ${KERNEL_VERSION}"
    print_info "  Config: $(basename "$kernel_config")"
    print_info "  Output: ${kernel_output}"
    print_info "  Size: ${size}"
}

# Generate random MAC address
generate_random_mac() {
    printf "06:%02x:%02x:%02x:%02x:%02x\n" \
        $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

# Generate short-lived registration token using GitHub API (like ARC does)
generate_registration_token() {
    local github_url="$1"
    local github_pat="$2"
    local runner_name="$3"
    
    # Validate GitHub URL format and extract components
    local api_url=""
    local scope=""
    local target=""
    
    if [[ "$github_url" =~ ^https://github\.com/enterprises/([^/]+)/?$ ]]; then
        # Enterprise URL
        local enterprise="${BASH_REMATCH[1]}"
        api_url="https://api.github.com/enterprises/${enterprise}/actions/runners/registration-token"
        scope="enterprise"
        target="$enterprise"
    elif [[ "$github_url" =~ ^https://github\.com/([^/]+)/?$ ]]; then
        # Organization URL
        local org="${BASH_REMATCH[1]}"
        api_url="https://api.github.com/orgs/${org}/actions/runners/registration-token"
        scope="organization"
        target="$org"
    elif [[ "$github_url" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]]; then
        # Repository URL
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        api_url="https://api.github.com/repos/${owner}/${repo}/actions/runners/registration-token"
        scope="repository"
        target="$owner/$repo"
    else
        echo "Invalid GitHub URL format: $github_url" >&2
        echo "Expected: https://github.com/owner/repo, https://github.com/org, or https://github.com/enterprises/ent" >&2
        return 1
    fi
    
    # Test basic API access first
    if ! curl -s --fail -H "Authorization: Bearer $github_pat" \
        https://api.github.com/user >/dev/null 2>&1; then
        echo "Failed to authenticate with GitHub API using provided PAT" >&2
        echo "Check your PAT token and permissions" >&2
        return 1
    fi
    
    # Generate registration token
    local response
    response=$(curl -s -w "%{http_code}" -X POST \
        -H "Authorization: Bearer $github_pat" \
        -H "Accept: application/vnd.github.v3+json" \
        "$api_url" 2>/dev/null)
    
    local http_code="${response: -3}"
    local body="${response%???}"
    
    case $http_code in
        201)
            # Parse JSON response
            local token
            token=$(echo "$body" | jq -r '.token' 2>/dev/null)
            
            if [ "$token" = "null" ] || [ -z "$token" ]; then
                echo "Failed to parse token from GitHub API response" >&2
                return 1
            fi
            
            # Optional: Show token expiration info to stderr
            local expires_at
            expires_at=$(echo "$body" | jq -r '.expires_at' 2>/dev/null)
            if [ "$expires_at" != "null" ] && [ -n "$expires_at" ]; then
                echo "Token expires at: $expires_at" >&2
            fi
            
            # Return the token to stdout only
            echo "$token"
            return 0
            ;;
        401)
            echo "GitHub API authentication failed (401): PAT token is invalid or expired" >&2
            return 1
            ;;
        403)
            echo "GitHub API access forbidden (403): PAT token lacks required permissions for $scope runners" >&2
            echo "Required permissions for $scope:" >&2
            case $scope in
                repository)
                    echo "  • repo (full repository access) OR public_repo + admin:repo_hook (for public repos)" >&2
                    ;;
                organization)
                    echo "  • admin:org (organization administration) + repo (repository access)" >&2
                    ;;
                enterprise)
                    echo "  • admin:enterprise (enterprise administration)" >&2
                    ;;
            esac
            return 1
            ;;
        404)
            echo "GitHub API not found (404): $scope '$target' doesn't exist or PAT lacks access" >&2
            return 1
            ;;
        422)
            echo "GitHub API unprocessable entity (422): $scope may not support self-hosted runners" >&2
            return 1
            ;;
        *)
            echo "GitHub API unexpected response: $http_code" >&2
            echo "Response: $body" >&2
            return 1
            ;;
    esac
}

# Build Ubuntu 24.04 runner filesystem with all packages
build_filesystem() {
    local rebuild_fs=false
    local skip_deps=false
    
    # Parse build-fs arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --rebuild-fs) rebuild_fs=true; shift ;;
            --rebuild) rebuild_fs=true; shift ;;  # Alternative flag
            --skip-deps) skip_deps=true; shift ;;
            *) print_error "Unknown build-fs option: $1"; exit 1 ;;
        esac
    done
    
    print_header "Building Ubuntu 24.04 GitHub Actions Runner Filesystem"
    
    local image_file="images/actions-runner-ubuntu-24.04.ext4"
    
    # Check if filesystem exists and handle rebuild
    if [ -f "${image_file}" ] && [ "$rebuild_fs" = false ]; then
        print_warning "Filesystem already exists. Use --rebuild-fs to recreate."
        return 0
    elif [ -f "${image_file}" ] && [ "$rebuild_fs" = true ]; then
        print_info "Rebuilding filesystem (--rebuild-fs specified)"
        rm -f "${image_file}"
    fi
    
    print_info "Creating ${ROOTFS_SIZE} filesystem image..."
    
    # Create and format image
    qemu-img create -f raw "${image_file}" "${ROOTFS_SIZE}"
    mkfs.ext4 "${image_file}"
    
    # Mount and setup
    local mount_dir="tmp_mount"
    mkdir -p "${mount_dir}"
    sudo mount "${image_file}" "${mount_dir}"
    
    # Mount proc and sys for proper chroot environment
    print_info "Setting up chroot environment..."
    sudo mkdir -p "${mount_dir}/proc" "${mount_dir}/sys" "${mount_dir}/dev" "${mount_dir}/tmp"
    
    # Mount with error checking
    if ! sudo mount -t proc proc "${mount_dir}/proc" 2>/dev/null; then
        print_warning "Failed to mount /proc, continuing without it"
    fi
    
    if ! sudo mount -t sysfs sysfs "${mount_dir}/sys" 2>/dev/null; then
        print_warning "Failed to mount /sys, continuing without it"
    fi
    
    if ! sudo mount -t devtmpfs dev "${mount_dir}/dev" 2>/dev/null; then
        if ! sudo mount --bind /dev "${mount_dir}/dev" 2>/dev/null; then
            print_warning "Failed to mount /dev, continuing without it"
        fi
    fi
    
    print_info "Installing Ubuntu 24.04 base system..."
    
    # Install comprehensive package set for GitHub Actions compatibility
    # Updated for Ubuntu 24.04 (noble) package names
    local packages="openssh-server,curl,wget,vim,htop,systemd,init,sudo,ca-certificates,cloud-init,jq,unzip,zip,git,iptables"
    # packages+=",build-essential,python3,python3-venv,python3-setuptools,openjdk-17-jdk"
    # packages+=",libsqlite3-dev,libssl-dev,pkg-config,autoconf,automake,libtool"
    packages+=",bison,flex,make,gcc,g++,binutils,file,gnupg,lsb-release"
    packages+=",software-properties-common,gpg-agent"
    
    sudo debootstrap --include="$packages" \
        noble "${mount_dir}" http://archive.ubuntu.com/ubuntu/
    
    print_info "Configuring GitHub Actions runner environment..."
    
    # Install Node.js and npm after base system (more reliable)
    print_info "Installing Node.js and npm..."
    sudo chroot "${mount_dir}" bash -c "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -"
    sudo chroot "${mount_dir}" apt-get install -y nodejs
    
    # Install pip for Python
    print_info "Installing Python pip..."
    sudo chroot "${mount_dir}" python3 -m ensurepip --upgrade || true
    
    # Create runner user
    sudo chroot "${mount_dir}" useradd -m -s /bin/bash runner
    sudo chroot "${mount_dir}" usermod -aG sudo runner
    echo "runner ALL=(ALL) NOPASSWD:ALL" | sudo tee "${mount_dir}/etc/sudoers.d/runner" > /dev/null
    
    # Install Docker CE (official Docker repository)
    print_info "Installing Docker CE from official repository..."
    
    # Add Docker's official GPG key
    sudo chroot "${mount_dir}" install -m 0755 -d /etc/apt/keyrings
    sudo chroot "${mount_dir}" curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chroot "${mount_dir}" chmod a+r /etc/apt/keyrings/docker.asc
    
    # Add the repository to Apt sources
    sudo chroot "${mount_dir}" bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
    
    # Update and install Docker
    sudo chroot "${mount_dir}" apt-get update
    sudo chroot "${mount_dir}" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo chroot "${mount_dir}" usermod -aG docker runner
    
    # Download and install GitHub Actions runner
    local runner_arch="x64"
    [[ "$(uname -m)" == "aarch64" ]] && runner_arch="arm64"
    
    sudo mkdir -p "${mount_dir}/opt/runner"
    sudo curl -fLo "${mount_dir}/tmp/runner.tar.gz" \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz"
    
    sudo chroot "${mount_dir}" bash -c "cd /opt/runner && tar xzf /tmp/runner.tar.gz && rm /tmp/runner.tar.gz"
    sudo chroot "${mount_dir}" bash -c "cd /opt/runner && ./bin/installdependencies.sh"
    sudo chroot "${mount_dir}" chown -R runner:runner /opt/runner
    
    # Create runner service
    sudo tee "${mount_dir}/etc/systemd/system/github-runner.service" > /dev/null <<'EOF'
[Unit]
Description=GitHub Actions Runner
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=runner
WorkingDirectory=/opt/runner
ExecStart=/opt/runner/run.sh
Restart=always
RestartSec=10
Environment=RUNNER_ALLOW_RUNASROOT=1

[Install]
WantedBy=multi-user.target
EOF
    
    # Configure Docker for Firecracker environment
    sudo mkdir -p "${mount_dir}/etc/docker"
    sudo tee "${mount_dir}/etc/docker/daemon.json" > /dev/null <<'EOF'
{
  "storage-driver": "overlay2",
  "iptables": true,
  "ip6tables": false,
  "bridge": "docker0",
  "userland-proxy": true,
  "ip-forward": true,
  "ip-masq": false,
  "features": {
    "buildkit": true
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-address-pools": [
    {
      "base": "172.17.0.0/16",
      "size": 24
    }
  ]
}
EOF
    
    # Configure kernel modules for Docker networking
    print_info "Configuring kernel modules for Docker networking..."
    sudo mkdir -p "${mount_dir}/etc/modules-load.d"
    sudo tee "${mount_dir}/etc/modules-load.d/docker.conf" > /dev/null <<'EOF'
# Docker and container networking modules
overlay
br_netfilter
xt_conntrack
nf_nat
nf_conntrack
bridge
veth
EOF
    
    # Configure sysctl for Docker networking (persistent)
    sudo mkdir -p "${mount_dir}/etc/sysctl.d"
    sudo tee "${mount_dir}/etc/sysctl.d/99-docker.conf" > /dev/null <<'EOF'
# Docker networking configuration
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1

# Bridge netfilter settings (if available)
# These may not work if br_netfilter module is missing
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-arptables = 1
EOF
    
    # Setup script for runner configuration
    sudo tee "${mount_dir}/usr/local/bin/setup-runner.sh" > /dev/null <<'EOF'
#!/bin/bash
set -euo pipefail

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/setup-runner.log
}

log "=== GitHub Actions Runner Setup Starting ==="

# Security: This VM only receives short-lived registration tokens (NOT PATs)
# The PAT token remains on the host and is never passed to the VM

# Check environment variables
if [ -z "\${RUNNER_TOKEN:-}" ] || [ -z "\${GITHUB_URL:-}\" ]; then
    log "ERROR: Missing required environment variables"
    log "RUNNER_TOKEN: \${RUNNER_TOKEN:-'(not set)'}"
    log "GITHUB_URL: \${GITHUB_URL:-'(not set)'}"
    log "Available environment:"
    env | grep -E '^(GITHUB_|RUNNER_)' | sed 's/^/  /' || log "No GITHUB_/RUNNER_ vars found"
    
    # Try to source from /etc/environment
    if [ -f /etc/environment ]; then
        log "Attempting to source from /etc/environment"
        set -a; source /etc/environment; set +a
        log "After sourcing /etc/environment:"
        env | grep -E '^(GITHUB_|RUNNER_)' | sed 's/^/  /' || log "Still no GITHUB_/RUNNER_ vars found"
    fi
    
    if [ -z "\${RUNNER_TOKEN:-}" ] || [ -z "\${GITHUB_URL:-}\" ]; then
        log "ERROR: Still missing required environment variables after all attempts"
        exit 1
    fi
fi

log "Environment variables found:"
log "GITHUB_URL: \$GITHUB_URL"
log "RUNNER_NAME: \${RUNNER_NAME:-\$(hostname)}"
log "RUNNER_LABELS: \${RUNNER_LABELS:-firecracker}"

# Wait for network to be ready
log "Waiting for network connectivity..."
for i in {1..30}; do
    if curl -s --connect-timeout 3 https://api.github.com/zen >/dev/null; then
        log "Network connectivity confirmed"
        break
    fi
    if [ $i -eq 30 ]; then
        log "ERROR: Network connectivity timeout after 30 attempts"
        exit 1
    fi
    log "Network not ready, attempt $i/30..."
    sleep 2
done

# Start and verify Docker
log "Starting Docker service..."
systemctl start docker || {
    log "ERROR: Failed to start Docker service"
    systemctl status docker --no-pager | sed 's/^/  /' || true
    exit 1
}

log "Waiting for Docker daemon to be ready..."
for i in {1..30}; do
    if docker info >/dev/null 2>&1; then
        log "Docker daemon is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        log "ERROR: Docker daemon not ready after 30 attempts"
        docker info 2>&1 | sed 's/^/  /' || true
        exit 1
    fi
    log "Docker daemon not ready, attempt $i/30..."
    sleep 2
done

# Add runner user to docker group
usermod -aG docker runner 2>/dev/null || log "Warning: Failed to add runner to docker group"

# Configure runner
log "Configuring GitHub Actions runner..."
cd /opt/runner

# Remove any existing configuration
if [ -f .runner ]; then
    log "Removing existing runner configuration..."
    sudo -u runner ./config.sh remove --token "$GITHUB_TOKEN" || log "Warning: Failed to remove existing config"
fi

# Create work directory
mkdir -p /tmp/runner-work
chown runner:runner /tmp/runner-work

log "Running runner configuration..."
sudo -u runner ./config.sh \
    --url "$GITHUB_URL" \
    --token "$GITHUB_TOKEN" \
    --name "${RUNNER_NAME:-$(hostname)}" \
    --labels "${RUNNER_LABELS:-firecracker}" \
    --work "/tmp/runner-work" \
    --unattended --replace || {
    log "ERROR: Runner configuration failed"
    log "Configuration output:"
    ls -la | sed 's/^/  /' || true
    exit 1
}

log "Runner configuration successful"
log "Configuration details:"
if [ -f .runner ]; then
    cat .runner | jq . | sed 's/^/  /' || cat .runner | sed 's/^/  /'
else
    log "ERROR: .runner file not created"
    exit 1
fi

# Enable and start runner service
log "Enabling GitHub runner service..."
systemctl enable github-runner || {
    log "ERROR: Failed to enable github-runner service"
    exit 1
}

log "Starting GitHub runner service..."
systemctl start github-runner || {
    log "ERROR: Failed to start github-runner service"
    systemctl status github-runner --no-pager | sed 's/^/  /' || true
    exit 1
}

# Verify runner is running
log "Verifying runner service status..."
sleep 5
if systemctl is-active --quiet github-runner; then
    log "✅ GitHub runner service is running"
    if pgrep -f "actions.runner" >/dev/null; then
        log "✅ Runner process is active"
    else
        log "⚠️  Runner service is active but process not found"
    fi
else
    log "❌ GitHub runner service is not running"
    systemctl status github-runner --no-pager | sed 's/^/  /' || true
    exit 1
fi

log "=== GitHub Actions Runner Setup Complete ==="
log "Runner should now be visible in your GitHub repository/organization"
EOF
    
    sudo chmod +x "${mount_dir}/usr/local/bin/setup-runner.sh"
    
    # Create ARC integration scripts for webhook handling and status reporting
    print_info "Creating ARC integration scripts..."
    
    # Enable services
    sudo chroot "${mount_dir}" systemctl enable ssh docker systemd-networkd github-runner
    
    # Install additional tools from ubuntu-24-packages.md
    print_info "Installing additional development tools..."
    
    # Install packages that are definitely available
    sudo chroot "${mount_dir}" apt-get install -y \
        ansible cmake git-lfs \
        python3-dev python-is-python3 ruby \
        postgresql-client mysql-client sqlite3 \
        xvfb mediainfo parallel rsync \
        2>/dev/null || true
    
    # Install Java packages (may not all be available)
    print_info "Installing Java development kits..."
    sudo chroot "${mount_dir}" apt-get install -y \
        openjdk-8-jdk openjdk-11-jdk openjdk-17-jdk openjdk-21-jdk \
        2>/dev/null || print_warning "Some Java versions may not be available"
    
    # Install browsers (may have different package names)
    print_info "Installing browsers..."
    sudo chroot "${mount_dir}" apt-get install -y firefox 2>/dev/null || true
    sudo chroot "${mount_dir}" apt-get install -y chromium 2>/dev/null || \
    sudo chroot "${mount_dir}" apt-get install -y chromium-browser 2>/dev/null || \
    print_warning "Chromium browser package not found"
    
    # Install tools that may not be in main repos
    print_info "Installing additional tools via alternative methods..."
    
    # Install kubectl
    sudo chroot "${mount_dir}" bash -c "curl -LO 'https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl' && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl" 2>/dev/null || true
    
    # Install helm
    sudo chroot "${mount_dir}" bash -c "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" 2>/dev/null || true
    
    # Cleanup
    sudo chroot "${mount_dir}" apt-get clean
    sudo chroot "${mount_dir}" rm -rf /var/lib/apt/lists/*
    
    # Properly unmount all filesystems
    print_info "Cleaning up mount points..."
    
    # Check what's actually mounted and unmount in reverse order
    if mountpoint -q "${mount_dir}/dev" 2>/dev/null; then
        sudo umount "${mount_dir}/dev" 2>/dev/null || print_warning "Failed to unmount /dev"
    fi
    
    if mountpoint -q "${mount_dir}/sys" 2>/dev/null; then
        sudo umount "${mount_dir}/sys" 2>/dev/null || print_warning "Failed to unmount /sys"
    fi
    
    if mountpoint -q "${mount_dir}/proc" 2>/dev/null; then
        sudo umount "${mount_dir}/proc" 2>/dev/null || print_warning "Failed to unmount /proc"
    fi
    
    # Final unmount of the main filesystem
    if mountpoint -q "${mount_dir}" 2>/dev/null; then
        sudo umount "${mount_dir}" || {
            print_error "Failed to unmount ${mount_dir}"
            exit 1
        }
    fi
    
    # Now safe to remove directory
    if [ -d "${mount_dir}" ]; then
        rmdir "${mount_dir}" 2>/dev/null || sudo rm -rf "${mount_dir}"
    fi
    
    local size=$(du -h "${image_file}" | cut -f1)
    print_info "✅ Filesystem created: ${image_file} (${size})"
}

# Create VM snapshot
create_snapshot() {
    local snapshot_name="${1:-runner-$(date +%Y%m%d-%H%M%S)}"
    local image_file="images/actions-runner-ubuntu-24.04.ext4"
    
    print_header "Creating Snapshot: ${snapshot_name}"
    
    # Validate snapshot name
    if [[ ! "$snapshot_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "Invalid snapshot name. Use only letters, numbers, dots, dashes, and underscores."
        exit 1
    fi
    
    if [ ! -f "$image_file" ]; then
        print_error "No filesystem image found. Run: $0 build-fs"
        exit 1
    fi
    
    local snapshot_dir="snapshots/${snapshot_name}"
    
    # Check if snapshot already exists
    if [ -d "$snapshot_dir" ]; then
        print_error "Snapshot already exists: $snapshot_name"
        print_info "Remove existing snapshot or use a different name"
        exit 1
    fi
    
    mkdir -p "$snapshot_dir"
    
    print_info "Creating snapshot from: $(basename "$image_file")"
    print_info "Copying filesystem (this may take a few minutes)..."
    
    # Copy with progress if available
    if command -v pv &> /dev/null; then
        pv "$image_file" > "${snapshot_dir}/rootfs.ext4"
    else
        cp "$image_file" "${snapshot_dir}/rootfs.ext4"
    fi
    
    # Create metadata
    cat > "${snapshot_dir}/info.json" <<EOF
{
  "name": "${snapshot_name}",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "runner_version": "${RUNNER_VERSION}",
  "docker_version": "${DOCKER_VERSION}",
  "kernel_version": "${KERNEL_VERSION}",
  "source_image": "$(basename "$image_file")",
  "image_size": "$(du -h "$image_file" | cut -f1)"
}
EOF
    
    local size=$(du -h "$snapshot_dir" | cut -f1)
    print_info "✅ Snapshot created: ${snapshot_dir} (${size})"
    print_info "Snapshot ready for deployment with: $0 launch --snapshot $snapshot_name"
}

# Setup Docker networking (common function for all modes)
setup_docker_networking() {
    log "Configuring Docker networking..."
    
    # Enable IPv4 forwarding
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    echo 'net.bridge.bridge-nf-call-iptables = 1' >> /etc/sysctl.conf 2>/dev/null || true
    echo 'net.bridge.bridge-nf-call-ip6tables = 1' >> /etc/sysctl.conf 2>/dev/null || true
    sysctl -p
    
    # Load networking modules with graceful fallback
    log "Loading networking modules..."
    modprobe br_netfilter 2>/dev/null && log "✅ br_netfilter loaded" || log "⚠️  br_netfilter not available"
    modprobe xt_conntrack 2>/dev/null && log "✅ xt_conntrack loaded" || log "⚠️  xt_conntrack not available" 
    modprobe overlay 2>/dev/null && log "✅ overlay loaded" || log "⚠️  overlay not available"
    modprobe bridge 2>/dev/null && log "✅ bridge loaded" || log "⚠️  bridge not available"
    
    # Setup fallback iptables rules if needed
    if ! lsmod | grep -q br_netfilter; then
        log "Setting up fallback iptables rules for Docker"
        iptables -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE 2>/dev/null || true
        iptables -A FORWARD -o docker0 -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -i docker0 ! -o docker0 -j ACCEPT 2>/dev/null || true
    fi
    
    # Restart Docker and test
    log "Restarting Docker..."
    systemctl restart docker
    sleep 10
    
    # Test Docker functionality
    if timeout 30 docker run --rm alpine:latest echo "Docker test" >/dev/null 2>&1; then
        log "✅ Docker networking functional"
        return 0
    else
        log "⚠️  Docker test failed - continuing anyway"
        return 1
    fi
}

# Setup GitHub runner (common function)
setup_github_runner() {
    local runner_mode="$1"
    
    log "Configuring GitHub Actions runner in $runner_mode mode..."
    cd /opt/runner
    
    # Remove existing config
    sudo -u runner ./config.sh remove --token "$RUNNER_TOKEN" 2>/dev/null || true
    
    # Create work directory
    mkdir -p /tmp/runner-work
    chown runner:runner /tmp/runner-work
    
    # Configure runner
    sudo -u runner ./config.sh \
        --url "$GITHUB_URL" \
        --token "$RUNNER_TOKEN" \
        --name "${RUNNER_NAME:-$(hostname)}" \
        --labels "${RUNNER_LABELS:-firecracker}" \
        --work "/tmp/runner-work" \
        --unattended --replace || {
        log "ERROR: Runner configuration failed"
        return 1
    }
    
    log "✅ Runner configured successfully"
    return 0
}

# Job completion handling for ephemeral VMs
handle_job_completion() {
    log "Setting up job completion monitoring..."
    
    cat > /usr/local/bin/monitor-job-completion.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# Source logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/job-monitor.log
}

LAST_JOB_CHECK=$(date +%s)
JOB_RUNNING=false

while true; do
    # Check if runner worker is active
    if pgrep -f "Runner.Worker" >/dev/null; then
        if [ "$JOB_RUNNING" = false ]; then
            log "Job started - worker process detected"
            JOB_RUNNING=true
        fi
        LAST_JOB_CHECK=$(date +%s)
    else
        if [ "$JOB_RUNNING" = true ]; then
            log "Job completed - worker process finished"
            JOB_RUNNING=false
            
            # Signal completion for ephemeral VMs
            if [ "${EPHEMERAL_MODE:-false}" = "true" ]; then
                log "Ephemeral mode: VM shutting down after job completion"
                
                # Create completion signal
                echo "job_completed:$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /tmp/ephemeral-cleanup
                
                # Give time for logs to flush
                sleep 5
                
                # Shutdown the VM
                log "Shutting down VM..."
                shutdown -h +1 "Job completed - ephemeral shutdown" &
                exit 0
            fi
        fi
    fi
    
    # Check if runner service is still alive
    if ! systemctl is-active --quiet github-runner; then
        log "Runner service stopped - restarting"
        systemctl restart github-runner
        sleep 10
    fi
    
    sleep 5
done
EOF
    
    chmod +x /usr/local/bin/monitor-job-completion.sh
    
    # Create systemd service for job monitoring
    cat > /etc/systemd/system/job-monitor.service << 'EOF'
[Unit]
Description=GitHub Actions Job Completion Monitor
After=github-runner.service
Requires=github-runner.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/monitor-job-completion.sh
Restart=always
RestartSec=10
Environment=EPHEMERAL_MODE=${EPHEMERAL_MODE:-false}

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl enable job-monitor
    log "✅ Job completion monitoring configured"
}

# Launch VM with cloud-init networking
launch_vm() {
    local snapshot_name=""
    local runner_name="runner-$(date +%H%M%S)"
    local github_url=""
    local github_pat=""
    local github_token=""  # For direct token override
    local labels="firecracker"
    local use_cloud_init=true
    local custom_kernel=""
    local use_host_bridge=false
    local use_dhcp=false
    local docker_mode=false
    local skip_deps=false
    local arc_mode=false
    local arc_controller_url=""
    local ephemeral_mode=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --snapshot) snapshot_name="$2"; shift 2 ;;
            --name) runner_name="$2"; shift 2 ;;
            --github-url) github_url="$2"; shift 2 ;;
            --github-pat) github_pat="$2"; shift 2 ;;
            --github-token) github_token="$2"; shift 2 ;;  # Direct token override (for backwards compatibility)
            --labels) labels="$2"; shift 2 ;;
            --memory) VM_MEMORY="$2"; shift 2 ;;
            --cpus) VM_CPUS="$2"; shift 2 ;;
            --kernel) custom_kernel="$2"; shift 2 ;;
            --no-cloud-init) use_cloud_init=false; shift ;;
            --use-host-bridge) use_host_bridge=true; shift ;;
            --docker-mode) docker_mode=true; shift ;;
            --skip-deps) skip_deps=true; shift ;;
            --arc-mode) arc_mode=true; shift ;;
            --arc-controller-url) arc_controller_url="$2"; shift 2 ;;
            --ephemeral-mode) ephemeral_mode=true; shift ;;
            *) print_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    
    # Generate registration token if needed
    local final_github_token="$github_token"
    if [ "$use_cloud_init" = true ]; then
        if [ -z "$final_github_token" ]; then
            if [ -z "$github_url" ] || [ -z "$github_pat" ]; then
                print_error "GitHub URL and PAT are required to generate registration token"
                print_error "Use: --github-url <url> --github-pat <pat>"
                print_error "Or provide direct token: --github-token <token> (for testing)"
                exit 1
            fi
            
            print_info "Generating short-lived registration token on host..."
            
            # Generate registration token using the same logic as ARC
            if ! command -v jq &> /dev/null; then
                print_error "jq is required for token generation. Install with: sudo apt install jq"
                exit 1
            fi
            
            # Call the token generation logic ON THE HOST
            final_github_token=$(generate_registration_token "$github_url" "$github_pat" "$runner_name")
            if [ $? -ne 0 ] || [ -z "$final_github_token" ]; then
                print_error "Failed to generate registration token"
                exit 1
            fi
            
            # Clean any potential ANSI escape codes from token (safety measure)
            final_github_token=$(echo "$final_github_token" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r\n' | xargs)
            
            print_info "✅ Registration token generated successfully"
            print_info "🔒 Security: PAT will NOT be passed to VM (only registration token)"
        else
            print_warning "Using provided token directly (--github-token specified)"
        fi
    fi
    
    if [ "$use_cloud_init" = true ] && ([ -z "$github_url" ] || [ -z "$final_github_token" ]); then
        print_error "GitHub URL and registration token are required (or use --no-cloud-init for testing)"
        exit 1
    fi
    
    # Find snapshot
    if [ -z "$snapshot_name" ]; then
        if [ ! -d "snapshots" ] || [ -z "$(ls -A snapshots 2>/dev/null)" ]; then
            print_error "No snapshots found. Run: $0 snapshot"
            exit 1
        fi
        snapshot_name=$(ls -t snapshots/ | head -1)
    fi
    
    local snapshot_dir="snapshots/${snapshot_name}"
    if [ ! -d "$snapshot_dir" ]; then
        print_error "Snapshot not found: $snapshot_name"
        exit 1
    fi
    
    print_header "Launching VM: ${runner_name}"
    
    # Start timing
    local start_time=$(date +%s)
    
    print_info "Debug: Current working directory: $(pwd)"
    print_info "Debug: Snapshot directory: ${snapshot_dir}"
    print_info "Debug: Looking for snapshot at: ${snapshot_dir}/rootfs.ext4"
    
    # Setup instance
    local vm_id=$(echo "$runner_name" | tr '[:upper:]' '[:lower:]' | head -c 8)
    local instance_dir="instances/${vm_id}"
    mkdir -p "$instance_dir"
    
    print_info "Debug: Instance directory: ${instance_dir}"
    print_info "Debug: Changing to: $(pwd)/${instance_dir}"
    
    cd "$instance_dir"
    
    print_info "Debug: Now in directory: $(pwd)"
    print_info "Debug: Will copy from: $(pwd)/../../${snapshot_dir}/rootfs.ext4"
    
    # Copy snapshot (adjust path since we're now in instances/vm-id/)
    cp "../../${snapshot_dir}/rootfs.ext4" "rootfs.ext4"
    
    # Generate SSH key
    ssh-keygen -t rsa -b 4096 -f "ssh_key" -N "" -C "$runner_name" >/dev/null 2>&1
    
    # Generate random MAC address for this VM
    local vm_mac=$(generate_random_mac)
    
    # Setup networking based on selected approach
    local bridge_device=""
    local tap_device=""
    local vm_ip=""
    local gateway_ip=""
    
    if [ "$use_host_bridge" = true ]; then
        # Use host bridge approach with DHCP
        bridge_device="br0"
        tap_device="tap-${vm_id}"
        use_dhcp=true
        
        print_info "Setting up host bridge networking via $bridge_device (DHCP)"
        
        # Check if host bridge exists
        if ! ip link show "$bridge_device" >/dev/null 2>&1; then
            print_error "Host bridge $bridge_device not found. Please create it first or use default networking."
            print_info "To create host bridge: sudo ip link add name br0 type bridge && sudo ip link set br0 up"
            exit 1
        fi
        
        # Create unique TAP device for this VM
        if ! ip link show "$tap_device" >/dev/null 2>&1; then
            print_info "Creating TAP device: $tap_device"
            sudo ip tuntap add dev "$tap_device" mode tap 2>/dev/null || {
                print_error "Failed to create TAP device $tap_device"
                exit 1
            }
            sudo ip link set dev "$tap_device" master "$bridge_device" 2>/dev/null || {
                print_error "Failed to attach TAP device to bridge"
                exit 1
            }
            sudo ip link set dev "$tap_device" up 2>/dev/null || {
                print_error "Failed to bring up TAP device $tap_device"
                exit 1
            }
        fi
        
        print_info "VM will get IP via DHCP from host network"
        
    else
        # Use original static IP approach
        bridge_device="fc-br0"
        tap_device="fc-tap0"
        gateway_ip="172.16.0.1"
        local ip_suffix=$((16#$(echo "$vm_id" | sha256sum | head -c 2) % 200 + 10))
        if [ $ip_suffix -eq 1 ]; then ip_suffix=10; fi
        vm_ip="172.16.0.${ip_suffix}"
        
        print_info "Setting up static networking: $vm_ip via $bridge_device"
        
        # Create bridge if needed
        if ! ip link show "$bridge_device" >/dev/null 2>&1; then
            print_info "Creating bridge: $bridge_device"
            sudo ip link add name "$bridge_device" type bridge 2>/dev/null || {
                print_error "Failed to create bridge $bridge_device"
                exit 1
            }
            sudo ip addr add "${gateway_ip}/24" dev "$bridge_device" 2>/dev/null || {
                print_error "Failed to assign IP to bridge $bridge_device"
                exit 1
            }
            sudo ip link set dev "$bridge_device" up 2>/dev/null || {
                print_error "Failed to bring up bridge $bridge_device"
                exit 1
            }
        fi
        
        # Create shared TAP if needed
        if ! ip link show "$tap_device" >/dev/null 2>&1; then
            print_info "Creating TAP device: $tap_device"
            sudo ip tuntap add dev "$tap_device" mode tap 2>/dev/null || {
                print_error "Failed to create TAP device $tap_device"
                exit 1
            }
            sudo ip link set dev "$tap_device" master "$bridge_device" 2>/dev/null || {
                print_error "Failed to attach TAP device to bridge"
                exit 1
            }
            sudo ip link set dev "$tap_device" up 2>/dev/null || {
                print_error "Failed to bring up TAP device $tap_device"
                exit 1
            }
        fi
        
        # Enable NAT for static approach
        sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
        local host_iface=$(ip route | grep default | awk '{print $5}' | head -1)
        sudo iptables -t nat -A POSTROUTING -s 172.16.0.0/24 -o "$host_iface" -j MASQUERADE 2>/dev/null || true
    fi
    
    # Setup cloud-init
    if [ "$use_cloud_init" = true ]; then
        mkdir -p cloud-init
        
        # Create network configuration content based on approach
        local network_config=""
        if [ "$use_dhcp" = true ]; then
            network_config="
      [Match]
      Name=eth0
      
      [Network]
      DHCP=yes
      DNS=8.8.8.8
      DNS=8.8.4.4"
        else
            network_config="
      [Match]
      Name=eth0
      
      [Network]
      Address=${vm_ip}/24
      Gateway=${gateway_ip}
      DNS=8.8.8.8
      DNS=8.8.4.4"
        fi
        
        # Create setup script content based on mode
        local setup_script_content=""
        if [ "$arc_mode" = true ]; then
            setup_script_content="#!/bin/bash
      set -euo pipefail
      
      # Source common functions
      $(declare -f log)
      $(declare -f setup_docker_networking)
      $(declare -f setup_github_runner)
      $(declare -f handle_job_completion)
      
      log \"=== ARC-Mode GitHub Actions Runner Setup ===\"
      
      # Wait for network
      log \"Waiting for network connectivity...\"
      for i in {1..30}; do
          if curl -s --connect-timeout 3 https://api.github.com/zen >/dev/null; then
              log \"Network connectivity confirmed\"
              break
          fi
          [ \$i -eq 30 ] && { log \"Network timeout\"; exit 1; }
          sleep 2
      done
      
      # Start Docker
      systemctl start docker
      usermod -aG docker runner
      
      # Setup Docker networking
      setup_docker_networking
      
      # Setup runner
      setup_github_runner \"arc\"
      
      # Setup job monitoring for ephemeral mode
      export EPHEMERAL_MODE=\"${ephemeral_mode}\"
      handle_job_completion
      
      # Start services
      systemctl start github-runner
      systemctl start job-monitor
      
      log \"=== ARC Setup Complete ===\""
        elif [ "$docker_mode" = true ]; then
            setup_script_content="#!/bin/bash
      set -euo pipefail
      
      # Source common functions
      $(declare -f log)
      $(declare -f setup_docker_networking)
      $(declare -f setup_github_runner)
      
      log \"=== Docker-Mode GitHub Actions Runner Setup ===\"
      
      # Wait for network
      for i in {1..30}; do
          if curl -s --connect-timeout 3 https://api.github.com/zen >/dev/null; then
              log \"Network ready\"
              break
          fi
          [ \$i -eq 30 ] && exit 1
          sleep 2
      done
      
      # Start Docker and setup networking
      systemctl start docker
      usermod -aG docker runner
      setup_docker_networking
      
      # Setup runner
      setup_github_runner \"docker\"
      
      # Run in foreground like Docker containers do
      log \"Starting runner in foreground (Docker mode)...\"
      cd /opt/runner
      exec sudo -u runner ./run.sh"
        else
            setup_script_content="#!/bin/bash
      set -euo pipefail

      # Source common functions
      $(declare -f log)
      $(declare -f setup_docker_networking)
      $(declare -f setup_github_runner)

      log \"=== Systemd-Mode GitHub Actions Runner Setup ===\"

      # Wait for network
      for i in {1..30}; do
          if curl -s --connect-timeout 3 https://api.github.com/zen >/dev/null; then
              log \"Network ready\"
              break
          fi
          [ \$i -eq 30 ] && exit 1
          sleep 2
      done

      # Start Docker and setup networking
      systemctl start docker
      usermod -aG docker runner
      setup_docker_networking
      
      # Setup runner
      setup_github_runner \"systemd\"

      # Start systemd service
      systemctl start github-runner

      log \"=== Setup Complete ===\""
        fi
        
        cat > cloud-init/user-data <<EOF
#cloud-config
hostname: ${runner_name}

users:
  - name: runner
    ssh_authorized_keys:
      - $(cat ssh_key.pub)
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

write_files:
  - path: /etc/environment
    content: |
      GITHUB_TOKEN=${final_github_token}
      GITHUB_URL=${github_url}
      RUNNER_NAME=${runner_name}
      RUNNER_LABELS=${labels}
      RUNNER_TOKEN=${final_github_token}
  - path: /usr/local/bin/setup-runner.sh
    permissions: '0755'
    content: |
$(echo "$setup_script_content" | sed 's/^/      /')
  - path: /usr/local/bin/run-with-env.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Security: Only short-lived registration token passed to VM (NOT PAT)
      export GITHUB_TOKEN="${final_github_token}"
      export GITHUB_URL="${github_url}"
      export RUNNER_NAME="${runner_name}"
      export RUNNER_LABELS="${labels}"
      export RUNNER_TOKEN="${final_github_token}"
      exec /usr/local/bin/setup-runner.sh
  - path: /etc/systemd/network/10-eth0.network
    content: |${network_config}

runcmd:
  - systemctl enable systemd-networkd
  - systemctl restart systemd-networkd
$(if [ "$arc_mode" = true ]; then echo "  - nohup /usr/local/bin/run-with-env.sh > /var/log/arc-runner.log 2>&1 &"; elif [ "$docker_mode" = true ]; then echo "  - nohup /usr/local/bin/run-with-env.sh > /var/log/docker-runner.log 2>&1 &"; else echo "  - /usr/local/bin/run-with-env.sh"; fi)

ssh_pwauth: false
EOF

        
        echo "{}" > cloud-init/network-config
        echo "instance-id: ${vm_id}" > cloud-init/meta-data
        
        genisoimage -output cloud-init.iso -volid cidata -joliet -rock cloud-init/ >/dev/null 2>&1
    fi
    
    # Setup kernel
    if [ -n "$custom_kernel" ]; then
        if [ ! -f "$custom_kernel" ]; then
            print_error "Custom kernel not found: $custom_kernel"
            exit 1
        fi
        cp "$custom_kernel" "vmlinux"
    else
        # Use built kernel if available (we're already in firecracker-data)
        local built_kernel="../kernels/vmlinux-${KERNEL_VERSION}-ubuntu24"
        if [ -f "$built_kernel" ]; then
            cp "$built_kernel" "vmlinux"
            print_info "Using built kernel: $(basename "$built_kernel")"
        else
            # Download default kernel
            if [ ! -f "vmlinux" ]; then
                print_info "Downloading default kernel..."
                curl -fsSL -o vmlinux "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.12/x86_64/vmlinux-6.1.128"
            fi
        fi
    fi
    
    # Start Firecracker
    local socket_path="firecracker.socket"
    rm -f "$socket_path"
    
    firecracker --api-sock "$socket_path" &
    local fc_pid=$!
    echo "$fc_pid" > firecracker.pid
    sleep 2
    
    # Configure VM
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d "{\"vcpu_count\": $VM_CPUS, \"mem_size_mib\": $VM_MEMORY}" \
        http://localhost/machine-config >/dev/null
    
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d "{\"kernel_image_path\": \"$(pwd)/vmlinux\", \"boot_args\": \"console=ttyS0 reboot=k panic=1 root=/dev/vda rw\"}" \
        http://localhost/boot-source >/dev/null
    
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d "{\"drive_id\": \"rootfs\", \"path_on_host\": \"$(pwd)/rootfs.ext4\", \"is_root_device\": true, \"is_read_only\": false}" \
        http://localhost/drives/rootfs >/dev/null
    
    if [ "$use_cloud_init" = true ]; then
        curl -X PUT --unix-socket "$socket_path" \
            -H "Content-Type: application/json" \
            -d "{\"drive_id\": \"cloudinit\", \"path_on_host\": \"$(pwd)/cloud-init.iso\", \"is_root_device\": false, \"is_read_only\": true}" \
            http://localhost/drives/cloudinit >/dev/null
    fi
    
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d "{\"iface_id\": \"eth0\", \"guest_mac\": \"${vm_mac}\", \"host_dev_name\": \"$tap_device\"}" \
        http://localhost/network-interfaces/eth0 >/dev/null
    
    # Start VM
    curl -X PUT --unix-socket "$socket_path" \
        -H "Content-Type: application/json" \
        -d '{"action_type": "InstanceStart"}' \
        http://localhost/actions >/dev/null
    
    print_info "✅ VM started: $runner_name"
    print_info "   VM ID: $vm_id"
    if [ "$use_dhcp" = true ]; then
        print_info "   Networking: DHCP via host bridge $bridge_device"
        print_info "   MAC: $vm_mac"
        print_info "   SSH: ssh -i $(pwd)/ssh_key runner@<dhcp-assigned-ip>"
        print_info "   Note: Check your DHCP server logs or network scanner for assigned IP"
    else
        print_info "   IP: $vm_ip (static)"
        print_info "   SSH: ssh -i $(pwd)/ssh_key runner@$vm_ip"
    fi
    
    # Save instance info
    cat > info.json <<EOF
{
  "name": "$runner_name",
  "vm_id": "$vm_id", 
  "ip": "${vm_ip:-dhcp}",
  "mac": "$vm_mac",
  "networking": "${use_dhcp:+dhcp}${use_dhcp:-static}",
  "bridge": "$bridge_device",
  "tap": "$tap_device",
  "github_url": "$github_url",
  "labels": "$labels",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pid": $fc_pid,
  "ephemeral_mode": $ephemeral_mode,
  "arc_mode": $arc_mode,
  "arc_controller_url": "${arc_controller_url:-null}",
  "docker_mode": $docker_mode
}
EOF
    
    cd ../..
    
    # Wait for VM
    print_info "Waiting for VM to be ready..."
    for i in {1..30}; do
        if ping -c 1 -W 2 "$vm_ip" >/dev/null 2>&1; then
            if ssh -i "instances/${vm_id}/ssh_key" -o ConnectTimeout=3 -o StrictHostKeyChecking=no runner@"$vm_ip" 'echo ready' >/dev/null 2>&1; then
                local end_time=$(date +%s)
                local duration=$((end_time - start_time))
                print_info "✅ VM is ready and accessible"
                print_info "🕐 Total startup time: ${duration} seconds"
                return 0
            fi
        fi
        sleep 2
    done
    
    print_warning "VM may still be starting up"
}

# List and manage VMs
list_vms() {
    print_header "Firecracker Resources"
    
    echo -e "${GREEN}Kernels:${NC}"
    if [ -d "kernels" ] && ls kernels/vmlinux-* &>/dev/null; then
        for kernel in kernels/vmlinux-*; do
            if [ -f "$kernel" ]; then
                local size=$(du -h "$kernel" | cut -f1)
                local name=$(basename "$kernel")
                echo "  $name ($size)"
            fi
        done
    else
        echo "  None built yet - run: $0 build-kernel"
    fi
    echo
    
    echo -e "${GREEN}Images:${NC}"
    if [ -d "images" ] && ls images/*.ext4 &>/dev/null; then
        for img in images/*.ext4; do
            if [ -f "$img" ]; then
                local size=$(du -h "$img" | cut -f1)
                local name=$(basename "$img")
                echo "  $name ($size)"
            fi
        done
    else
        echo "  None built yet - run: $0 build-fs" 
    fi
    echo
    
    echo -e "${GREEN}Snapshots:${NC}"
    if [ -d "snapshots" ] && [ "$(ls -A snapshots 2>/dev/null)" ]; then
        for snap in snapshots/*/info.json; do
            if [ -f "$snap" ]; then
                local name=$(jq -r '.name' "$snap")
                local created=$(jq -r '.created' "$snap")
                local size=$(jq -r '.image_size // "unknown"' "$snap")
                local runner_ver=$(jq -r '.runner_version // "unknown"' "$snap")
                echo "  $name - created: $created, size: $size, runner: v$runner_ver"
            fi
        done
    else
        echo "  None created yet - run: $0 snapshot <name>"
    fi
    echo
    
    echo -e "${GREEN}Running VMs:${NC}"
    if [ -d "instances" ] && [ "$(ls -A instances 2>/dev/null)" ]; then
        for inst in instances/*/info.json; do
            if [ -f "$inst" ]; then
                local name=$(jq -r '.name' "$inst")
                local ip=$(jq -r '.ip' "$inst") 
                local mac=$(jq -r '.mac // "unknown"' "$inst")
                local networking=$(jq -r '.networking // "static"' "$inst")
                local bridge=$(jq -r '.bridge // "unknown"' "$inst")
                local tap=$(jq -r '.tap // "unknown"' "$inst")
                local pid=$(jq -r '.pid' "$inst")
                local github_url=$(jq -r '.github_url // "none"' "$inst")
                local labels=$(jq -r '.labels // "none"' "$inst")
                
                if kill -0 "$pid" 2>/dev/null; then
                    echo "  ✅ $name - $ip ($networking)"
                    echo "     MAC: $mac, Bridge: $bridge, TAP: $tap"
                    echo "     GitHub: $github_url"
                    echo "     Labels: $labels"
                else
                    echo "  ❌ $name - $ip (stopped)"
                fi
            fi
        done
    else
        echo "  None running - run: $0 launch [options]"
    fi
    
    # Show network status if running on Linux
    if [[ "$(uname -s)" == "Linux" ]] && command -v ip &> /dev/null; then
        echo
        echo -e "${GREEN}Network Status:${NC}"
        if ip link show fc-br0 >/dev/null 2>&1; then
            local bridge_ip=$(ip addr show fc-br0 | grep 'inet ' | awk '{print $2}' | head -1)
            echo "  Bridge: fc-br0 ($bridge_ip) ✅"
        else
            echo "  Bridge: fc-br0 (not configured)"
        fi
        
        if ip link show fc-tap0 >/dev/null 2>&1; then
            echo "  TAP: fc-tap0 ✅"
        else
            echo "  TAP: fc-tap0 (not configured)"
        fi
    fi
}

# Stop VMs
stop_vms() {
    local pattern="${1:-.*}"
    
    if [ ! -d "instances" ]; then
        print_info "No instances found"
        return
    fi
    
    local stopped=0
    for inst in instances/*/info.json; do
        if [ -f "$inst" ]; then
            local name=$(jq -r '.name' "$inst")
            local pid=$(jq -r '.pid' "$inst")
            
            if [[ "$name" =~ $pattern ]]; then
                if kill -0 "$pid" 2>/dev/null; then
                    print_info "Stopping $name (PID: $pid)..."
                    kill "$pid" 2>/dev/null || true
                    sleep 1
                    kill -9 "$pid" 2>/dev/null || true
                    ((stopped++))
                fi
            fi
        fi
    done
    
    [ $stopped -eq 0 ] && print_info "No matching VMs to stop" || print_info "Stopped $stopped VM(s)"
}

# Check VM status and diagnostics
check_vm_status() {
    local vm_pattern="${1:-.*}"
    
    print_header "VM Status and Diagnostics"
    
    if [ ! -d "instances" ]; then
        print_info "No instances found"
        return
    fi
    
    for inst in instances/*/info.json; do
        if [ -f "$inst" ]; then
            local name=$(jq -r '.name' "$inst")
            local ip=$(jq -r '.ip' "$inst")
            local pid=$(jq -r '.pid' "$inst")
            local vm_dir=$(dirname "$inst")
            
            if [[ "$name" =~ $vm_pattern ]]; then
                echo
                echo -e "${GREEN}VM: $name${NC}"
                echo "================================"
                
                # Process status
                if kill -0 "$pid" 2>/dev/null; then
                    echo "✅ Firecracker process: Running (PID: $pid)"
                else
                    echo "❌ Firecracker process: Stopped"
                    continue
                fi
                
                # Network connectivity
                if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
                    echo "✅ Network: Reachable ($ip)"
                else
                    echo "❌ Network: Not reachable ($ip)"
                    continue
                fi
                
                # SSH access
                if ssh -i "${vm_dir}/ssh_key" -o ConnectTimeout=3 -o StrictHostKeyChecking=no runner@"$ip" 'echo ready' >/dev/null 2>&1; then
                    echo "✅ SSH: Accessible"
                    
                    # Get system status via SSH
                    echo "📊 System Status:"
                    ssh -i "${vm_dir}/ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no runner@"$ip" '
                        echo "   Uptime: $(uptime | cut -d"," -f1 | cut -d" " -f4-)"
                        echo "   Load: $(cat /proc/loadavg | cut -d" " -f1-3)"
                        echo "   Memory: $(free -h | grep Mem | awk "{print \$3\"/\"\$2}")"
                        echo "   Disk: $(df -h / | tail -1 | awk "{print \$3\"/\"\$2\" (\"\$5\")\"})"
                    ' 2>/dev/null || echo "   Failed to get system info"
                    
                    # Check cloud-init status
                    echo "☁️  Cloud-init Status:"
                    ssh -i "${vm_dir}/ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no runner@"$ip" '
                        if systemctl is-active --quiet cloud-final; then
                            echo "   ✅ cloud-final.service: $(systemctl show -p ActiveState --value cloud-final)"
                        else
                            echo "   ❌ cloud-final.service: $(systemctl show -p ActiveState --value cloud-final)"
                            echo "   Last errors:"
                            journalctl -u cloud-final --lines=3 --no-pager 2>/dev/null | sed "s/^/      /" || echo "      (no logs available)"
                        fi
                        
                        if systemctl is-active --quiet cloud-init; then
                            echo "   ✅ cloud-init.service: $(systemctl show -p ActiveState --value cloud-init)"
                        else
                            echo "   ❌ cloud-init.service: $(systemctl show -p ActiveState --value cloud-init)"
                        fi
                    ' 2>/dev/null || echo "   Failed to get cloud-init status"
                    
                    # Check GitHub runner status
                    echo "🏃 GitHub Runner Status:"
                    ssh -i "${vm_dir}/ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no runner@"$ip" '
                        if systemctl is-active --quiet github-runner; then
                            echo "   ✅ github-runner.service: Running"
                            if pgrep -f "actions.runner" >/dev/null; then
                                echo "   ✅ Runner process: Active"
                                echo "   📝 Runner logs (last 3 lines):"
                                journalctl -u github-runner --lines=3 --no-pager 2>/dev/null | sed "s/^/      /" || echo "      (no logs available)"
                            else
                                echo "   ⚠️  Runner process: Not found"
                            fi
                        else
                            echo "   ❌ github-runner.service: $(systemctl show -p ActiveState --value github-runner 2>/dev/null || echo "not found")"
                        fi
                        
                        # Check if runner is configured
                        if [ -f "/opt/runner/.runner" ]; then
                            echo "   ✅ Runner configuration: Found"
                            cat /opt/runner/.runner | jq -r "\"   🏷️  Runner name: \" + .agentName" 2>/dev/null || echo "   🏷️  Runner name: (failed to parse)"
                        else
                            echo "   ❌ Runner configuration: Missing"
                        fi
                        
                        # Check environment variables
                        if [ -f "/etc/environment" ]; then
                            if grep -q "GITHUB_" /etc/environment; then
                                echo "   ✅ Environment variables: Set"
                            else
                                echo "   ❌ Environment variables: Missing GITHUB_* vars"
                            fi
                        else
                            echo "   ❌ Environment variables: /etc/environment missing"
                        fi
                    ' 2>/dev/null || echo "   Failed to get runner status"
                    
                    # Check Docker status
                    echo "🐳 Docker Status:"
                    ssh -i "${vm_dir}/ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no runner@"$ip" '
                        if systemctl is-active --quiet docker; then
                            echo "   ✅ Docker service: Running"
                            if docker info >/dev/null 2>&1; then
                                echo "   ✅ Docker daemon: Accessible"
                            else
                                echo "   ❌ Docker daemon: Not accessible"
                            fi
                        else
                            echo "   ❌ Docker service: $(systemctl show -p ActiveState --value docker 2>/dev/null || echo "not found")"
                        fi
                    ' 2>/dev/null || echo "   Failed to get Docker status"
                    
                else
                    echo "❌ SSH: Not accessible"
                fi
            fi
        fi
    done
}

# Check runner status
check_runner() {
    local vm_pattern="${1:-.*}"
    
    if [ ! -d "instances" ]; then
        print_info "No instances found"
        return
    fi
    
    print_header "GitHub Runner Status"
    
    for inst in instances/*/info.json; do
        if [ -f "$inst" ]; then
            local name=$(jq -r '.name' "$inst")
            local ip=$(jq -r '.ip' "$inst")
            local vm_dir=$(dirname "$inst")
            
            if [[ "$name" =~ $vm_pattern ]]; then
                echo -e "${BLUE}$name ($ip):${NC}"
                
                if ssh -i "${vm_dir}/ssh_key" -o ConnectTimeout=3 -o StrictHostKeyChecking=no runner@"$ip" '
                    if systemctl is-active --quiet github-runner && pgrep -f "actions.runner" >/dev/null; then
                        echo "✅ Runner is running"
                        if [ -f "/opt/runner/.runner" ]; then
                            cat /opt/runner/.runner | jq -r "\"   Name: \" + .agentName + \", Pool: \" + .poolName" 2>/dev/null || echo "   (config available but failed to parse)"
                        fi
                    else
                        echo "❌ Runner is not running"
                        if systemctl --quiet is-failed github-runner; then
                            echo "   Service failed. Last error:"
                            journalctl -u github-runner --lines=2 --no-pager 2>/dev/null | tail -1 | sed "s/^/   /" || echo "   (no error logs)"
                        fi
                    fi
                ' 2>/dev/null; then
                    : # SSH command succeeded
                else
                    echo "❌ Cannot connect to VM"
                fi
                echo
            fi
        fi
    done
}

# Monitor and destroy ephemeral VMs when jobs complete
monitor_ephemeral() {
    print_header "Monitoring Ephemeral VMs"
    
    print_info "Starting ephemeral VM monitoring..."
    
    while true; do
        # Check all running VMs
        for inst in instances/*/info.json; do
            if [ -f "$inst" ]; then
                local instance_dir=$(dirname "$inst")
                local vm_name=$(jq -r '.name' "$inst" 2>/dev/null)
                local pid=$(jq -r '.pid' "$inst" 2>/dev/null)
                local ip=$(jq -r '.ip' "$inst" 2>/dev/null)
                local ephemeral=$(jq -r '.ephemeral_mode' "$inst" 2>/dev/null)
                
                # Skip non-ephemeral VMs
                if [ "$ephemeral" != "true" ]; then
                    continue
                fi
                
                print_info "Checking ephemeral VM: $vm_name"
                
                # Check if VM process is still alive
                if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
                    print_info "Ephemeral VM $vm_name has shutdown - cleaning up"
                    rm -rf "$instance_dir"
                    continue
                fi
                
                # Check for completion signal via SSH
                if [ "$ip" != "null" ] && [ -n "$ip" ]; then
                    if ssh -i "$instance_dir/ssh_key" -o ConnectTimeout=3 -o StrictHostKeyChecking=no runner@"$ip" \
                        '[ -f /tmp/ephemeral-cleanup ]' 2>/dev/null; then
                        print_info "Job completion signal found for VM: $vm_name"
                        
                        # Stop the VM
                        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                            print_info "Stopping VM process (PID: $pid)"
                            kill "$pid" 2>/dev/null || true
                            sleep 3
                            kill -9 "$pid" 2>/dev/null || true
                        fi
                        
                        # Clean up instance
                        rm -rf "$instance_dir"
                        print_info "✅ Ephemeral VM $vm_name destroyed and cleaned up"
                    fi
                fi
            fi
        done
        
        sleep 15
    done
}

# Cleanup everything  
cleanup() {
    print_header "Cleaning Up"
    
    stop_vms
    
    # Cleanup networking
    print_info "Cleaning up networking..."
    
    # Clean up per-VM TAP devices (host bridge approach)
    if [ -d "instances" ]; then
        for inst in instances/*/info.json; do
            if [ -f "$inst" ]; then
                local tap=$(jq -r '.tap // ""' "$inst")
                local networking=$(jq -r '.networking // "static"' "$inst")
                if [ -n "$tap" ] && [ "$networking" = "dhcp" ]; then
                    print_info "Removing TAP device: $tap"
                    sudo ip link del "$tap" 2>/dev/null || true
                fi
            fi
        done
    fi
    
    # Clean up default static networking devices
    sudo ip link del "fc-tap0" 2>/dev/null || true
    sudo ip link del "fc-br0" 2>/dev/null || true
    sudo iptables -t nat -D POSTROUTING -s 172.16.0.0/24 -j MASQUERADE 2>/dev/null || true
    
    # Remove instances
    if [ -d "instances" ]; then
        rm -rf instances/*
        print_info "Cleaned up instance data"
    fi
    
    print_info "✅ Cleanup complete"
    print_info "Note: Host bridge 'br0' (if used) is left intact"
}

# Usage
usage() {
    echo "Firecracker Complete v${VERSION} - All-in-One GitHub Actions Runner"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Build Commands:"
    echo "  build-kernel [options]    Build custom kernel with all networking modules"
    echo "  build-fs [options]        Build filesystem with GitHub Actions runner"
    echo "  snapshot [name]           Create snapshot from filesystem"
    echo ""
    echo "VM Management:"
    echo "  launch [options]          Launch runner VM"
    echo "  list                      List all resources"
    echo "  stop [pattern]            Stop VMs (optional regex pattern)" 
    echo "  status                    Check VM status and diagnostics"
    echo "  check-runner              Check GitHub runner status"
    echo "  monitor-ephemeral         Monitor and cleanup ephemeral VMs"
    echo "  cleanup                   Stop all VMs and cleanup"
    echo ""
    echo "Build Options:"
    echo "  --config <path>           Custom kernel config file"
    echo "  --rebuild-kernel          Force rebuild kernel"
    echo "  --rebuild-fs              Force rebuild filesystem"
    echo "  --skip-deps               Skip dependency checks"
    echo ""
    echo "Launch Options:"
    echo "  --snapshot <name>         Use specific snapshot"
    echo "  --name <name>             VM name"
    echo "  --github-url <url>        GitHub repo/org/enterprise URL"
    echo "  --github-pat <pat>        GitHub PAT (generates registration token)"
    echo "  --labels <labels>         Runner labels (default: firecracker)"
    echo "  --memory <mb>             VM memory (default: 2048)" 
    echo "  --cpus <count>            VM CPU count (default: 2)"
    echo "  --kernel <path>           Custom kernel path"
    echo "  --no-cloud-init           Disable cloud-init (testing only)"
    echo "  --use-host-bridge         Use host bridge networking with DHCP"
    echo "  --docker-mode             Run as Docker container (foreground)"
    echo "  --arc-mode                Enable ARC integration"
    echo "  --ephemeral-mode          Auto-shutdown after job completion"
    echo ""
    echo "Examples:"
    echo "  # Build components"
    echo "  $0 build-kernel --rebuild-kernel"
    echo "  $0 build-fs --rebuild-fs"
    echo "  $0 snapshot prod-runner"
    echo ""
    echo "  # Launch runners (PAT → registration token on host)"
    echo "  $0 launch --github-url https://github.com/org/repo --github-pat ghp_xxxx"
    echo "  $0 launch --ephemeral-mode --github-url https://github.com/org/repo --github-pat ghp_xxxx"
    echo "  $0 launch --docker-mode --github-url https://github.com/org/repo --github-pat ghp_xxxx"
    echo ""
    echo "  # Management"
    echo "  $0 list                   # Show all resources"
    echo "  $0 status                 # Check VM health"
    echo "  $0 monitor-ephemeral      # Monitor job completion"
    echo "  $0 cleanup                # Stop everything"
    echo ""
    echo "Security: PAT tokens stay on host, only short-lived registration tokens"
    echo "          are passed to VMs (following GitHub ARC security model)"
}

# Main function
main() {
    local cmd="${1:-help}"
    local skip_deps_global=false
    
    # Check for global --skip-deps flag
    if [[ "$*" =~ --skip-deps ]]; then
        skip_deps_global=true
    fi
    
    shift || true
    
    # Show banner for main commands (not for help/version)
    if [[ "$cmd" =~ ^(build-kernel|build-fs|snapshot|launch|list|cleanup)$ ]]; then
        print_banner
    fi
    
    case "$cmd" in
        build-kernel)
            check_os
            if [ "$skip_deps_global" = false ]; then
                check_dependencies
            else
                print_warning "Skipping dependency checks (--skip-deps specified)"
            fi
            setup_workspace
            build_kernel "$@"
            ;;
        build-fs)
            check_os
            if [ "$skip_deps_global" = false ]; then
                check_dependencies
            else
                print_warning "Skipping dependency checks (--skip-deps specified)"
            fi
            setup_workspace
            build_filesystem "$@"
            ;;
        snapshot)
            check_os
            setup_workspace
            create_snapshot "$@"
            ;;
        launch)
            check_os
            if [ "$skip_deps_global" = false ]; then
                check_dependencies
            else
                print_warning "Skipping dependency checks (--skip-deps specified)"
            fi
            setup_workspace
            launch_vm "$@"
            ;;
        list)
            setup_workspace
            list_vms
            ;;
        stop)
            setup_workspace
            stop_vms "$@" 
            ;;
        status)
            setup_workspace
            check_vm_status "$@"
            ;;
        check-runner)
            setup_workspace
            check_runner "$@"
            ;;
        monitor-ephemeral)
            setup_workspace
            monitor_ephemeral
            ;;
        cleanup)
            setup_workspace
            cleanup
            ;;
        version|--version|-v)
            echo "Firecracker Complete v${VERSION}"
            echo "GitHub Actions Runner on Firecracker VMs"
            echo ""
            echo "Features:"
            echo "  • Custom kernel building with Ubuntu 24.04 support"
            echo "  • Complete filesystem with Docker CE + GitHub Actions runner"
            echo "  • Cloud-init networking with shared bridge architecture"
            echo "  • VM management and monitoring"
            echo ""
            echo "Requirements: Ubuntu 24.04+ with KVM support"
            ;;
        help|--help|-h|"")
            usage
            ;;
        *)
            print_error "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

# Run
main "$@" 