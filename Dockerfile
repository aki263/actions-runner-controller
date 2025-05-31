# Build the manager binary
FROM golang:1.21 as builder

WORKDIR /workspace

# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

# Copy the go source
COPY main.go main.go
COPY apis/ apis/
COPY controllers/ controllers/
COPY github/ github/
COPY logging/ logging/
COPY build/ build/
COPY hash/ hash/
COPY cmd/ cmd/
COPY pkg/ pkg/
COPY simulator/ simulator/

# Build all required binaries
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o manager main.go
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o github-webhook-server ./cmd/githubwebhookserver
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o actions-metrics-server ./cmd/actionsmetricsserver
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o github-runnerscaleset-listener ./cmd/githubrunnerscalesetlistener
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o sleep ./cmd/sleep

# Use Ubuntu base image to support Firecracker and system utilities
FROM ubuntu:22.04

# Install necessary packages for Firecracker support
RUN apt-get update && apt-get install -y \
    # Network utilities for VM management
    iproute2 \
    bridge-utils \
    iptables \
    dnsmasq \
    # Cloud-init for VM configuration
    cloud-image-utils \
    cloud-init \
    # File system utilities
    util-linux \
    e2fsprogs \
    parted \
    # Process and system utilities
    procps \
    psmisc \
    # SSH utilities for VM key generation
    openssh-client \
    # Download utilities for kernel/rootfs retrieval
    wget \
    curl \
    # Security and cleanup
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Install Firecracker from GitHub releases
RUN ARCH="$(uname -m)" && \
    release_url="https://github.com/firecracker-microvm/firecracker/releases" && \
    latest=$(basename $(curl -fsSLI -o /dev/null -w %{url_effective} ${release_url}/latest)) && \
    curl -L ${release_url}/download/${latest}/firecracker-${latest}-${ARCH}.tgz | tar -xz && \
    mv release-${latest}-${ARCH}/firecracker-${latest}-${ARCH} /usr/local/bin/firecracker && \
    mv release-${latest}-${ARCH}/jailer-${latest}-${ARCH} /usr/local/bin/jailer && \
    chmod +x /usr/local/bin/firecracker /usr/local/bin/jailer && \
    rm -rf release-${latest}-${ARCH}

# Create directories for Firecracker assets
RUN mkdir -p /opt/firecracker/{kernels,images,snapshots,vm-configs} \
    && mkdir -p /var/lib/firecracker/vms \
    && mkdir -p /tmp/firecracker

# Create a non-root user for running the controller
RUN groupadd -r controller && useradd -r -g controller controller

WORKDIR /
COPY --from=builder /workspace/manager .
COPY --from=builder /workspace/github-webhook-server .
COPY --from=builder /workspace/actions-metrics-server .
COPY --from=builder /workspace/github-runnerscaleset-listener .
COPY --from=builder /workspace/sleep .

# Set proper permissions
RUN chown -R controller:controller /opt/firecracker \
    && chown -R controller:controller /var/lib/firecracker \
    && chown -R controller:controller /tmp/firecracker \
    && chmod +x /manager /github-webhook-server /actions-metrics-server /github-runnerscaleset-listener /sleep

# Note: Running as root is required for Firecracker VM management (network bridges, etc.)
# In production, consider using capabilities or privileged security contexts
USER root

ENTRYPOINT ["/manager"]
