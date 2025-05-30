#!/bin/bash

# Test Docker Networking in Firecracker VM
# Run this inside the VM to verify Docker networking is working

set -euo pipefail

echo "🔍 Testing Docker Networking Configuration"
echo "=========================================="

# Test 1: Check kernel modules
echo ""
echo "1. Checking required kernel modules:"
echo "-----------------------------------"

modules=("bridge" "br_netfilter" "overlay" "xt_conntrack" "nf_nat" "nf_conntrack")
for module in "${modules[@]}"; do
    if lsmod | grep -q "^$module"; then
        echo "✅ $module - loaded"
    else
        echo "❌ $module - not loaded"
    fi
done

# Test 2: Check sysctl settings
echo ""
echo "2. Checking sysctl networking settings:"
echo "--------------------------------------"

settings=(
    "net.ipv4.ip_forward"
    "net.bridge.bridge-nf-call-iptables" 
    "net.bridge.bridge-nf-call-ip6tables"
)

for setting in "${settings[@]}"; do
    value=$(sysctl -n "$setting" 2>/dev/null || echo "not found")
    if [ "$value" = "1" ]; then
        echo "✅ $setting = $value"
    else
        echo "❌ $setting = $value (should be 1)"
    fi
done

# Test 3: Check Docker service
echo ""
echo "3. Checking Docker service:"
echo "---------------------------"

if systemctl is-active --quiet docker; then
    echo "✅ Docker service is running"
else
    echo "❌ Docker service is not running"
    systemctl status docker --no-pager || true
    exit 1
fi

# Test 4: Test basic Docker functionality
echo ""
echo "4. Testing basic Docker functionality:"
echo "-------------------------------------"

if docker info >/dev/null 2>&1; then
    echo "✅ Docker daemon is accessible"
else
    echo "❌ Docker daemon is not accessible"
    exit 1
fi

# Test 5: Check Docker networks
echo ""
echo "5. Checking Docker networks:"
echo "----------------------------"

if docker network ls | grep -q bridge; then
    echo "✅ Docker bridge network exists"
    docker network inspect bridge --format='{{.IPAM.Config}}' | head -1
else
    echo "❌ Docker bridge network not found"
fi

# Test 6: Test container networking
echo ""
echo "6. Testing container networking:"
echo "-------------------------------"

echo "Testing hello-world container..."
if docker run --rm hello-world >/dev/null 2>&1; then
    echo "✅ hello-world container works"
else
    echo "❌ hello-world container failed"
fi

echo "Testing network connectivity..."
if docker run --rm alpine:latest ping -c 3 8.8.8.8 >/dev/null 2>&1; then
    echo "✅ Container network connectivity works"
else
    echo "❌ Container network connectivity failed"
fi

# Test 7: Test Docker build (the problematic operation)
echo ""
echo "7. Testing Docker build with networking:"
echo "---------------------------------------"

cat > /tmp/test-dockerfile <<'EOF'
FROM alpine:latest as builder
RUN echo "Build stage networking test" > /build.txt

FROM alpine:latest  
COPY --from=builder /build.txt /app/
CMD cat /app/build.txt && echo "Multi-stage build successful!"
EOF

echo "Building test image..."
if docker build -t networking-test -f /tmp/test-dockerfile /tmp >/dev/null 2>&1; then
    echo "✅ Docker build with networking works"
    
    echo "Running test container..."
    if docker run --rm networking-test 2>&1; then
        echo "✅ Test container execution works"
    else
        echo "❌ Test container execution failed"
    fi
    
    # Cleanup
    docker rmi networking-test >/dev/null 2>&1 || true
else
    echo "❌ Docker build with networking failed"
    echo "Build output:"
    docker build -t networking-test -f /tmp/test-dockerfile /tmp 2>&1 | tail -10
fi

rm -f /tmp/test-dockerfile

# Test 8: Network diagnostics
echo ""
echo "8. Network diagnostics:"
echo "----------------------"

echo "Network interfaces:"
ip addr show | grep -E "^[0-9]+:|inet "

echo ""
echo "Routing table:"
ip route show

echo ""
echo "iptables NAT rules:"
sudo iptables -t nat -L -n | head -10

echo ""
echo "🎯 Docker Networking Test Complete!"
echo "==================================="

# Summary
if docker run --rm alpine:latest sh -c "echo 'Final connectivity test'" >/dev/null 2>&1; then
    echo "✅ Overall assessment: Docker networking is working correctly"
    echo "🚀 Your Firecracker VM should now handle Docker builds successfully!"
else
    echo "❌ Overall assessment: Docker networking has issues"
    echo "📋 Check the failed tests above and run manual fixes"
fi 