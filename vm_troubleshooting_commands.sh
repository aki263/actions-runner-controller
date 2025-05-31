#!/bin/bash
echo "=== Firecracker VM Troubleshooting Commands ==="
echo "Copy and run these on your k8s cluster node:"
echo ""

cat << 'EOF'
# Get controller pod name
POD_NAME=$(kubectl get pods -n arc-systems -l app.kubernetes.io/name=actions-runner-controller -o jsonpath='{.items[0].metadata.name}')
echo "Controller pod: $POD_NAME"

# Check running VMs
echo "=== Running Firecracker processes ==="
kubectl exec -n arc-systems $POD_NAME -- ps aux | grep firecracker | grep -v grep

# List VM instances 
echo "=== VM instances ==="
kubectl exec -n arc-systems $POD_NAME -- find /opt/firecracker/data/instances -type d -maxdepth 1 | grep -v "^/opt/firecracker/data/instances$"

# View specific VM console log
VM_ID="tenki-st-XXXXXXXX"  # Replace with actual VM ID
echo "=== Console log for $VM_ID ==="
kubectl exec -n arc-systems $POD_NAME -- cat /opt/firecracker/data/instances/$VM_ID/console.log

# View VM info
echo "=== VM info for $VM_ID ==="
kubectl exec -n arc-systems $POD_NAME -- cat /opt/firecracker/data/instances/$VM_ID/info.json

# Check network interfaces
echo "=== Network interfaces ==="
kubectl exec -n arc-systems $POD_NAME -- ip link show | grep -E "(tap-|br|enp)"

# Check bridge status  
echo "=== Bridge br0 status ==="
kubectl exec -n arc-systems $POD_NAME -- ip link show br0
kubectl exec -n arc-systems $POD_NAME -- bridge link

# Check DHCP leases if using dnsmasq
echo "=== DHCP leases ==="
kubectl exec -n arc-systems $POD_NAME -- cat /var/lib/dhcp/dhcpd.leases 2>/dev/null || echo "DHCP leases not available"

# Monitor real-time logs
echo "=== Monitor real-time logs ==="
kubectl logs -f $POD_NAME -n arc-systems | grep -E "(Firecracker|VM|strict|resource|DHCP|bridge)"

# Check controller resource usage
echo "=== Controller resource usage ==="
kubectl top pods -n arc-systems $POD_NAME

# View runner events
echo "=== Recent runner events ==="
kubectl get events -n arc-runners --sort-by='.lastTimestamp' | tail -10

# Check if runners are getting IP addresses
echo "=== Runners with IPs ==="
kubectl get runners -A -o custom-columns="NAME:.metadata.name,IP:.status.ip,PHASE:.status.phase"

EOF 