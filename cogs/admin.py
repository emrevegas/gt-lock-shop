"""Admin: prices, withdraw worlds, orders."""

import discord
from discord import app_commands
from discord.ext import commands

import config
from database import db
from modules import orders
from modules.shop import DISPLAY, set_prices

# GUILD_ID varsa komutlar anında bu sunucuda görünür (global sync saatler sürebilir)
_ADMIN_GUILDS = (
    [discord.Object(id=config.GUILD_ID)] if config.GUILD_ID else None
)


def is_admin(interaction: discord.Interaction) -> bool:
    if not interaction.guild:
        return False
    if interaction.user.guild_permissions.administrator:
        return True
    if not config.ADMIN_ROLE_IDS:
        return False
    roles = {r.id for r in interaction.user.roles}
    return bool(roles & set(config.ADMIN_ROLE_IDS))


class Admin(commands.Cog):
    def __init__(self, bot: commands.Bot):
        self.bot = bot

    @app_commands.command(name="orderdebug", description="[Admin] DB + API + sipariş durumu")
    @app_commands.guilds(*(_ADMIN_GUILDS or []))
    async def orderdebug(self, interaction: discord.Interaction):
        if not is_admin(interaction):
            return await interaction.response.send_message("Yetkisiz.", ephemeral=True)
        counts = await orders.count_orders_by_status()
        active = await orders.list_active_orders(limit=10)
        lines = [
            f"**DB:** `{config.DB_PATH.resolve()}`",
            f"**API:** `http://{config.API_HOST}:{config.API_PORT}`",
            f"**LUCI_API_KEY:** {'ayarlı' if config.LUCI_API_KEY else '❌ BOŞ'}",
            f"**Durumlar:** `{counts}`",
        ]
        if active:
            lines.append("**Aktif siparişler:**")
            for o in active:
                lines.append(
                    f"• `#{o['id']}` {o['status']} — {o['growid']} @ {o['world_name']}"
                )
        else:
            lines.append("_Aktif (pending/processing) sipariş yok._")
        lines.append(
            "\nLuci `withdraw_worker.lua` çalışıyor olmalı.\n"
            "Konsolda `API GET /api/orders/next` satırları görünmeli."
        )
        await interaction.response.send_message("\n".join(lines), ephemeral=True)

    @app_commands.command(name="synccommands", description="[Admin] Slash komutları Discord'a yenile")
    @app_commands.guilds(*(_ADMIN_GUILDS or []))
    async def synccommands(self, interaction: discord.Interaction):
        if not is_admin(interaction):
            return await interaction.response.send_message("Yetkisiz.", ephemeral=True)
        await interaction.response.defer(ephemeral=True)
        names: list[str] = []
        if config.GUILD_ID:
            guild = discord.Object(id=config.GUILD_ID)
            self.bot.tree.copy_global_to(guild=guild)
            synced = await self.bot.tree.sync(guild=guild)
            names = [c.name for c in synced]
            msg = f"✅ Sunucu sync (`{config.GUILD_ID}`): **{len(synced)}** komut\n`{', '.join(names)}`"
        else:
            synced = await self.bot.tree.sync()
            names = [c.name for c in synced]
            msg = (
                f"✅ Global sync: **{len(synced)}** komut (Discord'da görünmesi ~1 saat sürebilir)\n"
                f"`{', '.join(names)}`\n"
                f"`.env` içine `GUILD_ID` ekle → anında sync."
            )
        await interaction.followup.send(msg, ephemeral=True)

    @app_commands.command(name="listorders", description="[Admin] Bekleyen siparişleri listele")
    @app_commands.describe(limit="Max satır (1-50)")
    @app_commands.guilds(*(_ADMIN_GUILDS or []))
    async def listorders(self, interaction: discord.Interaction, limit: app_commands.Range[int, 1, 50] = 15):
        if not is_admin(interaction):
            return await interaction.response.send_message("Yetkisiz.", ephemeral=True)
        active = await orders.list_active_orders(limit=limit)
        counts = await orders.count_orders_by_status()
        if not active:
            return await interaction.response.send_message(
                f"Aktif sipariş yok.\nDurumlar: `{counts}`",
                ephemeral=True,
            )
        lines = []
        for o in active:
            lines.append(
                f"`#{o['id']}` **{o['status']}** — <@{o['user_id']}> "
                f"`{o['growid']}` — {o['quantity']}x {DISPLAY.get(o['item_type'], o['item_type'])} "
                f"@ `{o['world_name']}`"
            )
        await interaction.response.send_message(
            f"**Aktif siparişler** ({len(active)})\n" + "\n".join(lines) + f"\n\nDurumlar: `{counts}`",
            ephemeral=True,
        )

    @app_commands.command(name="cancelorder", description="[Admin] Tek sipariş iptal (bakiye iade)")
    @app_commands.describe(siparis_id="Sipariş numarası (#id)")
    @app_commands.guilds(*(_ADMIN_GUILDS or []))
    async def cancelorder(self, interaction: discord.Interaction, siparis_id: int):
        if not is_admin(interaction):
            return await interaction.response.send_message("Yetkisiz.", ephemeral=True)
        updated = await orders.cancel_order_by_id(siparis_id)
        if not updated:
            return await interaction.response.send_message(
                f"Sipariş `#{siparis_id}` bulunamadı veya zaten bitmiş (pending/processing değil).",
                ephemeral=True,
            )
        await interaction.response.send_message(
            f"✅ Sipariş `#{siparis_id}` iptal edildi. İade: **{float(updated['price_paid']):.2f}**",
            ephemeral=True,
        )

    @app_commands.command(
        name="cancelallorders",
        description="[Admin] Tüm bekleyen/işlenen siparişleri iptal et (bakiye iade)",
    )
    @app_commands.describe(onay="Onaylamak için EVET yaz")
    @app_commands.guilds(*(_ADMIN_GUILDS or []))
    async def cancelallorders(self, interaction: discord.Interaction, onay: str):
        if not is_admin(interaction):
            return await interaction.response.send_message("Yetkisiz.", ephemeral=True)
        if onay.strip().upper() != "EVET":
            return await interaction.response.send_message(
                "⚠️ Tüm **pending** ve **processing** siparişler iptal edilir.\n"
                "Onaylamak için: `onay:EVET`",
                ephemeral=True,
            )

        result = await orders.cancel_all_active_orders()
        counts = await orders.count_orders_by_status()
        if result["cancelled"] == 0:
            return await interaction.response.send_message(
                f"İptal edilecek aktif sipariş yok.\nDurumlar: `{counts}`",
                ephemeral=True,
            )
        await interaction.response.send_message(
            f"✅ **{result['cancelled']}** sipariş iptal edildi.\n"
            f"💰 Toplam iade: **{result['refunded_total']:.2f}** "
            f"({result['users_refunded']} kullanıcı)\n"
            f"Durumlar: `{counts}`",
            ephemeral=True,
        )

    @app_commands.command(name="setprices", description="[Admin] WL/DL/BGL fiyatları")
    @app_commands.describe(wl="1 WL fiyatı", dl="1 DL fiyatı", bgl="1 BGL fiyatı")
    @app_commands.guilds(*(_ADMIN_GUILDS or []))
    async def setprices(
        self,
        interaction: discord.Interaction,
        wl: float,
        dl: float,
        bgl: float,
    ):
        if not is_admin(interaction):
            return await interaction.response.send_message("Yetkisiz.", ephemeral=True)
        if wl <= 0 or dl <= 0 or bgl <= 0:
            return await interaction.response.send_message(
                "Fiyatlar pozitif olmalı.", ephemeral=True
            )
        p = await set_prices(wl, dl, bgl)
        await interaction.response.send_message(
            f"✅ Fiyatlar güncellendi: WL={p['wl']}, DL={p['dl']}, BGL={p['bgl']}",
            ephemeral=True,
        )

    @app_commands.command(name="setworlds", description="[Admin] Withdraw dünyaları (virgülle)")
    @app_commands.describe(worlds="Örn: SHOP1,SHOP2,SHOP3")
    @app_commands.guilds(*(_ADMIN_GUILDS or []))
    async def setworlds(self, interaction: discord.Interaction, worlds: str):
        if not is_admin(interaction):
            return await interaction.response.send_message("Yetkisiz.", ephemeral=True)
        lst = [w.strip().upper() for w in worlds.split(",") if w.strip()]
        if len(lst) < 1:
            return await interaction.response.send_message(
                "En az 1 dünya gerekli.", ephemeral=True
            )
        saved = await orders.set_withdraw_worlds(lst)
        await interaction.response.send_message(
            f"✅ Withdraw dünyaları: {', '.join(saved)}", ephemeral=True
        )

    @app_commands.command(name="requeueorders", description="[Admin] Processing → pending")
    @app_commands.guilds(*(_ADMIN_GUILDS or []))
    async def requeueorders(self, interaction: discord.Interaction):
        if not is_admin(interaction):
            return await interaction.response.send_message("Yetkisiz.", ephemeral=True)
        n = await orders.release_all_processing()
        counts = await orders.count_orders_by_status()
        await interaction.response.send_message(
            f"✅ {n} sipariş yeniden `pending` yapıldı.\nDurumlar: `{counts}`",
            ephemeral=True,
        )

    @app_commands.command(name="addbalance", description="[Admin] Kullanıcıya bakiye ekle")
    @app_commands.guilds(*(_ADMIN_GUILDS or []))
    async def addbalance(
        self,
        interaction: discord.Interaction,
        user: discord.Member,
        amount: float,
    ):
        if not is_admin(interaction):
            return await interaction.response.send_message("Yetkisiz.", ephemeral=True)
        if amount <= 0:
            return await interaction.response.send_message(
                "Pozitif miktar gir.", ephemeral=True
            )
        new = await db.add_balance(user.id, amount)
        await interaction.response.send_message(
            f"✅ {user.mention} +{amount:.2f} → bakiye **{new:.2f}**",
            ephemeral=True,
        )


async def setup(bot: commands.Bot):
    await bot.add_cog(Admin(bot))
