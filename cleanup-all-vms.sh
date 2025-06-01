#!/bin/bash

# Cleanup all VMs script
set -e

DAEMON_URL="http://192.168.21.30:30090"

echo "Getting list of all VMs..."
VM_NAMES=$(curl -s "$DAEMON_URL/vms" | jq -r '.host_status' | grep "VM:" | awk '{print $2}')

if [ -z "$VM_NAMES" ]; then
    echo "No VMs found to cleanup"
    exit 0
fi

echo "Found VMs to cleanup:"
echo "$VM_NAMES"
echo
echo "Total VMs: $(echo "$VM_NAMES" | wc -l)"
echo

read -p "Are you sure you want to delete ALL VMs? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 1
fi

echo "Starting cleanup..."
count=0
total=$(echo "$VM_NAMES" | wc -l)

for vm_name in $VM_NAMES; do
    count=$((count + 1))
    echo "[$count/$total] Deleting VM: $vm_name"
    
    response=$(curl -s -X DELETE "$DAEMON_URL/vms/$vm_name")
    
    if echo "$response" | jq -e '.success' >/dev/null 2>&1; then
        echo "  ✅ Successfully deleted"
    else
        echo "  ❌ Failed to delete: $(echo "$response" | jq -r '.message // "Unknown error"')"
    fi
    
    # Small delay to avoid overwhelming the daemon
    sleep 0.5
done

echo
echo "Cleanup completed! Checking remaining VMs..."
curl -s "$DAEMON_URL/vms" | jq '.vms | length'
echo "VMs remaining in tracking" 