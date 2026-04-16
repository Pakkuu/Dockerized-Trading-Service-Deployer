"""
Mock Trading App
================
Simulates a live trading engine that generates and prints order activity
in a continuous loop. Designed to run inside a Docker container on
AWS ECS Fargate.

Environment Variables (injected by ECS task definition):
  TRADING_SYMBOL   - The ticker symbol to simulate (default: AAPL)
  ORDER_INTERVAL   - Seconds between orders (default: 2)
  LOG_LEVEL        - Logging verbosity: DEBUG | INFO | WARNING (default: INFO)
"""

import logging
import os
import random
import time
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Configuration from environment (populated via ECS task definition)
# ---------------------------------------------------------------------------
TRADING_SYMBOL: str = os.environ.get("TRADING_SYMBOL", "AAPL")
ORDER_INTERVAL: float = float(os.environ.get("ORDER_INTERVAL", "2"))
LOG_LEVEL: str = os.environ.get("LOG_LEVEL", "INFO").upper()

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger("trading-app")

# ---------------------------------------------------------------------------
# Simulation parameters
# ---------------------------------------------------------------------------
ORDER_TYPES = ["MARKET", "LIMIT", "STOP", "STOP_LIMIT"]
SIDES = ["BUY", "SELL"]
STATUSES = ["FILLED", "PARTIAL_FILL", "REJECTED", "PENDING", "CANCELLED"]
STATUS_WEIGHTS = [0.55, 0.20, 0.05, 0.15, 0.05]

BASE_PRICE = 182.50  # Approximate realistic base for demonstration
PRICE_VOLATILITY = 0.5  # ± per tick


def generate_order_id(sequence: int) -> str:
    """Return a zero-padded order identifier."""
    return f"ORD-{sequence:08d}"


def simulate_price(base: float, volatility: float) -> float:
    """Walk the price using a tiny random step."""
    return round(base + random.uniform(-volatility, volatility), 2)


def simulate_fill_price(order_price: float) -> float:
    """Introduce a small slippage around the order price."""
    slippage = random.uniform(-0.05, 0.05)
    return round(order_price + slippage, 2)


def emit_order_event(sequence: int, current_price: float) -> float:
    """
    Generate one simulated order event, log it, and return the updated price.
    """
    order_id = generate_order_id(sequence)
    order_type = random.choice(ORDER_TYPES)
    side = random.choice(SIDES)
    quantity = random.randint(1, 500)
    status = random.choices(STATUSES, weights=STATUS_WEIGHTS, k=1)[0]
    order_price = simulate_price(current_price, PRICE_VOLATILITY)
    fill_price = simulate_fill_price(order_price) if status in ("FILLED", "PARTIAL_FILL") else None
    filled_qty = random.randint(1, quantity) if status == "PARTIAL_FILL" else (quantity if status == "FILLED" else 0)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

    log_payload = (
        f"order_id={order_id} "
        f"symbol={TRADING_SYMBOL} "
        f"type={order_type} "
        f"side={side} "
        f"qty={quantity} "
        f"price={order_price:.2f} "
        f"status={status}"
    )

    if fill_price is not None:
        log_payload += f" fill_px={fill_price:.2f} filled_qty={filled_qty}"

    log_payload += f" ts={ts}"

    if status == "REJECTED":
        log.warning(log_payload)
    elif status in ("FILLED", "PARTIAL_FILL"):
        log.info(log_payload)
    else:
        log.debug(log_payload)

    # Drift the base price slightly toward the last fill to keep it realistic
    return fill_price if fill_price else current_price


def health_check_ping() -> None:
    """Emit a periodic heartbeat so ECS health checks can detect liveness."""
    log.info("HEARTBEAT status=alive symbol=%s", TRADING_SYMBOL)


def main() -> None:
    log.info(
        "Mock trading engine starting — symbol=%s interval=%ss log_level=%s",
        TRADING_SYMBOL,
        ORDER_INTERVAL,
        LOG_LEVEL,
    )

    sequence = 1
    current_price = BASE_PRICE
    heartbeat_counter = 0
    HEARTBEAT_EVERY = 10  # emit heartbeat every N orders

    while True:
        current_price = emit_order_event(sequence, current_price)
        sequence += 1
        heartbeat_counter += 1

        if heartbeat_counter >= HEARTBEAT_EVERY:
            health_check_ping()
            heartbeat_counter = 0

        time.sleep(ORDER_INTERVAL)


if __name__ == "__main__":
    main()
