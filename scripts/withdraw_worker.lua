--[[
  GT Lock Shop — Luci withdraw (dosya kuyruğu)
  QUEUE_BASE = bot.py ile aynı data/luci klasörü
]]

local QUEUE_BASE = "C:/Users/Administrator/Desktop/lock/data/luci"
local POLL_MS = 2500
local ORDER_TIMEOUT_MS = 120000
local WARP_RETRY_MS = 5000

local ITEM_WL = 242
local ITEM_DL = 1796
local ITEM_BGL = 7188

-- Yollar (init_paths sonradan günceller)
local PENDING_DIR = ""
local PROCESSING_DIR = ""
local RESULTS_DIR = ""
local INDEX_FILE = ""
local ACTIVE_FILE = ""

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
  trade_cmd_sent = false,
  trade_open = false,
  trade_item_id = 0,
  trade_qty = 0,
  trade_items_placed = false,
  trade_locked = false,
  trade_add_attempts = 0,
  last_trade_add_ms = 0,
  order_started_ms = 0,
}

-- Global fonksiyonlar: Lucifer runThread local upvalue taşımıyor
function GT_log(msg)
  local line = "[GT-Shop] " .. tostring(msg)
  print(line)
  pcall(function() getBot():getLog():append(line) end)
end

function GT_init_paths()
  local base = QUEUE_BASE
  local ok, path = pcall(function()
    return read(base .. "/QUEUE_PATH.txt")
  end)
  if ok and path and path ~= "" then
    path = path:gsub("%s+", ""):gsub("\\", "/")
    if path:sub(-1) == "/" then path = path:sub(1, -2) end
    base = path
  end
  PENDING_DIR = base .. "/pending"
  PROCESSING_DIR = base .. "/processing"
  RESULTS_DIR = base .. "/results"
  INDEX_FILE = base .. "/pending_index.txt"
  ACTIVE_FILE = base .. "/processing/active.txt"
  GT_log("Queue path: " .. base)
end

function GT_norm_name(name)
  if not name then return "" end
  local s = tostring(name)
  local ok, cleaned = pcall(function() return removeColor(s) end)
  if ok and cleaned then s = cleaned end
  s = string.lower(s)
  s = s:gsub("`", ""):gsub("[^%w]", "")
  return s
end

function GT_now_ms()
  return os.time() * 1000
end

function GT_split_world(world_field)
  local w = string.upper(tostring(world_field or ""))
  local name, door = w, ""
  local pipe = w:find("|", 1, true)
  if pipe then
    name = w:sub(1, pipe - 1)
    door = w:sub(pipe + 1)
  end
  return name, door
end

function GT_order_expired()
  if state.order_started_ms <= 0 then return false end
  return (GT_now_ms() - state.order_started_ms) >= ORDER_TIMEOUT_MS
end

function GT_parse_order_json(body)
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

function GT_item_id_for_type(t)
  if t == "dl" then return ITEM_DL end
  if t == "bgl" then return ITEM_BGL end
  return ITEM_WL
end

function GT_write_result(order_id, status, reason)
  local safe = (reason or ""):gsub('"', "'")
  local json = string.format(
    '{"id":%d,"status":"%s","reason":"%s","at":%d}',
    order_id, status, safe, os.time()
  )
  write(RESULTS_DIR .. "/" .. order_id .. ".json", json)
  GT_log("Result #" .. order_id .. " " .. status)
end

function GT_read_index_ids()
  local raw = read(INDEX_FILE)
  if not raw or raw == "" then return {} end
  local ids = {}
  for line in raw:gmatch("[^\r\n]+") do
    local n = tonumber(line:match("^(%d+)"))
    if n then ids[#ids + 1] = n end
  end
  return ids
end

function GT_write_index_ids(ids)
  if #ids == 0 then
    write(INDEX_FILE, "")
    return
  end
  local lines = {}
  for i = 1, #ids do lines[i] = tostring(ids[i]) end
  write(INDEX_FILE, table.concat(lines, "\n") .. "\n")
end

function GT_load_order_file(dir, id)
  local body = read(dir .. "/" .. id .. ".json")
  if not body or body == "" then return nil end
  return GT_parse_order_json(body)
end

function GT_claim_from_processing()
  local id_str = read(ACTIVE_FILE)
  if not id_str or id_str == "" then return nil end
  local id = tonumber(id_str:match("(%d+)"))
  if not id then return nil end
  local order = GT_load_order_file(PROCESSING_DIR, id)
  if order then
    GT_log("Resume processing #" .. id .. " world=" .. order.world_name)
    return order
  end
  return nil
end

function GT_claim_next_order()
  local ids = GT_read_index_ids()
  if #ids > 0 then
    local id = ids[1]
    local pending_path = PENDING_DIR .. "/" .. id .. ".json"
    local body = read(pending_path)
    if body and body ~= "" then
      local order = GT_parse_order_json(body)
      if order then
        write(PROCESSING_DIR .. "/" .. id .. ".json", body)
        write(ACTIVE_FILE, tostring(id))
        write(pending_path, "")
        local rest = {}
        for i = 2, #ids do rest[#rest + 1] = ids[i] end
        GT_write_index_ids(rest)
        GT_log("Claimed pending #" .. id .. " world=" .. order.world_name)
        return order
      end
    end
    GT_log("Pending file missing for #" .. id)
    local rest = {}
    for i = 2, #ids do rest[#rest + 1] = ids[i] end
    GT_write_index_ids(rest)
  end
  return GT_claim_from_processing()
end

function GT_player_matches(player)
  if not player or player.isLocalPlayer then return false end
  local expected = state.expected_norm
  if GT_norm_name(player.name) == expected then return true end
  if player.altName and GT_norm_name(player.altName) == expected then return true end
  return false
end

function GT_inventory_count(item_id)
  local inv = bot:getInventory()
  if not inv then return 0 end
  return inv:findItem(item_id) or 0
end

function GT_ensure_connected()
  if bot.status == BotStatus.online then return true end
  GT_log("Connecting... status=" .. tostring(bot.status))
  bot:connect()
  for _ = 1, 45 do
    sleep(1000)
    if bot.status == BotStatus.online then return true end
  end
  return false
end

function GT_warp_to_world(world_field)
  local world_name, door_id = GT_split_world(world_field)
  if world_name == "" then
    GT_log("Empty world name in order")
    return false
  end
  for attempt = 1, 10 do
    if GT_order_expired() then return false end
    GT_log("Warp " .. attempt .. "/10 -> " .. world_name .. (door_id ~= "" and ("|" .. door_id) or ""))
    if door_id ~= "" then
      bot:warp(world_name, door_id)
    else
      bot:warp(world_name)
    end
    sleep(WARP_RETRY_MS)
    if bot:isInWorld(world_name) then
      GT_log("In world " .. world_name)
      return true
    end
    local cur = ""
    if bot:isInWorld() and bot:getWorld() then
      cur = tostring(bot:getWorld().name or "?")
    end
    GT_log("Not in " .. world_name .. " yet (now: " .. cur .. ")")
  end
  return false
end

function GT_request_trade(growid)
  local gid = tostring(growid or ""):gsub("%s+", "")
  if gid == "" then return false end
  local cmd = "/trade " .. gid
  GT_log("Say: " .. cmd)
  bot:say(cmd)
  return true
end

function GT_find_buyer()
  local world = bot:getWorld()
  if not world then return nil end
  for _, p in pairs(world:getPlayers()) do
    if GT_player_matches(p) then return p end
  end
  return nil
end

function GT_trade_add_item(item_id, count)
  count = tonumber(count) or 1
  item_id = tonumber(item_id) or ITEM_WL
  GT_log("Adding to trade: item=" .. item_id .. " x" .. count)

  -- Yöntem 1: doğrudan trade_item (en yaygın)
  bot:sendPacket(2, "action|trade_item\nitemID|" .. item_id .. "\ncount|" .. count)
  sleep(350)

  -- Yöntem 2: dialog_return
  bot:sendPacket(2, "action|dialog_return\ndialog_name|trade_item\nitemID|" .. item_id .. "\ncount|" .. count)
  sleep(350)

  -- Yöntem 3: tradescreen dialog
  bot:sendPacket(2, "action|dialog_return\ndialog_name|tradescreen\nitemID|" .. item_id .. "\ncount|" .. count)
  sleep(350)

  -- Yöntem 4: tek tek ekle (WL gibi stackable)
  if count > 1 and count <= 40 then
    for i = 1, count do
      bot:sendPacket(2, "action|trade_item\nitemID|" .. item_id .. "\ncount|1")
      sleep(180)
    end
  end
end

function GT_trade_lock()
  GT_log("Trade lock")
  bot:sendPacket(2, "action|dialog_return\ndialog_name|trade_confirm\nbuttonClicked|lock\n")
  bot:sendPacket(2, "action|dialog_return\ndialog_name|tradescreen\nbuttonClicked|lock\n")
end

function GT_trade_accept()
  GT_log("Trade accept")
  bot:sendPacket(2, "action|dialog_return\ndialog_name|trade_confirm\nbuttonClicked|accept\n")
  bot:sendPacket(2, "action|dialog_return\ndialog_name|tradescreen\nbuttonClicked|accept\n")
end

function GT_on_trade_status(payload)
  if not payload or payload == "" then return end
  state.trade_open = true

  local slot_item, slot_count = payload:match("add_slot|(%d+)|(%d+)")
  if slot_item then
    local sid = tonumber(slot_item)
    local sc = tonumber(slot_count) or 0
    if sid == state.trade_item_id and sc >= state.trade_qty then
      state.trade_items_placed = true
      GT_log("Trade slot OK: " .. sid .. " x" .. sc)
    elseif sid == state.trade_item_id and sc > 0 then
      GT_log("Trade slot partial: " .. sc .. "/" .. state.trade_qty)
    end
  end

  if payload:find("locked|1") and state.trade_items_placed then
    state.trade_locked = true
  end
end

function GT_on_trade_console(msg)
  if not msg or msg == "" then return end
  local low = msg:lower()
  if low:find("trade change", 1, true) and low:find("added", 1, true) then
    state.trade_items_placed = true
    GT_log("Trade items confirmed (console)")
  end
  if low:find("trade complete", 1, true) or low:find("trade successful", 1, true) then
    state.trade_done = true
  end
end

function GT_trade_try_add_items()
  if state.trade_items_placed or state.trade_item_id <= 0 then return end
  if state.trade_add_attempts >= 8 then return end
  local now = GT_now_ms()
  if state.trade_add_attempts > 0 and (now - state.last_trade_add_ms) < 2000 then return end
  state.trade_add_attempts = state.trade_add_attempts + 1
  state.last_trade_add_ms = now
  GT_log("Trade add attempt " .. state.trade_add_attempts .. "/8")
  GT_trade_add_item(state.trade_item_id, state.trade_qty)
end

function GT_trade_tick()
  if not state.order or state.trade_done then return end
  if state.trade_phase ~= "trading" then return end

  if state.trade_open and not state.trade_items_placed then
    GT_trade_try_add_items()
    return
  end

  -- Trade penceresi event gelmezse 3 sn sonra yine dene
  if state.trade_cmd_sent and not state.trade_items_placed and not state.trade_open then
    local elapsed = GT_now_ms() - state.last_trade_add_ms
    if state.trade_add_attempts == 0 or elapsed > 3000 then
      state.trade_open = true
      GT_log("Trade open timeout — forcing item add")
      GT_trade_try_add_items()
    end
    return
  end

  if state.trade_items_placed and not state.trade_locked then
    GT_trade_lock()
    state.trade_locked = true
    sleep(800)
    GT_trade_accept()
  end
end

function GT_clear_state()
  state.busy = false
  state.order = nil
  state.trade_phase = "idle"
  state.trade_done = false
  state.trade_cmd_sent = false
  state.trade_open = false
  state.trade_item_id = 0
  state.trade_qty = 0
  state.trade_items_placed = false
  state.trade_locked = false
  state.trade_add_attempts = 0
  state.last_trade_add_ms = 0
  state.expected_norm = ""
  state.order_started_ms = 0
end

function GT_finish_fail(order, reason)
  GT_log(reason)
  GT_write_result(order.id, "failed", reason)
  write(ACTIVE_FILE, "")
  GT_clear_state()
end

function GT_finish_success(order)
  GT_write_result(order.id, "completed", "")
  GT_log("Done #" .. order.id)
  write(ACTIVE_FILE, "")
  GT_clear_state()
end

function GT_run_order(order)
  state.busy = true
  state.order = order
  state.expected_norm = GT_norm_name(order.growid)
  state.trade_phase = "waiting_player"
  state.trade_done = false
  state.trade_cmd_sent = false
  state.trade_open = false

  local item_id = order.item_id or GT_item_id_for_type(order.item_type)
  local qty = tonumber(order.quantity) or 1
  local world_name = GT_split_world(order.world_name)

  state.trade_item_id = item_id
  state.trade_qty = qty
  state.trade_items_placed = false
  state.trade_locked = false
  state.trade_add_attempts = 0
  state.last_trade_add_ms = 0
  state.order_started_ms = GT_now_ms()

  if state.expected_norm == "" then
    GT_finish_fail(order, "invalid_growid")
    return
  end
  if GT_inventory_count(item_id) < qty then
    GT_finish_fail(order, "insufficient_bot_stock")
    return
  end
  if not GT_ensure_connected() then
    GT_finish_fail(order, "bot_offline")
    return
  end

  GT_log(string.format("Order #%d world=%s growid=%s qty=%d", order.id, order.world_name, order.growid, qty))

  if not GT_warp_to_world(order.world_name) then
    GT_finish_fail(order, "warp_failed")
    return
  end

  while state.order and not GT_order_expired() do
    if not bot:isInWorld(world_name) then
      GT_warp_to_world(order.world_name)
    else
      if state.trade_done then
        GT_finish_success(order)
        return
      end
      local buyer = GT_find_buyer()
      if buyer and not state.trade_cmd_sent then
        state.trade_phase = "trading"
        state.trade_cmd_sent = true
        GT_log("Buyer in world: " .. tostring(buyer.name))
        GT_request_trade(order.growid)
      elseif state.trade_phase == "trading" then
        GT_trade_tick()
      elseif state.trade_phase == "waiting_player" and not state.trade_cmd_sent then
        state.trade_cmd_sent = true
        state.trade_phase = "trading"
        GT_request_trade(order.growid)
      end
      sleep(500)
    end
  end

  if state.order then
    if state.trade_done then
      GT_finish_success(order)
    else
      GT_finish_fail(order, "order_timeout_2min")
    end
  end
end

function on_variantlist(variant, netid)
  if not state.order then return end
  local head = variant:get(0):getString()
  if head == "OnTradeStatus" then
    state.trade_phase = "trading"
    local payload = ""
    pcall(function() payload = variant:get(4):getString() or "" end)
    GT_on_trade_status(payload)
  elseif head == "OnConsoleMessage" then
    GT_on_trade_console(variant:get(1):getString() or "")
  elseif head == "OnForceTradeEnd" then
    if state.trade_phase == "trading" and not state.trade_done then
      GT_log("Trade cancelled")
      state.trade_open = false
      state.trade_items_placed = false
      state.trade_locked = false
      state.trade_add_attempts = 0
      state.last_trade_add_ms = 0
    end
  end
end

addEvent(Event.variantlist, on_variantlist)

GT_init_paths()

while true do
  if not state.busy then
    local order = GT_claim_next_order()
    if order then
      -- runThread kullanma: Luci thread'de local upvalue kırılıyor
      GT_run_order(order)
    end
  end
  listenEvents(2)
  sleep(POLL_MS)
end
