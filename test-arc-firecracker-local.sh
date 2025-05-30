#!/bin/bash

# Test ARC Controller with Firecracker Integration using Kind
# This creates a minimal Kubernetes cluster and tests the actual controller code

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-arc-firecracker-test}"
GITHUB_PAT="${GITHUB_PAT:-}"
GITHUB_ORG="${GITHUB_ORG:-}"
GITHUB_REPO="${GITHUB_REPO:-}"

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if running on Linux (required for Firecracker)
    if [[ "$(uname)" != "Linux" ]]; then
        error "Firecracker requires Linux. This test must run on a Linux system."
        exit 1
    fi
    
    # Check for required tools
    local missing=()
    
    command -v docker >/dev/null 2>&1 || missing+=("docker")
    command -v kind >/dev/null 2>&1 || missing+=("kind")
    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
    command -v go >/dev/null 2>&1 || missing+=("go")
    
    if [[ ${#missing[@]} -ne 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        log "Install missing tools:"
        for tool in "${missing[@]}"; do
            case $tool in
                "docker")
                    echo "  Docker: https://docs.docker.com/engine/install/"
                    ;;
                "kind")
                    echo "  Kind: curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64 && chmod +x ./kind && sudo mv ./kind /usr/local/bin/"
                    ;;
                "kubectl")
                    echo "  kubectl: curl -LO https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl && chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
                    ;;
                "go")
                    echo "  Go: https://golang.org/doc/install"
                    ;;
            esac
        done
        exit 1
    fi
    
    # Check GitHub configuration
    if [[ -z "$GITHUB_PAT" ]]; then
        error "GITHUB_PAT not set. Please export your GitHub Personal Access Token."
        exit 1
    fi
    
    if [[ -z "$GITHUB_ORG" && -z "$GITHUB_REPO" ]]; then
        error "Either GITHUB_ORG or GITHUB_REPO must be set."
        exit 1
    fi
    
    success "Prerequisites check passed"
}

setup_kind_cluster() {
    log "Setting up Kind cluster: $CLUSTER_NAME"
    
    # Check if cluster already exists
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        warn "Cluster $CLUSTER_NAME already exists. Deleting..."
        kind delete cluster --name "$CLUSTER_NAME"
    fi
    
    # Create kind cluster config with privileged containers (needed for Firecracker)
    cat <<EOF > kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: /opt/firecracker
    containerPath: /opt/firecracker
  - hostPath: /tmp/firecracker-sockets
    containerPath: /tmp/firecracker-sockets
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    controllerManager:
      extraArgs:
        bind-address: 0.0.0.0
    scheduler:
      extraArgs:
        bind-address: 0.0.0.0
    etcd:
      local:
        extraArgs:
          listen-metrics-urls: http://0.0.0.0:2381
- role: worker
  extraMounts:
  - hostPath: /opt/firecracker
    containerPath: /opt/firecracker
  - hostPath: /tmp/firecracker-sockets
    containerPath: /tmp/firecracker-sockets
  kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    serverTLSBootstrap: true
    securityContext:
      privileged: true
EOF

    # Create cluster
    kind create cluster --name "$CLUSTER_NAME" --config kind-config.yaml
    
    # Wait for cluster to be ready
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    success "Kind cluster created: $CLUSTER_NAME"
}

build_and_deploy_controller() {
    log "Building and deploying ARC controller with Firecracker support..."
    
    # Build the controller
    log "Building controller..."
    make build
    
    # Build Docker image
    log "Building Docker image..."
    make docker-build IMG=arc-firecracker:test
    
    # Load image into kind cluster
    log "Loading image into Kind cluster..."
    kind load docker-image arc-firecracker:test --name "$CLUSTER_NAME"
    
    # Install CRDs
    log "Installing CRDs..."
    make install
    
    # Create namespace
    kubectl create namespace actions-runner-system --dry-run=client -o yaml | kubectl apply -f -
    
    # Create GitHub secret
    log "Creating GitHub credentials secret..."
    kubectl create secret generic github-pat-secret \
        --from-literal=github_token="$GITHUB_PAT" \
        -n actions-runner-system \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Deploy controller
    log "Deploying controller..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: controller-manager
  namespace: actions-runner-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: controller-manager
  template:
    metadata:
      labels:
        app: controller-manager
    spec:
      serviceAccountName: controller-manager
      containers:
      - name: manager
        image: arc-firecracker:test
        imagePullPolicy: Never
        args:
        - --metrics-addr=0.0.0.0:8080
        - --enable-leader-election=false
        env:
        - name: GITHUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: github-pat-secret
              key: github_token
        resources:
          limits:
            cpu: 200m
            memory: 128Mi
          requests:
            cpu: 100m
            memory: 64Mi
        volumeMounts:
        - name: firecracker-tools
          mountPath: /opt/firecracker
        securityContext:
          privileged: true
      volumes:
      - name: firecracker-tools
        hostPath:
          path: /opt/firecracker
          type: DirectoryOrCreate
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: controller-manager
  namespace: actions-runner-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: controller-manager-role
rules:
- apiGroups: ["actions.summerwind.dev"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: [""]
  resources: ["secrets", "configmaps", "events"]
  verbs: ["*"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: controller-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: controller-manager-role
subjects:
- kind: ServiceAccount
  name: controller-manager
  namespace: actions-runner-system
EOF

    # Wait for controller to be ready
    kubectl wait --for=condition=Available deployment/controller-manager -n actions-runner-system --timeout=300s
    
    success "Controller deployed successfully"
}

setup_firecracker_on_nodes() {
    log "Setting up Firecracker on cluster nodes..."
    
    # Create directories on host (which will be mounted in kind nodes)
    sudo mkdir -p /opt/firecracker/{kernels,images,scripts}
    sudo mkdir -p /tmp/firecracker-sockets
    
    # Copy firecracker tools if available
    if [[ -d "firecracker-poc" ]]; then
        sudo cp -r firecracker-poc/* /opt/firecracker/scripts/
        sudo chmod +x /opt/firecracker/scripts/firecracker-complete.sh
        success "Firecracker tools copied to cluster nodes"
    else
        warn "firecracker-poc not found. You'll need to setup Firecracker tools manually."
    fi
    
    # Install Firecracker on nodes via privileged pods
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: firecracker-setup
  namespace: actions-runner-system
spec:
  selector:
    matchLabels:
      app: firecracker-setup
  template:
    metadata:
      labels:
        app: firecracker-setup
    spec:
      hostNetwork: true
      hostPID: true
      containers:
      - name: setup
        image: ubuntu:22.04
        command: ["/bin/bash"]
        args:
        - -c
        - |
          set -e
          apt-get update
          apt-get install -y wget bridge-utils iptables
          
          # Install Firecracker
          cd /tmp
          wget -q https://github.com/firecracker-microvm/firecracker/releases/download/v1.4.1/firecracker-v1.4.1-x86_64.tgz
          tar xzf firecracker-v1.4.1-x86_64.tgz
          cp release-v1.4.1-x86_64/firecracker-v1.4.1-x86_64 /host/usr/local/bin/firecracker
          cp release-v1.4.1-x86_64/jailer-v1.4.1-x86_64 /host/usr/local/bin/jailer
          chmod +x /host/usr/local/bin/firecracker /host/usr/local/bin/jailer
          
          # Setup bridge network
          nsenter --net=/proc/1/ns/net ip link add firecracker-br0 type bridge || true
          nsenter --net=/proc/1/ns/net ip addr add 172.16.0.1/24 dev firecracker-br0 || true
          nsenter --net=/proc/1/ns/net ip link set firecracker-br0 up || true
          
          echo "Firecracker setup completed on node"
          sleep infinity
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-root
          mountPath: /host
        - name: firecracker-tools
          mountPath: /opt/firecracker
      volumes:
      - name: host-root
        hostPath:
          path: /
      - name: firecracker-tools
        hostPath:
          path: /opt/firecracker
      tolerations:
      - operator: Exists
EOF

    # Wait for daemonset to be ready
    kubectl rollout status daemonset/firecracker-setup -n actions-runner-system --timeout=300s
    
    success "Firecracker setup completed on all nodes"
}

test_firecracker_runnerdeployment() {
    log "Testing Firecracker RunnerDeployment..."
    
    # Determine GitHub scope
    local github_scope=""
    if [[ -n "$GITHUB_REPO" ]]; then
        github_scope="repository: \"$GITHUB_REPO\""
    elif [[ -n "$GITHUB_ORG" ]]; then
        github_scope="organization: \"$GITHUB_ORG\""
    fi
    
    # Create RunnerDeployment with Firecracker annotations
    cat <<EOF | kubectl apply -f -
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: firecracker-test-runners
  namespace: actions-runner-system
  annotations:
    # Enable Firecracker runtime
    runner.summerwind.dev/runtime: "firecracker"
    runner.summerwind.dev/firecracker-kernel: "/opt/firecracker/kernels/vmlinux-5.10"
    runner.summerwind.dev/firecracker-rootfs: "/opt/firecracker/images/ubuntu-runner.ext4"
    runner.summerwind.dev/firecracker-memory: "2048"
    runner.summerwind.dev/firecracker-vcpus: "2"
    runner.summerwind.dev/firecracker-network: '{"interface":"eth0","subnetCIDR":"172.16.0.0/24","gateway":"172.16.0.1"}'
spec:
  replicas: 2
  template:
    metadata:
      labels:
        app: firecracker-runner
    spec:
      $github_scope
      ephemeral: true
      githubAPICredentialsFrom:
        secretRef:
          name: github-pat-secret
      labels:
        - self-hosted
        - firecracker
        - linux
        - x64
        - test
      image: "runner:latest"
      resources:
        limits:
          cpu: "2"
          memory: "4Gi"
        requests:
          cpu: "1"
          memory: "2Gi"
EOF

    success "RunnerDeployment created with Firecracker configuration"
}

monitor_integration() {
    log "Monitoring ARC Firecracker integration..."
    
    echo
    log "=== Controller Logs ==="
    kubectl logs -f -l app=controller-manager -n actions-runner-system --tail=50 &
    local logs_pid=$!
    
    echo
    log "=== RunnerDeployment Status ==="
    kubectl get runnerdeployment firecracker-test-runners -n actions-runner-system -o yaml
    
    echo
    log "=== Events ==="
    kubectl get events -n actions-runner-system --sort-by=.metadata.creationTimestamp
    
    echo
    warn "Monitoring started. You should see:"
    warn "1. Controller detecting Firecracker annotations"
    warn "2. Firecracker VM creation attempts"
    warn "3. GitHub registration token generation"
    warn "4. VM scaling based on replica count"
    warn ""
    warn "Check your GitHub org/repo settings for new runners appearing"
    warn "Press Ctrl+C to stop monitoring"
    
    # Wait for user to stop
    wait $logs_pid 2>/dev/null || true
}

test_scaling() {
    log "Testing Firecracker scaling..."
    
    # Scale to 3 replicas
    log "Scaling to 3 replicas..."
    kubectl patch runnerdeployment firecracker-test-runners -n actions-runner-system -p '{"spec":{"replicas":3}}'
    
    sleep 30
    
    # Scale to 1 replica
    log "Scaling down to 1 replica..."
    kubectl patch runnerdeployment firecracker-test-runners -n actions-runner-system -p '{"spec":{"replicas":1}}'
    
    sleep 30
    
    # Scale to 0 (cleanup)
    log "Scaling to 0 (cleanup)..."
    kubectl patch runnerdeployment firecracker-test-runners -n actions-runner-system -p '{"spec":{"replicas":0}}'
    
    success "Scaling test completed"
}

cleanup() {
    log "Cleaning up test environment..."
    
    # Delete RunnerDeployment
    kubectl delete runnerdeployment firecracker-test-runners -n actions-runner-system --ignore-not-found=true
    
    # Delete Kind cluster
    kind delete cluster --name "$CLUSTER_NAME"
    
    # Cleanup host directories
    sudo rm -rf /opt/firecracker /tmp/firecracker-sockets
    
    # Cleanup files
    rm -f kind-config.yaml
    
    success "Cleanup completed"
}

main() {
    case "${1:-full}" in
        "setup")
            check_prerequisites
            setup_kind_cluster
            setup_firecracker_on_nodes
            build_and_deploy_controller
            ;;
        "test")
            test_firecracker_runnerdeployment
            monitor_integration
            ;;
        "scale")
            test_scaling
            ;;
        "monitor")
            monitor_integration
            ;;
        "cleanup")
            cleanup
            ;;
        "full")
            check_prerequisites
            setup_kind_cluster
            setup_firecracker_on_nodes
            build_and_deploy_controller
            test_firecracker_runnerdeployment
            
            echo
            warn "Setup completed! Now you can:"
            warn "1. Monitor: ./test-arc-firecracker-local.sh monitor"
            warn "2. Test scaling: ./test-arc-firecracker-local.sh scale"
            warn "3. Cleanup: ./test-arc-firecracker-local.sh cleanup"
            warn ""
            warn "Check GitHub: https://github.com/$GITHUB_ORG/settings/actions/runners"
            ;;
        *)
            echo "Usage: $0 [setup|test|scale|monitor|cleanup|full]"
            echo ""
            echo "Commands:"
            echo "  setup   - Setup Kind cluster and deploy controller"
            echo "  test    - Deploy RunnerDeployment and monitor"
            echo "  scale   - Test scaling up/down"
            echo "  monitor - Monitor controller logs and events"
            echo "  cleanup - Delete cluster and cleanup"
            echo "  full    - Run complete setup (default)"
            echo ""
            echo "Environment variables:"
            echo "  GITHUB_PAT    - GitHub Personal Access Token (required)"
            echo "  GITHUB_ORG    - GitHub Organization (required if no GITHUB_REPO)"
            echo "  GITHUB_REPO   - GitHub Repository (required if no GITHUB_ORG)"
            echo "  CLUSTER_NAME  - Kind cluster name (default: arc-firecracker-test)"
            ;;
    esac
}

# Trap cleanup on exit
trap cleanup EXIT

main "$@" 