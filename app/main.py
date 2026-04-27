import os
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="Risk Check Service")

# ---------------------------------------------------------------------------
# Configuration from environment
# ---------------------------------------------------------------------------
ALLOWED_SYMBOLS_STR = os.environ.get("ALLOWED_SYMBOLS", "SPY,AAPL,MSFT")
ALLOWED_SYMBOLS = set(sym.strip().upper() for sym in ALLOWED_SYMBOLS_STR.split(",") if sym.strip())
MAX_ORDER_QTY = int(os.environ.get("MAX_ORDER_QTY", "10000"))
MAX_NOTIONAL = float(os.environ.get("MAX_NOTIONAL", "1000000"))

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------
class OrderRequest(BaseModel):
    symbol: str
    side: str
    qty: int
    price: float

class CheckResponse(BaseModel):
    approved: bool
    reason: str

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health")
def health_check():
    return {"status": "ok"}

@app.get("/limits")
def get_limits():
    return {
        "ALLOWED_SYMBOLS": list(ALLOWED_SYMBOLS),
        "MAX_ORDER_QTY": MAX_ORDER_QTY,
        "MAX_NOTIONAL": MAX_NOTIONAL
    }

@app.post("/check", response_model=CheckResponse)
def check_order(order: OrderRequest):
    # 1. Price > 0, qty > 0
    if order.price <= 0:
        return CheckResponse(approved=False, reason="Price must be greater than 0")
    if order.qty <= 0:
        return CheckResponse(approved=False, reason="Quantity must be greater than 0")

    # 2. Side is "BUY" or "SELL"
    if order.side.upper() not in {"BUY", "SELL"}:
        return CheckResponse(approved=False, reason='Side must be "BUY" or "SELL"')

    # 3. Symbol in whitelist
    if order.symbol.upper() not in ALLOWED_SYMBOLS:
        return CheckResponse(approved=False, reason=f"Symbol {order.symbol} not in whitelist")

    # 4. Qty ≤ MAX_ORDER_QTY
    if order.qty > MAX_ORDER_QTY:
        return CheckResponse(approved=False, reason=f"Quantity {order.qty} exceeds max {MAX_ORDER_QTY}")

    # 5. Notional (qty × price) ≤ MAX_NOTIONAL
    notional = order.qty * order.price
    if notional > MAX_NOTIONAL:
        return CheckResponse(approved=False, reason=f"Notional {notional} exceeds max {MAX_NOTIONAL}")

    return CheckResponse(approved=True, reason="OK")
