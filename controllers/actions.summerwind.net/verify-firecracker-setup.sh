#!/bin/bash

# Verify Firecracker Integration Setup
# This script checks if the ARC controller is properly configured for Firecracker

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed or not in PATH"
    exit 1
fi

# Check if kubeconfig is available  
if ! kubectl cluster-info &> /dev/null; then
    print_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
    exit 1
fi

print_info "Verifying Firecracker integration setup..."

# Find ARC controller deployment
ARC_NAMESPACE="${1:-actions-runner-system}"
print_info "Looking for ARC controller in namespace: $ARC_NAMESPACE"

DEPLOYMENT_NAME=$(kubectl get deployment -n "$ARC_NAMESPACE" -l app.kubernetes.io/name=actions-runner-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$DEPLOYMENT_NAME" ]; then
    print_error "Cannot find Actions Runner Controller deployment in namespace $ARC_NAMESPACE"
    exit 1
fi

print_info "Found ARC deployment: $DEPLOYMENT_NAME"

# Check if ENABLE_FIRECRACKER is set
ENABLE_FIRECRACKER=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$ARC_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ENABLE_FIRECRACKER")].value}' 2>/dev/null || echo "")

if [ "$ENABLE_FIRECRACKER" = "true" ]; then
    print_info "✅ ENABLE_FIRECRACKER is set to 'true'"
else
    print_error "❌ ENABLE_FIRECRACKER is not set or not 'true'. Current value: '$ENABLE_FIRECRACKER'"
    print_info "To fix this, run:"
    echo "kubectl patch deployment $DEPLOYMENT_NAME -n $ARC_NAMESPACE -p '{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"manager\",\"env\":[{\"name\":\"ENABLE_FIRECRACKER\",\"value\":\"true\"}]}]}}}}'"
    exit 1
fi

# Check FIRECRACKER_DAEMON_URL
DAEMON_URL=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$ARC_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FIRECRACKER_DAEMON_URL")].value}' 2>/dev/null || echo "")

if [ -n "$DAEMON_URL" ]; then
    print_info "✅ FIRECRACKER_DAEMON_URL is set to: $DAEMON_URL"
else
    print_warning "⚠️  FIRECRACKER_DAEMON_URL is not set. Will use default: http://192.168.21.32:30090"
fi

# Check if pod is running
POD_STATUS=$(kubectl get pods -n "$ARC_NAMESPACE" -l app.kubernetes.io/name=actions-runner-controller -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

if [ "$POD_STATUS" = "Running" ]; then
    print_info "✅ ARC controller pod is running"
else
    print_warning "⚠️  ARC controller pod status: $POD_STATUS"
fi

# Check controller logs for Firecracker initialization
print_info "Checking controller logs for Firecracker initialization..."

POD_NAME=$(kubectl get pods -n "$ARC_NAMESPACE" -l app.kubernetes.io/name=actions-runner-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$POD_NAME" ]; then
    # Look for Firecracker initialization message in recent logs
    if kubectl logs "$POD_NAME" -n "$ARC_NAMESPACE" --tail=100 | grep -q "Host-based Firecracker VM Manager initialized"; then
        print_info "✅ Firecracker VM Manager initialization found in logs"
    else
        print_warning "⚠️  Firecracker VM Manager initialization not found in recent logs"
        print_info "This might be normal if the controller was restarted recently. Check full logs:"
        echo "kubectl logs $POD_NAME -n $ARC_NAMESPACE | grep -i firecracker"
    fi
else
    print_warning "Cannot find ARC controller pod to check logs"
fi

# Check if DaemonSet nodes are accessible
print_info "Testing DaemonSet API connectivity..."

# Test the default URL
TEST_URL="http://192.168.21.32:30090/health"
if curl -s --connect-timeout 5 "$TEST_URL" >/dev/null 2>&1; then
    print_info "✅ DaemonSet API is accessible at: $TEST_URL"
else
    print_warning "⚠️  Cannot reach DaemonSet API at: $TEST_URL"
    print_info "Make sure the Firecracker DaemonSet is running on the target node"
fi

# Check for RunnerDeployment with Firecracker runtime
print_info "Checking for Firecracker-enabled RunnerDeployments..."

FIRECRACKER_RUNNERS=$(kubectl get runnerdeployments --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.template.spec.runtime.type}{"\n"}{end}' 2>/dev/null | grep firecracker || echo "")

if [ -n "$FIRECRACKER_RUNNERS" ]; then
    print_info "✅ Found Firecracker RunnerDeployments:"
    echo "$FIRECRACKER_RUNNERS"
else
    print_warning "⚠️  No Firecracker RunnerDeployments found"
    print_info "Create a RunnerDeployment with spec.template.spec.runtime.type: firecracker"
fi

print_info ""
print_info "Firecracker integration verification complete!"
print_info ""
print_info "If there are any issues:"
print_info "1. Ensure ENABLE_FIRECRACKER=true is set in the ARC deployment"
print_info "2. Make sure the DaemonSet is running on nodes where you want VMs"
print_info "3. Check that RunnerDeployments have the correct Firecracker runtime configuration"
print_info "4. Verify network connectivity between ARC controller and DaemonSet nodes" 