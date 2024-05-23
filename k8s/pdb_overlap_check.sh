 #!/bin/bash
 # Color codes
 RED='\033[0;31m'
 GREEN='\033[0;32m'
 YELLOW='\033[1;33m'
 NC='\033[0m' # No Color
 # Fetch all PDBs across all namespaces
 pdb_data=$(kubectl get pdb --all-namespaces -o json 2>&1)
 # Check if the kubectl command succeeded
 if [ $? -ne 0 ]; then
     echo -e "${RED}Failed to fetch PodDisruptionBudgets. Please check your network connection or Kubernetes configuration. Error: $pdb_data${NC}"
     exit 1
 fi
 # Check if we have any PDBs at all
 if echo "$pdb_data" | jq -e '.items | length == 0' >/dev/null; then
     echo -e "${RED}No PodDisruptionBudgets found in any namespace.${NC}"
     exit 0
 fi
 # Create a temporary file with a unique name using mktemp
 tmpfile=$(mktemp /tmp/pdb_info.XXXXXX)
 # Parse PDB names, namespaces, and selectors
 echo "$pdb_data" | jq -r '.items[] | .metadata.name + "," + .metadata.namespace + "," + (.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(","))' > "$tmpfile"
 # Prepare to display overlaps
 echo -e "${YELLOW}Checking for overlaps...${NC}"
 overlaps_found=false
 overlaps=()
 checked_pairs=()
 max_name_length=8 # Minimum length to accommodate "PDB Name"
 max_namespace_length=9 # Minimum length to accommodate "Namespace"
 # Determine the maximum lengths of PDB names and namespaces
 while IFS=',' read -r name namespace selector; do
     if [[ ${#name} -gt $max_name_length ]]; then
         max_name_length=${#name}
     fi
     if [[ ${#namespace} -gt $max_namespace_length ]]; then
         max_namespace_length=${#namespace}
     fi
 done < "$tmpfile"
 # Add padding for better visibility in the table
 max_name_length=$((max_name_length + 2))
 max_namespace_length=$((max_namespace_length + 2))
 # Check for overlaps
 while IFS=',' read -r name namespace selector; do
     # Check for overlap
     while IFS=',' read -r check_name check_namespace check_selector; do
         if [[ "$name" != "$check_name" && "$selector" == "$check_selector" && "$namespace" == "$check_namespace" ]]; then
             # Sort the names to ensure consistent pair ordering
             if [[ "$name" < "$check_name" ]]; then
                 pair_key="${name}-${check_name}"
             else
                 pair_key="${check_name}-${name}"
             fi
             if [[ ! " ${checked_pairs[*]} " =~ " ${pair_key} " ]]; then
                 overlap_message=$(printf "%-${max_name_length}s %-${max_namespace_length}s %s" "$name" "$namespace" "$check_name")
                 overlaps+=("$overlap_message")
                 checked_pairs+=("$pair_key")
                 overlaps_found=true
             fi
         fi
     done < "$tmpfile"
 done < "$tmpfile"
 # Display results
 if $overlaps_found; then
     echo -e "${YELLOW}Overlap found:${NC}"
     printf "%-${max_name_length}s %-${max_namespace_length}s %s\n" "PDB Name" "Namespace" "Overlaps With"
     for overlap in "${overlaps[@]}"; do
         echo -e "$overlap"
     done
 else
     echo -e "${GREEN}No overlapping PodDisruptionBudgets found.${NC}"
 fi
 # Clean up temporary file
 rm "$tmpfile"