#!/usr/bin/env bash
set -euo pipefail

# Script to analyze DaemonSet resource requests per node
# This helps determine resource savings when reducing node count by increasing node size
#
# Usage: ./daemonset-resource-calculator.sh

# Check dependencies
command -v kubectl >/dev/null || { echo "❌ kubectl required"; exit 1; }
command -v jq >/dev/null || { echo "❌ jq required"; exit 1; }

# Helper functions
log() { echo "[$(date +'%H:%M:%S')] $*"; }

to_mcores() { 
  if [[ -z "$1" || "$1" == "null" ]]; then
    echo "0"
  elif [[ "$1" == *m ]]; then 
    echo "${1%m}"
  elif [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "$1" | awk '{printf "%d", $1*1000}'
  else
    echo "0"
  fi
}

to_bytes() { 
  if [[ -z "$1" || "$1" == "null" ]]; then
    echo "0"
    return
  fi
  
  echo "$1" | awk '
    /Ki$/{gsub(/Ki$/,""); print int($1*1024); exit} 
    /Mi$/{gsub(/Mi$/,""); print int($1*1024*1024); exit}
    /Gi$/{gsub(/Gi$/,""); print int($1*1024*1024*1024); exit}
    /Ti$/{gsub(/Ti$/,""); print int($1*1024*1024*1024*1024); exit}
    /^[0-9]+$/{print $1; exit}
    /^$/{print 0; exit}
    {print 0; exit}
  '
}

format_cpu() {
  local mcores="$1"
  if [[ "$mcores" -ge 1000 ]]; then
    echo "$mcores" | awk '{printf "%.2f cores", $1/1000}'
  else
    echo "${mcores}m"
  fi
}

format_memory() {
  local bytes="$1"
  if [[ "$bytes" -ge 1073741824 ]]; then
    echo "$bytes" | awk '{printf "%.2f Gi", $1/1073741824}'
  elif [[ "$bytes" -ge 1048576 ]]; then
    echo "$bytes" | awk '{printf "%.2f Mi", $1/1048576}'
  elif [[ "$bytes" -ge 1024 ]]; then
    echo "$bytes" | awk '{printf "%.2f Ki", $1/1024}'
  else
    echo "${bytes} bytes"
  fi
}

# Get cluster information
log "🔍 Gathering cluster information..."

# Get cluster name
CLUSTER_NAME=$(kubectl config current-context)
log "🏷️  Cluster: $CLUSTER_NAME"

# Get total number of nodes
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
log "📊 Total nodes in cluster: $TOTAL_NODES"

# Get all DaemonSets
log "🔍 Finding all DaemonSets..."
DAEMONSETS=$(kubectl get daemonsets --all-namespaces -o json)

if [[ "$(echo "$DAEMONSETS" | jq '.items | length')" -eq 0 ]]; then
  log "ℹ️  No DaemonSets found in the cluster"
  exit 0
fi

# Initialize per-node totals
TOTAL_CPU_PER_NODE_MCORES=0
TOTAL_MEM_PER_NODE_BYTES=0

echo ""
echo "🔍 DaemonSet Analysis (Per Node):"
echo "================================="
printf "%-30s %-20s %-15s %-15s\n" "NAME" "NAMESPACE" "CPU_REQUEST" "MEM_REQUEST"
echo "$(printf '%.0s-' {1..80})"

# Use temp file to store per-node totals (avoid subshell variable issues)
TEMP_TOTALS=$(mktemp)
echo "0 0" > "$TEMP_TOTALS"

while IFS= read -r ds; do
  name=$(echo "$ds" | jq -r '.metadata.name')
  namespace=$(echo "$ds" | jq -r '.metadata.namespace')
  
  # Get pod template spec
  podspec=$(echo "$ds" | jq -r '.spec.template.spec')
  
  # Calculate total resources for this DaemonSet per node
  ds_cpu_mcores=0
  ds_mem_bytes=0
  
  # Process each container
  while IFS= read -r container; do
    # Get CPU request
    cpu_request=$(echo "$container" | jq -r '.resources.requests.cpu // empty')
    cpu_mcores=$(to_mcores "$cpu_request")
    
    # Get memory request
    mem_request=$(echo "$container" | jq -r '.resources.requests.memory // empty')
    mem_bytes=$(to_bytes "$mem_request")
    
    ds_cpu_mcores=$((ds_cpu_mcores + cpu_mcores))
    ds_mem_bytes=$((ds_mem_bytes + mem_bytes))
  done < <(echo "$podspec" | jq -c '.containers[]?' 2>/dev/null)
  
  # Update per-node totals in temp file
  read -r curr_total_cpu curr_total_mem < "$TEMP_TOTALS"
  new_total_cpu=$((curr_total_cpu + ds_cpu_mcores))
  new_total_mem=$((curr_total_mem + ds_mem_bytes))
  echo "$new_total_cpu $new_total_mem" > "$TEMP_TOTALS"
  
  # Format output
  cpu_req_formatted=$(format_cpu "$ds_cpu_mcores")
  mem_req_formatted=$(format_memory "$ds_mem_bytes")
  
  printf "%-30s %-20s %-15s %-15s\n" \
    "$name" "$namespace" "$cpu_req_formatted" "$mem_req_formatted"
done < <(echo "$DAEMONSETS" | jq -c '.items[]')

# Read final per-node totals from temp file
read -r TOTAL_CPU_PER_NODE_MCORES TOTAL_MEM_PER_NODE_BYTES < "$TEMP_TOTALS"
rm -f "$TEMP_TOTALS"

echo ""
echo "📊 Summary:"
echo "==========="
echo "Cluster: $CLUSTER_NAME"
echo "Current state:"
echo "  • Total nodes: $TOTAL_NODES"
echo "  • DaemonSet resources per node:"
echo "    - CPU: $(format_cpu "$TOTAL_CPU_PER_NODE_MCORES")"
echo "    - Memory: $(format_memory "$TOTAL_MEM_PER_NODE_BYTES")"

echo ""
echo "💡 Key Insights:"
echo "==============="
echo "• DaemonSets run exactly one pod per node"
echo "• Each removed node will free up: $(format_cpu "$TOTAL_CPU_PER_NODE_MCORES") CPU + $(format_memory "$TOTAL_MEM_PER_NODE_BYTES") memory"
echo "• This frees up resources that can be used by regular workloads"

log "✅ Analysis complete!" 