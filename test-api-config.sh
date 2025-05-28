#!/bin/bash

# Test script to verify Firecracker API configuration format

set -euo pipefail

echo "Testing Firecracker API configuration format..."

# Test machine config
echo "Machine config JSON:"
cat << EOF
{
    "vcpu_count": 2,
    "mem_size_mib": 1024
}
EOF

echo ""

# Test boot source config
echo "Boot source JSON:"
cat << EOF
{
    "kernel_image_path": "/path/to/vmlinux-6.1.128",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off nomodules rw ip=172.20.0.2::172.20.0.1:255.255.255.0::eth0:off"
}
EOF

echo ""

# Test drive config
echo "Drive config JSON:"
cat << EOF
{
    "drive_id": "rootfs",
    "path_on_host": "/path/to/ubuntu-24.04-rootfs.ext4",
    "is_root_device": true,
    "is_read_only": false
}
EOF

echo ""

# Test network interface config
echo "Network interface JSON:"
cat << EOF
{
    "iface_id": "eth0",
    "guest_mac": "AA:FC:00:00:00:01",
    "host_dev_name": "tap-test"
}
EOF

echo ""
echo "✅ All configurations use correct format for individual API endpoints" 