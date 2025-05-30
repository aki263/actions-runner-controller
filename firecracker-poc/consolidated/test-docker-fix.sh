#!/bin/bash

# Test Docker Fix Script
# Run this to test Docker functionality with kernel module fixes

echo "=== Testing Docker Fix ==="
echo ""

echo "1. Building fresh image with Docker fixes..."
./firecracker-runner.sh build

echo ""
echo "2. Creating snapshot..."
./firecracker-runner.sh snapshot docker-fix-test

echo ""
echo "3. Testing with cloud-init but no network config (recommended)..."
echo "   This uses cloud-init for setup but relies on host networking"
echo ""

read -p "Enter GitHub URL: " github_url
read -p "Enter GitHub Token: " -s github_token
echo ""

./firecracker-runner.sh launch \
  --snapshot docker-fix-test \
  --no-cloud-init-network \
  --github-url "$github_url" \
  --github-token "$github_token" \
  --name docker-test

echo ""
echo "4. Checking VM status..."
./firecracker-runner.sh list

echo ""
echo "5. SSH into VM and test Docker:"
echo "   ./firecracker-runner.sh list  # Get VM IP"
echo "   ssh -i firecracker-data/instances/*/ssh_key runner@<VM-IP>"
echo ""
echo "6. Inside VM, test Docker:"
echo "   sudo systemctl status docker"
echo "   docker info"
echo "   docker run --rm hello-world"
echo "   docker run --rm ubuntu:latest echo 'Container test successful'" 