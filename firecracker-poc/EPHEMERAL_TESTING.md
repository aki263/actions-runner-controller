# Ephemeral VM Testing Guide

This guide explains how to test ephemeral VMs and ARC mode without a running ARC controller.

## Testing Ephemeral VMs

### 1. Start VM Monitor (Host Side)
```bash
# Terminal 1: Start the ephemeral VM monitor
./firecracker-complete.sh monitor-ephemeral
```

This starts:
- **Destruction server** on port 8081 (listens for VM completion signals)
- **VM monitor** that checks for shutdown VMs and completion signals
- **Automatic cleanup** of stopped ephemeral VMs

### 2. Launch Ephemeral VM (Terminal 2)
```bash
# Terminal 2: Launch ephemeral VM without ARC controller
./firecracker-complete.sh launch \
  --ephemeral-mode \
  --name "ephemeral-test-$(date +%s)" \
  --github-url https://github.com/org/repo \
  --github-token ghp_your_token

# With ARC mode (no controller needed for testing)
./firecracker-complete.sh launch \
  --arc-mode \
  --ephemeral-mode \
  --name "arc-ephemeral-$(date +%s)" \
  --github-url https://github.com/org/repo \
  --github-token ghp_your_token
```

### 3. Simulate Job Completion
```bash
# Option A: SSH into VM and create completion signal
ssh -i instances/vm-id/ssh_key runner@vm-ip
echo "job_completed:$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /tmp/ephemeral-cleanup
# VM will shutdown automatically after a few seconds

# Option B: Send destruction request to host
curl -X POST http://localhost:8081/vm/destroy \
  -H "Content-Type: application/json" \
  -d '{"vm_id":"ephemeral-test-123","reason":"job_completed"}'
```

## ARC Mode Without Controller

### Expected Behavior
When running ARC mode without an actual controller:

1. **Graceful Fallback**: ✅
   - Status reports fail gracefully with timeout
   - Logs show "ARC controller unreachable - running in offline mode"
   - VM continues to operate normally

2. **Offline Status Logging**: ✅
   - Status updates stored in `/var/log/arc-status-offline.log`
   - Format: `timestamp|status|message`
   - Can be replayed to controller later

3. **Job Monitoring**: ✅
   - Continues to monitor for job start/completion
   - Logs job lifecycle events
   - Ephemeral shutdown still works

### Example Logs (No Controller)
```
[2024-05-30 10:30:15] STATUS: starting - VM starting up
[2024-05-30 10:30:15] ⚠️  ARC controller unreachable - running in offline mode
[2024-05-30 10:30:45] STATUS: ready - Runner configured and ready
[2024-05-30 10:30:45] ⚠️  ARC controller unreachable - running in offline mode
[2024-05-30 10:35:12] STATUS: running - Executing job
[2024-05-30 10:37:28] STATUS: completed - Job finished
[2024-05-30 10:37:30] STATUS: shutting_down - VM shutting down (ephemeral mode)
```

## Testing Commands

### Monitor VM Status
```bash
# Check all VMs
./firecracker-complete.sh list

# Check specific VM status
./firecracker-complete.sh status

# Check runner status
./firecracker-complete.sh check-runner
```

### Manual VM Destruction
```bash
# Stop specific VMs
./firecracker-complete.sh stop pattern-name

# Stop all VMs
./firecracker-complete.sh cleanup
```

### Check Logs
```bash
# SSH into VM to check logs
ssh -i instances/vm-id/ssh_key runner@vm-ip

# Inside VM:
tail -f /var/log/setup-runner.log        # Setup and status logs
tail -f /var/log/arc-status-offline.log   # Offline status cache
tail -f /var/log/job-monitor.log          # Job lifecycle monitoring
```

## Key Features Tested

### ✅ Ephemeral Lifecycle
1. **VM Creation** → **Job Execution** → **Job Completion** → **VM Destruction**
2. Host-side monitoring and cleanup
3. Graceful shutdown with completion signals
4. Force destruction if VM doesn't shutdown

### ✅ ARC Mode Resilience  
1. **Controller Available**: Normal status reporting
2. **Controller Unavailable**: Offline mode with local logging
3. **Controller Intermittent**: Automatic retry with fallback
4. **Status Replay**: Offline logs can be sent to controller later

### ✅ Multi-Mode Support
- **Systemd Mode**: Traditional long-running VMs
- **Docker Mode**: Container-like direct execution  
- **ARC Mode**: Controller integration with job lifecycle
- **Ephemeral**: Auto-destruction after job completion

## Production Deployment

### 1. Start Monitor Service
```bash
# Run monitor as systemd service or in screen/tmux
nohup ./firecracker-complete.sh monitor-ephemeral > /var/log/vm-monitor.log 2>&1 &
```

### 2. ARC Controller Integration
```yaml
# When you have ARC controller running:
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: firecracker-ephemeral
spec:
  replicas: 0
  template:
    spec:
      ephemeral: true
      # Point to your actual ARC controller
      webhook:
        url: "http://firecracker-host:8081/vm/destroy"
```

### 3. Auto-scaling
- Use `monitor-ephemeral` to track VM lifecycle
- Integrate with cloud provider APIs for resource management
- Scale VMs based on GitHub Actions queue depth

## Troubleshooting

### VM Not Shutting Down
```bash
# Check completion signal
ssh -i instances/vm-id/ssh_key runner@vm-ip "ls -la /tmp/ephemeral-cleanup"

# Check job monitor
ssh -i instances/vm-id/ssh_key runner@vm-ip "ps aux | grep monitor-jobs"

# Force destroy
curl -X POST http://localhost:8081/vm/destroy -d '{"vm_id":"vm-name"}'
```

### ARC Controller Issues
```bash
# Check offline status cache
ssh -i instances/vm-id/ssh_key runner@vm-ip "cat /var/log/arc-status-offline.log"

# Test controller connectivity
curl -X POST http://arc-controller:8080/api/v1/runners/test/status \
  -H "Content-Type: application/json" \
  -d '{"status":"test","message":"connectivity test"}'
``` 