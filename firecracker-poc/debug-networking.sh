#!/bin/bash

# Network debugging script for Firecracker VM connectivity issues

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

debug_host_networking() {
    print_header "Host Network Configuration"
    
    print_info "IP forwarding status:"
    cat /proc/sys/net/ipv4/ip_forward
    
    print_info "TAP devices:"
    ip link show | grep tap || echo "No TAP devices found"
    
    print_info "TAP device details:"
    for tap in $(ip link show | grep -o 'tap-[^:]*' || true); do
        echo "  Device: $tap"
        ip addr show "$tap" 2>/dev/null || echo "    No IP assigned"
        echo ""
    done
    
    print_info "Routing table:"
    ip route show
    
    print_info "iptables NAT rules:"
    sudo iptables -t nat -L -n -v | grep -E "(MASQUERADE|172\.20\.0)" || echo "No relevant NAT rules found"
    
    print_info "iptables FORWARD rules:"
    sudo iptables -L FORWARD -n -v | grep -E "(tap|172\.20\.0)" || echo "No relevant FORWARD rules found"
}

test_vm_connectivity() {
    local vm_ip="${1:-172.20.0.2}"
    
    print_header "Testing VM Connectivity"
    
    print_info "Testing ping to VM ($vm_ip):"
    if ping -c 3 -W 2 "$vm_ip"; then
        print_info "✅ VM is reachable via ping"
    else
        print_error "❌ VM is not reachable via ping"
    fi
    
    print_info "Testing SSH connectivity:"
    local ssh_key="${WORK_DIR}/vm_key"
    if [ -f "$ssh_key" ]; then
        if ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$vm_ip" 'echo "SSH test successful"' 2>/dev/null; then
            print_info "✅ SSH is working"
        else
            print_error "❌ SSH is not working"
            print_info "Trying to connect with verbose output:"
            ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -v root@"$vm_ip" 'echo "SSH test"' || true
        fi
    else
        print_warning "SSH key not found at: $ssh_key"
    fi
}

show_vm_status() {
    print_header "VM Status"
    
    if [ ! -d "$WORK_DIR" ]; then
        print_warning "Work directory not found: $WORK_DIR"
        return
    fi
    
    cd "$WORK_DIR"
    
    print_info "Running VMs:"
    for pid_file in firecracker-*.pid; do
        if [ -f "$pid_file" ]; then
            local vm_id=$(basename "$pid_file" .pid | sed 's/firecracker-//')
            local pid=$(cat "$pid_file")
            
            if kill -0 "$pid" 2>/dev/null; then
                print_info "  VM $vm_id: RUNNING (PID: $pid)"
            else
                print_warning "  VM $vm_id: STOPPED (stale PID file)"
            fi
        fi
    done
}

fix_common_issues() {
    print_header "Attempting to Fix Common Issues"
    
    print_info "Enabling IP forwarding:"
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
    
    print_info "Checking for conflicting iptables rules:"
    # Remove any duplicate rules
    sudo iptables -t nat -D POSTROUTING -s 172.20.0.2/32 -j MASQUERADE 2>/dev/null || true
    sudo iptables -t nat -A POSTROUTING -s 172.20.0.2/32 -j MASQUERADE
    
    print_info "Ensuring FORWARD rules are in place:"
    sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    
    for tap in $(ip link show | grep -o 'tap-[^:]*' || true); do
        print_info "Fixing rules for $tap:"
        sudo iptables -D FORWARD -i "$tap" -j ACCEPT 2>/dev/null || true
        sudo iptables -A FORWARD -i "$tap" -j ACCEPT
        sudo iptables -D FORWARD -o "$tap" -j ACCEPT 2>/dev/null || true
        sudo iptables -A FORWARD -o "$tap" -j ACCEPT
    done
    
    print_info "Common fixes applied"
}

usage() {
    echo "Usage: $0 [command] [vm_ip]"
    echo ""
    echo "Commands:"
    echo "  host                  Debug host network configuration"
    echo "  vm [ip]              Test VM connectivity (default: 172.20.0.2)"
    echo "  status               Show VM status"
    echo "  fix                  Attempt to fix common networking issues"
    echo "  all [ip]             Run all debugging steps"
    echo ""
    echo "Examples:"
    echo "  $0 all"
    echo "  $0 vm 172.20.0.2"
    echo "  $0 fix"
}

main() {
    case "${1:-all}" in
        host)
            debug_host_networking
            ;;
        vm)
            test_vm_connectivity "${2:-172.20.0.2}"
            ;;
        status)
            show_vm_status
            ;;
        fix)
            fix_common_issues
            ;;
        all)
            show_vm_status
            debug_host_networking
            test_vm_connectivity "${2:-172.20.0.2}"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            usage
            ;;
    esac
}

main "$@" 