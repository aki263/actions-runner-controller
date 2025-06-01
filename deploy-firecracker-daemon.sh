#!/bin/bash
# deploy-firecracker-daemon.sh - Deploy Firecracker VM DaemonSet
# This script deploys the host-based Firecracker VM management system

set -euo pipefail

NAMESPACE="${FIRECRACKER_NAMESPACE:-arc-systems}"
NODE_LABEL="${FIRECRACKER_NODE_LABEL:-arc.actions/firecracker-capable=true}"

echo "=== Deploying Firecracker VM DaemonSet ==="
echo "Namespace: $NAMESPACE"
echo "Node Label: $NODE_LABEL"

# Create namespace if it doesn't exist
echo "Creating namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Apply the ConfigMap with scripts
echo "Applying Firecracker scripts ConfigMap..."
kubectl apply -f firecracker-scripts-configmap.yaml

# Apply the DaemonSet
echo "Applying Firecracker VM DaemonSet..."
kubectl apply -f firecracker-vm-daemonset.yaml

# Label nodes for DaemonSet scheduling
echo ""
echo "=== Node Labeling ==="
echo "To enable Firecracker on specific nodes, label them with:"
echo "  kubectl label node <NODE_NAME> arc.actions/firecracker-capable=true"
echo ""
echo "Current nodes that could be labeled:"
kubectl get nodes --no-headers | awk '{print "  kubectl label node " $1 " arc.actions/firecracker-capable=true"}'

echo ""
echo "=== Checking Deployment Status ==="
echo "DaemonSet status:"
kubectl get daemonset firecracker-vm-daemon -n "$NAMESPACE" -o wide

echo ""
echo "Pod status:"
kubectl get pods -n "$NAMESPACE" -l app=firecracker-vm-daemon

echo ""
echo "=== Next Steps ==="
echo "1. Label target nodes with: arc.actions/firecracker-capable=true"
echo "2. Verify DaemonSet pods are running"
echo "3. Check pod logs: kubectl logs -n $NAMESPACE -l app=firecracker-vm-daemon"
echo "4. Test API: curl http://<NODE_IP>:30090/health"
echo "5. Set ENABLE_FIRECRACKER=true in your ARC controller"
echo "6. Set FIRECRACKER_DAEMON_URL=http://<NODE_IP>:30090 if needed" 