#!/bin/bash

# Test New Networking Approach
# Tests the shared bridge networking with multiple VMs

echo "=== Testing Shared Bridge Networking ==="
echo ""

# Build if needed
if [ ! -f "firecracker-data/images/actions-runner-ubuntu-24.04.ext4" ]; then
    echo "Building runner image..."
    ./firecracker-runner.sh build
fi

# Create snapshot
echo "Creating test snapshot..."
./firecracker-runner.sh snapshot network-test

echo ""
echo "=== Test 1: VM with cloud-init ==="
./firecracker-runner.sh launch \
  --snapshot network-test \
  --name test-vm-1 \
  --github-url "https://github.com/test/repo" \
  --github-token "fake-token-for-test" &

sleep 5

echo ""
echo "=== Test 2: VM without cloud-init ==="
./firecracker-runner.sh launch \
  --snapshot network-test \
  --name test-vm-2 \
  --no-cloud-init &

sleep 10

echo ""
echo "=== Checking VM status ==="
./firecracker-runner.sh list

echo ""
echo "=== Checking bridge and networking ==="
echo "Bridge status:"
ip addr show firecracker-br0 2>/dev/null || echo "Bridge not found"

echo ""
echo "TAP device status:"
ip addr show firecracker-tap0 2>/dev/null || echo "TAP device not found"

echo ""
echo "Testing connectivity (wait 30 seconds for VMs to boot)..."
sleep 30

echo ""
echo "Ping test to VMs:"
for vm_dir in firecracker-data/instances/*/; do
    if [ -f "${vm_dir}info.json" ]; then
        vm_ip=$(jq -r '.ip' "${vm_dir}info.json")
        vm_name=$(jq -r '.name' "${vm_dir}info.json")
        echo -n "  $vm_name ($vm_ip): "
        if ping -c 1 -W 2 "$vm_ip" >/dev/null 2>&1; then
            echo "✅ Reachable"
        else
            echo "❌ Not reachable"
        fi
    fi
done

echo ""
echo "To SSH into VMs:"
for vm_dir in firecracker-data/instances/*/; do
    if [ -f "${vm_dir}info.json" ]; then
        vm_ip=$(jq -r '.ip' "${vm_dir}info.json")
        vm_name=$(jq -r '.name' "${vm_dir}info.json")
        echo "  $vm_name: ssh -i ${vm_dir}ssh_key runner@$vm_ip"
    fi
done

echo ""
echo "To cleanup: ./firecracker-runner.sh cleanup" 