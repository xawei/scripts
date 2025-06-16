#!/bin/bash

# ====== Configurable ======
REGION="ap-southeast-1"          # AWS region
PROFILES=("your-profile-name")   # AWS CLI profiles array, e.g. ("profile1" "profile2" "profile3")
NAMESPACES=("default")           # Namespaces to check, e.g. ("default" "kube-system" "app-namespace")

# Specific releases to check (leave empty to check all releases in the namespaces)
TARGET_RELEASES=()              # e.g. ("release1" "release2"), leave empty to check all

# Date/time filter - only show releases deployed after this date
# Format: "YYYY-MM-DD HH:MM:SS" or "YYYY-MM-DD"
# Example: "2024-06-15 10:30:00" or "2024-06-15"
AFTER_DATE=""                   # Set this to filter by date

TMP_KUBECONFIG="/tmp/tmp_kubeconfig_eks"

# ====== Functions ======

# Function to convert date string to timestamp for comparison
date_to_timestamp() {
    local date_str="$1"
    
    # Handle different date formats
    if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        # Add time if only date is provided
        date_str="$date_str 00:00:00"
    fi
    
    # Convert to timestamp (works on both macOS and Linux)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        date -j -f "%Y-%m-%d %H:%M:%S" "$date_str" "+%s" 2>/dev/null
    else
        date -d "$date_str" "+%s" 2>/dev/null
    fi
}

# Function to parse helm history date
parse_helm_date() {
    local helm_date="$1"
    
    # Helm typically shows dates like "Mon Jun 15 10:30:45 2024"
    # Convert to timestamp
    if [[ "$OSTYPE" == "darwin"* ]]; then
        date -j -f "%a %b %d %H:%M:%S %Y" "$helm_date" "+%s" 2>/dev/null
    else
        date -d "$helm_date" "+%s" 2>/dev/null
    fi
}

# Function to get latest release info after specified date
get_latest_release_after_date() {
    local kubeconfig="$1"
    local namespace="$2"
    local release="$3"
    local after_timestamp="$4"
    
    echo "    Checking release: $release"
    
    # Get helm history
    local history_output
    history_output=$(helm --kubeconfig "$kubeconfig" history "$release" -n "$namespace" --output json 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$history_output" ]; then
        echo "      ❌ Failed to get history for release: $release"
        return 1
    fi
    
    # Parse JSON and find latest revision after the specified date
    local latest_revision=""
    local latest_timestamp=0
    local latest_info=""
    
    # Use jq to parse the history (if available), otherwise parse manually
    if command -v jq >/dev/null 2>&1; then
        # Use jq for JSON parsing
        while IFS= read -r line; do
            local revision=$(echo "$line" | jq -r '.revision')
            local updated=$(echo "$line" | jq -r '.updated')
            local status=$(echo "$line" | jq -r '.status')
            local chart=$(echo "$line" | jq -r '.chart')
            local app_version=$(echo "$line" | jq -r '.app_version')
            local description=$(echo "$line" | jq -r '.description')
            
            # Parse the date
            local update_timestamp
            update_timestamp=$(parse_helm_date "$updated")
            
            if [ -n "$update_timestamp" ] && [ "$update_timestamp" -gt "$after_timestamp" ] && [ "$update_timestamp" -gt "$latest_timestamp" ]; then
                latest_timestamp="$update_timestamp"
                latest_revision="$revision"
                latest_info="Revision: $revision, Updated: $updated, Status: $status, Chart: $chart, App Version: $app_version, Description: $description"
            fi
        done < <(echo "$history_output" | jq -c '.[]')
    else
        # Fallback: use helm history without JSON (less reliable but works without jq)
        local history_text
        history_text=$(helm --kubeconfig "$kubeconfig" history "$release" -n "$namespace" 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            # Parse the text output (skip header line)
            echo "$history_text" | tail -n +2 | while IFS= read -r line; do
                if [ -n "$line" ]; then
                    # Extract revision (first column)
                    local revision=$(echo "$line" | awk '{print $1}')
                    # This is a simplified approach - for production use, consider using jq
                    echo "      Found revision: $revision (text parsing - install jq for better parsing)"
                fi
            done
        fi
        return 0
    fi
    
    if [ -n "$latest_revision" ]; then
        echo "      ✅ Latest release after specified date:"
        echo "         $latest_info"
        
        # Get additional details about the latest revision
        echo "      📋 Values for revision $latest_revision:"
        helm --kubeconfig "$kubeconfig" get values "$release" -n "$namespace" --revision "$latest_revision" 2>/dev/null | head -20
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            echo "         ❌ Could not retrieve values"
        fi
        
        return 0
    else
        echo "      ℹ️  No releases found after the specified date"
        return 1
    fi
}

# Function to get all releases in a namespace
get_all_releases() {
    local kubeconfig="$1"
    local namespace="$2"
    
    helm --kubeconfig "$kubeconfig" list -n "$namespace" --output json 2>/dev/null | \
    if command -v jq >/dev/null 2>&1; then
        jq -r '.[].name'
    else
        # Fallback without jq
        helm --kubeconfig "$kubeconfig" list -n "$namespace" --short 2>/dev/null
    fi
}

# ====== Script Begins ======

echo "====== Helm Chart History After Date ======"
echo "Region: $REGION"
echo "Profiles: ${PROFILES[*]}"
echo "Namespaces: ${NAMESPACES[*]}"

# Validate and convert the after date
if [ -z "$AFTER_DATE" ]; then
    echo "❌ ERROR: AFTER_DATE is not set. Please specify a date to filter by."
    echo "   Format: 'YYYY-MM-DD HH:MM:SS' or 'YYYY-MM-DD'"
    echo "   Example: '2024-06-15 10:30:00' or '2024-06-15'"
    exit 1
fi

AFTER_TIMESTAMP=$(date_to_timestamp "$AFTER_DATE")
if [ -z "$AFTER_TIMESTAMP" ]; then
    echo "❌ ERROR: Invalid date format: $AFTER_DATE"
    echo "   Use format: 'YYYY-MM-DD HH:MM:SS' or 'YYYY-MM-DD'"
    exit 1
fi

echo "After Date: $AFTER_DATE (timestamp: $AFTER_TIMESTAMP)"
echo ""

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo "⚠️  WARNING: jq is not installed. Date parsing may be less accurate."
    echo "   Install jq for better JSON parsing: brew install jq (macOS) or apt-get install jq (Ubuntu)"
    echo ""
fi

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

    # Process each namespace
    for namespace in "${NAMESPACES[@]}"; do
      echo "  -- Namespace: $namespace"
      
      # Check if namespace exists
      if ! kubectl --kubeconfig "$TMP_KUBECONFIG" get namespace "$namespace" >/dev/null 2>&1; then
        echo "    ❌ Namespace '$namespace' does not exist"
        continue
      fi
      
      # Get releases to check
      local releases_to_check=()
      if [ ${#TARGET_RELEASES[@]} -gt 0 ]; then
        releases_to_check=("${TARGET_RELEASES[@]}")
      else
        # Get all releases in the namespace
        mapfile -t releases_to_check < <(get_all_releases "$TMP_KUBECONFIG" "$namespace")
      fi
      
      if [ ${#releases_to_check[@]} -eq 0 ]; then
        echo "    ℹ️  No Helm releases found in namespace: $namespace"
        continue
      fi
      
      echo "    Found releases: ${releases_to_check[*]}"
      
      # Check each release
      for release in "${releases_to_check[@]}"; do
        if [ -n "$release" ]; then
          get_latest_release_after_date "$TMP_KUBECONFIG" "$namespace" "$release" "$AFTER_TIMESTAMP"
        fi
      done
      
      echo ""
    done
    
    echo ""
  done
  
  echo "====== End of Profile: $profile ======" 
  echo ""
done

# Cleanup
rm -f "$TMP_KUBECONFIG"

echo "====== Execution Complete ======" 