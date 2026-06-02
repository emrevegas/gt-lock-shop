# GT Lock Shop

Discord bot + Lucifer (Luci) script ile **WL / DL / BGL** satışı. Kullanıcılar **Solana** ve **Litecoin** ile bakiye yükler, admin fiyatından kilit satın alır; Luci botu kullanıcının dünyasındaki **Display Box** (fg `1422`) üzerine item drop eder.

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
[Luci withdraw_worker.lua] → dünyaya git → Display Box (1422) bul → drop
                         → data/luci/results/{id}.json
[bot.py] → results okur → DB + Discord DM
```

## Kurulum

```bash
cd gt-lock-shop
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env
python bot.py
```

### Luci

1. `QUEUE_BASE` = `data/luci` tam yolu
2. `scripts/withdraw_worker.lua` Lucifer'de çalıştır

## Akış (satın alma)

1. `/buy` → GrowID + **Display Box'ın olduğu dünya**
2. Bot dünyaya girer, **fg 1422** (Display Box) arar
3. Kutunun üstüne / yanına gidip **drop** ile WL/DL/BGL bırakır
4. Discord DM ile onay

### Kullanıcı gereksinimleri

- Dünyada en az bir **Display Box** (item id `1422`)
- Botun kutuya yaklaşabildiği boş tile

## Lisans

MIT
