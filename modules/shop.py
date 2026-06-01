"""WL / DL / BGL shop math and pricing."""

from typing import Literal

from config import (
    DEFAULT_PRICE_BGL,
    DEFAULT_PRICE_DL,
    DEFAULT_PRICE_WL,
    DL_PER_BGL,
    ITEM_BGL,
    ITEM_DL,
    ITEM_WL,
    WL_PER_DL,
)

ItemType = Literal["wl", "dl", "bgl"]

ITEM_MAP = {
    "wl": ITEM_WL,
    "dl": ITEM_DL,
    "bgl": ITEM_BGL,
}

DISPLAY = {
    "wl": "World Lock (WL)",
    "dl": "Diamond Lock (DL)",
    "bgl": "Blue Gem Lock (BGL)",
}


def wl_equivalent(item_type: ItemType, quantity: int) -> int:
    """Normalize quantity to WL units (1 DL = 100 WL, 1 BGL = 100 DL)."""
    q = max(1, int(quantity))
    if item_type == "wl":
        return q
    if item_type == "dl":
        return q * WL_PER_DL
    return q * WL_PER_DL * DL_PER_BGL


async def get_prices() -> dict[str, float]:
    from database.db import get_setting

    stored = await get_setting("prices")
    if isinstance(stored, dict):
        return {
            "wl": float(stored.get("wl", DEFAULT_PRICE_WL)),
            "dl": float(stored.get("dl", DEFAULT_PRICE_DL)),
            "bgl": float(stored.get("bgl", DEFAULT_PRICE_BGL)),
        }
    return {
        "wl": DEFAULT_PRICE_WL,
        "dl": DEFAULT_PRICE_DL,
        "bgl": DEFAULT_PRICE_BGL,
    }


async def set_prices(wl: float, dl: float, bgl: float) -> dict[str, float]:
    from database.db import set_setting

    prices = {"wl": wl, "dl": dl, "bgl": bgl}
    await set_setting("prices", prices)
    return prices


async def order_total(item_type: ItemType, quantity: int) -> float:
    prices = await get_prices()
    return prices[item_type] * max(1, int(quantity))


def item_id_for(item_type: ItemType) -> int:
    return ITEM_MAP[item_type]
