#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/firecracker-vm"

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

stop_vm() {
    local vm_id="$1"
    local pid_file="${WORK_DIR}/firecracker-${vm_id}.pid"
    local socket_path="${WORK_DIR}/firecracker-${vm_id}.socket"
    local tap_device="tap-${vm_id}"
    
    print_header "Stopping VM: ${vm_id}"
    
    if [ ! -f "${pid_file}" ]; then
        print_error "PID file not found: ${pid_file}"
        return 1
    fi
    
    local pid
    pid=$(cat "${pid_file}")
    
    # Check if process is still running
    if ! kill -0 "${pid}" 2>/dev/null; then
        print_warning "Process ${pid} is not running"
    else
        print_info "Stopping Firecracker process (PID: ${pid})..."
        kill "${pid}"
        
        # Wait for process to stop
        local attempts=0
        while kill -0 "${pid}" 2>/dev/null && [ $attempts -lt 10 ]; do
            sleep 1
            ((attempts++))
        done
        
        if kill -0 "${pid}" 2>/dev/null; then
            print_warning "Process did not stop gracefully, forcing termination..."
            kill -9 "${pid}"
        fi
        
        print_info "Firecracker process stopped"
    fi
    
    # Clean up network interface
    if ip link show "${tap_device}" &> /dev/null; then
        print_info "Removing TAP device: ${tap_device}"
        sudo ip link delete "${tap_device}" 2>/dev/null || true
    fi
    
    # Clean up files
    rm -f "${pid_file}" "${socket_path}"
    
    print_info "VM ${vm_id} stopped and cleaned up"
}

status_vm() {
    local vm_id="$1"
    local pid_file="${WORK_DIR}/firecracker-${vm_id}.pid"
    local config_file="${WORK_DIR}/vm-config-${vm_id}.json"
    local tap_device="tap-${vm_id}"
    
    print_header "VM Status: ${vm_id}"
    
    if [ ! -f "${pid_file}" ]; then
        print_info "Status: STOPPED (no PID file)"
        return 1
    fi
    
    local pid
    pid=$(cat "${pid_file}")
    
    if kill -0 "${pid}" 2>/dev/null; then
        print_info "Status: RUNNING (PID: ${pid})"
        
        # Show VM configuration if available
        if [ -f "${config_file}" ]; then
            echo ""
            echo "Configuration:"
            if command -v jq &> /dev/null; then
                echo "  CPUs: $(jq -r '.["machine-config"].vcpu_count // "N/A"' "${config_file}")"
                echo "  Memory: $(jq -r '.["machine-config"].mem_size_mib // "N/A"' "${config_file}") MB"
                echo "  Kernel: $(jq -r '.["boot-source"].kernel_image_path // "N/A"' "${config_file}")"
                echo "  Rootfs: $(jq -r '.drives[0].path_on_host // "N/A"' "${config_file}")"
            else
                echo "  Config file: ${config_file}"
            fi
        fi
        
        # Show network information
        if ip link show "${tap_device}" &> /dev/null; then
            echo ""
            echo "Network:"
            echo "  TAP device: ${tap_device}"
            local tap_ip
            tap_ip=$(ip addr show "${tap_device}" | grep 'inet ' | awk '{print $2}' || echo "N/A")
            echo "  Host IP: ${tap_ip}"
            echo "  VM IP: 172.20.0.2 (expected)"
        fi
        
        return 0
    else
        print_info "Status: STOPPED (PID file exists but process not running)"
        return 1
    fi
}

list_vms() {
    print_header "Listing VMs"
    
    if [ ! -d "${WORK_DIR}" ]; then
        print_info "No VMs found (work directory doesn't exist)"
        return 0
    fi
    
    local found_vms=false
    
    for pid_file in "${WORK_DIR}"/firecracker-*.pid; do
        if [ -f "${pid_file}" ]; then
            local vm_id
            vm_id=$(basename "${pid_file}" .pid | sed 's/firecracker-//')
            found_vms=true
            
            local pid
            pid=$(cat "${pid_file}")
            
            if kill -0 "${pid}" 2>/dev/null; then
                echo -e "${GREEN}${vm_id}${NC} - RUNNING (PID: ${pid})"
            else
                echo -e "${YELLOW}${vm_id}${NC} - STOPPED (stale PID file)"
            fi
        fi
    done
    
    if [ "$found_vms" = false ]; then
        print_info "No VMs found"
    fi
}

resize_rootfs() {
    local vm_id="$1"
    local new_size="$2"
    local rootfs_file="${WORK_DIR}/ubuntu-24.04-rootfs.ext4"
    
    print_header "Resizing Rootfs for VM: ${vm_id}"
    
    if [ ! -f "${rootfs_file}" ]; then
        print_error "Rootfs file not found: ${rootfs_file}"
        return 1
    fi
    
    # Check if VM is running
    local pid_file="${WORK_DIR}/firecracker-${vm_id}.pid"
    if [ -f "${pid_file}" ]; then
        local pid
        pid=$(cat "${pid_file}")
        if kill -0 "${pid}" 2>/dev/null; then
            print_error "VM ${vm_id} is currently running. Stop it first."
            return 1
        fi
    fi
    
    print_info "Current rootfs size:"
    qemu-img info "${rootfs_file}" | grep "virtual size" || true
    
    print_info "Resizing ${rootfs_file} to ${new_size}..."
    qemu-img resize "${rootfs_file}" "${new_size}"
    
    print_info "Expanding filesystem..."
    e2fsck -f "${rootfs_file}" || true
    resize2fs "${rootfs_file}"
    
    print_info "New rootfs size:"
    qemu-img info "${rootfs_file}" | grep "virtual size" || true
    
    print_info "Rootfs successfully resized to ${new_size}"
    print_info "You can now start the VM and the additional space will be available"
}

cleanup_all() {
    print_header "Cleaning Up All VMs"
    
    if [ ! -d "${WORK_DIR}" ]; then
        print_info "No work directory found, nothing to clean up"
        return 0
    fi
    
    # Stop all running VMs
    for pid_file in "${WORK_DIR}"/firecracker-*.pid; do
        if [ -f "${pid_file}" ]; then
            local vm_id
            vm_id=$(basename "${pid_file}" .pid | sed 's/firecracker-//')
            stop_vm "${vm_id}" || true
        fi
    done
    
    # Clean up any remaining TAP devices
    for tap_device in $(ip link show | grep "tap-" | awk -F': ' '{print $2}' | grep "tap-" || true); do
        print_info "Removing TAP device: ${tap_device}"
        sudo ip link delete "${tap_device}" 2>/dev/null || true
    done
    
    # Clean up iptables rules (be careful with this)
    print_warning "You may need to manually clean up iptables rules if they were created"
    print_info "Example: sudo iptables -t nat -D POSTROUTING -s 172.20.0.0/24 ! -o tap-* -j MASQUERADE"
    
    print_info "Cleanup completed"
}

killall_firecracker() {
    print_header "Emergency: Killing All Firecracker Processes"
    
    print_warning "This will forcefully terminate ALL Firecracker processes on the system!"
    
    # Find all firecracker processes
    local pids
    pids=$(pgrep -f firecracker || true)
    
    if [ -z "$pids" ]; then
        print_info "No Firecracker processes found"
        return 0
    fi
    
    print_info "Found Firecracker processes: $pids"
    
    # Kill them all
    echo "$pids" | xargs kill -9 2>/dev/null || true
    
    # Clean up any TAP devices
    for tap_device in $(ip link show | grep "tap-" | awk -F': ' '{print $2}' | grep "tap-" || true); do
        print_info "Removing TAP device: ${tap_device}"
        sudo ip link delete "${tap_device}" 2>/dev/null || true
    done
    
    # Clean up PID files
    if [ -d "${WORK_DIR}" ]; then
        rm -f "${WORK_DIR}"/firecracker-*.pid || true
        rm -f "${WORK_DIR}"/firecracker-*.socket || true
    fi
    
    print_info "All Firecracker processes terminated"
}

show_ssh_info() {
    local vm_id="$1"
    local ssh_key="${WORK_DIR}/vm_key"
    local vm_ip="172.20.0.2"
    
    print_header "SSH Connection Info for VM: ${vm_id}"
    
    if [ ! -f "${ssh_key}" ]; then
        print_error "SSH key not found: ${ssh_key}"
        return 1
    fi
    
    echo "SSH Command:"
    echo "  ssh -i \"${ssh_key}\" root@${vm_ip}"
    echo ""
    echo "SCP Examples:"
    echo "  scp -i \"${ssh_key}\" /local/file root@${vm_ip}:/remote/path"
    echo "  scp -i \"${ssh_key}\" root@${vm_ip}:/remote/file /local/path"
    echo ""
    echo "Port Forwarding Example:"
    echo "  ssh -i \"${ssh_key}\" -L 8080:localhost:80 root@${vm_ip}"
}

usage() {
    echo "Usage: $0 <command> [arguments]"
    echo ""
    echo "Commands:"
    echo "  stop <vm_id>              Stop a running VM"
    echo "  status <vm_id>            Show VM status"
    echo "  list                      List all VMs"
    echo "  resize <vm_id> <size>     Resize rootfs (VM must be stopped)"
    echo "  cleanup                   Stop all VMs and clean up"
    echo "  killall                   Emergency: Kill all Firecracker processes"
    echo "  ssh <vm_id>               Show SSH connection information"
    echo "  help                      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 stop abc123"
    echo "  $0 status abc123"
    echo "  $0 resize abc123 20G"
    echo "  $0 list"
    echo "  $0 cleanup"
    echo "  $0 killall                # Emergency use only"
}

main() {
    if [ $# -eq 0 ]; then
        usage
        exit 1
    fi
    
    local command="$1"
    shift
    
    case "${command}" in
        stop)
            if [ $# -ne 1 ]; then
                print_error "Usage: $0 stop <vm_id>"
                exit 1
            fi
            stop_vm "$1"
            ;;
        status)
            if [ $# -ne 1 ]; then
                print_error "Usage: $0 status <vm_id>"
                exit 1
            fi
            status_vm "$1"
            ;;
        list)
            list_vms
            ;;
        resize)
            if [ $# -ne 2 ]; then
                print_error "Usage: $0 resize <vm_id> <size>"
                print_error "Example: $0 resize abc123 20G"
                exit 1
            fi
            resize_rootfs "$1" "$2"
            ;;
        cleanup)
            cleanup_all
            ;;
        killall)
            killall_firecracker
            ;;
        ssh)
            if [ $# -ne 1 ]; then
                print_error "Usage: $0 ssh <vm_id>"
                exit 1
            fi
            show_ssh_info "$1"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            print_error "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@" 