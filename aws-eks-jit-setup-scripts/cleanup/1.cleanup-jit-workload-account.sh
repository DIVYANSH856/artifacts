#!/usr/bin/env bash
# Cleans up infrastructure resources created by the JIT EKS setup scripts in the
# JIT Workload Account:
#   - Bastion EC2 instance
#   - Instance profile + IAM bastion role
#   - Security group
#   - NAT Gateway + Elastic IP
#   - Subnets, route tables
#   - Internet Gateway
#   - VPC
#   - VPC Peering connections (requester side)
#
# NOTE: Does NOT remove IAM policies (CdxCreateJitEKSPermission etc.) from the
# cross-account role — those are left intact.
#
# Run this in the JIT WORKLOAD ACCOUNT.
###############################################################################
set -euo pipefail

###############################################################################
# Fixed values (must match what the setup scripts used)
###############################################################################
VPC_NAME="cdx-jit-k8s-hub-vpc"
ROLE_NAME="cdx-jit-k8s-hub-bastion-role"
INSTANCE_PROFILE_NAME="cdx-jit-k8s-hub-bastion-profile"
INSTANCE_NAME="cdx-jit-k8s-hub-bastion"
SG_NAME="cdx-jit-k8s-hub-bastion-sg"
NAT_GW_NAME="cdx-jit-k8s-hub-natgw"
IGW_NAME="cdx-jit-k8s-hub-igw"

###############################################################################
# Prompt
###############################################################################
echo "=== AWS EKS JIT — Cleanup JIT Workload Account ==="
echo ""
echo "⚠️  This will DELETE all bastion hub resources and policies."
echo ""

read -rp "AWS Region [us-east-1]: " INPUT_REGION
REGION="${INPUT_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

read -rp "AWS CLI Profile (leave empty for default) []: " INPUT_PROFILE
PROFILE_FLAG=""
if [[ -n "$INPUT_PROFILE" ]]; then
    PROFILE_FLAG="--profile $INPUT_PROFILE"
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text $PROFILE_FLAG)
echo ""
echo "Account: $ACCOUNT_ID"
echo "Region:  $REGION"
echo ""
read -rp "Proceed with cleanup? (yes/no) [no]: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

###############################################################################
# 1. Find VPC
###############################################################################
echo ""
echo "=== Finding VPC: $VPC_NAME ==="
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query "Vpcs[0].VpcId" --output text $PROFILE_FLAG 2>/dev/null)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    echo "  VPC not found. Skipping infrastructure cleanup."
else
    echo "  VPC: $VPC_ID"

    ###########################################################################
    # 3. Terminate EC2 instance
    ###########################################################################
    echo ""
    echo "=== Terminating bastion instance ==="
    INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
                  "Name=vpc-id,Values=$VPC_ID" \
                  "Name=instance-state-name,Values=running,pending,stopped" \
        --query "Reservations[0].Instances[0].InstanceId" \
        --output text $PROFILE_FLAG 2>/dev/null)

    if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" $PROFILE_FLAG > /dev/null
        echo "  Terminating: $INSTANCE_ID"
        echo "  Waiting for termination..."
        aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" $PROFILE_FLAG
        echo "  Terminated."
    else
        echo "  No instance found."
    fi

    ###########################################################################
    # 4. Delete VPC Peering connections (requester side)
    ###########################################################################
    echo ""
    echo "=== Deleting VPC peering connections ==="
    PEERINGS=$(aws ec2 describe-vpc-peering-connections \
        --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" \
                  "Name=status-code,Values=active,pending-acceptance,provisioning" \
        --query "VpcPeeringConnections[].VpcPeeringConnectionId" \
        --output text $PROFILE_FLAG 2>/dev/null)

    if [[ -n "$PEERINGS" && "$PEERINGS" != "None" ]]; then
        for pcx in $PEERINGS; do
            aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$pcx" $PROFILE_FLAG 2>/dev/null || true
            echo "  Deleted peering: $pcx"
        done
    else
        echo "  No peering connections found."
    fi

    ###########################################################################
    # 5. Delete NAT Gateway and release EIP
    ###########################################################################
    echo ""
    echo "=== Deleting NAT Gateway ==="
    NAT_GW_ID=$(aws ec2 describe-nat-gateways \
        --filter "Name=tag:Name,Values=$NAT_GW_NAME" "Name=state,Values=available,pending" \
        --query "NatGateways[0].NatGatewayId" --output text $PROFILE_FLAG 2>/dev/null)

    if [[ -n "$NAT_GW_ID" && "$NAT_GW_ID" != "None" ]]; then
        # Get EIP allocation before deleting NAT
        EIP_ALLOC=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_GW_ID" \
            --query "NatGateways[0].NatGatewayAddresses[0].AllocationId" \
            --output text $PROFILE_FLAG 2>/dev/null)

        aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_ID" $PROFILE_FLAG > /dev/null
        echo "  Deleting NAT Gateway: $NAT_GW_ID"
        echo "  Waiting for NAT Gateway deletion (this takes ~2 min)..."
        # Wait for NAT GW to be deleted
        for i in $(seq 1 30); do
            STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_GW_ID" \
                --query "NatGateways[0].State" --output text $PROFILE_FLAG 2>/dev/null)
            if [[ "$STATE" == "deleted" ]]; then break; fi
            sleep 10
        done
        echo "  NAT Gateway deleted."

        # Release EIP
        if [[ -n "$EIP_ALLOC" && "$EIP_ALLOC" != "None" ]]; then
            aws ec2 release-address --allocation-id "$EIP_ALLOC" $PROFILE_FLAG 2>/dev/null || true
            echo "  Released EIP: $EIP_ALLOC"
        fi
    else
        echo "  No NAT Gateway found."
    fi

    ###########################################################################
    # 6. Delete Security Group
    ###########################################################################
    echo ""
    echo "=== Deleting Security Group ==="
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
        --query "SecurityGroups[0].GroupId" --output text $PROFILE_FLAG 2>/dev/null)

    if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
        aws ec2 delete-security-group --group-id "$SG_ID" $PROFILE_FLAG 2>/dev/null || true
        echo "  Deleted SG: $SG_ID"
    else
        echo "  No security group found."
    fi

    ###########################################################################
    # 7. Delete Subnets
    ###########################################################################
    echo ""
    echo "=== Deleting Subnets ==="
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "Subnets[].SubnetId" --output text $PROFILE_FLAG 2>/dev/null)

    for sub in $SUBNET_IDS; do
        aws ec2 delete-subnet --subnet-id "$sub" $PROFILE_FLAG 2>/dev/null || true
        echo "  Deleted subnet: $sub"
    done

    ###########################################################################
    # 8. Delete Route Tables (non-main only)
    ###########################################################################
    echo ""
    echo "=== Deleting Route Tables ==="
    RT_IDS=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" \
        --output text $PROFILE_FLAG 2>/dev/null)

    for rt in $RT_IDS; do
        # Disassociate first
        ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
            --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" \
            --output text $PROFILE_FLAG 2>/dev/null)
        for assoc in $ASSOC_IDS; do
            aws ec2 disassociate-route-table --association-id "$assoc" $PROFILE_FLAG 2>/dev/null || true
        done
        aws ec2 delete-route-table --route-table-id "$rt" $PROFILE_FLAG 2>/dev/null || true
        echo "  Deleted route table: $rt"
    done

    ###########################################################################
    # 9. Detach and delete Internet Gateway
    ###########################################################################
    echo ""
    echo "=== Deleting Internet Gateway ==="
    IGW_ID=$(aws ec2 describe-internet-gateways \
        --filters "Name=tag:Name,Values=$IGW_NAME" \
        --query "InternetGateways[0].InternetGatewayId" \
        --output text $PROFILE_FLAG 2>/dev/null)

    if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]]; then
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" $PROFILE_FLAG 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" $PROFILE_FLAG 2>/dev/null || true
        echo "  Deleted IGW: $IGW_ID"
    else
        echo "  No IGW found."
    fi

    ###########################################################################
    # 10. Delete VPC
    ###########################################################################
    echo ""
    echo "=== Deleting VPC ==="
    aws ec2 delete-vpc --vpc-id "$VPC_ID" $PROFILE_FLAG 2>/dev/null || true
    echo "  Deleted VPC: $VPC_ID"
fi

###############################################################################
# 11. Delete Instance Profile and IAM Role
###############################################################################
echo ""
echo "=== Cleaning up IAM Role and Instance Profile ==="

# Remove role from instance profile
aws iam remove-role-from-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$ROLE_NAME" $PROFILE_FLAG 2>/dev/null || true

# Delete instance profile
aws iam delete-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" $PROFILE_FLAG 2>/dev/null || true
echo "  Deleted instance profile: $INSTANCE_PROFILE_NAME"

# Detach policies from role
aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" $PROFILE_FLAG 2>/dev/null || true

# Delete role
aws iam delete-role --role-name "$ROLE_NAME" $PROFILE_FLAG 2>/dev/null || true
echo "  Deleted role: $ROLE_NAME"

###############################################################################
# Summary
###############################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ JIT Workload Account Cleanup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Removed:"
echo "    • Bastion EC2 instance"
echo "    • Instance Profile: $INSTANCE_PROFILE_NAME"
echo "    • IAM Role: $ROLE_NAME"
echo "    • VPC peering connections"
echo "    • NAT Gateway + EIP"
echo "    • Security Group, Subnets, Route Tables"
echo "    • Internet Gateway"
echo "    • VPC: $VPC_NAME"
echo ""
echo "  NOTE: IAM policies (CdxCreateJitEKSPermission, CdxManageEKSAccessEntry)"
echo "        on the cross-account role are NOT removed."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
