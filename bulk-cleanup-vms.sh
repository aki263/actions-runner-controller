#!/bin/bash

# Bulk cleanup all VMs script - for testing only
set -e

DAEMON_URL="http://192.168.21.32:30090"

echo "Getting list of all VMs..."
VM_NAMES=$(curl -s "$DAEMON_URL/vms" | jq -r '.vms | keys[]')

if [ -z "$VM_NAMES" ]; then
    echo "No VMs found to cleanup"
    exit 0
fi

echo "Found VMs to cleanup:"
echo "$VM_NAMES" | head -10
echo "... and $(echo "$VM_NAMES" | wc -l) total VMs"
echo

echo "Starting bulk cleanup..."
count=0
total=$(echo "$VM_NAMES" | wc -l)

for vm_name in $VM_NAMES; do
    count=$((count + 1))
    echo -n "[$count/$total] Deleting VM: $vm_name ... "
    
    response=$(curl -s -X DELETE "$DAEMON_URL/vms/$vm_name" 2>/dev/null)
    
    if echo "$response" | grep -q '"success": *true'; then
        echo "✓"
    else
        echo "✗ ($(echo "$response" | jq -r '.message // "unknown error"'))"
    fi
done

echo
echo "Cleanup complete! Checking final status..."
sleep 2
final_count=$(curl -s "$DAEMON_URL/vms" | jq '.vms | length')
echo "Remaining VMs: $final_count" 