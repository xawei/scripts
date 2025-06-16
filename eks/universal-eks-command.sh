#!/bin/bash

# ====== Configurable ======
REGION="ap-southeast-1"          # AWS region
PROFILES=("your-profile-name")   # AWS CLI profiles array, e.g. ("profile1" "profile2" "profile3")

# Custom command to execute on each cluster
# The kubeconfig will be automatically set for each cluster
# You can use {CLUSTER} placeholder for the current cluster name
# You can use {PROFILE} placeholder for the current AWS profile
# Examples:
#   "kubectl get nodes"
#   "helm list --all-namespaces"
#   "kubectl get pods -n kube-system"
#   "echo 'Checking cluster: {CLUSTER} in profile: {PROFILE}' && kubectl get nodes"
CUSTOM_COMMAND="kubectl get nodes"

# Optional: Specific clusters to target (leave empty to target all clusters)
TARGET_CLUSTERS=()              # e.g. ("cluster1" "cluster2"), leave empty to check all

TMP_KUBECONFIG="/tmp/tmp_kubeconfig_eks"

# ====== Functions ======

# Function to execute the custom command with placeholder substitution
execute_custom_command() {
    local kubeconfig="$1"
    local cluster="$2"
    local profile="$3"
    
    # Replace placeholders in the command (no need for KUBECONFIG placeholder anymore)
    local cmd="${CUSTOM_COMMAND}"
    cmd="${cmd//\{CLUSTER\}/$cluster}"
    cmd="${cmd//\{PROFILE\}/$profile}"
    
    echo "  Command: $cmd"
    echo "  Output:"
    
    # Set KUBECONFIG environment variable and execute the command
    # This way kubectl, helm, and other tools will automatically use the correct config
    KUBECONFIG="$kubeconfig" eval "$cmd"
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo "  ❌ Command failed with exit code: $exit_code"
    else
        echo "  ✅ Command executed successfully"
    fi
    
    return $exit_code
}

# ====== Script Begins ======

echo "====== Universal EKS Command Executor ======"
echo "Region: $REGION"
echo "Profiles: ${PROFILES[*]}"
echo "Command Template: $CUSTOM_COMMAND"
echo ""

for profile in "${PROFILES[@]}"; do
  echo "====== AWS Profile: $profile ======"
  
  clusters=$(aws eks list-clusters --region "$REGION" --profile "$profile" --output text --query 'clusters[]')

  if [ -z "$clusters" ]; then
    echo "❌ No EKS clusters found in region $REGION using profile $profile."
    echo ""
    continue
  fi

  echo "Available clusters: $clusters"
  echo ""

  for cluster in $clusters; do
    # Check if specific clusters are targeted
    if [ ${#TARGET_CLUSTERS[@]} -gt 0 ]; then
      # Check if current cluster is in the target list
      if [[ ! " ${TARGET_CLUSTERS[@]} " =~ " ${cluster} " ]]; then
        echo "⏭️  Skipping cluster: $cluster (not in target list)"
        continue
      fi
    fi

    echo "==> Cluster: $cluster"

    # Update kubeconfig for the current cluster
    aws eks update-kubeconfig \
      --region "$REGION" \
      --name "$cluster" \
      --kubeconfig "$TMP_KUBECONFIG" \
      --profile "$profile" \
      > /dev/null 2>&1

    if [ $? -ne 0 ]; then
      echo "  ❌ Failed to update kubeconfig for cluster: $cluster"
      echo ""
      continue
    fi

    # Execute the custom command
    execute_custom_command "$TMP_KUBECONFIG" "$cluster" "$profile"
    
    echo ""
  done
  
  echo "====== End of Profile: $profile ======" 
  echo ""
done

# Cleanup
rm -f "$TMP_KUBECONFIG"

echo "====== Execution Complete ======" 