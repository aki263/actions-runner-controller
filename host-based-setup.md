# Host-Based Firecracker VM Architecture

## Overview
Instead of running Firecracker VMs inside containers, we'll install the VM management directly on Kubernetes nodes and have ARC communicate with a lightweight host agent.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Kubernetes Cluster                                          │
│                                                             │
│ ┌─────────────────┐    ┌─────────────────┐                 │
│ │ ARC Controller  │    │ Runner Resource │                 │
│ │                 │───▶│ (Custom)        │                 │
│ └─────────────────┘    └─────────────────┘                 │
│                                 │                           │
│                                 ▼                           │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Node 1                                                  │ │
│ │                                                         │ │
│ │ ┌─────────────────┐    ┌─────────────────┐             │ │
│ │ │ Host VM Agent   │    │ Firecracker VMs │             │ │
│ │ │ (Simple HTTP)   │───▶│ (Direct on Host)│             │ │
│ │ └─────────────────┘    └─────────────────┘             │ │
│ │                                                         │ │
│ │ /opt/firecracker/                                       │ │
│ │ ├── firecracker-complete.sh                             │ │
│ │ ├── vm-agent.py                                         │ │
│ │ └── data/                                               │ │
│ │     ├── kernels/                                        │ │
│ │     ├── snapshots/                                      │ │
│ │     └── instances/                                      │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Plan

### 1. Host Setup Script
Install Firecracker and our scripts directly on each node:

```bash
# /opt/firecracker/install.sh
#!/bin/bash
# Downloads firecracker-complete.sh and vm-agent.py
# Sets up systemd service for the agent
# Creates required directories and permissions
```

### 2. Lightweight VM Agent
Replace the Python daemon with a simple agent:

```python
# /opt/firecracker/vm-agent.py
# Simple HTTP server (port 8090) that:
# - Receives VM creation requests from ARC
# - Calls firecracker-complete.sh
# - Tracks resource usage (CPU/memory)
# - Reports VM status back to ARC
```

### 3. Resource Management
Simple resource tracking to prevent overallocation:

```bash
# Resource limits per node
MAX_VMS=10
MAX_MEMORY_PCT=80  # Don't use more than 80% of host memory
MAX_CPU_PCT=80     # Don't use more than 80% of host CPU

# Track current usage in /opt/firecracker/resources.json
```

### 4. ARC Integration
Modify ARC controller to call the host agent directly instead of creating pods.

## Advantages
- ✅ No container memory conflicts
- ✅ Direct KVM access
- ✅ Better performance
- ✅ Simpler debugging
- ✅ Direct host networking

## Resource Management Strategy
1. **Node Selection**: ARC selects nodes with available resources
2. **Resource Tracking**: Each agent tracks its own resource usage
3. **Limits**: Configurable limits prevent overallocation
4. **Cleanup**: Automatic cleanup of finished VMs

## Migration Steps
1. Create host installation scripts
2. Create lightweight VM agent
3. Modify ARC controller to use host agents
4. Test on single node first
5. Roll out to all nodes 