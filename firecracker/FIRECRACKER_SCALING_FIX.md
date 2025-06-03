# Firecracker VM Scaling Fix for ARC

## Problem Statement

The Actions Runner Controller (ARC) was not properly scaling Firecracker VMs because the autoscaling metrics (`PercentageRunnersBusy` and webhook-based scaling) only counted traditional pod-based runners, not VM-based runners.

### Root Cause

1. **Webhook scaling worked** - GitHub webhook events correctly triggered capacity reservations
2. **Metrics-based scaling was broken** - The autoscaling logic in `suggestReplicasByPercentageRunnersBusy()` only counted:
   - Kubernetes Runner resources that had corresponding pods
   - Firecracker VMs don't create pods, so they were invisible to the scaling logic
3. **This caused the autoscaler to think there were 0 runners** even when VMs were running and registered with GitHub

## Solution Overview

Modified the autoscaling logic to properly detect and count Firecracker VMs by:

1. **Enhanced Runner Detection**: Check both pod-based runners AND Firecracker VM runners
2. **Proper VM Counting**: Count Runner resources with Firecracker runtime, not just pods
3. **GitHub API Integration**: Match GitHub-registered runners to both pods and VMs

## Code Changes

### 1. Enhanced Autoscaling Logic (`autoscaling.go`)

**Added Firecracker VM Detection:**
```go
// Check if we're dealing with Firecracker VMs by looking for Runner resources with Firecracker runtime
var runnerResourceList v1alpha1.RunnerList
if err := r.Client.List(ctx, &runnerResourceList, client.InNamespace(hra.Namespace), client.MatchingLabels(map[string]string{
    kindLabel: hra.Spec.ScaleTargetRef.Name,
})); err != nil {
    return nil, err
}

// Map of Firecracker VMs that are running but don't have pods
firecrackerVMs := make(map[string]bool)

for _, runner := range runnerResourceList.Items {
    // Check if this is a Firecracker runner
    isFirecracker := (runner.Spec.Runtime != nil && runner.Spec.Runtime.Type == "firecracker") ||
        (runner.Annotations != nil && runner.Annotations["runner.summerwind.dev/runtime"] == "firecracker")
    
    if isFirecracker {
        firecrackerVMs[runner.Name] = true
        numFirecrackerVMs++
    }
}
```

**Enhanced Runner Counting Logic:**
```go
for _, runner := range runners {
    runnerName := *runner.Name
    
    // First check if this runner has a corresponding pod (traditional runners)
    if _, ok := runnerMap[runnerName]; ok {
        numRunnersRegistered++
        // ... existing pod-based logic
    } else if _, isFirecrackerVM := firecrackerVMs[runnerName]; isFirecrackerVM {
        // This is a Firecracker VM registered with GitHub but no pod
        numRunnersRegistered++
        
        if runner.GetBusy() {
            numRunnersBusy++
        }
        // Note: Firecracker VMs don't have the concept of "busy terminating" via pod annotations
    }
}

// If we have Firecracker VMs, update numRunners to include them
if numFirecrackerVMs > 0 {
    // For Firecracker deployments, count the number of VM runners instead of pods
    numRunners = numFirecrackerVMs
}
```

### 2. Enhanced Runner Map (`horizontalrunnerautoscaler_controller.go`)

**Updated `scaleTargetFromRD` to include Firecracker VMs:**
```go
runnerMap := make(map[string]struct{})
for _, runner := range runnerList.Items {
    runnerMap[runner.Name] = struct{}{}
    
    // Log if this is a Firecracker runner for debugging
    isFirecracker := (runner.Spec.Runtime != nil && runner.Spec.Runtime.Type == "firecracker") ||
        (runner.Annotations != nil && runner.Annotations["runner.summerwind.dev/runtime"] == "firecracker")
    
    if isFirecracker {
        r.Log.V(2).Info("Found Firecracker runner in map", "runner", runner.Name, "namespace", rd.Namespace)
    }
}
```

### 3. Added Missing Constants (`constants.go`)

```go
const (
    LabelKeyRunnerSetName        = "runnerset-name"
    LabelKeyRunnerDeploymentName = "runner-deployment-name"  // Added
    LabelKeyRunner               = "actions-runner"
)
```

## How It Works

### Traditional Pod-Based Runners
1. Runner resources create pods
2. GitHub API lists registered runners
3. Autoscaler matches GitHub runners to pods via `runnerMap`
4. Counts busy vs available runners for scaling decisions

### Firecracker VM Runners (Fixed)
1. Runner resources create VMs (not pods) 
2. GitHub API lists registered runners (same as before)
3. **NEW**: Autoscaler detects Firecracker runtime in Runner resources
4. **NEW**: Matches GitHub runners to VM-based Runner resources
5. **NEW**: Counts VMs instead of pods for Firecracker deployments
6. **NEW**: Proper busy vs available calculation for VMs

## Scaling Flow After Fix

### Webhook-Based Scaling (Already Worked)
```
GitHub Webhook → HRA Webhook Handler → Capacity Reservation → RunnerDeployment Scale → VM Creation
```

### Metrics-Based Scaling (Now Fixed)
```
GitHub API (runners) + Kubernetes API (Runner resources) → 
Detect Firecracker VMs → Count busy/available VMs → 
Calculate desired replicas → Scale RunnerDeployment → VM Creation/Deletion
```

## Testing

### Verification Commands
```bash
# Check HRA logs for Firecracker detection
kubectl logs arc-gha-rs-controller-* -n arc-systems | grep -i "firecracker\|num_firecracker_vms"

# Check scaling metrics
kubectl get hra tenki-standard-autoscale-* -n tenki-68130006 -o yaml

# Verify VM counts vs replicas
kubectl get runnerdeployment tenki-standard-autoscale-* -n tenki-68130006 -o yaml
```

### Expected Log Output
```
INFO    Detected Firecracker deployment
    numFirecrackerVMs=2
    numRunners=2
    numRunnersRegistered=2

INFO    Suggested desired replicas of 2 by PercentageRunnersBusy
    num_firecracker_vms=2
    num_runners=2
    num_runners_registered=2
    num_runners_busy=0
```

## Backwards Compatibility

This fix is **fully backwards compatible**:
- ✅ Traditional pod-based runners continue to work exactly as before
- ✅ Webhook-based scaling continues to work for both pods and VMs
- ✅ Only enhances metrics-based scaling to properly handle VMs
- ✅ No breaking changes to existing configurations

## Benefits

1. **Complete Scaling Support**: Both webhook and metrics-based scaling now work for Firecracker VMs
2. **Accurate Resource Counting**: VMs are properly counted in autoscaling decisions
3. **Better Observability**: Enhanced logging shows VM vs pod counts
4. **Cost Optimization**: Proper scale-down when VMs are idle
5. **Performance**: Efficient scale-up when VMs are busy

This fix ensures that Firecracker VM deployments have the same robust autoscaling capabilities as traditional pod-based deployments. 