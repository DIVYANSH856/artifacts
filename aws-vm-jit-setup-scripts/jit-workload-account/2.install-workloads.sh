#!/bin/bash
set -e
set -u

handle_error() {
    local exit_code=$?
    echo "[ERROR] Line $1, exit code $exit_code"
    exit $exit_code
}
trap 'handle_error $LINENO' ERR

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
ok()   { echo "[✓] $*"; }
info() { echo "[i] $*"; }
step() { echo ""; echo "━━━ $* ━━━"; }

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

# ============================================================================
# CONFIGURATION
# ============================================================================

echo "=== JIT VM Workload Infrastructure Setup ==="
echo ""

AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")
PROJECT_NAME=$(prompt_with_default "Project Name" "cdx-jit-vm")
S3_BUCKET_NAME=$(prompt_with_default "S3 Bucket for Recordings" "${PROJECT_NAME}-recordings-$(aws sts get-caller-identity --query Account --output text)")

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

VPC_CIDR=$(prompt_with_default "VPC CIDR" "10.50.0.0/16")

# Auto-calculated subnet CIDRs
VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)
PUBLIC_SUBNET_1_CIDR="${VPC_BASE}.1.0/24"
PUBLIC_SUBNET_2_CIDR="${VPC_BASE}.2.0/24"
PRIVATE_SUBNET_1_CIDR="${VPC_BASE}.3.0/24"
PRIVATE_SUBNET_2_CIDR="${VPC_BASE}.4.0/24"
AZ_1="${AWS_REGION}a"
AZ_2="${AWS_REGION}b"

CLUSTER_NAME="${PROJECT_NAME}-cluster"
ROLE_NAME="${PROJECT_NAME}-ECSRole"
LOG_GROUP="/ecs/${PROJECT_NAME}"
NAMESPACE="${PROJECT_NAME}-local"
ECR_PREFIX="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Validate AWS connectivity
info "Validating AWS access..."
aws sts get-caller-identity > /dev/null || { echo "ERROR: AWS credentials not configured"; exit 1; }

echo ""
echo "Account:       $ACCOUNT_ID"
echo "Region:        $AWS_REGION"
echo "Project:       $PROJECT_NAME"
echo "VPC CIDR:      $VPC_CIDR"
echo "Public Subs:   $PUBLIC_SUBNET_1_CIDR ($AZ_1), $PUBLIC_SUBNET_2_CIDR ($AZ_2)"
echo "Private Subs:  $PRIVATE_SUBNET_1_CIDR ($AZ_1), $PRIVATE_SUBNET_2_CIDR ($AZ_2)"
echo ""

# ============================================================================
# VPC (idempotent — checks for existing)
# ============================================================================

step "VPC"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" "Name=cidr,Values=${VPC_CIDR}" \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc},{Key=Purpose,Value=vm-jit},{Key=created_by,Value=cloudanix}]" \
        --query 'Vpc.VpcId' --output text --region "$AWS_REGION")
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' --region "$AWS_REGION"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}' --region "$AWS_REGION"
    ok "VPC created: $VPC_ID"
else
    ok "VPC exists: $VPC_ID"
fi

# Internet Gateway
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ -z "$IGW_ID" ] || [ "$IGW_ID" = "None" ]; then
    IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw}]" \
        --query 'InternetGateway.InternetGatewayId' --output text --region "$AWS_REGION")
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$AWS_REGION"
    ok "IGW created: $IGW_ID"
else
    ok "IGW exists: $IGW_ID"
fi

# ─── Subnets (2 public + 2 private across 2 AZs) ──────────────────────────

step "Subnets (multi-AZ)"

find_or_create_subnet() {
    local vpc_id=$1 cidr=$2 az=$3 name=$4
    local sub_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" "Name=cidr-block,Values=$cidr" \
        --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION" 2>/dev/null)
    if [ -z "$sub_id" ] || [ "$sub_id" = "None" ]; then
        sub_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block "$cidr" --availability-zone "$az" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}}]" \
            --query 'Subnet.SubnetId' --output text --region "$AWS_REGION")
    fi
    echo "$sub_id"
}

PUB_SUB_1=$(find_or_create_subnet "$VPC_ID" "$PUBLIC_SUBNET_1_CIDR" "$AZ_1" "${PROJECT_NAME}-public-1")
aws ec2 modify-subnet-attribute --subnet-id "$PUB_SUB_1" --map-public-ip-on-launch --region "$AWS_REGION" 2>/dev/null || true

PUB_SUB_2=$(find_or_create_subnet "$VPC_ID" "$PUBLIC_SUBNET_2_CIDR" "$AZ_2" "${PROJECT_NAME}-public-2")
aws ec2 modify-subnet-attribute --subnet-id "$PUB_SUB_2" --map-public-ip-on-launch --region "$AWS_REGION" 2>/dev/null || true

PRIV_SUB_1=$(find_or_create_subnet "$VPC_ID" "$PRIVATE_SUBNET_1_CIDR" "$AZ_1" "${PROJECT_NAME}-private-1")
PRIV_SUB_2=$(find_or_create_subnet "$VPC_ID" "$PRIVATE_SUBNET_2_CIDR" "$AZ_2" "${PROJECT_NAME}-private-2")

ok "Public:  $PUB_SUB_1 ($AZ_1), $PUB_SUB_2 ($AZ_2)"
ok "Private: $PRIV_SUB_1 ($AZ_1), $PRIV_SUB_2 ($AZ_2)"

# ─── NAT Gateway ───────────────────────────────────────────────────────────

step "NAT Gateway"
NAT_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ -z "$NAT_ID" ] || [ "$NAT_ID" = "None" ]; then
    EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text --region "$AWS_REGION")
    NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUB_SUB_1" --allocation-id "$EIP" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat}]" \
        --query 'NatGateway.NatGatewayId' --output text --region "$AWS_REGION")
    info "Waiting for NAT Gateway..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID" --region "$AWS_REGION"
    ok "NAT created: $NAT_ID"
else
    ok "NAT exists: $NAT_ID"
fi

# ─── Route Tables ──────────────────────────────────────────────────────────

step "Route Tables"

# Public route table
PUB_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT_NAME}-pub-rt" \
    --query 'RouteTables[0].RouteTableId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ -z "$PUB_RT" ] || [ "$PUB_RT" = "None" ]; then
    PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-pub-rt}]" \
        --query 'RouteTable.RouteTableId' --output text --region "$AWS_REGION")
    aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_1" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_2" --region "$AWS_REGION" > /dev/null
fi

# Private route table
PRIV_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT_NAME}-priv-rt" \
    --query 'RouteTables[0].RouteTableId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ -z "$PRIV_RT" ] || [ "$PRIV_RT" = "None" ]; then
    PRIV_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-priv-rt}]" \
        --query 'RouteTable.RouteTableId' --output text --region "$AWS_REGION")
    aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_ID" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_1" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_2" --region "$AWS_REGION" > /dev/null
fi
ok "Route tables configured"

# ============================================================================
# SECURITY GROUPS
# ============================================================================

step "Security Groups"

ECS_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ -z "$ECS_SG" ] || [ "$ECS_SG" = "None" ]; then
    ECS_SG=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-ecs-sg" \
        --description "ECS tasks - sshpiper(2222), proxyserver(8079), NFS(2049)" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-ecs-sg}]" \
        --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 2222 --cidr "$VPC_CIDR" --region "$AWS_REGION" > /dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 8079 --cidr "$VPC_CIDR" --region "$AWS_REGION" > /dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 2049 --source-group "$ECS_SG" --region "$AWS_REGION" > /dev/null
fi

VPCE_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-vpce-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ -z "$VPCE_SG" ] || [ "$VPCE_SG" = "None" ]; then
    VPCE_SG=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-vpce-sg" \
        --description "VPC Endpoints - HTTPS from VPC" --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpce-sg}]" \
        --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress --group-id "$VPCE_SG" --protocol tcp --port 443 --cidr "$VPC_CIDR" --region "$AWS_REGION" > /dev/null
fi

ok "ECS SG: $ECS_SG | VPCE SG: $VPCE_SG"

# ============================================================================
# VPC ENDPOINTS (SSM for ECS Exec)
# ============================================================================

step "VPC Endpoints (SSM)"
for SVC in ssm ssmmessages ec2messages; do
    EXISTING_VPCE=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.${SVC}" "Name=vpc-endpoint-state,Values=available,pending" \
        --query 'VpcEndpoints[0].VpcEndpointId' --output text --region "$AWS_REGION" 2>/dev/null)
    if [ -z "$EXISTING_VPCE" ] || [ "$EXISTING_VPCE" = "None" ]; then
        VPCE_ID=$(aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --vpc-endpoint-type Interface \
            --service-name "com.amazonaws.${AWS_REGION}.${SVC}" \
            --subnet-ids "$PRIV_SUB_1" "$PRIV_SUB_2" \
            --security-group-ids "$VPCE_SG" --private-dns-enabled \
            --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${PROJECT_NAME}-${SVC}}]" \
            --query 'VpcEndpoint.VpcEndpointId' --output text --region "$AWS_REGION")
        info "  $SVC: $VPCE_ID (created)"
    else
        info "  $SVC: $EXISTING_VPCE (exists)"
    fi
done
ok "VPC endpoints ready"

# ============================================================================
# S3 BUCKET (session recordings)
# ============================================================================

step "S3 Bucket"
if aws s3api head-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null >/dev/null; then
    ok "S3 exists: $S3_BUCKET_NAME"
else
    if [ "$AWS_REGION" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" > /dev/null
    else
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
    fi
    ok "S3 created: $S3_BUCKET_NAME"
fi
aws s3api put-bucket-versioning --bucket "$S3_BUCKET_NAME" --versioning-configuration Status=Enabled 2>/dev/null || true
aws s3api put-bucket-encryption --bucket "$S3_BUCKET_NAME" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' 2>/dev/null || true

# ============================================================================
# IAM ROLE (single role for execution + task)
# ============================================================================

step "IAM Role"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""

if [ -z "$ROLE_ARN" ]; then
    cat > /tmp/ecs-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file:///tmp/ecs-trust.json \
        --tags "Key=Purpose,Value=vm-jit" "Key=created_by,Value=cloudanix" > /dev/null
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
    ok "IAM Role created: $ROLE_NAME ($ROLE_ARN)"
else
    ok "IAM Role exists: $ROLE_NAME ($ROLE_ARN)"
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" 2>/dev/null || true

cat > /tmp/task-policy.json << EOF
{
    "Version":"2012-10-17",
    "Statement":[
        {"Sid":"ECSExec","Effect":"Allow","Action":["ssmmessages:CreateControlChannel","ssmmessages:CreateDataChannel","ssmmessages:OpenControlChannel","ssmmessages:OpenDataChannel"],"Resource":"*"},
        {"Sid":"SecretsManager","Effect":"Allow","Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],"Resource":"arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:${PROJECT_NAME}*"},
        {"Sid":"S3Recordings","Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::${S3_BUCKET_NAME}","arn:aws:s3:::${S3_BUCKET_NAME}/*"]},
        {"Sid":"CloudWatchLogs","Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogStreams"],"Resource":"*"},
        {"Sid":"EFSAccess","Effect":"Allow","Action":["elasticfilesystem:ClientMount","elasticfilesystem:ClientWrite","elasticfilesystem:ClientRootAccess"],"Resource":"*"},
        {"Sid":"AssumeRole","Effect":"Allow","Action":"sts:AssumeRole","Resource":"*"}
    ]
}
EOF
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "${PROJECT_NAME}-task-policy" \
    --policy-document file:///tmp/task-policy.json

# ============================================================================
# CLOUDWATCH LOG GROUP
# ============================================================================

aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 30 --region "$AWS_REGION" 2>/dev/null || true
ok "Log group: $LOG_GROUP"

# ============================================================================
# SECRETS MANAGER (app config secrets)
# ============================================================================

step "Secrets Manager (app config)"

APP_SECRET_NAME="${PROJECT_NAME}-secret"
EXISTING_SECRET=$(aws secretsmanager describe-secret --secret-id "$APP_SECRET_NAME" --region "$AWS_REGION" 2>/dev/null && echo "yes" || echo "no")

if [ "$EXISTING_SECRET" = "no" ]; then
    CDX_API_AUTH_TOKEN=$(prompt_with_default "CDX_API_AUTH_TOKEN" "")
    CDX_SIGNATURE_SECRET_KEY=$(prompt_with_default "CDX_SIGNATURE_SECRET_KEY" "")
    CDX_SENTRY_DSN=$(prompt_with_default "CDX_SENTRY_DSN (optional, press enter to skip)" "")

    SECRET_JSON=$(jq -n \
        --arg token "$CDX_API_AUTH_TOKEN" \
        --arg sig "$CDX_SIGNATURE_SECRET_KEY" \
        --arg sentry "$CDX_SENTRY_DSN" \
        '{CDX_API_AUTH_TOKEN: $token, CDX_SIGNATURE_SECRET_KEY: $sig, CDX_SENTRY_DSN: $sentry}')

    aws secretsmanager create-secret \
        --name "$APP_SECRET_NAME" \
        --description "App secrets for ${PROJECT_NAME} containers" \
        --secret-string "$SECRET_JSON" \
        --tags "Key=Purpose,Value=vm-jit" "Key=created_by,Value=cloudanix" \
        --region "$AWS_REGION" > /dev/null
    ok "Secret created: $APP_SECRET_NAME"
else
    ok "Secret exists: $APP_SECRET_NAME"
fi

APP_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$APP_SECRET_NAME" \
    --query 'ARN' --output text --region "$AWS_REGION")

# ============================================================================
# EFS (shared volume for sshpiper workingdir + recordings)
# ============================================================================

step "EFS File System"

EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name'&&Value=='${PROJECT_NAME}-efs']].FileSystemId | [0]" \
    --output text --region "$AWS_REGION" 2>/dev/null)

if [ -z "$EFS_ID" ] || [ "$EFS_ID" = "None" ]; then
    EFS_ID=$(aws efs create-file-system \
        --performance-mode generalPurpose \
        --throughput-mode bursting \
        --encrypted \
        --tags "Key=Name,Value=${PROJECT_NAME}-efs" "Key=created_by,Value=cloudanix" \
        --query 'FileSystemId' --output text --region "$AWS_REGION")

    info "Waiting for EFS to become available..."
    for i in $(seq 1 20); do
        EFS_STATE=$(aws efs describe-file-systems --file-system-id "$EFS_ID" \
            --query 'FileSystems[0].LifeCycleState' --output text --region "$AWS_REGION")
        if [ "$EFS_STATE" = "available" ]; then break; fi
        sleep 5
    done
    ok "EFS created: $EFS_ID"
else
    ok "EFS exists: $EFS_ID"
fi

# Mount targets (idempotent — only create if not present)
for SUB in "$PRIV_SUB_1" "$PRIV_SUB_2"; do
    EXISTING_MT=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query "MountTargets[?SubnetId=='${SUB}'].MountTargetId | [0]" --output text --region "$AWS_REGION" 2>/dev/null)
    if [ -z "$EXISTING_MT" ] || [ "$EXISTING_MT" = "None" ]; then
        aws efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$SUB" \
            --security-groups "$ECS_SG" --region "$AWS_REGION" > /dev/null
    fi
done
info "Waiting for mount targets..."
sleep 20

# Access points (idempotent)
SSHPIPER_AP=$(aws efs describe-access-points --file-system-id "$EFS_ID" \
    --query "AccessPoints[?Tags[?Key=='Name'&&Value=='${PROJECT_NAME}-sshpiper-ap']].AccessPointId | [0]" \
    --output text --region "$AWS_REGION" 2>/dev/null)
if [ -z "$SSHPIPER_AP" ] || [ "$SSHPIPER_AP" = "None" ]; then
    SSHPIPER_AP=$(aws efs create-access-point --file-system-id "$EFS_ID" \
        --posix-user "Uid=0,Gid=0" \
        --root-directory "Path=/sshpiper,CreationInfo={OwnerUid=0,OwnerGid=0,Permissions=0777}" \
        --tags "Key=Name,Value=${PROJECT_NAME}-sshpiper-ap" \
        --query 'AccessPointId' --output text --region "$AWS_REGION")
fi

RECORDINGS_AP=$(aws efs describe-access-points --file-system-id "$EFS_ID" \
    --query "AccessPoints[?Tags[?Key=='Name'&&Value=='${PROJECT_NAME}-recordings-ap']].AccessPointId | [0]" \
    --output text --region "$AWS_REGION" 2>/dev/null)
if [ -z "$RECORDINGS_AP" ] || [ "$RECORDINGS_AP" = "None" ]; then
    RECORDINGS_AP=$(aws efs create-access-point --file-system-id "$EFS_ID" \
        --posix-user "Uid=0,Gid=0" \
        --root-directory "Path=/recordings,CreationInfo={OwnerUid=0,OwnerGid=0,Permissions=0777}" \
        --tags "Key=Name,Value=${PROJECT_NAME}-recordings-ap" \
        --query 'AccessPointId' --output text --region "$AWS_REGION")
fi

ok "EFS: $EFS_ID (sshpiper-ap: $SSHPIPER_AP, recordings-ap: $RECORDINGS_AP)"

# ============================================================================
# CLOUD MAP NAMESPACE (Service Discovery) — FIXED: proper timeout handling
# ============================================================================

step "Cloud Map Namespace"

NAMESPACE_ID=$(aws servicediscovery list-namespaces \
    --filters "Name=NAME,Values=${NAMESPACE}" \
    --query 'Namespaces[0].Id' --output text --region "$AWS_REGION" 2>/dev/null)

if [ -z "$NAMESPACE_ID" ] || [ "$NAMESPACE_ID" = "None" ]; then
    OPERATION_ID=$(aws servicediscovery create-private-dns-namespace \
        --name "$NAMESPACE" \
        --vpc "$VPC_ID" \
        --description "Service discovery for ${PROJECT_NAME}" \
        --query 'OperationId' --output text --region "$AWS_REGION")

    info "Waiting for namespace creation (up to 3 min)..."
    NAMESPACE_READY=false
    for i in $(seq 1 36); do
        OP_STATUS=$(aws servicediscovery get-operation --operation-id "$OPERATION_ID" \
            --query 'Operation.Status' --output text --region "$AWS_REGION" 2>/dev/null)
        if [ "$OP_STATUS" = "SUCCESS" ]; then
            NAMESPACE_READY=true
            break
        fi
        if [ "$OP_STATUS" = "FAIL" ]; then
            echo "[ERROR] Namespace creation failed!"
            aws servicediscovery get-operation --operation-id "$OPERATION_ID" --region "$AWS_REGION"
            exit 1
        fi
        sleep 5
    done

    if [ "$NAMESPACE_READY" = false ]; then
        echo "[ERROR] Timed out waiting for Cloud Map namespace creation (3 min)."
        echo "        Operation ID: $OPERATION_ID"
        echo "        Check: aws servicediscovery get-operation --operation-id $OPERATION_ID --region $AWS_REGION"
        exit 1
    fi

    NAMESPACE_ID=$(aws servicediscovery list-namespaces \
        --filters "Name=NAME,Values=${NAMESPACE}" \
        --query 'Namespaces[0].Id' --output text --region "$AWS_REGION")
    ok "Namespace created: $NAMESPACE ($NAMESPACE_ID)"
else
    ok "Namespace exists: $NAMESPACE ($NAMESPACE_ID)"
fi

# ============================================================================
# ECS CLUSTER (with Service Connect)
# ============================================================================

step "ECS Cluster"

# Ensure ECS Service Linked Role exists (required for Service Connect)
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true
info "Ensuring ECS Service Linked Role is ready..."
sleep 10

CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" \
    --query 'clusters[0].status' --output text --region "$AWS_REGION" 2>/dev/null)

if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
    # Update with namespace if needed
    aws ecs update-cluster --cluster "$CLUSTER_NAME" \
        --service-connect-defaults "namespace=arn:aws:servicediscovery:${AWS_REGION}:${ACCOUNT_ID}:namespace/${NAMESPACE_ID}" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    ok "Cluster exists: $CLUSTER_NAME"
else
    # Retry loop to handle SLR propagation delay
    CLUSTER_CREATED=false
    for attempt in 1 2 3; do
        if aws ecs create-cluster --cluster-name "$CLUSTER_NAME" \
            --capacity-providers FARGATE \
            --default-capacity-provider-strategy "capacityProvider=FARGATE,weight=1" \
            --configuration "executeCommandConfiguration={logging=DEFAULT}" \
            --service-connect-defaults "namespace=arn:aws:servicediscovery:${AWS_REGION}:${ACCOUNT_ID}:namespace/${NAMESPACE_ID}" \
            --tags "key=Purpose,value=vm-jit" "key=created_by,value=cloudanix" \
            --region "$AWS_REGION" > /dev/null 2>&1; then
            CLUSTER_CREATED=true
            break
        fi
        info "ECS SLR not ready yet, retrying in 15s (attempt $attempt/3)..."
        sleep 15
    done
    if [ "$CLUSTER_CREATED" = false ]; then
        echo "[ERROR] Failed to create ECS cluster after 3 attempts. ECS Service Linked Role may need more time."
        echo "        Try running the script again in a minute."
        exit 1
    fi
    ok "Cluster created: $CLUSTER_NAME"
fi

# ============================================================================
# TASK DEFINITIONS (with EFS volumes)
# ============================================================================

step "Task Definitions"

EFS_VOLUMES='[{"name":"sshpiper-workingdir","efsVolumeConfiguration":{"fileSystemId":"'$EFS_ID'","transitEncryption":"ENABLED","authorizationConfig":{"accessPointId":"'$SSHPIPER_AP'","iam":"ENABLED"}}},{"name":"sshpiper-recordings","efsVolumeConfiguration":{"fileSystemId":"'$EFS_ID'","transitEncryption":"ENABLED","authorizationConfig":{"accessPointId":"'$RECORDINGS_AP'","iam":"ENABLED"}}}]'

# 1. sshpiper
cat > /tmp/td-sshpiper.json << EOF
{
    "family": "${PROJECT_NAME}-sshpiper",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256", "memory": "512",
    "executionRoleArn": "${ROLE_ARN}",
    "taskRoleArn": "${ROLE_ARN}",
    "volumes": ${EFS_VOLUMES},
    "containerDefinitions": [{
        "name": "sshpiper",
        "image": "${ECR_PREFIX}/cloudanix/ecr-aws-jit-vm-sshpiper:latest",
        "essential": true,
        "portMappings": [{"name":"sshpiper","containerPort":2222,"protocol":"tcp"}],
        "mountPoints": [
            {"sourceVolume":"sshpiper-workingdir","containerPath":"/tmp/sshpiper/workingdir","readOnly":false},
            {"sourceVolume":"sshpiper-recordings","containerPath":"/tmp/recordings","readOnly":false}
        ],
        "linuxParameters": {"initProcessEnabled": true},
        "logConfiguration": {"logDriver":"awslogs","options":{"awslogs-group":"${LOG_GROUP}","awslogs-region":"${AWS_REGION}","awslogs-stream-prefix":"sshpiper"}}
    }]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-sshpiper.json --region "$AWS_REGION" > /dev/null
ok "Task def: ${PROJECT_NAME}-sshpiper"

# 2. vmproxyserver
cat > /tmp/td-proxyserver.json << EOF
{
    "family": "${PROJECT_NAME}-vmproxyserver",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "512", "memory": "1024",
    "executionRoleArn": "${ROLE_ARN}",
    "taskRoleArn": "${ROLE_ARN}",
    "volumes": ${EFS_VOLUMES},
    "containerDefinitions": [{
        "name": "vmproxyserver",
        "image": "${ECR_PREFIX}/cloudanix/cdx-jit-vm-vmproxyserver:latest",
        "essential": true,
        "portMappings": [{"name":"vmproxyserver","containerPort":8079,"protocol":"tcp"}],
        "mountPoints": [
            {"sourceVolume":"sshpiper-workingdir","containerPath":"/tmp/sshpiper/workingdir","readOnly":false},
            {"sourceVolume":"sshpiper-recordings","containerPath":"/tmp/recordings","readOnly":false}
        ],
        "environment": [
            {"name":"CDX_ENVIRONMENT","value":"production"},
            {"name":"CDX_DEFAULT_REGION","value":"${AWS_REGION}"},
            {"name":"CDX_DATA_CENTER","value":"US"},
            {"name":"CDX_LOG_LEVEL","value":"DEBUG"},
            {"name":"CDX_VM_PROXY_VERSION","value":"1.0.0"},
            {"name":"CDX_VM_LOG_MANAGER_VERSION","value":"1.0.0"},
            {"name":"CDX_VM_LOGGING_S3_BUCKET","value":"${S3_BUCKET_NAME}"},
            {"name":"CDX_VM_SECRETS_MANAGER_NAME","value":"${PROJECT_NAME}-ssh-keys"},
            {"name":"AWS_STS_REGIONAL_ENDPOINTS","value":"regional"}
        ],
        "secrets": [
            {"name":"CDX_API_AUTH_TOKEN","valueFrom":"${APP_SECRET_ARN}:CDX_API_AUTH_TOKEN::"},
            {"name":"CDX_SIGNATURE_SECRET_KEY","valueFrom":"${APP_SECRET_ARN}:CDX_SIGNATURE_SECRET_KEY::"},
            {"name":"CDX_SENTRY_DSN","valueFrom":"${APP_SECRET_ARN}:CDX_SENTRY_DSN::"}
        ],
        "healthCheck": {
            "command": ["CMD-SHELL","pgrep -f 'python.*main.py' || exit 1"],
            "interval": 30, "timeout": 5, "retries": 3, "startPeriod": 15
        },
        "linuxParameters": {"initProcessEnabled": true},
        "logConfiguration": {"logDriver":"awslogs","options":{"awslogs-group":"${LOG_GROUP}","awslogs-region":"${AWS_REGION}","awslogs-stream-prefix":"vmproxyserver"}}
    }]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-proxyserver.json --region "$AWS_REGION" > /dev/null
ok "Task def: ${PROJECT_NAME}-vmproxyserver"

# 3. vmcommandlogging
cat > /tmp/td-logging.json << EOF
{
    "family": "${PROJECT_NAME}-vmcommandlogging",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256", "memory": "512",
    "executionRoleArn": "${ROLE_ARN}",
    "taskRoleArn": "${ROLE_ARN}",
    "volumes": ${EFS_VOLUMES},
    "containerDefinitions": [{
        "name": "vmcommandlogging",
        "image": "${ECR_PREFIX}/cloudanix/ecr-aws-jit-vm-logging:latest",
        "essential": true,
        "mountPoints": [
            {"sourceVolume":"sshpiper-workingdir","containerPath":"/tmp/sshpiper/workingdir","readOnly":false},
            {"sourceVolume":"sshpiper-recordings","containerPath":"/tmp/recordings","readOnly":false}
        ],
        "environment": [
            {"name":"CDX_ENVIRONMENT","value":"production"},
            {"name":"CDX_DEFAULT_REGION","value":"${AWS_REGION}"},
            {"name":"CDX_DATA_CENTER","value":"US"},
            {"name":"CDX_LOG_LEVEL","value":"INFO"},
            {"name":"CDX_VM_LOG_MANAGER_VERSION","value":"1.0.0"},
            {"name":"CDX_VM_LOGGING_S3_BUCKET","value":"${S3_BUCKET_NAME}"},
            {"name":"AWS_STS_REGIONAL_ENDPOINTS","value":"regional"}
        ],
        "secrets": [
            {"name":"CDX_API_AUTH_TOKEN","valueFrom":"${APP_SECRET_ARN}:CDX_API_AUTH_TOKEN::"},
            {"name":"CDX_SIGNATURE_SECRET_KEY","valueFrom":"${APP_SECRET_ARN}:CDX_SIGNATURE_SECRET_KEY::"},
            {"name":"CDX_SENTRY_DSN","valueFrom":"${APP_SECRET_ARN}:CDX_SENTRY_DSN::"}
        ],
        "healthCheck": {
            "command": ["CMD-SHELL","pgrep -f 'python.*commandlogmanager' || exit 1"],
            "interval": 30, "timeout": 5, "retries": 3, "startPeriod": 15
        },
        "linuxParameters": {"initProcessEnabled": true},
        "logConfiguration": {"logDriver":"awslogs","options":{"awslogs-group":"${LOG_GROUP}","awslogs-region":"${AWS_REGION}","awslogs-stream-prefix":"vmcommandlogging"}}
    }]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-logging.json --region "$AWS_REGION" > /dev/null
ok "Task def: ${PROJECT_NAME}-vmcommandlogging"

# ============================================================================
# ECS SERVICES (with Service Connect)
# ============================================================================

step "ECS Services"

NETWORK_CONFIG="awsvpcConfiguration={subnets=[$PRIV_SUB_1,$PRIV_SUB_2],securityGroups=[$ECS_SG],assignPublicIp=DISABLED}"

# Service Connect configs
SC_SSHPIPER='{"enabled":true,"namespace":"arn:aws:servicediscovery:'$AWS_REGION':'$ACCOUNT_ID':namespace/'$NAMESPACE_ID'","services":[{"portName":"sshpiper","discoveryName":"sshpiper","clientAliases":[{"port":2222,"dnsName":"sshpiper.'$NAMESPACE'"}]}]}'
SC_VMPROXY='{"enabled":true,"namespace":"arn:aws:servicediscovery:'$AWS_REGION':'$ACCOUNT_ID':namespace/'$NAMESPACE_ID'","services":[{"portName":"vmproxyserver","discoveryName":"vmproxyserver","clientAliases":[{"port":8079,"dnsName":"vmproxyserver.'$NAMESPACE'"}]}]}'
SC_LOGGING='{"enabled":true,"namespace":"arn:aws:servicediscovery:'$AWS_REGION':'$ACCOUNT_ID':namespace/'$NAMESPACE_ID'"}'

create_or_skip_service() {
    local svc_name=$1 task_def=$2 sc_config=$3
    local existing=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc_name" \
        --query 'services[?status==`ACTIVE`].serviceName | [0]' --output text --region "$AWS_REGION" 2>/dev/null)
    if [ -n "$existing" ] && [ "$existing" != "None" ]; then
        ok "Service exists: $svc_name"
    else
        aws ecs create-service \
            --cluster "$CLUSTER_NAME" \
            --service-name "$svc_name" \
            --task-definition "$task_def" \
            --desired-count 1 \
            --launch-type FARGATE \
            --enable-execute-command \
            --network-configuration "$NETWORK_CONFIG" \
            --service-connect-configuration "$sc_config" \
            --tags "key=Purpose,value=vm-jit" "key=created_by,value=cloudanix" \
            --region "$AWS_REGION" > /dev/null
        ok "Service created: $svc_name"
    fi
}

create_or_skip_service "${PROJECT_NAME}-sshpiper" "${PROJECT_NAME}-sshpiper" "$SC_SSHPIPER"
create_or_skip_service "${PROJECT_NAME}-vmproxyserver" "${PROJECT_NAME}-vmproxyserver" "$SC_VMPROXY"
create_or_skip_service "${PROJECT_NAME}-vmcommandlogging" "${PROJECT_NAME}-vmcommandlogging" "$SC_LOGGING"

# ============================================================================
# OUTPUT
# ============================================================================

step "Infrastructure Setup Complete"
echo ""
echo "  VPC:             $VPC_ID ($VPC_CIDR)"
echo "  Public Subnets:  $PUB_SUB_1, $PUB_SUB_2"
echo "  Private Subnets: $PRIV_SUB_1, $PRIV_SUB_2"
echo "  ECS Cluster:     $CLUSTER_NAME"
echo "  ECS SG:          $ECS_SG"
echo "  EFS:             $EFS_ID"
echo "  IAM Role:        $ROLE_NAME"
echo "  S3 Bucket:       $S3_BUCKET_NAME"
echo "  Namespace:       $NAMESPACE ($NAMESPACE_ID)"
echo "  Log Group:       $LOG_GROUP"
echo ""
echo "  Services (Service Connect):"
echo "    sshpiper:2222         — SSH proxy"
echo "    vmproxyserver:8079    — control plane"
echo "    vmcommandlogging      — log uploader"
echo ""
echo "  Shared EFS: $EFS_ID"
echo "    /tmp/sshpiper/workingdir  (AP: $SSHPIPER_AP)"
echo "    /tmp/recordings           (AP: $RECORDINGS_AP)"
echo ""
echo "  Next: ./3.setup-vpc-peering.sh"
echo ""

# Cleanup temp files
rm -f /tmp/ecs-trust.json /tmp/task-policy.json /tmp/td-sshpiper.json /tmp/td-proxyserver.json /tmp/td-logging.json
