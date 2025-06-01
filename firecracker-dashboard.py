#!/usr/bin/env python3
"""
Firecracker VM Monitoring Dashboard
A web interface to monitor Firecracker VMs, daemon status, and startup logs
"""

import os
import json
import subprocess
import requests
import time
from datetime import datetime, timedelta
from flask import Flask, render_template_string, jsonify, request
import threading
import re

app = Flask(__name__)

# Configuration
DAEMON_URL = "http://192.168.21.32:30090"
KUBECONFIG = "/root/staging-kubeconfig.yaml"
REFRESH_INTERVAL = 5  # seconds

# Global cache for data
cache = {
    'last_update': None,
    'daemon_status': {},
    'vms': {},
    'daemon_logs': [],
    'arc_logs': [],
    'nodes': [],
    'daemon_metrics': {}
}

def run_kubectl(*args):
    """Run kubectl command and return output"""
    cmd = ["kubectl", f"--kubeconfig={KUBECONFIG}"] + list(args)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return result.stdout if result.returncode == 0 else None
    except Exception as e:
        print(f"kubectl error: {e}")
        return None

def sanitize_github_token(text):
    """Remove or mask GitHub tokens from text"""
    if not text:
        return text
    
    # Pattern to match GitHub tokens (typically start with ghp_, gho_, ghs_, or ghu_ or long alphanumeric strings)
    # Replace long alphanumeric strings that look like tokens
    text = re.sub(r'gh[pousr]_[A-Za-z0-9]{36}', '[GITHUB_TOKEN_HIDDEN]', text)
    text = re.sub(r'BNNAW[A-Z0-9]{60,}', '[GITHUB_TOKEN_HIDDEN]', text)
    text = re.sub(r'"github_token":\s*"[^"]{20,}"', '"github_token": "[HIDDEN]"', text)
    
    return text

def get_daemon_status():
    """Get daemon health and VM status"""
    try:
        # Health check
        health_resp = requests.get(f"{DAEMON_URL}/health", timeout=5)
        health = health_resp.json() if health_resp.status_code == 200 else {"status": "unhealthy"}
        
        # VM list
        vms_resp = requests.get(f"{DAEMON_URL}/vms", timeout=5)
        vms_data = vms_resp.json() if vms_resp.status_code == 200 else {"vms": {}}
        
        # Sanitize VM data to remove tokens
        if "vms" in vms_data:
            for vm_id, vm_info in vms_data["vms"].items():
                if "spec" in vm_info and "github_token" in vm_info["spec"]:
                    vm_info["spec"]["github_token"] = "[HIDDEN]"
        
        return {
            "health": health,
            "vms": vms_data,
            "timestamp": datetime.now().isoformat()
        }
    except Exception as e:
        return {
            "health": {"status": "error", "error": str(e)},
            "vms": {"vms": {}},
            "timestamp": datetime.now().isoformat()
        }

def get_daemon_logs():
    """Get recent daemon pod logs"""
    try:
        # Get daemon pod name
        pods_output = run_kubectl("-n", "arc-systems", "get", "pods", "-l", "app=firecracker-daemon", "-o", "name")
        if not pods_output:
            return ["No daemon pod found"]
        
        pod_name = pods_output.strip().split('/')[-1]
        
        # Get logs
        logs_output = run_kubectl("-n", "arc-systems", "logs", pod_name, "--tail=50")
        if logs_output:
            # Sanitize logs to remove tokens
            sanitized_logs = [sanitize_github_token(line) for line in logs_output.strip().split('\n')]
            return sanitized_logs
        return ["No logs available"]
    except Exception as e:
        return [f"Error getting logs: {e}"]

def get_arc_logs():
    """Get recent ARC controller logs"""
    try:
        # Get ARC pod name
        pods_output = run_kubectl("-n", "arc-systems", "get", "pods", "-l", "app.kubernetes.io/name=actions-runner-controller", "-o", "name")
        if not pods_output:
            return ["No ARC pod found (scaled down)"]
        
        pod_name = pods_output.strip().split('/')[-1]
        
        # Get logs with firecracker mentions
        logs_output = run_kubectl("-n", "arc-systems", "logs", pod_name, "--tail=100")
        if logs_output:
            lines = logs_output.strip().split('\n')
            # Filter for firecracker-related logs and sanitize tokens
            filtered_lines = [sanitize_github_token(line) for line in lines if 'firecracker' in line.lower() or 'vm' in line.lower()][:30]
            return filtered_lines
        return ["No relevant logs available"]
    except Exception as e:
        return [f"Error getting ARC logs: {e}"]

def get_node_info():
    """Get node information"""
    try:
        nodes_output = run_kubectl("get", "nodes", "-o", "json")
        if nodes_output:
            nodes_data = json.loads(nodes_output)
            nodes = []
            for node in nodes_data.get('items', []):
                node_info = {
                    'name': node['metadata']['name'],
                    'status': 'Ready' if any(c['type'] == 'Ready' and c['status'] == 'True' 
                                           for c in node['status']['conditions']) else 'NotReady',
                    'ip': next((addr['address'] for addr in node['status']['addresses'] 
                              if addr['type'] == 'InternalIP'), 'Unknown'),
                    'firecracker_capable': node['metadata'].get('labels', {}).get('arc.actions/firecracker-capable', 'false')
                }
                nodes.append(node_info)
            return nodes
        return []
    except Exception as e:
        return [{"name": "Error", "status": f"Error: {e}", "ip": "Unknown", "firecracker_capable": "false"}]

def get_vm_logs(vm_id):
    """Get startup logs for a specific VM"""
    try:
        # Get VM logs from daemon
        logs_resp = requests.get(f"{DAEMON_URL}/vms/{vm_id}/logs", timeout=5)
        if logs_resp.status_code == 200:
            logs_data = logs_resp.json()
            if logs_data.get('success') and 'logs' in logs_data:
                # Format the comprehensive logs
                logs = logs_data['logs']
                formatted_logs = ""
                
                # Add different log sections
                if logs.get('creation_log'):
                    formatted_logs += "=== VM Creation Log ===\n" + logs['creation_log'] + "\n\n"
                
                if logs.get('creation_errors'):
                    formatted_logs += "=== Creation Errors ===\n" + logs['creation_errors'] + "\n\n"
                
                if logs.get('startup_log'):
                    formatted_logs += "=== Startup Log ===\n" + logs['startup_log'] + "\n\n"
                
                if logs.get('firecracker_log'):
                    formatted_logs += "=== Firecracker Log ===\n" + logs['firecracker_log'] + "\n\n"
                
                if logs.get('vm_log'):
                    formatted_logs += "=== VM Process Log ===\n" + logs['vm_log'] + "\n\n"
                
                if logs.get('console_log'):
                    formatted_logs += "=== Console Log ===\n" + logs['console_log'] + "\n\n"
                
                if logs.get('deletion_log'):
                    formatted_logs += "=== Deletion Log ===\n" + logs['deletion_log'] + "\n\n"
                
                if not formatted_logs.strip():
                    formatted_logs = "No logs available for this VM"
                
                # Add timestamps
                if logs.get('created_at'):
                    formatted_logs = f"Created: {logs['created_at']}\n\n" + formatted_logs
                if logs.get('collected_at'):
                    formatted_logs += f"\nLogs collected: {logs['collected_at']}"
                
                return sanitize_github_token(formatted_logs)
            else:
                return f"Error in response format: {logs_data}"
        else:
            return f"Error getting logs: HTTP {logs_resp.status_code}"
    except Exception as e:
        return f"Error getting logs: {e}"

def get_vm_metrics(vm_id):
    """Get metrics for a specific VM"""
    try:
        metrics_resp = requests.get(f"{DAEMON_URL}/vms/{vm_id}/metrics", timeout=5)
        if metrics_resp.status_code == 200:
            metrics_data = metrics_resp.json()
            if metrics_data.get('success') and 'metrics' in metrics_data:
                return metrics_data['metrics']
        return None
    except Exception as e:
        print(f"Error getting metrics for {vm_id}: {e}")
        return None

def get_daemon_metrics():
    """Get overall daemon metrics"""
    try:
        metrics_resp = requests.get(f"{DAEMON_URL}/metrics", timeout=5)
        if metrics_resp.status_code == 200:
            return metrics_resp.json()
        return {}
    except Exception as e:
        print(f"Error getting daemon metrics: {e}")
        return {}

def update_cache():
    """Update cached data"""
    global cache
    cache['daemon_status'] = get_daemon_status()
    cache['daemon_logs'] = get_daemon_logs()
    cache['arc_logs'] = get_arc_logs()
    cache['nodes'] = get_node_info()
    cache['daemon_metrics'] = get_daemon_metrics()
    cache['last_update'] = datetime.now()

def background_updater():
    """Background thread to update cache periodically"""
    while True:
        try:
            update_cache()
            time.sleep(REFRESH_INTERVAL)
        except Exception as e:
            print(f"Background update error: {e}")
            time.sleep(REFRESH_INTERVAL)

# Start background updater
update_thread = threading.Thread(target=background_updater, daemon=True)
update_thread.start()

# HTML Template with enhanced VM section and logs
HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>Firecracker VM Dashboard</title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        body { 
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; 
            margin: 0; 
            padding: 20px; 
            background-color: #f5f5f5;
        }
        .container { max-width: 1400px; margin: 0 auto; }
        .header { 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white; 
            padding: 20px; 
            border-radius: 10px; 
            margin-bottom: 20px;
            text-align: center;
        }
        .grid { 
            display: grid; 
            grid-template-columns: repeat(auto-fit, minmax(400px, 1fr)); 
            gap: 20px; 
        }
        .card { 
            background: white; 
            padding: 20px; 
            border-radius: 10px; 
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            border-left: 4px solid #667eea;
        }
        .status { 
            display: inline-block; 
            padding: 4px 12px; 
            border-radius: 20px; 
            font-size: 12px; 
            font-weight: bold;
            text-transform: uppercase;
        }
        .status.healthy { background-color: #d4edda; color: #155724; }
        .status.unhealthy { background-color: #f8d7da; color: #721c24; }
        .status.error { background-color: #fff3cd; color: #856404; }
        .status.running { background-color: #d1ecf1; color: #0c5460; }
        .status.stopped { background-color: #f8d7da; color: #721c24; }
        .logs { 
            background-color: #2d3748; 
            color: #e2e8f0; 
            padding: 15px; 
            border-radius: 5px; 
            font-family: 'Courier New', monospace; 
            font-size: 12px; 
            max-height: 400px; 
            overflow-y: auto;
            white-space: pre-wrap;
        }
        .vm-item { 
            background-color: #f8f9fa; 
            padding: 15px; 
            margin: 5px 0; 
            border-radius: 5px;
            border-left: 3px solid #6c757d;
            position: relative;
        }
        .vm-item.running { border-left-color: #28a745; }
        .vm-item.stopped { border-left-color: #dc3545; }
        .vm-actions {
            position: absolute;
            top: 10px;
            right: 10px;
        }
        .vm-logs-container {
            margin-top: 10px;
            display: none;
        }
        .vm-logs {
            background-color: #2d3748;
            color: #e2e8f0;
            padding: 10px;
            border-radius: 4px;
            font-family: 'Courier New', monospace;
            font-size: 11px;
            max-height: 200px;
            overflow-y: auto;
            white-space: pre-wrap;
        }
        .pagination {
            text-align: center;
            margin: 15px 0;
        }
        .pagination button {
            margin: 0 5px;
            padding: 8px 12px;
            border: 1px solid #ddd;
            background: white;
            cursor: pointer;
            border-radius: 4px;
        }
        .pagination button.active {
            background: #007bff;
            color: white;
        }
        .pagination button:disabled {
            background: #f8f9fa;
            cursor: not-allowed;
            opacity: 0.6;
        }
        .vm-overview-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
        }
        .refresh-time { 
            text-align: center; 
            color: #6c757d; 
            margin-top: 20px; 
            font-size: 14px;
        }
        .metric { 
            display: flex; 
            justify-content: space-between; 
            margin: 10px 0; 
            padding: 8px 0;
            border-bottom: 1px solid #e9ecef;
        }
        .metric:last-child { border-bottom: none; }
        .node-item {
            background-color: #f8f9fa;
            padding: 15px;
            margin: 10px 0;
            border-radius: 8px;
            border-left: 4px solid #6c757d;
        }
        .node-item.firecracker { border-left-color: #fd7e14; }
        .actions { margin-top: 15px; }
        .btn {
            display: inline-block;
            padding: 6px 12px;
            margin: 2px;
            text-decoration: none;
            border-radius: 4px;
            font-size: 12px;
            border: none;
            cursor: pointer;
        }
        .btn-primary { background-color: #007bff; color: white; }
        .btn-success { background-color: #28a745; color: white; }
        .btn-danger { background-color: #dc3545; color: white; }
        .btn-info { background-color: #17a2b8; color: white; }
        .btn-sm { padding: 4px 8px; font-size: 10px; }
        .full-width { grid-column: 1 / -1; }
        .vm-info { margin-bottom: 10px; }
        .vm-title { font-weight: bold; font-size: 14px; margin-bottom: 5px; }
    </style>
    <script>
        let currentPage = 1;
        const vmsPerPage = 5;
        let allVMs = {};
        
        function refreshData() {
            fetch('/api/data')
                .then(response => response.json())
                .then(data => {
                    updateDisplay(data);
                    allVMs = data.daemon_status.vms.vms || {};
                    displayVMs();
                })
                .catch(error => console.error('Error:', error));
        }
        
        function updateDisplay(data) {
            // Update timestamp
            document.getElementById('last-update').textContent = 
                'Last updated: ' + new Date(data.last_update).toLocaleString();
            
            // Update daemon status
            const healthStatus = data.daemon_status.health.status;
            document.getElementById('daemon-health').className = 'status ' + healthStatus;
            document.getElementById('daemon-health').textContent = healthStatus;
            
            // Update VM count
            const vmCount = Object.keys(data.daemon_status.vms.vms || {}).length;
            document.getElementById('vm-count').textContent = vmCount;
            
            // Update logs
            document.getElementById('daemon-logs').textContent = data.daemon_logs.join('\\n');
            document.getElementById('arc-logs').textContent = data.arc_logs.join('\\n');
        }
        
        function displayVMs() {
            const vmList = Object.entries(allVMs);
            const totalPages = Math.ceil(vmList.length / vmsPerPage);
            const startIdx = (currentPage - 1) * vmsPerPage;
            const endIdx = startIdx + vmsPerPage;
            const currentVMs = vmList.slice(startIdx, endIdx);
            
            // Update VM container
            const vmContainer = document.getElementById('vm-container');
            if (currentVMs.length === 0) {
                vmContainer.innerHTML = '<p>No VMs currently running</p>';
            } else {
                vmContainer.innerHTML = currentVMs.map(([vmId, vmInfo]) => `
                    <div class="vm-item ${vmInfo.status}">
                        <div class="vm-actions">
                            <button class="btn btn-info btn-sm" onclick="toggleVMLogs('${vmId}')">
                                📋 Logs
                            </button>
                            <button class="btn btn-success btn-sm" onclick="toggleVMMetrics('${vmId}')">
                                📊 Metrics
                            </button>
                            <button class="btn btn-danger btn-sm" onclick="deleteVM('${vmId}')">
                                🗑️ Delete
                            </button>
                        </div>
                        <div class="vm-info">
                            <div class="vm-title">${vmId}</div>
                            <span class="status ${vmInfo.status}">${vmInfo.status}</span>
                            <br>
                            <small>Created: ${vmInfo.created}</small>
                            <br>
                            <small>Networking: ${vmInfo.networking}</small>
                            <br>
                            <small>Memory: ${vmInfo.spec.memory_mb}MB, vCPUs: ${vmInfo.spec.vcpus}</small>
                        </div>
                        <div id="logs-${vmId}" class="vm-logs-container">
                            <div class="vm-logs" id="logs-content-${vmId}">Loading logs...</div>
                        </div>
                        <div id="metrics-${vmId}" class="vm-logs-container">
                            <div class="vm-logs" id="metrics-content-${vmId}">Loading metrics...</div>
                        </div>
                    </div>
                `).join('');
            }
            
            // Update pagination
            updatePagination(totalPages);
        }
        
        function updatePagination(totalPages) {
            const paginationContainer = document.getElementById('pagination-container');
            if (totalPages <= 1) {
                paginationContainer.innerHTML = '';
                return;
            }
            
            let paginationHTML = `
                <button onclick="changePage(${currentPage - 1})" ${currentPage <= 1 ? 'disabled' : ''}>
                    ← Previous
                </button>
            `;
            
            for (let i = 1; i <= totalPages; i++) {
                paginationHTML += `
                    <button onclick="changePage(${i})" ${i === currentPage ? 'class="active"' : ''}>
                        ${i}
                    </button>
                `;
            }
            
            paginationHTML += `
                <button onclick="changePage(${currentPage + 1})" ${currentPage >= totalPages ? 'disabled' : ''}>
                    Next →
                </button>
            `;
            
            paginationContainer.innerHTML = paginationHTML;
        }
        
        function changePage(newPage) {
            const totalPages = Math.ceil(Object.keys(allVMs).length / vmsPerPage);
            if (newPage >= 1 && newPage <= totalPages) {
                currentPage = newPage;
                displayVMs();
            }
        }
        
        function toggleVMLogs(vmId) {
            const logsContainer = document.getElementById(`logs-${vmId}`);
            const logsContent = document.getElementById(`logs-content-${vmId}`);
            
            if (logsContainer.style.display === 'none' || logsContainer.style.display === '') {
                logsContainer.style.display = 'block';
                
                // Fetch logs
                fetch(`/api/vm-logs/${vmId}`)
                    .then(response => response.json())
                    .then(data => {
                        logsContent.textContent = data.logs || 'No logs available';
                    })
                    .catch(error => {
                        logsContent.textContent = 'Error loading logs: ' + error;
                    });
            } else {
                logsContainer.style.display = 'none';
            }
        }
        
        function toggleVMMetrics(vmId) {
            const metricsContainer = document.getElementById(`metrics-${vmId}`);
            const metricsContent = document.getElementById(`metrics-content-${vmId}`);
            
            if (metricsContainer.style.display === 'none' || metricsContainer.style.display === '') {
                metricsContainer.style.display = 'block';
                
                // Fetch metrics
                fetch(`/api/vm-metrics/${vmId}`)
                    .then(response => response.json())
                    .then(data => {
                        metricsContent.textContent = JSON.stringify(data.metrics) || 'No metrics available';
                    })
                    .catch(error => {
                        metricsContent.textContent = 'Error loading metrics: ' + error;
                    });
            } else {
                metricsContainer.style.display = 'none';
            }
        }
        
        function deleteVM(vmId) {
            if (confirm(`Are you sure you want to delete VM: ${vmId}?`)) {
                fetch(`/api/delete-vm/${vmId}`, { method: 'DELETE' })
                    .then(response => response.json())
                    .then(data => {
                        alert('VM Deletion: ' + (data.success ? 'Success' : 'Failed - ' + data.message));
                        refreshData();
                    });
            }
        }
        
        function createVM() {
            const vmId = 'test-vm-' + Date.now();
            fetch('/api/create-vm', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    vm_id: vmId,
                    github_url: 'https://github.com/aakash-test-workflow',
                    github_token: 'test-token',
                    labels: 'test,dashboard',
                    memory_mb: 2048,
                    vcpus: 2
                })
            })
            .then(response => response.json())
            .then(data => {
                alert('VM Creation: ' + (data.success ? 'Success' : 'Failed - ' + data.message));
                refreshData();
            });
        }
        
        // Auto-refresh every 5 seconds
        setInterval(refreshData, 5000);
        
        // Initial load
        document.addEventListener('DOMContentLoaded', function() {
            refreshData();
        });
    </script>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔥 Firecracker VM Dashboard</h1>
            <p>Real-time monitoring for ARC Firecracker VMs on tenki-staging-runner-2</p>
        </div>
        
        <div class="grid">
            <div class="card">
                <h3>🏥 Daemon Health</h3>
                <div class="metric">
                    <span>Status:</span>
                    <span id="daemon-health" class="status {{ daemon_status.health.status }}">
                        {{ daemon_status.health.status }}
                    </span>
                </div>
                <div class="metric">
                    <span>Endpoint:</span>
                    <span>{{ daemon_url }}</span>
                </div>
                <div class="metric">
                    <span>Active VMs:</span>
                    <span id="vm-count">{{ daemon_status.vms.vms|length }}</span>
                </div>
                <div class="actions">
                    <button class="btn btn-success" onclick="createVM()">Create Test VM</button>
                    <button class="btn btn-primary" onclick="refreshData()">Refresh</button>
                </div>
            </div>
            
            <div class="card">
                <h3>📊 Daemon Metrics</h3>
                <div class="metric">
                    <span>Total Created:</span>
                    <span>{{ daemon_metrics.get('total_vms_created', 0) }}</span>
                </div>
                <div class="metric">
                    <span>Total Deleted:</span>
                    <span>{{ daemon_metrics.get('total_vms_deleted', 0) }}</span>
                </div>
                <div class="metric">
                    <span>Failed Creations:</span>
                    <span>{{ daemon_metrics.get('failed_creations', 0) }}</span>
                </div>
                <div class="metric">
                    <span>Daemon Uptime:</span>
                    <span id="daemon-uptime">{{ "%.1f"|format(daemon_metrics.get('uptime_seconds', 0) / 3600) }}h</span>
                </div>
                <div class="actions">
                    <a href="{{ daemon_url }}/metrics" target="_blank" class="btn btn-info">View Raw Metrics</a>
                </div>
            </div>
            
            <div class="card">
                <h3>🖥️ Cluster Nodes</h3>
                {% for node in nodes %}
                <div class="node-item {% if node.firecracker_capable == 'true' %}firecracker{% endif %}">
                    <strong>{{ node.name }}</strong>
                    <span class="status {{ node.status.lower() }}">{{ node.status }}</span>
                    <br>
                    <small>IP: {{ node.ip }}</small>
                    {% if node.firecracker_capable == 'true' %}
                    <br><small>🔥 Firecracker Capable</small>
                    {% endif %}
                </div>
                {% endfor %}
            </div>
        </div>
        
        <div class="grid">
            <div class="card full-width">
                <div class="vm-overview-header">
                    <h3>📊 VM Overview</h3>
                    <div>
                        <span>Total VMs: <strong id="total-vm-count">{{ daemon_status.vms.vms|length }}</strong></span>
                    </div>
                </div>
                
                <div id="vm-container">
                    <!-- VMs will be populated by JavaScript -->
                </div>
                
                <div class="pagination" id="pagination-container">
                    <!-- Pagination will be populated by JavaScript -->
                </div>
            </div>
        </div>
        
        <div class="grid">
            <div class="card">
                <h3>🔧 Quick Actions</h3>
                <div class="actions">
                    <a href="{{ daemon_url }}/health" target="_blank" class="btn btn-primary">Check Health</a>
                    <a href="{{ daemon_url }}/vms" target="_blank" class="btn btn-primary">View VMs JSON</a>
                    <button class="btn btn-success" onclick="createVM()">Create VM</button>
                </div>
                <h4>Test Commands:</h4>
                <div class="logs">curl {{ daemon_url }}/health
curl {{ daemon_url }}/vms
curl -X POST {{ daemon_url }}/vms -H "Content-Type: application/json" -d '{
  "vm_id": "test-vm-$(date +%s)",
  "github_url": "https://github.com/aakash-test-workflow",
  "github_token": "test-token",
  "labels": "test",
  "memory_mb": 2048,
  "vcpus": 2
}'</div>
            </div>
        </div>
        
        <div class="grid">
            <div class="card full-width">
                <h3>📋 Daemon Logs</h3>
                <div id="daemon-logs" class="logs">{{ daemon_logs|join('\\n') }}</div>
            </div>
        </div>
        
        <div class="grid">
            <div class="card full-width">
                <h3>🎯 ARC Controller Logs (Firecracker Related)</h3>
                <div id="arc-logs" class="logs">{{ arc_logs|join('\\n') }}</div>
            </div>
        </div>
        
        <div id="last-update" class="refresh-time">
            Last updated: {{ last_update.strftime('%Y-%m-%d %H:%M:%S') if last_update else 'Never' }}
        </div>
    </div>
</body>
</html>
"""

@app.route('/')
def dashboard():
    """Main dashboard page"""
    return render_template_string(HTML_TEMPLATE, 
                                daemon_url=DAEMON_URL,
                                daemon_status=cache['daemon_status'],
                                daemon_logs=cache['daemon_logs'],
                                arc_logs=cache['arc_logs'],
                                nodes=cache['nodes'],
                                daemon_metrics=cache['daemon_metrics'],
                                last_update=cache['last_update'])

@app.route('/api/data')
def api_data():
    """API endpoint for live data"""
    return jsonify({
        'daemon_status': cache['daemon_status'],
        'daemon_logs': cache['daemon_logs'],
        'arc_logs': cache['arc_logs'],
        'nodes': cache['nodes'],
        'daemon_metrics': cache['daemon_metrics'],
        'last_update': cache['last_update'].isoformat() if cache['last_update'] else None
    })

@app.route('/api/create-vm', methods=['POST'])
def create_vm():
    """API endpoint to create a test VM"""
    try:
        vm_spec = request.get_json()
        response = requests.post(f"{DAEMON_URL}/vms", json=vm_spec, timeout=10)
        return jsonify(response.json())
    except Exception as e:
        return jsonify({"success": False, "message": str(e)})

@app.route('/api/vm-logs/<vm_id>')
def api_vm_logs(vm_id):
    """API endpoint to get VM startup logs"""
    logs = get_vm_logs(vm_id)
    return jsonify({"vm_id": vm_id, "logs": logs})

@app.route('/api/vm-metrics/<vm_id>')
def api_vm_metrics(vm_id):
    """API endpoint to get VM metrics"""
    metrics = get_vm_metrics(vm_id)
    return jsonify({"vm_id": vm_id, "metrics": metrics})

@app.route('/api/delete-vm/<vm_id>', methods=['DELETE'])
def api_delete_vm(vm_id):
    """API endpoint to delete a VM"""
    try:
        response = requests.delete(f"{DAEMON_URL}/vms/{vm_id}", timeout=10)
        return jsonify(response.json())
    except Exception as e:
        return jsonify({"success": False, "message": str(e)})

if __name__ == '__main__':
    print(f"Starting Firecracker Dashboard...")
    print(f"Daemon URL: {DAEMON_URL}")
    print(f"Dashboard will be available at: http://localhost:5000")
    print(f"To access remotely, use port forwarding:")
    print(f"  kubectl port-forward -n default pod/dashboard-pod 5000:5000")
    
    # Initial cache update
    update_cache()
    
    app.run(host='0.0.0.0', port=5000, debug=False) 