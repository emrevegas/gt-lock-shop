# GT Lock Shop

Discord bot + Lucifer (Luci) script ile **WL / DL / BGL** satışı. Kullanıcılar **Solana** ve **Litecoin** ile bakiye yükler, admin fiyatından kilit satın alır; Luci botu kullanıcının dünyasındaki **bağış kutusuna** (Donation Box) teslim eder.

## Oranlar

| Birim | Karşılık |
|-------|----------|
| 1 WL  | 1 WL     |
| 1 DL  | 100 WL   |
| 1 BGL | 100 DL   |

Ürünler: **World Lock** (242), **Diamond Lock** (1796), **Blue Gem Lock** (7188).

## Mimari (dosya kuyruğu)

```
[Kullanıcı Discord] → /buy (GrowID + dünya) → SQLite + data/luci/pending/{id}.json
[Luci withdraw_worker.lua] → dünyaya git → donation box bul → item bırak
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
- **scripts/withdraw_worker.lua** — Luci donation box teslimatı (HTTP yok)

## Kurulum

```bash
cd gt-lock-shop
python -m venv .venv
.venv\Scripts\activate   # Windows
pip install -r requirements.txt
copy .env.example .env
# DISCORD_TOKEN, CRYPTO_MNEMONIC doldur
python bot.py
```

### Luci

1. `python bot.py` çalışsın → `data/luci/QUEUE_PATH.txt` oluşur.
2. `scripts/withdraw_worker.lua` içinde `QUEUE_BASE` = bu klasörün tam yolu  
   Örn: `C:/Users/Administrator/Desktop/lock/data/luci`
3. Scripti Lucifer'de çalıştır; Log'da `Claimed pending #...` görünür.

## Discord komutları

| Komut | Açıklama |
|-------|----------|
| `/balance` | Bakiye + GrowID |
| `/setgrowid` | GrowID kaydet |
| `/deposit` | SOL/LTC adresleri |
| `/checkdeposit` | Manuel tarama |
| `/prices` | Fiyat listesi |
| `/buy` | WL/DL/BGL satın al (GrowID + dünya adı) |
| `/setprices` | Admin fiyat |
| `/listorders` | Admin aktif siparişler |
| `/addbalance` | Admin manuel bakiye |

## Akış (satın alma)

1. Kullanıcı `/buy` → miktar → GrowID + **bağış kutusunun olduğu dünya** adı.
2. Luci botu o dünyaya girer.
3. Bot erişebildiği bir **Donation Box** arar (`hasAccess`).
4. Bulursa gerekli WL/DL/BGL miktarını kutuya bırakır.
5. Luci `results/{id}.json` yazar → bot işler → Discord **DM**.

### Kullanıcı için gereksinimler

- Dünyada en az bir **Donation Box** olmalı.
- Botun kutuya ulaşabildiği bir alan olmalı (kilit/erişim).
- Kapı varsa dünya adını `MYWORLD|DOORID` formatında yazabilirsin.

## Notlar

- Yatırım motoru flipbot’taki SOL/LTC HD cüzdan deseninin sadeleştirilmiş halidir.
- Donation dialog paketleri sunucu sürümüne göre değişebilir; loglarda `Donation dialog:` satırını kontrol et.

## Lisans

MIT — kendi sorumluluğunuzda kullanın.
