--[[
  Luci API bağlantı testi — sadece HTTP dener, trade yok.
  Lucifer'de çalıştır; Log sekmesinde [GT-Shop] satırlarını oku.
]]

local API_URL = "http://127.0.0.1:8765"
local API_KEY = "POWERFULSECRET"  -- .env LUCI_API_KEY ile aynı olmalı

local function log(msg)
  print("[GT-Shop-TEST] " .. tostring(msg))
  pcall(function()
    getBot():getLog():append("[GT-Shop-TEST] " .. tostring(msg))
  end)
end

local function request(method, path, body)
  local client = HttpClient.new()
  client.method = method
  client.url = API_URL .. path
  client.headers = {
    ["X-Api-Key"] = API_KEY,
    ["User-Agent"] = "Lucifer-GTShop-Test",
    ["Accept"] = "application/json",
  }
  if body then
    client.headers["Content-Type"] = "application/json"
    client.content = body
  end

  log(">>> " .. tostring(method) .. " " .. client.url)
  local res = client:request()
  local err = 0
  if res.getError then
    err = res:getError() or res.error or 0
  else
    err = res.error or 0
  end
  log("status=" .. tostring(res.status) .. " neterr=" .. tostring(err))
  if err ~= 0 and res.getError then
    log("getError=" .. tostring(res.getError()))
  end
  local preview = (res.body or ""):sub(1, 300)
  log("body=" .. preview)
  return res
end

log("Test başlıyor API_URL=" .. API_URL)

local h = request(Method.get, "/health", nil)
if not h or h.status ~= 200 then
  log("FAIL /health — bot.py çalışıyor mu? Port 8765 açık mı?")
  return
end
log("OK /health")

local p = request(Method.get, "/api/orders/pending", nil)
if p and p.status == 401 then
  log("FAIL 401 — API_KEY yanlış (.env LUCI_API_KEY ile lua aynı olmalı)")
  return
end
if p and p.status == 200 then
  log("OK /api/orders/pending — API ve key doğru")
else
  log("FAIL pending endpoint")
end

log("Test bitti. withdraw_worker.lua çalıştırabilirsin.")
