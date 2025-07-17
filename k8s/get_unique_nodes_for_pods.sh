#!/bin/bash
# Get unique nodes for pods in a namespace, optionally filtered by workload type(s)
# Usage: ./get_unique_nodes_for_pods.sh [namespace] [workload_types]
# 
# Arguments:
#   namespace     - Target namespace (default: current namespace)
#   workload_types - Comma-separated list of workload types (default: all)
#                    Options: deployment,statefulset,daemonset,job,cronjob,all
#                    Examples: "deployment,statefulset" or "deploy,sts,ds"
#
# Examples:
#   ./get_unique_nodes_for_pods.sh                    # All pods in current namespace
#   ./get_unique_nodes_for_pods.sh production         # All pods in production namespace
#   ./get_unique_nodes_for_pods.sh "" deployment      # Only deployment pods in current namespace
#   ./get_unique_nodes_for_pods.sh kube-system "deployment,daemonset"  # Deployments and DaemonSets in kube-system

NAMESPACE=${1:-$(kubectl config view --minify -o jsonpath='{..namespace}')}
WORKLOAD_TYPES=${2:-all}

echo "=== Unique nodes for pods in namespace: $NAMESPACE ==="
if [ "$WORKLOAD_TYPES" != "all" ]; then
    echo "Filtering by workload types: $WORKLOAD_TYPES"
fi

# Convert comma-separated workload types to array
IFS=',' read -ra WORKLOAD_ARRAY <<< "$WORKLOAD_TYPES"

if [ "$WORKLOAD_TYPES" = "all" ]; then
    # Get all pods
    kubectl get pods -n $NAMESPACE -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq
else
    # Get pods for each specified workload type
    for workload in "${WORKLOAD_ARRAY[@]}"; do
        case $workload in
            "deployment"|"deploy")
                kubectl get pods -n $NAMESPACE -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null
                ;;
            "statefulset"|"sts")
                kubectl get pods -n $NAMESPACE -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="StatefulSet")]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null
                ;;
            "daemonset"|"ds")
                kubectl get pods -n $NAMESPACE -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="DaemonSet")]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null
                ;;
            "job")
                kubectl get pods -n $NAMESPACE -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="Job")]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null
                ;;
            "cronjob"|"cj")
                kubectl get pods -n $NAMESPACE -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="Job")]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null
                ;;
            *)
                echo "Unknown workload type: $workload" >&2
                ;;
        esac
    done | sort | uniq
fi 