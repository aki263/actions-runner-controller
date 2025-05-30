package actionssummerwindnet

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/go-logr/logr"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	v1alpha1 "github.com/actions/actions-runner-controller/apis/actions.summerwind.net/v1alpha1"
)

const (
	// Annotations for Firecracker configuration
	FirecrackerRuntimeAnnotation = "runner.summerwind.dev/runtime"
	FirecrackerKernelAnnotation  = "runner.summerwind.dev/firecracker-kernel"
	FirecrackerRootfsAnnotation  = "runner.summerwind.dev/firecracker-rootfs"
	FirecrackerMemoryAnnotation  = "runner.summerwind.dev/firecracker-memory"
	FirecrackerVCPUsAnnotation   = "runner.summerwind.dev/firecracker-vcpus"
	FirecrackerNetworkAnnotation = "runner.summerwind.dev/firecracker-network"

	// Labels for tracking Firecracker VMs
	FirecrackerVMLabel = "runner.summerwind.dev/firecracker-vm"

	// Default values
	DefaultFirecrackerMemory = 2048
	DefaultFirecrackerVCPUs  = 2
)

type FirecrackerNetworkConfig struct {
	Interface  string `json:"interface,omitempty"`
	SubnetCIDR string `json:"subnetCIDR,omitempty"`
	Gateway    string `json:"gateway,omitempty"`
}

// RunnerDeploymentFirecrackerReconciler handles Firecracker VM integration for RunnerDeployments
type RunnerDeploymentFirecrackerReconciler struct {
	client.Client
	Log    logr.Logger
	Scheme *runtime.Scheme

	// Path to firecracker-complete.sh script
	FirecrackerScriptPath string

	// GitHub Client for token generation
	GitHubClient *MultiGitHubClient
}

// +kubebuilder:rbac:groups=actions.summerwind.dev,resources=runnerdeployments,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=core,resources=secrets,verbs=get;list;watch

func (r *RunnerDeploymentFirecrackerReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("runnerdeployment-firecracker", req.NamespacedName)

	var rd v1alpha1.RunnerDeployment
	if err := r.Get(ctx, req.NamespacedName, &rd); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Check if this RunnerDeployment is configured for Firecracker
	if !r.isFirecrackerRuntime(&rd) {
		// Not a Firecracker deployment, ignore
		return ctrl.Result{}, nil
	}

	log.Info("Processing Firecracker RunnerDeployment")

	// Handle deletion
	if !rd.ObjectMeta.DeletionTimestamp.IsZero() {
		return r.handleFirecrackerDeletion(ctx, &rd, log)
	}

	// Handle creation/update
	return r.handleFirecrackerRunnerDeployment(ctx, &rd, log)
}

func (r *RunnerDeploymentFirecrackerReconciler) isFirecrackerRuntime(rd *v1alpha1.RunnerDeployment) bool {
	runtime, exists := rd.Annotations[FirecrackerRuntimeAnnotation]
	return exists && runtime == "firecracker"
}

func (r *RunnerDeploymentFirecrackerReconciler) handleFirecrackerRunnerDeployment(ctx context.Context, rd *v1alpha1.RunnerDeployment, log logr.Logger) (ctrl.Result, error) {
	// Get current replica count
	replicas := 1
	if rd.Spec.Replicas != nil {
		replicas = *rd.Spec.Replicas
	}

	log.Info("Managing Firecracker VMs", "desired_replicas", replicas)

	// List existing VMs for this deployment
	existingVMs, err := r.listFirecrackerVMs(rd)
	if err != nil {
		log.Error(err, "Failed to list existing Firecracker VMs")
		return ctrl.Result{}, err
	}

	currentVMs := len(existingVMs)
	log.Info("Current VM state", "existing_vms", currentVMs, "desired_replicas", replicas)

	// Scale up if needed
	if currentVMs < replicas {
		needed := replicas - currentVMs
		log.Info("Scaling up Firecracker VMs", "needed", needed)

		for i := 0; i < needed; i++ {
			if err := r.createFirecrackerVM(ctx, rd, log); err != nil {
				log.Error(err, "Failed to create Firecracker VM")
				return ctrl.Result{RequeueAfter: time.Second * 30}, err
			}
		}
	}

	// Scale down if needed
	if currentVMs > replicas {
		excess := currentVMs - replicas
		log.Info("Scaling down Firecracker VMs", "excess", excess)

		for i := 0; i < excess && i < len(existingVMs); i++ {
			if err := r.deleteFirecrackerVM(existingVMs[i], log); err != nil {
				log.Error(err, "Failed to delete Firecracker VM", "vm", existingVMs[i])
			}
		}
	}

	return ctrl.Result{RequeueAfter: time.Minute * 2}, nil
}

func (r *RunnerDeploymentFirecrackerReconciler) createFirecrackerVM(ctx context.Context, rd *v1alpha1.RunnerDeployment, log logr.Logger) error {
	// Generate registration token
	registrationToken, err := r.generateRegistrationToken(ctx, rd, log)
	if err != nil {
		return fmt.Errorf("failed to generate registration token: %w", err)
	}

	// Get Firecracker configuration
	config, err := r.getFirecrackerConfig(rd)
	if err != nil {
		return fmt.Errorf("failed to get Firecracker config: %w", err)
	}

	// Generate unique VM name
	vmName := fmt.Sprintf("%s-%s-%d", rd.Name, rd.Namespace, time.Now().Unix())

	// Build repository URL
	repoURL, err := r.buildGitHubURL(rd)
	if err != nil {
		return fmt.Errorf("failed to build GitHub URL: %w", err)
	}

	// Create VM using firecracker-complete.sh
	cmd := exec.Command(r.FirecrackerScriptPath, "create-runner-vm",
		"--vm-id", vmName,
		"--registration-token", registrationToken,
		"--github-url", repoURL,
		"--memory", strconv.Itoa(config.Memory),
		"--cpus", strconv.Itoa(config.VCPUs),
		"--ephemeral-mode",
	)

	if config.KernelPath != "" {
		cmd.Args = append(cmd.Args, "--kernel", config.KernelPath)
	}

	if config.RootfsPath != "" {
		cmd.Args = append(cmd.Args, "--rootfs", config.RootfsPath)
	}

	// Set environment variables
	cmd.Env = os.Environ()
	if rd.Spec.Template.Spec.Labels != nil {
		labels := strings.Join(rd.Spec.Template.Spec.Labels, ",")
		cmd.Env = append(cmd.Env, "RUNNER_LABELS="+labels)
	}

	log.Info("Creating Firecracker VM", "vm_name", vmName, "command", strings.Join(cmd.Args, " "))

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to create Firecracker VM: %w, output: %s", err, string(output))
	}

	log.Info("Firecracker VM created successfully", "vm_name", vmName, "output", string(output))
	return nil
}

func (r *RunnerDeploymentFirecrackerReconciler) generateRegistrationToken(ctx context.Context, rd *v1alpha1.RunnerDeployment, log logr.Logger) (string, error) {
	// Get GitHub credentials from secret
	if rd.Spec.Template.Spec.GitHubAPICredentialsFrom == nil {
		return "", fmt.Errorf("github credentials not configured")
	}

	// Create a temporary Runner object to use existing GitHub client initialization
	tempRunner := &v1alpha1.Runner{
		ObjectMeta: metav1.ObjectMeta{
			Name:      rd.Name,
			Namespace: rd.Namespace,
		},
		Spec: v1alpha1.RunnerSpec{
			RunnerConfig: rd.Spec.Template.Spec.RunnerConfig,
		},
	}

	// Use existing GitHub client pattern like in firecracker_vm_controller.go
	ghc, err := r.GitHubClient.InitForRunner(ctx, tempRunner)
	if err != nil {
		return "", fmt.Errorf("failed to initialize GitHub client: %w", err)
	}

	// Generate registration token using existing method
	rt, err := ghc.GetRegistrationToken(ctx, rd.Spec.Template.Spec.Enterprise, rd.Spec.Template.Spec.Organization, rd.Spec.Template.Spec.Repository, fmt.Sprintf("%s-%d", rd.Name, time.Now().Unix()))
	if err != nil {
		return "", fmt.Errorf("failed to generate registration token: %w", err)
	}

	log.Info("Generated registration token successfully")
	return *rt.Token, nil
}

func (r *RunnerDeploymentFirecrackerReconciler) buildGitHubURL(rd *v1alpha1.RunnerDeployment) (string, error) {
	if rd.Spec.Template.Spec.Enterprise != "" {
		return fmt.Sprintf("https://github.com/enterprises/%s", rd.Spec.Template.Spec.Enterprise), nil
	} else if rd.Spec.Template.Spec.Organization != "" {
		return fmt.Sprintf("https://github.com/%s", rd.Spec.Template.Spec.Organization), nil
	} else if rd.Spec.Template.Spec.Repository != "" {
		return fmt.Sprintf("https://github.com/%s", rd.Spec.Template.Spec.Repository), nil
	}
	return "", fmt.Errorf("no GitHub URL scope defined")
}

type FirecrackerConfig struct {
	KernelPath string
	RootfsPath string
	Memory     int
	VCPUs      int
	Network    FirecrackerNetworkConfig
}

func (r *RunnerDeploymentFirecrackerReconciler) getFirecrackerConfig(rd *v1alpha1.RunnerDeployment) (*FirecrackerConfig, error) {
	config := &FirecrackerConfig{
		Memory: DefaultFirecrackerMemory,
		VCPUs:  DefaultFirecrackerVCPUs,
	}

	// Get kernel path
	if kernel, exists := rd.Annotations[FirecrackerKernelAnnotation]; exists {
		config.KernelPath = kernel
	}

	// Get rootfs path
	if rootfs, exists := rd.Annotations[FirecrackerRootfsAnnotation]; exists {
		config.RootfsPath = rootfs
	}

	// Get memory
	if memory, exists := rd.Annotations[FirecrackerMemoryAnnotation]; exists {
		if mem, err := strconv.Atoi(memory); err == nil {
			config.Memory = mem
		}
	}

	// Get vCPUs
	if vcpus, exists := rd.Annotations[FirecrackerVCPUsAnnotation]; exists {
		if cpu, err := strconv.Atoi(vcpus); err == nil {
			config.VCPUs = cpu
		}
	}

	// Get network config
	if network, exists := rd.Annotations[FirecrackerNetworkAnnotation]; exists {
		if err := json.Unmarshal([]byte(network), &config.Network); err != nil {
			// Use defaults if parsing fails
			config.Network = FirecrackerNetworkConfig{
				Interface:  "eth0",
				SubnetCIDR: "172.16.0.0/24",
				Gateway:    "172.16.0.1",
			}
		}
	}

	return config, nil
}

func (r *RunnerDeploymentFirecrackerReconciler) listFirecrackerVMs(rd *v1alpha1.RunnerDeployment) ([]string, error) {
	// Use firecracker-complete.sh to list VMs for this deployment
	cmd := exec.Command(r.FirecrackerScriptPath, "list-arc-vms", "--filter", fmt.Sprintf("deployment=%s", rd.Name))

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("failed to list VMs: %w, output: %s", err, string(output))
	}

	// Parse output to get VM names
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	var vms []string
	for _, line := range lines {
		if line != "" && !strings.HasPrefix(line, "#") {
			parts := strings.Fields(line)
			if len(parts) > 0 {
				vms = append(vms, parts[0])
			}
		}
	}

	return vms, nil
}

func (r *RunnerDeploymentFirecrackerReconciler) deleteFirecrackerVM(vmName string, log logr.Logger) error {
	cmd := exec.Command(r.FirecrackerScriptPath, "delete-arc-vm", vmName)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to delete VM %s: %w, output: %s", vmName, err, string(output))
	}

	log.Info("Firecracker VM deleted successfully", "vm_name", vmName)
	return nil
}

func (r *RunnerDeploymentFirecrackerReconciler) handleFirecrackerDeletion(ctx context.Context, rd *v1alpha1.RunnerDeployment, log logr.Logger) (ctrl.Result, error) {
	log.Info("Cleaning up Firecracker VMs for deleted RunnerDeployment")

	// List and delete all VMs for this deployment
	vms, err := r.listFirecrackerVMs(rd)
	if err != nil {
		log.Error(err, "Failed to list VMs for cleanup")
		return ctrl.Result{}, err
	}

	for _, vm := range vms {
		if err := r.deleteFirecrackerVM(vm, log); err != nil {
			log.Error(err, "Failed to delete VM during cleanup", "vm", vm)
		}
	}

	log.Info("Firecracker VM cleanup completed", "deleted_vms", len(vms))
	return ctrl.Result{}, nil
}

func (r *RunnerDeploymentFirecrackerReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&v1alpha1.RunnerDeployment{}).
		Complete(r)
}
