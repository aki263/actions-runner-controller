#!/bin/bash

# Firecracker VM Snapshot Manager
# Creates and manages snapshots of runner VMs for fast deployment

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_IMAGE_DIR="${SCRIPT_DIR}/runner-image"
SNAPSHOTS_DIR="${SCRIPT_DIR}/snapshots"
WORK_DIR="${SCRIPT_DIR}/firecracker-vm"

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
        exit 1
    fi
}

create_snapshot() {
    local snapshot_name="${1:-runner-$(date +%Y%m%d-%H%M%S)}"
    local source_image="${RUNNER_IMAGE_DIR}/actions-runner-ubuntu-24.04.ext4"
    
    print_header "Creating VM Snapshot: ${snapshot_name}"
    
    # Check if source image exists
    if [ ! -f "$source_image" ]; then
        print_error "Runner image not found: $source_image"
        print_info "Please run ./build-runner-image.sh first"
        exit 1
    fi
    
    # Create snapshots directory
    mkdir -p "$SNAPSHOTS_DIR"
    
    local snapshot_dir="${SNAPSHOTS_DIR}/${snapshot_name}"
    mkdir -p "$snapshot_dir"
    
    print_info "Creating snapshot directory: $snapshot_dir"
    
    # Copy the base image as snapshot
    print_info "Creating snapshot from runner image..."
    cp "$source_image" "${snapshot_dir}/rootfs.ext4"
    
    # Create snapshot metadata
    cat > "${snapshot_dir}/snapshot-info.json" <<EOF
{
  "snapshot_name": "${snapshot_name}",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "source_image": "$source_image",
  "source_image_size": "$(du -b "$source_image" | cut -f1)",
  "source_image_md5": "$(md5sum "$source_image" | cut -d' ' -f1)",
  "snapshot_type": "actions-runner",
  "description": "GitHub Actions Runner VM snapshot ready for cloud-init configuration"
}
EOF
    
    # Copy kernel if available
    if [ -f "${WORK_DIR}/vmlinux-6.1.128" ]; then
        print_info "Including kernel in snapshot..."
        cp "${WORK_DIR}/vmlinux-6.1.128" "${snapshot_dir}/vmlinux"
    elif [ -f "${WORK_DIR}/vmlinux-6.1.128-custom" ]; then
        print_info "Including custom kernel in snapshot..."
        cp "${WORK_DIR}/vmlinux-6.1.128-custom" "${snapshot_dir}/vmlinux"
    else
        print_warning "No kernel found in ${WORK_DIR}. You'll need to provide one when launching VMs."
    fi
    
    # Create launch template
    cat > "${snapshot_dir}/launch-template.json" <<EOF
{
  "boot-source": {
    "kernel_image_path": "KERNEL_PATH_PLACEHOLDER",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off nomodules rw root=/dev/vda rootfstype=ext4 ip=172.16.0.2::172.16.0.1:255.255.255.192::eth0:on"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "ROOTFS_PATH_PLACEHOLDER",
      "is_root_device": true,
      "is_read_only": false
    },
    {
      "drive_id": "cloudinit",
      "path_on_host": "CLOUDINIT_PATH_PLACEHOLDER",
      "is_root_device": false,
      "is_read_only": true
    }
  ],
  "network-interfaces": [
    {
      "iface_id": "net1",
      "guest_mac": "06:00:AC:10:00:02",
      "host_dev_name": "TAP_DEVICE_PLACEHOLDER"
    }
  ],
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 2048
  }
}
EOF
    
    # Create cloud-init template for runner configuration
    cat > "${snapshot_dir}/cloud-init-template.yaml" <<'EOF'
#cloud-config
hostname: ${RUNNER_NAME}
fqdn: ${RUNNER_NAME}.local

# Configure users
users:
  - name: runner
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

# SSH configuration
ssh_pwauth: false
disable_root: false

# Network configuration
network:
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

# Environment variables for GitHub Actions runner
write_files:
  - path: /etc/systemd/system/actions-runner.service.d/override.conf
    permissions: '0644'
    content: |
      [Service]
      Environment=GITHUB_TOKEN=${GITHUB_TOKEN}
      Environment=GITHUB_URL=${GITHUB_URL}
      Environment=RUNNER_NAME=${RUNNER_NAME}
      Environment=RUNNER_LABELS=${RUNNER_LABELS}
      Environment=RUNNER_WORK_DIR=${RUNNER_WORK_DIR}

  - path: /root/configure-runner.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      echo "Configuring GitHub Actions Runner..."
      echo "Runner: ${RUNNER_NAME}"
      echo "GitHub URL: ${GITHUB_URL}"
      echo "Labels: ${RUNNER_LABELS}"
      
      # Export environment variables
      export GITHUB_TOKEN="${GITHUB_TOKEN}"
      export GITHUB_URL="${GITHUB_URL}"
      export RUNNER_NAME="${RUNNER_NAME}"
      export RUNNER_LABELS="${RUNNER_LABELS}"
      export RUNNER_WORK_DIR="${RUNNER_WORK_DIR}"
      
      # Start the runner service
      systemctl daemon-reload
      systemctl enable actions-runner
      systemctl start actions-runner

# Run commands after boot
runcmd:
  - /root/configure-runner.sh

# Final message
final_message: "GitHub Actions Runner ${RUNNER_NAME} is ready!"
EOF
    
    # Create a simple launch script template
    cat > "${snapshot_dir}/launch.sh" <<'EOF'
#!/bin/bash
# Launch script for GitHub Actions Runner VM from snapshot

set -euo pipefail

# Configuration
SNAPSHOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_NAME="${1:-runner-$(date +%H%M%S)}"
GITHUB_URL="${2:-}"
GITHUB_TOKEN="${3:-}"

# Default values
RUNNER_LABELS="${RUNNER_LABELS:-firecracker,ubuntu-24.04}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
RUNNER_WORK_DIR="${RUNNER_WORK_DIR:-/home/runner/_work}"

if [ -z "$GITHUB_URL" ] || [ -z "$GITHUB_TOKEN" ]; then
    echo "Usage: $0 <runner-name> <github-url> <github-token>"
    echo "Example: $0 my-runner https://github.com/myorg/myrepo ghp_xxxxxxxxxxxx"
    exit 1
fi

echo "Launching runner VM: $RUNNER_NAME"
echo "GitHub URL: $GITHUB_URL"

# Use the main launch script with this snapshot
exec "$(dirname "$SNAPSHOT_DIR")/launch-runner-vm.sh" \
    --snapshot "$SNAPSHOT_DIR" \
    --runner-name "$RUNNER_NAME" \
    --github-url "$GITHUB_URL" \
    --github-token "$GITHUB_TOKEN" \
    --runner-labels "$RUNNER_LABELS"
EOF
    
    chmod +x "${snapshot_dir}/launch.sh"
    
    # Calculate snapshot size
    local snapshot_size=$(du -sh "$snapshot_dir" | cut -f1)
    
    print_info "Snapshot created successfully!"
    print_info "Snapshot location: $snapshot_dir"
    print_info "Snapshot size: $snapshot_size"
    print_info ""
    print_info "Files created:"
    print_info "  - rootfs.ext4: Runner filesystem snapshot"
    print_info "  - vmlinux: Kernel binary (if available)"
    print_info "  - snapshot-info.json: Snapshot metadata"
    print_info "  - launch-template.json: VM configuration template"
    print_info "  - cloud-init-template.yaml: Cloud-init configuration template"
    print_info "  - launch.sh: Quick launch script"
    print_info ""
    print_info "To launch a VM from this snapshot:"
    print_info "  cd $snapshot_dir"
    print_info "  ./launch.sh <runner-name> <github-url> <github-token>"
    
    # Update snapshot registry
    update_snapshot_registry "$snapshot_name" "$snapshot_dir"
}

update_snapshot_registry() {
    local snapshot_name="$1"
    local snapshot_dir="$2"
    local registry_file="${SNAPSHOTS_DIR}/registry.json"
    
    # Create registry if it doesn't exist
    if [ ! -f "$registry_file" ]; then
        echo '{"snapshots": []}' > "$registry_file"
    fi
    
    # Add snapshot to registry
    local temp_file=$(mktemp)
    jq --arg name "$snapshot_name" \
       --arg dir "$snapshot_dir" \
       --arg created "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
       '.snapshots += [{
           "name": $name,
           "path": $dir,
           "created_at": $created,
           "type": "actions-runner"
       }]' "$registry_file" > "$temp_file"
    
    mv "$temp_file" "$registry_file"
    print_info "Updated snapshot registry: $registry_file"
}

list_snapshots() {
    print_header "Available VM Snapshots"
    
    local registry_file="${SNAPSHOTS_DIR}/registry.json"
    
    if [ ! -f "$registry_file" ]; then
        print_info "No snapshots found. Create one with: ./snapshot-runner-image.sh create"
        return
    fi
    
    echo "Snapshots:"
    jq -r '.snapshots[] | "  \(.name) - \(.created_at) (\(.path))"' "$registry_file"
    echo ""
    
    # Show disk usage
    if [ -d "$SNAPSHOTS_DIR" ]; then
        local total_size=$(du -sh "$SNAPSHOTS_DIR" 2>/dev/null | cut -f1 || echo "unknown")
        print_info "Total snapshots size: $total_size"
    fi
}

delete_snapshot() {
    local snapshot_name="$1"
    
    if [ -z "$snapshot_name" ]; then
        print_error "Snapshot name required"
        print_info "Usage: $0 delete <snapshot-name>"
        return 1
    fi
    
    print_header "Deleting Snapshot: ${snapshot_name}"
    
    local registry_file="${SNAPSHOTS_DIR}/registry.json"
    local snapshot_dir="${SNAPSHOTS_DIR}/${snapshot_name}"
    
    if [ ! -d "$snapshot_dir" ]; then
        print_error "Snapshot not found: $snapshot_name"
        return 1
    fi
    
    # Confirm deletion
    read -p "Are you sure you want to delete snapshot '$snapshot_name'? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deletion cancelled"
        return 0
    fi
    
    # Delete snapshot directory
    rm -rf "$snapshot_dir"
    print_info "Deleted snapshot directory: $snapshot_dir"
    
    # Update registry
    if [ -f "$registry_file" ]; then
        local temp_file=$(mktemp)
        jq --arg name "$snapshot_name" '.snapshots |= map(select(.name != $name))' "$registry_file" > "$temp_file"
        mv "$temp_file" "$registry_file"
        print_info "Updated snapshot registry"
    fi
    
    print_info "Snapshot '$snapshot_name' deleted successfully"
}

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  create [snapshot-name]    Create a new snapshot from runner image"
    echo "  list                      List all available snapshots"
    echo "  delete <snapshot-name>    Delete a snapshot"
    echo "  help                      Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 create                 # Create snapshot with auto-generated name"
    echo "  $0 create runner-v1.0     # Create snapshot with specific name"
    echo "  $0 list                   # List all snapshots"
    echo "  $0 delete runner-v1.0     # Delete specific snapshot"
}

main() {
    check_os
    
    case "${1:-help}" in
        create)
            create_snapshot "${2:-}"
            ;;
        list)
            list_snapshots
            ;;
        delete)
            delete_snapshot "${2:-}"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            usage
            ;;
    esac
}

# Run main function
main "$@" 