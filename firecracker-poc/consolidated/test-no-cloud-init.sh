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
echo "3. Choose kernel option:"
echo "   a) Use default kernel (downloaded automatically)"
echo "   b) Use custom kernel"
echo ""
read -p "Enter choice (a/b): " kernel_choice

if [ "$kernel_choice" = "b" ]; then
    # Look for common custom kernel locations
    if [ -f "../working-kernel-config" ]; then
        echo "Found working-kernel-config, checking for built kernel..."
    fi
    
    # Common locations for custom kernels
    custom_kernels=(
        "../vmlinux-6.1.128-custom"
        "../firecracker-vm/vmlinux-6.1.128-custom"
        "./vmlinux-custom"
        "../build/vmlinux"
    )
    
    echo "Looking for custom kernels..."
    for kernel in "${custom_kernels[@]}"; do
        if [ -f "$kernel" ]; then
            echo "Found: $kernel"
            kernel_path="$kernel"
            break
        fi
    done
    
    if [ -z "$kernel_path" ]; then
        read -p "Enter path to custom kernel: " kernel_path
    fi
    
    if [ ! -f "$kernel_path" ]; then
        echo "Error: Kernel not found at $kernel_path"
        exit 1
    fi
    
    kernel_option="--kernel $kernel_path"
    echo "Using custom kernel: $kernel_path"
else
    kernel_option=""
    echo "Using default kernel (will be downloaded)"
fi

echo ""
echo "3. Launching VM without cloud-init for testing..."
echo "   Command: ./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name test-vm $kernel_option"
echo ""

# Ask user to confirm
read -p "Press Enter to launch, or Ctrl+C to cancel..."

./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name test-vm $kernel_option

echo ""
echo "4. If successful, you should be able to SSH with:"
echo "   ssh -i firecracker-data/instances/*/ssh_key runner@172.16.0.2"
echo ""
echo "5. Test commands in VM:"
echo "   ip addr show eth0"
echo "   ip route"
echo "   ping 8.8.8.8"
echo "   systemctl status docker"
echo "   uname -r                   # Check kernel version" 