#!/bin/bash

# Script to remove finalizers from specific Kubernetes objects
# Usage: ./remove-finalizers.sh <resource-type> <name-pattern> [namespace]
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
    echo "  resource-type    Kubernetes resource type (e.g., managedresources, pods, deployments)"
    echo "  name-pattern     String pattern to match in resource names"
    echo "  namespace        Optional: specific namespace (if not provided, searches all namespaces)"
    echo ""
    echo "Examples:"
    echo "  $0 managedresources 'my-app'                    # Remove finalizers from all MRs containing 'my-app'"
    echo "  $0 pods 'test-' default                         # Remove finalizers from pods containing 'test-' in default namespace"
    echo "  $0 deployments 'old-' kube-system               # Remove finalizers from deployments containing 'old-' in kube-system"
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
if ! kubectl api-resources --no-headers | grep -q "^${RESOURCE_TYPE}\s"; then
    print_error "Invalid resource type: ${RESOURCE_TYPE}"
    print_info "Available resource types:"
    kubectl api-resources --no-headers | awk '{print $1}' | sort
    exit 1
fi

# Build kubectl command
if [ -n "$NAMESPACE" ]; then
    KUBECTL_CMD="kubectl get ${RESOURCE_TYPE} -n ${NAMESPACE}"
    NAMESPACE_FLAG="-n ${NAMESPACE}"
else
    KUBECTL_CMD="kubectl get ${RESOURCE_TYPE} --all-namespaces"
    NAMESPACE_FLAG="--all-namespaces"
fi

print_info "Searching for ${RESOURCE_TYPE} containing '${NAME_PATTERN}' in their names..."

# Get resources matching the pattern
if [ -n "$NAMESPACE" ]; then
    RESOURCES=$(kubectl get ${RESOURCE_TYPE} -n ${NAMESPACE} --no-headers 2>/dev/null | grep "${NAME_PATTERN}" | awk '{print $1}' || true)
else
    RESOURCES=$(kubectl get ${RESOURCE_TYPE} --all-namespaces --no-headers 2>/dev/null | grep "${NAME_PATTERN}" | awk '{print $2 ":" $1}' || true)
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
            if kubectl patch ${RESOURCE_TYPE} ${resource} -n ${NAMESPACE} --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null; then
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
            if kubectl patch ${RESOURCE_TYPE} ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null; then
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
        REMAINING=$(kubectl get ${RESOURCE_TYPE} -n ${NAMESPACE} -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers and (.metadata.finalizers | length > 0) and (.metadata.name | contains("'${NAME_PATTERN}'"))?) | .metadata.name' 2>/dev/null || true)
    else
        REMAINING=$(kubectl get ${RESOURCE_TYPE} --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers and (.metadata.finalizers | length > 0) and (.metadata.name | contains("'${NAME_PATTERN}'"))?) | "\(.metadata.namespace):\(.metadata.name)"' 2>/dev/null || true)
    fi
    
    if [ -n "$REMAINING" ]; then
        print_warning "The following resources still have finalizers:"
        echo "$REMAINING"
    else
        print_success "No remaining ${RESOURCE_TYPE} with finalizers found containing '${NAME_PATTERN}'"
    fi
fi