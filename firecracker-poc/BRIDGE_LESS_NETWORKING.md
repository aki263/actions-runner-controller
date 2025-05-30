# Bridge-less Networking for Firecracker VMs

If your host doesn't have bridges or you don't want to create them, the Firecracker integration now supports several bridge-less networking modes that work directly with your existing `eth0`/`eth1` interfaces.

## 🌐 **Networking Modes**

### 1. **Macvlan Mode** (Recommended)
VMs get their own MAC addresses on your existing network.

**Pros:**
- ✅ No bridges needed
- ✅ VMs appear as separate devices on your network
- ✅ Can use DHCP from your existing network
- ✅ Good performance
- ✅ Network isolation between VMs

**Cons:**
- ⚠️ Host can't communicate directly with VMs (macvlan limitation)
- ⚠️ Requires promiscuous mode on some switches

**Configuration:**
```yaml
networkConfig:
  networkMode: "macvlan"
  parentInterface: "eth0"          # Your existing interface
  macvlanMode: "bridge"            # or "vepa", "private", "passthru"
  dhcpEnabled: true                # Use your network's DHCP
```

**When to use:** Best for production when VMs need to be accessible from the network and you have DHCP available.

### 2. **NAT Mode**
VMs get private IPs with NAT to internet via your host interface.

**Pros:**
- ✅ No bridges needed
- ✅ Complete isolation from your network
- ✅ Host can reach VMs
- ✅ Internet access via NAT
- ✅ Controlled subnet

**Cons:**
- ⚠️ VMs not directly accessible from network
- ⚠️ Requires iptables rules

**Configuration:**
```yaml
networkConfig:
  networkMode: "nat"
  parentInterface: "eth1"          # Interface for internet access
  subnetCIDR: "10.0.100.0/24"     # Private VM network
  gateway: "10.0.100.1"
```

**When to use:** Best for security-focused environments where VMs should be isolated but need internet access.

### 3. **Host Network Mode**
VMs share the host's network namespace (simplest).

**Pros:**
- ✅ Simplest setup
- ✅ No network configuration needed
- ✅ VMs accessible on host IPs
- ✅ No performance overhead

**Cons:**
- ⚠️ No network isolation
- ⚠️ Port conflicts possible
- ⚠️ Security implications

**Configuration:**
```yaml
networkConfig:
  networkMode: "host"
```

**When to use:** Best for development/testing where simplicity is more important than isolation.

## 📋 **Complete Examples**

### Macvlan with DHCP (Easiest)
```yaml
runtime:
  type: firecracker
  firecracker:
    snapshotName: "prod-runner-v1"
    networkConfig:
      networkMode: "macvlan"
      parentInterface: "eth0"
      dhcpEnabled: true
    arcControllerURL: "http://192.168.1.100:30080"  # Use your host IP
```

### Macvlan with Static IPs
```yaml
runtime:
  type: firecracker
  firecracker:
    snapshotName: "prod-runner-v1"
    networkConfig:
      networkMode: "macvlan"
      parentInterface: "eth0"
      dhcpEnabled: false
      subnetCIDR: "192.168.1.0/24"
      gateway: "192.168.1.1"
    arcControllerURL: "http://192.168.1.100:30080"
```

### NAT Mode (Isolated)
```yaml
runtime:
  type: firecracker
  firecracker:
    snapshotName: "prod-runner-v1"
    networkConfig:
      networkMode: "nat"
      parentInterface: "eth1"
      subnetCIDR: "10.0.100.0/24"
      gateway: "10.0.100.1"
    arcControllerURL: "http://10.0.100.1:30080"
```

### Host Network (Simplest)
```yaml
runtime:
  type: firecracker
  firecracker:
    snapshotName: "prod-runner-v1"
    networkConfig:
      networkMode: "host"
    arcControllerURL: "http://localhost:30080"
```

## 🔧 **Setup Requirements**

### For Macvlan Mode:
```bash
# No special setup needed, but ensure promiscuous mode if required
sudo ip link set eth0 promisc on  # Only if switch requires it
```

### For NAT Mode:
```bash
# Ensure iptables and forwarding are available
sudo apt install iptables
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### For Host Network:
```bash
# No special setup needed
```

## 🌐 **Network Flow Diagrams**

### Macvlan Mode:
```
Internet → Router → Switch → eth0 (host) → macvlan interface → TAP → VM
                                   └─→ VM gets IP from router's DHCP
```

### NAT Mode:
```
Internet → Router → eth1 (host) → iptables NAT → TAP → VM (private IP)
                                                   └─→ VM: 10.0.100.x
```

### Host Network:
```
Internet → Router → Switch → eth0 (host) ═══════════════ VM (shares host network)
```

## ⚡ **Quick Decision Guide**

| Use Case | Recommended Mode | Why |
|----------|------------------|-----|
| Production with network access | Macvlan + DHCP | Professional, scalable |
| Security-focused | NAT | Isolated but functional |
| Development/Testing | Host Network | Simple, fast setup |
| Multi-interface setup | Macvlan on eth0, NAT on eth1 | Best of both worlds |

## 🛠 **Troubleshooting**

### Macvlan Issues:
```bash
# Check if macvlan interface exists
ip link show | grep mv-

# Verify parent interface
ip link show eth0

# Check VM can reach DHCP
# (from inside VM)
dhclient eth0
```

### NAT Issues:
```bash
# Check iptables rules
sudo iptables -t nat -L POSTROUTING
sudo iptables -L FORWARD

# Verify TAP interface has IP
ip addr show tap-*

# Test connectivity from host
ping 10.0.100.10  # VM IP
```

### Host Network Issues:
```bash
# Check if TAP exists
ip link show tap-*

# Verify no port conflicts
netstat -tlnp
```

## 📊 **Performance Comparison**

| Mode | Network Latency | Throughput | Isolation | Setup Complexity |
|------|----------------|------------|-----------|------------------|
| Host Network | Lowest | Highest | None | Lowest |
| Macvlan | Low | High | Medium | Low |
| NAT | Medium | Medium | High | Medium |
| Bridge | Medium | Medium | Medium | High |

Choose the mode that best fits your security, performance, and complexity requirements! 