#!/bin/bash
 
 # Function to print a section header
 print_header() {
     echo "====================================="
     echo "$1"
     echo "====================================="
 }
 
 # Function to print the output in a formatted way
 print_output() {
     printf "%-20s %-25s %-40s\n" "$1" "$2" "$3"
 }
 
 # Check if the necessary AWS CLI commands are available
 if ! command -v aws &> /dev/null
 then
     echo "AWS CLI not found. Please install it to proceed."
     exit 1
 fi
 
 # Check if EKS version and add-ons are provided
 if [ -z "$1" ] || [ -z "$2" ]; then
     echo "Usage: $0 <eks_version> <comma_separated_addons>"
     exit 1
 fi
 
 EKS_VERSION=$1
 ADDONS=$2
 
 print_header "Checking Compatibility for EKS Version $EKS_VERSION"
 
 # Print the table header
 print_output "Add-On" "Default Version" "Supported Versions"
 
 # Loop through the add-ons to check their versions
 IFS=',' read -r -a ADDON_ARRAY <<< "$ADDONS"
 for ADDON in "${ADDON_ARRAY[@]}"
 do
     # Retrieve the add-on versions and filter by EKS version
     ADDON_VERSIONS=$(aws eks describe-addon-versions --addon-name "$ADDON" --query "addons[0].addonVersions" --output json)
 
     # Extract the default version
     DEFAULT_VERSION=$(echo "$ADDON_VERSIONS" | jq -r --arg EKS_VERSION "$EKS_VERSION" '.[] | select(.compatibilities[] | select(.clusterVersion == $EKS_VERSION) | .defaultVersion == true) | .addonVersion')
 
     # Extract all supported versions
     SUPPORTED_VERSIONS=$(echo "$ADDON_VERSIONS" | jq -r --arg EKS_VERSION "$EKS_VERSION" '.[] | select(.compatibilities[] | select(.clusterVersion == $EKS_VERSION)) | .addonVersion' | paste -sd "," -)
 
     # Check for empty or null values
     if [ -z "$DEFAULT_VERSION" ] || [ "$DEFAULT_VERSION" == "null" ]; then
         DEFAULT_VERSION="No default version found"
     fi
 
     if [ -z "$SUPPORTED_VERSIONS" ] || [ "$SUPPORTED_VERSIONS" == "null" ]; then
         SUPPORTED_VERSIONS="No supported versions found"
     fi
 
     print_output "$ADDON" "$DEFAULT_VERSION" "$SUPPORTED_VERSIONS"
 done