"""Dosya tabanlı Luci kuyruğu (API yerine read/write)."""

import json
import logging
import time
from pathlib import Path
from typing import Any, Optional

from config import LUCI_QUEUE_DIR
from modules.shop import item_id_for

log = logging.getLogger("gt-lock-shop")

PENDING_DIR = LUCI_QUEUE_DIR / "pending"
PROCESSING_DIR = LUCI_QUEUE_DIR / "processing"
RESULTS_DIR = LUCI_QUEUE_DIR / "results"
INDEX_FILE = LUCI_QUEUE_DIR / "pending_index.txt"
PATH_FILE = LUCI_QUEUE_DIR / "QUEUE_PATH.txt"


def ensure_queue_dirs() -> Path:
    for d in (LUCI_QUEUE_DIR, PENDING_DIR, PROCESSING_DIR, RESULTS_DIR):
        d.mkdir(parents=True, exist_ok=True)
    PATH_FILE.write_text(str(LUCI_QUEUE_DIR.resolve()), encoding="utf-8")
    if not INDEX_FILE.exists():
        INDEX_FILE.write_text("", encoding="utf-8")
    return LUCI_QUEUE_DIR.resolve()


def _order_payload(order: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": int(order["id"]),
        "user_id": int(order["user_id"]),
        "growid": str(order["growid"]),
        "item_type": str(order["item_type"]),
        "quantity": int(order["quantity"]),
        "price_paid": float(order["price_paid"]),
        "world_name": str(order["world_name"]),
        "item_id": int(order.get("item_id") or item_id_for(order["item_type"])),
        "created_at": int(order.get("created_at") or time.time()),
    }


def enqueue_order(order: dict[str, Any]) -> None:
    """Luci'nin okuyacağı pending dosyası + index."""
    ensure_queue_dirs()
    oid = int(order["id"])
    path = PENDING_DIR / f"{oid}.json"
    path.write_text(json.dumps(_order_payload(order), ensure_ascii=False), encoding="utf-8")

    lines = INDEX_FILE.read_text(encoding="utf-8").splitlines()
    ids = [x.strip() for x in lines if x.strip().isdigit()]
    sid = str(oid)
    if sid not in ids:
        ids.append(sid)
    INDEX_FILE.write_text("\n".join(ids) + ("\n" if ids else ""), encoding="utf-8")
    log.info("[Luci file] enqueued #%s → %s", oid, path)


def remove_order_files(order_id: int) -> None:
    oid = int(order_id)
    for p in (
        PENDING_DIR / f"{oid}.json",
        PROCESSING_DIR / f"{oid}.json",
        RESULTS_DIR / f"{oid}.json",
    ):
        if p.exists():
            p.unlink()
    lines = INDEX_FILE.read_text(encoding="utf-8").splitlines()
    lines = [ln for ln in lines if ln.strip() != str(oid)]
    INDEX_FILE.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def clear_all_queue_files() -> int:
    ensure_queue_dirs()
    n = 0
    for folder in (PENDING_DIR, PROCESSING_DIR, RESULTS_DIR):
        for p in folder.glob("*.json"):
            p.unlink()
            n += 1
    INDEX_FILE.write_text("", encoding="utf-8")
    log.info("[Luci file] cleared %s queue file(s)", n)
    return n


def queue_stats() -> dict[str, int]:
    ensure_queue_dirs()
    return {
        "pending_files": len(list(PENDING_DIR.glob("*.json"))),
        "processing_files": len(list(PROCESSING_DIR.glob("*.json"))),
        "result_files": len(list(RESULTS_DIR.glob("*.json")),
        ),
    }


def _read_json(path: Path) -> Optional[dict]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


async def sync_pending_orders_from_db() -> int:
    """DB'de pending olup dosyası olmayan siparişleri kuyruğa yaz."""
    from modules.orders import list_active_orders

    n = 0
    for order in await list_active_orders(limit=100):
        if order["status"] != "pending":
            continue
        oid = int(order["id"])
        if not (PENDING_DIR / f"{oid}.json").exists():
            order = dict(order)
            order["item_id"] = item_id_for(order["item_type"])
            enqueue_order(order)
            n += 1
    return n


async def process_file_results() -> int:
    """Luci'nin yazdığı results/*.json dosyalarını işle."""
    from modules.orders import complete_order, fail_order, get_order

    ensure_queue_dirs()
    handled = 0
    for path in sorted(RESULTS_DIR.glob("*.json")):
        data = _read_json(path)
        if not data or "id" not in data:
            path.unlink(missing_ok=True)
            continue
        oid = int(data["id"])
        status = str(data.get("status", "")).lower()
        reason = str(data.get("reason", "") or "")

        order = await get_order(oid)
        if not order:
            path.unlink(missing_ok=True)
            (PROCESSING_DIR / f"{oid}.json").unlink(missing_ok=True)
            continue

        if status == "completed":
            if order["status"] != "completed":
                await complete_order(oid)
            log.info("[Luci file] order #%s completed", oid)
        else:
            if order["status"] not in ("failed", "cancelled"):
                await fail_order(oid, reason or "luci_failed")
            log.info("[Luci file] order #%s failed: %s", oid, reason)

        path.unlink(missing_ok=True)
        (PROCESSING_DIR / f"{oid}.json").unlink(missing_ok=True)
        (PENDING_DIR / f"{oid}.json").unlink(missing_ok=True)
        handled += 1

    return handled


async def sync_processing_from_files() -> int:
    """processing/*.json varsa DB'yi processing yap."""
    from database import db

    ensure_queue_dirs()
    n = 0
    for path in PROCESSING_DIR.glob("*.json"):
        data = _read_json(path)
        if not data:
            continue
        oid = int(data["id"])
        row = await db.fetchone("SELECT status FROM orders WHERE id = ?", (oid,))
        if row and row["status"] == "pending":
            now = int(time.time())
            await db.get_conn().execute(
                "UPDATE orders SET status = 'processing', luci_claimed_at = ? WHERE id = ?",
                (now, oid),
            )
            await db.get_conn().commit()
            (PENDING_DIR / f"{oid}.json").unlink(missing_ok=True)
            log.info("[Luci file] order #%s → processing (file claim)", oid)
            n += 1
    return n
