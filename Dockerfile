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

# Use distroless as minimal base image to package the manager binary
# Refer to https://github.com/GoogleContainerTools/distroless for more details
FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=builder /workspace/manager .
COPY --from=builder /workspace/github-webhook-server .
COPY --from=builder /workspace/actions-metrics-server .
COPY --from=builder /workspace/github-runnerscaleset-listener .
COPY --from=builder /workspace/sleep .
USER 65532:65532

ENTRYPOINT ["/manager"]
