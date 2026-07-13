#!/bin/bash
# Attaches EKS JIT policies to the cross-account IAM role in the management account.
#   1. Auto-discovers the cross-account role (cdx-*-role_cross_accnt*)
#   2. Creates and attaches CdxCreateJitEKSPermission policy (SSO + EKS access entry creation)
#   3. Creates and attaches CdxManageEKSAccessEntry policy (EKS access entry lifecycle)
#
# Run this in the MANAGEMENT ACCOUNT.
###############################################################################
set -euo pipefail

###############################################################################
# Helper functions
###############################################################################
prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -rp "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
ok()   { echo "[✓] $*"; }
info() { echo "[i] $*"; }
step() { echo ""; echo "━━━ $* ━━━"; }

###############################################################################
# Configuration
###############################################################################
echo "=== AWS EKS JIT — Management Account Policy Setup ==="
echo ""

AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")
export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
info "Account ID: $ACCOUNT_ID"

###############################################################################
# Auto-discover cross-account role
###############################################################################
step "Discovering cross-account role"

ROLE_NAME=""
DISCOVERED_ROLES=$(aws iam list-roles \
    --query "Roles[?contains(RoleName, 'cdx-') && contains(RoleName, 'role_cross_accnt')].RoleName" \
    --output text 2>/dev/null || echo "")

if [[ -n "$DISCOVERED_ROLES" && "$DISCOVERED_ROLES" != "None" ]]; then
    # Convert whitespace-separated output into a clean array
    ROLE_ARRAY=()
    for r in $DISCOVERED_ROLES; do
        ROLE_ARRAY+=("$r")
    done

    if [[ ${#ROLE_ARRAY[@]} -eq 1 ]]; then
        ROLE_NAME="${ROLE_ARRAY[0]}"
        ok "Auto-discovered role: $ROLE_NAME"
    else
        echo ""
        echo "Multiple cross-account roles found:"
        for i in "${!ROLE_ARRAY[@]}"; do
            echo "  $((i + 1))) ${ROLE_ARRAY[$i]}"
        done
        echo ""
        read -rp "Select role number [1]: " ROLE_CHOICE
        ROLE_CHOICE="${ROLE_CHOICE:-1}"
        # Validate selection is a number and in range
        if ! [[ "$ROLE_CHOICE" =~ ^[0-9]+$ ]] || [[ "$ROLE_CHOICE" -lt 1 ]] || [[ "$ROLE_CHOICE" -gt ${#ROLE_ARRAY[@]} ]]; then
            echo "ERROR: Invalid selection. Please enter a number between 1 and ${#ROLE_ARRAY[@]}."
            exit 1
        fi
        ROLE_NAME="${ROLE_ARRAY[$((ROLE_CHOICE - 1))]}"
        ok "Selected role: $ROLE_NAME"
    fi
else
    info "Could not auto-discover role matching pattern 'cdx-*-role_cross_accnt*'"
    ROLE_NAME=$(prompt_with_default "Enter the cross-account IAM role name" "")
    if [[ -z "$ROLE_NAME" ]]; then
        echo "ERROR: Role name is required."
        exit 1
    fi
fi

# Verify role exists
if ! aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
    echo "ERROR: Role '$ROLE_NAME' not found in this account."
    exit 1
fi
ok "Role verified: $ROLE_NAME"

###############################################################################
# Policy 1: CdxCreateJitEKSPermission
###############################################################################
step "Policy: CdxCreateJitEKSPermission"

POLICY_1_NAME="CdxCreateJitEKSPermission"
POLICY_1_DOC=$(cat <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowSSOAndEKSAccessEntryCreation",
            "Effect": "Allow",
            "Action": [
                "sso:CreatePermissionSet",
                "sso:PutInlinePolicyToPermissionSet",
                "sso:DeletePermissionSet",
                "sso:ListPermissionSets",
                "eks:CreateAccessEntry"
            ],
            "Resource": "*"
        }
    ]
}
EOF
)

POLICY_1_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_1_NAME}"

# Check if policy already exists
if aws iam get-policy --policy-arn "$POLICY_1_ARN" > /dev/null 2>&1; then
    ok "Policy already exists: $POLICY_1_NAME"
else
    aws iam create-policy \
        --policy-name "$POLICY_1_NAME" \
        --description "Allows SSO permission set management and EKS access entry creation for JIT EKS" \
        --policy-document "$POLICY_1_DOC" > /dev/null
    ok "Policy created: $POLICY_1_NAME"
fi

# Attach policy to role (idempotent)
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_1_ARN" 2>/dev/null || true
ok "Attached $POLICY_1_NAME to $ROLE_NAME"

###############################################################################
# Policy 2: CdxManageEKSAccessEntry
###############################################################################
step "Policy: CdxManageEKSAccessEntry"

POLICY_2_NAME="CdxManageEKSAccessEntry"
POLICY_2_DOC=$(cat <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowEKSAccessEntryLifecycle",
            "Effect": "Allow",
            "Action": [
                "eks:CreateAccessEntry",
                "eks:AssociateAccessPolicy",
                "eks:DisassociateAccessPolicy",
                "eks:DeleteAccessEntry"
            ],
            "Resource": "*"
        }
    ]
}
EOF
)

POLICY_2_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_2_NAME}"

# Check if policy already exists
if aws iam get-policy --policy-arn "$POLICY_2_ARN" > /dev/null 2>&1; then
    ok "Policy already exists: $POLICY_2_NAME"
else
    aws iam create-policy \
        --policy-name "$POLICY_2_NAME" \
        --description "Allows full EKS access entry lifecycle management for JIT EKS" \
        --policy-document "$POLICY_2_DOC" > /dev/null
    ok "Policy created: $POLICY_2_NAME"
fi

# Attach policy to role (idempotent)
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_2_ARN" 2>/dev/null || true
ok "Attached $POLICY_2_NAME to $ROLE_NAME"

###############################################################################
# Summary
###############################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Management Account EKS JIT Policy Setup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Account         : $ACCOUNT_ID"
echo "  Region          : $AWS_REGION"
echo "  Role            : $ROLE_NAME"
echo ""
echo "  Policies attached:"
echo "    1. $POLICY_1_NAME — SSO permission set + EKS access entry creation"
echo "    2. $POLICY_2_NAME — EKS access entry lifecycle (create/associate/delete)"
echo ""
echo "  Next steps:"
echo "    → Run jit-workload-account/1.attach-eks-policies.sh in the JIT workload account"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
