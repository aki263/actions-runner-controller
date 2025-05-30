#!/bin/bash

# Commands to run on your Linux system to fix the TAP gateway issue
# Copy and paste these commands on the Linux machine where the VM is running

echo "=== Fix TAP Gateway on Linux System ==="
echo ""

echo "1. Check current TAP devices:"
echo "   ip addr show | grep -A 3 'tap-'"
echo ""

echo "2. Find the TAP device (should be tap-vm-a-7 or similar):"
echo "   ip link show | grep tap-"
echo ""

echo "3. Configure gateway IP on the TAP device:"
echo "   sudo ip addr add 172.16.0.1/24 dev tap-vm-a-7"
echo ""

echo "4. Verify gateway is configured:"
echo "   ip addr show tap-vm-a-7"
echo ""

echo "5. Test SSH connectivity:"
echo "   ssh -i /path/to/your/firecracker-data/instances/vm-a-7/ssh_key runner@172.16.0.97"
echo ""

echo "=== If you want to fix all TAP devices automatically ==="
echo ""
echo "# Add gateway to first TAP device if not already configured:"
echo "if ! ip addr show | grep -q '172.16.0.1'; then"
echo "    first_tap=\$(ip link show | grep -o 'tap-[a-zA-Z0-9\\-]*' | head -1)"
echo "    if [ -n \"\$first_tap\" ]; then"
echo "        sudo ip addr add 172.16.0.1/24 dev \"\$first_tap\""
echo "        echo \"Gateway configured on \$first_tap\""
echo "    fi"
echo "fi" 