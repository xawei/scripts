#!/bin/bash

# Script to remove finalizers from specific Kubernetes objects
# Usage: ./remove-finalizers.sh <resource-type> <name-pattern> [namespace]
# Example: ./remove-finalizers.sh managedresources.crossplane.io "my-app" crossplane-system
# Example: ./remove-finalizers.sh managedresources "my-app" crossplane-system

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 <resource-type> <name-pattern> [namespace]"
    echo ""
    echo "Arguments:"
    echo "  resource-type    Kubernetes resource type (short name or full CRD name)"
    echo "                   Examples: managedresources, managedresources.crossplane.io, pods, deployments"
    echo "  name-pattern     String pattern to match in resource names"
    echo "  namespace        Optional: specific namespace (if not provided, searches all namespaces)"
    echo ""
    echo "Examples:"
    echo "  $0 managedresources 'my-app'                              # Short name"
    echo "  $0 managedresources.crossplane.io 'my-app'                # Full CRD name"
    echo "  $0 pods 'test-' default                                   # Built-in resource"
    echo "  $0 deployments.apps 'old-' kube-system                   # Full API group"
    echo ""
    echo "To list available resource types:"
    echo "  kubectl api-resources"
}

# Function to validate resource type
validate_resource_type() {
    local resource_type="$1"
    
    # Check if it's a valid resource type (either short name or full name)
    if kubectl api-resources --no-headers | awk '{print $1}' | grep -q "^${resource_type}$"; then
        return 0
    fi
    
    # Check if it's a valid full name (NAME.GROUP)
    if kubectl api-resources --no-headers | awk '{print $1"."$3}' | grep -q "^${resource_type}$"; then
        return 0
    fi
    
    # Check if it's a valid full name with version (NAME.VERSION.GROUP)
    if kubectl api-resources --no-headers | awk '{if($3) print $1"."$2"."$3; else print $1"."$2}' | grep -q "^${resource_type}$"; then
        return 0
    fi
    
    return 1
}

# Function to get the correct resource name for kubectl commands
get_kubectl_resource_name() {
    local resource_type="$1"
    
    # If it's already a short name that exists, use it
    if kubectl api-resources --no-headers | awk '{print $1}' | grep -q "^${resource_type}$"; then
        echo "$resource_type"
        return 0
    fi
    
    # If it's a full name, try to find the corresponding short name
    local short_name=$(kubectl api-resources --no-headers | awk -v full="$resource_type" '
        {
            if ($3) {
                full_name = $1"."$3
                full_name_with_version = $1"."$2"."$3
            } else {
                full_name = $1"."$2
                full_name_with_version = $1"."$2
            }
            if (full_name == full || full_name_with_version == full) {
                print $1
                exit
            }
        }')
    
    if [ -n "$short_name" ]; then
        echo "$short_name"
    else
        echo "$resource_type"
    fi
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed or not in PATH"
    exit 1
fi

# Check arguments
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    print_error "Invalid number of arguments"
    show_usage
    exit 1
fi

RESOURCE_TYPE="$1"
NAME_PATTERN="$2"
NAMESPACE="$3"

# Validate resource type
if ! validate_resource_type "$RESOURCE_TYPE"; then
    print_error "Invalid resource type: ${RESOURCE_TYPE}"
    print_info "Available resource types (short names):"
    kubectl api-resources --no-headers | awk '{print "  " $1}' | sort
    echo ""
    print_info "Available resource types (full names):"
    kubectl api-resources --no-headers | awk '{if($3) print "  " $1"."$3; else print "  " $1"."$2}' | sort
    exit 1
fi

# Get the correct resource name for kubectl commands
KUBECTL_RESOURCE=$(get_kubectl_resource_name "$RESOURCE_TYPE")

print_info "Using resource type: ${RESOURCE_TYPE} (kubectl: ${KUBECTL_RESOURCE})"
print_info "Searching for ${RESOURCE_TYPE} containing '${NAME_PATTERN}' in their names..."

# Get resources matching the pattern
if [ -n "$NAMESPACE" ]; then
    RESOURCES=$(kubectl get ${KUBECTL_RESOURCE} -n ${NAMESPACE} --no-headers 2>/dev/null | grep "${NAME_PATTERN}" | awk '{print $1}' || true)
else
    RESOURCES=$(kubectl get ${KUBECTL_RESOURCE} --all-namespaces --no-headers 2>/dev/null | grep "${NAME_PATTERN}" | awk '{print $2 ":" $1}' || true)
fi

if [ -z "$RESOURCES" ]; then
    print_warning "No ${RESOURCE_TYPE} found containing '${NAME_PATTERN}' in their names"
    exit 0
fi

print_info "Found the following ${RESOURCE_TYPE} that will have their finalizers removed:"
echo ""

# Display resources in a formatted way
if [ -n "$NAMESPACE" ]; then
    echo "NAMESPACE: ${NAMESPACE}"
    echo "RESOURCES:"
    echo "$RESOURCES" | while read -r resource; do
        echo "  - ${resource}"
    done
else
    echo "NAMESPACE:RESOURCE"
    echo "$RESOURCES" | while read -r resource; do
        echo "  - ${resource}"
    done
fi

echo ""
print_warning "This will remove ALL finalizers from the above resources!"
print_warning "This action cannot be undone and may cause resource cleanup issues."
echo ""

# Ask for confirmation
read -p "Do you want to proceed? (yes/no): " confirmation

if [ "$confirmation" != "yes" ] && [ "$confirmation" != "y" ]; then
    print_info "Operation cancelled by user"
    exit 0
fi

print_info "Proceeding with finalizer removal..."
echo ""

# Remove finalizers
SUCCESS_COUNT=0
ERROR_COUNT=0

if [ -n "$NAMESPACE" ]; then
    echo "$RESOURCES" | while read -r resource; do
        if [ -n "$resource" ]; then
            print_info "Removing finalizers from ${resource} in namespace ${NAMESPACE}..."
            if kubectl patch ${KUBECTL_RESOURCE} ${resource} -n ${NAMESPACE} --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null; then
                print_success "Successfully removed finalizers from ${resource}"
                ((SUCCESS_COUNT++))
            else
                print_error "Failed to remove finalizers from ${resource}"
                ((ERROR_COUNT++))
            fi
        fi
    done
else
    echo "$RESOURCES" | while read -r resource; do
        if [ -n "$resource" ]; then
            RESOURCE_NAMESPACE=$(echo "$resource" | cut -d':' -f1)
            RESOURCE_NAME=$(echo "$resource" | cut -d':' -f2)
            print_info "Removing finalizers from ${RESOURCE_NAME} in namespace ${RESOURCE_NAMESPACE}..."
            if kubectl patch ${KUBECTL_RESOURCE} ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null; then
                print_success "Successfully removed finalizers from ${RESOURCE_NAME}"
                ((SUCCESS_COUNT++))
            else
                print_error "Failed to remove finalizers from ${RESOURCE_NAME}"
                ((ERROR_COUNT++))
            fi
        fi
    done
fi

echo ""
print_info "Operation completed!"
print_success "Successfully processed: ${SUCCESS_COUNT} resources"
if [ $ERROR_COUNT -gt 0 ]; then
    print_error "Failed to process: ${ERROR_COUNT} resources"
fi

# Optional: Show remaining resources with finalizers
echo ""
read -p "Do you want to check for remaining resources with finalizers? (yes/no): " check_remaining

if [ "$check_remaining" = "yes" ] || [ "$check_remaining" = "y" ]; then
    print_info "Checking for remaining ${RESOURCE_TYPE} with finalizers containing '${NAME_PATTERN}'..."
    
    if [ -n "$NAMESPACE" ]; then
        REMAINING=$(kubectl get ${KUBECTL_RESOURCE} -n ${NAMESPACE} -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers and (.metadata.finalizers | length > 0) and (.metadata.name | contains("'${NAME_PATTERN}'"))) | .metadata.name' 2>/dev/null || true)
    else
        REMAINING=$(kubectl get ${KUBECTL_RESOURCE} --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers and (.metadata.finalizers | length > 0) and (.metadata.name | contains("'${NAME_PATTERN}'"))) | "\(.metadata.namespace):\(.metadata.name)"' 2>/dev/null || true)
    fi
    
    if [ -n "$REMAINING" ]; then
        print_warning "The following resources still have finalizers:"
        echo "$REMAINING"
    else
        print_success "No remaining ${RESOURCE_TYPE} with finalizers found containing '${NAME_PATTERN}'"
    fi
fi