#!/bin/bash

# ====== Configurable ======
REGION="ap-southeast-1"          # AWS region
PROFILES=("your-profile-name")   # AWS CLI profiles array, e.g. ("profile1" "profile2" "profile3")
NAMESPACE="default"              # Namespace to inspect

DEPLOYMENTS=()                   # e.g. ("api" "web"), leave empty to check all
DAEMONSETS=()                    # e.g. ("fluentd"), leave empty to check all
STATEFULSETS=()                  # e.g. ("mysql"), leave empty to check all

TMP_KUBECONFIG="/tmp/tmp_kubeconfig_eks"

# ====== Script Begins ======

for profile in "${PROFILES[@]}"; do
  echo "====== AWS Profile: $profile ======"
  
  clusters=$(aws eks list-clusters --region "$REGION" --profile "$profile" --output text --query 'clusters[]')

  if [ -z "$clusters" ]; then
    echo "❌ No EKS clusters found in region $REGION using profile $profile."
    echo ""
    continue
  fi

  for cluster in $clusters; do
    echo "==> Cluster: $cluster"

    aws eks update-kubeconfig \
      --region "$REGION" \
      --name "$cluster" \
      --kubeconfig "$TMP_KUBECONFIG" \
      --profile "$profile" \
      > /dev/null

    echo "-- Namespace: $NAMESPACE"

    # === Deployments ===
    echo ">> Deployments"
    local_deployments=("${DEPLOYMENTS[@]}")
    if [ ${#local_deployments[@]} -eq 0 ]; then
      local_deployments=($(kubectl --kubeconfig "$TMP_KUBECONFIG" -n "$NAMESPACE" get deployments -o jsonpath='{.items[*].metadata.name}'))
    fi

    for deploy in "${local_deployments[@]}"; do
      images=$(kubectl --kubeconfig "$TMP_KUBECONFIG" -n "$NAMESPACE" get deployment "$deploy" \
        -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null)

      if [ $? -eq 0 ]; then
        echo "  ✅ Deployment: $deploy"
        for img in $images; do
          echo "    Image: $img"
        done
      else
        echo "  ❌ Deployment: $deploy not found."
      fi
    done

    # === DaemonSets ===
    echo ">> DaemonSets"
    local_daemonsets=("${DAEMONSETS[@]}")
    if [ ${#local_daemonsets[@]} -eq 0 ]; then
      local_daemonsets=($(kubectl --kubeconfig "$TMP_KUBECONFIG" -n "$NAMESPACE" get daemonsets -o jsonpath='{.items[*].metadata.name}'))
    fi

    for ds in "${local_daemonsets[@]}"; do
      images=$(kubectl --kubeconfig "$TMP_KUBECONFIG" -n "$NAMESPACE" get daemonset "$ds" \
        -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null)

      if [ $? -eq 0 ]; then
        echo "  ✅ DaemonSet: $ds"
        for img in $images; do
          echo "    Image: $img"
        done
      else
        echo "  ❌ DaemonSet: $ds not found."
      fi
    done

    # === StatefulSets ===
    echo ">> StatefulSets"
    local_statefulsets=("${STATEFULSETS[@]}")
    if [ ${#local_statefulsets[@]} -eq 0 ]; then
      local_statefulsets=($(kubectl --kubeconfig "$TMP_KUBECONFIG" -n "$NAMESPACE" get statefulsets -o jsonpath='{.items[*].metadata.name}'))
    fi

    for sts in "${local_statefulsets[@]}"; do
      images=$(kubectl --kubeconfig "$TMP_KUBECONFIG" -n "$NAMESPACE" get statefulset "$sts" \
        -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null)

      if [ $? -eq 0 ]; then
        echo "  ✅ StatefulSet: $sts"
        for img in $images; do
          echo "    Image: $img"
        done
      else
        echo "  ❌ StatefulSet: $sts not found."
      fi
    done

    echo ""
  done
  
  echo "====== End of Profile: $profile ======" 
  echo ""
done

# Cleanup
rm -f "$TMP_KUBECONFIG"