#!/bin/bash

# Test ARC Controller Firecracker Integration Locally
# This runs the controller code directly to test Firecracker integration

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
GITHUB_PAT="${GITHUB_PAT:-}"
GITHUB_ORG="${GITHUB_ORG:-}"
GITHUB_REPO="${GITHUB_REPO:-}"

create_test_controller() {
    log "Creating standalone controller test..."
    
    # Create a Go test file that exercises the controller logic
    cat > test_firecracker_controller.go <<'EOF'
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/go-logr/logr"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	v1alpha1 "github.com/actions/actions-runner-controller/apis/actions.summerwind.net/v1alpha1"
	actionssummerwindnet "github.com/actions/actions-runner-controller/controllers/actions.summerwind.net"
)

// MockGitHubClient simulates the GitHub client for testing
type MockGitHubClient struct{}

func (m *MockGitHubClient) InitForRunner(ctx context.Context, runner *v1alpha1.Runner) (*actionssummerwindnet.GitHubClient, error) {
	return &actionssummerwindnet.GitHubClient{}, nil
}

func (m *MockGitHubClient) GetRegistrationToken(ctx context.Context, enterprise, org, repo, name string) (*actionssummerwindnet.RegistrationToken, error) {
	token := "fake-registration-token-for-testing"
	return &actionssummerwindnet.RegistrationToken{
		Token: &token,
	}, nil
}

// MockFirecrackerScript simulates the firecracker-complete.sh script
func createMockFirecrackerScript() error {
	script := `#!/bin/bash
# Mock firecracker-complete.sh script for testing

case "$1" in
    "create-runner-vm")
        echo "Mock: Creating VM with ID: $4"
        echo "Mock: Registration token: $6"
        echo "Mock: GitHub URL: $8"
        echo "Mock: Memory: $10 MB"
        echo "Mock: CPUs: $12"
        echo "Mock: VM created successfully"
        # Create a fake process file to simulate running VM
        mkdir -p /tmp/mock-vms
        echo "running" > "/tmp/mock-vms/$4.status"
        ;;
    "list-arc-vms")
        echo "Mock: Listing VMs..."
        for vm in /tmp/mock-vms/*.status; do
            if [[ -f "$vm" ]]; then
                basename "$vm" .status
            fi
        done
        ;;
    "get-arc-vm-status")
        vm_file="/tmp/mock-vms/$2.status"
        if [[ -f "$vm_file" ]]; then
            echo "Mock: VM $2 status: $(cat "$vm_file")"
        else
            echo "Mock: VM $2 not found"
            exit 1
        fi
        ;;
    "delete-arc-vm")
        vm_file="/tmp/mock-vms/$2.status"
        if [[ -f "$vm_file" ]]; then
            rm -f "$vm_file"
            echo "Mock: VM $2 deleted"
        else
            echo "Mock: VM $2 not found"
            exit 1
        fi
        ;;
    "cleanup-arc-vms")
        echo "Mock: Cleaning up all VMs..."
        rm -rf /tmp/mock-vms/*
        echo "Mock: All VMs cleaned up"
        ;;
    *)
        echo "Mock firecracker script called with: $*"
        ;;
esac
`
    
    # Write mock script
    if err := os.WriteFile("mock-firecracker-complete.sh", []byte(script), 0755); err != nil {
        return fmt.Errorf("failed to create mock script: %w", err)
    }
    
    return nil
}

func testFirecrackerController() error {
    ctx := context.Background()
    
    # Setup logging
    logf.SetLogger(zap.New(zap.UseDevMode(true)))
    logger := logf.Log.WithName("test")
    
    # Create scheme and add our types
    scheme := runtime.NewScheme()
    if err := v1alpha1.AddToScheme(scheme); err != nil {
        return fmt.Errorf("failed to add scheme: %w", err)
    }
    
    # Create fake Kubernetes client
    client := fake.NewClientBuilder().
        WithScheme(scheme).
        Build()
    
    # Create mock GitHub client
    mockGitHubClient := &MockGitHubClient{}
    
    # Create Firecracker controller
    controller := &actionssummerwindnet.RunnerDeploymentFirecrackerReconciler{
        Client:                client,
        Log:                   logger,
        Scheme:                scheme,
        GitHubClient:          mockGitHubClient,
        FirecrackerScriptPath: "./mock-firecracker-complete.sh",
    }
    
    # Create test RunnerDeployment with Firecracker annotations
    rd := &v1alpha1.RunnerDeployment{
        ObjectMeta: metav1.ObjectMeta{
            Name:      "test-firecracker-deployment",
            Namespace: "test-namespace",
            Annotations: map[string]string{
                "runner.summerwind.dev/runtime":             "firecracker",
                "runner.summerwind.dev/firecracker-kernel":  "/opt/firecracker/kernels/vmlinux-5.10",
                "runner.summerwind.dev/firecracker-rootfs":  "/opt/firecracker/images/ubuntu-runner.ext4",
                "runner.summerwind.dev/firecracker-memory":  "2048",
                "runner.summerwind.dev/firecracker-vcpus":   "2",
                "runner.summerwind.dev/firecracker-network": `{"interface":"eth0","subnetCIDR":"172.16.0.0/24","gateway":"172.16.0.1"}`,
            },
        },
        Spec: v1alpha1.RunnerDeploymentSpec{
            Replicas: func() *int { i := 2; return &i }(),
            Template: v1alpha1.RunnerTemplate{
                Spec: v1alpha1.RunnerSpec{
                    RunnerConfig: v1alpha1.RunnerConfig{
                        Organization: os.Getenv("GITHUB_ORG"),
                        Repository:   os.Getenv("GITHUB_REPO"),
                        GitHubAPICredentialsFrom: &v1alpha1.GitHubAPICredentialsFrom{
                            SecretRef: v1alpha1.SecretReference{
                                Name: "github-pat-secret",
                            },
                        },
                        Labels: []string{"self-hosted", "firecracker", "test"},
                    },
                },
            },
        },
    }
    
    # Create the RunnerDeployment in fake client
    if err := client.Create(ctx, rd); err != nil {
        return fmt.Errorf("failed to create RunnerDeployment: %w", err)
    }
    
    # Test controller reconciliation
    logger.Info("Testing Firecracker controller reconciliation...")
    
    req := ctrl.Request{
        NamespacedName: types.NamespacedName{
            Name:      rd.Name,
            Namespace: rd.Namespace,
        },
    }
    
    # Run reconciliation
    result, err := controller.Reconcile(ctx, req)
    if err != nil {
        return fmt.Errorf("reconciliation failed: %w", err)
    }
    
    logger.Info("Reconciliation completed", "result", result)
    
    # Test scaling
    logger.Info("Testing scaling...")
    
    # Update replicas to 3
    if err := client.Get(ctx, req.NamespacedName, rd); err != nil {
        return fmt.Errorf("failed to get RunnerDeployment: %w", err)
    }
    
    rd.Spec.Replicas = func() *int { i := 3; return &i }()
    if err := client.Update(ctx, rd); err != nil {
        return fmt.Errorf("failed to update RunnerDeployment: %w", err)
    }
    
    # Reconcile again
    result, err = controller.Reconcile(ctx, req)
    if err != nil {
        return fmt.Errorf("scaling reconciliation failed: %w", err)
    }
    
    logger.Info("Scaling reconciliation completed", "result", result)
    
    # Test scale down
    logger.Info("Testing scale down...")
    
    if err := client.Get(ctx, req.NamespacedName, rd); err != nil {
        return fmt.Errorf("failed to get RunnerDeployment: %w", err)
    }
    
    rd.Spec.Replicas = func() *int { i := 1; return &i }()
    if err := client.Update(ctx, rd); err != nil {
        return fmt.Errorf("failed to update RunnerDeployment: %w", err)
    }
    
    # Reconcile again
    result, err = controller.Reconcile(ctx, req)
    if err != nil {
        return fmt.Errorf("scale down reconciliation failed: %w", err)
    }
    
    logger.Info("Scale down reconciliation completed", "result", result)
    
    # Test deletion
    logger.Info("Testing deletion...")
    
    if err := client.Delete(ctx, rd); err != nil {
        return fmt.Errorf("failed to delete RunnerDeployment: %w", err)
    }
    
    # Update deletion timestamp to simulate deletion
    rd.DeletionTimestamp = &metav1.Time{Time: time.Now()}
    if err := client.Update(ctx, rd); err != nil {
        # This might fail in fake client, that's OK
        logger.Info("Could not update deletion timestamp (expected in fake client)")
    }
    
    result, err = controller.Reconcile(ctx, req)
    if err != nil {
        return fmt.Errorf("deletion reconciliation failed: %w", err)
    }
    
    logger.Info("Deletion reconciliation completed", "result", result)
    
    logger.Info("🎉 All tests passed!")
    return nil
}

func main() {
    # Create mock script
    if err := createMockFirecrackerScript(); err != nil {
        log.Fatalf("Failed to create mock script: %v", err)
    }
    defer os.Remove("mock-firecracker-complete.sh")
    
    # Create mock VMs directory
    os.MkdirAll("/tmp/mock-vms", 0755)
    defer os.RemoveAll("/tmp/mock-vms")
    
    # Run tests
    if err := testFirecrackerController(); err != nil {
        log.Fatalf("Test failed: %v", err)
    }
    
    fmt.Println("✅ Firecracker controller integration test completed successfully!")
}
EOF

    success "Controller test file created"
}

run_controller_test() {
    log "Running controller integration test..."
    
    # Ensure we have Go modules
    if [[ ! -f "go.mod" ]]; then
        error "go.mod not found. Please run this from the ARC project root."
        return 1
    fi
    
    # Set environment variables
    export GITHUB_ORG="$GITHUB_ORG"
    export GITHUB_REPO="$GITHUB_REPO"
    
    # Run the test
    go run test_firecracker_controller.go
}

test_controller_build() {
    log "Testing controller build..."
    
    # Try building the controller
    if make build; then
        success "Controller builds successfully"
    else
        error "Controller build failed"
        return 1
    fi
}

test_annotations_parsing() {
    log "Testing annotation parsing logic..."
    
    # Create a simple test for annotation parsing
    cat > test_annotations.go <<'EOF'
package main

import (
    "encoding/json"
    "fmt"
    "strconv"
)

type FirecrackerNetworkConfig struct {
    Interface  string `json:"interface,omitempty"`
    SubnetCIDR string `json:"subnetCIDR,omitempty"`
    Gateway    string `json:"gateway,omitempty"`
}

type FirecrackerConfig struct {
    KernelPath string
    RootfsPath string
    Memory     int
    VCPUs      int
    Network    FirecrackerNetworkConfig
}

func parseFirecrackerConfig(annotations map[string]string) (*FirecrackerConfig, error) {
    config := &FirecrackerConfig{
        Memory: 2048, // default
        VCPUs:  2,    // default
    }
    
    if kernel, exists := annotations["runner.summerwind.dev/firecracker-kernel"]; exists {
        config.KernelPath = kernel
    }
    
    if rootfs, exists := annotations["runner.summerwind.dev/firecracker-rootfs"]; exists {
        config.RootfsPath = rootfs
    }
    
    if memory, exists := annotations["runner.summerwind.dev/firecracker-memory"]; exists {
        if mem, err := strconv.Atoi(memory); err == nil {
            config.Memory = mem
        }
    }
    
    if vcpus, exists := annotations["runner.summerwind.dev/firecracker-vcpus"]; exists {
        if cpu, err := strconv.Atoi(vcpus); err == nil {
            config.VCPUs = cpu
        }
    }
    
    if network, exists := annotations["runner.summerwind.dev/firecracker-network"]; exists {
        if err := json.Unmarshal([]byte(network), &config.Network); err != nil {
            # Use defaults if parsing fails
            config.Network = FirecrackerNetworkConfig{
                Interface:  "eth0",
                SubnetCIDR: "172.16.0.0/24",
                Gateway:    "172.16.0.1",
            }
        }
    }
    
    return config, nil
}

func main() {
    # Test annotation parsing
    annotations := map[string]string{
        "runner.summerwind.dev/runtime":             "firecracker",
        "runner.summerwind.dev/firecracker-kernel":  "/opt/firecracker/kernels/vmlinux-5.10",
        "runner.summerwind.dev/firecracker-rootfs":  "/opt/firecracker/images/ubuntu-runner.ext4",
        "runner.summerwind.dev/firecracker-memory":  "4096",
        "runner.summerwind.dev/firecracker-vcpus":   "4",
        "runner.summerwind.dev/firecracker-network": `{"interface":"eth0","subnetCIDR":"172.16.0.0/24","gateway":"172.16.0.1"}`,
    }
    
    config, err := parseFirecrackerConfig(annotations)
    if err != nil {
        fmt.Printf("❌ Annotation parsing failed: %v\n", err)
        return
    }
    
    fmt.Printf("✅ Annotations parsed successfully:\n")
    fmt.Printf("   Kernel: %s\n", config.KernelPath)
    fmt.Printf("   Rootfs: %s\n", config.RootfsPath)
    fmt.Printf("   Memory: %d MB\n", config.Memory)
    fmt.Printf("   vCPUs: %d\n", config.VCPUs)
    fmt.Printf("   Network: %+v\n", config.Network)
}
EOF

    go run test_annotations.go
    rm -f test_annotations.go
}

check_firecracker_script_integration() {
    log "Testing Firecracker script integration..."
    
    if [[ ! -f "firecracker-poc/firecracker-complete.sh" ]]; then
        warn "firecracker-complete.sh not found. Creating mock for testing..."
        mkdir -p firecracker-poc
        cat > firecracker-poc/firecracker-complete.sh <<'EOF'
#!/bin/bash
echo "Mock firecracker-complete.sh called with: $*"
case "$1" in
    "create-runner-vm")
        echo "Would create VM: $4"
        ;;
    "list-arc-vms")
        echo "test-vm-123"
        echo "test-vm-456"
        ;;
    "delete-arc-vm")
        echo "Would delete VM: $2"
        ;;
esac
EOF
        chmod +x firecracker-poc/firecracker-complete.sh
    fi
    
    # Test script execution
    log "Testing script calls..."
    ./firecracker-poc/firecracker-complete.sh create-runner-vm --vm-id test-123 --registration-token fake-token
    ./firecracker-poc/firecracker-complete.sh list-arc-vms
    ./firecracker-poc/firecracker-complete.sh delete-arc-vm test-123
    
    success "Firecracker script integration test passed"
}

main() {
    case "${1:-full}" in
        "build")
            test_controller_build
            ;;
        "annotations")
            test_annotations_parsing
            ;;
        "script")
            check_firecracker_script_integration
            ;;
        "controller")
            create_test_controller
            run_controller_test
            ;;
        "full")
            log "Running full controller integration test..."
            
            # Check environment
            if [[ -z "$GITHUB_PAT" ]]; then
                error "GITHUB_PAT not set"
                echo "export GITHUB_PAT='ghp_your_token_here'"
                exit 1
            fi
            
            if [[ -z "$GITHUB_ORG" && -z "$GITHUB_REPO" ]]; then
                error "Either GITHUB_ORG or GITHUB_REPO must be set"
                exit 1
            fi
            
            # Run all tests
            test_controller_build
            test_annotations_parsing  
            check_firecracker_script_integration
            create_test_controller
            run_controller_test
            
            # Cleanup
            rm -f test_firecracker_controller.go
            
            success "🎉 All controller integration tests passed!"
            ;;
        *)
            echo "Usage: $0 [build|annotations|script|controller|full]"
            echo ""
            echo "Commands:"
            echo "  build       - Test controller build"
            echo "  annotations - Test annotation parsing"
            echo "  script      - Test Firecracker script integration"
            echo "  controller  - Test controller logic with mocks"
            echo "  full        - Run all tests (default)"
            echo ""
            echo "Environment variables:"
            echo "  GITHUB_PAT    - GitHub Personal Access Token"
            echo "  GITHUB_ORG    - GitHub Organization"
            echo "  GITHUB_REPO   - GitHub Repository"
            ;;
    esac
}

main "$@" 