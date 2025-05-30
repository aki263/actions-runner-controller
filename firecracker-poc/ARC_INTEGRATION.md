# ARC (Actions Runner Controller) Integration

This document explains the ARC integration features added to the Firecracker Complete solution for ephemeral GitHub Actions runners.

## Overview

The ARC integration enables Firecracker VMs to act as ephemeral runners that:
- Report status back to an ARC controller
- Monitor job lifecycle (start, running, completion)
- Automatically shutdown/reboot after job completion
- Handle scale-down events from the controller
- Provide detailed VM metrics and health status

## ARC Mode Features

### 1. **Job Lifecycle Monitoring**
- Detects when jobs start and complete
- Monitors runner process health
- Automatic restart on runner failure
- Reports job status to ARC controller

### 2. **Status Reporting**
- Periodic status updates to ARC controller
- VM metrics (CPU, memory, disk usage)
- Runner state (idle, running, offline)
- Network connectivity status

### 3. **Webhook Handler**
- Listens for scale-down events
- Handles reboot commands
- Graceful shutdown on scale events
- Simple HTTP server for controller communication

### 4. **Ephemeral Mode**
- Automatic VM shutdown after job completion
- Perfect for cost optimization
- Prevents resource waste
- Integrates with ARC scaling policies

## Usage

### Basic ARC Mode
```bash
./firecracker-complete.sh launch \
  --arc-mode \
  --github-url https://github.com/org/repo \
  --github-token ghp_xxx \
  --arc-controller-url http://arc-controller:8080
```

### Ephemeral Mode (Auto-shutdown)
```bash
./firecracker-complete.sh launch \
  --arc-mode \
  --ephemeral-mode \
  --github-url https://github.com/org/repo \
  --github-token ghp_xxx \
  --arc-controller-url http://arc-controller:8080
```

### With Custom Labels and Resources
```bash
./firecracker-complete.sh launch \
  --arc-mode \
  --ephemeral-mode \
  --labels "firecracker,ubuntu-24.04,ephemeral" \
  --memory 4096 \
  --cpus 4 \
  --github-url https://github.com/org/repo \
  --github-token ghp_xxx \
  --arc-controller-url http://arc-controller:8080
```

## ARC Controller API

The VM communicates with the ARC controller using these endpoints:

### Status Reporting
```
POST /api/v1/runners/{runner_name}/status
Content-Type: application/json

{
  "runner_name": "runner-123456",
  "status": "running|idle|starting|offline|completed|shutting_down",
  "message": "Human readable status message",
  "timestamp": "2024-01-01T12:00:00Z",
  "vm_ip": "172.16.0.10",
  "uptime": "up 5 minutes",
  "load": "0.15 0.10 0.05",
  "memory_usage": "45.2",
  "disk_usage": "15"
}
```

### Webhook Events
The VM listens on port 8080 for webhook events:

```
POST http://vm-ip:8080/webhook
Content-Type: application/json

{
  "action": "scale_down|reboot",
  "runner_name": "runner-123456",
  "timestamp": "2024-01-01T12:00:00Z"
}
```

## Status States

| Status | Description | Action |
|--------|-------------|--------|
| `starting` | VM booting, runner configuring | Wait |
| `ready` | Runner configured, waiting for jobs | Available |
| `idle` | Runner active, no job running | Available |
| `running` | Job in progress | Busy |
| `completed` | Job finished | Ready for next or shutdown |
| `shutting_down` | VM shutting down (ephemeral mode) | Cleanup |
| `restarting` | Runner process restarting | Wait |
| `failed` | Setup or runner failure | Investigate |
| `offline` | Runner not responding | Restart VM |

## Monitoring and Logs

### Log Files
- `/var/log/setup-runner.log` - Runner setup and configuration
- `/var/log/arc-webhook.log` - Webhook events and responses  
- `/var/log/arc-status.log` - Status reporting activity
- `/var/log/job-monitor.log` - Job lifecycle monitoring

### Monitoring Scripts
- `/usr/local/bin/monitor-jobs.sh` - Job lifecycle monitoring
- `/usr/local/bin/arc-webhook-handler.sh` - Webhook event handler
- `/usr/local/bin/arc-status-reporter.sh` - Status reporting

### Check Status
```bash
# Check runner status
./firecracker-complete.sh status

# Check specific runner
./firecracker-complete.sh check-runner runner-name

# SSH into VM to check logs
ssh -i instances/vm-id/ssh_key runner@vm-ip
tail -f /var/log/setup-runner.log
```

## Environment Variables

The following environment variables can be set in the VM:

| Variable | Default | Description |
|----------|---------|-------------|
| `ARC_CONTROLLER_URL` | - | ARC controller base URL |
| `ARC_WEBHOOK_PORT` | 8080 | Port for webhook listener |
| `ARC_REPORT_INTERVAL` | 30 | Status reporting interval (seconds) |
| `RUNNER_NAME` | hostname | Runner name for identification |

## Integration with Kubernetes ARC

This solution can integrate with the official Actions Runner Controller for Kubernetes:

1. **Deploy ARC Controller** in your Kubernetes cluster
2. **Configure Firecracker VMs** to report to ARC controller
3. **Use Ephemeral Mode** for cost-effective scaling
4. **Monitor via ARC Dashboard** for centralized management

### Example ARC Controller Configuration
```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: firecracker-runners
spec:
  replicas: 0  # Start with 0, scale via webhooks
  template:
    spec:
      repository: org/repo
      labels:
        - firecracker
        - ubuntu-24.04
      ephemeral: true
      # Custom webhook endpoint for Firecracker VMs
      webhook:
        url: "http://firecracker-manager:8080/scale"
```

## Comparison: Container vs Firecracker ARC

| Feature | Container ARC | Firecracker ARC |
|---------|---------------|-----------------|
| **Isolation** | Process-level | VM-level (stronger) |
| **Startup Time** | ~10s | ~30s |
| **Resource Overhead** | Low | Medium |
| **Security** | Good | Excellent |
| **Kernel Access** | Limited | Full |
| **Nested Virtualization** | No | Yes |
| **Cost** | Lower | Medium |
| **Use Case** | Standard CI/CD | Security-critical, kernel work |

## Troubleshooting

### Common Issues

1. **Status not reporting**
   - Check `ARC_CONTROLLER_URL` is set
   - Verify network connectivity to controller
   - Check `/var/log/arc-status.log`

2. **Webhook not responding**
   - Verify port 8080 is accessible
   - Check firewall rules
   - Review `/var/log/arc-webhook.log`

3. **Jobs not detected**
   - Ensure runner is properly configured
   - Check GitHub runner registration
   - Monitor `/var/log/job-monitor.log`

4. **VM not shutting down**
   - Verify `--ephemeral-mode` flag was used
   - Check job completion detection
   - Review shutdown logs

### Debug Commands
```bash
# Check all processes
ps aux | grep -E "(runner|monitor|webhook)"

# Test webhook endpoint
curl -X POST http://vm-ip:8080/webhook \
  -H "Content-Type: application/json" \
  -d '{"action":"reboot"}'

# Manual status report
curl -X POST http://arc-controller:8080/api/v1/runners/test/status \
  -H "Content-Type: application/json" \
  -d '{"status":"test","message":"manual test"}'
```

## Future Enhancements

- **Auto-scaling integration** with cloud providers
- **Multi-architecture support** (ARM64)
- **Custom job routing** based on labels
- **Advanced metrics collection** (Prometheus)
- **Distributed runner pools** across regions
- **Job queue optimization** and prioritization 