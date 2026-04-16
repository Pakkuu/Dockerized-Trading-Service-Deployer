# Dockerized Trading Service Deployer

A bash-based deployment pipeline for a Dockerized mock trading app running on **AWS ECS Fargate**, with **UV** for Python package management.

---

## Project Structure

```
.
├── Dockerfile              # Multi-stage build (UV + Python 3.12-slim)
├── deploy.sh               # Build → Push → Register task def → Launch service
├── teardown.sh             # Stop service → Deregister task defs → Delete images
├── app/
│   ├── trading_app.py      # Mock trading engine (prints simulated orders)
│   └── pyproject.toml      # UV project manifest
└── README.md
```

---

## Quick Start

### 1. Fill in your AWS config

Both `deploy.sh` and `teardown.sh` have a `SECTION 1` block at the top with `TODO` comments. Set at minimum:

| Variable | Description |
|---|---|
| `AWS_REGION` | e.g. `us-east-1` |
| `AWS_ACCOUNT_ID` | Your 12-digit account ID |
| `ECR_REPO_NAME` | e.g. `mock-trading-app` |
| `ECS_CLUSTER_NAME` | Must already exist |
| `TASK_EXECUTION_ROLE_ARN` | IAM role with `AmazonECSTaskExecutionRolePolicy` |
| `SUBNET_IDS` | Comma-separated subnet IDs for Fargate ENI |
| `SECURITY_GROUP_IDS` | Comma-separated security group IDs |

### 2. Deploy

```bash
chmod +x deploy.sh teardown.sh
./deploy.sh
```

### 3. Tear down

```bash
# Standard teardown (keeps ECR repo and log group)
./teardown.sh

# Full cleanup including ECR repo and CloudWatch log group
DELETE_ECR_REPO=true DELETE_LOG_GROUP=true ./teardown.sh

# Skip confirmation prompt (for CI)
SKIP_CONFIRM=true ./teardown.sh
```

---

## App Configuration

The mock trading app reads its configuration from environment variables, which are injected by the ECS task definition:

| Variable | Default | Description |
|---|---|---|
| `TRADING_SYMBOL` | `AAPL` | Ticker to simulate |
| `ORDER_INTERVAL` | `2` | Seconds between simulated orders |
| `LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARNING` |

---

## Resource Limits (Fargate)

Configured in `deploy.sh` Section 2:
- **CPU**: `256` units (0.25 vCPU)
- **Memory**: `512` MiB

Adjust `TASK_CPU` and `TASK_MEMORY` to scale up.

---

## Health Check

The container health check runs every **30 seconds** with a **10-second timeout**, 3 retries, and a 15-second start window:

```json
{
  "command": ["CMD-SHELL", "python -c 'import sys; sys.exit(0)' || exit 1"],
  "interval": 30,
  "timeout": 10,
  "retries": 3,
  "startPeriod": 15
}
```

---

## IAM Requirements

Your IAM user/role needs (at minimum):

```
ecr:GetAuthorizationToken
ecr:BatchCheckLayerAvailability
ecr:CompleteLayerUpload
ecr:InitiateLayerUpload
ecr:PutImage
ecr:UploadLayerPart
ecr:CreateRepository
ecr:ListImages
ecr:BatchDeleteImage
ecs:RegisterTaskDefinition
ecs:DeregisterTaskDefinition
ecs:ListTaskDefinitions
ecs:CreateService
ecs:UpdateService
ecs:DeleteService
ecs:DescribeServices
ecs:ListServices
iam:PassRole
logs:CreateLogGroup
logs:DescribeLogGroups
logs:DeleteLogGroup
```
