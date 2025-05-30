# Firecracker VM Testing Guide

## Quick Status Check

The service being "inactive (dead)" is normal when testing with `--no-cloud-init` because the environment variables haven't been set up yet.

## Current VM State Analysis

✅ **What's Working:**
- VM is running and accessible via SSH
- GitHub runner service is installed and enabled
- systemd service is properly configured

❌ **What's Missing:**
- Environment variables (GITHUB_TOKEN, GITHUB_URL, etc.)
- Runner configuration and registration

## Testing Options

### Option 1: Manual GitHub Runner Setup (Inside VM)

1. **Copy the test script to VM:**
   ```bash
   # On host
   scp -i firecracker-data/instances/*/ssh_key test-github-runner.sh runner@172.16.0.2:~/
   ```

2. **SSH into VM and run:**
   ```bash
   ssh -i firecracker-data/instances/*/ssh_key runner@172.16.0.2
   chmod +x test-github-runner.sh
   ./test-github-runner.sh
   ```

### Option 2: Test Basic VM Functions (No GitHub)

```bash
# Inside VM, test core functionality:
ssh -i firecracker-data/instances/*/ssh_key runner@172.16.0.2

# Test networking
ping 8.8.8.8
curl -I https://github.com

# Test Docker
sudo systemctl status docker
sudo systemctl start docker
docker run --rm hello-world

# Test runner installation
ls -la /opt/runner/
/opt/runner/run.sh --help

# Test kernel features  
uname -r
cat /proc/version
ls /sys/fs/cgroup/
```

### Option 3: Test with Cloud-Init (Full Automation)

```bash
# On host, test full automation:
./firecracker-runner.sh launch \
  --snapshot runner-20250529-222120 \
  --github-url "https://github.com/your-org/repo" \
  --github-token "ghp_your_token_here" \
  --name production-test
```

## Service Troubleshooting

### Check Service Status:
```bash
sudo systemctl status github-runner
sudo journalctl -u github-runner -n 20
```

### Common Issues:

1. **"Access denied" for systemctl enable**
   - Solution: Use `sudo systemctl enable github-runner` ✅

2. **Service "inactive (dead)"**  
   - Normal without environment variables
   - Solution: Set up environment and start manually

3. **Docker not working**
   ```bash
   sudo systemctl start docker
   sudo usermod -aG docker runner
   # Logout and login again
   ```

## Environment Variables Needed

The runner service needs these environment variables:
```bash
GITHUB_TOKEN=ghp_your_token_here
GITHUB_URL=https://github.com/your-org/repo  
RUNNER_NAME=unique-runner-name
RUNNER_LABELS=firecracker,custom-kernel,test
```

## Success Indicators

✅ **VM is ready when:**
- SSH access works
- Network connectivity established  
- Docker service running
- Runner binary responds to commands

✅ **Runner is working when:**
- `systemctl status github-runner` shows "active (running)"
- Runner appears in GitHub settings
- Can accept workflow jobs

## Next Steps

1. **Test basic VM first** - verify networking, Docker, SSH
2. **Then test runner setup** - either manual or cloud-init
3. **Finally test custom kernel** - compare features with default kernel 