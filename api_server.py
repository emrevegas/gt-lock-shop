"""HTTP API for Lucifer (Luci) withdraw script."""

from contextlib import asynccontextmanager
from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

import config
from database import db
from modules import orders


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.init_db()
    released = await orders.release_all_processing()
    if released:
        print(f"[API] Re-queued {released} stuck processing order(s)")
    await orders.reset_stale_processing()
    yield


app = FastAPI(title="GT Lock Shop Luci Bridge", version="1.0.0", lifespan=lifespan)


def verify_key(x_api_key: Optional[str] = Header(None)) -> None:
    if not config.LUCI_API_KEY:
        raise HTTPException(503, "LUCI_API_KEY not configured")
    if x_api_key != config.LUCI_API_KEY:
        raise HTTPException(401, "Invalid API key")


class CompleteBody(BaseModel):
    order_id: int


class FailBody(BaseModel):
    order_id: int
    reason: str = "unknown"


@app.get("/health")
async def health():
    return {"ok": True}


@app.get("/api/orders/next", dependencies=[Depends(verify_key)])
async def next_order():
    counts = await orders.count_orders_by_status()
    order = await orders.claim_next_pending()
    if not order:
        if counts.get("pending") or counts.get("processing"):
            print(f"[API] No claimable order (counts={counts})")
        return {"order": None, "counts": counts}
    print(f"[API] Claimed order #{order['id']} → world {order['world_name']} growid={order['growid']}")
    return {"order": order, "counts": counts}


@app.get("/api/orders/stats", dependencies=[Depends(verify_key)])
async def order_stats():
    return {"counts": await orders.count_orders_by_status()}


@app.post("/api/orders/requeue-stuck", dependencies=[Depends(verify_key)])
async def requeue_stuck():
    n = await orders.release_all_processing()
    return {"requeued": n}


@app.post("/api/orders/cancel-all", dependencies=[Depends(verify_key)])
async def cancel_all_orders():
    result = await orders.cancel_all_active_orders()
    return result


@app.post("/api/orders/complete", dependencies=[Depends(verify_key)])
async def complete_order(body: CompleteBody):
    order = await orders.complete_order(body.order_id)
    if not order:
        raise HTTPException(404, "Order not found")
    return {"order": order}


@app.post("/api/orders/fail", dependencies=[Depends(verify_key)])
async def fail_order(body: FailBody):
    order = await orders.fail_order(body.order_id, body.reason)
    if not order:
        raise HTTPException(404, "Order not found")
    return {"order": order}


@app.get("/api/config", dependencies=[Depends(verify_key)])
async def luci_config():
    worlds = await orders.get_withdraw_worlds()
    return {"withdraw_worlds": worlds}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "api_server:app",
        host=config.API_HOST,
        port=config.API_PORT,
        reload=False,
    )
