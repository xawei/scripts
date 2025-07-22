#!/usr/bin/env bash
set -euo pipefail

# Usage
if [[ -z "${1-}" ]]; then
  echo "Usage: $0 <workloads.json>"
  exit 1
fi

file="$1"
command -v jq >/dev/null || { echo "❌ jq required"; exit 1; }
command -v kubectl >/dev/null || { echo "❌ kubectl required"; exit 1; }

tot_cpu=0
tot_mem=0

to_mcores(){ 
  if [[ "$1" == *m ]]; then 
    echo "${1%m}"
  elif [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "$(( $1 * 1000 ))"
  else
    # Handle fractional cores like "0.1" -> 100m
    echo "$1" | awk '{printf "%d", $1*1000}'
  fi
}

to_bytes(){ 
  echo "$1" | awk '
    /Ki$/{gsub(/Ki$/,""); print int($1*1024); exit} 
    /Mi$/{gsub(/Mi$/,""); print int($1*1024*1024); exit}
    /Gi$/{gsub(/Gi$/,""); print int($1*1024*1024*1024); exit}
    /^[0-9]+$/{print $1; exit}
    /^$/{print 0; exit}
    {print 0; exit}
  '
}

log() { echo "[$(date +'%H:%M:%S')] $*"; }

process_workload(){
  local kind="$1" name="$2" ns="$3"
  log "⏳ Fetching ${kind}/${ns}/${name}"
  
  # Get pod spec with error handling
  if ! podspec=$(kubectl -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.template.spec}' 2>/dev/null); then
    echo "⚠️  Warning: Failed to get ${kind}/${name} in namespace ${ns}"
    echo "0 0"  # Return 0 CPU and 0 memory
    return
  fi
  
  if [[ -z "$podspec" || "$podspec" == "null" ]]; then
    echo "⚠️  Warning: No pod spec found for ${kind}/${name} in namespace ${ns}"
    echo "0 0"
    return
  fi
  
  # Sum for this workload - use process substitution to avoid subshell
  local w_cpu=0 w_mem=0
  
  # Use process substitution instead of pipe to avoid subshell
  while read -r c; do
    [[ -z "$c" || "$c" == "null" ]] && continue
    
    cpu=$(echo "$c" | jq -r '.resources.requests.cpu // "0"')
    mem=$(echo "$c" | jq -r '.resources.requests.memory // "0"')
    
    # Skip if no resources defined
    [[ "$cpu" == "null" || "$cpu" == "0" ]] && cpu="0"
    [[ "$mem" == "null" || "$mem" == "0" ]] && mem="0"
    
    mc=$(to_mcores "$cpu")
    mb=$(($(to_bytes "$mem")/1024/1024))
    
    w_cpu=$((w_cpu+mc))
    w_mem=$((w_mem+mb))
  done < <(echo "$podspec" | jq -c '.containers[]?' 2>/dev/null || echo "")
  
  echo "- ${kind}/${name} => CPU ${w_cpu}m | MEM ${w_mem}Mi" >&2
  
  # Return the values to be captured by caller
  echo "$w_cpu $w_mem"
}

log "✅ Starting resource summary analysis"

# Function to process workloads and accumulate totals
process_workload_list() {
  local json_key="$1"
  local workload_kind="$2"
  
  # Use process substitution to avoid subshell issues
  while read -r obj; do
    [[ -z "$obj" || "$obj" == "null" ]] && continue
    
    name=$(echo "$obj" | jq -r '.name')
    ns=$(echo "$obj" | jq -r '.namespace')
    
    # Capture the output from process_workload
    result=$(process_workload "$workload_kind" "$name" "$ns")
    
    # Extract CPU and memory from the last line of output
    if [[ "$result" =~ ([0-9]+)\ ([0-9]+)$ ]]; then
      w_cpu=${BASH_REMATCH[1]}
      w_mem=${BASH_REMATCH[2]}
      tot_cpu=$((tot_cpu + w_cpu))
      tot_mem=$((tot_mem + w_mem))
    fi
  done < <(jq -c ".${json_key}[]?" "$file" 2>/dev/null || echo "")
}

# Loop through workloads
for kind_pair in "deploy deployment" "sts statefulset"; do
  read -r json_key workload_kind <<< "$kind_pair"
  process_workload_list "$json_key" "$workload_kind"
done

# Add DaemonSets
log "🔁 Including DaemonSets in relevant namespaces"
while read -r ns; do
  [[ -z "$ns" ]] && continue
  
  # Get daemonsets in this namespace
  while read -r ds; do
    [[ -z "$ds" ]] && continue
    name=${ds#daemonset.apps/}
    [[ -z "$name" ]] && continue
    
    result=$(process_workload daemonset "$name" "$ns")
    
    # Extract CPU and memory from the last line of output
    if [[ "$result" =~ ([0-9]+)\ ([0-9]+)$ ]]; then
      w_cpu=${BASH_REMATCH[1]}
      w_mem=${BASH_REMATCH[2]}
      tot_cpu=$((tot_cpu + w_cpu))
      tot_mem=$((tot_mem + w_mem))
    fi
  done < <(kubectl -n "$ns" get daemonsets -o name 2>/dev/null || echo "")
done < <(jq -r '.deploy[]?.namespace, .sts[]?.namespace' "$file" 2>/dev/null | sort -u)

log "✅ Done fetching"

echo
echo "🧮 Total CPU requests: ${tot_cpu}m"
echo "🧮 Total Memory requests: ${tot_mem}Mi"