#!/usr/bin/env bash
# Sets up the EKS bastion hub infrastructure (IDEMPOTENT — safe to re-run):
#   1. Creates a VPC with 2 public + 2 private subnets across 2 AZs
#   2. Creates an Internet Gateway and NAT Gateway for connectivity
#   3. Creates route tables for public/private subnets
#   4. Creates an IAM role with SSM policy for the bastion EC2
#   5. Launches an EC2 instance in a private subnet with SSM enabled
#   6. Tags all resources with owner=cloudanix purpose=cdx-jit-k8s
#      service=bastion scope=hub
#
# Every resource is checked before creation — if it already exists, it is
# reused. This makes the script safe to re-run after a partial failure.
#
# Run this in the JIT WORKLOAD ACCOUNT (where the bastion lives).
###############################################################################
set -euo pipefail

###############################################################################
# Fixed values
###############################################################################
VPC_NAME="cdx-jit-k8s-hub-vpc"
IGW_NAME="cdx-jit-k8s-hub-igw"
NAT_GW_NAME="cdx-jit-k8s-hub-natgw"
PUBLIC_RT_NAME="cdx-jit-k8s-hub-public-rt"
PRIVATE_RT_NAME="cdx-jit-k8s-hub-private-rt"
SG_NAME="cdx-jit-k8s-hub-bastion-sg"
ROLE_NAME="cdx-jit-k8s-hub-bastion-role"
INSTANCE_PROFILE_NAME="cdx-jit-k8s-hub-bastion-profile"
INSTANCE_NAME="cdx-jit-k8s-hub-bastion"
INSTANCE_TYPE="t3.micro"

# Tag string for --tag-specifications (without outer braces — they come from the template)
TAGS="Key=owner,Value=cloudanix},{Key=purpose,Value=cdx-jit-k8s},{Key=service,Value=bastion},{Key=scope,Value=hub"

###############################################################################
# Prompt for inputs
###############################################################################
read -rp "AWS Region [us-east-1]: " INPUT_REGION
REGION="${INPUT_REGION:-us-east-1}"

read -rp "VPC CIDR block [10.200.0.0/16]: " INPUT_VPC_CIDR
VPC_CIDR="${INPUT_VPC_CIDR:-10.200.0.0/16}"

# Auto-calculate subnet CIDRs from VPC CIDR base
VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)
DEFAULT_PUB1="${VPC_BASE}.1.0/24"
DEFAULT_PUB2="${VPC_BASE}.2.0/24"
DEFAULT_PRIV1="${VPC_BASE}.3.0/24"
DEFAULT_PRIV2="${VPC_BASE}.4.0/24"

read -rp "Public Subnet 1 CIDR [$DEFAULT_PUB1]: " INPUT_PUB1
PUBLIC_SUBNET_1_CIDR="${INPUT_PUB1:-$DEFAULT_PUB1}"

read -rp "Public Subnet 2 CIDR [$DEFAULT_PUB2]: " INPUT_PUB2
PUBLIC_SUBNET_2_CIDR="${INPUT_PUB2:-$DEFAULT_PUB2}"

read -rp "Private Subnet 1 CIDR [$DEFAULT_PRIV1]: " INPUT_PRIV1
PRIVATE_SUBNET_1_CIDR="${INPUT_PRIV1:-$DEFAULT_PRIV1}"

read -rp "Private Subnet 2 CIDR [$DEFAULT_PRIV2]: " INPUT_PRIV2
PRIVATE_SUBNET_2_CIDR="${INPUT_PRIV2:-$DEFAULT_PRIV2}"

read -rp "AWS CLI Profile (leave empty for default) []: " INPUT_PROFILE
PROFILE="${INPUT_PROFILE}"

# Build profile flag
PROFILE_FLAG=""
if [[ -n "$PROFILE" ]]; then
    PROFILE_FLAG="--profile $PROFILE"
fi

# Resolve AZs dynamically
AZ_1=$(aws ec2 describe-availability-zones \
    --region "$REGION" \
    --query "AvailabilityZones[0].ZoneName" \
    --output text $PROFILE_FLAG)
AZ_2=$(aws ec2 describe-availability-zones \
    --region "$REGION" \
    --query "AvailabilityZones[1].ZoneName" \
    --output text $PROFILE_FLAG)

echo ""
echo "=== Configuration ==="
echo "Region              : $REGION"
echo "VPC CIDR            : $VPC_CIDR"
echo "Public Subnets      : $PUBLIC_SUBNET_1_CIDR ($AZ_1), $PUBLIC_SUBNET_2_CIDR ($AZ_2)"
echo "Private Subnets     : $PRIVATE_SUBNET_1_CIDR ($AZ_1), $PRIVATE_SUBNET_2_CIDR ($AZ_2)"
echo ""

###############################################################################
# Helper: find or create subnet
###############################################################################
find_or_create_subnet() {
    local vpc_id=$1 cidr=$2 az=$3 name=$4
    local sub_id
    sub_id=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=$name" \
        --region "$REGION" \
        --query 'Subnets[0].SubnetId' --output text $PROFILE_FLAG 2>/dev/null)
    if [[ -z "$sub_id" || "$sub_id" == "None" ]]; then
        sub_id=$(aws ec2 create-subnet \
            --vpc-id "$vpc_id" --cidr-block "$cidr" --availability-zone "$az" \
            --region "$REGION" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$name},{$TAGS}]" \
            --query 'Subnet.SubnetId' --output text $PROFILE_FLAG)
        echo "[✓] Subnet created: $name ($sub_id)" >&2
    else
        echo "[✓] Subnet exists: $name ($sub_id)" >&2
    fi
    echo "$sub_id"
}

###############################################################################
# VPC (find or create)
###############################################################################
echo ""
echo "=== VPC: $VPC_NAME ==="
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=$VPC_NAME" "Name=cidr,Values=$VPC_CIDR" \
    --region "$REGION" \
    --query "Vpcs[0].VpcId" \
    --output text $PROFILE_FLAG 2>/dev/null)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block "$VPC_CIDR" \
        --region "$REGION" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{$TAGS}]" \
        --query "Vpc.VpcId" \
        --output text $PROFILE_FLAG)
    echo "[✓] VPC created: $VPC_ID"
else
    echo "[✓] VPC exists: $VPC_ID"
fi

# Enable DNS (idempotent)
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' --region "$REGION" $PROFILE_FLAG
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}' --region "$REGION" $PROFILE_FLAG

###############################################################################
# Internet Gateway (find or create)
###############################################################################
echo ""
echo "=== Internet Gateway: $IGW_NAME ==="
IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters "Name=tag:Name,Values=$IGW_NAME" \
    --region "$REGION" \
    --query "InternetGateways[0].InternetGatewayId" \
    --output text $PROFILE_FLAG 2>/dev/null)

if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway \
        --region "$REGION" \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME},{$TAGS}]" \
        --query "InternetGateway.InternetGatewayId" \
        --output text $PROFILE_FLAG)
    echo "[✓] IGW created: $IGW_ID"
else
    echo "[✓] IGW exists: $IGW_ID"
fi

# Attach to VPC (idempotent)
aws ec2 attach-internet-gateway \
    --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" \
    --region "$REGION" $PROFILE_FLAG 2>/dev/null || true

###############################################################################
# Subnets (2 public + 2 private across 2 AZs)
###############################################################################
echo ""
echo "=== Subnets (multi-AZ) ==="
PUB_SUB_1=$(find_or_create_subnet "$VPC_ID" "$PUBLIC_SUBNET_1_CIDR" "$AZ_1" "cdx-jit-k8s-hub-public-1")
PUB_SUB_2=$(find_or_create_subnet "$VPC_ID" "$PUBLIC_SUBNET_2_CIDR" "$AZ_2" "cdx-jit-k8s-hub-public-2")
PRIV_SUB_1=$(find_or_create_subnet "$VPC_ID" "$PRIVATE_SUBNET_1_CIDR" "$AZ_1" "cdx-jit-k8s-hub-private-1")
PRIV_SUB_2=$(find_or_create_subnet "$VPC_ID" "$PRIVATE_SUBNET_2_CIDR" "$AZ_2" "cdx-jit-k8s-hub-private-2")

###############################################################################
# NAT Gateway (find or create — in first public subnet)
###############################################################################
echo ""
echo "=== NAT Gateway: $NAT_GW_NAME ==="
NAT_GW_ID=$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:Name,Values=$NAT_GW_NAME" "Name=state,Values=available,pending" \
    --region "$REGION" \
    --query "NatGateways[0].NatGatewayId" \
    --output text $PROFILE_FLAG 2>/dev/null)

if [[ -z "$NAT_GW_ID" || "$NAT_GW_ID" == "None" ]]; then
    EIP_ALLOC_ID=$(aws ec2 allocate-address \
        --domain vpc --region "$REGION" \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=cdx-jit-k8s-hub-natgw-eip},{$TAGS}]" \
        --query "AllocationId" --output text $PROFILE_FLAG)

    NAT_GW_ID=$(aws ec2 create-nat-gateway \
        --subnet-id "$PUB_SUB_1" --allocation-id "$EIP_ALLOC_ID" \
        --region "$REGION" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$NAT_GW_NAME},{$TAGS}]" \
        --query "NatGateway.NatGatewayId" --output text $PROFILE_FLAG)

    echo "Waiting for NAT Gateway to become available..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID" --region "$REGION" $PROFILE_FLAG
    echo "[✓] NAT Gateway created: $NAT_GW_ID"
else
    echo "[✓] NAT Gateway exists: $NAT_GW_ID"
fi

###############################################################################
# Public Route Table (find or create)
###############################################################################
echo ""
echo "=== Public Route Table: $PUBLIC_RT_NAME ==="
PUBLIC_RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$PUBLIC_RT_NAME" \
    --region "$REGION" \
    --query "RouteTables[0].RouteTableId" \
    --output text $PROFILE_FLAG 2>/dev/null)

if [[ -z "$PUBLIC_RT_ID" || "$PUBLIC_RT_ID" == "None" ]]; then
    PUBLIC_RT_ID=$(aws ec2 create-route-table \
        --vpc-id "$VPC_ID" --region "$REGION" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PUBLIC_RT_NAME},{$TAGS}]" \
        --query "RouteTable.RouteTableId" --output text $PROFILE_FLAG)
    echo "[✓] Public RT created: $PUBLIC_RT_ID"
else
    echo "[✓] Public RT exists: $PUBLIC_RT_ID"
fi

# Default route via IGW (idempotent)
aws ec2 create-route --route-table-id "$PUBLIC_RT_ID" \
    --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" \
    --region "$REGION" $PROFILE_FLAG > /dev/null 2>&1 || true

# Associate both public subnets (idempotent)
for PUB_SUB in "$PUB_SUB_1" "$PUB_SUB_2"; do
    ASSOC=$(aws ec2 describe-route-tables --route-table-ids "$PUBLIC_RT_ID" \
        --region "$REGION" \
        --query "RouteTables[0].Associations[?SubnetId=='$PUB_SUB'].RouteTableAssociationId | [0]" \
        --output text $PROFILE_FLAG 2>/dev/null)
    if [[ -z "$ASSOC" || "$ASSOC" == "None" ]]; then
        aws ec2 associate-route-table --route-table-id "$PUBLIC_RT_ID" \
            --subnet-id "$PUB_SUB" --region "$REGION" $PROFILE_FLAG > /dev/null
    fi
done

###############################################################################
# Private Route Table (find or create)
###############################################################################
echo ""
echo "=== Private Route Table: $PRIVATE_RT_NAME ==="
PRIVATE_RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$PRIVATE_RT_NAME" \
    --region "$REGION" \
    --query "RouteTables[0].RouteTableId" \
    --output text $PROFILE_FLAG 2>/dev/null)

if [[ -z "$PRIVATE_RT_ID" || "$PRIVATE_RT_ID" == "None" ]]; then
    PRIVATE_RT_ID=$(aws ec2 create-route-table \
        --vpc-id "$VPC_ID" --region "$REGION" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PRIVATE_RT_NAME},{$TAGS}]" \
        --query "RouteTable.RouteTableId" --output text $PROFILE_FLAG)
    echo "[✓] Private RT created: $PRIVATE_RT_ID"
else
    echo "[✓] Private RT exists: $PRIVATE_RT_ID"
fi

# Default route via NAT GW (idempotent)
aws ec2 create-route --route-table-id "$PRIVATE_RT_ID" \
    --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_ID" \
    --region "$REGION" $PROFILE_FLAG > /dev/null 2>&1 || true

# Associate both private subnets (idempotent)
for PRIV_SUB in "$PRIV_SUB_1" "$PRIV_SUB_2"; do
    ASSOC=$(aws ec2 describe-route-tables --route-table-ids "$PRIVATE_RT_ID" \
        --region "$REGION" \
        --query "RouteTables[0].Associations[?SubnetId=='$PRIV_SUB'].RouteTableAssociationId | [0]" \
        --output text $PROFILE_FLAG 2>/dev/null)
    if [[ -z "$ASSOC" || "$ASSOC" == "None" ]]; then
        aws ec2 associate-route-table --route-table-id "$PRIVATE_RT_ID" \
            --subnet-id "$PRIV_SUB" --region "$REGION" $PROFILE_FLAG > /dev/null
    fi
done

###############################################################################
# Security Group (find or create)
###############################################################################
echo ""
echo "=== Security Group: $SG_NAME ==="
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
    --region "$REGION" \
    --query "SecurityGroups[0].GroupId" \
    --output text $PROFILE_FLAG 2>/dev/null)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "Bastion hub SG - SSM managed, no inbound SSH required" \
        --vpc-id "$VPC_ID" --region "$REGION" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{$TAGS}]" \
        --query "GroupId" --output text $PROFILE_FLAG)
    echo "[✓] Security Group created: $SG_ID"
else
    echo "[✓] Security Group exists: $SG_ID"
fi

# Ensure all outbound allowed (idempotent)
aws ec2 authorize-security-group-egress --group-id "$SG_ID" \
    --protocol "-1" --cidr "0.0.0.0/0" \
    --region "$REGION" $PROFILE_FLAG 2>/dev/null || true

###############################################################################
# IAM Role (find or create)
###############################################################################
echo ""
echo "=== IAM Role: $ROLE_NAME ==="
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.Arn' --output text $PROFILE_FLAG 2>/dev/null) || ROLE_ARN=""

if [[ -z "$ROLE_ARN" ]]; then
    TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --tags "Key=owner,Value=cloudanix" "Key=purpose,Value=cdx-jit-k8s" "Key=service,Value=bastion" "Key=scope,Value=hub" \
        $PROFILE_FLAG > /dev/null
    echo "[✓] IAM Role created: $ROLE_NAME"
else
    echo "[✓] IAM Role exists: $ROLE_NAME"
fi

# Attach SSM policy (idempotent)
aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
    $PROFILE_FLAG 2>/dev/null || true

###############################################################################
# Instance Profile (find or create)
###############################################################################
echo ""
echo "=== Instance Profile: $INSTANCE_PROFILE_NAME ==="
EXISTING_PROFILE=$(aws iam get-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --query 'InstanceProfile.Arn' --output text $PROFILE_FLAG 2>/dev/null) || EXISTING_PROFILE=""

if [[ -z "$EXISTING_PROFILE" ]]; then
    aws iam create-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --tags "Key=owner,Value=cloudanix" "Key=purpose,Value=cdx-jit-k8s" "Key=service,Value=bastion" "Key=scope,Value=hub" \
        $PROFILE_FLAG > /dev/null
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME" $PROFILE_FLAG 2>/dev/null || true
    echo "[✓] Instance Profile created: $INSTANCE_PROFILE_NAME"
    echo "Waiting for instance profile propagation..."
    sleep 10
else
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME" $PROFILE_FLAG 2>/dev/null || true
    echo "[✓] Instance Profile exists: $INSTANCE_PROFILE_NAME"
fi

###############################################################################
# Get latest Amazon Linux 2023 AMI
###############################################################################
echo ""
echo "=== Resolving latest Amazon Linux 2023 AMI ==="
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --region "$REGION" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text $PROFILE_FLAG)
echo "AMI ID: $AMI_ID"

###############################################################################
# EC2 Instance (find or create — in first private subnet)
###############################################################################
echo ""
echo "=== Bastion Instance: $INSTANCE_NAME ==="
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
              "Name=vpc-id,Values=$VPC_ID" \
              "Name=instance-state-name,Values=running,pending,stopped" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text $PROFILE_FLAG 2>/dev/null)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --subnet-id "$PRIV_SUB_1" \
        --security-group-ids "$SG_ID" \
        --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" \
        --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{$TAGS}]" \
        --region "$REGION" \
        --query "Instances[0].InstanceId" \
        --output text $PROFILE_FLAG)
    echo "[✓] Instance launched: $INSTANCE_ID"

    echo "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION" $PROFILE_FLAG
    echo "Instance is running."
else
    echo "[✓] Instance exists: $INSTANCE_ID"
    INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --region "$REGION" --query "Reservations[0].Instances[0].State.Name" \
        --output text $PROFILE_FLAG)
    if [[ "$INSTANCE_STATE" == "stopped" ]]; then
        echo "Instance is stopped — starting..."
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" $PROFILE_FLAG > /dev/null
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION" $PROFILE_FLAG
        echo "Instance is running."
    fi
fi

###############################################################################
# Wait for SSM agent to register
###############################################################################
echo ""
echo "=== Waiting for SSM agent to register ==="
for i in $(seq 1 30); do
    SSM_STATUS=$(aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --region "$REGION" \
        --query "InstanceInformationList[0].PingStatus" \
        --output text $PROFILE_FLAG 2>/dev/null || echo "None")

    if [[ "$SSM_STATUS" == "Online" ]]; then
        echo "SSM agent is online."
        break
    fi

    if [[ $i -eq 30 ]]; then
        echo ""
        echo "WARNING: SSM agent did not come online within 150s."
        echo "  Check NAT Gateway connectivity and instance profile attachment."
    fi

    echo -n "."
    sleep 5
done

###############################################################################
# Output summary
###############################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Bastion Hub Setup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  VPC              : $VPC_ID ($VPC_CIDR)"
echo "  Public Subnets   : $PUB_SUB_1 ($AZ_1), $PUB_SUB_2 ($AZ_2)"
echo "  Private Subnets  : $PRIV_SUB_1 ($AZ_1), $PRIV_SUB_2 ($AZ_2)"
echo "  NAT Gateway      : $NAT_GW_ID"
echo "  Security Group   : $SG_ID"
echo "  IAM Role         : $ROLE_NAME"
echo "  Instance Profile : $INSTANCE_PROFILE_NAME"
echo "  Bastion Instance : $INSTANCE_ID"
echo "  Region           : $REGION"
echo ""
echo "  Tags: owner=cloudanix purpose=cdx-jit-k8s service=bastion scope=hub"
echo ""
echo "  Connect via SSM:"
echo "    aws ssm start-session --target $INSTANCE_ID --region $REGION"
echo ""
echo "  Port forward to EKS:"
echo "    aws ssm start-session --target $INSTANCE_ID \\"
echo "      --document-name AWS-StartPortForwardingSessionToRemoteHost \\"
echo "      --parameters '{\"host\":[\"<EKS_ENDPOINT>\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}' \\"
echo "      --region $REGION"
echo ""
echo "  Next steps:"
echo "    → Run jit-workload-account/3.setup-vpc-peering.sh to peer with EKS VPCs"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
