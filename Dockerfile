# ============================================================
#  Mock Trading App — Dockerfile
#  Base image : python:3.12-slim
#  Package mgr: UV (https://github.com/astral-sh/uv)
#  Entrypoint : app/trading_app.py
# ============================================================

# ── Stage 1: dependency resolver ────────────────────────────
FROM python:3.12-slim AS builder

# Install UV from the official installer (no pip needed)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /build

# Copy pyproject and lock file first to leverage layer caching.
# If neither changes, UV will reuse the cached virtual environment.
COPY app/pyproject.toml ./
# Uncomment the next line once you have generated a lock file:
# COPY app/uv.lock ./

# Create a virtual environment and install dependencies.
# --no-cache keeps the image lean; --frozen requires an existing lock file.
RUN uv venv .venv && \
    UV_PYTHON_PREFERENCE=only-system \
    uv pip install --no-cache -r <(uv pip compile pyproject.toml 2>/dev/null || echo "") || true

# ── Stage 2: runtime image ──────────────────────────────────
FROM python:3.12-slim AS runtime

RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

LABEL maintainer="your-email@example.com"          # TODO: replace with real contact
LABEL org.opencontainers.image.title="mock-trading-app"
LABEL org.opencontainers.image.version="0.1.0"

# Install UV in the runtime image so it can be used as the process runner
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Non-root user for ECS security best-practice
RUN groupadd --gid 1001 trader && \
    useradd  --uid 1001 --gid trader --shell /bin/bash --create-home trader

WORKDIR /app

# Copy the virtual environment built in the builder stage
COPY --from=builder /build/.venv /app/.venv

# Copy application source
COPY app/ /app/

# Make sure the venv Python is preferred at runtime
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Runtime environment variables — overridden by ECS task definition
ENV ALLOWED_SYMBOLS="SPY,AAPL,MSFT" \
    MAX_ORDER_QTY="10000" \
    MAX_NOTIONAL="1000000" \
    PORT="8080"

USER trader

# ECS health-check: verify the FastAPI app is alive
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
