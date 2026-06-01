--[[
  GT Lock Shop — Lucifer (Luci) withdraw worker
]]

local API_URL = "http://127.0.0.1:8765"
local API_KEY = "change-me-to-a-long-random-secret"
local POLL_MS = 2500
-- Tüm sipariş (dünyaya gir + trade) en fazla 2 dakika
local ORDER_TIMEOUT_MS = 120000

local ITEM_WL = 242
local ITEM_DL = 1796
local ITEM_BGL = 7188

local bot = getBot()
bot.auto_reconnect = true
bot.auto_accept = true
bot.auto_ban = false -- yanlış banları önler; sadece isim eşleşmesi ile trade

local state = {
  order = nil,
  expected_norm = "",
  trade_netid = nil,
  trade_phase = "idle",
  trade_done = false,
  order_started_ms = 0,
}

local function log(msg)
  getBot():getLog():append("[GT-Shop] " .. tostring(msg))
  print("[GT-Shop] " .. tostring(msg))
end

-- Büyük/küçük harf duyarsız; renk kodu, backtick, boşluk temizlenir
local function norm_name(name)
  if not name then return "" end
  local s = removeColor(tostring(name))
  s = s:gsub("`", ""):gsub("[^%w]", ""):lower()
  return s
end

local function order_expired()
  if state.order_started_ms <= 0 then return false end
  return (os.clock() * 1000 - state.order_started_ms) >= ORDER_TIMEOUT_MS
end

local function player_matches_buyer(player)
  if not player or player.isLocalPlayer then return false end
  local expected = state.expected_norm
  if expected == "" then return false end
  if norm_name(player.name) == expected then return true end
  if player.altName and norm_name(player.altName) == expected then return true end
  return false
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

local function find_expected_player()
  local world = bot:getWorld()
  if not world then return nil end
  for _, p in pairs(world:getPlayers()) do
    if player_matches_buyer(p) then
      return p
    end
  end
  return nil
end

local function trade_add_item(item_id, count)
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

local function finish_order_fail(order, reason)
  log(reason)
  api_fail(order.id, reason)
  state.order = nil
  state.trade_phase = "idle"
  state.trade_done = false
  state.expected_norm = ""
  state.order_started_ms = 0
end

local function finish_order_success(order)
  api_complete(order.id)
  log("Order #" .. order.id .. " completed")
  state.order = nil
  state.trade_phase = "idle"
  state.trade_done = false
  state.expected_norm = ""
  state.order_started_ms = 0
end

local function run_order(order)
  state.order = order
  state.expected_norm = norm_name(order.growid)
  state.trade_phase = "waiting_player"
  state.trade_done = false
  state.trade_netid = nil
  state.order_started_ms = os.clock() * 1000

  local item_id = order.item_id or item_id_for_type(order.item_type)
  local qty = tonumber(order.quantity) or 1

  if state.expected_norm == "" then
    finish_order_fail(order, "invalid_growid")
    return
  end

  if inventory_count(item_id) < qty then
    finish_order_fail(order, "insufficient_bot_stock")
    return
  end

  log(string.format(
    "Order #%d → %s | buyer=%s (norm=%s) | 2min timeout",
    order.id, order.world_name, order.growid, state.expected_norm
  ))
  bot:warp(order.world_name)

  while state.order and not order_expired() do
    if not bot:isInWorld(order.world_name) then
      sleep(800)
    else
      if state.trade_done then
        finish_order_success(order)
        return
      end

      local buyer = find_expected_player()
      if buyer and state.trade_phase == "waiting_player" then
        state.trade_netid = buyer.netid
        state.trade_phase = "trading"
        log("Buyer matched: " .. removeColor(buyer.name))
        bot:wrenchPlayer(buyer.netid)
        sleep(1500)
        trade_add_item(item_id, qty)
        sleep(800)
        trade_lock()
        sleep(500)
        trade_accept()
      end

      sleep(500)
    end
  end

  if state.order then
    if state.trade_done then
      finish_order_success(order)
    else
      finish_order_fail(order, "order_timeout_2min")
    end
  end
end

function on_variantlist(variant, netid)
  if not state.order then return end
  local head = variant:get(0):getString()
  if head == "OnConsoleMessage" then
    local msg = variant:get(1):getString() or ""
    local low = msg:lower()
    if low:find("trade complete") or low:find("trade successful") or low:find("accepted the trade") then
      state.trade_done = true
      log("Trade complete detected")
    end
  elseif head == "OnForceTradeEnd" then
    if state.trade_phase == "trading" and not state.trade_done then
      log("Trade cancelled")
    end
  end
end

addEvent(Event.variantlist, on_variantlist)

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
