"""GT Lock Shop — Discord bot + background deposit monitor."""

import asyncio
import logging

import discord
from discord.ext import commands, tasks

import config
from api_server import app as fastapi_app
from database import db

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("gt-lock-shop")

intents = discord.Intents.default()
intents.message_content = False
intents.members = True


class GTLockBot(commands.Bot):
    def __init__(self):
        super().__init__(command_prefix="!", intents=intents)

    async def setup_hook(self):
        await db.init_db()
        for ext in ("cogs.shop", "cogs.wallet", "cogs.admin"):
            try:
                await self.load_extension(ext)
            except Exception as e:
                log.exception("Failed to load %s: %s", ext, e)
        await self.tree.sync()
        if not self.deposit_monitor.is_running():
            self.deposit_monitor.start()
        if not self.order_notify.is_running():
            self.order_notify.start()

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
                    await user.send(
                        f"❌ Sipariş `#{order['id']}` başarısız: {order.get('fail_reason') or 'bilinmiyor'}\n"
                        f"Bakiye iade edildi."
                    )
                except discord.HTTPException:
                    pass
            await mark_notified(order["id"])

    @order_notify.before_loop
    async def before_order_notify(self):
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

    bot = GTLockBot()
    api_task = asyncio.create_task(run_api())
    try:
        await bot.start(config.DISCORD_TOKEN)
    finally:
        api_task.cancel()


if __name__ == "__main__":
    asyncio.run(main())
