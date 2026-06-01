--[[
  GT Lock Shop — Luci withdraw (DOSYA kuyruğu, API yok)
  Kuyruk klasörü: data/luci/QUEUE_PATH.txt içinde yazar (bot.py ile aynı proje)
]]

-- Tam yol: bot'un oluşturduğu data/luci/QUEUE_PATH.txt dosyasını oku veya elle yaz
local QUEUE_BASE = "C:/Users/Administrator/Desktop/lock/data/luci"
local POLL_MS = 2500
local ORDER_TIMEOUT_MS = 120000
local WARP_RETRY_MS = 5000

local ITEM_WL = 242
local ITEM_DL = 1796
local ITEM_BGL = 7188

local PENDING_DIR = QUEUE_BASE .. "/pending"
local PROCESSING_DIR = QUEUE_BASE .. "/processing"
local RESULTS_DIR = QUEUE_BASE .. "/results"
local INDEX_FILE = QUEUE_BASE .. "/pending_index.txt"

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

local function try_load_queue_base()
  local ok, path = pcall(function()
    return read(QUEUE_BASE .. "/QUEUE_PATH.txt")
  end)
  if ok and path and path ~= "" then
    path = path:gsub("%s+", ""):gsub("\\", "/")
    if path:sub(-1) == "/" then path = path:sub(1, -2) end
    return path
  end
  return QUEUE_BASE
end

local function now_ms()
  return os.time() * 1000
end

local function norm_name(name)
  if not name then return "" end
  local s = removeColor(tostring(name))
  return s:gsub("`", ""):gsub("[^%w]", ""):lower()
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
  return name, door
end

local function player_matches_buyer(player)
  if not player or player.isLocalPlayer then return false end
  local expected = state.expected_norm
  if norm_name(player.name) == expected then return true end
  if player.altName and norm_name(player.altName) == expected then return true end
  return false
end

local function parse_order_json(body)
  if not body or body == "" then return nil end
  body = body:gsub("%s+", "")
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
  return nil
end

local function item_id_for_type(t)
  if t == "dl" then return ITEM_DL end
  if t == "bgl" then return ITEM_BGL end
  return ITEM_WL
end

local function write_result(order_id, status, reason)
  local safe = (reason or ""):gsub('"', "'")
  local json = string.format(
    '{"id":%d,"status":"%s","reason":"%s","at":%d}',
    order_id, status, safe, os.time()
  )
  write(RESULTS_DIR .. "/" .. order_id .. ".json", json)
  log("Wrote result #" .. order_id .. " " .. status)
end

local function read_index_ids()
  local raw = read(INDEX_FILE)
  if not raw or raw == "" then return {} end
  local ids = {}
  for line in raw:gmatch("[^\r\n]+") do
    local n = tonumber(line:match("^(%d+)"))
    if n then ids[#ids + 1] = n end
  end
  return ids
end

local function write_index_ids(ids)
  if #ids == 0 then
    write(INDEX_FILE, "")
    return
  end
  local lines = {}
  for i = 1, #ids do lines[i] = tostring(ids[i]) end
  write(INDEX_FILE, table.concat(lines, "\n") .. "\n")
end

local function claim_next_order()
  local ids = read_index_ids()
  if #ids == 0 then return nil end

  local id = ids[1]
  local pending_path = PENDING_DIR .. "/" .. id .. ".json"
  local body = read(pending_path)
  if not body or body == "" then
    log("Missing pending file #" .. id .. ", skipping")
    local rest = {}
    for i = 2, #ids do rest[#rest + 1] = ids[i] end
    write_index_ids(rest)
    return nil
  end

  local order = parse_order_json(body)
  if not order then
    log("Parse error pending #" .. id)
    return nil
  end

  write(PROCESSING_DIR .. "/" .. id .. ".json", body)
  write(pending_path, "")

  local rest = {}
  for i = 2, #ids do rest[#rest + 1] = ids[i] end
  write_index_ids(rest)

  log("Claimed file order #" .. id)
  return order
end

local function inventory_count(item_id)
  local inv = bot:getInventory()
  if not inv then return 0 end
  return inv:findItem(item_id) or 0
end

local function ensure_connected()
  if bot.status == BotStatus.online then return true end
  log("Connecting... status=" .. tostring(bot.status))
  bot:connect()
  for _ = 1, 45 do
    sleep(1000)
    if bot.status == BotStatus.online then return true end
  end
  return false
end

local function warp_to_world(world_field)
  local world_name, door_id = split_world(world_field)
  for attempt = 1, 10 do
    if order_expired() then return false end
    log("Warp " .. attempt .. " → " .. world_name)
    if door_id ~= "" then
      bot:warp(world_name, door_id)
    else
      bot:warp(world_name)
    end
    sleep(WARP_RETRY_MS)
    if bot:isInWorld(world_name) then return true end
  end
  return false
end

local function find_expected_player()
  local world = bot:getWorld()
  if not world then return nil end
  for _, p in pairs(world:getPlayers()) do
    if player_matches_buyer(p) then return p end
  end
  return nil
end

local function trade_add_item(item_id, count)
  for i = 1, count do
    bot:sendPacket(2, string.format(
      "action|dialog_return\ndialog_name|trade_item\nitemID|%d\ncount|1\n", item_id))
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
  write_result(order.id, "failed", reason)
  clear_state()
end

local function finish_order_success(order)
  write_result(order.id, "completed", "")
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
  local world_name = split_world(order.world_name)

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

  log(string.format("Start #%d → %s buyer=%s", order.id, order.world_name, order.growid))

  if not warp_to_world(order.world_name) then
    finish_order_fail(order, "warp_failed")
    return
  end

  while state.order and not order_expired() do
    if not bot:isInWorld(world_name) then
      warp_to_world(order.world_name)
    else
      if state.trade_done then
        finish_order_success(order)
        return
      end
      local buyer = find_expected_player()
      if buyer and state.trade_phase == "waiting_player" then
        state.trade_phase = "trading"
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
  if variant:get(0):getString() == "OnConsoleMessage" then
    local msg = (variant:get(1):getString() or ""):lower()
    if msg:find("trade complete", 1, true) or msg:find("trade successful", 1, true) then
      state.trade_done = true
    end
  end
end

addEvent(Event.variantlist, on_variantlist)

QUEUE_BASE = try_load_queue_base()
PENDING_DIR = QUEUE_BASE .. "/pending"
PROCESSING_DIR = QUEUE_BASE .. "/processing"
RESULTS_DIR = QUEUE_BASE .. "/results"
INDEX_FILE = QUEUE_BASE .. "/pending_index.txt"

log("File worker → " .. QUEUE_BASE)

while true do
  if not state.busy then
    local order = claim_next_order()
    if order then
      state.busy = true
      runThread(run_order, order)
    end
  end
  listenEvents(2)
  sleep(POLL_MS)
end
