"""SOL + LTC HD wallet deposits (simplified from flipbot pattern)."""

import os
import time
from typing import Optional

import requests

from config import BLOCKCYPHER_TOKEN, CRYPTO_MNEMONIC, MIN_DEPOSIT_USD, SOL_RPC_URL
from database import db

COINGECKO = "https://api.coingecko.com/api/v3/simple/price"
BLOCKCYPHER_BASE = "https://api.blockcypher.com/v1/ltc/main"
MONITOR_TTL = 86_400

_rate_cache: dict = {}
_RATE_TTL = 60


def _seed() -> bytes:
    from bip_utils import Bip39SeedGenerator

    if not CRYPTO_MNEMONIC:
        raise RuntimeError("CRYPTO_MNEMONIC not set in .env")
    return Bip39SeedGenerator(CRYPTO_MNEMONIC).Generate()


def derive_sol_address(index: int) -> str:
    from bip_utils import Bip44, Bip44Changes, Bip44Coins

    ctx = (
        Bip44.FromSeed(_seed(), Bip44Coins.SOLANA)
        .Purpose()
        .Coin()
        .Account(index)
        .Change(Bip44Changes.CHAIN_EXT)
        .AddressIndex(0)
    )
    return ctx.PublicKey().ToAddress()


def derive_ltc_address(index: int) -> str:
    from bip_utils import Bip44, Bip44Changes, Bip44Coins

    ctx = (
        Bip44.FromSeed(_seed(), Bip44Coins.LITECOIN)
        .Purpose()
        .Coin()
        .Account(index)
        .Change(Bip44Changes.CHAIN_EXT)
        .AddressIndex(0)
    )
    return ctx.PublicKey().ToAddress()


async def _next_wallet_index() -> int:
    idx = await db.get_setting("crypto_wallet_index", 0)
    if not isinstance(idx, int):
        idx = int(idx or 0)
    await db.set_setting("crypto_wallet_index", idx + 1)
    return idx


async def get_or_create_wallet(user_id: int) -> dict:
    conn = db.get_conn()
    row = await conn.execute_fetchone(
        "SELECT wallet_json FROM crypto_wallets WHERE user_id = ?", (user_id,)
    )
    if row:
        import json

        return json.loads(row["wallet_json"])

    index = await _next_wallet_index()
    wallet = {
        "index": index,
        "sol": {"address": derive_sol_address(index), "last_balance": -1},
        "ltc": {"address": derive_ltc_address(index), "last_balance": -1},
        "check_until": int(time.time()) + MONITOR_TTL,
    }
    import json

    await conn.execute(
        "INSERT INTO crypto_wallets (user_id, wallet_json, updated_at) VALUES (?, ?, ?)",
        (user_id, json.dumps(wallet), int(time.time())),
    )
    await conn.commit()
    return wallet


async def _save_wallet(user_id: int, wallet: dict) -> None:
    import json

    await db.get_conn().execute(
        "UPDATE crypto_wallets SET wallet_json = ?, updated_at = ? WHERE user_id = ?",
        (json.dumps(wallet), int(time.time()), user_id),
    )
    await db.get_conn().commit()


def fetch_rates() -> dict:
    now = time.time()
    if _rate_cache and now - _rate_cache.get("_ts", 0) < _RATE_TTL:
        return _rate_cache
    r = requests.get(
        COINGECKO,
        params={"ids": "solana,litecoin", "vs_currencies": "usd"},
        timeout=15,
    )
    r.raise_for_status()
    data = r.json()
    out = {
        "_ts": now,
        "sol_usd": float(data.get("solana", {}).get("usd", 0)),
        "ltc_usd": float(data.get("litecoin", {}).get("usd", 0)),
    }
    _rate_cache.update(out)
    return out


def sol_balance_lamports(address: str) -> int:
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "getBalance",
        "params": [address],
    }
    r = requests.post(SOL_RPC_URL, json=payload, timeout=20)
    r.raise_for_status()
    val = r.json().get("result", {}).get("value")
    return int(val) if val is not None else -1


def ltc_balance_satoshis(address: str) -> int:
    url = f"{BLOCKCYPHER_BASE}/addrs/{address}/balance"
    params = {}
    if BLOCKCYPHER_TOKEN:
        params["token"] = BLOCKCYPHER_TOKEN
    r = requests.get(url, params=params, timeout=20)
    r.raise_for_status()
    return int(r.json().get("final_balance", 0))


async def _usd_to_balance(usd: float) -> float:
    """1 balance unit = 1 USD by default; admin can change via setting."""
    rate = await db.get_setting("usd_to_balance", 1.0)
    try:
        rate = float(rate)
    except (TypeError, ValueError):
        rate = 1.0
    if rate <= 0:
        rate = 1.0
    return round(usd * rate, 2)


async def check_user_deposits(user_id: int) -> list[dict]:
    wallet = await get_or_create_wallet(user_id)
    if wallet.get("check_until", 0) < time.time():
        return []

    rates = fetch_rates()
    credited = []
    changed = False

    sol = wallet.get("sol") or {}
    addr = sol.get("address")
    if addr:
        current = sol_balance_lamports(addr)
        last = int(sol.get("last_balance", -1))
        if current >= 0:
            if last < 0:
                last = 0
                sol["last_balance"] = 0
            if current > last:
                diff_sol = (current - last) / 1_000_000_000
                usd = diff_sol * rates.get("sol_usd", 0)
                if usd >= MIN_DEPOSIT_USD:
                    bal = await _usd_to_balance(usd)
                    if bal > 0:
                        await db.add_balance(user_id, bal)
                        await _log_deposit(user_id, "SOL", diff_sol, usd, bal)
                        credited.append(
                            {
                                "chain": "SOL",
                                "crypto": round(diff_sol, 6),
                                "usd": round(usd, 2),
                                "balance": bal,
                            }
                        )
                sol["last_balance"] = current
                changed = True

    ltc = wallet.get("ltc") or {}
    laddr = ltc.get("address")
    if laddr:
        current = ltc_balance_satoshis(laddr)
        last = int(ltc.get("last_balance", -1))
        if current >= 0:
            if last < 0:
                last = 0
                ltc["last_balance"] = 0
            if current > last:
                diff_ltc = (current - last) / 100_000_000
                usd = diff_ltc * rates.get("ltc_usd", 0)
                if usd >= MIN_DEPOSIT_USD:
                    bal = await _usd_to_balance(usd)
                    if bal > 0:
                        await db.add_balance(user_id, bal)
                        await _log_deposit(user_id, "LTC", diff_ltc, usd, bal)
                        credited.append(
                            {
                                "chain": "LTC",
                                "crypto": round(diff_ltc, 8),
                                "usd": round(usd, 2),
                                "balance": bal,
                            }
                        )
                ltc["last_balance"] = current
                changed = True

    if changed:
        wallet["sol"] = sol
        wallet["ltc"] = ltc
        await _save_wallet(user_id, wallet)

    return credited


async def _log_deposit(
    user_id: int, chain: str, crypto: float, usd: float, credited: float
) -> None:
    await db.get_conn().execute(
        """
        INSERT INTO deposit_log (user_id, chain, amount_crypto, amount_usd, credited, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (user_id, chain, crypto, usd, credited, int(time.time())),
    )
    await db.get_conn().commit()


async def extend_monitor(user_id: int) -> None:
    wallet = await get_or_create_wallet(user_id)
    wallet["check_until"] = int(time.time()) + MONITOR_TTL
    await _save_wallet(user_id, wallet)
