#!/bin/bash

# Reset daemon state script
set -e

DAEMON_URL="http://192.168.21.32:30090"

echo "🔄 Resetting Firecracker Daemon State"
echo "======================================"

# 1. Check current VM count
echo "1. Current VM count in daemon:"
current_count=$(curl -s "$DAEMON_URL/vms" | jq '.vms | length')
echo "   VMs tracked: $current_count"

# 2. Restart the daemon pod to clear state
echo
echo "2. Restarting daemon pod to clear state..."
kubectl --kubeconfig=/root/staging-kubeconfig.yaml -n arc-systems delete pod -l app=firecracker-daemon

echo "   Waiting for new pod to start..."
sleep 30

# Get new pod name
new_pod=$(kubectl --kubeconfig=/root/staging-kubeconfig.yaml -n arc-systems get pods -l app=firecracker-daemon -o jsonpath='{.items[0].metadata.name}')
echo "   New pod: $new_pod"

# 3. Wait for daemon to be ready
echo
echo "3. Waiting for daemon to be ready..."
for i in {1..30}; do
    if curl -s "$DAEMON_URL/health" | grep -q '"status": "healthy"'; then
        echo "   ✅ Daemon is healthy"
        break
    fi
    echo "   ⏳ Waiting... ($i/30)"
    sleep 2
done

# 4. Check final VM count
echo
echo "4. Final VM count after reset:"
final_count=$(curl -s "$DAEMON_URL/vms" | jq '.vms | length')
echo "   VMs tracked: $final_count"

echo
if [ "$final_count" -eq 0 ]; then
    echo "✅ SUCCESS: Daemon state reset, no VMs tracked"
else
    echo "⚠️  WARNING: Still tracking $final_count VMs"
fi

echo
echo "5. Testing daemon functionality:"
echo "   Health: $(curl -s "$DAEMON_URL/health" | jq -r '.status')"
echo "   Ready for testing!" 