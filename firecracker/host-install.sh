#!/bin/bash

# Host-Based Firecracker Installation Script
# Installs Firecracker VM management directly on Kubernetes nodes

set -euo pipefail

INSTALL_DIR="/opt/firecracker"
DATA_DIR="/opt/firecracker/data"
SERVICE_USER="firecracker"
VM_AGENT_PORT="8090"

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
apt install -y curl wget jq python3 python3-pip iproute2 iptables bridge-utils

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

# Download our scripts from the current directory or ConfigMap
print_info "Installing Firecracker management scripts..."

# Copy firecracker-complete.sh (if exists locally, otherwise download from ConfigMap)
if [[ -f "firecracker-complete.sh" ]]; then
    cp firecracker-complete.sh "$INSTALL_DIR/"
else
    print_warning "firecracker-complete.sh not found locally, will need to be provided"
fi

# Create lightweight VM agent
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

# Configuration
LISTEN_PORT = 8090
SCRIPT_PATH = "/opt/firecracker/firecracker-complete.sh"
DATA_DIR = "/opt/firecracker/data"
RESOURCE_FILE = "/opt/firecracker/resources.json"

# Resource limits (configurable)
MAX_VMS = int(os.environ.get('MAX_VMS', '10'))
MAX_MEMORY_PCT = int(os.environ.get('MAX_MEMORY_PCT', '80'))
MAX_CPU_PCT = int(os.environ.get('MAX_CPU_PCT', '80'))

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/firecracker-agent.log'),
        logging.StreamHandler()
    ]
)

class ResourceManager:
    def __init__(self):
        self.resource_file = RESOURCE_FILE
        self.load_resources()
    
    def load_resources(self):
        try:
            with open(self.resource_file, 'r') as f:
                self.resources = json.load(f)
        except FileNotFoundError:
            self.resources = {"vms": {}, "total_memory_mb": 0, "total_cpus": 0}
            self.save_resources()
    
    def save_resources(self):
        with open(self.resource_file, 'w') as f:
            json.dump(self.resources, f, indent=2)
    
    def get_system_resources(self):
        memory = psutil.virtual_memory()
        cpu_count = psutil.cpu_count()
        return {
            "total_memory_mb": memory.total // (1024 * 1024),
            "available_memory_mb": memory.available // (1024 * 1024),
            "cpu_count": cpu_count,
            "cpu_percent": psutil.cpu_percent(interval=1)
        }
    
    def can_create_vm(self, memory_mb, cpus):
        system = self.get_system_resources()
        
        # Check VM count limit
        if len(self.resources["vms"]) >= MAX_VMS:
            return False, f"VM limit reached ({MAX_VMS})"
        
        # Check memory limit
        used_memory = self.resources["total_memory_mb"]
        max_memory = (system["total_memory_mb"] * MAX_MEMORY_PCT) // 100
        if used_memory + memory_mb > max_memory:
            return False, f"Memory limit would be exceeded ({used_memory + memory_mb} > {max_memory})"
        
        # Check CPU limit
        used_cpus = self.resources["total_cpus"]
        max_cpus = (system["cpu_count"] * MAX_CPU_PCT) // 100
        if used_cpus + cpus > max_cpus:
            return False, f"CPU limit would be exceeded ({used_cpus + cpus} > {max_cpus})"
        
        return True, "OK"
    
    def reserve_resources(self, vm_name, memory_mb, cpus):
        self.resources["vms"][vm_name] = {
            "memory_mb": memory_mb,
            "cpus": cpus,
            "created_at": time.time()
        }
        self.resources["total_memory_mb"] += memory_mb
        self.resources["total_cpus"] += cpus
        self.save_resources()
    
    def release_resources(self, vm_name):
        if vm_name in self.resources["vms"]:
            vm_resources = self.resources["vms"][vm_name]
            self.resources["total_memory_mb"] -= vm_resources["memory_mb"]
            self.resources["total_cpus"] -= vm_resources["cpus"]
            del self.resources["vms"][vm_name]
            self.save_resources()

class FirecrackerVMHandler(BaseHTTPRequestHandler):
    def __init__(self, *args, resource_manager=None, **kwargs):
        self.resource_manager = resource_manager
        super().__init__(*args, **kwargs)
    
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {"status": "healthy", "timestamp": time.time()}
            self.wfile.write(json.dumps(response).encode())
        
        elif self.path == '/vms':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            
            # Get VM list from firecracker-complete.sh
            try:
                result = subprocess.run(
                    [SCRIPT_PATH, 'list'],
                    capture_output=True,
                    text=True,
                    cwd=DATA_DIR
                )
                
                # Parse the output and combine with resource info
                system_resources = self.resource_manager.get_system_resources()
                response = {
                    "vms": self.resource_manager.resources["vms"],
                    "system": system_resources,
                    "limits": {
                        "max_vms": MAX_VMS,
                        "max_memory_pct": MAX_MEMORY_PCT,
                        "max_cpu_pct": MAX_CPU_PCT
                    }
                }
                
                self.wfile.write(json.dumps(response).encode())
            except Exception as e:
                logging.error(f"Failed to list VMs: {e}")
                self.send_error(500, f"Failed to list VMs: {e}")
        
        else:
            self.send_error(404, "Not found")
    
    def do_POST(self):
        if self.path == '/vms':
            try:
                content_length = int(self.headers['Content-Length'])
                post_data = self.rfile.read(content_length)
                request = json.loads(post_data.decode('utf-8'))
                
                # Extract VM parameters
                vm_name = request.get('name', f'vm-{int(time.time())}')
                memory_mb = int(request.get('memory', '2048'))
                cpus = int(request.get('cpus', '2'))
                snapshot = request.get('snapshot', '')
                github_url = request.get('github_url', '')
                github_token = request.get('github_token', '')
                use_host_bridge = request.get('use_host_bridge', False)
                
                logging.info(f"Creating VM: {vm_name} (Memory: {memory_mb}MB, CPUs: {cpus})")
                
                # Check resource availability
                can_create, reason = self.resource_manager.can_create_vm(memory_mb, cpus)
                if not can_create:
                    self.send_response(429)  # Too Many Requests
                    self.send_header('Content-type', 'application/json')
                    self.end_headers()
                    response = {"error": reason}
                    self.wfile.write(json.dumps(response).encode())
                    return
                
                # Reserve resources
                self.resource_manager.reserve_resources(vm_name, memory_mb, cpus)
                
                # Build command
                cmd = [
                    SCRIPT_PATH, 'launch',
                    '--name', vm_name,
                    '--memory', str(memory_mb),
                    '--cpus', str(cpus),
                    '--skip-deps'  # Skip dependency checks on host
                ]
                
                if snapshot:
                    cmd.extend(['--snapshot', snapshot])
                if github_url:
                    cmd.extend(['--github-url', github_url])
                if github_token:
                    cmd.extend(['--github-token', github_token])
                if use_host_bridge:
                    cmd.append('--use-host-bridge')
                
                # Execute in background
                def create_vm():
                    try:
                        result = subprocess.run(
                            cmd,
                            capture_output=True,
                            text=True,
                            cwd=DATA_DIR,
                            timeout=300  # 5 minute timeout
                        )
                        
                        if result.returncode != 0:
                            logging.error(f"VM creation failed for {vm_name}: {result.stderr}")
                            self.resource_manager.release_resources(vm_name)
                        else:
                            logging.info(f"VM created successfully: {vm_name}")
                    
                    except subprocess.TimeoutExpired:
                        logging.error(f"VM creation timed out for {vm_name}")
                        self.resource_manager.release_resources(vm_name)
                    except Exception as e:
                        logging.error(f"VM creation exception for {vm_name}: {e}")
                        self.resource_manager.release_resources(vm_name)
                
                # Start creation in background
                threading.Thread(target=create_vm, daemon=True).start()
                
                # Return immediate response
                self.send_response(202)  # Accepted
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                response = {
                    "vm_name": vm_name,
                    "status": "creating",
                    "message": "VM creation started"
                }
                self.wfile.write(json.dumps(response).encode())
                
            except Exception as e:
                logging.error(f"Failed to create VM: {e}")
                self.send_error(500, f"Failed to create VM: {e}")
        
        else:
            self.send_error(404, "Not found")
    
    def log_message(self, format, *args):
        logging.info(f"{self.address_string()} - {format % args}")

def main():
    # Change to data directory
    os.chdir(DATA_DIR)
    
    # Initialize resource manager
    resource_manager = ResourceManager()
    
    # Create HTTP server with resource manager
    def handler(*args, **kwargs):
        FirecrackerVMHandler(*args, resource_manager=resource_manager, **kwargs)
    
    server = HTTPServer(('0.0.0.0', LISTEN_PORT), handler)
    
    logging.info(f"Firecracker VM Agent starting on port {LISTEN_PORT}")
    logging.info(f"Resource limits: VMs={MAX_VMS}, Memory={MAX_MEMORY_PCT}%, CPU={MAX_CPU_PCT}%")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Shutting down...")
        server.shutdown()

if __name__ == '__main__':
    main()
EOF

chmod +x "$INSTALL_DIR/vm-agent.py"

# Install Python dependencies
print_info "Installing Python dependencies..."
pip3 install psutil

# Create systemd service
print_info "Creating systemd service..."
cat > /etc/systemd/system/firecracker-agent.service << EOF
[Unit]
Description=Firecracker VM Agent
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$DATA_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/vm-agent.py
Restart=always
RestartSec=10
Environment=MAX_VMS=10
Environment=MAX_MEMORY_PCT=80
Environment=MAX_CPU_PCT=80

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
chmod +x "$INSTALL_DIR/firecracker-complete.sh" 2>/dev/null || true

# Enable and start service
print_info "Enabling and starting service..."
systemctl daemon-reload
systemctl enable firecracker-agent
systemctl start firecracker-agent

# Wait for service to start
sleep 2

# Test the service
print_info "Testing the service..."
if systemctl is-active --quiet firecracker-agent; then
    print_info "✅ Firecracker agent is running"
    
    # Test HTTP endpoint
    if curl -s http://localhost:$VM_AGENT_PORT/health >/dev/null; then
        print_info "✅ HTTP endpoint is responding"
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
print_info "  Location: $INSTALL_DIR"
print_info "  Data: $DATA_DIR"
print_info "  Service: firecracker-agent"
print_info "  Port: $VM_AGENT_PORT"
print_info "  Logs: journalctl -u firecracker-agent -f"
print_info ""
print_info "Test with: curl http://localhost:$VM_AGENT_PORT/health" 