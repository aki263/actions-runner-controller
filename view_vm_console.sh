#!/bin/bash
echo "=== VM Console Log Viewer ==="

if [ -z "$1" ]; then
    echo "Usage: $0 <vm-id-or-pattern>"
    echo "Available VMs:"
    
    # Run this on the controller pod
    POD_NAME=$(kubectl get pods -n arc-systems -l app.kubernetes.io/name=actions-runner-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$POD_NAME" ]; then
        echo "Checking VM instances..."
        kubectl exec -n arc-systems $POD_NAME -- find /opt/firecracker/data/instances -name "console.log" 2>/dev/null | sed 's|/opt/firecracker/data/instances/||' | sed 's|/console.log||' || echo "No VM instances found"
    else
        echo "Controller pod not found"
    fi
    exit 1
fi

VM_PATTERN="$1"
POD_NAME=$(kubectl get pods -n arc-systems -l app.kubernetes.io/name=actions-runner-controller -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD_NAME" ]; then
    echo "Error: Controller pod not found"
    exit 1
fi

echo "Looking for VM console logs matching: $VM_PATTERN"

# Find matching console logs
CONSOLE_LOGS=$(kubectl exec -n arc-systems $POD_NAME -- find /opt/firecracker/data/instances -name "console.log" -path "*$VM_PATTERN*" 2>/dev/null)

if [ -z "$CONSOLE_LOGS" ]; then
    echo "No console logs found matching pattern: $VM_PATTERN"
    echo "Available VMs:"
    kubectl exec -n arc-systems $POD_NAME -- find /opt/firecracker/data/instances -name "console.log" 2>/dev/null | sed 's|/opt/firecracker/data/instances/||' | sed 's|/console.log||'
    exit 1
fi

echo "Found console logs:"
echo "$CONSOLE_LOGS"
echo ""

for log in $CONSOLE_LOGS; do
    VM_ID=$(echo "$log" | sed 's|/opt/firecracker/data/instances/||' | sed 's|/console.log||')
    echo "=== Console Log for VM: $VM_ID ==="
    kubectl exec -n arc-systems $POD_NAME -- cat "$log" 2>/dev/null || echo "Failed to read console log"
    echo ""
    
    # Also show VM info if available
    INFO_FILE=$(echo "$log" | sed 's|console.log|info.json|')
    if kubectl exec -n arc-systems $POD_NAME -- test -f "$INFO_FILE" 2>/dev/null; then
        echo "=== VM Info for $VM_ID ==="
        kubectl exec -n arc-systems $POD_NAME -- cat "$INFO_FILE" 2>/dev/null || echo "Failed to read VM info"
        echo ""
    fi
done

echo "=== Live VM processes ==="
kubectl exec -n arc-systems $POD_NAME -- ps aux | grep firecracker | grep -v grep || echo "No Firecracker processes running"

echo "=== Network interfaces ==="
kubectl exec -n arc-systems $POD_NAME -- ip link show | grep -E "(tap-|br|eth)" || echo "No relevant network interfaces found" 