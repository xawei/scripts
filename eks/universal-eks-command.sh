#!/bin/bash

# ====== Configurable ======
REGION="ap-southeast-1"          # AWS region
PROFILES=("your-profile-name")   # AWS CLI profiles array, e.g. ("profile1" "profile2" "profile3")

# Custom commands to execute on each cluster
CUSTOM_COMMANDS=(
    "kubectl get nodes"
    "kubectl get pods -n kube-system"
    "helm list --all-namespaces"
)

# Optional: Specific clusters to target (leave empty to target all clusters)
TARGET_CLUSTERS=()              # e.g. ("cluster1" "cluster2"), leave empty to check all

TMP_KUBECONFIG="/tmp/tmp_kubeconfig_eks"

# ====== Functions ======

# Function to execute the custom commands with placeholder substitution
execute_custom_commands() {
    local kubeconfig="$1"
    local cluster="$2"
    local profile="$3"
    
    # Check if commands are specified
    if [ ${#CUSTOM_COMMANDS[@]} -eq 0 ] || [ -z "${CUSTOM_COMMANDS[0]}" ]; then
        echo "  ❌ No commands specified to execute"
        return 1
    fi
    
    echo "  Executing ${#CUSTOM_COMMANDS[@]} command(s):"
    
    local overall_success=0
    local command_number=1
    
    for cmd_template in "${CUSTOM_COMMANDS[@]}"; do
        # Replace placeholders in the command
        local cmd="${cmd_template}"
        cmd="${cmd//\{CLUSTER\}/$cluster}"
        cmd="${cmd//\{PROFILE\}/$profile}"
        
        echo ""
        echo "  [$command_number/${#CUSTOM_COMMANDS[@]}] Command: $cmd"
        echo "  Output:"
        
        # Set KUBECONFIG environment variable and execute the command
        KUBECONFIG="$kubeconfig" eval "$cmd"
        local exit_code=$?
        
        if [ $exit_code -ne 0 ]; then
            echo "  ❌ Command $command_number failed with exit code: $exit_code"
            overall_success=1
        else
            echo "  ✅ Command $command_number executed successfully"
        fi
        
        ((command_number++))
        
        # Add separator between commands (except for the last one)
        if [ $command_number -le ${#CUSTOM_COMMANDS[@]} ]; then
            echo "  " $(printf '%.0s-' {1..50})
        fi
    done
    
    if [ $overall_success -eq 0 ]; then
        echo "  🎉 All commands executed successfully!"
    else
        echo "  ⚠️  Some commands failed"
    fi
    
    return $overall_success
}

# ====== Script Begins ======

echo "====== Universal EKS Command Executor ======"
echo "Region: $REGION"
echo "Profiles: ${PROFILES[*]}"

# Display command information
if [ ${#CUSTOM_COMMANDS[@]} -gt 0 ] && [ -n "${CUSTOM_COMMANDS[0]}" ]; then
    echo "Commands to execute (${#CUSTOM_COMMANDS[@]} total):"
    for i in "${!CUSTOM_COMMANDS[@]}"; do
        echo "  $((i+1)). ${CUSTOM_COMMANDS[i]}"
    done
else
    echo "❌ ERROR: No commands specified in CUSTOM_COMMANDS array"
    exit 1
fi

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
    execute_custom_commands "$TMP_KUBECONFIG" "$cluster" "$profile"
    
    echo ""
  done
  
  echo "====== End of Profile: $profile ======" 
  echo ""
done

# Cleanup
rm -f "$TMP_KUBECONFIG"

echo "====== Execution Complete ======" 