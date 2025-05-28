#!/bin/bash

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    if [[ "$OSTYPE" == "darwin"* ]]; then
        print_error "This script is designed to run on Linux/Ubuntu, not macOS"
        print_info "You are currently on macOS. Please run this script on your Linux machine."
        print_info "Firecracker requires KVM which is only available on Linux."
        exit 1
    fi
}

show_usage() {
    echo "Firecracker VM Management Script"
    echo "Usage: $0 <command> [arguments]"
    echo ""
    echo "Commands:"
    echo "  list                    List all VMs"
    echo "  status <vm_id>          Show VM status"
    echo "  stop <vm_id>            Stop a VM"
    echo "  ssh <vm_id>             SSH into a VM"
    echo "  resize <vm_id> <size>   Resize VM rootfs"
    echo "  cleanup                 Clean up all stopped VMs"
    echo "  help                    Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 status a1b2c3d4"
    echo "  $0 stop a1b2c3d4"
    echo "  $0 ssh a1b2c3d4"
    echo "  $0 resize a1b2c3d4 20G"
    echo "  $0 cleanup"
}

list_vms() {
    print_header "Firecracker VMs"
    
    if [ ! -d "${WORK_DIR}" ]; then
        print_info "No VMs found (work directory doesn't exist)"
        return
    fi
    
    cd "${WORK_DIR}"
    
    local found_vms=false
    
    for pid_file in firecracker-*.pid; do
        if [ ! -f "$pid_file" ]; then
            continue
        fi
        
        found_vms=true
        local vm_id=$(echo "$pid_file" | sed 's/firecracker-\(.*\)\.pid/\1/')
        local pid=$(cat "$pid_file" 2>/dev/null || echo "unknown")
        local status="stopped"
        
        if [ "$pid" != "unknown" ] && kill -0 "$pid" 2>/dev/null; then
            status="running"
        fi
        
        local config_file="vm-config-${vm_id}.json"
        local memory="unknown"
        local cpus="unknown"
        
        if [ -f "$config_file" ]; then
            memory=$(grep -o '"mem_size_mib": [0-9]*' "$config_file" | cut -d' ' -f2)
            cpus=$(grep -o '"vcpu_count": [0-9]*' "$config_file" | cut -d' ' -f2)
        fi
        
        echo -e "${GREEN}VM ID:${NC} $vm_id"
        echo -e "  Status: $status"
        echo -e "  PID: $pid"
        echo -e "  Memory: ${memory}MB"
        echo -e "  CPUs: $cpus"
        echo -e "  Config: $config_file"
        echo ""
    done
    
    if [ "$found_vms" = false ]; then
        print_info "No VMs found"
    fi
}

get_vm_status() {
    local vm_id="$1"
    local pid_file="${WORK_DIR}/firecracker-${vm_id}.pid"
    
    if [ ! -f "$pid_file" ]; then
        echo "not_found"
        return
    fi
    
    local pid=$(cat "$pid_file" 2>/dev/null || echo "unknown")
    
    if [ "$pid" = "unknown" ]; then
        echo "unknown"
        return
    fi
    
    if kill -0 "$pid" 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

show_vm_status() {
    local vm_id="$1"
    
    if [ -z "$vm_id" ]; then
        print_error "VM ID is required"
        echo "Usage: $0 status <vm_id>"
        exit 1
    fi
    
    print_header "VM Status: $vm_id"
    
    local status=$(get_vm_status "$vm_id")
    local pid_file="${WORK_DIR}/firecracker-${vm_id}.pid"
    local config_file="${WORK_DIR}/vm-config-${vm_id}.json"
    local socket_path="${WORK_DIR}/firecracker-${vm_id}.socket"
    
    case $status in
        "not_found")
            print_error "VM not found: $vm_id"
            exit 1
            ;;
        "unknown")
            print_warning "VM status unknown (corrupted PID file)"
            ;;
        "running")
            print_info "VM is running"
            ;;
        "stopped")
            print_warning "VM is stopped"
            ;;
    esac
    
    echo ""
    echo -e "${GREEN}VM Details:${NC}"
    echo "  VM ID: $vm_id"
    echo "  Status: $status"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        echo "  PID: $pid"
    fi
    
    if [ -f "$config_file" ]; then
        local memory=$(grep -o '"mem_size_mib": [0-9]*' "$config_file" | cut -d' ' -f2)
        local cpus=$(grep -o '"vcpu_count": [0-9]*' "$config_file" | cut -d' ' -f2)
        echo "  Memory: ${memory}MB"
        echo "  CPUs: $cpus"
    fi
    
    echo ""
    echo -e "${GREEN}Files:${NC}"
    echo "  PID file: $pid_file"
    echo "  Config: $config_file"
    echo "  Socket: $socket_path"
    echo "  SSH key: ${WORK_DIR}/vm_key"
    
    if [ "$status" = "running" ]; then
        echo ""
        echo -e "${GREEN}SSH Connection:${NC}"
        echo "  ssh -i \"${WORK_DIR}/vm_key\" root@172.20.0.2"
    fi
}

stop_vm() {
    local vm_id="$1"
    
    if [ -z "$vm_id" ]; then
        print_error "VM ID is required"
        echo "Usage: $0 stop <vm_id>"
        exit 1
    fi
    
    print_header "Stopping VM: $vm_id"
    
    local status=$(get_vm_status "$vm_id")
    local pid_file="${WORK_DIR}/firecracker-${vm_id}.pid"
    local socket_path="${WORK_DIR}/firecracker-${vm_id}.socket"
    local tap_device="tap-${vm_id}"
    
    if [ "$status" = "not_found" ]; then
        print_error "VM not found: $vm_id"
        exit 1
    fi
    
    if [ "$status" = "stopped" ]; then
        print_info "VM is already stopped"
    else
        # Try graceful shutdown via API first
        if [ -S "$socket_path" ]; then
            print_info "Attempting graceful shutdown..."
            curl -X PUT \
                --unix-socket "$socket_path" \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -d '{"action_type": "SendCtrlAltDel"}' \
                http://localhost/actions &>/dev/null || true
            
            sleep 3
        fi
        
        # Force kill if still running
        local pid=$(cat "$pid_file" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            print_info "Force stopping VM (PID: $pid)..."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
        
        print_info "VM stopped"
    fi
    
    # Clean up socket
    if [ -S "$socket_path" ]; then
        rm -f "$socket_path"
        print_info "Removed socket: $socket_path"
    fi
    
    # Clean up TAP device
    if ip link show "$tap_device" &>/dev/null; then
        sudo ip link delete "$tap_device" 2>/dev/null || true
        print_info "Removed TAP device: $tap_device"
    fi
    
    print_info "VM cleanup completed"
}

ssh_vm() {
    local vm_id="$1"
    
    if [ -z "$vm_id" ]; then
        print_error "VM ID is required"
        echo "Usage: $0 ssh <vm_id>"
        exit 1
    fi
    
    local status=$(get_vm_status "$vm_id")
    
    if [ "$status" = "not_found" ]; then
        print_error "VM not found: $vm_id"
        exit 1
    fi
    
    if [ "$status" != "running" ]; then
        print_error "VM is not running"
        exit 1
    fi
    
    local ssh_key="${WORK_DIR}/vm_key"
    
    if [ ! -f "$ssh_key" ]; then
        print_error "SSH key not found: $ssh_key"
        exit 1
    fi
    
    print_info "Connecting to VM $vm_id..."
    exec ssh -i "$ssh_key" -o StrictHostKeyChecking=no root@172.20.0.2
}

resize_vm() {
    local vm_id="$1"
    local new_size="$2"
    
    if [ -z "$vm_id" ] || [ -z "$new_size" ]; then
        print_error "VM ID and new size are required"
        echo "Usage: $0 resize <vm_id> <size>"
        echo "Example: $0 resize a1b2c3d4 20G"
        exit 1
    fi
    
    print_header "Resizing VM: $vm_id to $new_size"
    
    local status=$(get_vm_status "$vm_id")
    
    if [ "$status" = "not_found" ]; then
        print_error "VM not found: $vm_id"
        exit 1
    fi
    
    if [ "$status" = "running" ]; then
        print_error "Cannot resize running VM. Stop it first:"
        print_info "$0 stop $vm_id"
        exit 1
    fi
    
    cd "${WORK_DIR}"
    local rootfs_file="ubuntu-24.04-rootfs.ext4"
    
    if [ ! -f "$rootfs_file" ]; then
        print_error "Rootfs file not found: $rootfs_file"
        exit 1
    fi
    
    print_info "Resizing $rootfs_file to $new_size..."
    qemu-img resize "$rootfs_file" "$new_size"
    
    print_info "Expanding filesystem..."
    e2fsck -f "$rootfs_file" || true
    resize2fs "$rootfs_file"
    
    print_info "Rootfs resized to $new_size"
}

cleanup_vms() {
    print_header "Cleaning Up Stopped VMs"
    
    if [ ! -d "${WORK_DIR}" ]; then
        print_info "No work directory found"
        return
    fi
    
    cd "${WORK_DIR}"
    
    local cleaned_count=0
    
    for pid_file in firecracker-*.pid; do
        if [ ! -f "$pid_file" ]; then
            continue
        fi
        
        local vm_id=$(echo "$pid_file" | sed 's/firecracker-\(.*\)\.pid/\1/')
        local status=$(get_vm_status "$vm_id")
        
        if [ "$status" = "stopped" ] || [ "$status" = "unknown" ]; then
            print_info "Cleaning up VM: $vm_id"
            
            # Remove files
            rm -f "firecracker-${vm_id}.pid"
            rm -f "firecracker-${vm_id}.socket"
            rm -f "vm-config-${vm_id}.json"
            
            # Remove TAP device
            local tap_device="tap-${vm_id}"
            if ip link show "$tap_device" &>/dev/null; then
                sudo ip link delete "$tap_device" 2>/dev/null || true
            fi
            
            ((cleaned_count++))
        fi
    done
    
    print_info "Cleaned up $cleaned_count stopped VMs"
}

main() {
    check_os
    
    if [ $# -eq 0 ]; then
        show_usage
        exit 1
    fi
    
    local command="$1"
    shift
    
    case "$command" in
        "list"|"ls")
            list_vms
            ;;
        "status"|"stat")
            show_vm_status "$@"
            ;;
        "stop"|"kill")
            stop_vm "$@"
            ;;
        "ssh"|"connect")
            ssh_vm "$@"
            ;;
        "resize")
            resize_vm "$@"
            ;;
        "cleanup"|"clean")
            cleanup_vms
            ;;
        "help"|"--help"|"-h")
            show_usage
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@" 