--[[
  GT Lock Shop — Luci withdraw (dosya kuyruğu)
  Sipariş: kullanıcının dünyasına git → Display Box (1422) bul → sol/sağdan yüzünü kutuya çevir → tek drop
]]

local QUEUE_BASE = "C:/Users/Administrator/Desktop/lock/data/luci"
local POLL_MS = 2500
local ORDER_TIMEOUT_MS = 120000
local WARP_RETRY_MS = 5000
local MAX_STACK = 200

local ITEM_WL = 242
local ITEM_DL = 1796
local ITEM_BGL = 7188

local DISPLAY_BOX_FG = 1422

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
  order_started_ms = 0,
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

function GT_is_display_box(fg)
  if not fg or fg == 0 then return false end
  if fg == DISPLAY_BOX_FG then return true end
  local ok, info = pcall(function() return getInfo(fg) end)
  if not ok or not info then return false end
  local name = tostring(info.name or ""):lower()
  if name:find("seed", 1, true) then return false end
  return name:find("display box", 1, true) ~= nil
end

function GT_path_exists(x, y)
  local ok, path = pcall(function() return bot:getPath(x, y) end)
  if ok and path and #path > 0 then return true end
  return false
end

function GT_can_reach_tile(x, y)
  if GT_path_exists(x, y) then return true end
  if GT_tile_has_access(x, y) then return true end
  return false
end

function GT_find_display_boxes()
  local world = bot:getWorld()
  if not world then return {} end
  local boxes = {}
  for _, tile in pairs(world:getTiles()) do
    if GT_is_display_box(tile.fg) then
      GT_log("Display box fg=" .. tile.fg .. " @ " .. tile.x .. "," .. tile.y)
      boxes[#boxes + 1] = { x = tile.x, y = tile.y, fg = tile.fg }
    end
  end
  return boxes
end

function GT_find_reachable_display_boxes()
  local all = GT_find_display_boxes()
  if #all == 0 then return {} end
  GT_log("Display boxes in world: " .. #all)
  local reachable = {}
  for _, box in ipairs(all) do
    if GT_can_reach_tile(box.x - 1, box.y) or GT_can_reach_tile(box.x + 1, box.y) then
      reachable[#reachable + 1] = box
    end
  end
  if #reachable == 0 then
    GT_log("Reach check failed — trying first display anyway")
    return { all[1] }
  end
  return reachable
end

function GT_tile_standable(x, y)
  local ok, tile = pcall(function() return getTile(x, y) end)
  if not ok or not tile then return false end
  if tile.fg == 0 then return true end
  if tile.fg == DISPLAY_BOX_FG then return false end
  local info_ok, info = pcall(function() return getInfo(tile.fg) end)
  if info_ok and info and (info.collision_type or 0) > 0 then
    return false
  end
  return true
end

-- Display kutusunun soluna veya sağına git; yüzü kutuya çevir (drop ön tile = display).
function GT_stand_beside_display(dx, dy)
  local sides = {
    { x = dx - 1, y = dy, face_left = false },
    { x = dx + 1, y = dy, face_left = true },
  }
  for _, side in ipairs(sides) do
    if not GT_tile_standable(side.x, side.y) then
      GT_log("Not standable: " .. side.x .. "," .. side.y)
    elseif not GT_can_reach_tile(side.x, side.y) then
      GT_log("No path to: " .. side.x .. "," .. side.y)
    else
      pcall(function() bot:findPath(side.x, side.y) end)
      sleep(800)
      if bot:isInTile(side.x, side.y) then
        pcall(function() bot:setDirection(side.face_left) end)
        sleep(350)
        GT_log("Beside display @ " .. side.x .. "," .. side.y .. " face_left=" .. tostring(side.face_left))
        return true
      end
    end
  end
  return false
end

function GT_drop_once(item_id, count)
  bot:sendPacket(2, "action|drop\nitemID|" .. tostring(item_id) .. "|\n")
  sleep(450)
  bot:sendPacket(2,
    "action|dialog_return\n" ..
    "dialog_name|drop_item\n" ..
    "itemID|" .. tostring(item_id) .. "|\n" ..
    "count|" .. tostring(count) .. "\n"
  )
  sleep(700)
end

function GT_inventory_dropped(before, item_id, amount)
  local after = GT_inventory_count(item_id)
  return (before - after) >= amount
end

function GT_drop_on_display(display_x, display_y, item_id, count)
  local before = GT_inventory_count(item_id)
  if before < count then return false end

  GT_log("Drop " .. count .. "x item " .. item_id .. " on display @ " .. display_x .. "," .. display_y)

  if not GT_stand_beside_display(display_x, display_y) then
    GT_log("Cannot stand left/right of display box")
    return false
  end

  for attempt = 1, 2 do
    if GT_order_expired() then return false end
    if GT_inventory_dropped(before, item_id, count) then
      local delta = before - GT_inventory_count(item_id)
      GT_log("Drop OK (inv -" .. delta .. ")")
      return true
    end
    GT_log("Drop attempt " .. attempt .. "/2")
    GT_drop_once(item_id, count)
    listenEvents(1)
  end

  GT_log("Drop failed — inv before=" .. before .. " after=" .. GT_inventory_count(item_id))
  return false
end

function GT_drop_all_on_display(box, item_id, total_qty)
  local remaining = total_qty
  while remaining > 0 do
    if GT_order_expired() then return false, "order_timeout_2min" end
    local chunk = remaining
    if chunk > MAX_STACK then chunk = MAX_STACK end
    local ok = GT_drop_on_display(box.x, box.y, item_id, chunk)
    if not ok then
      return false, "drop_failed"
    end
    remaining = remaining - chunk
    sleep(500)
  end
  return true, ""
end

function GT_clear_state()
  state.busy = false
  state.order = nil
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
  local boxes = GT_find_reachable_display_boxes()
  if #boxes == 0 then
    GT_log("Rescan display boxes in 3s (world load)...")
    sleep(3000)
    boxes = GT_find_reachable_display_boxes()
  end
  if #boxes == 0 then
    GT_finish_fail(order, "no_display_box")
    return
  end

  GT_log("Found " .. #boxes .. " display box(es)")
  local box = boxes[1]
  local ok, reason = GT_drop_all_on_display(box, item_id, qty)
  if ok then
    GT_finish_success(order)
  else
    GT_finish_fail(order, reason ~= "" and reason or "drop_failed")
  end
end

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
