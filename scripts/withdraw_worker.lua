--[[
  GT Lock Shop — Luci donation box withdraw (dosya kuyruğu)
  Sipariş: kullanıcının dünyasına git → erişilebilir donation box bul → item bırak
]]

local QUEUE_BASE = "C:/Users/Administrator/Desktop/lock/data/luci"
local POLL_MS = 2500
local ORDER_TIMEOUT_MS = 120000
local WARP_RETRY_MS = 5000
local MAX_STACK = 200

local ITEM_WL = 242
local ITEM_DL = 1796
local ITEM_BGL = 7188

-- Bilinen donation box foreground ID'leri (sunucuya göre ekle)
local DONATION_BOX_IDS = {
  [1452] = true,
  [2810] = true,
  [9878] = true,
  [9984] = true,
  [11586] = true, -- Donut Donation Box (bazı sürümler)
}

local PENDING_DIR = ""
local PROCESSING_DIR = ""
local RESULTS_DIR = ""
local INDEX_FILE = ""
local ACTIVE_FILE = ""

local bot = getBot()
bot.auto_reconnect = true
bot.auto_accept = false
bot.auto_ban = false

local state = {
  busy = false,
  order = nil,
  deposit_done = false,
  donate_dialog_name = "",
  order_started_ms = 0,
  donate_box_x = -1,
  donate_box_y = -1,
}

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

function GT_tile_has_access(x, y)
  local ok, result = pcall(function()
    return hasAccess(x, y)
  end)
  return ok and result == true
end

function GT_is_donation_box(fg)
  if not fg or fg == 0 then return false end
  if DONATION_BOX_IDS[fg] then return true end
  local ok, info = pcall(function() return getInfo(fg) end)
  if not ok or not info then return false end
  local name = tostring(info.name or ""):lower()
  if name:find("seed", 1, true) then return false end
  return name:find("donation", 1, true) ~= nil and name:find("box", 1, true) ~= nil
end

function GT_path_exists(x, y)
  local ok, path = pcall(function() return bot:getPath(x, y) end)
  if ok and path and #path > 0 then return true end
  return false
end

-- hasAccess kutunun kendisinde false olabilir; komşu tile veya path yeterli
function GT_can_reach_box(box_x, box_y)
  local offsets = {
    { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
  }
  for _, off in ipairs(offsets) do
    local tx, ty = box_x + off[1], box_y + off[2]
    if GT_path_exists(tx, ty) then return true end
    if GT_tile_has_access(tx, ty) then return true end
  end
  -- Yol bulunamazsa yine dene (findPath runtime'da çalışabilir)
  return true
end

function GT_find_donation_boxes()
  local world = bot:getWorld()
  if not world then return {} end
  local boxes = {}
  for _, tile in pairs(world:getTiles()) do
    if GT_is_donation_box(tile.fg) then
      GT_log("Donation box fg=" .. tile.fg .. " @ " .. tile.x .. "," .. tile.y)
      boxes[#boxes + 1] = { x = tile.x, y = tile.y, fg = tile.fg }
    end
  end
  return boxes
end

function GT_find_accessible_donation_boxes()
  local all = GT_find_donation_boxes()
  if #all == 0 then
    GT_log("No donation box tiles in world scan")
    return {}
  end
  GT_log("Donation boxes in world: " .. #all)
  local reachable = {}
  for _, box in ipairs(all) do
    if GT_can_reach_box(box.x, box.y) then
      reachable[#reachable + 1] = box
    end
  end
  if #reachable == 0 then
    GT_log("Reach check failed — trying first box anyway")
    return { all[1] }
  end
  return reachable
end

function GT_move_near_tile(x, y)
  local offsets = {
    { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
  }
  for _, off in ipairs(offsets) do
    local tx, ty = x + off[1], y + off[2]
    pcall(function() bot:findPath(tx, ty) end)
    sleep(700)
    if bot:isInTile(tx, ty) then return true end
  end
  pcall(function() bot:findPath(x, y) end)
  sleep(700)
  return bot:isInTile(x, y)
end

function GT_open_donation_box(box_x, box_y)
  pcall(function() bot:wrench(box_x, box_y) end)
  sleep(500)
end

-- Luci debug: give_item paketi 2x = donation box'a item düşer
function GT_give_item_packet(box_x, box_y, item_id, count)
  return "action|dialog_return\n" ..
    "dialog_name|give_item\n" ..
    "itemID|" .. tostring(item_id) .. "|\n" ..
    "tilex|" .. tostring(box_x) .. "|\n" ..
    "tiley|" .. tostring(box_y) .. "|\n" ..
    "buttonClicked|give\n\n\n" ..
    "count|" .. tostring(count) .. "\n" ..
    "sign_text|\n\n\n"
end

function GT_send_give_item(box_x, box_y, item_id, count)
  local pkt = GT_give_item_packet(box_x, box_y, item_id, count)
  bot:sendPacket(2, pkt)
  sleep(400)
  bot:sendPacket(2, pkt)
  sleep(600)
end

function GT_inventory_decreased(before, item_id, min_delta)
  local after = GT_inventory_count(item_id)
  if after < before then return true end
  if min_delta and (before - after) >= min_delta then return true end
  return false
end

function GT_donate_chunk(box_x, box_y, item_id, count)
  local before = GT_inventory_count(item_id)
  if before < count then return false end

  state.deposit_done = false
  state.donate_box_x = box_x
  state.donate_box_y = box_y

  GT_log("Donate " .. count .. "x item " .. item_id .. " @ " .. box_x .. "," .. box_y)
  if not GT_move_near_tile(box_x, box_y) then
    GT_log("Could not reach donation box — trying anyway")
  end

  for attempt = 1, 3 do
    if GT_inventory_decreased(before, item_id, 1) or state.deposit_done then
      GT_log("Donate OK")
      return true
    end

    GT_log("give_item x2 attempt " .. attempt .. "/3")
    GT_open_donation_box(box_x, box_y)
    sleep(500)
    GT_send_give_item(box_x, box_y, item_id, count)
    listenEvents(2)
  end

  if GT_inventory_decreased(before, item_id, 1) or state.deposit_done then
    return true
  end
  GT_log("Donate failed — inv before=" .. before .. " after=" .. GT_inventory_count(item_id))
  return false
end

function GT_donate_all(box, item_id, total_qty)
  local remaining = total_qty
  while remaining > 0 do
    if GT_order_expired() then return false, "order_timeout_2min" end
    local chunk = remaining
    if chunk > MAX_STACK then chunk = MAX_STACK end
    local ok = GT_donate_chunk(box.x, box.y, item_id, chunk)
    if not ok then
      return false, "donation_failed"
    end
    remaining = remaining - chunk
    sleep(500)
  end
  return true, ""
end

function GT_clear_state()
  state.busy = false
  state.order = nil
  state.deposit_done = false
  state.donate_dialog_name = ""
  state.order_started_ms = 0
  state.donate_box_x = -1
  state.donate_box_y = -1
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
  state.deposit_done = false
  state.donate_dialog_name = ""
  state.order_started_ms = GT_now_ms()

  local item_id = order.item_id or GT_item_id_for_type(order.item_type)
  local qty = tonumber(order.quantity) or 1
  local world_name = GT_split_world(order.world_name)

  if world_name == "" then
    GT_finish_fail(order, "invalid_world")
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

  GT_log(string.format(
    "Order #%d world=%s growid=%s qty=%d item=%d",
    order.id, order.world_name, order.growid, qty, item_id
  ))

  if not GT_warp_to_world(order.world_name) then
    GT_finish_fail(order, "warp_failed")
    return
  end

  sleep(2000)
  local boxes = GT_find_accessible_donation_boxes()
  if #boxes == 0 then
    GT_log("Rescan donation boxes in 3s (world load)...")
    sleep(3000)
    boxes = GT_find_accessible_donation_boxes()
  end
  if #boxes == 0 then
    GT_finish_fail(order, "no_donation_box")
    return
  end

  GT_log("Found " .. #boxes .. " accessible donation box(es)")
  local box = boxes[1]
  local ok, reason = GT_donate_all(box, item_id, qty)
  if ok then
    GT_finish_success(order)
  else
    GT_finish_fail(order, reason ~= "" and reason or "donation_failed")
  end
end

function on_variantlist(variant, netid)
  if not state.order then return end
  local head = variant:get(0):getString()
  if head == "OnDialogRequest" then
    local dlg = variant:get(1):getString() or ""
    local dname = dlg:match("end_dialog|([^|\n]+)|")
    if dname then
      state.donate_dialog_name = dname
      GT_log("Dialog captured: " .. dname)
    end
  elseif head == "OnConsoleMessage" or head == "OnTalkBubble" then
    local msg = variant:get(1):getString() or ""
    local low = msg:lower()
    if low:find("has donated", 1, true) or low:find("donated", 1, true) then
      state.deposit_done = true
      GT_log("Donate confirmed (chat)")
    end
  elseif head == "OnTextOverlay" then
    local msg = variant:get(1):getString() or ""
    local low = msg:lower()
    if low:find("has donated", 1, true) then
      state.deposit_done = true
    end
  end
end

addEvent(Event.variantlist, on_variantlist)

GT_init_paths()

while true do
  if not state.busy then
    local order = GT_claim_next_order()
    if order then
      GT_run_order(order)
    end
  end
  listenEvents(2)
  sleep(POLL_MS)
end
