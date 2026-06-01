"""Buy WL / DL / BGL with balance."""

import discord
from discord import app_commands
from discord.ext import commands

from database import db
from modules import orders
from modules.shop import DISPLAY, ItemType, order_total


class GrowidModal(discord.ui.Modal, title="GrowID"):
    def __init__(self, parent: "BuyConfirmView"):
        super().__init__()
        self.parent = parent
        self.growid_input = discord.ui.TextInput(
            label="GrowID",
            placeholder="Oyun içi kullanıcı adın",
            min_length=3,
            max_length=20,
        )
        self.add_item(self.growid_input)

    async def on_submit(self, interaction: discord.Interaction):
        self.parent.growid = self.growid_input.value.strip()
        await interaction.response.defer()
        await self.parent.finish_purchase(interaction)


class BuyConfirmView(discord.ui.View):
    def __init__(
        self,
        user_id: int,
        item_type: ItemType,
        quantity: int,
        total: float,
    ):
        super().__init__(timeout=120)
        self.user_id = user_id
        self.item_type = item_type
        self.quantity = quantity
        self.total = total
        self.growid: str | None = None

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user_id:
            await interaction.response.send_message(
                "Bu menü sana ait değil.", ephemeral=True
            )
            return False
        return True

    @discord.ui.button(label="GrowID gir & Satın al", style=discord.ButtonStyle.green)
    async def confirm(self, interaction: discord.Interaction, button: discord.ui.Button):
        saved = await db.get_growid(self.user_id)
        if saved:
            self.growid = saved
            await interaction.response.defer()
            await self.finish_purchase(interaction)
        else:
            await interaction.response.send_modal(GrowidModal(self))

    async def finish_purchase(self, interaction: discord.Interaction):
        if not self.growid:
            return
        if not await db.deduct_balance(self.user_id, self.total):
            msg = "Yetersiz bakiye."
            if interaction.response.is_done():
                return await interaction.followup.send(msg, ephemeral=True)
            return await interaction.response.send_message(msg, ephemeral=True)

        try:
            order = await orders.create_order(
                self.user_id,
                self.growid,
                self.item_type,
                self.quantity,
                self.total,
            )
        except ValueError as e:
            await db.add_balance(self.user_id, self.total)
            msg = f"❌ Sipariş oluşturulamadı: {e}"
            if interaction.response.is_done():
                return await interaction.followup.send(msg, ephemeral=True)
            return await interaction.response.send_message(msg, ephemeral=True)

        await db.set_growid(self.user_id, self.growid)
        text = (
            f"🛒 Sipariş **#{order['id']}** oluşturuldu.\n"
            f"**{self.quantity}x** {DISPLAY[self.item_type]}\n"
            f"GrowID: `{self.growid}`\n"
            f"Dünya: `{order['world_name']}` (bot seni bekliyor)\n\n"
            f"Luci botu trade isteği atacak; kabul edip onay ekranını da onayla."
        )
        for child in self.children:
            child.disabled = True
        if interaction.response.is_done():
            await interaction.edit_original_response(content=text, view=self)
        else:
            await interaction.response.edit_message(content=text, view=self)


class Shop(commands.Cog):
    def __init__(self, bot: commands.Bot):
        self.bot = bot

    @app_commands.command(name="buy", description="WL / DL / BGL satın al")
    @app_commands.describe(
        item="Kilit türü",
        quantity="Adet",
    )
    @app_commands.choices(
        item=[
            app_commands.Choice(name="World Lock (WL)", value="wl"),
            app_commands.Choice(name="Diamond Lock (DL)", value="dl"),
            app_commands.Choice(name="Blue Gem Lock (BGL)", value="bgl"),
        ]
    )
    async def buy(
        self,
        interaction: discord.Interaction,
        item: app_commands.Choice[str],
        quantity: app_commands.Range[int, 1, 200],
    ):
        item_type: ItemType = item.value  # type: ignore
        total = await order_total(item_type, quantity)
        bal = await db.get_balance(interaction.user.id)
        if bal < total:
            return await interaction.response.send_message(
                f"Yetersiz bakiye. Gerekli: **{total:.2f}**, senin: **{bal:.2f}**",
                ephemeral=True,
            )

        view = BuyConfirmView(interaction.user.id, item_type, quantity, total)
        await interaction.response.send_message(
            f"**{quantity}x** {DISPLAY[item_type]} — Toplam: **{total:.2f}**\n"
            f"Onayla ve GrowID gir.",
            view=view,
            ephemeral=True,
        )

    @app_commands.command(name="prices", description="Güncel fiyat listesi")
    async def prices(self, interaction: discord.Interaction):
        from modules.shop import get_prices

        p = await get_prices()
        await interaction.response.send_message(
            f"📋 Fiyatlar (bakiye birimi):\n"
            f"• WL: **{p['wl']:.2f}**\n"
            f"• DL: **{p['dl']:.2f}** (1 DL = 100 WL)\n"
            f"• BGL: **{p['bgl']:.2f}** (1 BGL = 100 DL)\n",
            ephemeral=True,
        )


async def setup(bot: commands.Bot):
    await bot.add_cog(Shop(bot))
