#!/bin/bash
echo "=== Testing Firecracker VM Resource Controls ==="

# First clean up disk space and scale down runners
echo "Step 1: Cleaning up existing resources..."
./cleanup_disk_space.sh
./scale_down_runners.sh

echo "Step 2: Apply new deployment with strict controls..."
kubectl patch deployment arc-gha-rs-controller-actions-runner-controller -n arc-systems --patch-file fix-deployment.yaml

echo "Step 3: Wait for deployment to update..."
kubectl rollout status deployment/arc-gha-rs-controller-actions-runner-controller -n arc-systems --timeout=300s

echo "Step 4: Check pod status..."
kubectl get pods -n arc-systems -l app.kubernetes.io/name=actions-runner-controller

echo "Step 5: Check pod logs for resource control messages..."
POD_NAME=$(kubectl get pods -n arc-systems -l app.kubernetes.io/name=actions-runner-controller -o jsonpath='{.items[0].metadata.name}')
kubectl logs $POD_NAME -n arc-systems | tail -20

echo "Step 6: Scale up runners cautiously (1 replica)..."
kubectl scale runnerdeployment -n arc-runners tenki-staging-firecracker --replicas=1 2>/dev/null || echo "No runnerdeployment found, trying HRA..."
kubectl patch hra -n arc-runners tenki-staging-firecracker --type='merge' -p='{"spec":{"minReplicas":1,"maxReplicas":1}}' 2>/dev/null || echo "No HRA found"

echo "Step 7: Monitor VM creation..."
echo "Watch for 'Creating Firecracker VM with strict resource controls' messages..."
kubectl logs -f $POD_NAME -n arc-systems &
LOG_PID=$!

echo "Monitoring for 30 seconds..."
sleep 30
kill $LOG_PID 2>/dev/null

echo "Step 8: Check current runners and disk usage..."
kubectl get runners -A 2>/dev/null || echo "No runners found"
echo "Current disk usage:"
df -h / | grep -E "(Filesystem|/dev/)"

echo "=== Test completed ===" 