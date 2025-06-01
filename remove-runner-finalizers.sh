#!/bin/bash

# Script to remove finalizers from stuck runners
NAMESPACE="tenki-68130006"
KUBECONFIG="/root/staging-kubeconfig.yaml"

echo "Removing finalizers from all runners in namespace $NAMESPACE..."

# Get all runner names and remove finalizers
kubectl --kubeconfig=$KUBECONFIG get runners -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | while read runner_name; do
    if [ ! -z "$runner_name" ]; then
        echo "Removing finalizer from $runner_name"
        kubectl --kubeconfig=$KUBECONFIG patch runner $runner_name -n $NAMESPACE -p '{"metadata":{"finalizers":[]}}' --type=merge
    fi
done

echo "Finalizer removal complete. Waiting for runners to be deleted..."
sleep 5

# Check remaining runners
remaining=$(kubectl --kubeconfig=$KUBECONFIG get runners -n $NAMESPACE --no-headers | wc -l)
echo "Remaining runners: $remaining" 