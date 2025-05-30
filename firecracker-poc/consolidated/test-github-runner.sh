#!/bin/bash

# Test GitHub Runner Setup Script
# Run this INSIDE the VM after SSH'ing in

echo "=== GitHub Actions Runner Manual Setup Test ==="
echo ""

# Check if we're in the VM
if [ "$(hostname)" != "lbm-19-4" ]; then
    echo "This script should be run inside the Firecracker VM"
    echo "SSH first: ssh -i /path/to/ssh_key runner@172.16.0.2"
    exit 1
fi

echo "1. Checking current environment..."
echo "Hostname: $(hostname)"
echo "User: $(whoami)"
echo "Runner directory: $(ls -la /opt/runner/ | head -5)"
echo ""

echo "2. Setting up environment variables..."
echo "Please provide your GitHub information:"
read -p "GitHub URL (repo or org): " GITHUB_URL
read -p "GitHub Token: " -s GITHUB_TOKEN
echo ""
read -p "Runner Name (default: $(hostname)): " RUNNER_NAME
RUNNER_NAME=${RUNNER_NAME:-$(hostname)}
read -p "Runner Labels (default: firecracker,test): " RUNNER_LABELS
RUNNER_LABELS=${RUNNER_LABELS:-firecracker,test}

echo ""
echo "3. Configuring GitHub Actions Runner..."

# Export environment variables
export GITHUB_TOKEN
export GITHUB_URL  
export RUNNER_NAME
export RUNNER_LABELS

cd /opt/runner

echo "Configuring runner with:"
echo "  URL: $GITHUB_URL"
echo "  Name: $RUNNER_NAME"
echo "  Labels: $RUNNER_LABELS"
echo ""

# Configure the runner
./config.sh \
    --url "$GITHUB_URL" \
    --token "$GITHUB_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --work "/tmp/runner-work" \
    --unattended --replace

if [ $? -eq 0 ]; then
    echo ""
    echo "4. Starting the runner service..."
    
    # Create environment file for systemd
    sudo tee /etc/environment > /dev/null <<EOF
GITHUB_TOKEN=$GITHUB_TOKEN
GITHUB_URL=$GITHUB_URL
RUNNER_NAME=$RUNNER_NAME
RUNNER_LABELS=$RUNNER_LABELS
EOF

    sudo systemctl start github-runner
    sleep 3
    sudo systemctl status github-runner
    
    echo ""
    echo "5. Runner should now be visible in GitHub!"
    echo "   Check: $GITHUB_URL/settings/actions/runners"
    echo ""
    echo "6. Test runner logs:"
    echo "   sudo journalctl -u github-runner -f"
else
    echo "❌ Runner configuration failed!"
    echo "Check your GitHub URL and token"
fi 