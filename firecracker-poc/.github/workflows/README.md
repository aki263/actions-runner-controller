# GitHub Workflows for Firecracker Runners

This directory contains GitHub Actions workflows to test and validate your Firecracker runners.

## 🧪 Available Workflows

### 1. Test Firecracker Runners (`test-firecracker-runners.yml`)

**Purpose**: Comprehensive testing of deployed Firecracker runners

**Trigger**: Manual (workflow_dispatch)

**Key Features**:
- 🖥️ **System Information**: Hardware specs, OS details, network info
- 🐳 **Docker Testing**: Verify Docker CE installation and functionality
- 🏃‍♂️ **Runner Validation**: Test GitHub Actions runner environment
- 📊 **Performance Benchmarks**: CPU, memory, disk, and network tests
- 🧪 **Stress Testing**: CPU, memory, and Docker stress tests
- 🔍 **Full Diagnostics**: Detailed system analysis
- 🔬 **Comparison**: Optional GitHub-hosted runner comparison

**Inputs**:
- `runner_labels`: Runner labels (e.g., `firecracker`, `self-hosted`)
- `test_level`: `basic`, `full`, or `stress`
- `docker_test`: Enable Docker functionality tests
- `performance_test`: Enable performance benchmarks

### 2. Deploy and Test Firecracker Runner (`deploy-test-runner.yml`)

**Purpose**: Guide for deploying runners and provide deployment instructions

**Trigger**: Manual (workflow_dispatch)

**Key Features**:
- 📋 **Deployment Instructions**: Step-by-step runner deployment guide
- ✅ **Verification**: Pre-deployment checklist
- 🎉 **Connection Test**: Verify deployed runner connectivity
- 📌 **Fallback Guidance**: Help when runners aren't available yet

**Inputs**:
- `runner_name`: Name for the test runner
- `runner_memory`: Memory allocation in MB
- `runner_cpus`: Number of CPU cores
- `test_after_deploy`: Attempt to test the runner after deployment

## 🚀 How to Use

### Step 1: Deploy a Firecracker Runner

1. **On your Linux host**, deploy a runner:
   ```bash
   cd firecracker-poc/consolidated/
   
   # Build image (first time only)
   ./firecracker-runner.sh build
   
   # Create snapshot
   ./firecracker-runner.sh snapshot
   
   # Deploy runner
   ./firecracker-runner.sh launch \
     --name "test-runner-1" \
     --github-url "https://github.com/your-org/your-repo" \
     --github-token "$GITHUB_TOKEN" \
     --labels "firecracker,test,test-runner-1"
   ```

2. **Verify deployment**:
   ```bash
   ./firecracker-runner.sh list
   ```

3. **Check GitHub**: Go to Repository Settings → Actions → Runners to see your runner

### Step 2: Test the Runner

1. **Go to GitHub Actions** in your repository
2. **Select "Test Firecracker Runners"** workflow
3. **Click "Run workflow"**
4. **Configure inputs**:
   - Runner labels: `firecracker,test,test-runner-1`
   - Test level: `basic` (for quick test) or `full` (comprehensive)
   - Enable Docker test: ✅
   - Enable performance test: ✅ (optional)

5. **Click "Run workflow"** and watch the results!

### Step 3: Alternative - Use Deployment Helper

1. **Go to GitHub Actions** in your repository
2. **Select "Deploy and Test Firecracker Runner"** workflow  
3. **Click "Run workflow"**
4. **Configure inputs**:
   - Runner name: `my-test-runner`
   - Memory: `2048` MB
   - CPUs: `2`
   - Test after deploy: ✅

5. **Follow the generated deployment instructions**

## 📊 Test Results Examples

### Basic Test Output
```
=== FIRECRACKER RUNNER SYSTEM SPECS ===
Runner: firecracker,test,test-runner-1
🔧 Hardware Information:
CPU Model: Intel(R) Xeon(R) CPU E5-2686 v4 @ 2.30GHz
CPU Cores: 2
Memory Total: 2.0Gi
Disk Space: 20G total, 18G available

💻 Operating System:
OS: Ubuntu 24.04.1 LTS
Kernel: 6.1.128
Uptime: up 2 minutes

🐳 Docker Information:
Docker Version: Docker version 27.3.1, build ce12230
✅ Docker functionality verified
```

### Performance Test Output
```
=== PERFORMANCE BENCHMARKS ===
💾 Memory Performance:
100+0 records in, 100+0 records out
104857600 bytes (105 MB, 100 MiB) copied, 0.08s, 1.3 GB/s

💽 Disk I/O Performance:
Sequential write test: 1.2 GB/s
Sequential read test: 2.1 GB/s

🔢 CPU Performance:
CPU computation test: completed in 0.95s
```

## 🎯 Use Cases

### Development Testing
```yaml
runner_labels: "firecracker,dev"
test_level: "basic"
docker_test: true
performance_test: false
```

### Production Validation
```yaml
runner_labels: "firecracker,production"
test_level: "full"
docker_test: true
performance_test: true
```

### Stress Testing
```yaml
runner_labels: "firecracker,test"
test_level: "stress"
docker_test: true
performance_test: true
```

## 🔧 Customization

### Adding Custom Tests

Edit `test-firecracker-runners.yml` to add custom test steps:

```yaml
- name: 🧪 Custom Application Test
  run: |
    echo "Testing custom application..."
    # Your custom tests here
```

### Different Runner Labels

Use different label combinations for different runner pools:

- `firecracker,production,eu-west-1` - Production EU runners
- `firecracker,development,high-memory` - Development high-memory runners
- `firecracker,ci,fast-cpu` - CI runners with fast CPUs

### Custom Metrics

Add custom performance metrics:

```yaml
- name: 📊 Custom Metrics
  run: |
    echo "Application startup time:"
    time your-app --version
    
    echo "Database connection test:"
    time pg_isready -h localhost
```

## 🐛 Troubleshooting

### Runner Not Found
- Check runner is online: Repository Settings → Actions → Runners
- Verify labels match exactly (case-sensitive)
- Check runner status: `./firecracker-runner.sh list`

### Tests Failing
- SSH into runner: `ssh -i runner-instances/*/ssh_key runner@172.16.0.2`
- Check runner service: `systemctl status github-runner`
- View runner logs: `journalctl -u github-runner -f`

### Performance Issues
- Check VM resources: `htop`, `free -h`, `df -h`
- Monitor host system resources
- Consider increasing VM memory/CPU

## 🎉 Next Steps

1. **Set up monitoring**: Use the performance tests to establish baselines
2. **Automate deployment**: Create scripts to deploy runner pools
3. **Scale testing**: Test multiple runners simultaneously
4. **Custom workflows**: Create application-specific test workflows

---

**These workflows help you verify that your Firecracker runners are working correctly and performing well!** 🚀 