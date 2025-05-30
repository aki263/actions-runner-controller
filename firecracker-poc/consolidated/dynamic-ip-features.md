# Dynamic IP and DHCP Features

## Problem Solved
Previously, all VMs used the same IP (172.16.0.2), causing conflicts when running multiple instances.

## New Features

### 1. **Dynamic Static IP Allocation**
- **Default behavior**: Each VM gets a unique static IP
- **IP Range**: 172.16.0.10 - 172.16.0.210 
- **Generation**: Based on VM ID hash to ensure uniqueness
- **Gateway**: Always 172.16.0.1

```bash
# Each VM gets a different IP automatically
./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name vm1  # Gets 172.16.0.47
./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name vm2  # Gets 172.16.0.123
./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name vm3  # Gets 172.16.0.89
```

### 2. **DHCP Support (Optional)**
- **Requires**: dnsmasq package
- **IP Range**: 172.16.0.100 - 172.16.0.200
- **Benefits**: True dynamic allocation, automatic lease management
- **Usage**: Add `--dhcp` flag

```bash
# DHCP mode (requires dnsmasq)
sudo apt install dnsmasq  # Install first
./firecracker-runner.sh launch --dhcp --snapshot runner-20250529-222120 --no-cloud-init --name dhcp-vm
```

## Usage Examples

### Multiple VMs with Static IPs
```bash
# Launch 3 VMs - each gets unique IP
./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name test-vm-1
./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name test-vm-2  
./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name test-vm-3

# Check their IPs
./firecracker-runner.sh list
```

### DHCP Mode
```bash
# Enable DHCP for dynamic allocation
./firecracker-runner.sh launch --dhcp --snapshot runner-20250529-222120 --no-cloud-init --name dhcp-test

# VM will get IP from 172.16.0.100-200 range
```

### Combined with Custom Kernel
```bash
# Use custom kernel + static IP
./firecracker-runner.sh launch \
  --kernel ../vmlinux-6.1.128-custom \
  --snapshot runner-20250529-222120 \
  --no-cloud-init \
  --name custom-kernel-test

# Use custom kernel + DHCP
./firecracker-runner.sh launch \
  --kernel ../vmlinux-6.1.128-custom \
  --dhcp \
  --snapshot runner-20250529-222120 \
  --no-cloud-init \
  --name custom-kernel-dhcp
```

## Technical Details

### Static IP Generation
```bash
# IP calculated as: 172.16.0.{10 + (hash(vm_id) % 200)}
vm_id="test-vm"  # First 8 chars: "test-vm"
hash_value=$(echo "$vm_id" | sha256sum | head -c 2)  # Get first 2 hex chars
ip_suffix=$((16#$hash_value % 200 + 10))  # Convert to decimal, mod 200, add 10
# Result: 172.16.0.$ip_suffix
```

### DHCP Server Setup
```bash
# Automatic dnsmasq configuration per TAP device
sudo dnsmasq \
  --interface=tap-abcd1234 \
  --dhcp-range=172.16.0.100,172.16.0.200,12h \
  --dhcp-option=3,172.16.0.1 \
  --dhcp-option=6,8.8.8.8,8.8.4.4 \
  --pid-file=/tmp/dnsmasq-tap-abcd1234.pid
```

## Cloud-Init vs No-Cloud-Init

### Cloud-Init Mode
- **Static**: Network config embedded in cloud-init
- **DHCP**: `dhcp4: true` in network configuration

### No-Cloud-Init Mode  
- **Static**: Direct systemd-networkd configuration
- **DHCP**: `DHCP=yes` in networkd config

## Troubleshooting

### Check VM IPs
```bash
./firecracker-runner.sh list  # Shows all running VMs with IPs
```

### DHCP Issues
```bash
# Check if dnsmasq is running
ps aux | grep dnsmasq

# Check DHCP logs
sudo journalctl -f | grep dnsmasq

# Install dnsmasq if missing
sudo apt install dnsmasq
```

### Multiple VM SSH
```bash
# List VMs to get IPs
./firecracker-runner.sh list

# SSH to specific VM (replace IP)
ssh -i firecracker-data/instances/test-vm-1*/ssh_key runner@172.16.0.47
ssh -i firecracker-data/instances/test-vm-2*/ssh_key runner@172.16.0.123
```

### Cleanup
```bash
# Stops all VMs, DHCP servers, and removes TAP devices
./firecracker-runner.sh cleanup
```

## Benefits

1. **No IP Conflicts**: Multiple VMs can run simultaneously
2. **Automatic Allocation**: No manual IP management needed
3. **Flexible Options**: Choose static or DHCP based on needs
4. **Clean Architecture**: Each VM gets its own TAP device and network config
5. **Easy Testing**: Multiple kernel tests in parallel

## Important: Networking Fix

### Issue Found
The initial implementation had a critical networking flaw:
- Multiple TAP devices were assigned the same gateway IP `172.16.0.1/30`
- This created routing conflicts and prevented proper VM communication

### Fix Applied
- **Changed from**: `/30` subnets (4 IPs total per TAP device)
- **Changed to**: `/24` subnet (256 IPs shared across all VMs)
- **Result**: Single gateway `172.16.0.1/24` shared by all TAP devices

### If You Have Existing Conflicts
Run the fix script on your Linux server:
```bash
./fix-networking.sh
```

This will:
1. Stop all running VMs
2. Remove conflicting TAP devices  
3. Clean up DHCP servers
4. Allow fresh start with correct networking

### Correct Networking After Fix
```bash
# After fix, you should see:
# - One gateway IP: 172.16.0.1/24 (on first TAP device)
# - Other TAP devices: no IP assigned (bridge mode)
# - VMs get unique IPs: 172.16.0.10, 172.16.0.47, 172.16.0.123, etc.

# Test multiple VMs:
./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name vm1
./firecracker-runner.sh launch --snapshot runner-20250529-222120 --no-cloud-init --name vm2  
./firecracker-runner.sh list  # Should show different IPs for each VM
``` 