#!/bin/bash

# Configurable variables
REGION="ap-southeast-1"         # Change to your AWS region
PROFILE="your-profile-name"     # AWS CLI profile name
NAMESPACE="your-namespace"      # Namespace to inspect (e.g., "default")
TMP_KUBECONFIG="/tmp/tmp_kubeconfig_eks"

# Get all EKS clusters
clusters=$(aws eks list-clusters --region "$REGION" --profile "$PROFILE" --output text --query 'clusters[]')

if [ -z "$clusters" ]; then
  echo "No clusters found in region $REGION with profile $PROFILE."
  exit 1
fi

for cluster in $clusters; do
  echo "==> Cluster: $cluster"

  # Generate temporary kubeconfig
  aws eks update-kubeconfig \
    --region "$REGION" \
    --name "$cluster" \
    --kubeconfig "$TMP_KUBECONFIG" \
    --profile "$PROFILE" \
    > /dev/null

  # Get pods and extract images
  pods=$(kubectl --kubeconfig "$TMP_KUBECONFIG" -n "$NAMESPACE" get pods -o json 2>/dev/null)

  if [ $? -ne 0 ]; then
    echo "  ❌ Namespace '$NAMESPACE' not found or inaccessible."
    echo ""
    continue
  fi

  echo "$pods" | jq -r '.items[] | "  Pod: \(.metadata.name)\n    Images: \(.spec.containers[].image)"'

  echo ""
done

# Clean up
rm -f "$TMP_KUBECONFIG"