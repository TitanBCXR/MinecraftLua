--[[
  perimeter_sensor.lua  -  Territory sensor (Advanced Peripherals Player Detector)
  Titan-Version: 1.2.7

  Place on a computer with:
    * Advanced Peripherals Player Detector (adjacent / networked)
    * Wireless modem (joins the Titan mesh)
    * GPS in range (approach bearing, auto-name, and optional GPS host)

  Modes:
    * Multi-gate: manager assigns side -> North Gate, East Gate, ...
    * Single-sensor: no side required; covers whole area (raise ranges).
      On ENTER: approach bearing + player Y level.

  Also hosts GPS for routers/nav (gpshost on by default when a fix exists).

  Range is a half-extent per axis (blocks from the detector):
    range <n>           set X=Y=Z
    range x|y|z <n>     set one axis (e.g. wide X, short Z)

  Reports only to ONE bound perimeter manager (not the whole mesh).

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
  side = nil,       -- 8-way compass sector (optional for single-sensor mode)
  range = DEFAULT_RANGE,  -- legacy / default half-extent when axis unset
  rangeX = nil,     -- X half-extent (blocks from detector); nil -> range
  rangeY = nil,     -- Y half-extent (height); nil -> range
  rangeZ = nil,     -- Z half-extent; nil -> range
  name = nil,
  poll = 0.5,
  autoName = true,  -- rename label when manager assigns a side
  ignore = {},      -- [lowercase] = display name (synced from manager)
  managerId = nil,  -- locked perimeter manager computer id
  gpsHost = true,   -- answer gps.locate for routers / nav (via titan.relayLoop)
  gpsCoords = nil,  -- optional {x,y,z}; else live GPS fix
}

local seen = {}
local detector = nil
local lastPos = { x = nil, y = nil, z = nil }
local managerOrigin = nil
local managerId = nil          -- perimeter manager computer id (direct or via mesh)
local otaBusy = false
local broadcastHello -- forward decl (used by self-assign)
local saveCfg        -- forward decl (used by setBoundManager)
local locateGps      -- forward decl (used by syncGpsHost)

local function boundManagerId()
  return tonumber(cfg.managerId) or tonumber(managerId)
end

local function setBoundManager(id, opts)
  opts = opts or {}
  id = tonumber(id)
  if not id or id == os.getComputerID() then return false end
  local prev = cfg.managerId
  cfg.managerId = id
  managerId = id
  if prev ~= id then
    saveCfg()
    if not opts.quiet then
      print("Bound manager #" .. tostring(id))
    end
  end
  return true
end

-- Deliver to the bound manager only (unicast + targeted MAIN hop).
-- Discovery hellos may flood until a manager is locked.
local function deliverPerimeter(msg, opts)
  opts = opts or {}
  if type(msg) ~= "table" then return false end
  msg.from = os.getComputerID()
  msg.sensorId = msg.sensorId or os.getComputerID()
  msg.originId = msg.originId or os.getComputerID()
  local dest = boundManagerId()
  if dest then msg.managerId = dest end

  local t = tostring(msg.type or "")
  local isHello = (t == (MSG.PERIMETER_HELLO or "perimeter_hello")
    or t == (MSG.PERIMETER_ASSIGN_REQ or "perimeter_assign_req"))

  if dest and dest ~= os.getComputerID() and not opts.flood then
    rednet.send(dest, msg, P)
    local mainId = titan.getMainRouterId and titan.getMainRouterId()
    if mainId and mainId ~= os.getComputerID() and mainId ~= dest then
      rednet.send(mainId, {
        type = MSG.PERIMETER_FWD or "perimeter_fwd",
        dest = dest,
        originId = os.getComputerID(),
        payload = msg,
        from = os.getComputerID(),
        managerId = dest,
      }, titan.ROUTER_PROTOCOL or "titan_router")
    end
    return true
  end

  -- Unbound: only discovery traffic may broadcast; never flood events/pulses.
  if opts.flood or (isHello and not dest) then
    rednet.broadcast(msg, P)
    local mainId = titan.getMainRouterId and titan.getMainRouterId()
    if mainId and mainId ~= os.getComputerID() then
      local hop = {}
      for k, v in pairs(msg) do hop[k] = v end
      hop.hop = true
      hop.originId = os.getComputerID()
      rednet.send(mainId, hop, titan.ROUTER_PROTOCOL or "titan_router")
    end
    return true
  end
  return false
end

local function rememberManager(id, msg)
  id = tonumber(id)
  if not id or id == os.getComputerID() then return end
  if msg and msg.kind and msg.kind ~= "manager" and msg.kind ~= "perimeter_manager" then
    return
  end
  -- Locked sensors ignore other managers.
  if cfg.managerId and cfg.managerId ~= id then return end
  managerId = id
  if not cfg.managerId then
    setBoundManager(id, { quiet = true })
  end
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

saveCfg = function()
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
  if type(cfg.ignore) ~= "table" then cfg.ignore = {} end
  if cfg.managerId ~= nil then
    cfg.managerId = tonumber(cfg.managerId)
    managerId = cfg.managerId
  end
  for _, k in ipairs({ "rangeX", "rangeY", "rangeZ" }) do
    if cfg[k] ~= nil then cfg[k] = tonumber(cfg[k]) end
  end
  if cfg.gpsHost == nil then cfg.gpsHost = true end
  if type(cfg.gpsCoords) == "table" and cfg.gpsCoords.x and cfg.gpsCoords.z then
    cfg.gpsCoords = {
      x = math.floor(tonumber(cfg.gpsCoords.x) + 0.5),
      y = math.floor(tonumber(cfg.gpsCoords.y or 0) + 0.5),
      z = math.floor(tonumber(cfg.gpsCoords.z) + 0.5),
    }
  else
    cfg.gpsCoords = nil
  end
end

local function axisRange(axis)
  local v = nil
  if axis == "x" then v = cfg.rangeX
  elseif axis == "y" then v = cfg.rangeY
  elseif axis == "z" then v = cfg.rangeZ
  end
  v = tonumber(v) or tonumber(cfg.range) or DEFAULT_RANGE
  return math.max(1, math.floor(v))
end

local function rangeSummary()
  return ("X=%d Y=%d Z=%d"):format(axisRange("x"), axisRange("y"), axisRange("z"))
end

local function syncGpsHost()
  if cfg.gpsHost == false then
    if titan.setGpsHost then titan.setGpsHost(false) end
    return false
  end
  local c = cfg.gpsCoords
  if not (c and c.x and c.z) then
    locateGps()
    if lastPos.x then
      c = { x = lastPos.x, y = lastPos.y or 0, z = lastPos.z }
    end
  end
  if c and c.x and c.z and titan.setGpsHost then
    titan.setGpsHost(c)
    return true
  end
  if titan.setGpsHost then titan.setGpsHost(false) end
  return false
end

local function ignoreKey(name)
  return tostring(name or ""):lower()
end

local function isIgnored(name)
  return type(cfg.ignore) == "table" and cfg.ignore[ignoreKey(name)] ~= nil
end

local function applyIgnoreList(list)
  local nextMap = {}
  if type(list) == "table" then
    for k, v in pairs(list) do
      if type(k) == "number" and type(v) == "string" and v:match("%S") then
        nextMap[ignoreKey(v)] = v:match("^%s*(.-)%s*$")
      elseif type(k) == "string" and k:match("%S") then
        local display = (type(v) == "string" and v:match("%S")) and v or k
        nextMap[ignoreKey(k)] = display:match("^%s*(.-)%s*$")
      end
    end
  end
  local prev = cfg.ignore or {}
  local changed = false
  for k, v in pairs(nextMap) do
    if prev[k] ~= v then changed = true; break end
  end
  if not changed then
    for k in pairs(prev) do
      if nextMap[k] == nil then changed = true; break end
    end
  end
  cfg.ignore = nextMap
  return changed
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

locateGps = function()
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
  if cfg.name and cfg.name ~= "" then return cfg.name end
  local label = os.getComputerLabel()
  if label and label ~= "" then return label end
  if cfg.side then return sidePretty(cfg.side) .. " Gate" end
  return "Territory"
end

local function applyNameFromSide()
  if cfg.autoName == false then return false end
  local name
  if cfg.side then
    name = sidePretty(cfg.side) .. " Gate"
  else
    name = "Territory"
  end
  if cfg.name == name and os.getComputerLabel() == name then return false end
  cfg.name = name
  os.setComputerLabel(name)
  return true
end

-- Player world pos via Advanced Peripherals (nil if unavailable).
local function playerWorldPos(name)
  if not detector or type(name) ~= "string" then return nil end
  local ok, pos = pcall(function() return detector.getPlayerPos(name) end)
  if ok and type(pos) == "table" and pos.x and pos.z then
    return math.floor(pos.x + 0.5), math.floor((pos.y or 0) + 0.5), math.floor(pos.z + 0.5)
  end
  return nil
end

-- Bearing from this sensor toward the player (approach direction).
local function approachFromPlayer(name)
  locateGps()
  local px, py, pz = playerWorldPos(name)
  if not px or not lastPos.x or not lastPos.z then return nil end
  local bearing = sectorFromDelta(px - lastPos.x, pz - lastPos.z)
  return bearing, px, py, pz
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
  local flood = false
  local payload = {
    type = MSG.PERIMETER_HELLO or "perimeter_hello",
    kind = "sensor",
    side = cfg.side,
    gate = gateLabel(),
    sensorId = os.getComputerID(),
    range = cfg.range,
    rangeX = axisRange("x"),
    rangeY = axisRange("y"),
    rangeZ = axisRange("z"),
    gpsHost = (cfg.gpsHost ~= false),
    autoName = (cfg.autoName ~= false),
    x = lastPos.x, y = lastPos.y, z = lastPos.z,
    -- Only request a gate side when explicitly asked (`auto`); nil side = whole-area.
    wantAssign = not not (extra and extra.wantAssign),
  }
  if type(extra) == "table" then
    flood = not not extra.flood
    for k, v in pairs(extra) do
      if k ~= "flood" then payload[k] = v end
    end
  end
  deliverPerimeter(payload, { flood = flood })
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
  if msg.clearSide or msg.side == false or msg.side == "" then
    if cfg.side ~= nil then
      cfg.side = nil
      changed = true
      if cfg.autoName ~= false then applyNameFromSide() end
    end
  elseif msg.side then
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
    if r >= 1 then
      if r ~= cfg.range then cfg.range = r; changed = true end
      -- Uniform range clears per-axis overrides unless axes are in the same msg.
      if msg.rangeX == nil and msg.rangeY == nil and msg.rangeZ == nil then
        if cfg.rangeX or cfg.rangeY or cfg.rangeZ then
          cfg.rangeX, cfg.rangeY, cfg.rangeZ = nil, nil, nil
          changed = true
        end
      end
    end
  end
  for _, axis in ipairs({ "rangeX", "rangeY", "rangeZ" }) do
    if msg[axis] ~= nil then
      local r = math.floor(tonumber(msg[axis]) or 0)
      if r >= 1 and cfg[axis] ~= r then
        cfg[axis] = r
        changed = true
      end
    end
  end
  if msg.gpsHost ~= nil then
    local want = not not msg.gpsHost
    if (cfg.gpsHost ~= false) ~= want then
      cfg.gpsHost = want
      changed = true
    end
  end
  if msg.gpsHere then
    locateGps()
    if lastPos.x then
      cfg.gpsHost = true
      cfg.gpsCoords = { x = lastPos.x, y = lastPos.y or 0, z = lastPos.z }
      changed = true
    end
  end
  if type(msg.gpsCoords) == "table" and msg.gpsCoords.x and msg.gpsCoords.z then
    cfg.gpsCoords = {
      x = math.floor(tonumber(msg.gpsCoords.x) + 0.5),
      y = math.floor(tonumber(msg.gpsCoords.y or 0) + 0.5),
      z = math.floor(tonumber(msg.gpsCoords.z) + 0.5),
    }
    cfg.gpsHost = true
    changed = true
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
  if msg.managerId ~= nil or msg.bindManager ~= nil then
    local mid = tonumber(msg.managerId or msg.bindManager)
    if mid and mid ~= cfg.managerId then
      setBoundManager(mid, { quiet = true })
      changed = true
    end
  end
  if msg.clearManager then
    if cfg.managerId then
      cfg.managerId = nil
      managerId = nil
      changed = true
    end
  end
  if msg.ignore ~= nil then
    if applyIgnoreList(msg.ignore) then changed = true end
  end
  if changed then
    saveCfg()
    local ign = 0
    for _ in pairs(cfg.ignore or {}) do ign = ign + 1 end
    print(("Config from manager: side=%s range=%s name=%s mgr=%s ignore=%d%s"):format(
      tostring(cfg.side or "area"), rangeSummary(), gateLabel(),
      tostring(boundManagerId() or "?"), ign,
      (cfg.autoName == false) and " (custom)" or ""))
    syncGpsHost()
    -- Don't re-hello on ignore/bind-only sync (avoids config loops).
    if msg.side ~= nil or msg.clearSide or msg.range ~= nil
        or msg.rangeX ~= nil or msg.rangeY ~= nil or msg.rangeZ ~= nil
        or msg.name ~= nil or msg.poll ~= nil or msg.autoName ~= nil
        or msg.gpsHost ~= nil or msg.gpsCoords ~= nil or msg.gpsHere then
      broadcastHello()
    end
  end
  return changed
end

local function normalizePlayerList(list)
  local out, set = {}, {}
  if type(list) ~= "table" then return out, set end
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

-- Half-extents on each axis (blocks from detector). Prefer cubic / coords APIs.
local function listInRange()
  if not detector then return {} end
  local rx, ry, rz = axisRange("x"), axisRange("y"), axisRange("z")
  local list = nil
  -- getPlayersInCubic(w,h,d): full cuboid size centered on the detector.
  -- Our ranges are half-extents (same idea as old radial `range`).
  if detector.getPlayersInCubic then
    local ok, res = pcall(function()
      return detector.getPlayersInCubic(rx * 2, ry * 2, rz * 2)
    end)
    if ok and type(res) == "table" then list = res end
  end
  if not list and detector.getPlayersInCoords then
    locateGps()
    if lastPos.x then
      local ok, res = pcall(function()
        return detector.getPlayersInCoords(
          { x = lastPos.x - rx, y = (lastPos.y or 0) - ry, z = lastPos.z - rz },
          { x = lastPos.x + rx + 1, y = (lastPos.y or 0) + ry + 1, z = lastPos.z + rz + 1 }
        )
      end)
      if ok and type(res) == "table" then list = res end
    end
  end
  if not list then
    local span = math.max(rx, ry, rz)
    local ok, res = pcall(function()
      return detector.getPlayersInRange(span)
    end)
    if ok and type(res) == "table" then
      -- Filter spherical results down to the X/Z(/Y) box when we have positions.
      local filtered = {}
      for _, name in ipairs(res) do
        local n = (type(name) == "table" and name.name) or name
        if type(n) == "string" then
          local px, py, pz = playerWorldPos(n)
          if not px then
            filtered[#filtered + 1] = n
          else
            locateGps()
            local cx, cy, cz = lastPos.x or px, lastPos.y or py, lastPos.z or pz
            if math.abs(px - cx) <= rx and math.abs((py or 0) - (cy or 0)) <= ry
                and math.abs(pz - cz) <= rz then
              filtered[#filtered + 1] = n
            end
          end
        end
      end
      list = filtered
    end
  end
  return normalizePlayerList(list)
end

local function scanOnce()
  -- Side is optional: unset = single-sensor whole-area mode.
  if not detector then
    detector = findDetector()
    if not detector then return end
  end
  local list, nowSet = listInRange()
  -- Drop ignored players from the live set / pulse.
  local filtered, filteredSet = {}, {}
  for _, name in ipairs(list) do
    if not isIgnored(name) then
      filtered[#filtered + 1] = name
      filteredSet[name] = true
    elseif seen[name] then
      seen[name] = nil -- silently drop if they were tracked before ignore
    end
  end
  list, nowSet = filtered, filteredSet

  for name in pairs(nowSet) do
    if not seen[name] then
      seen[name] = true
      local approach, px, py, pz = approachFromPlayer(name)
      local via = approach or cfg.side
      print(("[%s] ENTER %s from %s at Y=%s"):format(
        os.date("%H:%M:%S") or "?", name, sideAbbrev(via),
        py ~= nil and tostring(py) or "?"))
      sendEvent(MSG.PERIMETER_ENTER or "perimeter_enter", name, {
        approach = approach,
        side = cfg.side or approach,
        playerX = px, playerY = py, playerZ = pz,
        entryY = py,
      })
    end
  end
  for name in pairs(seen) do
    if not nowSet[name] then
      seen[name] = nil
      local approach, px, py, pz = approachFromPlayer(name)
      local via = approach or cfg.side
      print(("[%s] EXIT  %s via %s Y=%s"):format(
        os.date("%H:%M:%S") or "?", name, sideAbbrev(via),
        py ~= nil and tostring(py) or "?"))
      sendEvent(MSG.PERIMETER_EXIT or "perimeter_exit", name, {
        approach = approach,
        side = cfg.side or approach,
        playerX = px, playerY = py, playerZ = pz,
        entryY = py,
      })
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
    rangeX = axisRange("x"),
    rangeY = axisRange("y"),
    rangeZ = axisRange("z"),
    ts = utc,
    time = text,
    x = lastPos.x, y = lastPos.y, z = lastPos.z,
  })
end

local function printHelp()
  print("Perimeter sensor - Player Detector")
  print("  side <n|ne|e|se|s|sw|w|nw>   gate sector (optional)")
  print("  range <n>                    set X=Y=Z half-extent (default 50)")
  print("  range x|y|z <n>              set one axis (blocks from detector)")
  print("  rangex|rangey|rangez <n>     same")
  print("  gpshost [on|off|here|x y z]  host GPS for routers/nav")
  print("  name <label>                 custom label (locks auto-name)")
  print("  autoname                     name from direction vs manager")
  print("  auto                         ask manager to assign from GPS")
  print("  update [-y]                  download packages (reboot with -y)")
  print("  poll <seconds>               scan rate (default 0.5)")
  print("  manager <id>|clear           lock reports to one manager")
  print("  status | help")
  print("No side = whole-area mode (approach bearing + enter Y).")
  print("Reports only go to the bound manager (not whole mesh).")
end

local function printStatus()
  print("gate: " .. gateLabel() .. (cfg.autoName == false and " (custom)" or " (auto)"))
  if cfg.side then
    print("side: " .. sidePretty(cfg.side) .. " (" .. sideAbbrev(cfg.side) .. ")")
  else
    print("side: (none - whole-area / approach bearing)")
  end
  print("range: " .. rangeSummary() .. "  poll: " .. tostring(cfg.poll))
  print("manager: #" .. tostring(boundManagerId() or "(unbound - discovering)"))
  locateGps()
  if lastPos.x then
    print(("gps: %d,%d,%d"):format(lastPos.x, lastPos.y, lastPos.z))
  else
    print("gps: (none - needed for approach / auto-name / gpshost)")
  end
  if cfg.gpsHost == false then
    print("gpshost: off")
  else
    local c = cfg.gpsCoords or (lastPos.x and lastPos) or nil
    if c and c.x then
      print(("gpshost: on @ %d,%d,%d"):format(c.x, c.y or 0, c.z))
    else
      print("gpshost: on (waiting for GPS fix)")
    end
  end
  if managerOrigin then
    print(("manager origin: %d,%d,%d"):format(
      managerOrigin.x, managerOrigin.y or 0, managerOrigin.z))
  else
    print("manager origin: (not heard yet)")
  end
  local d, kind = findDetector()
  print("detector: " .. (d and kind or "NOT FOUND"))
  local ign = {}
  for _, display in pairs(cfg.ignore or {}) do ign[#ign + 1] = display end
  table.sort(ign, function(a, b) return a:lower() < b:lower() end)
  if #ign == 0 then
    print("ignore: (none)")
  else
    print("ignore: " .. table.concat(ign, ", "))
  end
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
  elseif cmd == "range" or cmd == "rangex" or cmd == "rangey" or cmd == "rangez" then
    local axis, n
    if cmd == "rangex" then axis, n = "x", tonumber(a[2])
    elseif cmd == "rangey" then axis, n = "y", tonumber(a[2])
    elseif cmd == "rangez" then axis, n = "z", tonumber(a[2])
    else
      local a2 = (a[2] or ""):lower()
      if a2 == "x" or a2 == "y" or a2 == "z" then
        axis, n = a2, tonumber(a[3])
      else
        n = tonumber(a[2])
      end
    end
    if axis then
      if not n or n < 1 then
        print("Usage: range " .. axis .. " <blocks>")
      else
        local key = "range" .. axis:upper()
        cfg[key] = math.floor(n)
        saveCfg()
        print(key .. " = " .. cfg[key] .. "  (" .. rangeSummary() .. ")")
        broadcastHello()
      end
    elseif not n or n < 1 then
      print("range " .. rangeSummary())
      print("Usage: range <n>   or   range x|y|z <n>")
    else
      cfg.range = math.floor(n)
      cfg.rangeX, cfg.rangeY, cfg.rangeZ = nil, nil, nil
      saveCfg()
      print("range X=Y=Z = " .. cfg.range)
      broadcastHello()
    end
  elseif cmd == "gpshost" or cmd == "gps" then
    local sub = (a[2] or ""):lower()
    if sub == "" or sub == "status" then
      syncGpsHost()
      printStatus()
    elseif sub == "off" or sub == "disable" or sub == "false" then
      cfg.gpsHost = false
      saveCfg()
      syncGpsHost()
      print("gpshost off")
    elseif sub == "on" or sub == "enable" or sub == "true" then
      cfg.gpsHost = true
      saveCfg()
      local ok = syncGpsHost()
      print(ok and "gpshost on" or "gpshost on (need GPS fix or gpshost x y z)")
    elseif sub == "here" or sub == "auto" then
      locateGps()
      if not lastPos.x then
        print("No GPS fix.")
      else
        cfg.gpsHost = true
        cfg.gpsCoords = { x = lastPos.x, y = lastPos.y or 0, z = lastPos.z }
        saveCfg()
        syncGpsHost()
        print(("gpshost @ %d,%d,%d"):format(cfg.gpsCoords.x, cfg.gpsCoords.y, cfg.gpsCoords.z))
      end
    else
      local x, y, z = tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
      if not (x and y and z) then
        print("Usage: gpshost on|off|here|<x> <y> <z>")
      else
        cfg.gpsHost = true
        cfg.gpsCoords = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
        saveCfg()
        syncGpsHost()
        print(("gpshost @ %d,%d,%d"):format(cfg.gpsCoords.x, cfg.gpsCoords.y, cfg.gpsCoords.z))
      end
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
  elseif cmd == "manager" or cmd == "mgr" or cmd == "bind" then
    local sub = (a[2] or ""):lower()
    if sub == "" or sub == "status" or sub == "show" then
      print("manager: #" .. tostring(boundManagerId() or "(unbound)"))
    elseif sub == "clear" or sub == "none" or sub == "off" then
      cfg.managerId = nil
      managerId = nil
      saveCfg()
      print("Manager unbound — discovery flood until next bind.")
    else
      local id = tonumber(a[2])
      if not id then
        print("Usage: manager <id> | manager clear")
      else
        setBoundManager(id)
        broadcastHello()
      end
    end
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
  print("Detector OK.  range " .. rangeSummary())
  syncGpsHost()
end
if cfg.side then
  print("side = " .. sidePretty(cfg.side) .. " (" .. sideAbbrev(cfg.side) .. ")")
  if cfg.autoName ~= false then applyNameFromSide() end
else
  print("Whole-area mode (no side) - scanning now; approach bearing on enter.")
  print("Multi-gate layout: type `auto` (or set side) after manager `here`.")
  if cfg.autoName ~= false then applyNameFromSide() end
end
do
  local mid = boundManagerId()
  if mid then
    print("manager: #" .. tostring(mid) .. " (reports locked)")
  else
    print("manager: unbound - will lock to first manager hello")
  end
  local ign = 0
  for _ in pairs(cfg.ignore or {}) do ign = ign + 1 end
  if ign > 0 then print("ignore list: " .. ign .. " player(s)") end
end
print("Type help.  manager <id>  |  status")
print("")

local function scanLoop()
  while true do
    local ok, err = pcall(scanOnce)
    if not ok then print("scan error: " .. tostring(err)) end
    sleep(tonumber(cfg.poll) or 0.5)
  end
end

local function helloLoop()
  if titan.netJitter then titan.netJitter(1.5) else sleep((((os.getComputerID() or 0) % 10) / 10)) end
  local n = 0
  while true do
    n = n + 1
    syncGpsHost()
    -- Flood only until bound to a manager (mesh discovery).
    local bound = boundManagerId()
    broadcastHello({
      flood = not bound,
    })
    if not bound or (n % 4 == 0) then
      requestManagerViaRouter()
    end
    sleep(28)
  end
end

local function handleNetMsg(id, msg, proto)
  local routerProto = titan.ROUTER_PROTOCOL or "titan_router"
  if type(msg) ~= "table" then return end
  local t = msg.type
  if t == MSG.PERIMETER_CONFIG or t == "perimeter_config" then
    local target = msg.sensorId or msg.id or msg.to
    if target == nil or tonumber(target) == os.getComputerID()
        or target == "*" or target == "all" then
      -- Only accept config from bound manager once locked.
      local bound = boundManagerId()
      local fromId = tonumber(msg.from) or tonumber(id)
      if bound and fromId and fromId ~= bound then return end
      if id then rememberManager(id, { kind = "manager" }) end
      applyConfig(msg)
    end
  elseif t == MSG.PERIMETER_UPDATE or t == "perimeter_update" then
    local target = msg.sensorId or msg.id or msg.to
    if target == nil or tonumber(target) == os.getComputerID()
        or target == "*" or target == "all" then
      local bound = boundManagerId()
      local fromId = tonumber(msg.from) or tonumber(id)
      if bound and fromId and fromId ~= bound then return end
      runForcedUpdate(id, "Manager force-update", { reboot = true })
    end
  elseif (t == MSG.PERIMETER_HELLO or t == "perimeter_hello")
      and (msg.kind == "manager" or msg.kind == "perimeter_manager") then
    rememberManager(id, msg)
    if msg.origin and (not cfg.managerId or cfg.managerId == tonumber(id)) then
      managerOrigin = {
        x = msg.origin.x, y = msg.origin.y, z = msg.origin.z,
      }
      -- Multi-gate only: refresh side/name if already assigned.
      if cfg.side then
        selfAssignFromOrigin(msg.origin, { quiet = true })
      end
    end
  elseif (t == MSG.PERIMETER_ROSTER or t == "perimeter_roster")
      or (proto == routerProto and t == "perimeter_roster") then
    local managers = msg.managers or {}
    if #managers > 0 and not boundManagerId() then
      rememberManager(managers[1].id, { kind = "manager" })
      print("Bound manager via router: #" .. tostring(boundManagerId()))
    end
  elseif t == MSG.PERIMETER_FWD or t == "perimeter_fwd" then
    local payload = msg.payload
    if type(payload) == "table" then
      local target = payload.sensorId or payload.id or payload.to or msg.dest
      if target == nil or tonumber(target) == os.getComputerID()
          or target == "*" or target == "all" then
        local bound = boundManagerId()
        local fromId = tonumber(payload.from) or tonumber(msg.from) or tonumber(id)
        if bound and fromId and fromId ~= bound then return end
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

local function netLoop()
  while true do
    local id, msg, proto = rednet.receive(nil, 1)
    local batch = {}
    if type(msg) == "table" and id then batch[#batch + 1] = { id, msg, proto } end
    for _ = 1, 12 do
      local id2, msg2, proto2 = rednet.receive(nil, 0)
      if not id2 then break end
      if type(msg2) == "table" then batch[#batch + 1] = { id2, msg2, proto2 } end
    end
    for bi = 1, #batch do
      handleNetMsg(batch[bi][1], batch[bi][2], batch[bi][3])
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
