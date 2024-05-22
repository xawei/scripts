#!/bin/bash
# Header for output
echo "PodDisruptionBudgets (PDBs) with Zero Allowed Disruptions and Active Pods"
echo "-------------------------------------------------------------------------"
# Collect all PDBs where allowed disruptions are zero and encode in base64 for easier handling
data=$(kubectl get pdb --all-namespaces -o json | jq -r '.items[] | select(.status.disruptionsAllowed == 0) | @base64')
# Check if data is not empty
if [[ -z "$data" ]]; then
    echo "No PDBs with zero allowed disruptions."
    exit 0
fi
# Variables to hold maximum lengths
max_ns=10 # "NAMESPACE"
max_name=8 # "PDB NAME"
max_dis=18 # "ALLOWED DISRUPTIONS"
output_lines=() # Array to hold the formatted lines
# Process each PDB and calculate max lengths
while IFS= read -r encoded_line; do
    # Decode each line from base64 and extract fields
    decoded_line=$(echo "$encoded_line" | base64 --decode)
    namespace=$(echo "$decoded_line" | jq -r '.metadata.namespace')
    name=$(echo "$decoded_line" | jq -r '.metadata.name')
    disruptions=$(echo "$decoded_line" | jq -r '.status.disruptionsAllowed')
    # Extract the selector, safely handling potential complex structures
    selector=$(echo "$decoded_line" | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
    if [ -z "$selector" ]; then
        continue # Skip PDBs with no valid selector
    fi
    # Check if there are any pods matching the PDB selector in the namespace
    pod_count=$(kubectl get pods -n "$namespace" --selector="$selector" --no-headers 2>/dev/null | wc -l | xargs)
    # Skip PDBs that match zero pods or have invalid selectors
    if [ "$pod_count" -eq 0 ]; then
        continue
    fi
    # Calculate column widths dynamically
    [ ${#namespace} -gt $max_ns ] && max_ns=${#namespace}
    [ ${#name} -gt $max_name ] && max_name=${#name}
    [ ${#disruptions} -gt $max_dis ] && max_dis=${#disruptions}
    # Format and save the line
    line_format=$(printf "%-${max_ns}s %-${max_name}s" "$namespace" "$name")
    output_lines+=("$line_format")
done <<< "$data"
# Print the header
printf "%-${max_ns}s %-${max_name}s \n" "NAMESPACE" "PDB NAME"
echo "-------------------------------------------------------------------------"
# Print each stored line from the array with proper alignment
for line in "${output_lines[@]}"; do
    printf "%s\n" "$line"
done
# Check if the array is empty to handle the case of no matching PDBs
if [ ${#output_lines[@]} -eq 0 ]; then
    echo "No active PDBs with zero allowed disruptions found."
fi