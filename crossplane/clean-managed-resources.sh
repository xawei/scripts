#!/bin/bash

# Script to clean Crossplane managed resources with AWS resource cleanup
# Usage: ./clean-managed-resources.sh [resource-name-pattern] [namespace] [--force-aws-cleanup]
# Example: ./clean-managed-resources.sh "my-app" default
# Example: ./clean-managed-resources.sh "test-" --force-aws-cleanup

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
    echo "Usage: $0 [resource-name-pattern] [namespace] [--force-aws-cleanup]"
    echo ""
    echo "Arguments:"
    echo "  resource-name-pattern   Optional: String pattern to match in resource names"
    echo "  namespace              Optional: specific namespace (default: all namespaces)"
    echo "  --force-aws-cleanup    Optional: Force AWS resource cleanup before deleting MRs"
    echo ""
    echo "Examples:"
    echo "  $0                                           # Clean all managed resources"
    echo "  $0 'my-app'                                 # Clean MRs containing 'my-app'"
    echo "  $0 'test-' crossplane-system                # Clean MRs in specific namespace"
    echo "  $0 'my-app' '' --force-aws-cleanup          # Force AWS cleanup first"
    echo ""
    echo "This script will:"
    echo "  1. Identify Crossplane managed resources"
    echo "  2. Optionally clean up associated AWS resources"
    echo "  3. Delete managed resources"
    echo "  4. Remove finalizers if resources are stuck"
}

# Check required tools
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed or not in PATH"
    exit 1
fi

# Parse arguments
RESOURCE_PATTERN=""
NAMESPACE=""
FORCE_AWS_CLEANUP=false

for arg in "$@"; do
    case $arg in
        --force-aws-cleanup)
            FORCE_AWS_CLEANUP=true
            shift
            ;;
        *)
            if [ -z "$RESOURCE_PATTERN" ]; then
                RESOURCE_PATTERN="$arg"
            elif [ -z "$NAMESPACE" ]; then
                NAMESPACE="$arg"
            fi
            shift
            ;;
    esac
done

# Check if AWS CLI is available for AWS cleanup
AWS_CLI_AVAILABLE=false
if command -v aws &> /dev/null; then
    AWS_CLI_AVAILABLE=true
    print_info "AWS CLI detected - AWS resource cleanup will be available"
else
    print_warning "AWS CLI not found - AWS resource cleanup will be skipped"
fi

# Get all Crossplane managed resource types
get_managed_resource_types() {
    kubectl api-resources --no-headers 2>/dev/null | \
        awk '$3 ~ /crossplane\.io/ && $1 !~ /claim/ && $1 !~ /composite/ && $1 !~ /definition/ && $1 !~ /configuration/ {print $1}' || true
}

MR_TYPES=$(get_managed_resource_types)

if [ -z "$MR_TYPES" ]; then
    print_warning "No Crossplane managed resource types found in the cluster"
    exit 0
fi

print_info "Found managed resource types: $(echo $MR_TYPES | tr '\n' ' ')"

# Function to get managed resources matching pattern
get_matching_resources() {
    local resource_type="$1"
    local pattern="$2"
    local ns="$3"
    
    if [ -n "$ns" ]; then
        if [ -n "$pattern" ]; then
            kubectl get "$resource_type" -n "$ns" --no-headers 2>/dev/null | \
                grep "$pattern" | awk '{print $1}' || true
        else
            kubectl get "$resource_type" -n "$ns" --no-headers 2>/dev/null | \
                awk '{print $1}' || true
        fi
    else
        if [ -n "$pattern" ]; then
            kubectl get "$resource_type" --all-namespaces --no-headers 2>/dev/null | \
                grep "$pattern" | awk '{print $2 ":" $1}' || true
        else
            kubectl get "$resource_type" --all-namespaces --no-headers 2>/dev/null | \
                awk '{print $2 ":" $1}' || true
        fi
    fi
}

# Function to extract AWS resource info from managed resource
get_aws_resource_info() {
    local resource_type="$1"
    local resource_name="$2"
    local resource_ns="$3"
    
    local resource_json
    resource_json=$(kubectl get "$resource_type" "$resource_name" -n "$resource_ns" -o json 2>/dev/null || echo '{}')
    
    # Extract AWS resource ID/ARN from various possible fields
    local aws_id
    aws_id=$(echo "$resource_json" | jq -r '
        .status.atProvider.id // 
        .status.atProvider.arn // 
        .status.atProvider.instanceId // 
        .status.atProvider.vpcId // 
        .status.atProvider.subnetId // 
        .status.atProvider.securityGroupId // 
        .status.atProvider.roleArn // 
        .metadata.annotations["crossplane.io/external-name"] // 
        "unknown"' 2>/dev/null || echo "unknown")
    
    # Extract AWS region
    local aws_region
    aws_region=$(echo "$resource_json" | jq -r '
        .spec.forProvider.region // 
        .spec.providerConfigRef.name // 
        "us-east-1"' 2>/dev/null || echo "us-east-1")
    
    echo "${aws_id}:${aws_region}"
}

# Function to cleanup AWS resource
cleanup_aws_resource() {
    local resource_type="$1"
    local aws_info="$2"
    
    local aws_id=$(echo "$aws_info" | cut -d':' -f1)
    local aws_region=$(echo "$aws_info" | cut -d':' -f2)
    
    if [ "$aws_id" = "unknown" ] || [ "$aws_id" = "null" ]; then
        print_warning "Cannot determine AWS resource ID for cleanup"
        return 1
    fi
    
    print_info "Attempting to cleanup AWS resource: $aws_id in region $aws_region"
    
    # Determine AWS service and cleanup command based on resource type
    case "$resource_type" in
        *instance*|*ec2*)
            print_info "Terminating EC2 instance: $aws_id"
            aws ec2 terminate-instances --instance-ids "$aws_id" --region "$aws_region" 2>/dev/null || true
            ;;
        *vpc*)
            print_info "Deleting VPC: $aws_id"
            aws ec2 delete-vpc --vpc-id "$aws_id" --region "$aws_region" 2>/dev/null || true
            ;;
        *subnet*)
            print_info "Deleting subnet: $aws_id"
            aws ec2 delete-subnet --subnet-id "$aws_id" --region "$aws_region" 2>/dev/null || true
            ;;
        *securitygroup*)
            print_info "Deleting security group: $aws_id"
            aws ec2 delete-security-group --group-id "$aws_id" --region "$aws_region" 2>/dev/null || true
            ;;
        *role*|*iam*)
            print_info "Deleting IAM role: $aws_id"
            aws iam delete-role --role-name "$aws_id" --region "$aws_region" 2>/dev/null || true
            ;;
        *bucket*|*s3*)
            print_info "Deleting S3 bucket: $aws_id"
            aws s3 rb "s3://$aws_id" --force --region "$aws_region" 2>/dev/null || true
            ;;
        *rds*|*database*)
            print_info "Deleting RDS instance: $aws_id"
            aws rds delete-db-instance --db-instance-identifier "$aws_id" --skip-final-snapshot --region "$aws_region" 2>/dev/null || true
            ;;
        *)
            print_warning "Unknown resource type '$resource_type' - manual AWS cleanup may be required for: $aws_id"
            return 1
            ;;
    esac
    
    return 0
}

# Collect all matching managed resources
ALL_RESOURCES=""
for resource_type in $MR_TYPES; do
    resources=$(get_matching_resources "$resource_type" "$RESOURCE_PATTERN" "$NAMESPACE")
    if [ -n "$resources" ]; then
        if [ -n "$ALL_RESOURCES" ]; then
            ALL_RESOURCES="$ALL_RESOURCES\n$resource_type:$resources"
        else
            ALL_RESOURCES="$resource_type:$resources"
        fi
    fi
done

if [ -z "$ALL_RESOURCES" ]; then
    if [ -n "$RESOURCE_PATTERN" ]; then
        print_warning "No managed resources found matching pattern '${RESOURCE_PATTERN}'"
    else
        print_warning "No managed resources found"
    fi
    exit 0
fi

print_info "Found the following managed resources that will be cleaned up:"
echo ""

# Display resources in a formatted way
echo -e "$ALL_RESOURCES" | while IFS=':' read -r resource_type resource_info; do
    if [ -n "$resource_info" ]; then
        echo "TYPE: $resource_type"
        if [ -n "$NAMESPACE" ]; then
            echo "NAMESPACE: $NAMESPACE"
            echo "RESOURCES:"
            echo "$resource_info" | while read -r resource; do
                if [ -n "$resource" ]; then
                    echo "  - $resource"
                fi
            done
        else
            echo "NAMESPACE:RESOURCE"
            echo "$resource_info" | while read -r resource; do
                if [ -n "$resource" ]; then
                    echo "  - $resource"
                fi
            done
        fi
        echo ""
    fi
done

print_warning "This will clean up AWS resources and delete ALL the above managed resources!"
print_warning "This action cannot be undone and will permanently delete AWS infrastructure."
echo ""

if [ "$FORCE_AWS_CLEANUP" = true ]; then
    print_warning "AWS cleanup is ENABLED - external AWS resources will be deleted first!"
fi

echo ""

# Ask for confirmation
read -p "Do you want to proceed? (yes/no): " confirmation

if [ "$confirmation" != "yes" ] && [ "$confirmation" != "y" ]; then
    print_info "Operation cancelled by user"
    exit 0
fi

print_info "Proceeding with managed resource cleanup..."
echo ""

# Process each resource
SUCCESS_COUNT=0
ERROR_COUNT=0
AWS_CLEANUP_COUNT=0

echo -e "$ALL_RESOURCES" | while IFS=':' read -r resource_type resource_info; do
    if [ -n "$resource_info" ]; then
        echo "$resource_info" | while read -r resource; do
            if [ -n "$resource" ]; then
                if [ -n "$NAMESPACE" ]; then
                    resource_name="$resource"
                    resource_ns="$NAMESPACE"
                else
                    resource_name=$(echo "$resource" | cut -d':' -f1)
                    resource_ns=$(echo "$resource" | cut -d':' -f2)
                fi
                
                print_info "Processing $resource_type '$resource_name' in namespace '$resource_ns'..."
                
                # AWS cleanup if enabled and AWS CLI is available
                if [ "$FORCE_AWS_CLEANUP" = true ] && [ "$AWS_CLI_AVAILABLE" = true ]; then
                    aws_info=$(get_aws_resource_info "$resource_type" "$resource_name" "$resource_ns")
                    if cleanup_aws_resource "$resource_type" "$aws_info"; then
                        print_success "AWS resource cleanup completed for '$resource_name'"
                        ((AWS_CLEANUP_COUNT++))
                        # Wait a bit for AWS resource to be deleted
                        sleep 5
                    else
                        print_warning "AWS resource cleanup failed or skipped for '$resource_name'"
                    fi
                fi
                
                # Delete the managed resource
                print_info "Deleting managed resource '$resource_name'..."
                if kubectl delete "$resource_type" "$resource_name" -n "$resource_ns" --timeout=120s 2>/dev/null; then
                    print_success "Successfully deleted $resource_type '$resource_name'"
                    ((SUCCESS_COUNT++))
                else
                    print_warning "Failed to delete $resource_type '$resource_name' - may need finalizer removal"
                    
                    # Try to remove finalizers
                    print_info "Attempting to remove finalizers from '$resource_name'..."
                    if kubectl patch "$resource_type" "$resource_name" -n "$resource_ns" --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null; then
                        print_success "Finalizers removed from '$resource_name'"
                        # Try deletion again
                        if kubectl delete "$resource_type" "$resource_name" -n "$resource_ns" --timeout=30s 2>/dev/null; then
                            print_success "Successfully deleted $resource_type '$resource_name' after finalizer removal"
                            ((SUCCESS_COUNT++))
                        else
                            print_error "Failed to delete $resource_type '$resource_name' even after finalizer removal"
                            ((ERROR_COUNT++))
                        fi
                    else
                        print_error "Failed to remove finalizers from '$resource_name'"
                        ((ERROR_COUNT++))
                    fi
                fi
                
                echo ""
            fi
        done
    fi
done

echo ""
print_info "Cleanup operation completed!"
print_success "Successfully processed: $SUCCESS_COUNT managed resources"
if [ $AWS_CLEANUP_COUNT -gt 0 ]; then
    print_success "AWS resources cleaned up: $AWS_CLEANUP_COUNT"
fi
if [ $ERROR_COUNT -gt 0 ]; then
    print_error "Failed to process: $ERROR_COUNT managed resources"
fi

# Final check for remaining resources
echo ""
read -p "Do you want to check for remaining managed resources with finalizers? (yes/no): " check_remaining

if [ "$check_remaining" = "yes" ] || [ "$check_remaining" = "y" ]; then
    print_info "Checking for remaining managed resources with finalizers..."
    
    REMAINING_FOUND=false
    for resource_type in $MR_TYPES; do
        if [ -n "$NAMESPACE" ]; then
            remaining=$(kubectl get "$resource_type" -n "$NAMESPACE" -o json 2>/dev/null | \
                jq -r '.items[] | select(.metadata.finalizers and (.metadata.finalizers | length > 0)) | .metadata.name' 2>/dev/null || true)
            if [ -n "$remaining" ]; then
                print_warning "$resource_type in namespace $NAMESPACE with finalizers:"
                echo "$remaining" | while read -r resource; do
                    echo "  - $resource"
                done
                REMAINING_FOUND=true
            fi
        else
            remaining=$(kubectl get "$resource_type" --all-namespaces -o json 2>/dev/null | \
                jq -r '.items[] | select(.metadata.finalizers and (.metadata.finalizers | length > 0)) | "\(.metadata.namespace):\(.metadata.name)"' 2>/dev/null || true)
            if [ -n "$remaining" ]; then
                print_warning "$resource_type with finalizers:"
                echo "$remaining" | while read -r resource; do
                    echo "  - $resource"
                done
                REMAINING_FOUND=true
            fi
        fi
    done
    
    if [ "$REMAINING_FOUND" = false ]; then
        print_success "No remaining managed resources with finalizers found"
    else
        echo ""
        print_info "To remove finalizers from stuck resources, you can use:"
        echo "  ../k8s/remove_finalizers.sh <resource-type> <resource-name> [namespace]"
    fi
fi