#!/bin/bash

# Example usage of Firecracker VM setup scripts

set -euo pipefail

echo "=================================================="
echo "Firecracker VM Setup - Example Usage"
echo "=================================================="
echo ""

# Check if running on macOS (this won't work on macOS)
if [[ "$(uname)" == "Darwin" ]]; then
    echo "❌ This script requires Linux with KVM support."
    echo "   Firecracker cannot run on macOS directly."
    echo ""
    echo "To test this on macOS, you need:"
    echo "1. A Linux VM (VMware Fusion, Parallels, or VirtualBox)"
    echo "2. Enable nested virtualization in your VM"
    echo "3. Run these scripts inside the Linux VM"
    echo ""
    echo "Alternatively, use a cloud Linux instance:"
    echo "- AWS EC2 (c5.metal, m5.metal, etc.)"
    echo "- DigitalOcean droplet with nested virtualization"
    echo "- Google Cloud Compute Engine"
    exit 1
fi

echo "🔍 This script demonstrates the Firecracker VM setup process"
echo ""

# Example 1: Basic VM setup
echo "Example 1: Create a basic VM (2 CPUs, 1GB RAM, 10GB disk)"
echo "Command: ./firecracker-setup.sh"
echo ""

# Example 2: Custom VM setup
echo "Example 2: Create a powerful development VM"
echo "Command: ./firecracker-setup.sh --cpus 4 --memory 4096 --rootfs-size 20G"
echo ""

# Example 3: Management commands
echo "Example 3: VM management"
echo "List VMs:     ./firecracker-manage.sh list"
echo "VM status:    ./firecracker-manage.sh status <vm_id>"
echo "Stop VM:      ./firecracker-manage.sh stop <vm_id>"
echo "SSH info:     ./firecracker-manage.sh ssh <vm_id>"
echo "Resize disk:  ./firecracker-manage.sh resize <vm_id> 50G"
echo "Cleanup all:  ./firecracker-manage.sh cleanup"
echo ""

# Example 4: SSH connection
echo "Example 4: Connect to VM via SSH"
echo "ssh -i ./firecracker-vm/vm_key root@172.20.0.2"
echo ""

# Example 5: Install packages in VM
echo "Example 5: Install packages in the VM"
echo "# After SSH-ing into the VM:"
echo "apt update"
echo "apt install -y docker.io nodejs python3 build-essential"
echo ""

# Example 6: Port forwarding
echo "Example 6: Port forwarding from host to VM"
echo "# Forward host port 8080 to VM port 80"
echo "ssh -i ./firecracker-vm/vm_key -L 8080:localhost:80 root@172.20.0.2"
echo ""

echo "📋 Prerequisites checklist:"
echo "□ Linux system with KVM support"
echo "□ sudo/root access"
echo "□ curl, qemu-utils, debootstrap installed"
echo "□ Firecracker binary in PATH"
echo "□ User in 'kvm' group"
echo ""

echo "🚀 Ready to create your first Firecracker VM?"
echo "Run: ./firecracker-setup.sh"
echo ""

echo "📚 For more information, see README.md" 