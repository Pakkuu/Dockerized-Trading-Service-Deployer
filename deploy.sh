#!/usr/bin/env bash
# =============================================================================
#  deploy.sh — Build, push, and launch the Risk Check Service on AWS ECS Fargate
# =============================================================================
#
#  Prerequisites:
#    - AWS CLI v2 installed and configured (aws configure)
#    - Docker daemon running
#    - IAM user/role with permissions:
#        ecr:GetAuthorizationToken, ecr:BatchCheckLayerAvailability,
#        ecr:CompleteLayerUpload, ecr:InitiateLayerUpload, ecr:PutImage,
#        ecr:UploadLayerPart, ecs:RegisterTaskDefinition,
#        ecs:CreateService, ecs:UpdateService, ecs:DescribeServices,
#        iam:PassRole, logs:CreateLogGroup
#
#  Usage:
#    chmod +x deploy.sh
#    ./deploy.sh
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 1 — AWS Configuration (loaded from aws.config)
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/aws.config" ]]; then
    echo "ERROR: aws.config file not found!"
    exit 1
fi

set -a
source "${SCRIPT_DIR}/aws.config"
set +a

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 2 — Resource limits & application configuration
# ─────────────────────────────────────────────────────────────────────────────

# Fargate CPU units  (256 = 0.25 vCPU | 512 = 0.5 vCPU | 1024 = 1 vCPU)
TASK_CPU="256"

# Fargate memory in MiB (must be compatible with chosen CPU; 512 is minimum)
TASK_MEMORY="512"

# Application environment variables injected into the container
ALLOWED_SYMBOLS="SPY,AAPL,MSFT"
MAX_ORDER_QTY="10000"
MAX_NOTIONAL="1000000"
PORT="8080"

# CloudWatch log group where container stdout/stderr will be streamed
LOG_GROUP_NAME="/ecs/${TASK_DEF_FAMILY}"

# Docker image tag (defaults to git short SHA for traceability)
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')}"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 3 — Derived values (no edits needed below unless customising)
# ─────────────────────────────────────────────────────────────────────────────

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_IMAGE_URI="${ECR_REGISTRY}/${ECR_REPO_NAME}:${IMAGE_TAG}"
ECR_IMAGE_LATEST="${ECR_REGISTRY}/${ECR_REPO_NAME}:latest"

# ─────────────────────────────────────────────────────────────────────────────
#  Helper functions
# ─────────────────────────────────────────────────────────────────────────────

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' not found. Please install it."
}

# ─────────────────────────────────────────────────────────────────────────────
#  Step 0 — Pre-flight checks
# ─────────────────────────────────────────────────────────────────────────────

log "=== Pre-flight checks ==="
require_cmd aws
require_cmd docker
require_cmd jq

aws sts get-caller-identity --region "${AWS_REGION}" > /dev/null || \
    die "AWS credentials not configured or invalid."

log "Deploying image tag: ${IMAGE_TAG}"

# ─────────────────────────────────────────────────────────────────────────────
#  Step 1 — Ensure ECR repository exists
# ─────────────────────────────────────────────────────────────────────────────

log "=== Step 1: Ensuring ECR repository exists ==="

aws ecr describe-repositories \
    --repository-names "${ECR_REPO_NAME}" \
    --region "${AWS_REGION}" > /dev/null 2>&1 || \
aws ecr create-repository \
    --repository-name "${ECR_REPO_NAME}" \
    --region "${AWS_REGION}" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 > /dev/null

log "ECR repository ready: ${ECR_REPO_NAME}"

# ─────────────────────────────────────────────────────────────────────────────
#  Step 2 — Build Docker image
# ─────────────────────────────────────────────────────────────────────────────

log "=== Step 2: Building Docker image ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker build \
    --tag "${ECR_IMAGE_URI}" \
    --tag "${ECR_IMAGE_LATEST}" \
    --file "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"

log "Image built: ${ECR_IMAGE_URI}"

# ─────────────────────────────────────────────────────────────────────────────
#  Step 3 — Authenticate to ECR and push image
# ─────────────────────────────────────────────────────────────────────────────

log "=== Step 3: Pushing image to ECR ==="

aws ecr get-login-password --region "${AWS_REGION}" | \
    docker login --username AWS --password-stdin "${ECR_REGISTRY}"

docker push "${ECR_IMAGE_URI}"
docker push "${ECR_IMAGE_LATEST}"

log "Image pushed: ${ECR_IMAGE_URI}"

# ─────────────────────────────────────────────────────────────────────────────
#  Step 4 — Ensure CloudWatch log group exists
# ─────────────────────────────────────────────────────────────────────────────

log "=== Step 4: Ensuring CloudWatch log group exists ==="

aws logs describe-log-groups \
    --log-group-name-prefix "${LOG_GROUP_NAME}" \
    --region "${AWS_REGION}" | \
    jq -r '.logGroups[].logGroupName' | \
    grep -qx "${LOG_GROUP_NAME}" || \
aws logs create-log-group \
    --log-group-name "${LOG_GROUP_NAME}" \
    --region "${AWS_REGION}"

log "Log group ready: ${LOG_GROUP_NAME}"

# ─────────────────────────────────────────────────────────────────────────────
#  Step 5 — Register ECS task definition
# ─────────────────────────────────────────────────────────────────────────────

log "=== Step 5: Registering ECS task definition ==="

TASK_DEF_JSON=$(cat <<EOF
{
  "family": "${TASK_DEF_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "${TASK_CPU}",
  "memory": "${TASK_MEMORY}",
  "executionRoleArn": "${TASK_EXECUTION_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "risk-check-service",
      "image": "${ECR_IMAGE_URI}",
      "essential": true,
      "environment": [
        { "name": "ALLOWED_SYMBOLS", "value": "${ALLOWED_SYMBOLS}" },
        { "name": "MAX_ORDER_QTY",   "value": "${MAX_ORDER_QTY}" },
        { "name": "MAX_NOTIONAL",    "value": "${MAX_NOTIONAL}" },
        { "name": "PORT",            "value": "${PORT}" }
      ],
      "portMappings": [
        {
          "containerPort": 8080,
          "hostPort": 8080,
          "protocol": "tcp"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group":         "${LOG_GROUP_NAME}",
          "awslogs-region":        "${AWS_REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:8080/health || exit 1"
        ],
        "interval": 30,
        "timeout":  10,
        "retries":  3,
        "startPeriod": 15
      },
      "resourceRequirements": [],
      "stopTimeout": 30
    }
  ]
}
EOF
)

TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json "${TASK_DEF_JSON}" \
    --region "${AWS_REGION}" \
    --query "taskDefinition.taskDefinitionArn" \
    --output text)

log "Task definition registered: ${TASK_DEF_ARN}"

# ─────────────────────────────────────────────────────────────────────────────
#  Step 6 — Create or update ECS Fargate service
# ─────────────────────────────────────────────────────────────────────────────

log "=== Step 6: Creating / updating ECS Fargate service ==="

NETWORK_CONFIG="{
  \"awsvpcConfiguration\": {
    \"subnets\": [$(echo "${SUBNET_IDS}" | sed 's/,/\",\"/g; s/^/\"/; s/$/\"/')],
    \"securityGroups\": [$(echo "${SECURITY_GROUP_IDS}" | sed 's/,/\",\"/g; s/^/\"/; s/$/\"/')],
    \"assignPublicIp\": \"ENABLED\"
  }
}"

SERVICE_EXISTS=$(aws ecs describe-services \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${ECS_SERVICE_NAME}" \
    --region "${AWS_REGION}" \
    --query "length(services[?status!='INACTIVE'])" \
    --output text 2>/dev/null || echo "0")

if [[ "${SERVICE_EXISTS}" -gt 0 ]]; then
    log "Updating existing service..."
    aws ecs update-service \
        --cluster "${ECS_CLUSTER_NAME}" \
        --service "${ECS_SERVICE_NAME}" \
        --task-definition "${TASK_DEF_ARN}" \
        --force-new-deployment \
        --region "${AWS_REGION}" > /dev/null
else
    log "Creating new service..."
    aws ecs create-service \
        --cluster "${ECS_CLUSTER_NAME}" \
        --service-name "${ECS_SERVICE_NAME}" \
        --task-definition "${TASK_DEF_ARN}" \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "${NETWORK_CONFIG}" \
        --scheduling-strategy REPLICA \
        --region "${AWS_REGION}" > /dev/null
fi

log "=== Deployment complete ==="
log "Cluster : ${ECS_CLUSTER_NAME}"
log "Service : ${ECS_SERVICE_NAME}"
log "Task Def: ${TASK_DEF_ARN}"
log "Image   : ${ECR_IMAGE_URI}"
log "Logs    : https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#logsV2:log-groups/log-group/${LOG_GROUP_NAME//\//\$252F}"
