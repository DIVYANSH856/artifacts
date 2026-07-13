#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Helper functions
###############################################################################
ok()   { echo "[✓] $*"; }
info() { echo "[i] $*"; }
step() { echo ""; echo "━━━ $* ━━━"; }

###############################################################################
# Configuration
###############################################################################
echo "=== AWS EKS JIT — Create Permission Sets ==="
echo ""

read -rp "AWS Region [us-east-1]: " INPUT_REGION
REGION="${INPUT_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

# Get SSO Instance ARN
info "Discovering SSO instance..."
INSTANCE_ARN=$(aws sso-admin list-instances \
    --query "Instances[0].InstanceArn" --output text 2>/dev/null)

if [[ -z "$INSTANCE_ARN" || "$INSTANCE_ARN" == "None" ]]; then
    echo "ERROR: Could not find an IAM Identity Center instance."
    echo "       Ensure IAM Identity Center is enabled in this account/region."
    exit 1
fi
ok "SSO Instance: $INSTANCE_ARN"

SESSION_DURATION="PT1H"

###############################################################################
# Permission Sets to create
###############################################################################
PERMISSION_SETS=(
    "AmazonEKSAdminPolicy"
    "AmazonEKSClusterAdminPolicy"
    "AmazonEKSAdminViewPolicy"
    "AmazonEKSEditPolicy"
    "AmazonEKSViewPolicy"
)

###############################################################################
# Helper: check if permission set already exists
###############################################################################
get_permission_set_arn() {
    local name=$1
    local next_token=""
    local ps_arn=""

    while true; do
        if [[ -n "$next_token" ]]; then
            RESPONSE=$(aws sso-admin list-permission-sets \
                --instance-arn "$INSTANCE_ARN" \
                --next-token "$next_token" \
                --query '{arns: PermissionSets, token: NextToken}' --output json 2>/dev/null)
        else
            RESPONSE=$(aws sso-admin list-permission-sets \
                --instance-arn "$INSTANCE_ARN" \
                --query '{arns: PermissionSets, token: NextToken}' --output json 2>/dev/null)
        fi

        # Check each permission set ARN for matching name
        ARNS=$(echo "$RESPONSE" | jq -r '.arns[]? // empty')
        for arn in $ARNS; do
            PS_NAME=$(aws sso-admin describe-permission-set \
                --instance-arn "$INSTANCE_ARN" \
                --permission-set-arn "$arn" \
                --query "PermissionSet.Name" --output text 2>/dev/null)
            if [[ "$PS_NAME" == "$name" ]]; then
                echo "$arn"
                return 0
            fi
        done

        next_token=$(echo "$RESPONSE" | jq -r '.token // empty')
        if [[ -z "$next_token" || "$next_token" == "null" ]]; then
            break
        fi
    done

    echo ""
    return 0
}

###############################################################################
# Create Permission Sets
###############################################################################
step "Creating Permission Sets"

for PS_NAME in "${PERMISSION_SETS[@]}"; do
    echo ""
    echo "--- $PS_NAME ---"

    EXISTING_ARN=$(get_permission_set_arn "$PS_NAME")

    if [[ -n "$EXISTING_ARN" ]]; then
        ok "Already exists: $EXISTING_ARN"
    else
        PS_ARN=$(aws sso-admin create-permission-set \
            --instance-arn "$INSTANCE_ARN" \
            --name "$PS_NAME" \
            --description "EKS JIT access policy - $PS_NAME" \
            --session-duration "$SESSION_DURATION" \
            --query "PermissionSet.PermissionSetArn" \
            --output text)
        ok "Created: $PS_ARN"
    fi
done

###############################################################################
# Summary
###############################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Permission Sets Created"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  SSO Instance     : $INSTANCE_ARN"
echo "  Session Duration : $SESSION_DURATION"
echo ""
echo "  Permission Sets:"
echo "    1. AmazonEKSAdminPolicy"
echo "    2. AmazonEKSClusterAdminPolicy"
echo "    3. AmazonEKSAdminViewPolicy"
echo "    4. AmazonEKSEditPolicy"
echo "    5. AmazonEKSViewPolicy"
echo ""
echo "  These are empty permission sets (no policies attached)."
echo "  They map to EKS access policies for JIT access entry creation."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
