# GT Lock Shop

Discord bot + Lucifer (Luci) script ile **WL / DL / BGL** satışı. Kullanıcılar **Solana** ve **Litecoin** ile bakiye yükler, admin fiyatından kilit satın alır; Luci botu rastgele withdraw dünyasında trade ile teslim eder.

## Oranlar

| Birim | Karşılık |
|-------|----------|
| 1 WL  | 1 WL     |
| 1 DL  | 100 WL   |
| 1 BGL | 100 DL   |

Ürünler: **World Lock** (242), **Diamond Lock** (1796), **Blue Gem Lock** (7188).

## Mimari

```
[Kullanıcı Discord] → /deposit (SOL/LTC) → bakiye
                    → /buy → sipariş kuyruğu (SQLite)
[Luci withdraw_worker.lua] → HTTP API → dünya + trade
[Discord DM] ← işlem onaylandı / başarısız
```

- **bot.py** — Discord + 2 dk crypto tarama + sipariş bildirimi
- **api_server.py** (aynı process) — Luci için `GET /api/orders/next`, `complete`, `fail`
- **scripts/withdraw_worker.lua** — Luci tarafı withdraw/trade

## Kurulum

```bash
cd gt-lock-shop
python -m venv .venv
.venv\Scripts\activate   # Windows
pip install -r requirements.txt
copy .env.example .env
# DISCORD_TOKEN, LUCI_API_KEY, CRYPTO_MNEMONIC, WITHDRAW_WORLDS doldur
python bot.py
```

### Luci

1. `scripts/withdraw_worker.lua` içinde `API_URL` ve `API_KEY` (.env ile aynı `LUCI_API_KEY`) ayarla.
2. Bot envanterinde yeterli WL/DL/BGL bulundur.
3. Withdraw dünyaları botun erişebildiği ve mümkünse sadece alıcı girişine açık dünyalar olsun (`/setworlds`).

## Discord komutları

| Komut | Açıklama |
|-------|----------|
| `/balance` | Bakiye + GrowID |
| `/setgrowid` | GrowID kaydet |
| `/deposit` | SOL/LTC adresleri |
| `/checkdeposit` | Manuel tarama |
| `/prices` | Fiyat listesi |
| `/buy` | WL/DL/BGL satın al |
| `/setprices` | Admin fiyat |
| `/setworlds` | Admin withdraw dünyaları |
| `/addbalance` | Admin manuel bakiye |

## API (Luci)

Header: `X-Api-Key: <LUCI_API_KEY>`

- `GET /api/orders/next` — sıradaki siparişi `processing` yapar
- `POST /api/orders/complete` — `{"order_id": 1}`
- `POST /api/orders/fail` — `{"order_id": 1, "reason": "..."}`

## Akış (satın alma)

1. Kullanıcı `/buy` → miktar → GrowID (veya kayıtlı GrowID).
2. Sistem 5 dünyadan birini rastgele atar.
3. Luci dünyaya girer; GrowID eşleşmeyen oyuncular için ban/kick dener (`auto_ban`).
4. Eşleşen oyuncuya trade → miktarı koyar → lock/accept (`auto_accept` bot tarafında).
5. Kullanıcı trade + onay ekranını kabul eder.
6. Script `complete` çağırır → Discord **DM: işlem onaylandı**.

## Notlar

- Yatırım motoru flipbot’taki SOL/LTC HD cüzdan deseninin sadeleştirilmiş halidir.
- Trade paketleri sunucu sürümüne göre değişebilir; `withdraw_worker.lua` içindeki `trade_add_item` / `trade_lock` satırlarını Luci loglarından ince ayar yap.
- Üretimde `API_HOST=0.0.0.0` sadece güvenilir ağda; `LUCI_API_KEY` güçlü olsun.

## Lisans

MIT — kendi sorumluluğunuzda kullanın.
