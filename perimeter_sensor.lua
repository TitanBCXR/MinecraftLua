--[[
  perimeter_sensor.lua  -  Territory edge sensor (Advanced Peripherals Player Detector)
  Titan-Version: 1.2.2

  Place on a computer at a perimeter gate with:
    * Advanced Peripherals Player Detector (adjacent / networked)
    * Wireless modem (joins the Titan mesh)
    * GPS in range (for auto side / name from the manager origin)

  On hearing the manager origin, this sensor names itself from its direction:
    North Gate, Northeast Gate, East Gate, ... Northwest Gate
  Custom labels stick until you clear them (`autoname`) or the manager renames.

  Setup:
    side <n|ne|e|se|s|sw|w|nw>   manual override (or wait for auto)
    range <n>                    detection radius (default 50)
    name <label>                 custom label (disables auto-name)
    autoname                     restore direction-based name
    auto                         ask manager to re-assign from GPS
    update [-y]                  pull packages (manager can force this remotely)
    status | help

  Manager can push side / range / name remotely (`rename` on the board),
  and `update` / `forceupdate` to OTA every perimeter sensor (SSH fallback).

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
local managerOrigin = nil
local managerId = nil          -- perimeter manager computer id (direct or via mesh)
local otaBusy = false
local broadcastHello -- forward decl (used by self-assign)

-- Deliver a perimeter payload over broadcast + directed manager + main-router hop.
local function deliverPerimeter(msg)
  if type(msg) ~= "table" then return end
  msg.from = os.getComputerID()
  msg.sensorId = msg.sensorId or os.getComputerID()
  msg.originId = msg.originId or os.getComputerID()
  rednet.broadcast(msg, P)
  if managerId and managerId ~= os.getComputerID() then
    rednet.send(managerId, msg, P)
  end
  local mainId = titan.getMainRouterId and titan.getMainRouterId()
  if mainId and mainId ~= os.getComputerID() then
    local hop = {}
    for k, v in pairs(msg) do hop[k] = v end
    hop.hop = true
    hop.originId = os.getComputerID()
    rednet.send(mainId, hop, P)
    -- Router protocol so MAIN's directory loop always sees it for forwarding.
    rednet.send(mainId, hop, titan.ROUTER_PROTOCOL or "titan_router")
  end
end

local function rememberManager(id, msg)
  id = tonumber(id)
  if not id or id == os.getComputerID() then return end
  if msg and msg.kind and msg.kind ~= "manager" and msg.kind ~= "perimeter_manager" then
    return
  end
  managerId = id
  if msg and msg.origin then
    managerOrigin = {
      x = msg.origin.x, y = msg.origin.y, z = msg.origin.z,
    }
  end
end

local function requestManagerViaRouter()
  local mainId = titan.getMainRouterId and titan.getMainRouterId()
  if not mainId then return end
  rednet.send(mainId, {
    type = MSG.PERIMETER_ROSTER_REQ or "perimeter_roster_req",
    kind = "perimeter_sensor",
    from = os.getComputerID(),
    gate = cfg.name or os.getComputerLabel(),
  }, titan.ROUTER_PROTOCOL or "titan_router")
end

local function runForcedUpdate(fromId, reason, opts)
  opts = opts or {}
  if otaBusy then return false, "busy" end
  otaBusy = true
  print("")
  print("[OTA] " .. tostring(reason or "Forced update"))
  local prev = titan.systemVersion and titan.systemVersion() or "?"
  local uok, detail = titan.updateSelf()
  if not uok then
    print("[OTA] Update failed: " .. tostring(detail))
    if fromId then
      rednet.send(fromId, {
        type = MSG.PERIMETER_UPDATE_FAIL or "perimeter_update_fail",
        err = tostring(detail),
        version = prev,
        gate = cfg.name or os.getComputerLabel() or ("Gate-" .. os.getComputerID()),
        sensorId = os.getComputerID(),
      }, P)
    end
    otaBusy = false
    return false, detail
  end
  local ver = titan.systemVersion and titan.systemVersion() or "?"
  print(("[OTA] Updated v%s -> v%s"):format(tostring(prev), tostring(ver)))
  if fromId then
    rednet.send(fromId, {
      type = MSG.PERIMETER_UPDATE_ACK or "perimeter_update_ack",
      version = ver,
      prev = prev,
      gate = cfg.name or os.getComputerLabel() or ("Gate-" .. os.getComputerID()),
      sensorId = os.getComputerID(),
    }, P)
  end
  if opts.reboot ~= false then
    print("[OTA] Rebooting...")
    sleep(1)
    os.reboot()
  end
  otaBusy = false
  return true, detail
end

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

-- Bearing from manager origin → this sensor (Minecraft: +X east, +Z south).
local function sectorFromDelta(dx, dz)
  if dx == 0 and dz == 0 then return "north" end
  local ang = math.deg(math.atan2(dx, -dz))
  if ang < 0 then ang = ang + 360 end
  local sectors = {
    "north", "northeast", "east", "southeast",
    "south", "southwest", "west", "northwest",
  }
  local idx = math.floor((ang + 22.5) / 45) % 8
  return sectors[idx + 1]
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
  if cfg.autoName == false or not cfg.side then return false end
  local name = sidePretty(cfg.side) .. " Gate"
  if cfg.name == name and os.getComputerLabel() == name then return false end
  cfg.name = name
  os.setComputerLabel(name)
  return true
end

-- Name / side from GPS vs manager origin (self-assign).
local function selfAssignFromOrigin(origin, opts)
  opts = opts or {}
  if type(origin) ~= "table" or not origin.x or not origin.z then return false end
  managerOrigin = { x = origin.x, y = origin.y, z = origin.z }
  locateGps()
  if not lastPos.x then return false end
  local dx = lastPos.x - managerOrigin.x
  local dz = lastPos.z - managerOrigin.z
  local side = sectorFromDelta(dx, dz)
  local changed = false
  if side ~= cfg.side then
    cfg.side = side
    changed = true
  end
  if cfg.autoName ~= false then
    if applyNameFromSide() then changed = true end
  end
  if changed then
    saveCfg()
    if not opts.quiet then
      print(("Self-named %s from manager (dx=%d dz=%d)"):format(
        gateLabel(), dx, dz))
    end
    broadcastHello()
  end
  return true
end

local function sendEvent(msgType, player, extra)
  local utc, text = stamp()
  local payload = {
    type = msgType,
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
  deliverPerimeter(payload)
end

broadcastHello = function(extra)
  locateGps()
  local payload = {
    type = MSG.PERIMETER_HELLO or "perimeter_hello",
    kind = "sensor",
    side = cfg.side,
    gate = gateLabel(),
    sensorId = os.getComputerID(),
    range = cfg.range,
    autoName = (cfg.autoName ~= false),
    x = lastPos.x, y = lastPos.y, z = lastPos.z,
    wantAssign = (cfg.side == nil) or (extra and extra.wantAssign),
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do payload[k] = v end
  end
  deliverPerimeter(payload)
end

local function requestAssign()
  locateGps()
  if not lastPos.x then
    print("No GPS — cannot auto-assign. Set side manually or fix GPS.")
    return false
  end
  deliverPerimeter({
    type = MSG.PERIMETER_ASSIGN_REQ or "perimeter_assign_req",
    kind = "sensor",
    sensorId = os.getComputerID(),
    gate = gateLabel(),
    range = cfg.range,
    x = lastPos.x, y = lastPos.y, z = lastPos.z,
    wantAssign = true,
  })
  if not managerId then requestManagerViaRouter() end
  print(("Assign requested @ %d,%d,%d (manager=%s)"):format(
    lastPos.x, lastPos.y, lastPos.z, tostring(managerId or "via-router")))
  return true
end

local function applyConfig(msg)
  local changed = false
  -- autoName first so side/name handling respects manager intent
  if msg.autoName ~= nil then
    cfg.autoName = not not msg.autoName
  end
  if msg.side then
    local s = normalizeSide(msg.side)
    if s and s ~= cfg.side then
      cfg.side = s
      changed = true
      if cfg.autoName ~= false then applyNameFromSide() end
    elseif s and cfg.autoName ~= false then
      if applyNameFromSide() then changed = true end
    end
  end
  if msg.range ~= nil then
    local r = math.floor(tonumber(msg.range) or 0)
    if r >= 1 and r ~= cfg.range then
      cfg.range = r
      changed = true
    end
  end
  -- Gate display name. Direction assign sends name + autoName=true.
  -- rename sends name without keeping autoname (autoName false / omitted → custom).
  if msg.name and tostring(msg.name) ~= "" then
    local newName = tostring(msg.name)
    if cfg.name ~= newName then
      cfg.name = newName
      os.setComputerLabel(cfg.name)
      changed = true
    end
    if msg.autoName == nil and cfg.autoName ~= false then
      cfg.autoName = false
      changed = true
    end
  end
  if msg.poll ~= nil then
    local p = tonumber(msg.poll)
    if p and p >= 0.2 then cfg.poll = p; changed = true end
  end
  if changed then
    saveCfg()
    print(("Config from manager: side=%s range=%s name=%s%s"):format(
      tostring(cfg.side), tostring(cfg.range), gateLabel(),
      (cfg.autoName == false) and " (custom)" or ""))
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
  deliverPerimeter({
    type = MSG.PERIMETER_PULSE or "perimeter_pulse",
    side = cfg.side,
    gate = gateLabel(),
    sensorId = os.getComputerID(),
    players = list,
    range = cfg.range,
    ts = utc,
    time = text,
    x = lastPos.x, y = lastPos.y, z = lastPos.z,
  })
end

local function printHelp()
  print("Perimeter sensor — Player Detector gate")
  print("  side <n|ne|e|se|s|sw|w|nw>   manual sector")
  print("  range <blocks>               default " .. DEFAULT_RANGE)
  print("  name <label>                 custom label (locks auto-name)")
  print("  autoname                     name from direction vs manager")
  print("  auto                         ask manager to assign from GPS")
  print("  update [-y]                  download packages (reboot with -y)")
  print("  poll <seconds>               scan rate (default 0.5)")
  print("  status | help")
  print("Auto-names from manager origin (North Gate, …). Manager: rename / update")
end

local function printStatus()
  print("gate: " .. gateLabel() .. (cfg.autoName == false and " (custom)" or " (auto)"))
  print("side: " .. tostring(cfg.side and (sidePretty(cfg.side) .. " (" .. sideAbbrev(cfg.side) .. ")") or "(waiting for manager origin / assign)"))
  print("range: " .. tostring(cfg.range) .. "  poll: " .. tostring(cfg.poll))
  locateGps()
  if lastPos.x then
    print(("gps: %d,%d,%d"):format(lastPos.x, lastPos.y, lastPos.z))
  else
    print("gps: (none — needed for auto-name)")
  end
  if managerOrigin then
    print(("manager origin: %d,%d,%d"):format(
      managerOrigin.x, managerOrigin.y or 0, managerOrigin.z))
  else
    print("manager origin: (not heard yet)")
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
      print("name = " .. gateLabel() .. (cfg.autoName == false and " (custom)" or " (auto)"))
    else
      cfg.name = table.concat(a, " ", 2)
      cfg.autoName = false
      saveCfg()
      os.setComputerLabel(cfg.name)
      print("name = " .. cfg.name .. " (custom)")
      broadcastHello()
    end
  elseif cmd == "autoname" or cmd == "autolabel" then
    cfg.autoName = true
    if managerOrigin then
      selfAssignFromOrigin(managerOrigin)
    elseif cfg.side then
      applyNameFromSide()
      saveCfg()
      print("name = " .. gateLabel() .. " (auto)")
      broadcastHello()
    else
      saveCfg()
      print("Auto-name on — waiting for manager origin or side.")
      requestAssign()
    end
  elseif cmd == "auto" or cmd == "assign" then
    if managerOrigin then selfAssignFromOrigin(managerOrigin) end
    requestAssign()
  elseif cmd == "update" or cmd == "upgrade" then
    local auto = (a[2] == "-y" or a[2] == "--yes" or a[2] == "yes")
    -- Over SSH: update then return "reboot" so the client gets an ACK first.
    local viaSsh = titan.sshIsAuthed and titan.sshIsAuthed()
    local ok, detail = runForcedUpdate(nil, "Manual update", { reboot = false })
    if not ok then
      print("Update failed: " .. tostring(detail))
      return true
    end
    if auto or viaSsh then
      print("Updated — rebooting.")
      return "reboot"
    end
    write("Reboot now to load new code? [Y/n] ")
    local yn = (read() or ""):lower()
    if yn == "" or yn == "y" then return "reboot" end
    return true
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
-- Keep stock label until direction auto-name or a custom name is set.
if cfg.name then
  os.setComputerLabel(cfg.name)
elseif os.getComputerLabel() then
  -- leave existing label; auto-name will replace when origin is known
else
  os.setComputerLabel("Perimeter-" .. os.getComputerID())
end
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
  if cfg.autoName ~= false then applyNameFromSide() end
else
  print("No side yet — will self-name from manager origin (needs GPS)...")
  requestAssign()
end
print("Type help. Manager: rename <id> <label>")
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
    if not managerId or (n % 3 == 0) then
      requestManagerViaRouter()
    end
    sleep(15)
  end
end

local function netLoop()
  local routerProto = titan.ROUTER_PROTOCOL or "titan_router"
  while true do
    local id, msg, proto = rednet.receive(nil, 1)
    if type(msg) == "table" then
      local t = msg.type
      if t == MSG.PERIMETER_CONFIG or t == "perimeter_config" then
        local target = msg.sensorId or msg.id or msg.to
        if target == nil or tonumber(target) == os.getComputerID()
            or target == "*" or target == "all" then
          if id then rememberManager(id, { kind = "manager" }) end
          applyConfig(msg)
        end
      elseif t == MSG.PERIMETER_UPDATE or t == "perimeter_update" then
        local target = msg.sensorId or msg.id or msg.to
        if target == nil or tonumber(target) == os.getComputerID()
            or target == "*" or target == "all" then
          runForcedUpdate(id, "Manager force-update", { reboot = true })
        end
      elseif (t == MSG.PERIMETER_HELLO or t == "perimeter_hello")
          and (msg.kind == "manager" or msg.kind == "perimeter_manager") then
        rememberManager(id, msg)
        if msg.origin then
          selfAssignFromOrigin(msg.origin)
        end
        if not cfg.side then requestAssign() end
      elseif (t == MSG.PERIMETER_ROSTER or t == "perimeter_roster")
          or (proto == routerProto and t == "perimeter_roster") then
        local managers = msg.managers or {}
        if #managers > 0 then
          rememberManager(managers[1].id, { kind = "manager" })
          print("Manager via router: #" .. tostring(managerId))
        end
      elseif t == MSG.PERIMETER_FWD or t == "perimeter_fwd" then
        local payload = msg.payload
        if type(payload) == "table" then
          local target = payload.sensorId or payload.id or payload.to or msg.dest
          if target == nil or tonumber(target) == os.getComputerID()
              or target == "*" or target == "all" then
            local pt = payload.type
            if pt == MSG.PERIMETER_CONFIG or pt == "perimeter_config" then
              applyConfig(payload)
            elseif pt == MSG.PERIMETER_UPDATE or pt == "perimeter_update" then
              runForcedUpdate(id, "Manager force-update (hop)", { reboot = true })
            end
          end
        end
      end
    end
  end
end

local function consoleLoop()
  while true do
    write("gate> ")
    local r = handleCommand(read())
    if r == "exit" then return end
    if r == "reboot" then
      print("Rebooting...")
      sleep(0.5)
      os.reboot()
    end
  end
end

titan.setSshHandler(function(line)
  local r = handleCommand(line)
  if r == "reboot" then return "reboot" end
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
