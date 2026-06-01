--[[
  GT Lock Shop — Lucifer (Luci) withdraw worker
]]

-- .env LUCI_API_KEY ile BİREBİR aynı olmalı
local API_URL = "http://127.0.0.1:8765"
local API_KEY = "BURAYA_ENV_LUCI_API_KEY"
local POLL_MS = 2500
local ORDER_TIMEOUT_MS = 120000
local WARP_RETRY_MS = 5000

local ITEM_WL = 242
local ITEM_DL = 1796
local ITEM_BGL = 7188

local bot = getBot()
bot.auto_reconnect = true
bot.auto_accept = true
bot.auto_ban = false

local state = {
  busy = false,
  order = nil,
  expected_norm = "",
  trade_phase = "idle",
  trade_done = false,
  order_started_ms = 0,
}

local function log(msg)
  getBot():getLog():append("[GT-Shop] " .. tostring(msg))
  print("[GT-Shop] " .. tostring(msg))
end

local function now_ms()
  return os.time() * 1000
end

local function norm_name(name)
  if not name then return "" end
  local s = removeColor(tostring(name))
  s = s:gsub("`", ""):gsub("[^%w]", ""):lower()
  return s
end

local function order_expired()
  if state.order_started_ms <= 0 then return false end
  return (now_ms() - state.order_started_ms) >= ORDER_TIMEOUT_MS
end

local function split_world(world_field)
  local w = string.upper(tostring(world_field or ""))
  local name, door = w, ""
  local pipe = w:find("|", 1, true)
  if pipe then
    name = w:sub(1, pipe - 1)
    door = w:sub(pipe + 1)
  end
  local colon = name:find(":", 1, true)
  if colon and door == "" then
    door = name:sub(colon + 1)
    name = name:sub(1, colon - 1)
  end
  return name, door
end

local function player_matches_buyer(player)
  if not player or player.isLocalPlayer then return false end
  local expected = state.expected_norm
  if expected == "" then return false end
  if norm_name(player.name) == expected then return true end
  if player.altName and norm_name(player.altName) == expected then return true end
  return false
end

local function http_request(method, path, json_body)
  local client = HttpClient.new()
  client.method = method
  client.url = API_URL .. path
  client.headers = {
    ["X-Api-Key"] = API_KEY,
    ["User-Agent"] = "Lucifer-GTShop",
    ["Accept"] = "application/json",
  }
  if json_body then
    client.headers["Content-Type"] = "application/json"
    client.content = json_body
  end

  local res = client:request()
  local net_err = res.error or 0
  if res.getError then
    local msg = res:getError()
    if msg and msg ~= "" then
      net_err = msg
    end
  end
  if net_err ~= 0 and net_err ~= "0" then
    log("HTTP network error: " .. tostring(net_err) .. " url=" .. client.url)
    return nil, "network:" .. tostring(net_err)
  end
  if res.status ~= 200 then
    log("HTTP " .. tostring(res.status) .. " " .. path .. " body=" .. tostring(res.body):sub(1, 120))
    return nil, "HTTP " .. tostring(res.status)
  end
  return res.body, nil
end

local function http_get(path)
  return http_request(Method.get, path, nil)
end

local function http_post(path, json_body)
  return http_request(Method.post, path, json_body)
end

local function parse_order_json(body)
  if not body or body == "" then return nil end
  body = body:gsub("%s+", "")
  if body:find('"order":null', 1, true) then
    return nil
  end
  if not body:find('"order":{', 1, true) then
    return nil
  end
  local id = body:match('"id":(%d+)')
  local growid = body:match('"growid":"([^"]+)"')
  local world = body:match('"world_name":"([^"]+)"')
  local item_type = body:match('"item_type":"([^"]+)"')
  local qty = body:match('"quantity":(%d+)')
  local item_id = body:match('"item_id":(%d+)')
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
  log("Parse fail body=" .. tostring(body):sub(1, 200))
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
  local order = parse_order_json(body)
  if order then
    log("API order #" .. order.id .. " world=" .. order.world_name)
  end
  return order
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

local function ensure_connected()
  if bot.status == BotStatus.online then
    return true
  end
  log("Bot not online (" .. tostring(bot.status) .. "), connecting...")
  bot:connect()
  for _ = 1, 45 do
    sleep(1000)
    if bot.status == BotStatus.online then
      log("Bot connected")
      return true
    end
  end
  log("Connect timeout, status=" .. tostring(bot.status))
  return false
end

local function current_world_name()
  if not bot:isInWorld() then return "" end
  local w = bot:getWorld()
  if w and w.name then
    return string.upper(tostring(w.name))
  end
  return ""
end

local function warp_to_world(world_field)
  local world_name, door_id = split_world(world_field)
  if world_name == "" then
    return false
  end
  for attempt = 1, 10 do
    if order_expired() then return false end
    log("Warp " .. attempt .. "/10 → " .. world_name .. (door_id ~= "" and ("|" .. door_id) or ""))
    if door_id ~= "" then
      bot:warp(world_name, door_id)
    else
      bot:warp(world_name)
    end
    sleep(WARP_RETRY_MS)
    if bot:isInWorld(world_name) then
      log("Entered world " .. world_name)
      return true
    end
    log("Not in target yet (now: " .. current_world_name() .. ", status=" .. tostring(bot.status) .. ")")
  end
  return false
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

local function clear_state()
  state.busy = false
  state.order = nil
  state.trade_phase = "idle"
  state.trade_done = false
  state.expected_norm = ""
  state.order_started_ms = 0
end

local function finish_order_fail(order, reason)
  log(reason)
  api_fail(order.id, reason)
  clear_state()
end

local function finish_order_success(order)
  api_complete(order.id)
  log("Order #" .. order.id .. " completed")
  clear_state()
end

local function run_order(order)
  state.busy = true
  state.order = order
  state.expected_norm = norm_name(order.growid)
  state.trade_phase = "waiting_player"
  state.trade_done = false
  state.order_started_ms = now_ms()

  local item_id = order.item_id or item_id_for_type(order.item_type)
  local qty = tonumber(order.quantity) or 1
  local world_name, _door = split_world(order.world_name)

  if state.expected_norm == "" then
    finish_order_fail(order, "invalid_growid")
    return
  end

  if inventory_count(item_id) < qty then
    finish_order_fail(order, "insufficient_bot_stock")
    return
  end

  if not ensure_connected() then
    finish_order_fail(order, "bot_offline")
    return
  end

  log(string.format(
    "Start order #%d → %s | buyer=%s",
    order.id, order.world_name, order.growid
  ))

  if not warp_to_world(order.world_name) then
    finish_order_fail(order, "warp_failed")
    return
  end

  while state.order and not order_expired() do
    if not bot:isInWorld(world_name) then
      if not warp_to_world(order.world_name) then
        sleep(1000)
      end
    else
      if state.trade_done then
        finish_order_success(order)
        return
      end

      local buyer = find_expected_player()
      if buyer and state.trade_phase == "waiting_player" then
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
    if low:find("trade complete", 1, true) or low:find("trade successful", 1, true) then
      state.trade_done = true
      log("Trade complete detected")
    end
  end
end

addEvent(Event.variantlist, on_variantlist)

log("Worker starting → " .. API_URL)

local health_body, health_err = http_get("/health")
if health_err then
  log("FATAL: /health failed: " .. health_err)
  log("bot.py bu makinede çalışıyor mu? Sadece: py bot.py")
else
  log("API health OK: " .. tostring(health_body):sub(1, 80))
end

local _, re_err = http_post("/api/orders/requeue-stuck", "{}")
if re_err then
  log("requeue-stuck warn: " .. re_err)
end

while true do
  if not state.busy then
    local order = fetch_next_order()
    if order then
      state.busy = true
      runThread(run_order, order)
    end
  end
  listenEvents(2)
  sleep(POLL_MS)
end
