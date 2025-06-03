# Firecracker Integration Files

This directory contains all files related to Firecracker VM integration with Actions Runner Controller (ARC).

## 📋 Contents

### Documentation
- **`FIRECRACKER_SCALING_FIX.md`** - Technical documentation about the autoscaling fix for VMs
- **`FIRECRACKER_INTEGRATION_COMPLETE.md`** - Complete integration guide and architecture documentation

### Scripts & Daemon
- **`firecracker-complete.sh`** - Main Firecracker VM management script (VM creation, deletion, status)
- **`host-install-improved.sh`** - Improved host installation script with Python VM agent
- **`host-install.sh`** - Original host installation script

### Kubernetes Deployment Files
- **`deploy-firecracker-arc.yaml`** - Main ARC controller deployment with Firecracker support
- **`firecracker-controller-deployment.yaml`** - Firecracker-specific controller deployment
- **`firecracker-vm-daemonset.yaml`** - VM daemon DaemonSet for host-based VM management
- **`firecracker-ds-updated.yaml`** - Updated daemon configuration
- **`firecracker-service-new.yaml`** - Service configuration for VM daemon

### ConfigMaps
- **`firecracker-scripts-configmap.yaml`** - ConfigMap containing VM management scripts
- **`firecracker-host-install-v2-cm.yaml`** - ConfigMap for host installation scripts

### Runner Deployment
- **`tenki-fc-rdeploy.yaml`** - Example RunnerDeployment configuration with Firecracker runtime

### Container
- **`Dockerfile.firecracker`** - Dockerfile for building Firecracker-enabled ARC controller

## 🚀 Quick Start

1. **Deploy VM Daemon:**
   ```bash
   kubectl apply -f firecracker-vm-daemonset.yaml
   kubectl apply -f firecracker-scripts-configmap.yaml
   kubectl apply -f firecracker-host-install-v2-cm.yaml
   ```

2. **Deploy ARC Controller:**
   ```bash
   kubectl apply -f deploy-firecracker-arc.yaml
   ```

3. **Create RunnerDeployment:**
   ```bash
   kubectl apply -f tenki-fc-rdeploy.yaml
   ```

## 🔧 Key Features

- **VM-based runners** instead of container-based
- **Host-based daemon** for VM management
- **Autoscaling support** for both webhook and metrics-based scaling
- **Snapshot support** for fast VM boot times
- **Network isolation** with bridge networking

## 📝 Notes

- All Go controller files remain in the main codebase
- These files support the Firecracker runtime implementation
- See documentation files for detailed architecture and troubleshooting information 