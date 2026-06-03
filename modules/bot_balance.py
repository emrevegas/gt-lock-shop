"""Luci worker bot_balance.json — WL/DL/BGL stok dosyası."""

import json
import time
from pathlib import Path
from typing import Any, Optional

from config import DL_PER_BGL, LUCI_QUEUE_DIR, WL_PER_DL

BOT_BALANCE_FILE = LUCI_QUEUE_DIR / "bot_balance.json"
STALE_SECONDS = 90


def _read_json(path: Path) -> Optional[dict[str, Any]]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def read_bot_balance() -> Optional[dict[str, Any]]:
    if not BOT_BALANCE_FILE.exists():
        return None
    return _read_json(BOT_BALANCE_FILE)


def wl_equivalent(wl: int, dl: int, bgl: int) -> int:
    return int(wl) + int(dl) * WL_PER_DL + int(bgl) * WL_PER_DL * DL_PER_BGL


def format_bot_balance_message() -> str:
    data = read_bot_balance()
    if not data:
        return (
            "Bot stoğu henüz yok.\n"
            f"Luci `withdraw_worker.lua` çalışıyor mu? Dosya: `{BOT_BALANCE_FILE.resolve()}`"
        )

    wl = int(data.get("wl") or 0)
    dl = int(data.get("dl") or 0)
    bgl = int(data.get("bgl") or 0)
    at = int(data.get("at") or 0)
    bot_name = str(data.get("bot") or "?")
    world = str(data.get("world") or "?")
    equiv = wl_equivalent(wl, dl, bgl)

    age_note = ""
    if at > 0:
        age = int(time.time()) - at
        if age > STALE_SECONDS:
            age_note = f"\n⚠️ Son güncelleme **{age}** sn önce (script çalışmıyor olabilir)."
        else:
            age_note = f"\n🕐 Güncellendi: <t:{at}:R>"

    return (
        f"**Bot:** `{bot_name}` · dünya `{world}`\n"
        f"🪙 **WL:** `{wl:,}` · **DL:** `{dl:,}` · **BGL:** `{bgl:,}`\n"
        f"📊 Toplam (WL karşılığı): **~{equiv:,} WL**{age_note}"
    )
