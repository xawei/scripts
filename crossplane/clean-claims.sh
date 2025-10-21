#!/bin/bash

# Crossplane Claims Cleanup Script
# This script cleans up Crossplane claim resources (namespace-scoped)
# Claims are obtained using: kubectl get claim

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOVE_FINALIZERS_SCRIPT="$SCRIPT_DIR/../k8s/remove_finalizers.sh"

# Default values
NAMESPACE=""
PATTERN=""
DRY_RUN=false
FORCE=false
VERBOSE=false
REMOVE_FINALIZERS=false
CONFIRM=true

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Clean up Crossplane claim resources (namespace-scoped resources from 'kubectl get claim')

Options:
    -n, --namespace NAMESPACE    Target specific namespace (default: all namespaces)
    -p, --pattern PATTERN        Filter claims by name pattern (grep pattern)
    -d, --dry-run               Show what would be deleted without actually deleting
    -f, --force                 Skip confirmation prompts
    -v, --verbose               Enable verbose output
    -r, --remove-finalizers     Remove finalizers if deletion is stuck
    -y, --yes                   Auto-confirm all prompts
    -h, --help                  Show this help message

Examples:
    $0                                    # List all claims in all namespaces
    $0 -n default                        # Clean claims in default namespace
    $0 -p "database"                      # Clean claims matching "database" pattern
    $0 -n production -p "test-" -d        # Dry run for test claims in production namespace
    $0 -f -r                             # Force cleanup with finalizer removal

EOF
}

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi
}

# Check if we can access the cluster
check_cluster_access() {
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot access Kubernetes cluster. Please check your kubeconfig"
        exit 1
    fi
}

# Get all claim resources across all namespaces
get_all_claims() {
    local namespace_flag=""
    if [[ -n "$NAMESPACE" ]]; then
        namespace_flag="-n $NAMESPACE"
    else
        namespace_flag="--all-namespaces"
    fi
    
    log_verbose "Getting all claim resources with: kubectl get claim $namespace_flag"
    
    # Get all claim resources
    local claims_output
    if ! claims_output=$(kubectl get claim $namespace_flag --no-headers 2>/dev/null); then
        log_warning "No claim resources found or unable to access claims"
        return 1
    fi
    
    if [[ -z "$claims_output" ]]; then
        log_info "No claim resources found"
        return 1
    fi
    
    echo "$claims_output"
}

# Filter claims by pattern
filter_claims() {
    local claims="$1"
    
    if [[ -n "$PATTERN" ]]; then
        log_verbose "Filtering claims with pattern: $PATTERN"
        echo "$claims" | grep "$PATTERN" || {
            log_info "No claims match the pattern: $PATTERN"
            return 1
        }
    else
        echo "$claims"
    fi
}

# Display claims in a formatted table
display_claims() {
    local claims="$1"
    
    echo
    log_info "Found Crossplane Claims:"
    echo
    
    if [[ -n "$NAMESPACE" ]]; then
        printf "%-50s %-15s %-10s\n" "TYPE/NAME" "READY" "AGE"
        printf "%-50s %-15s %-10s\n" "---------" "-----" "---"
        echo "$claims" | while read -r line; do
            if [[ -n "$line" ]]; then
                # For single namespace: TYPE/NAME READY READY AGE
                local type_name=$(echo "$line" | awk '{print $1}')
                local ready1=$(echo "$line" | awk '{print $2}')
                local ready2=$(echo "$line" | awk '{print $3}')
                local age=$(echo "$line" | awk '{print $4}')
                printf "%-50s %-15s %-10s\n" "$type_name" "$ready2" "$age"
            fi
        done
    else
        printf "%-15s %-50s %-15s %-10s\n" "NAMESPACE" "TYPE/NAME" "READY" "AGE"
        printf "%-15s %-50s %-15s %-10s\n" "---------" "---------" "-----" "---"
        echo "$claims" | while read -r line; do
            if [[ -n "$line" ]]; then
                # For all namespaces: NAMESPACE TYPE/NAME READY READY AGE
                local ns=$(echo "$line" | awk '{print $1}')
                local type_name=$(echo "$line" | awk '{print $2}')
                local ready1=$(echo "$line" | awk '{print $3}')
                local ready2=$(echo "$line" | awk '{print $4}')
                local age=$(echo "$line" | awk '{print $5}')
                printf "%-15s %-50s %-15s %-10s\n" "$ns" "$type_name" "$ready2" "$age"
            fi
        done
    fi
    echo
}

# Get claim details for deletion
get_claim_details() {
    local claims="$1"
    local claim_details=()
    
    while read -r line; do
        if [[ -n "$line" ]]; then
            if [[ -n "$NAMESPACE" ]]; then
                # Single namespace format: TYPE/NAME READY READY AGE
                local type_name=$(echo "$line" | awk '{print $1}')
                # Split TYPE/NAME into type and name
                local type=$(echo "$type_name" | cut -d'/' -f1)
                local name=$(echo "$type_name" | cut -d'/' -f2)
                claim_details+=("$NAMESPACE:$name:$type")
            else
                # All namespaces format: NAMESPACE TYPE/NAME READY READY AGE
                local ns=$(echo "$line" | awk '{print $1}')
                local type_name=$(echo "$line" | awk '{print $2}')
                # Split TYPE/NAME into type and name
                local type=$(echo "$type_name" | cut -d'/' -f1)
                local name=$(echo "$type_name" | cut -d'/' -f2)
                claim_details+=("$ns:$name:$type")
            fi
        fi
    done <<< "$claims"
    
    printf '%s\n' "${claim_details[@]}"
}

# Delete a single claim
delete_claim() {
    local namespace="$1"
    local name="$2"
    local type="$3"
    
    log_verbose "Deleting claim: $type/$name in namespace $namespace"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would delete: $type/$name in namespace $namespace"
        return 0
    fi
    
    # Attempt to delete the claim
    if kubectl delete "$type" "$name" -n "$namespace" --timeout=30s 2>/dev/null; then
        log_success "Deleted claim: $type/$name in namespace $namespace"
        return 0
    else
        log_warning "Failed to delete claim: $type/$name in namespace $namespace"
        
        if [[ "$REMOVE_FINALIZERS" == "true" ]]; then
            log_info "Attempting to remove finalizers for: $type/$name"
            
            if [[ -f "$REMOVE_FINALIZERS_SCRIPT" ]]; then
                if "$REMOVE_FINALIZERS_SCRIPT" "$type" "$name" -n "$namespace"; then
                    log_success "Finalizers removed for: $type/$name"
                    # Try deletion again
                    if kubectl delete "$type" "$name" -n "$namespace" --timeout=30s 2>/dev/null; then
                        log_success "Deleted claim after finalizer removal: $type/$name"
                        return 0
                    else
                        log_error "Still unable to delete claim: $type/$name"
                        return 1
                    fi
                else
                    log_error "Failed to remove finalizers for: $type/$name"
                    return 1
                fi
            else
                log_error "Finalizer removal script not found: $REMOVE_FINALIZERS_SCRIPT"
                return 1
            fi
        fi
        return 1
    fi
}

# Confirm deletion
confirm_deletion() {
    local count="$1"
    
    if [[ "$FORCE" == "true" ]] || [[ "$CONFIRM" == "false" ]]; then
        return 0
    fi
    
    echo
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warning "This is a DRY RUN. No actual deletions will be performed."
    else
        log_warning "This will delete $count Crossplane claim resource(s)."
        log_warning "This action cannot be undone!"
    fi
    echo
    
    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
}

# Main cleanup function
cleanup_claims() {
    log_info "Starting Crossplane claims cleanup..."
    
    # Get all claims
    local all_claims
    if ! all_claims=$(get_all_claims); then
        exit 0
    fi
    
    # Filter claims if pattern is provided
    local filtered_claims
    if ! filtered_claims=$(filter_claims "$all_claims"); then
        exit 0
    fi
    
    # Display found claims
    display_claims "$filtered_claims"
    
    # Get claim details for deletion
    local claim_details
    claim_details=$(get_claim_details "$filtered_claims")
    
    local claim_count
    claim_count=$(echo "$claim_details" | wc -l)
    
    if [[ $claim_count -eq 0 ]]; then
        log_info "No claims to delete"
        exit 0
    fi
    
    # Confirm deletion
    confirm_deletion "$claim_count"
    
    # Delete claims
    log_info "Processing $claim_count claim(s)..."
    echo
    
    local success_count=0
    local failure_count=0
    
    while read -r detail; do
        if [[ -n "$detail" ]]; then
            IFS=':' read -r ns name type <<< "$detail"
            if delete_claim "$ns" "$name" "$type"; then
                ((success_count++))
            else
                ((failure_count++))
            fi
        fi
    done <<< "$claim_details"
    
    echo
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "Dry run completed. No actual changes were made."
    elif [[ $failure_count -eq 0 ]]; then
        log_success "Claims cleanup completed successfully! Deleted $success_count claim(s)."
    elif [[ $success_count -eq 0 ]]; then
        log_error "Claims cleanup failed! Unable to delete any of the $failure_count claim(s)."
        exit 1
    else
        log_warning "Claims cleanup partially completed. Deleted $success_count claim(s), failed to delete $failure_count claim(s)."
        exit 1
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -p|--pattern)
            PATTERN="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -r|--remove-finalizers)
            REMOVE_FINALIZERS=true
            shift
            ;;
        -y|--yes)
            CONFIRM=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    check_kubectl
    check_cluster_access
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Script configuration:"
        log_info "  Namespace: ${NAMESPACE:-'all namespaces'}"
        log_info "  Pattern: ${PATTERN:-'none'}"
        log_info "  Dry run: $DRY_RUN"
        log_info "  Force: $FORCE"
        log_info "  Remove finalizers: $REMOVE_FINALIZERS"
        echo
    fi
    
    cleanup_claims
}

# Run main function
main