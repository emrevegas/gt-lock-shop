"""Balance and crypto deposit commands."""

import discord
from discord import app_commands
from discord.ext import commands

from database import db
from modules.crypto_deposit import check_user_deposits, extend_monitor, get_or_create_wallet


class Wallet(commands.Cog):
    def __init__(self, bot: commands.Bot):
        self.bot = bot

    @app_commands.command(name="balance", description="Bakiyeni göster")
    async def balance(self, interaction: discord.Interaction):
        bal = await db.get_balance(interaction.user.id)
        growid = await db.get_growid(interaction.user.id)
        g = f"`{growid}`" if growid else "_ayarlanmadı_"
        await interaction.response.send_message(
            f"💰 Bakiye: **{bal:.2f}**\n🎮 Kayıtlı GrowID: {g}",
            ephemeral=True,
        )

    @app_commands.command(name="setgrowid", description="GrowID kaydet")
    @app_commands.describe(growid="Growtopia kullanıcı adın")
    async def setgrowid(self, interaction: discord.Interaction, growid: str):
        gid = growid.strip()
        if len(gid) < 3 or len(gid) > 20:
            return await interaction.response.send_message(
                "Geçersiz GrowID.", ephemeral=True
            )
        await db.set_growid(interaction.user.id, gid)
        await interaction.response.send_message(
            f"✅ GrowID kaydedildi: `{gid}`", ephemeral=True
        )

    @app_commands.command(name="deposit", description="SOL / LTC yatırma adreslerin")
    async def deposit(self, interaction: discord.Interaction):
        try:
            wallet = await get_or_create_wallet(interaction.user.id)
            await extend_monitor(interaction.user.id)
        except RuntimeError as e:
            return await interaction.response.send_message(
                f"❌ {e}", ephemeral=True
            )

        sol = wallet["sol"]["address"]
        ltc = wallet["ltc"]["address"]
        embed = discord.Embed(
            title="💳 Kripto Yatırım",
            description=(
                "Aşağıdaki adreslere **sadece SOL veya LTC** gönderin.\n"
                "Onay sonrası bakiye otomatik yüklenir (2 dk tarama)."
            ),
            color=discord.Color.blue(),
        )
        embed.add_field(name="◎ Solana (SOL)", value=f"`{sol}`", inline=False)
        embed.add_field(name="Ł Litecoin (LTC)", value=f"`{ltc}`", inline=False)
        await interaction.response.send_message(embed=embed, ephemeral=True)

    @app_commands.command(name="checkdeposit", description="Yatırımları şimdi kontrol et")
    async def checkdeposit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True)
        try:
            hits = await check_user_deposits(interaction.user.id)
        except Exception as e:
            return await interaction.followup.send(f"❌ Hata: {e}", ephemeral=True)
        if not hits:
            return await interaction.followup.send(
                "Yeni yatırım bulunamadı.", ephemeral=True
            )
        lines = [
            f"**{h['chain']}** +{h['balance']:.2f} bakiye (~${h['usd']:.2f})"
            for h in hits
        ]
        await interaction.followup.send("\n".join(lines), ephemeral=True)


async def setup(bot: commands.Bot):
    await bot.add_cog(Wallet(bot))
