# GitHub Runner Logs and Debugging Guide

## **📋 Log File Locations**

### **🏃 GitHub Actions Runner Logs**

#### **Systemd Service Logs**
```bash
# Main runner service logs
sudo journalctl -u github-runner -f

# Show recent logs with timestamps
sudo journalctl -u github-runner --since "10 minutes ago"

# Show all logs since boot
sudo journalctl -u github-runner --since boot

# Show logs with priority (errors/warnings)
sudo journalctl -u github-runner -p err..alert
```

#### **Runner Application Logs**
```bash
# Runner application directory
cd /opt/runner

# Runner output logs (if service is running)
tail -f /opt/runner/*.log

# Specific log files in runner directory
ls -la /opt/runner/_diag/
```

### **🔧 Setup and Configuration Logs**

#### **Cloud-Init Logs**
```bash
# Cloud-init final stage logs
sudo journalctl -u cloud-final -f

# Cloud-init configuration logs
tail -f /var/log/cloud-init.log
tail -f /var/log/cloud-init-output.log

# Check cloud-init status
cloud-init status --long
```

#### **Setup Script Logs**
```bash
# Our custom setup script logs
tail -f /var/log/setup-runner.log

# ARC mode logs (if using ARC mode)
tail -f /var/log/arc-runner.log

# Docker mode logs (if using Docker mode) 
tail -f /var/log/docker-runner.log

# Job monitoring logs (ARC mode)
tail -f /var/log/job-monitor.log
```

### **🐳 Docker Logs**

#### **Docker Service Logs**
```bash
# Docker daemon logs
sudo journalctl -u docker -f

# Docker system info
docker system info

# Docker network inspection
docker network ls
docker network inspect bridge
```

#### **Container Logs**
```bash
# List running containers
docker ps

# View logs for specific container
docker logs <container_id>

# Follow logs for container
docker logs -f <container_id>
```

### **🌐 System and Network Logs**

#### **System Logs**
```bash
# General system logs
sudo journalctl -f

# Kernel messages
dmesg | tail -20

# Network interface logs
sudo journalctl -u systemd-networkd -f
```

#### **Network Configuration**
```bash
# Show network interfaces
ip addr show

# Show routing table
ip route show

# Show iptables rules (for Docker networking)
sudo iptables -L -n
sudo iptables -t nat -L -n
```

## **🔍 Common Debugging Commands**

### **Check Runner Status**
```bash
# Quick status check
systemctl status github-runner

# Check if runner process is running
pgrep -f "actions.runner"
ps aux | grep -E "(actions\.runner|Runner\.Worker)"

# Check runner configuration
cat /opt/runner/.runner | jq .
```

### **Check Docker Status**
```bash
# Docker service status
systemctl status docker

# Test Docker functionality
docker run --rm hello-world

# Check Docker networking
docker network ls
docker run --rm alpine:latest ping -c 3 8.8.8.8
```

### **Check Environment Variables**
```bash
# Show GitHub-related environment variables
env | grep -E '^(GITHUB_|RUNNER_)'

# Check environment file
cat /etc/environment
```

## **🐛 Common Issues and Solutions**

### **1. Runner Not Starting**

**Check logs:**
```bash
sudo journalctl -u github-runner --lines=50
cat /var/log/setup-runner.log
```

**Common causes:**
- Invalid registration token (expired)
- Network connectivity issues
- Missing environment variables
- Docker not running

### **2. Docker Networking Issues**

**Check networking:**
```bash
# Check IPv4 forwarding
cat /proc/sys/net/ipv4/ip_forward  # Should be 1

# Check bridge netfilter
lsmod | grep br_netfilter

# Check Docker daemon
docker info | grep -E "(Cgroup|Storage|Network)"
```

**Fix networking:**
```bash
# Reload kernel modules
sudo modprobe br_netfilter
sudo modprobe overlay

# Apply sysctl settings
sudo sysctl -p /etc/sysctl.d/99-docker.conf

# Restart Docker
sudo systemctl restart docker
```

### **3. Cloud-Init Issues**

**Check cloud-init status:**
```bash
cloud-init status --long
sudo journalctl -u cloud-init -u cloud-config -u cloud-final
```

**Common issues:**
- YAML syntax errors
- Network not ready during cloud-init
- Environment variables not set

### **4. Job Execution Issues**

**Check job logs:**
```bash
# Runner worker process logs
sudo journalctl -u github-runner | grep -E "(Worker|Job)"

# Check for active jobs
pgrep -f "Runner.Worker"

# ARC mode job monitoring
tail -f /var/log/job-monitor.log
```

## **📊 Real-Time Monitoring**

### **Multi-Log Monitoring**
```bash
# Monitor multiple logs simultaneously
sudo multitail \
  /var/log/setup-runner.log \
  -I /var/log/cloud-init-output.log \
  -I /var/log/syslog
```

### **Live System Monitoring**
```bash
# Monitor system resources
htop

# Monitor network activity
sudo netstat -tupln

# Monitor Docker events
docker events
```

## **🔧 Log Collection Script**

Save this as `collect-logs.sh` for troubleshooting:

```bash
#!/bin/bash
LOGDIR="/tmp/runner-debug-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"

echo "Collecting runner logs to: $LOGDIR"

# System info
uname -a > "$LOGDIR/system-info.txt"
cat /etc/os-release >> "$LOGDIR/system-info.txt"
uptime >> "$LOGDIR/system-info.txt"

# Service status
systemctl status github-runner --no-pager > "$LOGDIR/runner-status.txt"
systemctl status docker --no-pager > "$LOGDIR/docker-status.txt"

# Service logs
sudo journalctl -u github-runner --no-pager > "$LOGDIR/runner-service.log"
sudo journalctl -u docker --no-pager > "$LOGDIR/docker-service.log"
sudo journalctl -u cloud-final --no-pager > "$LOGDIR/cloud-init.log"

# Application logs
cp /var/log/setup-runner.log "$LOGDIR/" 2>/dev/null || true
cp /var/log/cloud-init-output.log "$LOGDIR/" 2>/dev/null || true
cp /opt/runner/_diag/*.log "$LOGDIR/" 2>/dev/null || true

# Configuration
env | grep -E '^(GITHUB_|RUNNER_)' > "$LOGDIR/environment.txt"
cat /etc/environment > "$LOGDIR/etc-environment.txt" 2>/dev/null || true
cat /opt/runner/.runner > "$LOGDIR/runner-config.json" 2>/dev/null || true

# Network info
ip addr show > "$LOGDIR/network-interfaces.txt"
ip route show > "$LOGDIR/routing-table.txt"
sudo iptables -L -n > "$LOGDIR/iptables.txt"
docker network ls > "$LOGDIR/docker-networks.txt" 2>/dev/null || true

echo "Logs collected in: $LOGDIR"
echo "Compress with: tar -czf runner-logs.tar.gz -C /tmp $(basename $LOGDIR)"
```

## **🚀 Quick SSH Access**

From the host, you can easily SSH into the VM to check logs:

```bash
# SSH into VM (from host)
ssh -i instances/*/ssh_key runner@<vm-ip>

# Quick log check
ssh -i instances/*/ssh_key runner@<vm-ip> 'sudo journalctl -u github-runner --lines=20'

# Quick status check
ssh -i instances/*/ssh_key runner@<vm-ip> 'systemctl status github-runner && docker ps'
```

This comprehensive logging guide should help you debug any issues with the GitHub Actions runners! 