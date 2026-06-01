"""SQLite persistence for balances, orders, and settings."""

import json
import logging
import time
from typing import Any, Optional

import aiosqlite

from config import DB_PATH

log = logging.getLogger("gt-lock-shop")

_conn: Optional[aiosqlite.Connection] = None


async def init_db() -> None:
    global _conn
    if _conn is not None:
        return
    path = DB_PATH.resolve()
    log.info("SQLite database: %s", path)
    _conn = await aiosqlite.connect(path)
    _conn.row_factory = aiosqlite.Row
    await _conn.execute("PRAGMA journal_mode=WAL")
    await _conn.execute("PRAGMA synchronous=NORMAL")
    await _conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS users (
            user_id INTEGER PRIMARY KEY,
            balance REAL NOT NULL DEFAULT 0,
            growid TEXT,
            created_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS crypto_wallets (
            user_id INTEGER PRIMARY KEY,
            wallet_json TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS deposit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            chain TEXT NOT NULL,
            amount_crypto REAL NOT NULL,
            amount_usd REAL NOT NULL,
            credited REAL NOT NULL,
            tx_note TEXT,
            created_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS orders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            growid TEXT NOT NULL,
            item_type TEXT NOT NULL,
            quantity INTEGER NOT NULL,
            price_paid REAL NOT NULL,
            world_name TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            luci_claimed_at INTEGER,
            completed_at INTEGER,
            fail_reason TEXT,
            notified INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        );
        """
    )
    await _conn.commit()
    # migrations for existing DBs
    try:
        await _conn.execute(
            "ALTER TABLE orders ADD COLUMN notified INTEGER NOT NULL DEFAULT 0"
        )
        await _conn.commit()
    except Exception:
        pass


def get_conn_or_none() -> Optional[aiosqlite.Connection]:
    return _conn


def get_conn() -> aiosqlite.Connection:
    if _conn is None:
        raise RuntimeError("Database not initialized — call init_db() first")
    return _conn


async def fetchone(sql: str, params: tuple = ()) -> Optional[aiosqlite.Row]:
    cursor = await get_conn().execute(sql, params)
    return await cursor.fetchone()


async def fetchall(sql: str, params: tuple = ()) -> list[aiosqlite.Row]:
    cursor = await get_conn().execute(sql, params)
    return await cursor.fetchall()


async def ensure_user(user_id: int) -> None:
    conn = get_conn()
    row = await fetchone("SELECT user_id FROM users WHERE user_id = ?", (user_id,))
    if row:
        return
    await conn.execute(
        "INSERT INTO users (user_id, balance, growid, created_at) VALUES (?, 0, NULL, ?)",
        (user_id, int(time.time())),
    )
    await conn.commit()


async def get_balance(user_id: int) -> float:
    await ensure_user(user_id)
    row = await fetchone("SELECT balance FROM users WHERE user_id = ?", (user_id,))
    return float(row["balance"]) if row else 0.0


async def add_balance(user_id: int, amount: float) -> float:
    await ensure_user(user_id)
    conn = get_conn()
    await conn.execute(
        "UPDATE users SET balance = balance + ? WHERE user_id = ?",
        (amount, user_id),
    )
    await conn.commit()
    return await get_balance(user_id)


async def deduct_balance(user_id: int, amount: float) -> bool:
    bal = await get_balance(user_id)
    if bal < amount - 1e-9:
        return False
    conn = get_conn()
    await conn.execute(
        "UPDATE users SET balance = balance - ? WHERE user_id = ?",
        (amount, user_id),
    )
    await conn.commit()
    return True


async def set_growid(user_id: int, growid: str) -> None:
    await ensure_user(user_id)
    await get_conn().execute(
        "UPDATE users SET growid = ? WHERE user_id = ?",
        (growid.strip(), user_id),
    )
    await get_conn().commit()


async def get_growid(user_id: int) -> Optional[str]:
    await ensure_user(user_id)
    row = await fetchone("SELECT growid FROM users WHERE user_id = ?", (user_id,))
    return row["growid"] if row and row["growid"] else None


async def get_setting(key: str, default: Any = None) -> Any:
    row = await fetchone("SELECT value FROM settings WHERE key = ?", (key,))
    if not row:
        return default
    try:
        return json.loads(row["value"])
    except json.JSONDecodeError:
        return row["value"]


async def set_setting(key: str, value: Any) -> None:
    await get_conn().execute(
        "INSERT INTO settings (key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, json.dumps(value)),
    )
    await get_conn().commit()
