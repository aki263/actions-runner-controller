#!/bin/bash

# Test script to verify environment variable fix
# This simulates what cloud-init does when running the setup script

echo "Testing environment variable availability in cloud-init context..."
echo

# Test 1: Direct execution (should fail with original setup)
echo "Test 1: Running setup-runner.sh directly (original approach)"
echo "Expected: Should fail with 'Missing GITHUB_TOKEN or GITHUB_URL'"
echo

# Create a mock setup script that just checks environment variables
cat > test-setup.sh << 'EOF'
#!/bin/bash
if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_URL:-}" ]; then
    echo "❌ FAIL: Missing GITHUB_TOKEN or GITHUB_URL environment variables"
    echo "GITHUB_TOKEN: ${GITHUB_TOKEN:-'(not set)'}"
    echo "GITHUB_URL: ${GITHUB_URL:-'(not set)'}"
    exit 1
else
    echo "✅ SUCCESS: Environment variables found"
    echo "GITHUB_TOKEN: ${GITHUB_TOKEN}"
    echo "GITHUB_URL: ${GITHUB_URL}"
fi
EOF
chmod +x test-setup.sh

# Simulate original approach
./test-setup.sh
echo

# Test 2: Using wrapper script (should succeed)
echo "Test 2: Using run-with-env.sh wrapper (new approach)"
echo "Expected: Should succeed with environment variables set"
echo

# Create wrapper script that mimics the fix
cat > test-wrapper.sh << 'EOF'
#!/bin/bash
export GITHUB_TOKEN="test-token-123"
export GITHUB_URL="https://github.com/test/repo"
export RUNNER_NAME="test-runner"
export RUNNER_LABELS="test-labels"
exec ./test-setup.sh
EOF
chmod +x test-wrapper.sh

# Test the wrapper approach
./test-wrapper.sh
echo

echo "Test complete!"
echo
echo "Summary:"
echo "- Original approach: Environment variables not available during cloud-init"
echo "- Fixed approach: Wrapper script exports variables before calling setup script"
echo "- This is exactly what the updated firecracker-complete.sh now does"

# Cleanup
rm -f test-setup.sh test-wrapper.sh 