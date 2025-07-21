#!/bin/bash
# Get pod info, node name, and specific node label values for predefined namespaces and workloads
# Edit the arrays below to set your namespaces, deployments, statefulsets, and node labels of interest

# === CONFIGURATION ===
NAMESPACES=("default" "kube-system" "argocd")
DEPLOYMENTS=("coredns" "crossplane")
STATEFULSETS=("argocd-application-controller")
NODE_LABELS=("kubernetes.io/hostname" "kubernetes.io/os")
# =====================

# Collect all rows
rows=()
rows+=("NAMESPACE|WORKLOAD|POD|NODE|NODE_LABELS")

for ns in "${NAMESPACES[@]}"; do
  # Deployments
  for deploy in "${DEPLOYMENTS[@]}"; do
    pods=$(kubectl get pods -n "$ns" -o json | jq -r \
      --arg name "$deploy" '
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
      rows+=("$ns|$deploy (deploy)|$pod|$node|$label_values")
    done <<< "$pods"
  done
  # StatefulSets
  for sts in "${STATEFULSETS[@]}"; do
    pods=$(kubectl get pods -n "$ns" -o json | jq -r \
      --arg name "$sts" '
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
      rows+=("$ns|$sts (sts)|$pod|$node|$label_values")
    done <<< "$pods"
  done
done

# Calculate max width for each column
max_ns=0; max_workload=0; max_pod=0; max_node=0; max_labels=0
for row in "${rows[@]}"; do
  IFS='|' read -r ns workload pod node labels <<< "$row"
  (( ${#ns} > max_ns )) && max_ns=${#ns}
  (( ${#workload} > max_workload )) && max_workload=${#workload}
  (( ${#pod} > max_pod )) && max_pod=${#pod}
  (( ${#node} > max_node )) && max_node=${#node}
  (( ${#labels} > max_labels )) && max_labels=${#labels}

done

# Print all rows with dynamic widths
fmt="%-${max_ns}s  %-${max_workload}s  %-${max_pod}s  %-${max_node}s  %-${max_labels}s\n"
for row in "${rows[@]}"; do
  IFS='|' read -r ns workload pod node labels <<< "$row"
  printf "$fmt" "$ns" "$workload" "$pod" "$node" "$labels"
done 