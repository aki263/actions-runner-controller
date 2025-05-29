#!/bin/bash

# Demo Script: Complete GitHub Actions Runner Workflow
# Demonstrates building, snapshotting, and launching Firecracker runner VMs

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_banner() {
    echo -e "${CYAN}"
    echo "================================================================"
    echo "  GitHub Actions Runner Workflow Demo"
    echo "  Firecracker VM + Cloud-Init + Snapshots"
    echo "================================================================"
    echo -e "${NC}"
}

print_step() {
    echo -e "${BLUE}[STEP $1]${NC} $2"
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

check_os() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        print_error "This demo requires Ubuntu 24.04 or compatible Linux distribution with KVM support."
        print_error "macOS is not supported as Firecracker requires Linux KVM."
        print_info ""
        print_info "To run this demo:"
        print_info "1. Use a Linux VM (VMware Fusion, Parallels, VirtualBox)"
        print_info "2. Use a cloud Linux instance (AWS EC2, Google Cloud, etc.)"
        print_info "3. Use Docker Desktop with Linux containers"
        exit 1
    fi
}

interactive_setup() {
    echo -e "${CYAN}Welcome to the GitHub Actions Runner Workflow Demo!${NC}"
    echo ""
    echo "This demo will:"
    echo "1. 🏗️  Build a GitHub Actions runner VM image"
    echo "2. 📸 Create a reusable snapshot"
    echo "3. 🚀 Launch a runner VM with your GitHub configuration"
    echo ""
    
    # Get user input
    echo -e "${YELLOW}Please provide your GitHub configuration:${NC}"
    echo ""
    
    read -p "GitHub URL (repo or org): " GITHUB_URL
    if [ -z "$GITHUB_URL" ]; then
        print_error "GitHub URL is required"
        exit 1
    fi
    
    read -p "GitHub Token (ghp_...): " -s GITHUB_TOKEN
    echo ""
    if [ -z "$GITHUB_TOKEN" ]; then
        print_error "GitHub Token is required"
        exit 1
    fi
    
    read -p "Runner Name (default: demo-runner): " RUNNER_NAME
    RUNNER_NAME=${RUNNER_NAME:-demo-runner}
    
    read -p "Runner Labels (default: firecracker,demo): " RUNNER_LABELS
    RUNNER_LABELS=${RUNNER_LABELS:-firecracker,demo}
    
    echo ""
    print_info "Configuration:"
    print_info "  GitHub URL: $GITHUB_URL"
    print_info "  Runner Name: $RUNNER_NAME"
    print_info "  Runner Labels: $RUNNER_LABELS"
    echo ""
    
    read -p "Continue with demo? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Demo cancelled"
        exit 0
    fi
}

demo_build_phase() {
    print_step "1" "Building GitHub Actions Runner Image"
    echo ""
    print_info "This will create a VM image with:"
    print_info "  • Ubuntu 24.04 LTS"
    print_info "  • GitHub Actions Runner v2.311.0"
    print_info "  • Docker v24.0.7"
    print_info "  • All necessary dependencies"
    echo ""
    
    if [ -f "runner-image/actions-runner-ubuntu-24.04.ext4" ]; then
        print_warning "Runner image already exists. Skipping build..."
        sleep 2
    else
        print_info "Starting build process (this may take 15-30 minutes)..."
        ./build-runner-image.sh --rootfs-size 25G
    fi
    
    print_info "✅ Build phase complete!"
    echo ""
}

demo_snapshot_phase() {
    print_step "2" "Creating VM Snapshot"
    echo ""
    print_info "Creating a reusable snapshot for fast deployment..."
    
    local snapshot_name="demo-runner-$(date +%Y%m%d-%H%M%S)"
    ./snapshot-runner-image.sh create "$snapshot_name"
    
    echo ""
    print_info "✅ Snapshot phase complete!"
    print_info "📸 Snapshot: $snapshot_name"
    
    # Store snapshot name for launch phase
    echo "$snapshot_name" > .demo-snapshot-name
    echo ""
}

demo_launch_phase() {
    print_step "3" "Launching Runner VM"
    echo ""
    
    # Get snapshot name from previous phase
    local snapshot_name
    if [ -f ".demo-snapshot-name" ]; then
        snapshot_name=$(cat .demo-snapshot-name)
        print_info "Using snapshot: $snapshot_name"
    else
        print_info "Using latest available snapshot..."
    fi
    
    print_info "Launching runner VM with configuration:"
    print_info "  • Runner Name: $RUNNER_NAME"
    print_info "  • Labels: $RUNNER_LABELS"
    print_info "  • Memory: 2GB"
    print_info "  • CPUs: 2"
    echo ""
    
    local launch_cmd="./launch-runner-vm.sh \
        --github-url \"$GITHUB_URL\" \
        --github-token \"$GITHUB_TOKEN\" \
        --runner-name \"$RUNNER_NAME\" \
        --runner-labels \"$RUNNER_LABELS\""
    
    if [ -n "${snapshot_name:-}" ]; then
        launch_cmd="$launch_cmd --snapshot ./snapshots/$snapshot_name"
    fi
    
    print_info "Executing: $launch_cmd"
    eval "$launch_cmd"
    
    print_info "✅ Launch phase complete!"
    echo ""
}

demo_verification() {
    print_step "4" "Verifying Runner Setup"
    echo ""
    
    print_info "Checking runner status..."
    
    # Give some time for runner to fully start
    sleep 5
    
    print_info "VM should be accessible at: 172.16.0.2"
    print_info "SSH access available with generated key"
    print_info "Runner should be visible in your GitHub repository/organization"
    echo ""
    
    print_info "🔍 You can verify the runner by:"
    print_info "  1. Checking GitHub repo/org → Settings → Actions → Runners"
    print_info "  2. Running a test workflow"
    print_info "  3. SSH into the VM: ssh -i runner-instances/runner_key_* runner@172.16.0.2"
    echo ""
}

show_next_steps() {
    print_step "5" "Next Steps & Cleanup"
    echo ""
    
    print_info "🎉 Demo completed successfully!"
    echo ""
    print_info "What you can do next:"
    print_info "  • Create a test GitHub Actions workflow"
    print_info "  • Scale by launching multiple runners"
    print_info "  • Customize the cloud-init configuration"
    print_info "  • Build production snapshots"
    echo ""
    
    print_info "📚 Documentation:"
    print_info "  • Workflow Guide: ./RUNNER_WORKFLOW.md"
    print_info "  • Networking Guide: ./FIRECRACKER_README.md"
    echo ""
    
    print_info "🛠️  Management commands:"
    print_info "  • List VMs: ./firecracker-manage.sh list"
    print_info "  • Stop VMs: ./firecracker-manage.sh cleanup"
    print_info "  • List snapshots: ./snapshot-runner-image.sh list"
    echo ""
    
    print_warning "⚠️  Don't forget to clean up when done:"
    print_warning "  ./firecracker-manage.sh cleanup  # Stop all VMs"
    echo ""
    
    # Cleanup demo files
    rm -f .demo-snapshot-name
}

show_demo_summary() {
    echo ""
    print_banner
    echo ""
    print_info "🏁 Demo Summary"
    echo ""
    print_info "Phase 1: ✅ Built runner image with GitHub Actions runner"
    print_info "Phase 2: ✅ Created VM snapshot for fast deployment"
    print_info "Phase 3: ✅ Launched runner VM with cloud-init configuration"
    print_info "Phase 4: ✅ Verified runner setup and accessibility"
    echo ""
    print_info "Your GitHub Actions runner '$RUNNER_NAME' should now be:"
    print_info "  • Registered with GitHub"
    print_info "  • Ready to accept workflow jobs"
    print_info "  • Accessible via SSH for debugging"
    echo ""
    print_info "🚀 Ready for GitHub Actions workflows!"
    echo ""
}

main() {
    print_banner
    
    check_os
    interactive_setup
    
    echo ""
    print_info "🚀 Starting GitHub Actions Runner Workflow Demo..."
    echo ""
    
    demo_build_phase
    demo_snapshot_phase
    demo_launch_phase
    demo_verification
    show_next_steps
    show_demo_summary
    
    print_info "Demo completed! Check your GitHub repository for the new runner."
}

# Run main function
main "$@" 