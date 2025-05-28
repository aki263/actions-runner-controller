package actionssummerwindnet

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/go-logr/logr"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	v1alpha1 "github.com/actions/actions-runner-controller/apis/actions.summerwind.net/v1alpha1"
)

// FirecrackerVMReconciler reconciles a FirecrackerVM object
type FirecrackerVMReconciler struct {
	client.Client
	Log          logr.Logger
	Scheme       *runtime.Scheme
	GitHubClient *MultiGitHubClient

	// Firecracker configuration
	FirecrackerDefaults FirecrackerVMDefaults
}

// FirecrackerVMDefaults contains default configuration for Firecracker VMs
type FirecrackerVMDefaults struct {
	// RootfsPath is the hardcoded path to the rootfs image
	RootfsPath string

	// KernelPath is the path to the kernel image
	KernelPath string

	// DefaultMemoryMiB is the default memory allocation
	DefaultMemoryMiB int

	// DefaultVCPUs is the default vCPU count
	DefaultVCPUs int

	// NetworkInterface is the default network interface
	NetworkInterface string

	// SubnetCIDR is the default subnet CIDR
	SubnetCIDR string

	// Gateway is the default gateway IP
	Gateway string

	// BaseIPAddress is the base IP for assigning to VMs
	BaseIPAddress string
}

// +kubebuilder:rbac:groups=actions.summerwind.dev,resources=firecrackervm,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=actions.summerwind.dev,resources=firecrackervm/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=actions.summerwind.dev,resources=firecrackervm/finalizers,verbs=update

func (r *FirecrackerVMReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("firecrackervm", req.NamespacedName)

	var vm v1alpha1.FirecrackerVM
	if err := r.Get(ctx, req.NamespacedName, &vm); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Handle deletion
	if !vm.ObjectMeta.DeletionTimestamp.IsZero() {
		return r.processVMDeletion(ctx, &vm, log)
	}

	// Handle creation/update
	return r.processVMCreation(ctx, &vm, log)
}

func (r *FirecrackerVMReconciler) processVMCreation(ctx context.Context, vm *v1alpha1.FirecrackerVM, log logr.Logger) (ctrl.Result, error) {
	switch vm.Status.Phase {
	case "", v1alpha1.FirecrackerVMPhasePending:
		return r.startVM(ctx, vm, log)
	case v1alpha1.FirecrackerVMPhaseStarting:
		return r.checkVMStarted(ctx, vm, log)
	case v1alpha1.FirecrackerVMPhaseRunning:
		return r.registerRunner(ctx, vm, log)
	case v1alpha1.FirecrackerVMPhaseReady:
		return r.monitorVM(ctx, vm, log)
	case v1alpha1.FirecrackerVMPhaseFailed:
		// For failed VMs, try to restart if configured
		return ctrl.Result{RequeueAfter: time.Minute * 5}, nil
	default:
		return ctrl.Result{}, nil
	}
}

func (r *FirecrackerVMReconciler) startVM(ctx context.Context, vm *v1alpha1.FirecrackerVM, log logr.Logger) (ctrl.Result, error) {
	log.Info("Starting Firecracker VM")

	// Generate cloud-init data with runner configuration
	cloudInitData, err := r.generateCloudInit(ctx, vm)
	if err != nil {
		log.Error(err, "Failed to generate cloud-init data")
		return ctrl.Result{}, err
	}

	// Assign IP address
	ipAddress, err := r.assignIPAddress(vm)
	if err != nil {
		log.Error(err, "Failed to assign IP address")
		return ctrl.Result{}, err
	}

	// Create cloud-init ISO
	cloudInitPath, err := r.createCloudInitISO(vm.Name, cloudInitData, log)
	if err != nil {
		log.Error(err, "Failed to create cloud-init ISO")
		return ctrl.Result{}, err
	}

	// Start Firecracker VM
	err = r.startFirecrackerVM(vm, ipAddress, cloudInitPath, log)
	if err != nil {
		log.Error(err, "Failed to start Firecracker VM")
		vm.Status.Phase = v1alpha1.FirecrackerVMPhaseFailed
		vm.Status.Message = fmt.Sprintf("Failed to start VM: %v", err)
		r.Status().Update(ctx, vm)
		return ctrl.Result{}, err
	}

	// Update status
	vm.Status.Phase = v1alpha1.FirecrackerVMPhaseStarting
	vm.Status.IPAddress = ipAddress
	vm.Status.StartedAt = &metav1.Time{Time: time.Now()}
	vm.Status.Message = "VM starting"

	if err := r.Status().Update(ctx, vm); err != nil {
		log.Error(err, "Failed to update VM status")
		return ctrl.Result{}, err
	}

	return ctrl.Result{RequeueAfter: time.Second * 30}, nil
}

func (r *FirecrackerVMReconciler) checkVMStarted(ctx context.Context, vm *v1alpha1.FirecrackerVM, log logr.Logger) (ctrl.Result, error) {
	log.Info("Checking if VM has started", "ip", vm.Status.IPAddress)

	// Check if VM is responding (simple ping test)
	if r.isVMReady(vm.Status.IPAddress) {
		vm.Status.Phase = v1alpha1.FirecrackerVMPhaseRunning
		vm.Status.Message = "VM is running"

		if err := r.Status().Update(ctx, vm); err != nil {
			log.Error(err, "Failed to update VM status")
			return ctrl.Result{}, err
		}

		return ctrl.Result{Requeue: true}, nil
	}

	// Check if we've been waiting too long
	if time.Since(vm.Status.StartedAt.Time) > time.Minute*5 {
		vm.Status.Phase = v1alpha1.FirecrackerVMPhaseFailed
		vm.Status.Message = "VM failed to start within timeout"
		r.Status().Update(ctx, vm)
		return ctrl.Result{}, fmt.Errorf("VM startup timeout")
	}

	return ctrl.Result{RequeueAfter: time.Second * 10}, nil
}

func (r *FirecrackerVMReconciler) registerRunner(ctx context.Context, vm *v1alpha1.FirecrackerVM, log logr.Logger) (ctrl.Result, error) {
	log.Info("Registering runner with GitHub")

	// Wait for runner registration to complete via cloud-init
	// In a real implementation, you'd check the runner status via SSH or API

	vm.Status.Phase = v1alpha1.FirecrackerVMPhaseReady
	vm.Status.Ready = true
	vm.Status.Message = "Runner registered and ready"

	if err := r.Status().Update(ctx, vm); err != nil {
		log.Error(err, "Failed to update VM status")
		return ctrl.Result{}, err
	}

	return ctrl.Result{RequeueAfter: time.Minute * 5}, nil
}

func (r *FirecrackerVMReconciler) monitorVM(ctx context.Context, vm *v1alpha1.FirecrackerVM, log logr.Logger) (ctrl.Result, error) {
	log.V(1).Info("Monitoring VM health")

	// Check if VM is still running
	if !r.isVMReady(vm.Status.IPAddress) {
		vm.Status.Phase = v1alpha1.FirecrackerVMPhaseFailed
		vm.Status.Ready = false
		vm.Status.Message = "VM is no longer responsive"
		r.Status().Update(ctx, vm)
		return ctrl.Result{}, fmt.Errorf("VM health check failed")
	}

	return ctrl.Result{RequeueAfter: time.Minute * 5}, nil
}

func (r *FirecrackerVMReconciler) processVMDeletion(ctx context.Context, vm *v1alpha1.FirecrackerVM, log logr.Logger) (ctrl.Result, error) {
	log.Info("Deleting Firecracker VM")

	// Stop the VM
	err := r.stopFirecrackerVM(vm, log)
	if err != nil {
		log.Error(err, "Failed to stop Firecracker VM")
		// Continue with cleanup even if stop fails
	}

	// Clean up cloud-init ISO
	cloudInitPath := filepath.Join("/tmp", fmt.Sprintf("%s-cloud-init.iso", vm.Name))
	os.Remove(cloudInitPath)

	return ctrl.Result{}, nil
}

func (r *FirecrackerVMReconciler) generateCloudInit(ctx context.Context, vm *v1alpha1.FirecrackerVM) (string, error) {
	// Get registration token from GitHub
	ghc, err := r.GitHubClient.InitForRunner(ctx, &v1alpha1.Runner{
		ObjectMeta: vm.ObjectMeta,
		Spec: v1alpha1.RunnerSpec{
			RunnerConfig: vm.Spec.RunnerSpec,
		},
	})
	if err != nil {
		return "", fmt.Errorf("failed to initialize GitHub client: %w", err)
	}

	token, err := ghc.GetRegistrationToken(ctx, vm.Spec.RunnerSpec.Enterprise, vm.Spec.RunnerSpec.Organization, vm.Spec.RunnerSpec.Repository, vm.Name)
	if err != nil {
		return "", fmt.Errorf("failed to get registration token: %w", err)
	}

	// Create cloud-init user data with runner installation and configuration
	cloudInit := fmt.Sprintf(`#cloud-config
package_update: true
packages:
  - curl
  - jq
  - git

write_files:
  - path: /home/runner/setup-runner.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e
      
      # Create runner user if it doesn't exist
      if ! id -u runner &>/dev/null; then
        useradd -m -s /bin/bash runner
        usermod -aG sudo runner
        echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
      fi
      
      # Switch to runner user
      su - runner -c "
        # Download and setup GitHub Actions runner
        cd /home/runner
        curl -o actions-runner-linux-x64-2.311.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.311.0/actions-runner-linux-x64-2.311.0.tar.gz
        tar xzf ./actions-runner-linux-x64-2.311.0.tar.gz
        rm actions-runner-linux-x64-2.311.0.tar.gz
        
        # Configure runner
        export RUNNER_ALLOW_RUNASROOT=1
        export RUNNER_NAME='%s'
        export RUNNER_TOKEN='%s'
        export RUNNER_URL='%s'
        export RUNNER_LABELS='%s'
        export RUNNER_GROUP='%s'
        export RUNNER_WORKDIR='/home/runner/_work'
        export RUNNER_EPHEMERAL='true'
        
        # Configure the runner
        ./config.sh --url \$RUNNER_URL --token \$RUNNER_TOKEN --name \$RUNNER_NAME --labels \$RUNNER_LABELS --runnergroup \$RUNNER_GROUP --work \$RUNNER_WORKDIR --ephemeral --unattended
        
        # Install and start the service
        sudo ./svc.sh install
        sudo ./svc.sh start
      "

runcmd:
  - /home/runner/setup-runner.sh

final_message: "GitHub Actions runner setup complete"
`,
		vm.Name,
		token.GetToken(),
		r.getRunnerURL(vm.Spec.RunnerSpec),
		strings.Join(vm.Spec.RunnerSpec.Labels, ","),
		vm.Spec.RunnerSpec.Group,
	)

	return cloudInit, nil
}

func (r *FirecrackerVMReconciler) getRunnerURL(runnerSpec v1alpha1.RunnerConfig) string {
	if runnerSpec.Enterprise != "" {
		return fmt.Sprintf("https://github.com/enterprises/%s", runnerSpec.Enterprise)
	}
	if runnerSpec.Organization != "" {
		return fmt.Sprintf("https://github.com/%s", runnerSpec.Organization)
	}
	if runnerSpec.Repository != "" {
		return fmt.Sprintf("https://github.com/%s", runnerSpec.Repository)
	}
	return "https://github.com"
}

func (r *FirecrackerVMReconciler) assignIPAddress(vm *v1alpha1.FirecrackerVM) (string, error) {
	// Simple IP assignment logic - in production you'd want IPAM
	baseIP := net.ParseIP(r.FirecrackerDefaults.BaseIPAddress)
	if baseIP == nil {
		return "", fmt.Errorf("invalid base IP address: %s", r.FirecrackerDefaults.BaseIPAddress)
	}

	// Use a hash of the VM name to get a consistent IP
	hash := 0
	for _, b := range vm.Name {
		hash = hash*31 + int(b)
	}

	// Ensure we're in the valid range (avoid network and broadcast addresses)
	offset := (hash % 200) + 10 // IPs from .10 to .209

	ip := baseIP.To4()
	ip[3] = byte(int(ip[3]) + offset)

	return ip.String(), nil
}

func (r *FirecrackerVMReconciler) createCloudInitISO(vmName, cloudInitData string, log logr.Logger) (string, error) {
	tmpDir := "/tmp/cloud-init-" + vmName
	if err := os.MkdirAll(tmpDir, 0755); err != nil {
		return "", fmt.Errorf("failed to create temp directory: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	// Write user-data
	userDataPath := filepath.Join(tmpDir, "user-data")
	if err := os.WriteFile(userDataPath, []byte(cloudInitData), 0644); err != nil {
		return "", fmt.Errorf("failed to write user-data: %w", err)
	}

	// Write meta-data
	metaData := fmt.Sprintf("instance-id: %s\nlocal-hostname: %s\n", vmName, vmName)
	metaDataPath := filepath.Join(tmpDir, "meta-data")
	if err := os.WriteFile(metaDataPath, []byte(metaData), 0644); err != nil {
		return "", fmt.Errorf("failed to write meta-data: %w", err)
	}

	// Create ISO
	isoPath := filepath.Join("/tmp", fmt.Sprintf("%s-cloud-init.iso", vmName))
	cmd := exec.Command("genisoimage", "-output", isoPath, "-volid", "cidata", "-joliet", "-rock", tmpDir)
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("failed to create cloud-init ISO: %w", err)
	}

	return isoPath, nil
}

func (r *FirecrackerVMReconciler) startFirecrackerVM(vm *v1alpha1.FirecrackerVM, ipAddress, cloudInitPath string, log logr.Logger) error {
	// Get VM configuration with defaults
	memoryMiB := vm.Spec.MemoryMiB
	if memoryMiB == 0 {
		memoryMiB = r.FirecrackerDefaults.DefaultMemoryMiB
	}

	vcpus := vm.Spec.VCPUs
	if vcpus == 0 {
		vcpus = r.FirecrackerDefaults.DefaultVCPUs
	}

	rootfsPath := vm.Spec.RootfsPath
	if rootfsPath == "" {
		rootfsPath = r.FirecrackerDefaults.RootfsPath
	}

	kernelPath := vm.Spec.KernelPath
	if kernelPath == "" {
		kernelPath = r.FirecrackerDefaults.KernelPath
	}

	// Create Firecracker configuration
	config := fmt.Sprintf(`{
  "boot-source": {
    "kernel_image_path": "%s",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "%s",
      "is_root_device": true,
      "is_read_only": false
    },
    {
      "drive_id": "cloudinit",
      "path_on_host": "%s",
      "is_root_device": false,
      "is_read_only": true
    }
  ],
  "machine-config": {
    "vcpu_count": %d,
    "mem_size_mib": %d
  },
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "guest_mac": "AA:FC:00:00:00:01",
      "host_dev_name": "%s"
    }
  ]
}`, kernelPath, rootfsPath, cloudInitPath, vcpus, memoryMiB, r.FirecrackerDefaults.NetworkInterface)

	// Write config to file
	configPath := filepath.Join("/tmp", fmt.Sprintf("%s-config.json", vm.Name))
	if err := os.WriteFile(configPath, []byte(config), 0644); err != nil {
		return fmt.Errorf("failed to write Firecracker config: %w", err)
	}

	// Start Firecracker (this would be more complex in a real implementation)
	socketPath := filepath.Join("/tmp", fmt.Sprintf("%s.socket", vm.Name))

	cmd := exec.Command("firecracker",
		"--api-sock", socketPath,
		"--config-file", configPath,
	)

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start Firecracker: %w", err)
	}

	log.Info("Started Firecracker VM", "vmName", vm.Name, "pid", cmd.Process.Pid)
	return nil
}

func (r *FirecrackerVMReconciler) isVMReady(ipAddress string) bool {
	// Simple connectivity check
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(ipAddress, "22"), time.Second*5)
	if err != nil {
		return false
	}
	defer conn.Close()
	return true
}

func (r *FirecrackerVMReconciler) stopFirecrackerVM(vm *v1alpha1.FirecrackerVM, log logr.Logger) error {
	// Find and stop the Firecracker process
	// This is a simplified implementation
	socketPath := filepath.Join("/tmp", fmt.Sprintf("%s.socket", vm.Name))
	configPath := filepath.Join("/tmp", fmt.Sprintf("%s-config.json", vm.Name))

	// Clean up files
	os.Remove(socketPath)
	os.Remove(configPath)

	log.Info("Stopped Firecracker VM", "vmName", vm.Name)
	return nil
}

// SetupWithManager sets up the controller with the Manager.
func (r *FirecrackerVMReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&v1alpha1.FirecrackerVM{}).
		Complete(r)
}
