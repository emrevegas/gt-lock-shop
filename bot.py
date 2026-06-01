"""GT Lock Shop — Discord bot + Luci dosya kuyruğu."""

import asyncio
import logging

import discord
from discord.ext import commands, tasks

import config
from database import db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
log = logging.getLogger("gt-lock-shop")

intents = discord.Intents.default()
intents.members = True


class GTLockBot(commands.Bot):
    def __init__(self):
        super().__init__(command_prefix="!", intents=intents)

    async def on_ready(self):
        from modules.orders import count_orders_by_status
        from modules.luci_files import queue_stats

        counts = await count_orders_by_status()
        qs = queue_stats()
        log.info(
            "Discord ready: %s | db_orders=%s | file_queue=%s",
            self.user,
            counts,
            qs,
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
            log.info("Global sync: %d commands: %s", len(synced), names)
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
        if not self.luci_file_poll.is_running():
            self.luci_file_poll.start()

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
                        f"✅ **Teslimat tamamlandı** — Sipariş `#{order['id']}`\n"
                        f"{order['quantity']}x {DISPLAY.get(order['item_type'], order['item_type'])} "
                        f"→ dünya `{order['world_name']}` bağış kutusuna bırakıldı."
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
                        reason = "2 dakika içinde teslimat tamamlanmadı"
                    elif reason == "warp_failed":
                        reason = "Bot hedef dünyaya giremedi"
                    elif reason == "bot_offline":
                        reason = "Growtopia botu çevrimiçi değil"
                    elif reason == "no_donation_box":
                        reason = "Dünyada erişilebilir bağış kutusu bulunamadı"
                    elif reason == "donation_failed":
                        reason = "Bağış kutusuna item konulamadı"
                    elif reason == "invalid_world":
                        reason = "Geçersiz dünya adı"
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

    @tasks.loop(seconds=3.0)
    async def luci_file_poll(self):
        from modules.luci_files import process_file_results, sync_processing_from_files

        claimed = await sync_processing_from_files()
        handled = await process_file_results()
        if claimed:
            log.info("[Luci file] %s order(s) → processing", claimed)
        if handled:
            log.info("[Luci file] applied %s result(s) from disk", handled)

    @luci_file_poll.before_loop
    async def before_luci_file_poll(self):
        await self.wait_until_ready()

    @tasks.loop(seconds=20.0)
    async def order_queue_log(self):
        from modules.orders import count_orders_by_status, list_active_orders
        from modules.luci_files import queue_stats

        counts = await count_orders_by_status()
        qs = queue_stats()
        pending = int(counts.get("pending", 0))
        processing = int(counts.get("processing", 0))
        active = await list_active_orders(limit=5) if (pending or processing) else []
        ids = ", ".join(f"#{o['id']}:{o['status']}" for o in active) or "-"
        log.info(
            "[Order queue] db pending=%s processing=%s | files %s | active=[%s]",
            pending,
            processing,
            qs,
            ids,
        )

    @order_queue_log.before_loop
    async def before_order_queue_log(self):
        await self.wait_until_ready()


async def main():
    if not config.DISCORD_TOKEN:
        raise SystemExit("DISCORD_TOKEN missing in .env")

    await db.init_db()

    from modules.luci_files import ensure_queue_dirs, sync_pending_orders_from_db
    from modules.orders import release_all_processing

    qpath = ensure_queue_dirs()
    released = await release_all_processing()
    if released:
        log.info("Re-queued %s processing order(s) to file queue", released)
    synced = await sync_pending_orders_from_db()
    if synced:
        log.info("Synced %s pending order(s) to file queue", synced)

    log.info("GT Lock Shop | DB=%s | Luci queue=%s", config.DB_PATH.resolve(), qpath)

    if config.ENABLE_HTTP_API:
        from api_server import app as fastapi_app
        import uvicorn

        log.info("HTTP API enabled on %s:%s", config.API_HOST, config.API_PORT)

        async def run_api():
            config_uv = uvicorn.Config(
                fastapi_app,
                host=config.API_HOST,
                port=config.API_PORT,
                log_level="info",
            )
            await uvicorn.Server(config_uv).serve()

        bot = GTLockBot()
        api_task = asyncio.create_task(run_api())
        try:
            await bot.start(config.DISCORD_TOKEN)
        finally:
            api_task.cancel()
    else:
        log.info("HTTP API kapalı — Luci dosya kuyruğu kullanılıyor")
        bot = GTLockBot()
        await bot.start(config.DISCORD_TOKEN)


if __name__ == "__main__":
    asyncio.run(main())
