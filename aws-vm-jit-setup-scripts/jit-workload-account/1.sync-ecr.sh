#!/bin/bash
set -e

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

cleanup_old_images() {
    local repository="$1"
    local region="$2"
    local images_to_delete=$(aws ecr list-images \
        --repository-name "$repository" --region "$region" \
        --query 'imageIds[?imageTag!=`latest`].imageDigest' --output text)
    if [ -n "$images_to_delete" ]; then
        echo "Deleting old images..."
        for digest in $images_to_delete; do
            aws ecr batch-delete-image --repository-name "$repository" \
                --region "$region" --image-ids imageDigest=$digest --output text > /dev/null
        done
    fi
}

# Configuration
SOURCE_ACCOUNT_ID="774118602354"
TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Your AWS Account ID is: $TARGET_ACCOUNT_ID"

SOURCE_REGION="us-east-2"
TARGET_REGION_INPUT="${1:-us-east-1}"
TARGET_REGION=$(prompt_with_default "Enter the region of JIT VM setup" "$TARGET_REGION_INPUT")

IMAGE_TAG="latest"
PLATFORM="linux/amd64"

# Authenticate
echo "Authenticating to source ECR..."
aws ecr get-login-password --region "$SOURCE_REGION" | \
    docker login --username AWS --password-stdin "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com"

echo "Authenticating to target ECR..."
aws ecr get-login-password --region "$TARGET_REGION" | \
    docker login --username AWS --password-stdin "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com"

# Repositories for JIT VM
REPOSITORIES=(
    "cloudanix/ecr-aws-jit-vm-sshpiper"
    "cloudanix/ecr-aws-jit-vm-proxyserver"
    "cloudanix/ecr-aws-jit-vm-logging"
)

for REPO in "${REPOSITORIES[@]}"; do
    echo ""
    echo "Processing: $REPO"

    aws ecr describe-repositories --region "$TARGET_REGION" --repository-names "$REPO" >/dev/null 2>&1 || \
        aws ecr create-repository --region "$TARGET_REGION" --repository-name "$REPO"

    echo "  Pulling..."
    docker pull --platform "$PLATFORM" "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$REPO:$IMAGE_TAG"

    echo "  Tagging..."
    docker tag "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$REPO:$IMAGE_TAG" \
        "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:$IMAGE_TAG"

    echo "  Pushing..."
    docker push "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:$IMAGE_TAG"

    cleanup_old_images "$REPO" "$TARGET_REGION"
done

echo ""
echo "Image sync complete."
