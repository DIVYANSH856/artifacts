#!/bin/bash
set -e

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

echo "=== Store VM SSH Key in Secrets Manager ==="

PROJECT_NAME=$(prompt_with_default "Project Name" "cdx-jit-vm")
SECRET_NAME=$(prompt_with_default "Secret Name" "${PROJECT_NAME}/vm-ssh-key-1")
KEY_FILE=$(prompt_with_default "Path to SSH private key file" "/tmp/target-key.pem")
AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")
DESCRIPTION=$(prompt_with_default "Description" "SSH key for target VM")

if [ ! -f "$KEY_FILE" ]; then
    echo "ERROR: Key file not found: $KEY_FILE"
    exit 1
fi

echo ""
echo "Storing key from $KEY_FILE as secret: $SECRET_NAME"

# Check if secret already exists
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" 2>/dev/null; then
    echo "Secret exists. Updating..."
    aws secretsmanager update-secret \
        --secret-id "$SECRET_NAME" \
        --secret-string "file://$KEY_FILE" \
        --region "$AWS_REGION" > /dev/null
else
    echo "Creating new secret..."
    aws secretsmanager create-secret \
        --name "$SECRET_NAME" \
        --description "$DESCRIPTION" \
        --secret-string "file://$KEY_FILE" \
        --tags "Key=Purpose,Value=vm-jit" "Key=created_by,Value=cloudanix" \
        --region "$AWS_REGION" > /dev/null
fi

echo ""
echo "Done. Secret stored: $SECRET_NAME"
echo "The sshpiper container can retrieve this key for target VM authentication."
