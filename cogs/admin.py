"""Admin: prices, withdraw worlds."""

import discord
from discord import app_commands
from discord.ext import commands

import config
from database import db
from modules import orders
from modules.shop import set_prices


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

    @app_commands.command(name="setprices", description="[Admin] WL/DL/BGL fiyatları")
    @app_commands.describe(wl="1 WL fiyatı", dl="1 DL fiyatı", bgl="1 BGL fiyatı")
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

    @app_commands.command(name="setworlds", description="[Admin] 5 withdraw dünyası (virgülle)")
    @app_commands.describe(worlds="Örn: SHOP1,SHOP2,SHOP3,SHOP4,SHOP5")
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

    @app_commands.command(name="addbalance", description="[Admin] Kullanıcıya bakiye ekle")
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
