#!/bin/bash

# Host-Based Firecracker Installation Script v2
# Improved for production scaling with dynamic resource management

set -euo pipefail

INSTALL_DIR="/opt/firecracker"
DATA_DIR="/opt/firecracker/firecracker-data"
SERVICE_USER="firecracker"
VM_AGENT_PORT="8091"

# Dynamic resource configuration
CPU_OVERSUBSCRIPTION_RATIO="4"    # Allow 4x CPU oversubscription
MEMORY_RESERVATION_PCT="20"       # Reserve 20% of memory for host OS
MEMORY_UTILIZATION_PCT="80"       # Use up to 80% of available memory
MIN_FREE_MEMORY_MB="2048"         # Always keep 2GB free

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

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

print_info "Installing Firecracker VM management on host..."

# Get system information for dynamic configuration
TOTAL_MEMORY_MB=$(free -m | awk 'NR==2{print $2}')
TOTAL_CPUS=$(nproc)
HOSTNAME=$(hostname)

print_info "System Resources:"
print_info "  Hostname: $HOSTNAME"
print_info "  Total Memory: ${TOTAL_MEMORY_MB}MB"
print_info "  Total CPUs: $TOTAL_CPUS"
print_info "  CPU Oversubscription: ${CPU_OVERSUBSCRIPTION_RATIO}x"

# Calculate dynamic limits
RESERVED_MEMORY_MB=$((TOTAL_MEMORY_MB * MEMORY_RESERVATION_PCT / 100))
AVAILABLE_MEMORY_MB=$((TOTAL_MEMORY_MB - RESERVED_MEMORY_MB))
MAX_USABLE_MEMORY_MB=$((AVAILABLE_MEMORY_MB * MEMORY_UTILIZATION_PCT / 100))
MAX_VIRTUAL_CPUS=$((TOTAL_CPUS * CPU_OVERSUBSCRIPTION_RATIO))

print_info "Calculated Limits:"
print_info "  Reserved for OS: ${RESERVED_MEMORY_MB}MB"
print_info "  Max VM Memory: ${MAX_USABLE_MEMORY_MB}MB"
print_info "  Max Virtual CPUs: $MAX_VIRTUAL_CPUS"

# Create directories
print_info "Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$DATA_DIR"/{kernels,snapshots,instances,images}

# Create service user
print_info "Creating service user..."
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -s /bin/bash -d "$INSTALL_DIR" "$SERVICE_USER"
fi

# Install dependencies
print_info "Installing dependencies..."
apt update
apt install -y curl wget jq python3 python3-pip iproute2 iptables bridge-utils python3-psutil

# Install Python dependencies
# print_info "Installing Python dependencies..."
# pip3 install psutil

# Install Firecracker
print_info "Installing Firecracker..."
if ! command -v firecracker &> /dev/null; then
    FIRECRACKER_VERSION="v1.7.0"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        FIRECRACKER_ARCH="x86_64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        FIRECRACKER_ARCH="aarch64"
    else
        print_error "Unsupported architecture: $ARCH"
        exit 1
    fi
    
    wget -O /tmp/firecracker.tgz \
        "https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_VERSION}/firecracker-${FIRECRACKER_VERSION}-${FIRECRACKER_ARCH}.tgz"
    
    tar -xzf /tmp/firecracker.tgz -C /tmp/
    mv /tmp/release-${FIRECRACKER_VERSION}-${FIRECRACKER_ARCH}/firecracker-${FIRECRACKER_VERSION}-${FIRECRACKER_ARCH} /usr/local/bin/firecracker
    chmod +x /usr/local/bin/firecracker
    rm -rf /tmp/firecracker.tgz /tmp/release-*
fi

# Copy firecracker-complete.sh (should be in /tmp/)
print_info "Installing Firecracker management scripts..."
if [[ -f "/tmp/firecracker-complete.sh" ]]; then
    cp /tmp/firecracker-complete.sh "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/firecracker-complete.sh"
    print_info "✅ firecracker-complete.sh installed"
else
    print_error "firecracker-complete.sh not found in /tmp/"
    exit 1
fi

# Create improved VM agent with dynamic resource management
cat > "$INSTALL_DIR/vm-agent.py" << 'EOF'
#!/usr/bin/env python3

import json
import subprocess
import threading
import time
import psutil
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import logging
import os
import signal
import sys
import hashlib

# Configuration
LISTEN_PORT = 8091
SCRIPT_PATH = "/opt/firecracker/firecracker-complete.sh"
DATA_DIR = "/opt/firecracker/firecracker-data"
RESOURCE_FILE = "/opt/firecracker/resources.json"

# These will be set from command line or defaults
TOTAL_MEMORY_MB = 0
TOTAL_CPUS = 0
CPU_OVERSUBSCRIPTION_RATIO = 4
MEMORY_RESERVATION_PCT = 20
MEMORY_UTILIZATION_PCT = 80
MIN_FREE_MEMORY_MB = 2048

# Will be calculated in init
RESERVED_MEMORY_MB = 0
AVAILABLE_MEMORY_MB = 0
MAX_USABLE_MEMORY_MB = 0
MAX_VIRTUAL_CPUS = 0

def init_system_limits():
    global TOTAL_MEMORY_MB, TOTAL_CPUS, RESERVED_MEMORY_MB, AVAILABLE_MEMORY_MB, MAX_USABLE_MEMORY_MB, MAX_VIRTUAL_CPUS
    
    # Get system resources
    memory = psutil.virtual_memory()
    TOTAL_MEMORY_MB = memory.total // (1024 * 1024)
    TOTAL_CPUS = psutil.cpu_count()
    
    # Calculate limits
    RESERVED_MEMORY_MB = TOTAL_MEMORY_MB * MEMORY_RESERVATION_PCT // 100
    AVAILABLE_MEMORY_MB = TOTAL_MEMORY_MB - RESERVED_MEMORY_MB
    MAX_USABLE_MEMORY_MB = AVAILABLE_MEMORY_MB * MEMORY_UTILIZATION_PCT // 100
    MAX_VIRTUAL_CPUS = TOTAL_CPUS * CPU_OVERSUBSCRIPTION_RATIO
    
    print(f"Agent starting with dynamic limits:")
    print(f"  Total Memory: {TOTAL_MEMORY_MB}MB")
    print(f"  Max VM Memory: {MAX_USABLE_MEMORY_MB}MB")
    print(f"  Max Virtual CPUs: {MAX_VIRTUAL_CPUS}")

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/firecracker-agent.log'),
        logging.StreamHandler()
    ]
)

class DynamicResourceManager:
    def __init__(self):
        self.resource_file = RESOURCE_FILE
        self.load_resources()
        
        # Start cleanup thread
        self.cleanup_thread = threading.Thread(target=self.cleanup_dead_vms, daemon=True)
        self.cleanup_thread.start()
    
    def load_resources(self):
        try:
            with open(self.resource_file, 'r') as f:
                self.resources = json.load(f)
        except FileNotFoundError:
            self.resources = {"vms": {}, "total_memory_mb": 0, "total_virtual_cpus": 0}
            self.save_resources()
    
    def save_resources(self):
        with open(self.resource_file, 'w') as f:
            json.dump(self.resources, f, indent=2)
    
    def get_system_resources(self):
        memory = psutil.virtual_memory()
        cpu_percent = psutil.cpu_percent(interval=1)
        load_avg = os.getloadavg()
        
        return {
            "total_memory_mb": memory.total // (1024 * 1024),
            "available_memory_mb": memory.available // (1024 * 1024),
            "used_memory_mb": (memory.total - memory.available) // (1024 * 1024),
            "memory_percent": memory.percent,
            "total_cpus": TOTAL_CPUS,
            "cpu_percent": cpu_percent,
            "load_1min": load_avg[0],
            "load_5min": load_avg[1],
            "load_15min": load_avg[2],
            # Resource limits
            "max_usable_memory_mb": MAX_USABLE_MEMORY_MB,
            "max_virtual_cpus": MAX_VIRTUAL_CPUS,
            "cpu_oversubscription_ratio": CPU_OVERSUBSCRIPTION_RATIO
        }
    
    def can_create_vm(self, memory_mb, cpus):
        system = self.get_system_resources()
        
        # Check memory limit (hard limit)
        used_memory = self.resources["total_memory_mb"]
        if used_memory + memory_mb > MAX_USABLE_MEMORY_MB:
            return False, f"Memory limit exceeded: {used_memory + memory_mb}MB > {MAX_USABLE_MEMORY_MB}MB"
        
        # Check that we maintain minimum free memory
        if system["available_memory_mb"] - memory_mb < MIN_FREE_MEMORY_MB:
            return False, f"Would leave less than {MIN_FREE_MEMORY_MB}MB free memory"
        
        # Check virtual CPU limit (soft limit with oversubscription)
        used_vcpus = self.resources["total_virtual_cpus"]
        if used_vcpus + cpus > MAX_VIRTUAL_CPUS:
            return False, f"Virtual CPU limit exceeded: {used_vcpus + cpus} > {MAX_VIRTUAL_CPUS}"
        
        # Additional health checks
        if system["memory_percent"] > 90:
            return False, f"System memory usage too high: {system['memory_percent']}%"
        
        if system["load_5min"] > (TOTAL_CPUS * 2):
            return False, f"System load too high: {system['load_5min']} > {TOTAL_CPUS * 2}"
        
        return True, "OK"
    
    def reserve_resources(self, vm_name, memory_mb, cpus):
        self.resources["vms"][vm_name] = {
            "memory_mb": memory_mb,
            "cpus": cpus,
            "created_at": time.time(),
            "last_seen": time.time(),
            "status": "creating"
        }
        self.resources["total_memory_mb"] += memory_mb
        self.resources["total_virtual_cpus"] += cpus
        self.save_resources()
        
        logging.info(f"Reserved resources for {vm_name}: {memory_mb}MB, {cpus} vCPUs")
        logging.info(f"Total allocated: {self.resources['total_memory_mb']}MB, {self.resources['total_virtual_cpus']} vCPUs")
    
    def release_resources(self, vm_name):
        if vm_name in self.resources["vms"]:
            vm_resources = self.resources["vms"][vm_name]
            self.resources["total_memory_mb"] -= vm_resources["memory_mb"]
            self.resources["total_virtual_cpus"] -= vm_resources["cpus"]
            del self.resources["vms"][vm_name]
            self.save_resources()
            
            logging.info(f"Released resources for {vm_name}: {vm_resources['memory_mb']}MB, {vm_resources['cpus']} vCPUs")
    
    def update_vm_status(self, vm_name, status):
        if vm_name in self.resources["vms"]:
            self.resources["vms"][vm_name]["status"] = status
            self.resources["vms"][vm_name]["last_seen"] = time.time()
            self.save_resources()
    
    def get_vm_status(self, vm_name):
        """Get VM status by checking if Firecracker process is running"""
        if vm_name not in self.resources["vms"]:
            return None
            
        vm_data = self.resources["vms"][vm_name]
        
        # Check if VM process is running by looking for firecracker process
        # Use the same hash-based VM ID calculation as firecracker-complete.sh
        vm_id = hashlib.sha256(vm_name.lower().encode()).hexdigest()[:8]
        is_running = False
        
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                if proc.info['name'] == 'firecracker':
                    cmdline = proc.info['cmdline']
                    for arg in cmdline:
                        if f'instances/{vm_id}' in arg and 'firecracker.socket' in arg:
                            is_running = True
                            break
                if is_running:
                    break
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
        
        status = "running" if is_running else "stopped"
        
        # Update status in resources
        self.update_vm_status(vm_name, status)
        
        return {
            "vm_name": vm_name,
            "vm_id": vm_id,
            "status": status,
            "memory_mb": vm_data["memory_mb"],
            "cpus": vm_data["cpus"],
            "created_at": vm_data["created_at"],
            "last_seen": vm_data.get("last_seen", vm_data["created_at"])
        }
    
    def destroy_vm(self, vm_name):
        """Destroy a VM and release its resources"""
        logging.info(f"Destroying VM: {vm_name}")
        
        # Find VM instance directory using correct hash calculation
        vm_id = hashlib.sha256(vm_name.lower().encode()).hexdigest()[:8]
        instance_dir = os.path.join(DATA_DIR, "instances", vm_id)
        
        # Kill Firecracker process
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                if proc.info['name'] == 'firecracker':
                    cmdline = proc.info['cmdline']
                    for arg in cmdline:
                        if f'instances/{vm_id}' in arg and 'firecracker.socket' in arg:
                            logging.info(f"Killing Firecracker process {proc.pid} for VM {vm_name}")
                            proc.kill()
                            time.sleep(2)
                            if proc.is_running():
                                proc.kill()  # Force kill if still running
                            break
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
        
        # Clean up instance directory
        if os.path.exists(instance_dir):
            logging.info(f"Cleaning up instance directory: {instance_dir}")
            subprocess.run(["rm", "-rf", instance_dir], check=False)
        
        # Release resources
        self.release_resources(vm_name)
        
        logging.info(f"VM {vm_name} destroyed successfully")
    
    def cleanup_dead_vms(self):
        """Periodically clean up resources for dead VMs"""
        while True:
            try:
                time.sleep(60)  # Check every minute
                
                # Get list of running VM processes
                running_vms = set()
                for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
                    try:
                        if proc.info['name'] == 'firecracker':
                            # Extract VM name from socket path
                            cmdline = proc.info['cmdline']
                            for arg in cmdline:
                                if 'instances/' in arg and '/firecracker.socket' in arg:
                                    vm_id = arg.split('instances/')[1].split('/')[0]
                                    running_vms.add(vm_id)
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        continue
                
                # Check if tracked VMs are still running
                tracked_vms = list(self.resources["vms"].keys())
                for vm_name in tracked_vms:
                    # Extract VM ID from name using correct hash calculation
                    vm_id = hashlib.sha256(vm_name.lower().encode()).hexdigest()[:8]
                    
                    if vm_id not in running_vms:
                        # VM is not running, check if it's been dead for a while
                        vm_data = self.resources["vms"][vm_name]
                        last_seen = vm_data.get('last_seen', vm_data['created_at'])
                        
                        if time.time() - last_seen > 300:  # 5 minutes grace period
                            logging.warning(f"Cleaning up dead VM: {vm_name}")
                            self.release_resources(vm_name)
                
            except Exception as e:
                logging.error(f"Error in cleanup thread: {e}")

class FirecrackerVMHandler(BaseHTTPRequestHandler):
    def __init__(self, *args, resource_manager=None, **kwargs):
        self.resource_manager = resource_manager
        super().__init__(*args, **kwargs)
    
    def log_message(self, format, *args):
        # Override to reduce noise in logs (optional)
        pass
    
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            
            system_resources = self.resource_manager.get_system_resources()
            health_data = {
                "status": "healthy",
                "timestamp": time.time(),
                "system": system_resources,
                "allocated_resources": {
                    "total_memory_mb": self.resource_manager.resources["total_memory_mb"],
                    "total_virtual_cpus": self.resource_manager.resources["total_virtual_cpus"],
                    "active_vms": len(self.resource_manager.resources["vms"])
                }
            }
            self.wfile.write(json.dumps(health_data, indent=2).encode())
            
        elif self.path == '/metrics':
            # Prometheus-style metrics endpoint for monitoring
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            
            system_resources = self.resource_manager.get_system_resources()
            allocated = self.resource_manager.resources
            
            metrics = f"""# HELP firecracker_vms_total Total number of VMs
# TYPE firecracker_vms_total gauge
firecracker_vms_total {len(allocated["vms"])}

# HELP firecracker_memory_allocated_mb Total allocated memory in MB
# TYPE firecracker_memory_allocated_mb gauge
firecracker_memory_allocated_mb {allocated["total_memory_mb"]}

# HELP firecracker_memory_available_mb Available system memory in MB
# TYPE firecracker_memory_available_mb gauge
firecracker_memory_available_mb {system_resources["available_memory_mb"]}

# HELP firecracker_memory_max_usable_mb Maximum usable memory for VMs in MB
# TYPE firecracker_memory_max_usable_mb gauge
firecracker_memory_max_usable_mb {system_resources["max_usable_memory_mb"]}

# HELP firecracker_vcpus_allocated Total allocated virtual CPUs
# TYPE firecracker_vcpus_allocated gauge
firecracker_vcpus_allocated {allocated["total_virtual_cpus"]}

# HELP firecracker_vcpus_max_usable Maximum usable virtual CPUs
# TYPE firecracker_vcpus_max_usable gauge
firecracker_vcpus_max_usable {system_resources["max_virtual_cpus"]}

# HELP firecracker_system_cpu_percent System CPU usage percentage
# TYPE firecracker_system_cpu_percent gauge
firecracker_system_cpu_percent {system_resources["cpu_percent"]}

# HELP firecracker_system_memory_percent System memory usage percentage
# TYPE firecracker_system_memory_percent gauge
firecracker_system_memory_percent {system_resources["memory_percent"]}

# HELP firecracker_system_load_1min System load average (1 minute)
# TYPE firecracker_system_load_1min gauge
firecracker_system_load_1min {system_resources["load_1min"]}
"""
            self.wfile.write(metrics.encode())
            
        elif self.path.startswith('/api/vms/'):
            # Get VM status
            vm_name = self.path.split('/')[-1]
            logging.info(f"Getting status for VM: {vm_name}")
            
            vm_status = self.resource_manager.get_vm_status(vm_name)
            
            if vm_status:
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(vm_status).encode())
                logging.info(f"Returned status for VM {vm_name}: {vm_status['status']}")
            else:
                self.send_response(404)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                response = {"error": "VM not found", "vm_name": vm_name}
                self.wfile.write(json.dumps(response).encode())
                logging.warning(f"VM not found: {vm_name}")
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_POST(self):
        if self.path == '/api/vms':
            try:
                content_length = int(self.headers['Content-Length'])
                post_data = self.rfile.read(content_length)
                request_data = json.loads(post_data.decode('utf-8'))
                
                # Debug: Log the incoming request data
                logging.info(f"Received POST request data: {request_data}")
                
                vm_name = request_data['name']
                memory_mb = request_data['memory']
                cpus = request_data['cpus']
                github_url = request_data.get('github_url', '')
                github_token = request_data.get('github_token', '')
                snapshot = request_data.get('snapshot', '')  # Pass through what ARC controller sends
                
                logging.info(f"Creating VM: {vm_name} with {memory_mb}MB, {cpus} vCPUs, snapshot: '{snapshot}'")
                
                # Check if we can create the VM
                can_create, message = self.resource_manager.can_create_vm(memory_mb, cpus)
                
                if not can_create:
                    self.send_response(429)  # Too Many Requests
                    self.send_header('Content-type', 'application/json')
                    self.end_headers()
                    
                    response = {
                        "error": "Cannot create VM",
                        "reason": message,
                        "vm_name": vm_name
                    }
                    self.wfile.write(json.dumps(response).encode())
                    logging.warning(f"VM creation denied for {vm_name}: {message}")
                    return
                
                # Reserve resources
                self.resource_manager.reserve_resources(vm_name, memory_mb, cpus)
                
                # Launch VM
                cmd = [
                    SCRIPT_PATH, "launch",
                    "--name", vm_name,
                    "--memory", str(memory_mb),
                    "--cpus", str(cpus),
                    "--use-host-bridge",
                    "--skip-deps"
                ]
                
                if snapshot:  # Only add snapshot if not empty
                    cmd.extend(["--snapshot", snapshot])
                if github_url:
                    cmd.extend(["--github-url", github_url])
                if github_token:
                    cmd.extend(["--github-token", github_token])
                
                # Set environment variable to tell firecracker-complete.sh where to work
                env = os.environ.copy()
                env['FIRECRACKER_WORK_DIR'] = DATA_DIR
                
                # Log the full command for debugging
                logging.info(f"Executing command: {' '.join(cmd)}")
                logging.info(f"Working directory: {DATA_DIR}")
                logging.info(f"Environment FIRECRACKER_WORK_DIR: {DATA_DIR}")
                logging.info(f"Snapshot parameter: {snapshot}")
                
                # Execute in background with correct environment and capture output
                process = subprocess.Popen(cmd, cwd=DATA_DIR, 
                                         stdout=subprocess.PIPE, 
                                         stderr=subprocess.PIPE,
                                         env=env,
                                         text=True)
                
                # Start a background thread to monitor the process
                def monitor_process():
                    try:
                        stdout, stderr = process.communicate(timeout=300)  # 5 minute timeout
                        logging.info(f"VM creation process completed for {vm_name}")
                        logging.info(f"Return code: {process.returncode}")
                        if stdout:
                            logging.info(f"STDOUT: {stdout}")
                        if stderr:
                            logging.error(f"STDERR: {stderr}")
                        
                        if process.returncode != 0:
                            logging.error(f"VM creation failed for {vm_name} with return code {process.returncode}")
                            # Release resources if VM creation failed
                            self.resource_manager.release_resources(vm_name)
                        else:
                            logging.info(f"VM creation succeeded for {vm_name}")
                            # Update status to running
                            self.resource_manager.update_vm_status(vm_name, "running")
                            
                    except subprocess.TimeoutExpired:
                        logging.error(f"VM creation timed out for {vm_name}")
                        process.kill()
                        self.resource_manager.release_resources(vm_name)
                    except Exception as e:
                        logging.error(f"Error monitoring VM creation for {vm_name}: {e}")
                        self.resource_manager.release_resources(vm_name)
                
                # Start monitoring thread
                monitor_thread = threading.Thread(target=monitor_process, daemon=True)
                monitor_thread.start()
                
                self.send_response(202)  # Accepted
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                
                response = {
                    "vm_name": vm_name,
                    "status": "creating",
                    "message": "VM creation started",
                    "assigned_node": os.uname().nodename
                }
                self.wfile.write(json.dumps(response).encode())
                
                logging.info(f"Started VM creation: {vm_name}")
                
            except Exception as e:
                logging.error(f"Error creating VM: {e}")
                self.send_response(500)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                
                response = {"error": f"Internal server error: {e}"}
                self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_DELETE(self):
        if self.path.startswith('/api/vms/'):
            # Delete VM
            vm_name = self.path.split('/')[-1]
            logging.info(f"Deleting VM: {vm_name}")
            
            try:
                # Check if VM exists
                vm_status = self.resource_manager.get_vm_status(vm_name)
                
                if vm_status:
                    # Destroy the VM
                    self.resource_manager.destroy_vm(vm_name)
                    
                    self.send_response(200)
                    self.send_header('Content-type', 'application/json')
                    self.end_headers()
                    
                    response = {
                        "vm_name": vm_name,
                        "status": "deleted",
                        "message": "VM deleted successfully"
                    }
                    self.wfile.write(json.dumps(response).encode())
                    logging.info(f"VM {vm_name} deleted successfully")
                    
                else:
                    # VM not found
                    self.send_response(404)
                    self.send_header('Content-type', 'application/json')
                    self.end_headers()
                    
                    response = {
                        "error": "VM not found",
                        "vm_name": vm_name
                    }
                    self.wfile.write(json.dumps(response).encode())
                    logging.warning(f"Attempted to delete non-existent VM: {vm_name}")
                    
            except Exception as e:
                logging.error(f"Error deleting VM {vm_name}: {e}")
                self.send_response(500)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                
                response = {
                    "error": f"Failed to delete VM: {e}",
                    "vm_name": vm_name
                }
                self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()

def create_handler_class(resource_manager):
    def handler(*args, **kwargs):
        FirecrackerVMHandler(*args, resource_manager=resource_manager, **kwargs)
    return handler

def signal_handler(signum, frame):
    print(f"\nReceived signal {signum}, shutting down...")
    sys.exit(0)

def main():
    # Initialize system limits
    init_system_limits()
    
    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Create resource manager
    resource_manager = DynamicResourceManager()
    
    # Create HTTP server
    handler_class = create_handler_class(resource_manager)
    server = HTTPServer(('0.0.0.0', LISTEN_PORT), handler_class)
    
    print(f"Firecracker VM Agent starting on port {LISTEN_PORT}")
    print(f"Resource limits: {MAX_USABLE_MEMORY_MB}MB memory, {MAX_VIRTUAL_CPUS} vCPUs")
    print(f"Supported endpoints:")
    print(f"  GET  /health - Health check")
    print(f"  GET  /metrics - Prometheus metrics")
    print(f"  GET  /api/vms/{{vm_name}} - Get VM status")
    print(f"  POST /api/vms - Create VM")
    print(f"  DELETE /api/vms/{{vm_name}} - Delete VM")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()

if __name__ == "__main__":
    main()
EOF

chmod +x "$INSTALL_DIR/vm-agent.py"

# Create systemd service with dynamic environment
print_info "Creating systemd service..."
cat > /etc/systemd/system/firecracker-agent.service << EOF
[Unit]
Description=Firecracker VM Agent ($HOSTNAME)
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$DATA_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/vm-agent.py
Restart=always
RestartSec=10

# Dynamic resource configuration
Environment=HOSTNAME=$HOSTNAME
Environment=TOTAL_MEMORY_MB=$TOTAL_MEMORY_MB
Environment=TOTAL_CPUS=$TOTAL_CPUS

# Security settings
NoNewPrivileges=false
PrivateTmp=false
ProtectSystem=false
ProtectHome=false

[Install]
WantedBy=multi-user.target
EOF

# Set permissions
print_info "Setting permissions..."
chown -R root:root "$INSTALL_DIR"

# Enable and start service
print_info "Enabling and starting service..."
systemctl daemon-reload
systemctl enable firecracker-agent
systemctl start firecracker-agent

# Wait for service to start
sleep 3

# Test the service
print_info "Testing the service..."
if systemctl is-active --quiet firecracker-agent; then
    print_info "✅ Firecracker agent is running"
    
    # Test HTTP endpoint
    if curl -s http://localhost:$VM_AGENT_PORT/health >/dev/null; then
        print_info "✅ HTTP endpoint is responding"
        
        # Show resource information
        echo "📊 Resource Information:"
        curl -s http://localhost:$VM_AGENT_PORT/health | jq '.system' 2>/dev/null || echo "   (jq not available for pretty printing)"
    else
        print_warning "⚠️  HTTP endpoint not responding yet (may need a few seconds)"
    fi
else
    print_error "❌ Firecracker agent failed to start"
    systemctl status firecracker-agent --no-pager
    exit 1
fi

print_info "✅ Installation complete!"
print_info ""
print_info "Firecracker VM Agent Details:"
print_info "  Node: $HOSTNAME"
print_info "  Location: $INSTALL_DIR"
print_info "  Data: $DATA_DIR"
print_info "  Service: firecracker-agent"
print_info "  Port: $VM_AGENT_PORT"
print_info "  Logs: journalctl -u firecracker-agent -f"
print_info ""
print_info "Dynamic Resource Limits:"
print_info "  Max VM Memory: ${MAX_USABLE_MEMORY_MB}MB"
print_info "  Max Virtual CPUs: $MAX_VIRTUAL_CPUS (${CPU_OVERSUBSCRIPTION_RATIO}x oversubscription)"
print_info ""
print_info "Test with: curl http://localhost:$VM_AGENT_PORT/health"

export KUBECONFIG=/root/staging-kubeconfig.yaml && kubectl delete configmap firecracker-host-install-v2 -n arc-systems && kubectl create configmap firecracker-host-install-v2 --from-file=host-install-improved.sh -n arc-systems && kubectl rollout restart daemonset/firecracker-vm-daemon -n arc-systems && ssh 192.168.21.32 "systemctl restart firecracker-agent" 