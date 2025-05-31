#!/usr/bin/env python3
"""
Firecracker VM Daemon - Host-based VM management API
Wraps firecracker-complete.sh for Kubernetes integration
"""

import os
import json
import subprocess
import threading
import time
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class FirecrackerVMDaemon:
    def __init__(self, work_dir="/opt/firecracker", script_path="/usr/local/bin/firecracker-complete.sh"):
        self.work_dir = work_dir
        self.script_path = script_path
        self.vms = {}  # Track VM state
        
        # Ensure directories exist
        os.makedirs(work_dir, exist_ok=True)
        os.chdir(work_dir)
        
        logger.info(f"Firecracker VM Daemon starting in {work_dir}")
        logger.info(f"Using script: {script_path}")

    def execute_script(self, args, timeout=300):
        """Execute firecracker-complete.sh with given arguments"""
        cmd = [self.script_path] + args
        logger.info(f"Executing: {' '.join(cmd)}")
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=self.work_dir
            )
            return {
                "success": result.returncode == 0,
                "returncode": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr
            }
        except subprocess.TimeoutExpired:
            return {
                "success": False,
                "returncode": -1,
                "stdout": "",
                "stderr": f"Command timed out after {timeout} seconds"
            }
        except Exception as e:
            return {
                "success": False,
                "returncode": -1,
                "stdout": "",
                "stderr": str(e)
            }

    def create_vm(self, vm_spec):
        """Create a Firecracker VM using host bridge networking"""
        vm_id = vm_spec.get("vm_id", f"vm-{int(time.time())}")
        github_url = vm_spec.get("github_url", "")
        github_token = vm_spec.get("github_token", "")
        labels = vm_spec.get("labels", "firecracker")
        memory = vm_spec.get("memory_mb", 8192)
        vcpus = vm_spec.get("vcpus", 4)
        ephemeral = vm_spec.get("ephemeral", True)
        
        # Build firecracker-complete.sh launch command
        args = [
            "launch",
            "--name", vm_id,
            "--github-url", github_url,
            "--github-token", github_token,
            "--labels", labels,
            "--memory", str(memory),
            "--cpus", str(vcpus),
            "--use-host-bridge",  # Use host br0 bridge
            "--arc-mode",
            "--arc-controller-url", "http://localhost:30080"
        ]
        
        if ephemeral:
            args.append("--ephemeral-mode")
        
        # Execute VM creation
        result = self.execute_script(args, timeout=600)  # 10 minute timeout
        
        if result["success"]:
            # Track VM
            self.vms[vm_id] = {
                "created": datetime.now().isoformat(),
                "status": "running",
                "spec": vm_spec,
                "networking": "bridge-br0"
            }
            logger.info(f"VM {vm_id} created successfully")
        else:
            logger.error(f"Failed to create VM {vm_id}: {result['stderr']}")
        
        return {
            "vm_id": vm_id,
            "success": result["success"],
            "message": result["stderr"] if not result["success"] else "VM created successfully",
            "details": result
        }

    def delete_vm(self, vm_id):
        """Delete a Firecracker VM"""
        args = ["stop", vm_id]
        result = self.execute_script(args)
        
        if vm_id in self.vms:
            self.vms[vm_id]["status"] = "deleted"
        
        return {
            "vm_id": vm_id,
            "success": result["success"],
            "message": result["stderr"] if not result["success"] else "VM deleted successfully"
        }

    def list_vms(self):
        """List all VMs using firecracker-complete.sh"""
        result = self.execute_script(["list"])
        
        return {
            "success": result["success"],
            "vms": self.vms,
            "host_status": result["stdout"],
            "details": result
        }

    def get_vm_status(self, vm_id):
        """Get status of a specific VM"""
        args = ["status", vm_id]
        result = self.execute_script(args)
        
        vm_info = self.vms.get(vm_id, {})
        
        return {
            "vm_id": vm_id,
            "success": result["success"],
            "status": vm_info.get("status", "unknown"),
            "details": result["stdout"],
            "vm_info": vm_info
        }

class VMDaemonHandler(BaseHTTPRequestHandler):
    def __init__(self, daemon, *args, **kwargs):
        self.daemon = daemon
        super().__init__(*args, **kwargs)

    def log_message(self, format, *args):
        # Use our logger instead of default logging
        logger.info(f"{self.address_string()} - {format % args}")

    def do_GET(self):
        """Handle GET requests"""
        parsed = urlparse(self.path)
        path = parsed.path
        
        try:
            if path == "/health":
                self.send_json_response({"status": "healthy", "daemon": "firecracker-vm"})
            elif path == "/vms":
                result = self.daemon.list_vms()
                self.send_json_response(result)
            elif path.startswith("/vms/"):
                vm_id = path.split("/")[-1]
                result = self.daemon.get_vm_status(vm_id)
                self.send_json_response(result)
            else:
                self.send_error(404, "Not Found")
        except Exception as e:
            logger.error(f"GET error: {e}")
            self.send_error(500, str(e))

    def do_POST(self):
        """Handle POST requests"""
        parsed = urlparse(self.path)
        path = parsed.path
        
        try:
            # Read request body
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else "{}"
            data = json.loads(body)
            
            if path == "/vms":
                # Create VM
                result = self.daemon.create_vm(data)
                self.send_json_response(result, status_code=201 if result["success"] else 400)
            else:
                self.send_error(404, "Not Found")
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
        except Exception as e:
            logger.error(f"POST error: {e}")
            self.send_error(500, str(e))

    def do_DELETE(self):
        """Handle DELETE requests"""
        parsed = urlparse(self.path)
        path = parsed.path
        
        try:
            if path.startswith("/vms/"):
                vm_id = path.split("/")[-1]
                result = self.daemon.delete_vm(vm_id)
                self.send_json_response(result)
            else:
                self.send_error(404, "Not Found")
        except Exception as e:
            logger.error(f"DELETE error: {e}")
            self.send_error(500, str(e))

    def send_json_response(self, data, status_code=200):
        """Send JSON response"""
        response = json.dumps(data, indent=2)
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response.encode('utf-8'))

def create_handler(daemon):
    """Create request handler with daemon instance"""
    def handler(*args, **kwargs):
        return VMDaemonHandler(daemon, *args, **kwargs)
    return handler

def main():
    port = int(os.environ.get("DAEMON_PORT", "8090"))
    work_dir = os.environ.get("FIRECRACKER_WORK_DIR", "/opt/firecracker")
    script_path = os.environ.get("FIRECRACKER_SCRIPT", "/usr/local/bin/firecracker-complete.sh")
    
    # Initialize daemon
    daemon = FirecrackerVMDaemon(work_dir, script_path)
    
    # Create HTTP server
    handler = create_handler(daemon)
    server = HTTPServer(('0.0.0.0', port), handler)
    
    logger.info(f"Firecracker VM Daemon listening on port {port}")
    logger.info(f"API endpoints:")
    logger.info(f"  GET  /health          - Health check")
    logger.info(f"  GET  /vms             - List all VMs")
    logger.info(f"  POST /vms             - Create VM")
    logger.info(f"  GET  /vms/{{vm_id}}     - Get VM status")
    logger.info(f"  DELETE /vms/{{vm_id}}  - Delete VM")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down daemon...")
        server.shutdown()

if __name__ == "__main__":
    main() 