#!/bin/bash

# AWS Resources Cleanup Script
# This script deletes EC2 instances and EKS clusters with matching name patterns across all AWS regions
# Usage: ./delete-aws-resources.sh [OPTIONS]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
NAME_PATTERN=""
DRY_RUN=false
FORCE=false
VERBOSE=false
CONFIRM=true
DELETE_EC2=true
DELETE_EKS=true

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

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Delete EC2 instances and EKS clusters with matching name patterns across all AWS regions

Options:
    -p, --pattern PATTERN       Name pattern to match (required)
    -d, --dry-run              Show what would be deleted without actually deleting
    -f, --force                Skip confirmation prompts
    -v, --verbose              Enable verbose output
    -y, --yes                  Auto-confirm all prompts
    --ec2-only                 Delete only EC2 instances
    --eks-only                 Delete only EKS clusters
    -h, --help                 Show this help message

Examples:
    $0 -p "test-"                    # Delete all EC2 and EKS resources with names starting with 'test-'
    $0 -p "my-app" --dry-run         # Dry run for resources matching 'my-app'
    $0 -p "staging" --ec2-only -f    # Force delete only EC2 instances matching 'staging'
    $0 -p "dev-" --eks-only          # Delete only EKS clusters matching 'dev-'

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--pattern)
            NAME_PATTERN="$2"
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
        -y|--yes)
            CONFIRM=false
            shift
            ;;
        --ec2-only)
            DELETE_EKS=false
            shift
            ;;
        --eks-only)
            DELETE_EC2=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$NAME_PATTERN" ]]; then
    print_error "Name pattern is required. Use -p or --pattern to specify."
    usage
    exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured or invalid."
    exit 1
fi

# Function to get all AWS regions
get_all_regions() {
    aws ec2 describe-regions --query 'Regions[].RegionName' --output text
}

# Function to find EC2 instances matching pattern
find_ec2_instances() {
    local region=$1
    local pattern=$2
    
    if [[ "$VERBOSE" == "true" ]]; then
        print_info "Searching for EC2 instances in region: $region"
    fi
    
    aws ec2 describe-instances \
        --region "$region" \
        --query "Reservations[].Instances[?State.Name!='terminated' && contains(Tags[?Key=='Name'].Value | [0], '$pattern')].{InstanceId:InstanceId,Name:Tags[?Key=='Name'].Value|[0],State:State.Name}" \
        --output table 2>/dev/null || true
}

# Function to find EKS clusters matching pattern
find_eks_clusters() {
    local region=$1
    local pattern=$2
    
    if [[ "$VERBOSE" == "true" ]]; then
        print_info "Searching for EKS clusters in region: $region"
    fi
    
    local clusters
    clusters=$(aws eks list-clusters --region "$region" --query 'clusters' --output text 2>/dev/null || true)
    
    if [[ -n "$clusters" ]]; then
        for cluster in $clusters; do
            if [[ "$cluster" == *"$pattern"* ]]; then
                echo "$cluster"
            fi
        done
    fi
}

# Function to delete EC2 instances
delete_ec2_instances() {
    local region=$1
    local pattern=$2
    
    print_info "Processing EC2 instances in region: $region"
    
    local instances
    instances=$(aws ec2 describe-instances \
        --region "$region" \
        --query "Reservations[].Instances[?State.Name!='terminated' && contains(Tags[?Key=='Name'].Value | [0], '$pattern')].InstanceId" \
        --output text 2>/dev/null || true)
    
    if [[ -n "$instances" && "$instances" != "None" ]]; then
        for instance in $instances; do
            if [[ "$DRY_RUN" == "true" ]]; then
                print_warning "[DRY RUN] Would terminate EC2 instance: $instance in $region"
            else
                print_info "Terminating EC2 instance: $instance in $region"
                aws ec2 terminate-instances --region "$region" --instance-ids "$instance" > /dev/null
                print_success "Terminated EC2 instance: $instance"
            fi
        done
    else
        if [[ "$VERBOSE" == "true" ]]; then
            print_info "No EC2 instances found matching pattern '$pattern' in $region"
        fi
    fi
}

# Function to delete EKS clusters
delete_eks_clusters() {
    local region=$1
    local pattern=$2
    
    print_info "Processing EKS clusters in region: $region"
    
    local clusters
    clusters=$(find_eks_clusters "$region" "$pattern")
    
    if [[ -n "$clusters" ]]; then
        for cluster in $clusters; do
            if [[ "$DRY_RUN" == "true" ]]; then
                print_warning "[DRY RUN] Would delete EKS cluster: $cluster in $region"
            else
                print_info "Deleting EKS cluster: $cluster in $region"
                
                # First, delete all node groups
                local nodegroups
                nodegroups=$(aws eks list-nodegroups --region "$region" --cluster-name "$cluster" --query 'nodegroups' --output text 2>/dev/null || true)
                
                if [[ -n "$nodegroups" && "$nodegroups" != "None" ]]; then
                    for nodegroup in $nodegroups; do
                        print_info "Deleting node group: $nodegroup from cluster $cluster"
                        aws eks delete-nodegroup --region "$region" --cluster-name "$cluster" --nodegroup-name "$nodegroup" > /dev/null
                        
                        # Wait for node group deletion
                        print_info "Waiting for node group $nodegroup to be deleted..."
                        aws eks wait nodegroup-deleted --region "$region" --cluster-name "$cluster" --nodegroup-name "$nodegroup"
                        print_success "Node group $nodegroup deleted"
                    done
                fi
                
                # Delete the cluster
                aws eks delete-cluster --region "$region" --name "$cluster" > /dev/null
                print_info "Waiting for EKS cluster $cluster to be deleted..."
                aws eks wait cluster-deleted --region "$region" --name "$cluster"
                print_success "Deleted EKS cluster: $cluster"
            fi
        done
    else
        if [[ "$VERBOSE" == "true" ]]; then
            print_info "No EKS clusters found matching pattern '$pattern' in $region"
        fi
    fi
}

# Function to confirm deletion
confirm_deletion() {
    if [[ "$CONFIRM" == "true" && "$FORCE" == "false" && "$DRY_RUN" == "false" ]]; then
        echo
        print_warning "This will delete AWS resources matching pattern '$NAME_PATTERN' across ALL regions!"
        if [[ "$DELETE_EC2" == "true" ]]; then
            print_warning "- EC2 instances will be TERMINATED"
        fi
        if [[ "$DELETE_EKS" == "true" ]]; then
            print_warning "- EKS clusters will be DELETED (including all node groups)"
        fi
        echo
        read -p "Are you sure you want to continue? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            print_info "Operation cancelled."
            exit 0
        fi
    fi
}

# Main execution
main() {
    print_info "AWS Resources Cleanup Script"
    print_info "Pattern: $NAME_PATTERN"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warning "DRY RUN MODE - No resources will be deleted"
    fi
    
    # Get all AWS regions
    print_info "Getting list of AWS regions..."
    local regions
    regions=$(get_all_regions)
    
    if [[ -z "$regions" ]]; then
        print_error "Failed to get AWS regions"
        exit 1
    fi
    
    print_info "Found $(echo $regions | wc -w) regions"
    
    # Show what will be affected
    if [[ "$DRY_RUN" == "true" || "$VERBOSE" == "true" ]]; then
        print_info "Scanning for resources matching pattern '$NAME_PATTERN'..."
        
        for region in $regions; do
            if [[ "$DELETE_EC2" == "true" ]]; then
                find_ec2_instances "$region" "$NAME_PATTERN"
            fi
            
            if [[ "$DELETE_EKS" == "true" ]]; then
                local eks_clusters
                eks_clusters=$(find_eks_clusters "$region" "$NAME_PATTERN")
                if [[ -n "$eks_clusters" ]]; then
                    print_info "EKS clusters in $region matching '$NAME_PATTERN':"
                    echo "$eks_clusters"
                fi
            fi
        done
    fi
    
    # Confirm deletion
    confirm_deletion
    
    # Process each region
    for region in $regions; do
        if [[ "$DELETE_EC2" == "true" ]]; then
            delete_ec2_instances "$region" "$NAME_PATTERN"
        fi
        
        if [[ "$DELETE_EKS" == "true" ]]; then
            delete_eks_clusters "$region" "$NAME_PATTERN"
        fi
    done
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_success "Dry run completed. No resources were deleted."
    else
        print_success "Resource cleanup completed!"
    fi
}

# Run main function
main "$@"