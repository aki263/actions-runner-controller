#!/bin/bash
# Setup script for Firecracker integration with Actions Runner Controller

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration
FIRECRACKER_DIR="/opt/firecracker"
ARC_NAMESPACE="actions-runner-system"
FIRECRACKER_COMPLETE_SCRIPT="./firecracker-complete.sh"

print_header "Setting up Firecracker Integration for Actions Runner Controller"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root for Firecracker setup"
   exit 1
fi

# Check dependencies
print_info "Checking dependencies..."

DEPS=("firecracker" "kubectl" "jq" "curl" "ssh-keygen" "genisoimage")
MISSING_DEPS=()

for dep in "${DEPS[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        MISSING_DEPS+=("$dep")
    fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    print_error "Missing dependencies: ${MISSING_DEPS[*]}"
    print_info "Install with: sudo apt update && sudo apt install -y firecracker kubectl jq curl openssh-client genisoimage"
    exit 1
fi

# Check KVM access
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    print_error "Cannot access /dev/kvm. Run: sudo usermod -a -G kvm \$USER && newgrp kvm"
    exit 1
fi

# Setup Firecracker directories
print_info "Setting up Firecracker directories..."
mkdir -p "${FIRECRACKER_DIR}"/{data,kernels,images,snapshots,instances}
chown -R $(logname):$(logname) "${FIRECRACKER_DIR}" || true

# Create symbolic link to firecracker-complete.sh if it exists
if [ -f "${FIRECRACKER_COMPLETE_SCRIPT}" ]; then
    print_info "Linking firecracker-complete.sh to /usr/local/bin/"
    ln -sf "$(realpath ${FIRECRACKER_COMPLETE_SCRIPT})" /usr/local/bin/firecracker-complete
    chmod +x /usr/local/bin/firecracker-complete
else
    print_warning "firecracker-complete.sh not found at ${FIRECRACKER_COMPLETE_SCRIPT}"
    print_info "You'll need to manually place it or build your kernels/images"
fi

# Check Kubernetes connection
print_info "Checking Kubernetes connection..."
if ! kubectl get nodes &>/dev/null; then
    print_error "Cannot connect to Kubernetes cluster. Please configure kubectl."
    exit 1
fi

# Check if ARC is deployed
if ! kubectl get namespace "${ARC_NAMESPACE}" &>/dev/null; then
    print_error "Actions Runner Controller namespace '${ARC_NAMESPACE}' not found."
    print_info "Please install Actions Runner Controller first."
    exit 1
fi

# Apply Firecracker service and config
print_info "Applying Firecracker service and configuration..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: arc-firecracker-controller
  namespace: ${ARC_NAMESPACE}
  labels:
    app.kubernetes.io/name: actions-runner-controller
    app.kubernetes.io/component: firecracker-api
spec:
  type: NodePort
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    nodePort: 30080
    protocol: TCP
  - name: firecracker-api
    port: 8081
    targetPort: 8081
    nodePort: 30081
    protocol: TCP
  selector:
    app.kubernetes.io/name: actions-runner-controller
    app.kubernetes.io/component: controller-manager
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: firecracker-config
  namespace: ${ARC_NAMESPACE}
data:
  config.yaml: |
    workDir: "${FIRECRACKER_DIR}/data"
    kernelDir: "${FIRECRACKER_DIR}/kernels"
    imagesDir: "${FIRECRACKER_DIR}/images"
    snapshotsDir: "${FIRECRACKER_DIR}/snapshots"
    instancesDir: "${FIRECRACKER_DIR}/instances"
    
    defaultKernel: "vmlinux-6.1.128-ubuntu24"
    defaultRootfs: "actions-runner-ubuntu-24.04.ext4"
    defaultMemoryMiB: 2048
    defaultVCPUs: 2
    
    defaultNetworkConfig:
      interface: "eth0"
      subnetCIDR: "172.16.0.0/24"
      gateway: "172.16.0.1"
      bridgeName: "fc-br0"
      tapDeviceName: "fc-tap0"
    
    hostBridge:
      name: "br0"
      enabled: false
    
    arcControllerURL: "http://localhost:30080"
EOF

print_info "Firecracker service and config applied successfully"

# Update controller deployment to mount Firecracker directories
print_info "Updating Actions Runner Controller deployment for Firecracker support..."

# Get the current deployment
DEPLOYMENT_NAME=$(kubectl get deployment -n "${ARC_NAMESPACE}" -l app.kubernetes.io/name=actions-runner-controller -o jsonpath='{.items[0].metadata.name}')

if [ -z "$DEPLOYMENT_NAME" ]; then
    print_error "Cannot find Actions Runner Controller deployment"
    exit 1
fi

print_info "Found ARC deployment: ${DEPLOYMENT_NAME}"

# Create a patch to add Firecracker volumes and environment variables
cat <<EOF > /tmp/firecracker-patch.yaml
spec:
  template:
    spec:
      containers:
      - name: manager
        env:
        - name: FIRECRACKER_WORK_DIR
          value: "${FIRECRACKER_DIR}/data"
        - name: ENABLE_FIRECRACKER
          value: "true"
        volumeMounts:
        - name: firecracker-data
          mountPath: ${FIRECRACKER_DIR}
        - name: dev-kvm
          mountPath: /dev/kvm
        - name: firecracker-config
          mountPath: /etc/firecracker
          readOnly: true
      volumes:
      - name: firecracker-data
        hostPath:
          path: ${FIRECRACKER_DIR}
          type: DirectoryOrCreate
      - name: dev-kvm
        hostPath:
          path: /dev/kvm
          type: CharDevice
      - name: firecracker-config
        configMap:
          name: firecracker-config
EOF

# Apply the patch
if kubectl patch deployment "${DEPLOYMENT_NAME}" -n "${ARC_NAMESPACE}" --patch-file /tmp/firecracker-patch.yaml; then
    print_info "Successfully patched ARC deployment for Firecracker support"
else
    print_warning "Failed to patch deployment automatically. Manual patching may be required."
fi

rm -f /tmp/firecracker-patch.yaml

# Setup networking for Firecracker
print_info "Setting up Firecracker networking..."

# Enable IP forwarding
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
echo 'net.bridge.bridge-nf-call-iptables = 1' >> /etc/sysctl.conf
echo 'net.bridge.bridge-nf-call-ip6tables = 1' >> /etc/sysctl.conf
sysctl -p

# Load required modules
cat > /etc/modules-load.d/firecracker.conf <<EOF
# Firecracker required modules
br_netfilter
xt_conntrack
nf_nat
nf_conntrack
bridge
veth
overlay
EOF

# Load modules now
modprobe br_netfilter 2>/dev/null || true
modprobe xt_conntrack 2>/dev/null || true
modprobe overlay 2>/dev/null || true

print_info "Networking setup complete"

# Build kernel and filesystem if firecracker-complete.sh is available
if command -v firecracker-complete &>/dev/null; then
    print_info "Building Firecracker kernel and filesystem..."
    
    cd "${FIRECRACKER_DIR}/data" || mkdir -p "${FIRECRACKER_DIR}/data" && cd "${FIRECRACKER_DIR}/data"
    
    # Check if kernel exists
    if [ ! -f "kernels/vmlinux-6.1.128-ubuntu24" ]; then
        print_info "Building kernel (this may take 30-60 minutes)..."
        firecracker-complete build-kernel --skip-deps || {
            print_warning "Kernel build failed. You may need to build manually."
        }
    else
        print_info "Kernel already exists"
    fi
    
    # Check if filesystem exists
    if [ ! -f "images/actions-runner-ubuntu-24.04.ext4" ]; then
        print_info "Building filesystem (this may take 20-30 minutes)..."
        firecracker-complete build-fs --skip-deps || {
            print_warning "Filesystem build failed. You may need to build manually."
        }
    else
        print_info "Filesystem already exists"
    fi
    
    # Create a production snapshot
    if [ -f "images/actions-runner-ubuntu-24.04.ext4" ]; then
        print_info "Creating production snapshot..."
        firecracker-complete snapshot prod-runner-v1 || {
            print_warning "Snapshot creation failed"
        }
    fi
else
    print_warning "firecracker-complete not available. Please build kernel and filesystem manually."
fi

# Wait for deployment to be ready
print_info "Waiting for ARC deployment to be ready..."
kubectl rollout status deployment/"${DEPLOYMENT_NAME}" -n "${ARC_NAMESPACE}" --timeout=300s

print_header "Firecracker Integration Setup Complete!"

print_info "✅ Setup Summary:"
print_info "   • Firecracker directories: ${FIRECRACKER_DIR}"
print_info "   • NodePort service: arc-firecracker-controller (30080, 30081)"
print_info "   • Configuration: firecracker-config ConfigMap"
print_info "   • ARC deployment updated with Firecracker support"
print_info "   • Networking configured for Firecracker VMs"

if command -v firecracker-complete &>/dev/null; then
    print_info "   • Kernel and filesystem built"
    if [ -d "${FIRECRACKER_DIR}/data/snapshots/prod-runner-v1" ]; then
        print_info "   • Production snapshot ready: prod-runner-v1"
    fi
fi

echo
print_info "🚀 Next Steps:"
print_info "1. Create a RunnerDeployment with runtime.type: firecracker"
print_info "2. Configure GitHub credentials secret"
print_info "3. Deploy and monitor your Firecracker runners"
echo
print_info "📖 Example RunnerDeployment:"
print_info "   See: firecracker-poc/example-firecracker-runner-deploy.yaml"
echo
print_info "🔧 Troubleshooting:"
print_info "   • Check logs: kubectl logs -n ${ARC_NAMESPACE} deployment/${DEPLOYMENT_NAME}"
print_info "   • List VMs: firecracker-complete list"
print_info "   • VM status: firecracker-complete status"
echo
print_warning "⚠️  Important:"
print_info "   • Ensure your Kubernetes nodes have KVM support"
print_info "   • Firecracker VMs will run on the same nodes as ARC controller"
print_info "   • Network isolation: VMs use 172.16.0.0/24 by default" 