#!/usr/bin/env bash

set -euo pipefail

SG_NAME="cdx-jit-k8s-hub-bastion-sg"
ROLE_NAME="cdx-jit-k8s-hub-bastion-role"
INSTANCE_PROFILE_NAME="cdx-jit-k8s-hub-bastion-profile"
INSTANCE_NAME="cdx-jit-k8s-hub-bastion"
INSTANCE_TYPE="t3.micro"
TAGS="Key=owner,Value=cloudanix},{Key=purpose,Value=cdx-jit-k8s},{Key=service,Value=bastion},{Key=scope,Value=hub"

###############################################################################
# Prompt for inputs
###############################################################################
echo "=== EKS JIT Bastion Setup (Existing VPC) ==="
echo ""
echo "This script deploys a bastion EC2 into your existing VPC."
echo "You need to provide the VPC ID and subnet IDs."
echo ""

read -rp "AWS Region [us-east-1]: " INPUT_REGION
REGION="${INPUT_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

read -rp "VPC ID (required): " VPC_ID
if [[ -z "$VPC_ID" ]]; then
    echo "ERROR: VPC ID is required."
    exit 1
fi

read -rp "Private Subnet 1 ID for bastion instance (required): " PRIVATE_SUBNET_1_ID
if [[ -z "$PRIVATE_SUBNET_1_ID" ]]; then
    echo "ERROR: Private Subnet 1 ID is required."
    exit 1
fi

read -rp "Private Subnet 2 ID (optional, press enter to skip): " PRIVATE_SUBNET_2_ID

read -rp "AWS CLI Profile (leave empty for default) []: " INPUT_PROFILE
PROFILE="${INPUT_PROFILE}"

# Build profile flag
PROFILE_FLAG=""
if [[ -n "$PROFILE" ]]; then
    PROFILE_FLAG="--profile $PROFILE"
fi

###############################################################################
# Validate VPC and Subnet exist
###############################################################################
echo ""
echo "=== Validating inputs ==="

VPC_CIDR=$(aws ec2 describe-vpcs \
    --vpc-ids "$VPC_ID" \
    --region "$REGION" \
    --query "Vpcs[0].CidrBlock" \
    --output text $PROFILE_FLAG 2>/dev/null)

if [[ -z "$VPC_CIDR" || "$VPC_CIDR" == "None" ]]; then
    echo "ERROR: VPC $VPC_ID not found in region $REGION."
    exit 1
fi
echo "VPC: $VPC_ID ($VPC_CIDR)"

PRIVATE_SUBNET_1_CIDR=$(aws ec2 describe-subnets \
    --subnet-ids "$PRIVATE_SUBNET_1_ID" \
    --region "$REGION" \
    --query "Subnets[0].CidrBlock" \
    --output text $PROFILE_FLAG 2>/dev/null)

if [[ -z "$PRIVATE_SUBNET_1_CIDR" || "$PRIVATE_SUBNET_1_CIDR" == "None" ]]; then
    echo "ERROR: Subnet $PRIVATE_SUBNET_1_ID not found in region $REGION."
    exit 1
fi
echo "Private Subnet 1: $PRIVATE_SUBNET_1_ID ($PRIVATE_SUBNET_1_CIDR)"

# Check subnet belongs to VPC
SUBNET_VPC=$(aws ec2 describe-subnets \
    --subnet-ids "$PRIVATE_SUBNET_1_ID" \
    --region "$REGION" \
    --query "Subnets[0].VpcId" \
    --output text $PROFILE_FLAG)

if [[ "$SUBNET_VPC" != "$VPC_ID" ]]; then
    echo "ERROR: Subnet $PRIVATE_SUBNET_1_ID does not belong to VPC $VPC_ID (belongs to $SUBNET_VPC)."
    exit 1
fi

# Validate second private subnet if provided
if [[ -n "$PRIVATE_SUBNET_2_ID" ]]; then
    PRIVATE_SUBNET_2_CIDR=$(aws ec2 describe-subnets \
        --subnet-ids "$PRIVATE_SUBNET_2_ID" \
        --region "$REGION" \
        --query "Subnets[0].CidrBlock" \
        --output text $PROFILE_FLAG 2>/dev/null)
    if [[ -z "$PRIVATE_SUBNET_2_CIDR" || "$PRIVATE_SUBNET_2_CIDR" == "None" ]]; then
        echo "ERROR: Subnet $PRIVATE_SUBNET_2_ID not found in region $REGION."
        exit 1
    fi
    SUBNET_VPC_2=$(aws ec2 describe-subnets --subnet-ids "$PRIVATE_SUBNET_2_ID" \
        --region "$REGION" --query "Subnets[0].VpcId" --output text $PROFILE_FLAG)
    if [[ "$SUBNET_VPC_2" != "$VPC_ID" ]]; then
        echo "ERROR: Subnet $PRIVATE_SUBNET_2_ID does not belong to VPC $VPC_ID."
        exit 1
    fi
    echo "Private Subnet 2: $PRIVATE_SUBNET_2_ID ($PRIVATE_SUBNET_2_CIDR)"
fi

echo ""
echo "=== Configuration ==="
echo "Region           : $REGION"
echo "VPC              : $VPC_ID ($VPC_CIDR)"
echo "Private Subnet 1 : $PRIVATE_SUBNET_1_ID ($PRIVATE_SUBNET_1_CIDR)"
if [[ -n "$PRIVATE_SUBNET_2_ID" ]]; then
    echo "Private Subnet 2 : $PRIVATE_SUBNET_2_ID ($PRIVATE_SUBNET_2_CIDR)"
fi
echo ""

###############################################################################
# Create Security Group (idempotent)
###############################################################################
echo "=== Creating Security Group: $SG_NAME ==="

SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text --region "$REGION" $PROFILE_FLAG 2>/dev/null)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "Bastion hub SG - SSM managed, no inbound SSH required" \
        --vpc-id "$VPC_ID" \
        --region "$REGION" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{$TAGS}]" \
        --query "GroupId" \
        --output text $PROFILE_FLAG)

    # Allow all outbound (required for SSM agent connectivity)
    aws ec2 authorize-security-group-egress \
        --group-id "$SG_ID" \
        --protocol "-1" \
        --cidr "0.0.0.0/0" \
        --region "$REGION" $PROFILE_FLAG 2>/dev/null || true

    echo "Created Security Group: $SG_ID"
else
    echo "Security Group already exists: $SG_ID"
fi

###############################################################################
# Create IAM Role with SSM Policy (idempotent)
###############################################################################
echo ""
echo "=== Creating IAM Role: $ROLE_NAME ==="

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.Arn' --output text $PROFILE_FLAG 2>/dev/null) || ROLE_ARN=""

if [[ -z "$ROLE_ARN" ]]; then
    TRUST_POLICY=$(cat <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)

    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --tags "Key=owner,Value=cloudanix" "Key=purpose,Value=cdx-jit-k8s" "Key=service,Value=bastion" "Key=scope,Value=hub" \
        $PROFILE_FLAG > /dev/null

    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
        --query 'Role.Arn' --output text $PROFILE_FLAG)
    echo "Created IAM Role: $ROLE_NAME ($ROLE_ARN)"
else
    echo "IAM Role already exists: $ROLE_NAME ($ROLE_ARN)"
fi

# Attach SSM managed policy (idempotent)
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
    $PROFILE_FLAG 2>/dev/null || true
echo "Ensured AmazonSSMManagedInstanceCore policy is attached."

###############################################################################
# Create Instance Profile (idempotent)
###############################################################################
echo ""
echo "=== Creating Instance Profile: $INSTANCE_PROFILE_NAME ==="

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
        --role-name "$ROLE_NAME" \
        $PROFILE_FLAG 2>/dev/null || true
    echo "Created instance profile and added role."

    # Wait for instance profile to propagate
    echo "Waiting for instance profile propagation..."
    sleep 10
else
    # Ensure role is attached even if profile existed from a partial run
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME" \
        $PROFILE_FLAG 2>/dev/null || true
    echo "Instance profile already exists: $INSTANCE_PROFILE_NAME"
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
# Check if bastion instance already exists
###############################################################################
echo ""
echo "=== Checking for existing bastion instance ==="

EXISTING_INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
              "Name=vpc-id,Values=$VPC_ID" \
              "Name=instance-state-name,Values=running,pending,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text --region "$REGION" $PROFILE_FLAG 2>/dev/null)

if [[ -n "$EXISTING_INSTANCE" && "$EXISTING_INSTANCE" != "None" ]]; then
    INSTANCE_ID="$EXISTING_INSTANCE"
    echo "Bastion instance already exists: $INSTANCE_ID"

    # If stopped, start it
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" \
        --query "Reservations[0].Instances[0].State.Name" \
        --output text $PROFILE_FLAG)
    if [[ "$INSTANCE_STATE" == "stopped" ]]; then
        echo "Instance is stopped — starting..."
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" $PROFILE_FLAG > /dev/null
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION" $PROFILE_FLAG
        echo "Instance is running."
    fi
else
    ###########################################################################
    # Launch EC2 in Private Subnet with SSM
    ###########################################################################
    echo "=== Launching Bastion Instance: $INSTANCE_NAME ==="
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --subnet-id "$PRIVATE_SUBNET_1_ID" \
        --security-group-ids "$SG_ID" \
        --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" \
        --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{$TAGS}]" \
        --region "$REGION" \
        --query "Instances[0].InstanceId" \
        --output text $PROFILE_FLAG)
    echo "Instance ID: $INSTANCE_ID"

    echo "Waiting for instance to be running..."
    aws ec2 wait instance-running \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" $PROFILE_FLAG
    echo "Instance is running."
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
        echo "  Possible causes:"
        echo "    - Private subnet has no NAT Gateway or VPC endpoint for SSM"
        echo "    - Instance profile not propagated yet"
        echo "  Ensure the private subnet can reach SSM endpoints (via NAT GW or VPC endpoints)."
    fi

    echo -n "."
    sleep 5
done

###############################################################################
# Output summary
###############################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Bastion Setup Complete (Existing VPC)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  VPC              : $VPC_ID ($VPC_CIDR)"
echo "  Private Subnet 1 : $PRIVATE_SUBNET_1_ID ($PRIVATE_SUBNET_1_CIDR)"
if [[ -n "$PRIVATE_SUBNET_2_ID" ]]; then
    echo "  Private Subnet 2 : $PRIVATE_SUBNET_2_ID ($PRIVATE_SUBNET_2_CIDR)"
fi
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
echo "  IMPORTANT: Ensure the private subnet has outbound internet access"
echo "  (NAT Gateway) or VPC endpoints for SSM (ssm, ssmmessages, ec2messages)."
echo ""
echo "  Next steps:"
echo "    → Run jit-workload-account/3.setup-vpc-peering.sh to peer with EKS VPCs"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
