"""Withdraw order queue for Luci worker."""

import logging
import random
import time
from typing import Any, Optional

log = logging.getLogger("gt-lock-shop")

from config import WITHDRAW_WORLDS
from database import db
from modules.shop import ItemType, item_id_for


async def get_withdraw_worlds() -> list[str]:
    stored = await db.get_setting("withdraw_worlds")
    if isinstance(stored, list) and stored:
        return [str(w).strip().upper() for w in stored if str(w).strip()]
    return list(WITHDRAW_WORLDS)


async def set_withdraw_worlds(worlds: list[str]) -> list[str]:
    clean = [w.strip().upper() for w in worlds if w and w.strip()]
    await db.set_setting("withdraw_worlds", clean)
    return clean


def pick_world(worlds: list[str]) -> str:
    if not worlds:
        raise ValueError("No withdraw worlds configured")
    return random.choice(worlds)


def normalize_world_name(world_name: str) -> str:
    """WORLD or WORLD|DOOR — uppercase, trimmed."""
    raw = (world_name or "").strip().upper()
    if not raw:
        raise ValueError("Dünya adı boş olamaz")
    name, _, door = raw.partition("|")
    name = name.strip()
    if len(name) < 1 or len(name) > 24:
        raise ValueError("Geçersiz dünya adı")
    if door.strip():
        return f"{name}|{door.strip()}"
    return name


async def create_order(
    user_id: int,
    growid: str,
    world_name: str,
    item_type: ItemType,
    quantity: int,
    price_paid: float,
) -> dict[str, Any]:
    world = normalize_world_name(world_name)
    conn = db.get_conn()
    now = int(time.time())
    cur = await conn.execute(
        """
        INSERT INTO orders (user_id, growid, item_type, quantity, price_paid, world_name, status, created_at)
        VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
        """,
        (
            user_id,
            growid.strip(),
            item_type,
            int(quantity),
            float(price_paid),
            world,
            now,
        ),
    )
    await conn.commit()
    order_id = cur.lastrowid
    created = await get_order(order_id)
    if created:
        log.info(
            "[Order created] #%s user=%s growid=%s %sx%s world=%s status=%s",
            order_id,
            user_id,
            growid.strip(),
            quantity,
            item_type,
            world,
            created.get("status"),
        )
        from modules.luci_files import enqueue_order

        out = dict(created)
        out["item_id"] = item_id_for(item_type)
        enqueue_order(out)
    return created


async def get_order(order_id: int) -> Optional[dict[str, Any]]:
    row = await db.fetchone("SELECT * FROM orders WHERE id = ?", (order_id,))
    return dict(row) if row else None


async def claim_next_pending() -> Optional[dict[str, Any]]:
    """Atomically claim oldest pending order for Luci worker."""
    conn = db.get_conn()
    row = await db.fetchone(
        "SELECT * FROM orders WHERE status = 'pending' ORDER BY id ASC LIMIT 1"
    )
    if not row:
        return None
    order_id = row["id"]
    now = int(time.time())
    await conn.execute(
        "UPDATE orders SET status = 'processing', luci_claimed_at = ? WHERE id = ? AND status = 'pending'",
        (now, order_id),
    )
    await conn.commit()
    updated = await get_order(order_id)
    if updated and updated["status"] == "processing":
        out = dict(updated)
        out["item_id"] = item_id_for(updated["item_type"])
        return out
    return None


async def complete_order(order_id: int) -> Optional[dict[str, Any]]:
    conn = db.get_conn()
    await conn.execute(
        "UPDATE orders SET status = 'completed', completed_at = ? WHERE id = ?",
        (int(time.time()), order_id),
    )
    await conn.commit()
    return await get_order(order_id)


async def fail_order(order_id: int, reason: str, *, refund: bool = True) -> Optional[dict[str, Any]]:
    order = await get_order(order_id)
    if not order or order["status"] in ("completed", "failed"):
        return order
    prev_status = order["status"]
    conn = db.get_conn()
    await conn.execute(
        "UPDATE orders SET status = 'failed', fail_reason = ?, completed_at = ? WHERE id = ?",
        (reason[:500], int(time.time()), order_id),
    )
    await conn.commit()
    if refund and prev_status in ("pending", "processing"):
        await db.add_balance(int(order["user_id"]), float(order["price_paid"]))
    return await get_order(order_id)


async def mark_notified(order_id: int) -> None:
    await db.get_conn().execute(
        "UPDATE orders SET notified = 1 WHERE id = ?", (order_id,)
    )
    await db.get_conn().commit()


async def list_completed_unnotified() -> list[dict[str, Any]]:
    rows = await db.fetchall(
        "SELECT * FROM orders WHERE status = 'completed' AND notified = 0"
    )
    return [dict(r) for r in rows]


async def list_failed_unnotified() -> list[dict[str, Any]]:
    rows = await db.fetchall(
        "SELECT * FROM orders WHERE status = 'failed' AND notified = 0"
    )
    return [dict(r) for r in rows]


async def reset_stale_processing(max_age_sec: int = 120) -> int:
    """Re-queue orders stuck in processing (bot crash)."""
    cutoff = int(time.time()) - max_age_sec
    conn = db.get_conn()
    cur = await conn.execute(
        """
        UPDATE orders SET status = 'pending', luci_claimed_at = NULL
        WHERE status = 'processing' AND luci_claimed_at IS NOT NULL AND luci_claimed_at < ?
        """,
        (cutoff,),
    )
    await conn.commit()
    return cur.rowcount


async def release_all_processing() -> int:
    """Re-queue every processing order (bot restart)."""
    from modules.luci_files import enqueue_order

    rows = await db.fetchall("SELECT * FROM orders WHERE status = 'processing'")
    conn = db.get_conn()
    cur = await conn.execute(
        """
        UPDATE orders SET status = 'pending', luci_claimed_at = NULL
        WHERE status = 'processing'
        """
    )
    await conn.commit()
    for row in rows:
        o = dict(row)
        o["item_id"] = item_id_for(o["item_type"])
        enqueue_order(o)
    return cur.rowcount


async def count_orders_by_status() -> dict[str, int]:
    rows = await db.fetchall(
        "SELECT status, COUNT(*) AS c FROM orders GROUP BY status"
    )
    return {str(r["status"]): int(r["c"]) for r in rows}


async def list_active_orders(limit: int = 25) -> list[dict[str, Any]]:
    rows = await db.fetchall(
        """
        SELECT * FROM orders
        WHERE status IN ('pending', 'processing')
        ORDER BY id ASC
        LIMIT ?
        """,
        (max(1, min(int(limit), 100)),),
    )
    return [dict(r) for r in rows]


async def cancel_order_by_id(
    order_id: int,
    *,
    reason: str = "admin_cancelled",
    refund: bool = True,
) -> Optional[dict[str, Any]]:
    order = await get_order(order_id)
    if not order or order["status"] not in ("pending", "processing"):
        return None
    if refund:
        amount = float(order["price_paid"])
        if amount > 0:
            await db.add_balance(int(order["user_id"]), amount)
    conn = db.get_conn()
    await conn.execute(
        """
        UPDATE orders
        SET status = 'cancelled', fail_reason = ?, completed_at = ?, notified = 1
        WHERE id = ? AND status IN ('pending', 'processing')
        """,
        ((reason or "admin_cancelled")[:500], int(time.time()), order_id),
    )
    await conn.commit()
    from modules.luci_files import remove_order_files

    remove_order_files(order_id)
    return await get_order(order_id)


async def cancel_all_active_orders(
    *,
    reason: str = "admin_cancelled",
    refund: bool = True,
) -> dict[str, Any]:
    """
    Cancel every pending/processing order.
    Refunds price_paid to each user when refund=True.
    """
    rows = await db.fetchall(
        "SELECT * FROM orders WHERE status IN ('pending', 'processing') ORDER BY id ASC"
    )
    if not rows:
        return {"cancelled": 0, "refunded_total": 0.0, "users_refunded": 0}

    conn = db.get_conn()
    now = int(time.time())
    safe_reason = (reason or "admin_cancelled")[:500]
    cancelled = 0
    refunded_total = 0.0
    users_refunded: set[int] = set()

    for row in rows:
        order = dict(row)
        if refund:
            amount = float(order["price_paid"])
            if amount > 0:
                await db.add_balance(int(order["user_id"]), amount)
                refunded_total += amount
                users_refunded.add(int(order["user_id"]))
        await conn.execute(
            """
            UPDATE orders
            SET status = 'cancelled', fail_reason = ?, completed_at = ?, notified = 1
            WHERE id = ? AND status IN ('pending', 'processing')
            """,
            (safe_reason, now, order["id"]),
        )
        cancelled += 1

    await conn.commit()
    from modules.luci_files import clear_all_queue_files

    clear_all_queue_files()
    return {
        "cancelled": cancelled,
        "refunded_total": round(refunded_total, 2),
        "users_refunded": len(users_refunded),
    }
