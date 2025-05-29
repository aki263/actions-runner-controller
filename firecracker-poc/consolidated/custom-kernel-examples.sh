#!/bin/bash

# Custom Kernel Examples for Firecracker Runner
# This shows various ways to use custom kernels

echo "=== Firecracker Runner Custom Kernel Examples ==="
echo ""

echo "1. Using your custom built kernel:"
echo "   ./firecracker-runner.sh launch \\"
echo "     --kernel ../vmlinux-6.1.128-custom \\"
echo "     --snapshot runner-20250529-222120 \\"
echo "     --no-cloud-init \\"
echo "     --name test-custom-kernel"
echo ""

echo "2. Testing with custom kernel + GitHub runner:"
echo "   ./firecracker-runner.sh launch \\"
echo "     --kernel ../vmlinux-6.1.128-custom \\"
echo "     --snapshot runner-20250529-222120 \\"
echo "     --github-url https://github.com/your-org/repo \\"
echo "     --github-token ghp_xxxxx \\"
echo "     --name custom-kernel-runner"
echo ""

echo "3. Different kernel locations:"
echo "   # From firecracker-vm directory:"
echo "   --kernel ../firecracker-vm/vmlinux-6.1.128-custom"
echo ""
echo "   # From build directory:"
echo "   --kernel ../build/vmlinux"
echo ""
echo "   # Absolute path:"
echo "   --kernel /path/to/your/custom/vmlinux"
echo ""

echo "4. Verify your custom kernel features:"
echo "   # After VM starts, SSH in and check:"
echo "   ssh -i firecracker-data/instances/*/ssh_key runner@172.16.0.2"
echo "   uname -r                    # Kernel version"
echo "   cat /proc/config.gz | gunzip | grep CONFIG_DOCKER"
echo "   cat /proc/config.gz | gunzip | grep CONFIG_NAMESPACES"
echo "   cat /proc/config.gz | gunzip | grep CONFIG_CGROUPS"
echo ""

echo "5. Quick test commands:"
echo "   # Test container features:"
echo "   docker run --rm hello-world"
echo "   unshare --pid --fork --mount-proc bash"
echo "   ls /sys/fs/cgroup"
echo ""

echo "=== Kernel Build Reminder ==="
echo "If you need to build a custom kernel:"
echo "  cd ../; ./build-firecracker-kernel.sh"
echo "  # Look for: vmlinux-6.1.128-custom" 