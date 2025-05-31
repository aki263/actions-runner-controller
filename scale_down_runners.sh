#!/bin/bash
echo "=== Scaling down runners to prevent recreation ==="

# Scale down HorizontalRunnerAutoscalers
echo "Scaling down HRAs..."
kubectl patch hra -n arc-runners tenki-staging-firecracker --type='merge' -p='{"spec":{"minReplicas":0,"maxReplicas":0}}' 2>/dev/null || true

# Scale down RunnerDeployments  
echo "Scaling down RunnerDeployments..."
kubectl scale runnerdeployment -n arc-runners tenki-staging-firecracker --replicas=0 2>/dev/null || true

# Delete all existing runners
echo "Deleting existing runners..."
kubectl delete runners -n arc-runners --all 2>/dev/null || true

# Check current status
echo "Current runners:"
kubectl get runners -A 2>/dev/null || echo "No runners found or kubectl not configured"
kubectl get runnerdeployments -A 2>/dev/null || echo "No runnerdeployments found"
kubectl get hra -A 2>/dev/null || echo "No HRAs found"

echo "=== Script completed ===" 