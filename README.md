# GT Lock Shop

Discord bot + Lucifer (Luci) script ile **WL / DL / BGL** satışı. Kullanıcılar **Solana** ve **Litecoin** ile bakiye yükler, admin fiyatından kilit satın alır; Luci botu rastgele withdraw dünyasında trade ile teslim eder.

## Oranlar

| Birim | Karşılık |
|-------|----------|
| 1 WL  | 1 WL     |
| 1 DL  | 100 WL   |
| 1 BGL | 100 DL   |

Ürünler: **World Lock** (242), **Diamond Lock** (1796), **Blue Gem Lock** (7188).

## Mimari (dosya kuyruğu)

```
[Kullanıcı Discord] → /buy → SQLite + data/luci/pending/{id}.json
[Luci withdraw_worker.lua] → read/write dosyalar → trade
                         → data/luci/results/{id}.json
[bot.py] → results okur → DB + Discord DM
```

Klasörler (`data/luci/`):

| Klasör | Kim yazar | İçerik |
|--------|-----------|--------|
| `pending/` | Discord bot | Yeni sipariş JSON |
| `processing/` | Luci | İşlenen sipariş |
| `results/` | Luci | `completed` veya `failed` |

- **bot.py** — Discord + dosya kuyruğu izleme (3 sn)
- **scripts/withdraw_worker.lua** — Luci trade (HTTP yok)

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

1. `python bot.py` çalışsın → `data/luci/QUEUE_PATH.txt` oluşur.
2. `scripts/withdraw_worker.lua` içinde `QUEUE_BASE` = bu klasörün tam yolu  
   Örn: `C:/Users/Administrator/Desktop/lock/data/luci`
3. Scripti Lucifer'de çalıştır; Log'da `Claimed file order #...` görünür.
4. `/setworlds` ile withdraw dünyalarını ayarla.

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
6. Luci `results/{id}.json` yazar → bot işler → Discord **DM**.

## Notlar

- Yatırım motoru flipbot’taki SOL/LTC HD cüzdan deseninin sadeleştirilmiş halidir.
- Trade paketleri sunucu sürümüne göre değişebilir; `withdraw_worker.lua` içindeki `trade_add_item` / `trade_lock` satırlarını Luci loglarından ince ayar yap.
- Üretimde `API_HOST=0.0.0.0` sadece güvenilir ağda; `LUCI_API_KEY` güçlü olsun.

## Lisans

MIT — kendi sorumluluğunuzda kullanın.
