#!/bin/bash

# Fix Networking Conflicts Script
# This fixes the issue where multiple TAP devices have the same IP

echo "=== Fixing TAP Device Networking Conflicts ==="
echo ""

echo "Current TAP devices with conflicts:"
ip addr show | grep -A 2 "tap-" | grep "inet 172.16.0.1"

echo ""
echo "Stopping any running Firecracker instances..."
./firecracker-runner.sh cleanup

echo ""
echo "Removing conflicting TAP devices..."
for tap in $(ip link show | grep -o 'tap-[a-zA-Z0-9\-]*' || true); do
    echo "Removing $tap..."
    sudo ip link del "$tap" 2>/dev/null || true
done

echo ""
echo "Cleaning up any remaining DHCP servers..."
sudo pkill -f "dnsmasq.*tap-" 2>/dev/null || true

echo ""
echo "Checking for remaining TAP devices..."
remaining_taps=$(ip link show | grep -o 'tap-[a-zA-Z0-9\-]*' || true)
if [ -n "$remaining_taps" ]; then
    echo "Warning: Some TAP devices still exist:"
    echo "$remaining_taps"
else
    echo "✅ All TAP devices cleaned up"
fi

echo ""
echo "Networking conflicts fixed!"
echo ""
echo "Now you can test the updated script:"
echo "  ./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name vm1"
echo "  ./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name vm2"
echo "  ./firecracker-runner.sh list" 