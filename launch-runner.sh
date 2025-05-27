#!/bin/bash
set -e

# These environment variables are expected to be provided by the controller:
# RUNNER_CR_NAME: The name of the Runner CR.
# RUNNER_CR_NAMESPACE: The namespace of the Runner CR.
# RUNNER_CR_UID: The UID of the Runner CR.
# GITHUB_URL: The GitHub URL for runner registration.
# GITHUB_TOKEN: The GitHub registration token for the runner.
# VMI_NAMESPACE: (Optional, defaults to tenki-68130006 for now) Namespace where VMI and ConfigMap are created.

VMI_NAMESPACE="${VMI_NAMESPACE:-tenki-68130006}" # Default if not set

# Predictable VMI name based on CR information
EXPECTED_VMI_NAME="runner-vmi-${RUNNER_CR_NAMESPACE}-${RUNNER_CR_NAME}"
# Unique name for GitHub registration
RUNNER_NAME_FOR_GITHUB="runner-$(uuidgen)"

RUNNER_URL="$GITHUB_URL"
TOKEN="$GITHUB_TOKEN"

# Create runner-info.json locally first
mkdir -p /runner-info
cat <<EOF > /runner-info/runner-info.json
{
  "name": "$RUNNER_NAME_FOR_GITHUB",
  "url": "$RUNNER_URL",
  "token": "$TOKEN",
  "labels": "self-hosted,vm",
  "ephemeral": true
}
EOF

# ConfigMap name for this VMI's runner-info
RUNNER_INFO_CONFIGMAP_NAME="${EXPECTED_VMI_NAME}-runner-info"

# Create/Update the ConfigMap for runner-info
# This ensures the ConfigMap has the latest token if the pod is recreated.
kubectl create configmap "$RUNNER_INFO_CONFIGMAP_NAME"   --from-file=/runner-info/runner-info.json   -n "$VMI_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Define cleanup function for the ConfigMap
cleanup() {
  echo "Cleaning up ConfigMap $RUNNER_INFO_CONFIGMAP_NAME in namespace $VMI_NAMESPACE..."
  kubectl delete configmap "$RUNNER_INFO_CONFIGMAP_NAME" -n "$VMI_NAMESPACE" --ignore-not-found=true
}

# Set trap to ensure cleanup happens on script exit (normal or error)
trap cleanup EXIT

# Apply the VMI
# Note: The VMI spec now mounts the ConfigMap instead of a hostDisk.
cat <<EOF | kubectl apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstance
metadata:
  name: "$EXPECTED_VMI_NAME"
  namespace: "$VMI_NAMESPACE"
  labels:
    actions.summerwind.dev/runner-cr-name: "$RUNNER_CR_NAME"
    actions.summerwind.dev/runner-cr-namespace: "$RUNNER_CR_NAMESPACE"
    actions.summerwind.dev/runner-cr-uid: "$RUNNER_CR_UID"
spec:
  domain:
    cpu:
      cores: 2
    resources:
      requests:
        memory: 7Gi
    devices:
      disks:
        - name: os-disk
          disk:
            bus: virtio
        - name: runner-info-disk # Name of the disk device
          disk:
            bus: virtio
      interfaces:
        - name: default
          masquerade: {}
  networks:
    - name: default
      pod: {}
  volumes:
    - name: os-disk
      persistentVolumeClaim:
        claimName: ubuntu-2404-vm-pvc
    - name: runner-info-disk # Name of the volume
      configMap:
        name: "$RUNNER_INFO_CONFIGMAP_NAME" # Mount the ConfigMap created above
EOF

# Watch the VM until shutdown.
# Note: The original script watched in 'arc-vm' namespace, ensure VMI_NAMESPACE is used.
echo "Watching VMI $EXPECTED_VMI_NAME in namespace $VMI_NAMESPACE until shutdown..."
while kubectl get vmi "$EXPECTED_VMI_NAME" -n "$VMI_NAMESPACE" &>/dev/null; do
  # Re-register runner if VMI is running but runner is not registered or offline
  # This is a placeholder for more advanced logic if needed.
  # For now, the primary goal is to ensure the VMI is up with the correct info.
  sleep 15
done
echo "VMI $EXPECTED_VMI_NAME in namespace $VMI_NAMESPACE no longer found or has shut down."
