"""Load environment configuration."""

import os
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent
load_dotenv(ROOT / ".env")

DISCORD_TOKEN = os.getenv("DISCORD_TOKEN", "").strip()
GUILD_ID = int(os.getenv("GUILD_ID", "0") or 0)

ADMIN_ROLE_IDS = [
    int(x.strip())
    for x in os.getenv("ADMIN_ROLE_IDS", "").split(",")
    if x.strip().isdigit()
]

API_HOST = os.getenv("API_HOST", "127.0.0.1").strip()
API_PORT = int(os.getenv("API_PORT", "8765") or 8765)
LUCI_API_KEY = os.getenv("LUCI_API_KEY", "").strip()

CRYPTO_MNEMONIC = os.getenv("CRYPTO_MNEMONIC", "").strip()
BLOCKCYPHER_TOKEN = os.getenv("BLOCKCYPHER_TOKEN", "").strip()
SOL_RPC_URL = os.getenv("SOL_RPC_URL", "https://api.mainnet-beta.solana.com").strip()

DEFAULT_PRICE_WL = float(os.getenv("DEFAULT_PRICE_WL", "1") or 1)
DEFAULT_PRICE_DL = float(os.getenv("DEFAULT_PRICE_DL", "100") or 100)
DEFAULT_PRICE_BGL = float(os.getenv("DEFAULT_PRICE_BGL", "10000") or 10000)
MIN_DEPOSIT_USD = float(os.getenv("MIN_DEPOSIT_USD", "1") or 1)

WITHDRAW_WORLDS = [
    w.strip().upper()
    for w in os.getenv("WITHDRAW_WORLDS", "").split(",")
    if w.strip()
]

DATA_DIR = ROOT / "data"
DATA_DIR.mkdir(exist_ok=True)
DB_PATH = DATA_DIR / "shop.db"

# Luci dosya kuyruğu (withdraw_worker_file.lua burayı okur)
LUCI_QUEUE_DIR = DATA_DIR / "luci"

# Eski HTTP API (varsayılan kapalı)
ENABLE_HTTP_API = os.getenv("ENABLE_HTTP_API", "false").strip().lower() in (
    "1",
    "true",
    "yes",
)

# Growtopia item IDs
ITEM_WL = 242
ITEM_DL = 1796
ITEM_BGL = 7188

WL_PER_DL = 100
DL_PER_BGL = 100
