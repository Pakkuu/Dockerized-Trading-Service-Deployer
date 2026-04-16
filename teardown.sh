#!/usr/bin/env bash
# =============================================================================
#  teardown.sh — Stop the ECS service, deregister task defs, delete ECR images
# =============================================================================
#
#  ⚠️  WARNING: This script is DESTRUCTIVE.
#     It will stop the running service, delete all ECR image tags, and
#     deregister every revision of the task definition family.
#     Run only when you intentionally want to tear down the deployment.
#
#  Usage:
#    chmod +x teardown.sh
#    ./teardown.sh
#
#    # To skip the confirmation prompt (CI pipelines):
#    SKIP_CONFIRM=true ./teardown.sh
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 1 — AWS Configuration  (must match deploy.sh)
# ─────────────────────────────────────────────────────────────────────────────

# TODO: Set your target AWS region
AWS_REGION="us-east-1"

# TODO: Replace with your 12-digit AWS account ID
AWS_ACCOUNT_ID="123456789012"

# TODO: ECR repository name (must match deploy.sh)
ECR_REPO_NAME="mock-trading-app"

# TODO: ECS cluster name (must match deploy.sh)
ECS_CLUSTER_NAME="trading-cluster"

# TODO: ECS service name (must match deploy.sh)
ECS_SERVICE_NAME="mock-trading-service"

# TODO: ECS task definition family (must match deploy.sh)
TASK_DEF_FAMILY="mock-trading-task"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 2 — Teardown options
# ─────────────────────────────────────────────────────────────────────────────

# Set to "true" to also delete the ECR repository itself (not just its images)
DELETE_ECR_REPO="${DELETE_ECR_REPO:-false}"

# Set to "true" to also delete the CloudWatch log group
DELETE_LOG_GROUP="${DELETE_LOG_GROUP:-false}"

LOG_GROUP_NAME="/ecs/${TASK_DEF_FAMILY}"

# Skip interactive confirmation when running in CI
SKIP_CONFIRM="${SKIP_CONFIRM:-false}"

# ─────────────────────────────────────────────────────────────────────────────
#  Helper functions
# ─────────────────────────────────────────────────────────────────────────────

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
warn() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ⚠️  $*" >&2; }
die()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' not found. Please install it."
}

# ─────────────────────────────────────────────────────────────────────────────
#  Step 0 — Pre-flight checks & confirmation prompt
# ─────────────────────────────────────────────────────────────────────────────

log "=== Pre-flight checks ==="
require_cmd aws
require_cmd jq

aws sts get-caller-identity --region "${AWS_REGION}" > /dev/null || \
    die "AWS credentials not configured or invalid."

if [[ "${SKIP_CONFIRM}" != "true" ]]; then
    echo ""
    warn "You are about to DESTROY the following resources:"
    echo "   • ECS Service  : ${ECS_SERVICE_NAME}  (cluster: ${ECS_CLUSTER_NAME})"
    echo "   • Task Def     : all revisions of family '${TASK_DEF_FAMILY}'"
    echo "   • ECR images   : all tags in '${ECR_REPO_NAME}'"
    [[ "${DELETE_ECR_REPO}"   == "true" ]] && echo "   • ECR Repo     : ${ECR_REPO_NAME}  (will be DELETED)"
    [[ "${DELETE_LOG_GROUP}"  == "true" ]] && echo "   • Log Group    : ${LOG_GROUP_NAME}  (will be DELETED)"
    echo ""
    read -r -p "Type 'yes' to confirm: " CONFIRM
    [[ "${CONFIRM}" == "yes" ]] || { log "Teardown aborted."; exit 0; }
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Step 1 — Scale down and delete ECS service
# ─────────────────────────────────────────────────────────────────────────────

log "=== Step 1: Tearing down ECS service ==="

SERVICE_STATUS=$(aws ecs describe-services \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${ECS_SERVICE_NAME}" \
    --region "${AWS_REGION}" \
    --query "services[0].status" \
    --output text 2>/dev/null || echo "NONE")

if [[ "${SERVICE_STATUS}" == "ACTIVE" ]]; then
    log "Scaling service to 0 desired tasks..."
    aws ecs update-service \
        --cluster "${ECS_CLUSTER_NAME}" \
        --service "${ECS_SERVICE_NAME}" \
        --desired-count 0 \
        --region "${AWS_REGION}" > /dev/null

    log "Waiting for running tasks to stop (up to 5 min)..."
    aws ecs wait services-stable \
        --cluster "${ECS_CLUSTER_NAME}" \
        --services "${ECS_SERVICE_NAME}" \
        --region "${AWS_REGION}" || warn "Wait timed out — tasks may still be draining."

    log "Deleting ECS service..."
    aws ecs delete-service \
        --cluster "${ECS_CLUSTER_NAME}" \
        --service "${ECS_SERVICE_NAME}" \
        --force \
        --region "${AWS_REGION}" > /dev/null

    log "ECS service deleted: ${ECS_SERVICE_NAME}"
elif [[ "${SERVICE_STATUS}" == "NONE" || "${SERVICE_STATUS}" == "INACTIVE" ]]; then
    warn "Service '${ECS_SERVICE_NAME}' not found or already inactive — skipping."
else
    warn "Unexpected service status '${SERVICE_STATUS}' — attempting delete anyway."
    aws ecs delete-service \
        --cluster "${ECS_CLUSTER_NAME}" \
        --service "${ECS_SERVICE_NAME}" \
        --force \
        --region "${AWS_REGION}" > /dev/null || warn "Delete failed — may already be gone."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Step 2 — Deregister all task definition revisions
# ─────────────────────────────────────────────────────────────────────────────

log "=== Step 2: Deregistering task definition revisions ==="

TASK_DEF_ARNS=$(aws ecs list-task-definitions \
    --family-prefix "${TASK_DEF_FAMILY}" \
    --region "${AWS_REGION}" \
    --query "taskDefinitionArns[]" \
    --output text 2>/dev/null || true)

if [[ -z "${TASK_DEF_ARNS}" ]]; then
    warn "No task definition revisions found for family '${TASK_DEF_FAMILY}' — skipping."
else
    for ARN in ${TASK_DEF_ARNS}; do
        log "  Deregistering: ${ARN}"
        aws ecs deregister-task-definition \
            --task-definition "${ARN}" \
            --region "${AWS_REGION}" > /dev/null
    done
    log "All task definition revisions deregistered."

    # Delete (permanently remove) deregistered task definitions
    # Note: aws ecs delete-task-definitions requires CLI v2.13+
    if aws ecs delete-task-definitions help &>/dev/null; then
        log "Permanently deleting deregistered task definitions..."
        for ARN in ${TASK_DEF_ARNS}; do
            aws ecs delete-task-definitions \
                --task-definitions "${ARN}" \
                --region "${AWS_REGION}" > /dev/null 2>&1 || \
                warn "Could not permanently delete ${ARN} (may need AWS CLI ≥2.13)"
        done
    else
        warn "AWS CLI version does not support delete-task-definitions — revisions deregistered only."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Step 3 — Delete ECR images (all tags in the repository)
# ─────────────────────────────────────────────────────────────────────────────

log "=== Step 3: Deleting ECR images ==="

REPO_EXISTS=$(aws ecr describe-repositories \
    --repository-names "${ECR_REPO_NAME}" \
    --region "${AWS_REGION}" \
    --query "length(repositories)" \
    --output text 2>/dev/null || echo "0")

if [[ "${REPO_EXISTS}" -gt 0 ]]; then
    # Collect all image digests in the repository
    IMAGE_IDS=$(aws ecr list-images \
        --repository-name "${ECR_REPO_NAME}" \
        --region "${AWS_REGION}" \
        --query "imageIds[*]" \
        --output json 2>/dev/null)

    IMAGE_COUNT=$(echo "${IMAGE_IDS}" | jq 'length')

    if [[ "${IMAGE_COUNT}" -gt 0 ]]; then
        log "Deleting ${IMAGE_COUNT} image(s) from ${ECR_REPO_NAME}..."
        aws ecr batch-delete-image \
            --repository-name "${ECR_REPO_NAME}" \
            --image-ids "${IMAGE_IDS}" \
            --region "${AWS_REGION}" > /dev/null
        log "ECR images deleted."
    else
        warn "No images found in '${ECR_REPO_NAME}' — skipping image deletion."
    fi

    if [[ "${DELETE_ECR_REPO}" == "true" ]]; then
        log "Deleting ECR repository: ${ECR_REPO_NAME}"
        aws ecr delete-repository \
            --repository-name "${ECR_REPO_NAME}" \
            --force \
            --region "${AWS_REGION}" > /dev/null
        log "ECR repository deleted."
    fi
else
    warn "ECR repository '${ECR_REPO_NAME}' not found — skipping."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Step 4 — (Optional) Delete CloudWatch log group
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${DELETE_LOG_GROUP}" == "true" ]]; then
    log "=== Step 4: Deleting CloudWatch log group ==="
    aws logs delete-log-group \
        --log-group-name "${LOG_GROUP_NAME}" \
        --region "${AWS_REGION}" 2>/dev/null || \
        warn "Log group '${LOG_GROUP_NAME}' not found or already deleted."
    log "Log group deleted: ${LOG_GROUP_NAME}"
else
    log "=== Step 4: Skipping log group deletion (DELETE_LOG_GROUP=false) ==="
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Summary
# ─────────────────────────────────────────────────────────────────────────────

log "=== Teardown complete ==="
log "All tracked resources have been removed."
log "  ECS Cluster '${ECS_CLUSTER_NAME}' itself was NOT deleted (shared resource)."
[[ "${DELETE_ECR_REPO}"  != "true" ]] && log "  ECR repo '${ECR_REPO_NAME}' was NOT deleted (run with DELETE_ECR_REPO=true to remove)."
[[ "${DELETE_LOG_GROUP}" != "true" ]] && log "  Log group '${LOG_GROUP_NAME}' was NOT deleted (run with DELETE_LOG_GROUP=true to remove)."
