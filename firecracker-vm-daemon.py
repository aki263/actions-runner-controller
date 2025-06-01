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
import re
import glob
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
        self.vm_logs = {}  # Track VM startup logs
        self.metrics = {
            "total_vms_created": 0,
            "total_vms_deleted": 0,
            "current_vms": 0,
            "failed_creations": 0,
            "daemon_start_time": datetime.now().isoformat()
        }
        
        # Ensure directories exist
        os.makedirs(work_dir, exist_ok=True)
        os.chdir(work_dir)
        
        logger.info(f"Firecracker VM Daemon starting in {work_dir}")
        logger.info(f"Using script: {script_path}")

    def sanitize_output(self, text):
        """Remove sensitive information from output"""
        if not text:
            return text
        
        # Remove GitHub tokens
        text = re.sub(r'gh[pousr]_[A-Za-z0-9]{36}', '[TOKEN_HIDDEN]', text)
        text = re.sub(r'BNNAW[A-Z0-9]{60,}', '[TOKEN_HIDDEN]', text)
        text = re.sub(r'"github_token":\s*"[^"]{20,}"', '"github_token": "[HIDDEN]"', text)
        text = re.sub(r'--github-token\s+[^\s]+', '--github-token [HIDDEN]', text)
        
        return text

    def execute_script(self, args, timeout=300):
        """Execute firecracker-complete.sh with given arguments"""
        cmd = [self.script_path] + args
        logger.info(f"Executing: {self.sanitize_output(' '.join(cmd))}")
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=self.work_dir
            )
            
            # Sanitize outputs
            sanitized_result = {
                "success": result.returncode == 0,
                "returncode": result.returncode,
                "stdout": self.sanitize_output(result.stdout),
                "stderr": self.sanitize_output(result.stderr)
            }
            
            return sanitized_result
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

    def collect_vm_logs(self, vm_id):
        """Collect various logs for a VM"""
        logs = {
            "startup_log": "",
            "firecracker_log": "",
            "vm_log": "",
            "console_log": "",
            "collected_at": datetime.now().isoformat()
        }
        
        # Try to find log files in common locations
        log_patterns = [
            f"/opt/firecracker/{vm_id}*.log",
            f"/tmp/{vm_id}*.log", 
            f"/var/log/firecracker/{vm_id}*.log",
            f"/opt/firecracker/logs/{vm_id}*.log"
        ]
        
        for pattern in log_patterns:
            try:
                log_files = glob.glob(pattern)
                for log_file in log_files:
                    try:
                        with open(log_file, 'r') as f:
                            content = f.read()
                            if 'startup' in log_file.lower():
                                logs["startup_log"] += content + "\n"
                            elif 'firecracker' in log_file.lower():
                                logs["firecracker_log"] += content + "\n"
                            elif 'console' in log_file.lower():
                                logs["console_log"] += content + "\n"
                            else:
                                logs["vm_log"] += content + "\n"
                    except Exception as e:
                        logger.warning(f"Could not read log file {log_file}: {e}")
            except Exception as e:
                logger.debug(f"Could not glob pattern {pattern}: {e}")
        
        # Get process information if VM is running
        try:
            # Try to get process info
            result = subprocess.run(
                ["ps", "aux"], 
                capture_output=True, 
                text=True, 
                timeout=10
            )
            if result.returncode == 0:
                for line in result.stdout.split('\n'):
                    if vm_id in line and 'firecracker' in line.lower():
                        logs["vm_log"] += f"Process: {line}\n"
        except Exception as e:
            logger.debug(f"Could not get process info: {e}")
        
        # Sanitize all logs
        for key in logs:
            if isinstance(logs[key], str):
                logs[key] = self.sanitize_output(logs[key])
        
        return logs

    def get_vm_metrics(self, vm_id):
        """Get metrics for a specific VM"""
        metrics = {
            "vm_id": vm_id,
            "status": "unknown",
            "cpu_usage": 0,
            "memory_usage": 0,
            "network_stats": {},
            "uptime": 0,
            "collected_at": datetime.now().isoformat()
        }
        
        vm_info = self.vms.get(vm_id, {})
        metrics["status"] = vm_info.get("status", "unknown")
        
        # Try to get resource usage if VM is running
        try:
            # Get CPU and memory usage from ps
            result = subprocess.run(
                ["ps", "aux"], 
                capture_output=True, 
                text=True, 
                timeout=10
            )
            if result.returncode == 0:
                for line in result.stdout.split('\n'):
                    if vm_id in line and 'firecracker' in line.lower():
                        parts = line.split()
                        if len(parts) >= 4:
                            try:
                                metrics["cpu_usage"] = float(parts[2])  # %CPU
                                metrics["memory_usage"] = float(parts[3])  # %MEM
                            except (ValueError, IndexError):
                                pass
        except Exception as e:
            logger.debug(f"Could not get resource metrics: {e}")
        
        # Calculate uptime
        if "created" in vm_info:
            try:
                created_time = datetime.fromisoformat(vm_info["created"])
                uptime_seconds = (datetime.now() - created_time).total_seconds()
                metrics["uptime"] = uptime_seconds
            except Exception as e:
                logger.debug(f"Could not calculate uptime: {e}")
        
        return metrics

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
        # Script expects: launch <vm_name> [options]
        args = [
            "launch",
            vm_id,  # VM name as positional argument, not --name
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
            
            # Store creation logs
            self.vm_logs[vm_id] = {
                "creation_log": result["stdout"],
                "creation_errors": result["stderr"],
                "created_at": datetime.now().isoformat()
            }
            
            # Update metrics
            self.metrics["total_vms_created"] += 1
            self.metrics["current_vms"] = len(self.vms)
            
            logger.info(f"VM {vm_id} created successfully")
        else:
            # Update failure metrics
            self.metrics["failed_creations"] += 1
            
            # Store failure logs
            self.vm_logs[vm_id] = {
                "creation_log": result["stdout"],
                "creation_errors": result["stderr"],
                "created_at": datetime.now().isoformat(),
                "status": "failed"
            }
            
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
            self.vms[vm_id]["deleted_at"] = datetime.now().isoformat()
            
            # Update metrics
            self.metrics["total_vms_deleted"] += 1
            self.metrics["current_vms"] = len([v for v in self.vms.values() if v.get("status") != "deleted"])
        
        # Store deletion logs
        if vm_id not in self.vm_logs:
            self.vm_logs[vm_id] = {}
        
        self.vm_logs[vm_id]["deletion_log"] = result["stdout"]
        self.vm_logs[vm_id]["deletion_errors"] = result["stderr"]
        self.vm_logs[vm_id]["deleted_at"] = datetime.now().isoformat()
        
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
            "details": result,
            "metrics": self.metrics
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

    def get_vm_logs(self, vm_id):
        """Get comprehensive logs for a VM"""
        # Collect current logs
        current_logs = self.collect_vm_logs(vm_id)
        
        # Merge with stored logs
        stored_logs = self.vm_logs.get(vm_id, {})
        
        all_logs = {
            **stored_logs,
            **current_logs,
            "vm_id": vm_id
        }
        
        return all_logs

    def get_daemon_metrics(self):
        """Get overall daemon metrics"""
        metrics = self.metrics.copy()
        metrics["current_time"] = datetime.now().isoformat()
        metrics["uptime_seconds"] = (datetime.now() - datetime.fromisoformat(metrics["daemon_start_time"])).total_seconds()
        
        # Add per-VM metrics
        vm_metrics = {}
        for vm_id in self.vms:
            vm_metrics[vm_id] = self.get_vm_metrics(vm_id)
        
        metrics["vm_metrics"] = vm_metrics
        
        return metrics

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
            elif path == "/metrics":
                # Get daemon-wide metrics
                metrics = self.daemon.get_daemon_metrics()
                self.send_json_response(metrics)
            elif path.startswith("/vms/"):
                # Parse VM ID and action
                path_parts = path.strip("/").split("/")
                if len(path_parts) >= 2:
                    vm_id = path_parts[1]
                    if len(path_parts) == 2:
                        # GET /vms/{vm_id} - VM status
                        result = self.daemon.get_vm_status(vm_id)
                        self.send_json_response(result)
                    elif len(path_parts) == 3:
                        action = path_parts[2]
                        if action == "logs":
                            # GET /vms/{vm_id}/logs - VM logs
                            logs = self.daemon.get_vm_logs(vm_id)
                            self.send_json_response({
                                "success": True,
                                "vm_id": vm_id,
                                "logs": logs
                            })
                        elif action == "metrics":
                            # GET /vms/{vm_id}/metrics - VM metrics
                            metrics = self.daemon.get_vm_metrics(vm_id)
                            self.send_json_response({
                                "success": True,
                                "vm_id": vm_id,
                                "metrics": metrics
                            })
                        else:
                            self.send_error(404, f"Unknown action: {action}")
                    else:
                        self.send_error(404, "Invalid path")
                else:
                    self.send_error(404, "Invalid VM path")
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
    script_path = os.environ.get("FIRECRACKER_SCRIPT", "/app/firecracker-complete.sh")
    
    # Verify script exists
    if not os.path.exists(script_path):
        logger.error(f"Firecracker script not found at {script_path}")
        logger.info("Available files in /app:")
        try:
            for f in os.listdir("/app"):
                logger.info(f"  {f}")
        except:
            pass
        exit(1)
    
    # Initialize daemon
    daemon = FirecrackerVMDaemon(work_dir, script_path)
    
    # Create HTTP server
    handler = create_handler(daemon)
    server = HTTPServer(('0.0.0.0', port), handler)
    
    logger.info(f"Firecracker VM Daemon listening on port {port}")
    logger.info(f"Using script: {script_path}")
    logger.info(f"Work directory: {work_dir}")
    logger.info(f"API endpoints:")
    logger.info(f"  GET  /health          - Health check")
    logger.info(f"  GET  /vms             - List all VMs")
    logger.info(f"  GET  /metrics         - Get daemon metrics")
    logger.info(f"  POST /vms             - Create VM")
    logger.info(f"  GET  /vms/{{vm_id}}     - Get VM status")
    logger.info(f"  GET  /vms/{{vm_id}}/logs - Get VM logs")
    logger.info(f"  GET  /vms/{{vm_id}}/metrics - Get VM metrics")
    logger.info(f"  DELETE /vms/{{vm_id}}  - Delete VM")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down daemon...")
        server.shutdown()

if __name__ == "__main__":
    main() 