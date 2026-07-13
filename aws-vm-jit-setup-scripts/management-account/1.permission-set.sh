#!/bin/bash
set -e

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

echo "=== AWS SSO Permission Set Setup (JIT VM) ==="

INSTANCE_ARN=$(prompt_with_default "Enter SSO Instance ARN" "arn:aws:sso:::instance/ssoins-722367552337aabd")
PERMISSION_SET_NAME=$(prompt_with_default "Enter Permission Set Name" "cdx-EcsVmSsmAccess")
JIT_ACCOUNT_ID=$(prompt_with_default "Enter JIT Workload Account ID" "")
JIT_REGION=$(prompt_with_default "Enter JIT Account Region" "us-east-1")
JIT_CLUSTER_NAME=$(prompt_with_default "Enter JIT ECS Cluster Name" "cdx-jit-vm-cluster")
SESSION_DURATION="PT8H"

cat << EOF > permission-set-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "SSMSessionPolicy",
            "Effect": "Allow",
            "Action": [
                "ssm:StartSession",
                "ssm:DescribeSessions",
                "ssm:TerminateSession"
            ],
            "Resource": [
                "arn:aws:ecs:$JIT_REGION:$JIT_ACCOUNT_ID:cluster/$JIT_CLUSTER_NAME",
                "arn:aws:ecs:$JIT_REGION:$JIT_ACCOUNT_ID:task/$JIT_CLUSTER_NAME/*",
                "arn:aws:ssm:$JIT_REGION::document/AWS-StartPortForwardingSession"
            ]
        },
        {
            "Sid": "ECSDescribePolicy",
            "Effect": "Allow",
            "Action": [
                "ecs:DescribeTasks",
                "ecs:ListTasks",
                "ecs:DescribeServices",
                "ecs:ListServices",
                "ecs:ExecuteCommand"
            ],
            "Resource": [
                "arn:aws:ecs:$JIT_REGION:$JIT_ACCOUNT_ID:cluster/$JIT_CLUSTER_NAME",
                "arn:aws:ecs:$JIT_REGION:$JIT_ACCOUNT_ID:task/$JIT_CLUSTER_NAME/*",
                "arn:aws:ecs:$JIT_REGION:$JIT_ACCOUNT_ID:service/$JIT_CLUSTER_NAME/*"
            ]
        }
    ]
}
EOF

echo ""
echo "=== Configuration Summary ==="
echo "SSO Instance ARN:   $INSTANCE_ARN"
echo "Permission Set:     $PERMISSION_SET_NAME"
echo "JIT Account ID:     $JIT_ACCOUNT_ID"
echo "JIT Region:         $JIT_REGION"
echo "JIT Cluster Name:   $JIT_CLUSTER_NAME"
echo ""

echo "Step 1: Creating Permission Set..."
PERMISSION_SET_ARN=$(aws sso-admin create-permission-set \
    --instance-arn "$INSTANCE_ARN" \
    --name "$PERMISSION_SET_NAME" \
    --description "Permission set for JIT VM access via ECS SSM" \
    --session-duration "$SESSION_DURATION" \
    --query 'PermissionSet.PermissionSetArn' \
    --output text)
echo "Created: $PERMISSION_SET_ARN"

echo "Step 2: Adding inline policy..."
aws sso-admin put-inline-policy-to-permission-set \
    --instance-arn "$INSTANCE_ARN" \
    --permission-set-arn "$PERMISSION_SET_ARN" \
    --inline-policy file://permission-set-policy.json

echo "Step 3: Verifying..."
aws sso-admin describe-permission-set \
    --instance-arn "$INSTANCE_ARN" \
    --permission-set-arn "$PERMISSION_SET_ARN"

echo ""
echo "Done. Assign this permission set to users/groups in the JIT account."
