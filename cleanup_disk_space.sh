#!/bin/bash
echo "=== Disk Space Cleanup Script ==="
echo "Current disk usage:"
df -h /

echo -e "\n=== Checking largest directories ==="
du -h --max-depth=1 /var 2>/dev/null | sort -hr | head -10
du -h --max-depth=1 /opt 2>/dev/null | sort -hr | head -10

echo -e "\n=== Cleaning up Docker/containerd ==="
# Stop Docker if running
systemctl stop docker 2>/dev/null || true

# Clean up containerd
crictl rmi --prune 2>/dev/null || true
crictl rm $(crictl ps -a -q) 2>/dev/null || true
crictl rmp $(crictl pods -q) 2>/dev/null || true

# Clean up Docker images
docker system prune -a -f 2>/dev/null || true
docker volume prune -f 2>/dev/null || true

echo -e "\n=== Cleaning up logs ==="
journalctl --vacuum-time=2d
find /var/log -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true
find /var/log -type f -name "*.log.*" -delete 2>/dev/null || true

echo -e "\n=== Cleaning up temp files ==="
rm -rf /tmp/* 2>/dev/null || true
rm -rf /var/tmp/* 2>/dev/null || true

echo -e "\n=== Cleaning up package cache ==="
apt clean 2>/dev/null || true
apt autoremove -y 2>/dev/null || true

echo -e "\n=== Cleaning up Firecracker instances ==="
# Stop any running Firecracker processes
pkill -f firecracker 2>/dev/null || true
# Remove instance directories
rm -rf /opt/firecracker/data/instances/* 2>/dev/null || true
rm -rf /var/lib/firecracker/* 2>/dev/null || true

echo -e "\n=== Final disk usage ==="
df -h /

echo -e "\n=== Script completed ===" 