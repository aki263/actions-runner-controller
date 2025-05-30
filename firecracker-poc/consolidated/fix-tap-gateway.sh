#!/bin/bash

# Fix TAP Gateway Issues
# This script diagnoses and fixes missing gateway IPs on TAP devices

echo "=== Diagnosing TAP Gateway Issues ==="
echo ""

echo "Current TAP devices:"
ip addr show | grep -A 3 "tap-"
echo ""

echo "Checking for gateway IP 172.16.0.1:"
if ip addr show | grep -q "172.16.0.1"; then
    echo "✅ Gateway 172.16.0.1 is configured on:"
    ip addr show | grep -B 2 "172.16.0.1"
else
    echo "❌ Gateway 172.16.0.1 is NOT configured on any interface"
    echo ""
    
    # Find the first TAP device and configure gateway
    first_tap=$(ip link show | grep -o 'tap-[a-zA-Z0-9\-]*' | head -1)
    if [ -n "$first_tap" ]; then
        echo "Configuring gateway 172.16.0.1/24 on $first_tap..."
        if sudo ip addr add 172.16.0.1/24 dev "$first_tap" 2>/dev/null; then
            echo "✅ Gateway configured successfully"
        else
            echo "❌ Failed to configure gateway (may already exist)"
        fi
    else
        echo "❌ No TAP devices found"
    fi
fi

echo ""
echo "Current routing for 172.16.0.0/24:"
ip route show | grep "172.16.0" || echo "No routes found for 172.16.0.0/24"

echo ""
echo "Testing connectivity to VMs:"
./firecracker-runner.sh list

echo ""
echo "To test SSH connectivity:"
echo "1. Get VM IP from above list"
echo "2. Try: ssh -i firecracker-data/instances/*/ssh_key runner@<VM-IP>" 