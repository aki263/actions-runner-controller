# Firecracker Setup Script Fixes

## Issues Identified and Fixed

### 1. API Configuration Format Error

**Problem:** The original script was sending the entire VM configuration JSON to each API endpoint, causing errors like:
```
SerdeJson(Error("unknown field `boot-source`, expected one of `vcpu_count`, `mem_size_mib`, `smt`, `cpu_template`, `track_dirty_pages`, `huge_pages`", line: 1, column: 16))
```

**Root Cause:** Each Firecracker API endpoint expects only its specific configuration section, not the entire configuration object.

**Solution:** Modified `start_firecracker()` function to send individual configuration sections to their respective endpoints:

- `/machine-config` - Only CPU and memory settings
- `/boot-source` - Only kernel path and boot arguments  
- `/drives/rootfs` - Only drive configuration
- `/network-interfaces/eth0` - Only network interface settings

### 2. Kernel Version Update

**Changes:**
- Updated from kernel version `6.1` to `6.1.128`
- Added support for multiple kernel versions in download function
- Updated download URLs to use the correct Firecracker CI builds

**Supported Kernel Versions:**
- `5.10` - Legacy kernel from quickstart guide
- `6.1.55` - Firecracker CI v1.7 build
- `6.1.128` - Firecracker CI v1.10 build (current default)

### 3. Improved Error Handling

**Enhancements:**
- Better kernel version validation
- Clearer error messages for unsupported versions
- Option to manually place kernel files

## Fixed API Configuration Examples

### Machine Configuration
```json
{
    "vcpu_count": 2,
    "mem_size_mib": 1024
}
```
**Endpoint:** `PUT /machine-config`

### Boot Source Configuration
```json
{
    "kernel_image_path": "/path/to/vmlinux-6.1.128",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off nomodules rw ip=172.20.0.2::172.20.0.1:255.255.255.0::eth0:off"
}
```
**Endpoint:** `PUT /boot-source`

### Drive Configuration
```json
{
    "drive_id": "rootfs",
    "path_on_host": "/path/to/ubuntu-24.04-rootfs.ext4",
    "is_root_device": true,
    "is_read_only": false
}
```
**Endpoint:** `PUT /drives/rootfs`

### Network Interface Configuration
```json
{
    "iface_id": "eth0",
    "guest_mac": "AA:FC:00:00:00:01",
    "host_dev_name": "tap-device-name"
}
```
**Endpoint:** `PUT /network-interfaces/eth0`

## Expected Behavior After Fixes

1. **Successful VM Configuration:** Each API call should return success (HTTP 2xx)
2. **Proper VM Boot:** The VM should start without "Cannot start microvm without kernel configuration" errors
3. **SSH Connectivity:** SSH should become available within 30-60 seconds of VM start
4. **Network Access:** The VM should have internet connectivity through the TAP device

## Testing the Fixes

Run the setup script and verify:

```bash
# Start a new VM
./firecracker-setup.sh

# Check for successful API calls (no JSON errors in logs)
# Verify SSH connectivity works
ssh -i ./firecracker-vm/vm_key root@172.20.0.2

# Test internet access from within the VM
ssh -i ./firecracker-vm/vm_key root@172.20.0.2 'ping -c 3 google.com'
```

## Files Modified

- `firecracker-setup.sh` - Fixed API configuration and kernel version
- `README.md` - Updated documentation to reflect kernel 6.1.128
- `test-api-config.sh` - Updated test examples
- `FIRECRACKER_FIXES.md` - This documentation

The fixes ensure that the Firecracker VM setup script now correctly interacts with the Firecracker API and uses the latest supported kernel version. 