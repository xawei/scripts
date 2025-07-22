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

to_mcores(){ [[ "$1" == *m ]] && echo "${1%m}" || echo "$(bc <<< "$1*1000" | awk '{printf "%d",$1}')"; }
to_bytes(){ echo "$1" | awk '/Ki$/{print $1*1024} /Mi$/{print $1*1024*1024}/Gi$/{print $1*1024*1024*1024}/^[0-9]+$/{print}'; }

log() { echo "[$(date +'%H:%M:%S')] $*"; }

process_workload(){
  local kind="$1" name="$2" ns="$3"
  log "⏳ Fetching ${kind}/${ns}/${name}"
  podspec=$(kubectl -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.template.spec}')
  # Sum for this workload
  local w_cpu=0 w_mem=0
  echo "$podspec" | jq -c '.containers[]' | while read -r c; do
    cpu=$(echo "$c" | jq -r '.resources.requests.cpu // "0"')
    mem=$(echo "$c" | jq -r '.resources.requests.memory // "0"')
    mc=$(to_mcores "$cpu")
    mb=$(($(to_bytes "$mem")/1024/1024))
    w_cpu=$((w_cpu+mc))
    w_mem=$((w_mem+mb))
  done
  echo "- ${kind}/${name} => CPU ${w_cpu}m | MEM ${w_mem}Mi"
  tot_cpu=$((tot_cpu+w_cpu))
  tot_mem=$((tot_mem+w_mem))
}

log "✅ Starting resource summary analysis"

# Loop through workloads
for kind in deployments statefulsets; do
  jq -c ".${kind}[]" "$file" | while read -r obj; do
    name=$(echo "$obj" | jq -r '.name')
    ns=$(echo "$obj" | jq -r '.namespace')
    process_workload "${kind%?}" "$name" "$ns"
  done
done

# Add DaemonSets
log "🔁 Including DaemonSets in relevant namespaces"
jq -r '.deployments[].namespace, .statefulsets[].namespace' "$file" | sort -u | while read -r ns; do
  kubectl -n "$ns" get daemonsets -o name | while read -r ds; do
    name=${ds#daemonset.apps/}
    process_workload daemonset "$name" "$ns"
  done
done

log "✅ Done fetching"

echo
echo "🧮 Total CPU requests: ${tot_cpu}m"
echo "🧮 Total Memory requests: ${tot_mem}Mi"