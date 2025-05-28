#!/bin/bash

# Enhanced network debugging script for Firecracker VMs
# Based on official Firecracker networking guide

set -euo pipefail

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

# Configuration (should match firecracker-setup.sh)
VM_IP="172.16.0.2"
HOST_IP="172.16.0.1"
MASK_SHORT="/30"

print_header "Firecracker Network Debugging"

echo "Expected configuration:"
echo "  Host IP: ${HOST_IP}${MASK_SHORT}"
echo "  VM IP: ${VM_IP}"
echo ""

print_header "Host Network Configuration"

# Check TAP devices
print_info "TAP devices:"
ip link show | grep tap || echo "No TAP devices found"
echo ""

# Check TAP device configuration
for tap in $(ip link show | grep -o 'tap-[a-f0-9]*' || true); do
    print_info "TAP device: $tap"
    ip addr show "$tap" 2>/dev/null || echo "  Device not found"
    echo ""
done

# Check IP forwarding
print_info "IP forwarding status:"
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
    echo "  ✓ IP forwarding enabled"
else
    echo "  ✗ IP forwarding disabled"
fi
echo ""

# Check iptables rules
print_info "Relevant iptables rules:"
echo "NAT rules:"
sudo iptables -t nat -L POSTROUTING -n | grep MASQUERADE || echo "  No MASQUERADE rules found"
echo ""
echo "Forward policy:"
sudo iptables -L FORWARD -n | head -3
echo ""

# Check default route and host interface
print_info "Host default route:"
ip route show default
echo ""

print_info "Host network interfaces:"
ip addr show | grep -E '^[0-9]+:|inet ' | grep -v '127.0.0.1'
echo ""

print_header "VM Connectivity Tests"

# Test VM reachability
print_info "Testing VM connectivity:"
if ping -c 2 -W 2 "${VM_IP}" &> /dev/null; then
    echo "  ✓ VM is reachable via ping"
else
    echo "  ✗ VM is not reachable via ping"
fi
echo ""

# Check if VM is running
print_info "Firecracker processes:"
ps aux | grep firecracker | grep -v grep || echo "  No Firecracker processes found"
echo ""

# Check for VM sockets
print_info "Firecracker sockets:"
find /tmp -name "*.socket" 2>/dev/null | grep firecracker || echo "  No Firecracker sockets found"
echo ""

print_header "Troubleshooting Suggestions"

echo "If networking is not working, try:"
echo ""
echo "1. Check if Firecracker VM is running:"
echo "   ps aux | grep firecracker"
echo ""
echo "2. Verify TAP device configuration:"
echo "   ip addr show tap-<vm-id>"
echo ""
echo "3. Test basic connectivity:"
echo "   ping ${VM_IP}"
echo ""
echo "4. Check iptables rules:"
echo "   sudo iptables -t nat -L"
echo "   sudo iptables -L FORWARD"
echo ""
echo "5. Verify IP forwarding:"
echo "   cat /proc/sys/net/ipv4/ip_forward"
echo ""
echo "6. Inside the VM, run:"
echo "   ip route add default via ${HOST_IP} dev eth0"
echo "   echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
echo ""
echo "7. Test from inside VM:"
echo "   ping ${HOST_IP}  # Test gateway"
echo "   ping 8.8.8.8     # Test internet"
echo ""

print_header "Network Debug Complete" 