# Building Firecracker-enabled ARC Controller

## Quick Start

Use the Makefile targets to build Docker images with Firecracker support:

```bash
# View all available build targets
make help

# Build Firecracker-enabled image (standard)
make docker-build-firecracker

# Build optimized Firecracker image (smaller, production-ready)
make docker-build-firecracker-optimized

# Build multi-architecture images
make docker-buildx-firecracker
make docker-buildx-firecracker-optimized

# Push images to registry
make docker-push-firecracker
```

## Image Variants

### Standard Firecracker Image
- **Target**: `make docker-build-firecracker`
- **Dockerfile**: `Dockerfile` (enhanced with Ubuntu base)
- **Tags**: 
  - `summerwind/actions-runner-controller:${VERSION}-firecracker`
  - `summerwind/actions-runner-controller:firecracker-latest`

### Optimized Firecracker Image  
- **Target**: `make docker-build-firecracker-optimized`
- **Dockerfile**: `Dockerfile.firecracker` (multi-stage optimized)
- **Tags**:
  - `summerwind/actions-runner-controller:${VERSION}-firecracker-optimized`
  - `summerwind/actions-runner-controller:firecracker-optimized`

## Multi-Stage Dockerfile Explanation

Both Dockerfiles use **multi-stage builds**:

1. **Builder Stage** (`FROM golang:1.21 as builder`):
   - Compiles Go source code into binaries
   - Includes build tools and dependencies
   - Large intermediate image (~1GB+)

2. **Runtime Stage** (`FROM ubuntu:22.04`):
   - Final production image
   - Copies only compiled binaries from builder stage
   - Installs runtime dependencies (Firecracker, networking tools)
   - Smaller final image (~500MB)

This pattern ensures:
- **Security**: No source code or build tools in production
- **Size**: Optimized final image size
- **Performance**: Only necessary runtime components

## Environment Variables

Configure the build with these variables:

```bash
# Set custom image name
export DOCKER_IMAGE_NAME="myregistry/actions-runner-controller"

# Set version tag
export VERSION="v1.0.0"

# Multi-arch platforms
export PLATFORMS="linux/amd64,linux/arm64"

# Build and push
make docker-buildx-firecracker
```

## Package Dependencies

The Firecracker images include these additional packages:

- **firecracker** - Core Firecracker VMM
- **iproute2, bridge-utils, iptables** - Network management
- **dnsmasq** - DHCP/DNS services
- **cloud-image-utils, cloud-init** - VM configuration
- **util-linux, e2fsprogs** - File system utilities
- **wget, curl** - Download utilities

## Security Context Requirements

Firecracker VMs require elevated privileges:

```yaml
securityContext:
  privileged: true
  capabilities:
    add:
    - NET_ADMIN
    - SYS_ADMIN
    - SYS_RESOURCE
```

## Next Steps

After building the image:

1. **Deploy**: Use `firecracker-controller-deployment.yaml`
2. **Configure**: Label nodes with `firecracker.io/enabled=true`
3. **Prepare**: Install kernels and rootfs using `firecracker-complete.sh`
4. **Create**: Deploy RunnerDeployments with `runtime.type: firecracker`

See `FIRECRACKER_INTEGRATION.md` for complete setup instructions. 