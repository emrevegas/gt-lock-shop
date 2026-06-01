--[[
  GT Lock Shop — Lucifer (Luci) withdraw worker
  Discord bot API ile sipariş alır, dünyaya girer, eşleşen GrowID'ye trade atar.

  Kurulum:
  1. Discord bot + API çalışıyor olmalı (bot.py, LUCI_API_KEY)
  2. Bu dosyayı Luci'de bot scripti olarak çalıştır
  3. API_URL ve API_KEY değerlerini düzenle
]]

local API_URL = "http://127.0.0.1:8765"
local API_KEY = "change-me-to-a-long-random-secret"
local POLL_MS = 2500
local ENTER_WORLD_TIMEOUT_MS = 120000
local TRADE_TIMEOUT_MS = 180000

-- Growtopia item IDs
local ITEM_WL = 242
local ITEM_DL = 1796
local ITEM_BGL = 7188

local bot = getBot()
bot.auto_reconnect = true
bot.auto_accept = true
bot.auto_ban = true

local state = {
  order = nil,
  expected_growid = "",
  trade_netid = nil,
  trade_phase = "idle", -- idle | waiting_player | trading | done
  items_placed = false,
}

local function log(msg)
  getBot():getLog():append("[GT-Shop] " .. tostring(msg))
  print("[GT-Shop] " .. tostring(msg))
end

local function norm_name(name)
  if not name then return "" end
  return string.lower(removeColor(name)):gsub("%s+", "")
end

local function http_get(path)
  local client = HttpClient.new()
  client.method = Method.get
  client.url = API_URL .. path
  client.headers = client.headers or {}
  client.headers["X-Api-Key"] = API_KEY
  local res = client:request()
  if res.status ~= 200 then
    return nil, "HTTP " .. tostring(res.status) .. " " .. (res.body or "")
  end
  return res.body, nil
end

local function http_post(path, json_body)
  local client = HttpClient.new()
  client.method = Method.post
  client.url = API_URL .. path
  client.headers = client.headers or {}
  client.headers["X-Api-Key"] = API_KEY
  client.headers["Content-Type"] = "application/json"
  client.content = json_body
  local res = client:request()
  if res.status ~= 200 then
    return nil, "HTTP " .. tostring(res.status)
  end
  return res.body, nil
end

-- Minimal JSON helpers (order fields only)
local function parse_order_json(body)
  if not body or body == "" then return nil end
  if not body:find('"order"%s*:%s*null') then
    local id = body:match('"id"%s*:%s*(%d+)')
    local growid = body:match('"growid"%s*:"([^"]+)"')
    local world = body:match('"world_name"%s*:"([^"]+)"')
    local item_type = body:match('"item_type"%s*:"([^"]+)"')
    local qty = body:match('"quantity"%s*:(%d+)')
    local item_id = body:match('"item_id"%s*:(%d+)')
    if id and growid and world then
      return {
        id = tonumber(id),
        growid = growid,
        world_name = world,
        item_type = item_type or "wl",
        quantity = tonumber(qty) or 1,
        item_id = tonumber(item_id) or ITEM_WL,
      }
    end
  end
  return nil
end

local function item_id_for_type(t)
  if t == "dl" then return ITEM_DL end
  if t == "bgl" then return ITEM_BGL end
  return ITEM_WL
end

local function fetch_next_order()
  local body, err = http_get("/api/orders/next")
  if err then
    log("API error: " .. err)
    return nil
  end
  return parse_order_json(body)
end

local function api_complete(order_id)
  http_post("/api/orders/complete", string.format('{"order_id":%d}', order_id))
end

local function api_fail(order_id, reason)
  local safe = (reason or "fail"):gsub('"', "'")
  http_post("/api/orders/fail", string.format('{"order_id":%d,"reason":"%s"}', order_id, safe))
end

local function inventory_count(item_id)
  local inv = bot:getInventory()
  if not inv then return 0 end
  return inv:findItem(item_id) or 0
end

local function kick_or_ban_intruders()
  local world = bot:getWorld()
  if not world then return end
  local expected = norm_name(state.expected_growid)
  for _, p in pairs(world:getPlayers()) do
    if not p.isLocalPlayer then
      local n = norm_name(p.name)
      if n ~= expected then
        log("Intruder: " .. removeColor(p.name) .. " — auto_ban enabled")
        -- Luci auto_ban + wrench ban fallback
        bot:wrenchPlayer(p.netid)
        sleep(400)
        bot:sendPacket(2, "action|dialog_return\ndialog_name|popup\nbuttonClicked|ban\n")
        sleep(300)
      end
    end
  end
end

local function find_expected_player()
  local world = bot:getWorld()
  if not world then return nil end
  local expected = norm_name(state.expected_growid)
  for _, p in pairs(world:getPlayers()) do
    if not p.isLocalPlayer and norm_name(p.name) == expected then
      return p
    end
  end
  return nil
end

local function trade_add_item(item_id, count)
  -- Trade penceresine item ekle (Growtopia trade dialog)
  for i = 1, count do
    bot:sendPacket(2, string.format(
      "action|dialog_return\ndialog_name|trade_item\nitemID|%d\ncount|1\n",
      item_id
    ))
    sleep(120)
  end
end

local function trade_lock()
  bot:sendPacket(2, "action|dialog_return\ndialog_name|trade_confirm\nbuttonClicked|lock\n")
end

local function trade_accept()
  bot:sendPacket(2, "action|dialog_return\ndialog_name|trade_confirm\nbuttonClicked|accept\n")
end

local function run_order(order)
  state.order = order
  state.expected_growid = order.growid
  state.trade_phase = "waiting_player"
  state.items_placed = false
  state.trade_netid = nil

  local item_id = order.item_id or item_id_for_type(order.item_type)
  local qty = tonumber(order.quantity) or 1

  if inventory_count(item_id) < qty then
    log("Not enough items in inventory")
    api_fail(order.id, "insufficient_bot_stock")
    state.order = nil
    return
  end

  log(string.format("Order #%d → warp %s for %s x%d", order.id, order.world_name, order.growid, qty))
  bot:warp(order.world_name)

  local deadline = os.clock() * 1000 + ENTER_WORLD_TIMEOUT_MS
  while os.clock() * 1000 < deadline do
    if not bot:isInWorld(order.world_name) then
      sleep(1000)
    else
      kick_or_ban_intruders()
      local buyer = find_expected_player()
      if buyer then
        state.trade_netid = buyer.netid
        state.trade_phase = "trading"
        log("Buyer found, requesting trade: " .. removeColor(buyer.name))
        bot:wrenchPlayer(buyer.netid)
        sleep(1500)

        trade_add_item(item_id, qty)
        sleep(800)
        trade_lock()
        sleep(500)
        trade_accept()
        state.items_placed = true

        local trade_deadline = os.clock() * 1000 + TRADE_TIMEOUT_MS
        while os.clock() * 1000 < trade_deadline do
          sleep(500)
          kick_or_ban_intruders()
        end

        api_complete(order.id)
        log("Order completed (API notified)")
        state.order = nil
        state.trade_phase = "idle"
        return
      end
      sleep(800)
    end
  end

  log("Timeout waiting for buyer")
  api_fail(order.id, "buyer_timeout")
  state.order = nil
  state.trade_phase = "idle"
end

-- Trade tamamlandığında konsol / variant ile doğrula
function on_variantlist(variant, netid)
  if not state.order then return end
  local head = variant:get(0):getString()
  if head == "OnTradeStatus" then
    local payload = variant:get(4):getString() or ""
    if payload:find("accepted|1") and payload:find("locked|1") then
      -- Her iki taraf kilitlediğinde trade tamamlanır; bazı sürümlerde OnDialogRequest gelir
      log("Trade status: locked+accepted detected")
    end
  elseif head == "OnConsoleMessage" then
    local msg = variant:get(1):getString() or ""
    if msg:find("Trade complete") or msg:find("trade complete") then
      if state.order then
        api_complete(state.order.id)
        log("Trade complete (console)")
        state.order = nil
      end
    end
  elseif head == "OnForceTradeEnd" then
    if state.order and state.trade_phase == "trading" then
      log("Trade force-ended")
    end
  end
end

addEvent(Event.variantlist, on_variantlist)

-- Ana döngü: API'den sipariş çek
while true do
  if not state.order then
    local order = fetch_next_order()
    if order then
      runThread(run_order, order)
    end
  end
  listenEvents(2)
  sleep(POLL_MS)
end
