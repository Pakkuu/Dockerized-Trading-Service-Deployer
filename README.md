# Dockerized Risk Check Service Deployer

A bash-based deployment pipeline for a Dockerized **FastAPI Risk Check Service** running on **AWS ECS Fargate**, with **UV** for Python package management.

---

## Project Structure

```
.
├── Dockerfile              # Multi-stage build (UV + Python 3.12-slim)
├── deploy.sh               # Build → Push → Register task def → Launch service
├── teardown.sh             # Stop service → Deregister task defs → Delete images
├── app/
│   ├── main.py             # FastAPI Risk Check Service logic
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
| `ECR_REPO_NAME` | e.g. `risk-check-service` |
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

The risk check service reads its configuration from environment variables, which are injected by the ECS task definition:

| Variable | Default | Description |
|---|---|---|
| `ALLOWED_SYMBOLS` | `SPY,AAPL,MSFT` | Comma-separated list of allowed tickers |
| `MAX_ORDER_QTY` | `10000` | Maximum quantity allowed per order |
| `MAX_NOTIONAL` | `1000000` | Maximum notional value (qty × price) allowed |
| `PORT` | `8080` | The port for the FastAPI server |

---

## Endpoints

- `POST /check`: Evaluates an order (`symbol`, `side`, `qty`, `price`) against the configured limits and returns `{ "approved": true|false, "reason": "..." }`.
- `GET /health`: Returns `{ "status": "ok" }`.
- `GET /limits`: Returns the current environment configuration limits.

---

## Resource Limits (Fargate)

Configured in `deploy.sh` Section 2:
- **CPU**: `256` units (0.25 vCPU)
- **Memory**: `512` MiB

Adjust `TASK_CPU` and `TASK_MEMORY` to scale up.

---

## Health Check

The container health check pings the `/health` endpoint using cURL every **30 seconds** with a **10-second timeout**, 3 retries, and a 15-second start window:

```json
{
  "command": ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"],
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
