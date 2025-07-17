#!/bin/bash
# Get unique nodes for pods in a namespace
# Usage: ./get_unique_nodes_for_pods.sh <namespace>

NAMESPACE=${1:-default}
echo "=== Unique nodes for pods in namespace: $NAMESPACE ==="
kubectl get pods -n $NAMESPACE -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq 