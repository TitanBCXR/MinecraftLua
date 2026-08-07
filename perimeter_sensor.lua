--[[
  perimeter_sensor.lua  -  Territory edge sensor (Advanced Peripherals Player Detector)
  Titan-Version: 1.1.0

  Place on a computer at a perimeter gate with:
    * Advanced Peripherals Player Detector (adjacent / networked)
    * Wireless modem (joins the Titan mesh)
    * GPS in range (for auto side assign from the manager)

  The perimeter manager can auto-assign this gate to:
    north, northeast, east, southeast, south, southwest, west, northwest
  from its position relative to the manager origin. Default detection range: 50.

  Setup:
    side <n|ne|e|se|s|sw|w|nw>   manual override (or wait for manager auto)
    range <n>                    detection radius (default 50)
    name <label>                 e.g. North Gate
    auto                         ask manager to re-assign from GPS
    status | help

  Manager can push config remotely (side / range / name).

  Requires: modem, playerDetector / player_detector, lib/titan.lua
  Pair with: perimeter_manager.lua
]]

local titan = dofile("lib/titan.lua")
local MSG = titan.MSG
local P = titan.PROTOCOL

titan.openModem()

local CFG = "perimeter_sensor.cfg"
local DEFAULT_RANGE = 50
local cfg = {
  side = nil,       -- 8-way compass sector
  range = DEFAULT_RANGE,
  name = nil,
  poll = 0.5,
  autoName = true,  -- rename label when manager assigns a side
}

local seen = {}
local detector = nil
local lastPos = { x = nil, y = nil, z = nil }

local function saveCfg()
  local f = fs.open(CFG, "w"); f.write(textutils.serialize(cfg)); f.close()
end

local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r")
  local d = textutils.unserialize(f.readAll()); f.close()
  if type(d) == "table" then
    for k, v in pairs(d) do cfg[k] = v end
  end
  if cfg.range == nil then cfg.range = DEFAULT_RANGE end
end

local function normalizeSide(s)
  s = tostring(s or ""):lower():gsub("%s+", ""):gsub("_", "")
  local map = {
    n = "north", north = "north",
    ne = "northeast", northeast = "northeast",
    e = "east", east = "east",
    se = "southeast", southeast = "southeast",
    s = "south", south = "south",
    sw = "southwest", southwest = "southwest",
    w = "west", west = "west",
    nw = "northwest", northwest = "northwest",
  }
  return map[s]
end

local function sidePretty(s)
  s = normalizeSide(s) or s
  local pretty = {
    north = "North", northeast = "Northeast", east = "East",
    southeast = "Southeast", south = "South", southwest = "Southwest",
    west = "West", northwest = "Northwest",
  }
  return pretty[s] or tostring(s or "?")
end

local function sideAbbrev(s)
  s = normalizeSide(s)
  local a = {
    north = "N", northeast = "NE", east = "E", southeast = "SE",
    south = "S", southwest = "SW", west = "W", northwest = "NW",
  }
  return a[s] or "?"
end

local function findDetector()
  local d = peripheral.find("playerDetector")
  if d then return d, "playerDetector" end
  d = peripheral.find("player_detector")
  if d then return d, "player_detector" end
  return nil, nil
end

local function locateGps()
  local x, y, z = gps.locate(2)
  if x then
    lastPos.x, lastPos.y, lastPos.z = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
    return lastPos.x, lastPos.y, lastPos.z
  end
  return nil
end

local function stamp()
  local utc = os.epoch("utc")
  local ok, text = pcall(os.date, "!%Y-%m-%d %H:%M:%S")
  if not ok or type(text) ~= "string" then
    ok, text = pcall(os.date, "%Y-%m-%d %H:%M:%S")
  end
  return utc, (ok and text) or tostring(utc)
end

local function gateLabel()
  return cfg.name or os.getComputerLabel() or ("Gate-" .. os.getComputerID())
end

local function applyNameFromSide()
  if not cfg.autoName or not cfg.side then return end
  local name = sidePretty(cfg.side) .. " Gate"
  cfg.name = name
  os.setComputerLabel(name)
end

local function sendEvent(msgType, player, extra)
  local utc, text = stamp()
  local payload = {
    player = player,
    side = cfg.side,
    gate = gateLabel(),
    sensorId = os.getComputerID(),
    range = cfg.range,
    eventTs = utc,
    time = text,
    x = lastPos.x, y = lastPos.y, z = lastPos.z,
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do payload[k] = v end
  end
  titan.broadcast(msgType, payload)
end

local function broadcastHello(extra)
  locateGps()
  local payload = {
    type = MSG.PERIMETER_HELLO or "perimeter_hello",
    kind = "sensor",
    side = cfg.side,
    gate = gateLabel(),
    sensorId = os.getComputerID(),
    range = cfg.range,
    x = lastPos.x, y = lastPos.y, z = lastPos.z,
    wantAssign = (cfg.side == nil) or (extra and extra.wantAssign),
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do payload[k] = v end
  end
  rednet.broadcast(payload, P)
end

local function requestAssign()
  locateGps()
  if not lastPos.x then
    print("No GPS — cannot auto-assign. Set side manually or fix GPS.")
    return false
  end
  rednet.broadcast({
    type = MSG.PERIMETER_ASSIGN_REQ or "perimeter_assign_req",
    kind = "sensor",
    sensorId = os.getComputerID(),
    gate = gateLabel(),
    range = cfg.range,
    x = lastPos.x, y = lastPos.y, z = lastPos.z,
    wantAssign = true,
  }, P)
  print(("Assign requested from manager @ %d,%d,%d"):format(lastPos.x, lastPos.y, lastPos.z))
  return true
end

local function applyConfig(msg)
  local changed = false
  if msg.side then
    local s = normalizeSide(msg.side)
    if s and s ~= cfg.side then
      cfg.side = s
      changed = true
      if cfg.autoName ~= false then applyNameFromSide() end
    end
  end
  if msg.range ~= nil then
    local r = math.floor(tonumber(msg.range) or 0)
    if r >= 1 and r ~= cfg.range then
      cfg.range = r
      changed = true
    end
  end
  if msg.name and tostring(msg.name) ~= "" then
    cfg.name = tostring(msg.name)
    cfg.autoName = false
    os.setComputerLabel(cfg.name)
    changed = true
  end
  if msg.autoName ~= nil then
    cfg.autoName = not not msg.autoName
  end
  if msg.poll ~= nil then
    local p = tonumber(msg.poll)
    if p and p >= 0.2 then cfg.poll = p; changed = true end
  end
  if changed then
    saveCfg()
    print(("Config from manager: side=%s range=%s name=%s"):format(
      tostring(cfg.side), tostring(cfg.range), gateLabel()))
    broadcastHello()
  end
  return changed
end

local function listInRange()
  if not detector then return {} end
  local ok, list = pcall(function()
    return detector.getPlayersInRange(tonumber(cfg.range) or DEFAULT_RANGE)
  end)
  if not ok or type(list) ~= "table" then return {} end
  local out, set = {}, {}
  for _, name in ipairs(list) do
    if type(name) == "string" and name ~= "" then
      out[#out + 1] = name
      set[name] = true
    elseif type(name) == "table" and name.name then
      out[#out + 1] = name.name
      set[name.name] = true
    end
  end
  return out, set
end

local function scanOnce()
  if not cfg.side then return end
  if not detector then
    detector = findDetector()
    if not detector then return end
  end
  local list, nowSet = listInRange()
  for name in pairs(nowSet) do
    if not seen[name] then
      seen[name] = true
      print(("[%s] ENTER %s via %s"):format(
        os.date("%H:%M:%S") or "?", name, sideAbbrev(cfg.side)))
      sendEvent(MSG.PERIMETER_ENTER or "perimeter_enter", name)
    end
  end
  for name in pairs(seen) do
    if not nowSet[name] then
      seen[name] = nil
      print(("[%s] EXIT  %s via %s"):format(
        os.date("%H:%M:%S") or "?", name, sideAbbrev(cfg.side)))
      sendEvent(MSG.PERIMETER_EXIT or "perimeter_exit", name)
    end
  end
  local utc, text = stamp()
  rednet.broadcast({
    type = MSG.PERIMETER_PULSE or "perimeter_pulse",
    side = cfg.side,
    gate = gateLabel(),
    sensorId = os.getComputerID(),
    players = list,
    range = cfg.range,
    ts = utc,
    time = text,
    x = lastPos.x, y = lastPos.y, z = lastPos.z,
  }, P)
end

local function printHelp()
  print("Perimeter sensor — Player Detector gate")
  print("  side <n|ne|e|se|s|sw|w|nw>   manual sector")
  print("  range <blocks>               default " .. DEFAULT_RANGE)
  print("  name <label>                 gate display name")
  print("  auto                         ask manager to assign from GPS")
  print("  poll <seconds>               scan rate (default 0.5)")
  print("  status | help")
  print("Manager can push side/range/name remotely.")
end

local function printStatus()
  print("gate: " .. gateLabel())
  print("side: " .. tostring(cfg.side and (sidePretty(cfg.side) .. " (" .. sideAbbrev(cfg.side) .. ")") or "(waiting for manager auto-assign)"))
  print("range: " .. tostring(cfg.range) .. "  poll: " .. tostring(cfg.poll))
  locateGps()
  if lastPos.x then
    print(("gps: %d,%d,%d"):format(lastPos.x, lastPos.y, lastPos.z))
  else
    print("gps: (none — needed for auto-assign)")
  end
  local d, kind = findDetector()
  print("detector: " .. (d and kind or "NOT FOUND"))
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  print(("in range now: %d"):format(n))
end

local function handleCommand(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = (a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" or cmd == "?" then
    printHelp()
  elseif cmd == "status" then
    printStatus()
  elseif cmd == "side" then
    local s = normalizeSide(a[2])
    if not s then
      print("Usage: side n|ne|e|se|s|sw|w|nw")
    else
      cfg.side = s
      if cfg.autoName ~= false then applyNameFromSide() end
      saveCfg()
      print("side = " .. sidePretty(s))
      broadcastHello()
    end
  elseif cmd == "range" then
    local n = tonumber(a[2])
    if not n or n < 1 then
      print("Usage: range <blocks>")
    else
      cfg.range = math.floor(n)
      saveCfg()
      print("range = " .. cfg.range)
      broadcastHello()
    end
  elseif cmd == "name" or cmd == "label" then
    if not a[2] then
      print("name = " .. gateLabel())
    else
      cfg.name = table.concat(a, " ", 2)
      cfg.autoName = false
      saveCfg()
      os.setComputerLabel(cfg.name)
      print("name = " .. cfg.name)
      broadcastHello()
    end
  elseif cmd == "auto" or cmd == "assign" then
    requestAssign()
  elseif cmd == "poll" then
    local n = tonumber(a[2])
    if not n or n < 0.2 then
      print("Usage: poll <seconds>  (min 0.2)")
    else
      cfg.poll = n
      saveCfg()
      print("poll = " .. cfg.poll)
    end
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    print("Unknown. Type help.")
  end
  return true
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------
loadCfg()
if cfg.range == nil then cfg.range = DEFAULT_RANGE end
-- Upgrade legacy default 8 → 50 only when still at old stock default and no custom note.
-- (Skip forcing if user intentionally set 8.)
os.setComputerLabel(os.getComputerLabel() or cfg.name or ("Perimeter-" .. os.getComputerID()))
cfg.name = cfg.name or os.getComputerLabel()
saveCfg()

detector = findDetector()
locateGps()

term.clear(); term.setCursorPos(1, 1)
print("== Perimeter Sensor ==")
print(gateLabel() .. "  #" .. os.getComputerID())
if not detector then
  print("WARNING: No playerDetector / player_detector found.")
else
  print("Detector OK.  range=" .. tostring(cfg.range))
end
if cfg.side then
  print("side = " .. sidePretty(cfg.side) .. " (" .. sideAbbrev(cfg.side) .. ")")
else
  print("No side yet — requesting auto-assign from manager (needs GPS)...")
  requestAssign()
end
print("Type help. Manager can update this sensor remotely.")
print("")

local function scanLoop()
  while true do
    local ok, err = pcall(scanOnce)
    if not ok then print("scan error: " .. tostring(err)) end
    sleep(tonumber(cfg.poll) or 0.5)
  end
end

local function helloLoop()
  local n = 0
  while true do
    n = n + 1
    broadcastHello({ wantAssign = (cfg.side == nil) or (n % 4 == 1) })
    if cfg.side == nil and lastPos.x then
      requestAssign()
    end
    sleep(15)
  end
end

local function netLoop()
  while true do
    local id, msg = rednet.receive(P, 1)
    if type(msg) == "table" then
      local t = msg.type
      if t == MSG.PERIMETER_CONFIG or t == "perimeter_config" then
        local target = msg.sensorId or msg.id or msg.to
        if target == nil or tonumber(target) == os.getComputerID()
            or target == "*" or target == "all" then
          applyConfig(msg)
        end
      elseif (t == MSG.PERIMETER_HELLO or t == "perimeter_hello")
          and msg.kind == "manager" and msg.origin then
        -- Manager advertised origin; ask for assign if we still need a side.
        if not cfg.side then requestAssign() end
      end
    end
  end
end

local function consoleLoop()
  while true do
    write("gate> ")
    local r = handleCommand(read())
    if r == "exit" then return end
  end
end

titan.setSshHandler(function(line)
  handleCommand(line)
  return true
end)

parallel.waitForAny(
  scanLoop,
  helloLoop,
  netLoop,
  consoleLoop,
  function() titan.networkLoop("perimeter_sensor") end
)
print("Perimeter sensor stopped.")
