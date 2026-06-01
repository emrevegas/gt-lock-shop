"""HTTP API for Lucifer (Luci) withdraw script."""

import logging
import time
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from pydantic import BaseModel

import config
from database import db
from modules import orders

log = logging.getLogger("gt-lock-shop")

# Luci poll sayacı (çok gürültü olmasın diye null istekleri seyrek logla)
_last_null_poll_log: float = 0.0


@asynccontextmanager
async def lifespan(app: FastAPI):
    if db.get_conn_or_none() is None:
        await db.init_db()
    released = await orders.release_all_processing()
    if released:
        log.info("API startup: re-queued %s processing order(s)", released)
    await orders.reset_stale_processing()
    counts = await orders.count_orders_by_status()
    log.info("API ready on %s:%s | orders=%s", config.API_HOST, config.API_PORT, counts)
    yield


app = FastAPI(title="GT Lock Shop Luci Bridge", version="1.0.0", lifespan=lifespan)


@app.middleware("http")
async def log_api_requests(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    ms = (time.perf_counter() - start) * 1000
    # Luci her 2-3 sn poll eder; sadece önemli path'leri INFO'da tut
    path = request.url.path
    if path.startswith("/api/"):
        log.info(
            "API %s %s → %s (%.0fms)",
            request.method,
            path,
            response.status_code,
            ms,
        )
    return response


def verify_key(x_api_key: Optional[str] = Header(None)) -> None:
    if not config.LUCI_API_KEY:
        raise HTTPException(503, "LUCI_API_KEY not configured")
    if x_api_key != config.LUCI_API_KEY:
        log.warning("API rejected: bad or missing X-Api-Key from %s", x_api_key)
        raise HTTPException(401, "Invalid API key")


class CompleteBody(BaseModel):
    order_id: int


class FailBody(BaseModel):
    order_id: int
    reason: str = "unknown"


@app.get("/health")
async def health():
    return {"ok": True, "db": str(config.DB_PATH.resolve())}


@app.get("/api/orders/next", dependencies=[Depends(verify_key)])
async def next_order():
    global _last_null_poll_log
    counts = await orders.count_orders_by_status()
    order = await orders.claim_next_pending()
    if not order:
        now = time.time()
        if counts.get("pending") or counts.get("processing"):
            log.warning("API /next: claim failed but counts=%s", counts)
        elif now - _last_null_poll_log > 60:
            _last_null_poll_log = now
            log.info("API /next: no pending orders (Luci polling OK) counts=%s", counts)
        return {"order": None, "counts": counts}
    log.info(
        "API claimed order #%s → %s growid=%s (%sx%s)",
        order["id"],
        order["world_name"],
        order["growid"],
        order["quantity"],
        order["item_type"],
    )
    return {"order": order, "counts": counts}


@app.get("/api/orders/stats", dependencies=[Depends(verify_key)])
async def order_stats():
    return {"counts": await orders.count_orders_by_status()}


@app.get("/api/orders/pending", dependencies=[Depends(verify_key)])
async def pending_orders():
    """Siparişleri claim etmeden listele (debug)."""
    return {
        "orders": await orders.list_active_orders(limit=50),
        "counts": await orders.count_orders_by_status(),
    }


@app.post("/api/orders/requeue-stuck", dependencies=[Depends(verify_key)])
async def requeue_stuck():
    n = await orders.release_all_processing()
    log.info("API requeue-stuck: %s order(s)", n)
    return {"requeued": n}


@app.post("/api/orders/cancel-all", dependencies=[Depends(verify_key)])
async def cancel_all_orders():
    result = await orders.cancel_all_active_orders()
    log.info("API cancel-all: %s", result)
    return result


@app.post("/api/orders/complete", dependencies=[Depends(verify_key)])
async def complete_order(body: CompleteBody):
    order = await orders.complete_order(body.order_id)
    if not order:
        raise HTTPException(404, "Order not found")
    log.info("API complete order #%s", body.order_id)
    return {"order": order}


@app.post("/api/orders/fail", dependencies=[Depends(verify_key)])
async def fail_order(body: FailBody):
    order = await orders.fail_order(body.order_id, body.reason)
    if not order:
        raise HTTPException(404, "Order not found")
    log.info("API fail order #%s: %s", body.order_id, body.reason)
    return {"order": order}


@app.get("/api/config", dependencies=[Depends(verify_key)])
async def luci_config():
    worlds = await orders.get_withdraw_worlds()
    return {"withdraw_worlds": worlds}


if __name__ == "__main__":
    import sys

    print(
        "UYARI: Sadece API çalışıyor — siparişler Discord bot (bot.py) ile aynı process'te olmalı.\n"
        "Kullan: python bot.py",
        file=sys.stderr,
    )
    import uvicorn

    uvicorn.run(
        "api_server:app",
        host=config.API_HOST,
        port=config.API_PORT,
        reload=False,
        log_config=None,
    )
