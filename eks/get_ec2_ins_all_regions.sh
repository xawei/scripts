#!/bin/bash
# One-liner to get EC2 instances from all regions
for region in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do echo "=== $region ==="; aws ec2 describe-instances --region $region --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' --output table; done
