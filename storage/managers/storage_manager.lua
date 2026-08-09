--[[
  storage/managers/storage_manager.lua  -  Vault + I/O chest hub
  Titan-Version: 1.0.0

  Bulk storage cell:
    [Input chest] --> [Create Vault] --> [Output chest]
     Sophisticated      mass storage      Sophisticated

  Wire all three (+ this computer) with wired modems on one cable network.
  Bind peripherals, then stock is tracked from the vault. Input is ingested
  on a timer; pocket/admin `request` pushes items into the output chest.

  Commands:
    bind vault|input|output <name|side>
    unbind vault|input|output
    invs | status | stock [filter] | find <item>
    ingest              input -> vault now
    request <item> [count]
    monrate [secs]
    net | hostname [name]
    help | exit

  Run:  storage/managers/storage_manager
]]

local titan = nil
if fs.exists("lib/titan.lua") then
  local ok, t = pcall(dofile, "lib/titan.lua")
  if ok then titan = t end
end

local MSG = titan and titan.MSG or {}
local PROTO = (titan and titan.PROTOCOL) or "titan_net"
local CFG = "storage_manager.cfg"
local VERSION = "1.0.0"

local SIDE_ALIASES = {
  front = "front", forward = "front", f = "front",
  back = "back", behind = "back", rear = "back", b = "back",
  left = "left", l = "left",
  right = "right", r = "right",
  up = "top", top = "top", above = "top", u = "top",
  down = "bottom", bottom = "bottom", below = "bottom", d = "bottom",
}

local cfg = {
  vault = nil,
  input = nil,
  output = nil,
  monRate = 5,
  ingestSecs = 3,
  label = nil,
}

local cache = {
  items = {},
  totals = {},
  display = {},
  updated = 0,
  lastRequest = nil,
  netMain = nil,
  netOk = false,
  ingested = 0,
}

local monitor = peripheral.find("monitor")
if monitor then pcall(function() monitor.setTextScale(0.5) end) end

--------------------------------------------------------------------------------
-- Config / helpers
--------------------------------------------------------------------------------
local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r")
  if not f then return end
  local ok, data = pcall(textutils.unserialize, f.readAll())
  f.close()
  if ok and type(data) == "table" then
    for k, v in pairs(data) do cfg[k] = v end
  end
end

local function saveCfg()
  local f = fs.open(CFG, "w")
  if f then f.write(textutils.serialize(cfg)); f.close() end
end

local function now() return os.epoch("utc") end

local function shortName(name)
  if not name then return "?" end
  return name:match("([^:]+)$") or name
end

local function normalizeSide(s)
  if not s then return nil end
  return SIDE_ALIASES[tostring(s):lower()]
end

local function openModem()
  if titan and titan.openModem then
    local ok = pcall(titan.openModem)
    if ok then return true end
  end
  local found = false
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      pcall(peripheral.call, side, "open", rednet.CHANNEL_REPEAT)
      found = true
    end
  end
  return found
end

local function isInventory(name)
  if not name or not peripheral.isPresent(name) then return false end
  if peripheral.hasType and peripheral.hasType(name, "inventory") then return true end
  local w = peripheral.wrap(name)
  return w and type(w.list) == "function" and type(w.pushItems) == "function"
end

local function resolvePeripheral(ref)
  if not ref or ref == "" then return nil end
  local s = tostring(ref)
  if peripheral.isPresent(s) and isInventory(s) then return s end
  local side = normalizeSide(s)
  if side and peripheral.isPresent(side) then
    local t = peripheral.getType(side)
    if isInventory(side) then return side end
    -- Wired modem on that face: pick first remote inventory.
    local wrap = peripheral.wrap(side)
    if t == "modem" and wrap and type(wrap.getNamesRemote) == "function" then
      local names = wrap.getNamesRemote()
      for _, n in ipairs(names or {}) do
        if isInventory(n) then return n end
      end
    end
  end
  -- Partial name match among inventories.
  local want = s:lower()
  for _, name in ipairs(peripheral.getNames()) do
    if isInventory(name) and name:lower():find(want, 1, true) then
      return name
    end
  end
  return nil
end

local function wrapRole(role)
  local name = cfg[role]
  if not name or not peripheral.isPresent(name) then return nil, name end
  if not isInventory(name) then return nil, name end
  return peripheral.wrap(name), name
end

local function listInventories()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if isInventory(name) then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

--------------------------------------------------------------------------------
-- Stock / transfer
--------------------------------------------------------------------------------
local function rebuildRows()
  local rows = {}
  for name, count in pairs(cache.totals) do
    rows[#rows + 1] = {
      name = name,
      count = count,
      displayName = cache.display[name] or shortName(name),
    }
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  cache.items = rows
end

local function scanInv(name, totals, display)
  local inv = peripheral.wrap(name)
  if not inv then return 0 end
  local ok, list = pcall(inv.list)
  if not ok or type(list) ~= "table" then return 0 end
  local n = 0
  for slot, item in pairs(list) do
    if type(item) == "table" and item.name then
      local c = tonumber(item.count) or 0
      totals[item.name] = (totals[item.name] or 0) + c
      n = n + c
      if not display[item.name] and type(inv.getItemDetail) == "function" then
        local okd, det = pcall(inv.getItemDetail, slot)
        if okd and type(det) == "table" and det.displayName then
          display[item.name] = det.displayName
        end
      end
    end
  end
  return n
end

local function refresh()
  local totals, display = {}, {}
  local vault, vname = wrapRole("vault")
  if vault then
    scanInv(vname, totals, display)
  end
  -- Optionally show input still waiting to ingest.
  local input, iname = wrapRole("input")
  if input then
    scanInv(iname, totals, display)
  end
  cache.totals = totals
  cache.display = display
  cache.updated = now()
  rebuildRows()
  return vault ~= nil
end

local function matchFilter(row, filter)
  if not filter or filter == "" then return true end
  local f = tostring(filter):lower()
  if row.name:lower():find(f, 1, true) then return true end
  if row.displayName and row.displayName:lower():find(f, 1, true) then return true end
  return false
end

local function filteredRows(filter, limit)
  local out = {}
  for _, row in ipairs(cache.items) do
    if matchFilter(row, filter) then
      out[#out + 1] = row
      if limit and #out >= limit then break end
    end
  end
  return out
end

local function resolveItemQuery(query)
  local q = tostring(query or "")
  if q == "" then return nil end
  local ql = q:lower()
  if ql:find(":", 1, true) then return q end
  refresh()
  for _, row in ipairs(cache.items) do
    if row.name:lower() == ql
       or shortName(row.name):lower() == ql
       or (row.displayName and row.displayName:lower() == ql) then
      return row.name
    end
  end
  for _, row in ipairs(cache.items) do
    if row.name:lower():find(ql, 1, true)
       or (row.displayName and row.displayName:lower():find(ql, 1, true)) then
      return row.name
    end
  end
  return nil
end

local function ingestOnce()
  local input, iname = wrapRole("input")
  local vault, vname = wrapRole("vault")
  if not input or not vault then return 0, "need bound input + vault" end
  local ok, list = pcall(input.list)
  if not ok or type(list) ~= "table" then return 0, "input list failed" end
  local moved = 0
  for slot, item in pairs(list) do
    if type(item) == "table" and item.name and (tonumber(item.count) or 0) > 0 then
      local okp, n = pcall(input.pushItems, vname, slot)
      if okp and type(n) == "number" then moved = moved + n end
    end
  end
  cache.ingested = (cache.ingested or 0) + moved
  if moved > 0 then refresh() end
  return moved
end

local function fulfillRequest(itemQuery, count)
  count = math.max(1, math.floor(tonumber(count) or 64))
  local vault, vname = wrapRole("vault")
  local output, oname = wrapRole("output")
  if not vault then return false, "vault not bound", 0, nil end
  if not output then return false, "output not bound", 0, nil end

  -- Ingest first so input stock is available.
  pcall(ingestOnce)

  local itemName = resolveItemQuery(itemQuery)
  if not itemName then return false, "item not found: " .. tostring(itemQuery), 0, nil end

  local moved = 0
  local guard = 0
  while moved < count and guard < 512 do
    guard = guard + 1
    local ok, list = pcall(vault.list)
    if not ok or type(list) ~= "table" then break end
    local slotFind = nil
    local avail = 0
    for slot, item in pairs(list) do
      if type(item) == "table" and item.name == itemName then
        slotFind = slot
        avail = tonumber(item.count) or 0
        break
      end
    end
    if not slotFind or avail < 1 then break end
    local need = math.min(count - moved, avail)
    local okp, n = pcall(vault.pushItems, oname, slotFind, need)
    if not okp or type(n) ~= "number" or n < 1 then break end
    moved = moved + n
  end

  cache.lastRequest = {
    item = itemName, want = count, moved = moved, at = now(),
  }
  refresh()
  if moved < 1 then
    return false, "none moved (empty or output full?)", 0, itemName
  end
  return true, moved, moved, itemName
end

--------------------------------------------------------------------------------
-- Network
--------------------------------------------------------------------------------
local function statusPayload()
  local kinds = #cache.items
  local units = 0
  for _, r in ipairs(cache.items) do units = units + r.count end
  return {
    name = os.getComputerLabel() or ("Storage-" .. os.getComputerID()),
    kind = "storage",
    mode = "vault",
    vault = cfg.vault,
    input = cfg.input,
    output = cfg.output,
    types = kinds,
    units = units,
    lastRequest = cache.lastRequest,
    version = VERSION,
  }
end

local function announceStorage()
  if not titan then return end
  local payload = statusPayload()
  if titan.broadcast then
    pcall(titan.broadcast, MSG.STORAGE_HELLO or "storage_hello", payload)
  else
    rednet.broadcast({
      type = MSG.STORAGE_HELLO or "storage_hello",
      from = os.getComputerID(),
      name = payload.name,
      kind = "storage",
      data = payload,
    }, PROTO)
  end
  -- Also plain rednet for admin tablets listening on titan_net.
  rednet.broadcast({
    type = "storage_hello",
    from = os.getComputerID(),
    name = payload.name,
    kind = "storage",
    vault = cfg.vault, input = cfg.input, output = cfg.output,
    types = payload.types, units = payload.units,
  }, PROTO)
end

--------------------------------------------------------------------------------
-- Monitor / console
--------------------------------------------------------------------------------
local function drawMonitor()
  local out = monitor
  if not out then return end
  local w, h = out.getSize()
  if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
  out.clear()
  local function line(y, text, c)
    if y < 1 or y > h then return end
    out.setCursorPos(1, y)
    if out.setTextColor then out.setTextColor(c or colors.white) end
    out.write(tostring(text):sub(1, w))
  end
  local units = 0
  for _, r in ipairs(cache.items) do units = units + r.count end
  line(1, " STORAGE MANAGER ", colors.yellow)
  line(2, ("vault=%s"):format(tostring(cfg.vault or "?")):sub(1, w), colors.lime)
  line(3, ("in=%s  out=%s"):format(
    tostring(cfg.input or "?"), tostring(cfg.output or "?")):sub(1, w), colors.lightGray)
  line(4, ("types:%d  items:%d  net:%s"):format(
    #cache.items, units, cache.netOk and "ok" or "--"), colors.white)
  if cache.lastRequest then
    local lr = cache.lastRequest
    line(5, ("last: %dx %s"):format(
      tonumber(lr.moved) or 0, shortName(lr.item)):sub(1, w), colors.orange)
  else
    line(5, "last: (none)", colors.gray)
  end
  line(6, "COUNT   ITEM", colors.gray)
  local y = 7
  for _, row in ipairs(cache.items) do
    if y > h then break end
    line(y, ("%6d  %s"):format(row.count, (row.displayName or shortName(row.name)):sub(1, w - 8)), colors.white)
    y = y + 1
  end
  if #cache.items == 0 then
    line(7, "Bind vault + chests, then ingest.", colors.orange)
  end
end

local function printHelp()
  print("Storage Manager v" .. VERSION)
  print("  bind vault|input|output <peripheral|side>")
  print("  unbind vault|input|output")
  print("  invs | status | stock [filter] | find <item>")
  print("  ingest                 input -> vault")
  print("  request <item> [count] vault -> output")
  print("  monrate [secs] | net | hostname [name]")
  print("  help | exit")
end

local function printStock(filter, limit)
  limit = limit or 40
  refresh()
  local rows = filteredRows(filter, limit)
  print(("Stock (vault+input)  %d type(s)%s"):format(
    #cache.items, filter and ("  filter='" .. filter .. "'") or ""))
  if #rows == 0 then print("  (no matches)"); return end
  for _, row in ipairs(rows) do
    print(("  %6d  %-22s %s"):format(
      row.count, (row.displayName or shortName(row.name)):sub(1, 22), row.name))
  end
end

local function handleCommand(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = tostring(a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" or cmd == "?" then printHelp()
  elseif cmd == "status" then
    refresh()
    print(("vault:  %s"):format(tostring(cfg.vault or "(unbound)")))
    print(("input:  %s"):format(tostring(cfg.input or "(unbound)")))
    print(("output: %s"):format(tostring(cfg.output or "(unbound)")))
    print(("types: %d"):format(#cache.items))
    print(("net: %s"):format(cache.netOk and ("MAIN #" .. tostring(cache.netMain)) or "offline"))
    if cache.lastRequest then
      local lr = cache.lastRequest
      print(("last request: %d/%d %s"):format(
        tonumber(lr.moved) or 0, tonumber(lr.want) or 0, tostring(lr.item)))
    end
    drawMonitor()
  elseif cmd == "invs" or cmd == "peripherals" then
    local invs = listInventories()
    print(("Inventories (%d):"):format(#invs))
    for _, n in ipairs(invs) do
      local tag = ""
      if n == cfg.vault then tag = "  [vault]"
      elseif n == cfg.input then tag = "  [input]"
      elseif n == cfg.output then tag = "  [output]" end
      print("  " .. n .. tag)
    end
  elseif cmd == "bind" then
    local role = tostring(a[2] or ""):lower()
    local ref = a[3] and table.concat(a, " ", 3) or nil
    if (role ~= "vault" and role ~= "input" and role ~= "output") or not ref then
      print("Usage: bind vault|input|output <peripheralName|side>")
    else
      local name = resolvePeripheral(ref)
      if not name then
        print("No inventory matching: " .. tostring(ref))
      else
        cfg[role] = name
        saveCfg()
        print(("Bound %s = %s"):format(role, name))
        refresh(); drawMonitor(); announceStorage()
      end
    end
  elseif cmd == "unbind" then
    local role = tostring(a[2] or ""):lower()
    if role ~= "vault" and role ~= "input" and role ~= "output" then
      print("Usage: unbind vault|input|output")
    else
      cfg[role] = nil
      saveCfg()
      print("Unbound " .. role)
      refresh(); drawMonitor()
    end
  elseif cmd == "stock" or cmd == "list" then
    printStock(a[2] and table.concat(a, " ", 2) or nil, 40)
    drawMonitor()
  elseif cmd == "find" or cmd == "search" then
    if not a[2] then print("Usage: find <item>")
    else printStock(table.concat(a, " ", 2), 50) end
  elseif cmd == "ingest" then
    local n, err = ingestOnce()
    if err and n == 0 then print("ingest: " .. tostring(err))
    else print(("Ingested %d item(s) into vault."):format(n or 0)) end
    drawMonitor()
  elseif cmd == "request" or cmd == "req" then
    if not a[2] then
      print("Usage: request <item> [count]")
    else
      local item, count
      if tonumber(a[#a]) and #a >= 3 then
        count = tonumber(a[#a])
        item = table.concat(a, " ", 2, #a - 1)
      else
        item = table.concat(a, " ", 2)
        count = 64
      end
      local ok, movedOrErr, moved, resolved = fulfillRequest(item, count)
      if ok then
        print(("Sent %d x %s -> output"):format(moved or movedOrErr, tostring(resolved)))
      else
        print("Request failed: " .. tostring(movedOrErr))
      end
      drawMonitor()
    end
  elseif cmd == "monrate" then
    if a[2] then
      cfg.monRate = math.max(1, tonumber(a[2]) or cfg.monRate)
      saveCfg()
    end
    print("monRate=" .. tostring(cfg.monRate) .. "s  ingestSecs=" .. tostring(cfg.ingestSecs))
  elseif cmd == "net" then
    if titan and titan.reauth then pcall(titan.reauth, "storage") end
    cache.netMain = titan and titan.getMainRouterId and titan.getMainRouterId() or nil
    cache.netOk = cache.netMain ~= nil
    announceStorage()
    print(cache.netOk and ("Linked MAIN #" .. cache.netMain) or "No MAIN router yet.")
  elseif cmd == "hostname" or cmd == "host" then
    if a[2] then
      local name = table.concat(a, " ", 2)
      os.setComputerLabel(name)
      cfg.label = name
      saveCfg()
      announceStorage()
    end
    print("hostname: " .. tostring(os.getComputerLabel()))
  elseif cmd == "refresh" then
    refresh(); drawMonitor(); print("Refreshed.")
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    print("Unknown. Type help.")
  end
  return true
end

--------------------------------------------------------------------------------
-- Loops
--------------------------------------------------------------------------------
local function uiLoop()
  while true do
    monitor = peripheral.find("monitor") or monitor
    pcall(drawMonitor)
    sleep(tonumber(cfg.monRate) or 5)
  end
end

local function ingestLoop()
  while true do
    pcall(ingestOnce)
    sleep(tonumber(cfg.ingestSecs) or 3)
  end
end

local function netLoop()
  local helloT = os.startTimer(2)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "timer" and p1 == helloT then
      if titan and titan.getMainRouterId then
        cache.netMain = titan.getMainRouterId()
        cache.netOk = cache.netMain ~= nil
      end
      announceStorage()
      helloT = os.startTimer(20)
    elseif ev == "rednet_message" and (p3 == PROTO or p3 == nil) and type(p2) == "table" then
      local msg, from = p2, p1
      local t = msg.type
      if t == "storage_ping" or t == MSG.STORAGE_PING or t == "ping" or t == MSG.PING then
        rednet.send(from, {
          type = "storage_status",
          ok = true,
          from = os.getComputerID(),
          data = statusPayload(),
        }, PROTO)
        if titan and titan.send and MSG.STORAGE_STATUS then
          pcall(titan.send, from, MSG.STORAGE_STATUS, statusPayload())
        end
      elseif t == "storage_stock_req" or t == MSG.STORAGE_STOCK_REQ then
        if (now() - (cache.updated or 0)) > 5000 then refresh() end
        local rows = filteredRows(msg.filter, tonumber(msg.limit) or 40)
        local slim = {}
        for i, r in ipairs(rows) do
          slim[i] = { name = r.name, count = r.count, displayName = r.displayName }
        end
        rednet.send(from, {
          type = "storage_stock",
          ok = true,
          from = os.getComputerID(),
          items = slim,
          types = #cache.items,
          mode = "vault",
        }, PROTO)
      elseif t == "storage_request" or t == MSG.STORAGE_REQUEST then
        local ok, movedOrErr, moved, resolved = fulfillRequest(
          msg.item or msg.name, msg.count)
        rednet.send(from, {
          type = "storage_request_ack",
          ok = ok,
          err = not ok and tostring(movedOrErr) or nil,
          moved = ok and (moved or movedOrErr) or 0,
          item = resolved,
          count = msg.count,
          from = os.getComputerID(),
        }, PROTO)
        drawMonitor()
      end
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      monitor = peripheral.find("monitor")
      refresh()
    end
  end
end

local function consoleLoop()
  while true do
    write("storage> ")
    local line = read()
    local r = handleCommand(line)
    if r == "exit" then return end
  end
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------
if not openModem() then
  printError("No modem — attach a wired/wireless modem for mesh + binds.")
end
loadCfg()
os.setComputerLabel(os.getComputerLabel() or cfg.label or ("StorageManager-" .. os.getComputerID()))
cfg.label = os.getComputerLabel()
saveCfg()

term.clear(); term.setCursorPos(1, 1)
print("== Storage Manager v" .. VERSION .. " ==")
print("Vault + Sophisticated input/output chests.")
if titan and titan.reauth then pcall(titan.reauth, "storage") end
cache.netMain = titan and titan.getMainRouterId and titan.getMainRouterId() or nil
cache.netOk = cache.netMain ~= nil
refresh()
announceStorage()
drawMonitor()
if not cfg.vault then
  print("Bind peripherals:  bind vault <name>")
  print("                   bind input <name>")
  print("                   bind output <name>")
  print("List with: invs")
else
  print(("vault=%s input=%s output=%s"):format(
    tostring(cfg.vault), tostring(cfg.input), tostring(cfg.output)))
end
print("Type help.")

parallel.waitForAny(consoleLoop, netLoop, uiLoop, ingestLoop)
print("Storage manager closed.")
