#!/bin/bash

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

prompt_yes_no() {
    local prompt="$1"
    local default_value="${2:-n}"
    while true; do
        read -p "$prompt (y/n) [$default_value]: " yn
        yn=${yn:-$default_value}
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

cleanup_old_images() {
    local repository="$1"
    local region="$2"
    local keep_tag="$3"
    
    # Get all image digests except 'latest' and the current version tag
    local images_to_delete=$(aws ecr list-images \
        --repository-name "$repository" \
        --region "$region" \
        --query "imageIds[?imageTag!=\`latest\` && imageTag!=\`$keep_tag\`].imageDigest" \
        --output text)
    
    if [ -n "$images_to_delete" ]; then
        echo "Deleting old images..."
        for digest in $images_to_delete; do
            aws ecr batch-delete-image \
                --repository-name "$repository" \
                --region "$region" \
                --image-ids imageDigest=$digest --output text > /dev/null
            echo "Deleted image: $digest"
        done
    else
        echo "No old images to delete"
    fi
}

# Set variables
SOURCE_ACCOUNT_ID="774118602354"
TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Your AWS Account ID is: $TARGET_ACCOUNT_ID"

SOURCE_REGION="us-east-2"
TARGET_REGION_INPUT="${1:-"us-east-1"}"
TARGET_REGION=$(prompt_with_default "Enter the region of jit db setup" "$TARGET_REGION_INPUT")

IMAGE_TAG_INPUT="${2:-"latest"}"
IMAGE_TAG=$(prompt_with_default "Enter the image tag to pull and push" "$IMAGE_TAG_INPUT")
PLATFORM="linux/amd64"

echo ""
ENABLE_DAM=false
if prompt_yes_no "Enable Database Activity Monitoring (DAM)?" "n"; then
    ENABLE_DAM=true
    echo "DAM will be enabled"
else
    echo "DAM will be disabled"
fi

echo "Authenticating to the source account ECR..."
aws ecr get-login-password --region "$SOURCE_REGION" | docker login --username AWS --password-stdin "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com"

echo "Authenticating to the target account ECR..."
aws ecr get-login-password --region "$TARGET_REGION" | docker login --username AWS --password-stdin "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com"

REPOSITORIES=("cloudanix/ecr-aws-jit-proxy-sql" "cloudanix/ecr-aws-jit-query-logging" "cloudanix/ecr-aws-jit-proxy-server")

if [ "$ENABLE_DAM" = true ]; then
    REPOSITORIES+=("cloudanix/ecr-aws-jit-dam-server" "cloudanix/ecr-aws-jit-postgresql")
fi

for REPO in "${REPOSITORIES[@]}"; do
    echo "Processing repository: $REPO"

    aws ecr describe-repositories --region "$TARGET_REGION" --repository-names "$REPO" >/dev/null 2>&1 \
        || aws ecr create-repository --region "$TARGET_REGION" --repository-name "$REPO"

    echo "Pulling image from source account with tag: $IMAGE_TAG..."
    docker pull --platform "$PLATFORM" "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$REPO:$IMAGE_TAG"

    echo "Tagging image for target account..."
    docker tag "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$REPO:$IMAGE_TAG" \
        "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:$IMAGE_TAG"

    docker tag "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$REPO:$IMAGE_TAG" \
        "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:latest"

    echo "Pushing image tag $IMAGE_TAG..."
    docker push "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:$IMAGE_TAG"

    echo "Pushing image tag latest..."
    docker push "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:latest"

    cleanup_old_images "$REPO" "$TARGET_REGION" "$IMAGE_TAG"
done

echo "Image transfer complete for all repositories."
echo ""

ENABLE_UPDATE_SERVICES=false
if prompt_yes_no "Are you updating images in Cluster" "n"; then
    ENABLE_UPDATE_SERVICES=true
    echo "ECS will be updated with image tag: $IMAGE_TAG"
else
    echo "ECS will not be updated"
fi

if [ "$ENABLE_UPDATE_SERVICES" = true ]; then
    ECS_SERVICES=("proxysql" "query-logging" "proxyserver")

    if [ "$ENABLE_DAM" = true ]; then
        ECS_SERVICES+=("dam-server" "postgresql")
    fi

    # Function to get ECR repo name from service name
    get_repo_for_service() {
        case "$1" in
            proxysql)       echo "cloudanix/ecr-aws-jit-proxy-sql" ;;
            query-logging)  echo "cloudanix/ecr-aws-jit-query-logging" ;;
            proxyserver)    echo "cloudanix/ecr-aws-jit-proxy-server" ;;
            dam-server)     echo "cloudanix/ecr-aws-jit-dam-server" ;;
            postgresql)     echo "cloudanix/ecr-aws-jit-postgresql" ;;
        esac
    }

    for ECS_SERVICE in "${ECS_SERVICES[@]}"; do
        echo ""
        echo "━━━ Processing: $ECS_SERVICE ━━━"

        REPO=$(get_repo_for_service "$ECS_SERVICE")
        NEW_IMAGE="${TARGET_ACCOUNT_ID}.dkr.ecr.${TARGET_REGION}.amazonaws.com/${REPO}:${IMAGE_TAG}"

        for CLUSTER in "jit-db-cluster" "cdx-jit-db-cluster" "cdx-jit-db-cluster-2" "cdx-jit-db-cluster-3" "cdx-jit-db-cluster-4"; do
            # Check if cluster exists and is active
            if ! aws ecs describe-clusters --clusters "$CLUSTER" --region "$TARGET_REGION" \
                --query "clusters[?status=='ACTIVE'] | length(@)" --output text 2>/dev/null | grep -q "1"; then
                continue
            fi

            # Check if service exists in this cluster
            if ! aws ecs describe-services --cluster "$CLUSTER" --services "$ECS_SERVICE" \
                --region "$TARGET_REGION" \
                --query "services[?status!='INACTIVE'] | length(@)" --output text 2>/dev/null | grep -q "1"; then
                continue
            fi

            echo "  Found $ECS_SERVICE in cluster $CLUSTER"

            # Get current task definition ARN from the service
            CURRENT_TD_ARN=$(aws ecs describe-services --cluster "$CLUSTER" --services "$ECS_SERVICE" \
                --region "$TARGET_REGION" \
                --query "services[0].taskDefinition" --output text 2>/dev/null)

            if [[ -z "$CURRENT_TD_ARN" || "$CURRENT_TD_ARN" == "None" ]]; then
                echo "  WARNING: Could not get current task definition. Using force deployment."
                aws ecs update-service --cluster "$CLUSTER" --service "$ECS_SERVICE" \
                    --force-new-deployment --region "$TARGET_REGION" --output text > /dev/null
                continue
            fi

            # Get current task definition and update the image
            CURRENT_TD_JSON=$(aws ecs describe-task-definition --task-definition "$CURRENT_TD_ARN" \
                --region "$TARGET_REGION" --output json 2>/dev/null)

            # Update the container image — match by repo pattern in existing image
            # This handles varying container names across clusters
            REPO_PATTERN=$(get_repo_for_service "$ECS_SERVICE" | sed 's/cloudanix\///')
            NEW_TD_INPUT=$(echo "$CURRENT_TD_JSON" | jq --arg img "$NEW_IMAGE" --arg pattern "$REPO_PATTERN" \
                '.taskDefinition | {
                    family: .family,
                    containerDefinitions: (.containerDefinitions | map(if (.image | contains($pattern)) then .image = $img else . end)),
                    taskRoleArn: .taskRoleArn,
                    executionRoleArn: .executionRoleArn,
                    networkMode: .networkMode,
                    volumes: .volumes,
                    requiresCompatibilities: .requiresCompatibilities,
                    cpu: .cpu,
                    memory: .memory
                } | with_entries(select(.value != null))')

            # Register new task definition revision
            TD_INPUT_FILE="/tmp/td-input-${ECS_SERVICE}.json"
            echo "$NEW_TD_INPUT" > "$TD_INPUT_FILE"

            NEW_TD_ARN=$(aws ecs register-task-definition \
                --cli-input-json "file://${TD_INPUT_FILE}" \
                --region "$TARGET_REGION" \
                --query "taskDefinition.taskDefinitionArn" --output text 2>/tmp/td-error-${ECS_SERVICE}.log)

            if [[ -z "$NEW_TD_ARN" || "$NEW_TD_ARN" == "None" ]]; then
                echo "  WARNING: Failed to register new task definition. Using force deployment."
                echo "  Error: $(cat /tmp/td-error-${ECS_SERVICE}.log)"
                aws ecs update-service --cluster "$CLUSTER" --service "$ECS_SERVICE" \
                    --force-new-deployment --region "$TARGET_REGION" --output text > /dev/null
            else
                echo "  New task definition: $NEW_TD_ARN"
                aws ecs update-service --cluster "$CLUSTER" --service "$ECS_SERVICE" \
                    --task-definition "$NEW_TD_ARN" \
                    --region "$TARGET_REGION" --output text > /dev/null
                echo "  ✓ Updated $CLUSTER/$ECS_SERVICE → $IMAGE_TAG"
            fi
        done

        sleep 10
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Services updated with image tag: $IMAGE_TAG"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi
