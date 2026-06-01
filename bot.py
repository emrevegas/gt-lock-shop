"""GT Lock Shop — Discord bot + background deposit monitor."""

import asyncio
import logging

import discord
from discord.ext import commands, tasks

import config
from api_server import app as fastapi_app
from database import db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
log = logging.getLogger("gt-lock-shop")
# Uvicorn loglarını da aynı konsola yaz
for _name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
    logging.getLogger(_name).setLevel(logging.INFO)

intents = discord.Intents.default()
# Slash-only bot; message_content kapalı (uyarı normal, komutları etkilemez)
intents.members = True


class GTLockBot(commands.Bot):
    def __init__(self):
        super().__init__(command_prefix="!", intents=intents)

    async def on_ready(self):
        from modules.orders import count_orders_by_status

        counts = await count_orders_by_status()
        log.info(
            "Discord ready: %s (%s) | order counts=%s",
            self.user,
            self.user.id if self.user else "?",
            counts,
        )

    async def _sync_app_commands(self) -> list[str]:
        names: list[str] = []
        if config.GUILD_ID:
            guild = discord.Object(id=config.GUILD_ID)
            self.tree.copy_global_to(guild=guild)
            synced = await self.tree.sync(guild=guild)
            names = [c.name for c in synced]
            log.info("Guild sync %s: %d commands: %s", config.GUILD_ID, len(synced), names)
        else:
            synced = await self.tree.sync()
            names = [c.name for c in synced]
            log.info(
                "Global sync: %d commands (GUILD_ID yok — görünmesi saatler sürebilir): %s",
                len(synced),
                names,
            )
        return names

    async def setup_hook(self):
        for ext in ("cogs.shop", "cogs.wallet", "cogs.admin"):
            try:
                await self.load_extension(ext)
            except Exception as e:
                log.exception("Failed to load %s: %s", ext, e)
        await self._sync_app_commands()
        if not self.deposit_monitor.is_running():
            self.deposit_monitor.start()
        if not self.order_notify.is_running():
            self.order_notify.start()
        if not self.order_queue_log.is_running():
            self.order_queue_log.start()
        if not self.luci_watchdog.is_running():
            self.luci_watchdog.start()

    @tasks.loop(minutes=2.0)
    async def deposit_monitor(self):
        import json

        rows = await db.fetchall("SELECT user_id, wallet_json FROM crypto_wallets")
        from modules.crypto_deposit import check_user_deposits

        for row in rows:
            try:
                w = json.loads(row["wallet_json"])
                if w.get("check_until", 0) < __import__("time").time():
                    continue
            except Exception:
                continue
            try:
                hits = await check_user_deposits(int(row["user_id"]))
                for hit in hits:
                    user = self.get_user(int(row["user_id"]))
                    if user:
                        try:
                            await user.send(
                                f"✅ Deposit credited: **{hit['balance']:.2f}** balance "
                                f"({hit['chain']} {hit['crypto']}, ~${hit['usd']:.2f})"
                            )
                        except discord.HTTPException:
                            pass
            except Exception as e:
                log.warning("Deposit check uid=%s: %s", row["user_id"], e)

    @deposit_monitor.before_loop
    async def before_monitor(self):
        await self.wait_until_ready()

    @tasks.loop(seconds=12.0)
    async def order_notify(self):
        from modules.orders import list_completed_unnotified, list_failed_unnotified, mark_notified
        from modules.shop import DISPLAY

        for order in await list_completed_unnotified():
            user = self.get_user(int(order["user_id"]))
            if user:
                try:
                    await user.send(
                        f"✅ **İşlem onaylandı** — Sipariş `#{order['id']}`\n"
                        f"{order['quantity']}x {DISPLAY.get(order['item_type'], order['item_type'])} "
                        f"→ `{order['growid']}` dünyası: `{order['world_name']}`"
                    )
                except discord.HTTPException:
                    pass
            await mark_notified(order["id"])

        for order in await list_failed_unnotified():
            user = self.get_user(int(order["user_id"]))
            if user:
                try:
                    reason = order.get("fail_reason") or "bilinmiyor"
                    if reason == "order_timeout_2min":
                        reason = "2 dakika içinde trade tamamlanmadı"
                    elif reason == "warp_failed":
                        reason = "Bot hedef dünyaya giremedi (dünya adı/kapı ID kontrol et)"
                    elif reason == "bot_offline":
                        reason = "Growtopia botu çevrimiçi değil"
                    await user.send(
                        f"❌ Sipariş `#{order['id']}` başarısız: {reason}\n"
                        f"Bakiye iade edildi."
                    )
                except discord.HTTPException:
                    pass
            await mark_notified(order["id"])

    @order_notify.before_loop
    async def before_order_notify(self):
        await self.wait_until_ready()

    @tasks.loop(seconds=20.0)
    async def order_queue_log(self):
        from modules.orders import count_orders_by_status, list_active_orders

        counts = await count_orders_by_status()
        pending = int(counts.get("pending", 0))
        processing = int(counts.get("processing", 0))
        active = await list_active_orders(limit=5) if (pending or processing) else []
        ids = ", ".join(f"#{o['id']}:{o['status']}" for o in active) or "-"
        log.info(
            "[Order queue] pending=%s processing=%s active=[%s] all=%s",
            pending,
            processing,
            ids,
            counts,
        )

    @order_queue_log.before_loop
    async def before_order_queue_log(self):
        await self.wait_until_ready()

    @tasks.loop(seconds=30.0)
    async def luci_watchdog(self):
        import time

        from modules import luci_status
        from modules.orders import count_orders_by_status

        counts = await count_orders_by_status()
        pending = int(counts.get("pending", 0))
        processing = int(counts.get("processing", 0))
        if pending == 0 and processing == 0:
            return

        since = luci_status.seconds_since_poll()
        if since is None:
            log.warning(
                "[Luci] Sipariş bekliyor (pending=%s processing=%s) ama Luci API'ye HİÇ gelmedi. "
                "Lucifer'de scripts/withdraw_worker.lua çalıştır; API_URL ve API_KEY kontrol et.",
                pending,
                processing,
            )
        elif since > 45:
            log.warning(
                "[Luci] %ds'dir API isteği yok (pending=%s processing=%s). Script durmuş olabilir.",
                int(since),
                pending,
                processing,
            )

    @luci_watchdog.before_loop
    async def before_luci_watchdog(self):
        await self.wait_until_ready()


async def run_api():
    import uvicorn

    config_uv = uvicorn.Config(
        fastapi_app,
        host=config.API_HOST,
        port=config.API_PORT,
        log_level="info",
    )
    server = uvicorn.Server(config_uv)
    await server.serve()


async def main():
    if not config.DISCORD_TOKEN:
        raise SystemExit("DISCORD_TOKEN missing in .env")

    await db.init_db()
    log.info(
        "Starting GT Lock Shop | DB=%s | API=http://%s:%s",
        config.DB_PATH.resolve(),
        config.API_HOST,
        config.API_PORT,
    )
    if not config.LUCI_API_KEY:
        log.warning("LUCI_API_KEY boş — Luci script API'ye bağlanamaz!")

    bot = GTLockBot()
    api_task = asyncio.create_task(run_api())
    try:
        await bot.start(config.DISCORD_TOKEN)
    finally:
        api_task.cancel()


if __name__ == "__main__":
    asyncio.run(main())
