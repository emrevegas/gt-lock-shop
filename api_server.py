"""HTTP API for Lucifer (Luci) withdraw script."""

from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

import config
from database import db
from modules import orders

app = FastAPI(title="GT Lock Shop Luci Bridge", version="1.0.0")


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


@app.on_event("startup")
async def startup():
    await db.init_db()
    await orders.reset_stale_processing()


@app.get("/health")
async def health():
    return {"ok": True}


@app.get("/api/orders/next", dependencies=[Depends(verify_key)])
async def next_order():
    order = await orders.claim_next_pending()
    if not order:
        return {"order": None}
    return {"order": order}


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
