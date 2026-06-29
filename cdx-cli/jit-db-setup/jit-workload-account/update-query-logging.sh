#!/bin/bash
set -e
set -u

# ============================================================================
# Update query-logging service: pull image, push to ECR, force redeploy
# ============================================================================

SOURCE_ACCOUNT_ID="774118602354"
SOURCE_REGION="us-east-2"
IMAGE_TAG="v0.3.24"
REPO="cloudanix/ecr-aws-jit-query-logging"
PLATFORM="linux/amd64"

TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Target Account: $TARGET_ACCOUNT_ID"

read -p "Target AWS Region [ap-south-1]: " TARGET_REGION
TARGET_REGION=${TARGET_REGION:-ap-south-1}

read -p "ECS Cluster Name [cdx-jit-db-cluster]: " CLUSTER
CLUSTER=${CLUSTER:-cdx-jit-db-cluster}

ECR_PREFIX="${TARGET_ACCOUNT_ID}.dkr.ecr.${TARGET_REGION}.amazonaws.com"

# Step 1: Auth to both ECRs
echo "[1/4] Authenticating to ECRs..."
aws ecr get-login-password --region "$SOURCE_REGION" | \
  docker login --username AWS --password-stdin "${SOURCE_ACCOUNT_ID}.dkr.ecr.${SOURCE_REGION}.amazonaws.com"
aws ecr get-login-password --region "$TARGET_REGION" | \
  docker login --username AWS --password-stdin "$ECR_PREFIX"

# Step 2: Pull from source
echo "[2/4] Pulling ${REPO}:${IMAGE_TAG}..."
docker pull --platform "$PLATFORM" \
  "${SOURCE_ACCOUNT_ID}.dkr.ecr.${SOURCE_REGION}.amazonaws.com/${REPO}:${IMAGE_TAG}"

# Step 3: Tag and push to target
echo "[3/4] Pushing to target ECR..."
docker tag \
  "${SOURCE_ACCOUNT_ID}.dkr.ecr.${SOURCE_REGION}.amazonaws.com/${REPO}:${IMAGE_TAG}" \
  "${ECR_PREFIX}/${REPO}:${IMAGE_TAG}"
docker tag \
  "${SOURCE_ACCOUNT_ID}.dkr.ecr.${SOURCE_REGION}.amazonaws.com/${REPO}:${IMAGE_TAG}" \
  "${ECR_PREFIX}/${REPO}:latest"
docker push "${ECR_PREFIX}/${REPO}:${IMAGE_TAG}"
docker push "${ECR_PREFIX}/${REPO}:latest"

# Step 4: Force update ECS service
echo "[4/4] Force updating query-logging service..."
aws ecs update-service --cluster "$CLUSTER" --service query-logging \
  --force-new-deployment --region "$TARGET_REGION" --output text > /dev/null

echo ""
echo "Done! query-logging service is redeploying with image ${IMAGE_TAG}."
echo "Check status: aws ecs describe-services --cluster $CLUSTER --services query-logging --region $TARGET_REGION --query 'services[0].deployments[].{status:status,running:runningCount,desired:desiredCount}'"
