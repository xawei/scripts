#!/bin/bash
# Get pod info, node name, and specific node label values for specified workloads from a JSON input
# Usage: ./get_pods_nodes_labels.sh <workloads.json>
#
# Example workloads.json:
# {
#   "deploy": [
#     { "name": "coredns", "namespace": "kube-system" },
#     { "name": "crossplane", "namespace": "default" }
#   ],
#   "sts": [
#     { "name": "argocd-application-controller", "namespace": "argocd" }
#   ]
# }

# === CONFIGURATION ===
NODE_LABELS=("kubernetes.io/hostname" "kubernetes.io/os")
# =====================

if [ $# -ne 1 ]; then
  echo "Usage: $0 <workloads.json>"
  exit 1
fi

WORKLOADS_JSON="$1"

# Use a temp file to collect all rows
TMP_ROWS=$(mktemp)
echo "NAMESPACE|WORKLOAD|POD|NODE|NODE_LABELS" > "$TMP_ROWS"

# Deployments
jq -c '.deploy[]?' "$WORKLOADS_JSON" | while read -r item; do
  name=$(echo "$item" | jq -r '.name')
  ns=$(echo "$item" | jq -r '.namespace')
  pods=$(kubectl get pods -n "$ns" -o json | jq -r \
    --arg name "$name" '
      .items[] | select(.metadata.ownerReferences[]? | .kind=="ReplicaSet") |
      select(.metadata.ownerReferences[0].name | startswith($name)) |
      .metadata.name + "|" + .spec.nodeName')
  while IFS='|' read -r pod node; do
    [ -z "$pod" ] && continue
    label_values=""
    for label in "${NODE_LABELS[@]}"; do
      label_jsonpath=${label//./\\.}
      value=$(kubectl get node "$node" -o jsonpath="{.metadata.labels['$label_jsonpath']}")
      label_values+="$label=$value; "
    done
    echo "$ns|$name (deploy)|$pod|$node|$label_values" >> "$TMP_ROWS"
  done <<< "$pods"
done

# StatefulSets
jq -c '.sts[]?' "$WORKLOADS_JSON" | while read -r item; do
  name=$(echo "$item" | jq -r '.name')
  ns=$(echo "$item" | jq -r '.namespace')
  pods=$(kubectl get pods -n "$ns" -o json | jq -r \
    --arg name "$name" '
      .items[] | select(.metadata.ownerReferences[]? | .kind=="StatefulSet") |
      select(.metadata.ownerReferences[0].name==$name) |
      .metadata.name + "|" + .spec.nodeName')
  while IFS='|' read -r pod node; do
    [ -z "$pod" ] && continue
    label_values=""
    for label in "${NODE_LABELS[@]}"; do
      label_jsonpath=${label//./\\.}
      value=$(kubectl get node "$node" -o jsonpath="{.metadata.labels['$label_jsonpath']}")
      label_values+="$label=$value; "
    done
    echo "$ns|$name (sts)|$pod|$node|$label_values" >> "$TMP_ROWS"
  done <<< "$pods"
done

# Wait for all background jobs to finish
wait

# Calculate max width for each column
max_ns=0; max_workload=0; max_pod=0; max_node=0; max_labels=0
while IFS='|' read -r ns workload pod node labels; do
  (( ${#ns} > max_ns )) && max_ns=${#ns}
  (( ${#workload} > max_workload )) && max_workload=${#workload}
  (( ${#pod} > max_pod )) && max_pod=${#pod}
  (( ${#node} > max_node )) && max_node=${#node}
  (( ${#labels} > max_labels )) && max_labels=${#labels}
done < "$TMP_ROWS"

# Print all rows with dynamic widths
fmt="%-${max_ns}s  %-${max_workload}s  %-${max_pod}s  %-${max_node}s  %-${max_labels}s\n"
while IFS='|' read -r ns workload pod node labels; do
  printf "$fmt" "$ns" "$workload" "$pod" "$node" "$labels"
done < "$TMP_ROWS"

rm -f "$TMP_ROWS" 