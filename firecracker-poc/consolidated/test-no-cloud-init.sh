#!/bin/bash

# Test script for launching VM without cloud-init
# Run this on your Linux server

echo "Testing firecracker-runner.sh with --no-cloud-init option"
echo ""

# First clean up any running instances
echo "1. Cleaning up existing instances..."
./firecracker-runner.sh cleanup

echo ""
echo "2. Listing available resources..."
./firecracker-runner.sh list

echo ""
echo "3. Launching VM without cloud-init for testing..."
echo "   Command: ./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name test-vm"
echo ""

# Ask user to confirm
read -p "Press Enter to launch, or Ctrl+C to cancel..."

./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name test-vm

echo ""
echo "4. If successful, you should be able to SSH with:"
echo "   ssh -i firecracker-data/instances/*/ssh_key runner@172.16.0.2"
echo ""
echo "5. Test commands in VM:"
echo "   ip addr show eth0"
echo "   ip route"
echo "   ping 8.8.8.8"
echo "   systemctl status docker" 