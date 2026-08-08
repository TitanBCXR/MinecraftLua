--[[
  perimeter_manager.lua  -  Territory board for perimeter sensors
  Titan-Version: 1.3.8

  Central display for perimeter_sensor.lua gates. Shows who is inside the
  territory, which sector they entered from (N NE E SE S SW W NW), enter time,
  and a rolling enter/exit log with timestamps.

  Layouts:
    * Multi-gate: `here` then `assign all` (one sensor per direction)
    * Single-sensor: one detector covering the whole area (no side required);
      ENTER shows approach bearing from player position vs that sensor

  Sensors bind to THIS manager only (managerId pushed on hello/config).
  Forward ENTER/EXIT to an admin tablet:
    admin <id> | admin clear | admin

  Ignore list: allowed players never trigger ENTER/EXIT (pushed to sensors).
    ignore add|remove <name> | ignore list | ignore clear

  Event log is saved under perimeter_logs/ and reloaded on boot. Files over 5MB
  are deleted. `newlog` starts a fresh log and removes the previous one.

  Remote control of sensors:
    assign [id|all]              auto side/name from GPS vs origin
    rename <id|gate> <label>     custom name for one sensor
    set <id|all> side <dir|clear>
    set <id|all> range <n>
    set <id|all> name <label>
    range <n>                    shorthand: set all range
    ignore add|remove|list|clear allowed players
    admin <id>|clear             admin tablet for alerts / log sync
    update / forceupdate         OTA this board + every perimeter sensor
    origin / here / setpos       territory center
    log [n] | newlog | logs      event history on disk

  Requires: modem, GPS (for auto-assign), lib/titan.lua, optional monitor
]]

local titan = dofile("lib/titan.lua")
local MSG = titan.MSG
local P = titan.PROTOCOL

titan.openModem()

local CFG = "perimeter_manager.cfg"
local LOG_DIR = "perimeter_logs"
local LOG_MAX = 80                 -- lines kept in memory / on screen
local LOG_MAX_BYTES = 5 * 1024 * 1024  -- 5 MiB per log file
local DEFAULT_SENSOR_RANGE = 50
local cfg = {
  title = "Territory",
  grace = 4,
  defaultRange = DEFAULT_SENSOR_RANGE,
  origin = nil,  -- {x,y,z} manager / territory center
  logFile = nil, -- current log path under LOG_DIR
  ignore = {},   -- [lowercase] = display name (allowed / no alerts)
  adminId = nil, -- admin tablet computer id (alerts + log replies)
}

local present = {}
local log = {}
local sensors = {}      -- [id] = { side, gate, seen, players, x,y,z, range }
local dirty = true
local updateAcks = {}   -- [id] = ack msg (force-update campaign)
local updateFails = {}  -- [id] = fail msg
local hopViaMainRouter  -- forward decl (notifyAdmin / log reply)
local sendConfig        -- forward decl (bindSensorToSelf)

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
  if cfg.defaultRange == nil then cfg.defaultRange = DEFAULT_SENSOR_RANGE end
  if type(cfg.ignore) ~= "table" then cfg.ignore = {} end
  if cfg.adminId ~= nil then cfg.adminId = tonumber(cfg.adminId) end
end

local function ignoreKey(name)
  return tostring(name or ""):lower()
end

local function isIgnored(name)
  return type(cfg.ignore) == "table" and cfg.ignore[ignoreKey(name)] ~= nil
end

local function ignoreListSorted()
  local list = {}
  for _, display in pairs(cfg.ignore or {}) do
    list[#list + 1] = display
  end
  table.sort(list, function(a, b) return a:lower() < b:lower() end)
  return list
end

local function dropIgnoredPresent(name)
  local key = ignoreKey(name)
  local remove = {}
  for pname in pairs(present) do
    if ignoreKey(pname) == key then remove[#remove + 1] = pname end
  end
  for _, pname in ipairs(remove) do
    present[pname] = nil
    dirty = true
  end
  return #remove
end

local function nowUtc() return os.epoch("utc") end

local function formatTime(utc, fallback)
  if fallback and fallback ~= "" then return fallback end
  local ok, text = pcall(os.date, "!%Y-%m-%d %H:%M:%S", math.floor((utc or 0) / 1000))
  if ok and type(text) == "string" then return text end
  ok, text = pcall(os.date, "%H:%M:%S")
  return (ok and text) or tostring(utc or "?")
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

local function sideShort(s)
  s = normalizeSide(s) or tostring(s or "?"):lower()
  local a = {
    north = "N", northeast = "NE", east = "E", southeast = "SE",
    south = "S", southwest = "SW", west = "W", northwest = "NW",
  }
  return a[s] or s:sub(1, 2):upper()
end

local function sidePretty(s)
  s = normalizeSide(s)
  local pretty = {
    north = "North", northeast = "Northeast", east = "East",
    southeast = "Southeast", south = "South", southwest = "Southwest",
    west = "West", northwest = "Northwest",
  }
  return pretty[s] or tostring(s or "?")
end

-- Bearing from origin to point → 8-way sector (Minecraft: +X east, +Z south).
local function sectorFromDelta(dx, dz)
  if dx == 0 and dz == 0 then return "north" end
  -- Angle from north, clockwise, degrees [0,360)
  local ang = math.deg(math.atan2(dx, -dz))
  if ang < 0 then ang = ang + 360 end
  local sectors = {
    "north", "northeast", "east", "southeast",
    "south", "southwest", "west", "northwest",
  }
  local idx = math.floor((ang + 22.5) / 45) % 8
  return sectors[idx + 1]
end

--------------------------------------------------------------------------------
-- Persistent event log (perimeter_logs/, max 5MB per file)
--------------------------------------------------------------------------------
local function ensureLogDir()
  if not fs.exists(LOG_DIR) then fs.makeDir(LOG_DIR) end
end

local function logPath(name)
  if not name or name == "" then return nil end
  name = tostring(name)
  if name:sub(1, #LOG_DIR + 1) == (LOG_DIR .. "/") then return name end
  return LOG_DIR .. "/" .. name
end

local function listLogFiles()
  ensureLogDir()
  local files = {}
  for _, name in ipairs(fs.list(LOG_DIR)) do
    local path = LOG_DIR .. "/" .. name
    if not fs.isDir(path) then
      files[#files + 1] = { name = name, path = path, size = fs.getSize(path) or 0 }
    end
  end
  table.sort(files, function(a, b) return a.name < b.name end)
  return files
end

local function purgeOversizedLogs()
  local removed = 0
  for _, f in ipairs(listLogFiles()) do
    if f.size > LOG_MAX_BYTES then
      pcall(fs.delete, f.path)
      removed = removed + 1
      print(("Deleted oversized log %s (%d bytes > %d)"):format(
        f.name, f.size, LOG_MAX_BYTES))
      if cfg.logFile == f.path or cfg.logFile == f.name then
        cfg.logFile = nil
      end
    end
  end
  if removed > 0 then saveCfg() end
  return removed
end

local function newLogName()
  local ok, stamp = pcall(os.date, "!%Y%m%d-%H%M%S")
  if not ok or type(stamp) ~= "string" then
    stamp = tostring(nowUtc())
  end
  return ("events-%s.log"):format(stamp)
end

local function createEmptyLog(name)
  name = name or newLogName()
  cfg.logFile = name
  saveCfg()
  local path = logPath(name)
  local f = fs.open(path, "w")
  if f then
    f.write("# perimeter event log\n")
    f.write("# kind|time|utc|player|side|gate\n")
    f.close()
  end
  return path
end

-- Resolve active log file; create one only when createIfMissing is true.
local function resolveLogPath(createIfMissing)
  ensureLogDir()
  purgeOversizedLogs()
  local path = logPath(cfg.logFile)
  if path and fs.exists(path) and not fs.isDir(path) then
    if (fs.getSize(path) or 0) > LOG_MAX_BYTES then
      pcall(fs.delete, path)
      cfg.logFile = nil
      saveCfg()
      path = nil
    end
  else
    path = nil
  end
  if not path then
    local files = listLogFiles()
    if #files > 0 then
      -- Prefer newest by name (timestamped events-YYYYMMDD-HHMMSS.log)
      local newest = files[#files]
      cfg.logFile = newest.name
      saveCfg()
      path = newest.path
    elseif createIfMissing then
      path = createEmptyLog()
    end
  end
  return path
end

local function encodeLogLine(entry)
  local function esc(s)
    s = tostring(s or ""):gsub("|", "/")
    s = s:gsub("\n", " ")
    return s
  end
  return table.concat({
    esc(entry.kind),
    esc(entry.time),
    tostring(entry.ts or 0),
    esc(entry.player),
    esc(entry.side),
    esc(entry.gate),
    tostring(entry.playerY or entry.entryY or ""),
  }, "|")
end

local function decodeLogLine(line)
  if not line or line == "" or line:sub(1, 1) == "#" then return nil end
  local parts = {}
  local rest = tostring(line)
  for _ = 1, 6 do
    local a, b = rest:match("^(.-)|(.*)$")
    if not a then break end
    parts[#parts + 1] = a
    rest = b
  end
  parts[#parts + 1] = rest
  if #parts < 4 then return nil end
  return {
    kind = parts[1],
    time = parts[2],
    ts = tonumber(parts[3]) or 0,
    player = parts[4],
    side = parts[5],
    gate = parts[6],
    playerY = tonumber(parts[7]),
    entryY = tonumber(parts[7]),
  }
end

local function appendLogFile(entry)
  local path = resolveLogPath(true)
  if not path then return end
  local line = encodeLogLine(entry) .. "\n"
  local sz = fs.getSize(path) or 0
  if sz + #line > LOG_MAX_BYTES then
    -- Cap reached: delete oversized log and start fresh.
    pcall(fs.delete, path)
    cfg.logFile = nil
    saveCfg()
    path = createEmptyLog()
    if not path then return end
  end
  local f = fs.open(path, "a")
  if not f then return end
  f.write(line)
  f.close()
end

local function loadLogFromDisk()
  log = {}
  local path = resolveLogPath(false)
  if not path or not fs.exists(path) then return 0 end
  local f = fs.open(path, "r")
  if not f then return 0 end
  local lines = {}
  while true do
    local line = f.readLine()
    if not line then break end
    lines[#lines + 1] = line
  end
  f.close()
  -- Newest last in file → newest first in memory
  for i = #lines, 1, -1 do
    local e = decodeLogLine(lines[i])
    if e then
      log[#log + 1] = e
      if #log >= LOG_MAX then break end
    end
  end
  dirty = true
  return #log
end

local function startNewLog()
  ensureLogDir()
  local oldName = cfg.logFile
  local old = logPath(oldName)
  if old and fs.exists(old) then
    pcall(fs.delete, old)
    print("Deleted old log: " .. tostring(oldName))
  end
  purgeOversizedLogs()
  cfg.logFile = nil
  saveCfg()
  log = {}
  local path = createEmptyLog()
  dirty = true
  print("Started new log: " .. tostring(cfg.logFile))
  print("Path: " .. tostring(path))
  return path
end

local function notifyAdmin(kind, player, side, gate, ts, timeText, playerY)
  local adminId = tonumber(cfg.adminId)
  if not adminId then return end
  local payload = {
    type = MSG.PERIMETER_ALERT or "perimeter_alert",
    kind = kind,
    player = player,
    side = side,
    gate = gate,
    playerY = playerY,
    entryY = playerY,
    eventTs = ts or nowUtc(),
    time = formatTime(ts, timeText),
    title = cfg.title,
    managerId = os.getComputerID(),
    from = os.getComputerID(),
  }
  rednet.send(adminId, payload, P)
  hopViaMainRouter(adminId, payload)
end

local function pushLog(kind, player, side, gate, ts, timeText, playerY)
  local entry = {
    kind = kind,
    player = player,
    side = side,
    gate = gate,
    playerY = playerY,
    entryY = playerY,
    ts = ts or nowUtc(),
    time = formatTime(ts, timeText),
  }
  table.insert(log, 1, entry)
  while #log > LOG_MAX do log[#log] = nil end
  appendLogFile(entry)
  dirty = true
  local yTxt = (playerY ~= nil) and (" Y=" .. tostring(playerY)) or ""
  print(("[%s] %s %-12s %-5s %s%s"):format(
    entry.time, kind, tostring(player),
    sideShort(side), tostring(gate or ""), yTxt))
  if kind == "ENTER" or kind == "EXIT" then
    notifyAdmin(kind, player, side, gate, entry.ts, entry.time, playerY)
  end
end

local function replyPerimeterLog(toId, msg)
  toId = tonumber(toId) or tonumber(msg and msg.from)
  if not toId then return end
  local n = math.max(1, math.min(40, tonumber(msg and msg.limit) or 20))
  local events = {}
  for i = 1, math.min(n, #log) do
    local e = log[i]
    events[#events + 1] = {
      kind = e.kind, player = e.player, side = e.side,
      gate = e.gate, ts = e.ts, time = e.time,
      playerY = e.playerY or e.entryY, entryY = e.entryY or e.playerY,
    }
  end
  local inside = {}
  for name, row in pairs(present) do
    inside[#inside + 1] = {
      name = name,
      side = row.entrySide or row.lastSide,
      gate = row.lastGate,
      entered = row.enteredText,
      entryY = row.entryY,
      playerY = row.entryY or row.lastY,
    }
  end
  table.sort(inside, function(a, b) return a.name:lower() < b.name:lower() end)
  local payload = {
    type = MSG.PERIMETER_LOG or "perimeter_log",
    events = events,
    present = inside,
    title = cfg.title,
    managerId = os.getComputerID(),
    adminId = cfg.adminId,
    from = os.getComputerID(),
    ts = nowUtc(),
  }
  rednet.send(toId, payload, P)
  hopViaMainRouter(toId, payload)
end

local function bindSensorToSelf(sensorId)
  sendConfig(sensorId, {
    managerId = os.getComputerID(),
    ignore = ignoreListSorted(),
  })
end

local function touchPresent(player, side, gate, ts, timeText, isEnter, playerY)
  local row = present[player]
  if not row then
    row = {
      entrySide = side,
      enteredAt = ts or nowUtc(),
      enteredText = formatTime(ts, timeText),
      entryY = playerY,
      lastY = playerY,
      lastSide = side,
      lastGate = gate,
      lastSeen = ts or nowUtc(),
    }
    present[player] = row
    pushLog("ENTER", player, side, gate, ts, timeText, playerY)
  else
    row.lastSide = side or row.lastSide
    row.lastGate = gate or row.lastGate
    row.lastSeen = ts or nowUtc()
    if playerY ~= nil then row.lastY = playerY end
    row.pendingExit = nil
    if isEnter and not row.entrySide then
      row.entrySide = side
      row.enteredAt = ts or nowUtc()
      row.enteredText = formatTime(ts, timeText)
      if playerY ~= nil then row.entryY = playerY end
    elseif isEnter and row.entryY == nil and playerY ~= nil then
      row.entryY = playerY
    end
  end
  dirty = true
end

local function markExit(player, side, gate, ts, timeText, playerY)
  local row = present[player]
  -- Prefer live Y, else last known while they were inside.
  local useY = playerY
  if useY == nil and row then useY = row.lastY or row.entryY end
  if not row then
    pushLog("EXIT", player, side, gate, ts, timeText, useY)
    return
  end
  row.pendingExit = true
  row.pendingSide = side or row.lastSide
  row.pendingGate = gate or row.lastGate
  row.pendingTs = ts or nowUtc()
  row.pendingText = formatTime(ts, timeText)
  row.pendingY = useY or row.lastY or row.entryY
  dirty = true
end

local function confirmExits()
  local graceMs = (tonumber(cfg.grace) or 4) * 1000
  local t = nowUtc()
  local remove = {}
  for name, row in pairs(present) do
    local stale = (t - (row.lastSeen or 0)) >= graceMs
    if row.pendingExit and stale then
      pushLog("EXIT", name, row.pendingSide or row.lastSide,
        row.pendingGate or row.lastGate, row.pendingTs, row.pendingText,
        row.pendingY or row.lastY or row.entryY)
      remove[#remove + 1] = name
    elseif stale and not row.pendingExit then
      pushLog("EXIT", name, row.lastSide, row.lastGate, t, formatTime(t),
        row.lastY or row.entryY)
      remove[#remove + 1] = name
    end
  end
  for _, name in ipairs(remove) do
    present[name] = nil
    dirty = true
  end
end

hopViaMainRouter = function(destId, payload)
  local mainId = titan.getMainRouterId and titan.getMainRouterId()
  if not mainId or not destId then return false end
  rednet.send(mainId, {
    type = MSG.PERIMETER_FWD or "perimeter_fwd",
    dest = tonumber(destId),
    originId = os.getComputerID(),
    payload = payload,
    from = os.getComputerID(),
  }, titan.ROUTER_PROTOCOL or "titan_router")
  return true
end

sendConfig = function(targetId, fields)
  -- Do not put a default `name` here — sensors treat that as their gate label.
  local msg = {
    type = MSG.PERIMETER_CONFIG or "perimeter_config",
    sensorId = targetId,
    from = os.getComputerID(),
    kind = "manager",
    managerName = titan.hostname and titan.hostname() or os.getComputerLabel(),
  }
  for k, v in pairs(fields or {}) do msg[k] = v end
  if targetId == "*" or targetId == "all" then
    msg.sensorId = "*"
    rednet.broadcast(msg, P)
    -- Ask MAIN to unicast to every known perimeter sensor on the roster.
    local mainId = titan.getMainRouterId and titan.getMainRouterId()
    if mainId then
      rednet.send(mainId, {
        type = MSG.PERIMETER_ROSTER_REQ or "perimeter_roster_req",
        kind = "perimeter_manager",
        floodConfig = msg,
        from = os.getComputerID(),
      }, titan.ROUTER_PROTOCOL or "titan_router")
    end
  else
    local id = tonumber(targetId)
    rednet.send(id, msg, P)
    hopViaMainRouter(id, msg)
  end
end

local function pushIgnoreToSensors(targetId)
  sendConfig(targetId or "*", { ignore = ignoreListSorted() })
end

local function sensorIdFrom(id, msg)
  return tonumber(msg.originId) or tonumber(msg.sensorId) or tonumber(msg.from) or id
end

local function requestRouterRoster()
  local mainId = titan.getMainRouterId and titan.getMainRouterId()
  if not mainId then return false end
  rednet.send(mainId, {
    type = MSG.PERIMETER_ROSTER_REQ or "perimeter_roster_req",
    kind = "perimeter_manager",
    from = os.getComputerID(),
    name = os.getComputerLabel(),
  }, titan.ROUTER_PROTOCOL or "titan_router")
  return true
end

local function looksLikeSensorName(name)
  name = tostring(name or ""):lower()
  if name == "" then return true end
  -- Drop backbone nodes that MAIN sometimes mis-lists in the sensor roster.
  if name:find("router", 1, true) or name:find("modem", 1, true) then return false end
  if name:find("perimetermgr", 1, true) or name:find("perimeter_mgr", 1, true) then
    return false
  end
  if name:find("perimeter manager", 1, true) then return false end
  return true
end

local function applyRouterRoster(msg)
  local n = 0
  for _, s in ipairs(msg.sensors or {}) do
    local id = tonumber(s.id)
    if id and id ~= os.getComputerID() and looksLikeSensorName(s.name) then
      local row = sensors[id] or {}
      row.gate = s.name or row.gate
      if s.x then row.x, row.y, row.z = s.x, s.y, s.z end
      row.seen = row.seen or nowUtc()
      row.viaRouter = true
      sensors[id] = row
      n = n + 1
    end
  end
  if n > 0 then dirty = true end
  return n
end

local function assignSensor(id, s, opts)
  opts = opts or {}
  if not cfg.origin or not cfg.origin.x then
    return false, "no origin — run `here` on the manager first"
  end
  if not (s and s.x and s.z) then
    return false, "sensor has no GPS"
  end
  local dx = s.x - cfg.origin.x
  local dz = s.z - cfg.origin.z
  local side = sectorFromDelta(dx, dz)
  local range = opts.range or s.range or cfg.defaultRange or DEFAULT_SENSOR_RANGE
  local fields = { side = side, range = range }
  local custom = (s.autoName == false) and not opts.forceName
  if opts.name then
    fields.name = opts.name
    fields.autoName = false
  elseif not custom then
    fields.name = sidePretty(side) .. " Gate"
    fields.autoName = true
  end
  -- Custom-named gates keep their label; only side/range are refreshed.
  sendConfig(id, fields)
  s.side = side
  s.range = range
  if fields.name then s.gate = fields.name end
  if fields.autoName ~= nil then s.autoName = fields.autoName end
  dirty = true
  print(("Assigned #%d @ %d,%d → %s%s (dx=%d dz=%d) range=%d"):format(
    id, s.x, s.z, sidePretty(side),
    custom and (" keep \"" .. tostring(s.gate) .. "\"") or (" as " .. tostring(fields.name)),
    dx, dz, range))
  return true, side
end

local function touchSensor(id, msg)
  local s = sensors[id] or {}
  if msg.side then s.side = normalizeSide(msg.side) or msg.side end
  if msg.gate then s.gate = msg.gate end
  if msg.range then s.range = msg.range end
  if msg.autoName ~= nil then s.autoName = not not msg.autoName end
  if msg.x then s.x, s.y, s.z = msg.x, msg.y, msg.z end
  s.seen = nowUtc()
  if type(msg.players) == "table" then s.players = msg.players end
  sensors[id] = s
  dirty = true
  return s
end

local function maybeAutoAssign(id, s, msg)
  -- Whole-area sensors leave side unset; only assign when they ask (`auto`).
  if not msg.wantAssign then return end
  if not cfg.origin then return end
  if not (s.x and s.z) then return end
  assignSensor(id, s)
end

local function eventVia(msg, fallbackSide)
  return msg.approach or msg.side or fallbackSide
end

local function handleMsg(id, msg)
  if type(msg) ~= "table" or not msg.type then return end
  local t = msg.type

  -- Unwrap MAIN router hops.
  if t == MSG.PERIMETER_FWD or t == "perimeter_fwd" then
    if type(msg.payload) == "table" then
      local origin = tonumber(msg.originId) or tonumber(msg.payload.originId)
        or tonumber(msg.payload.sensorId) or id
      handleMsg(origin, msg.payload)
    end
    return
  end
  if t == MSG.PERIMETER_ROSTER or t == "perimeter_roster" then
    local n = applyRouterRoster(msg)
    if n > 0 then
      print(("Router roster: %d perimeter sensor(s)"):format(n))
    end
    return
  end

  local sid = sensorIdFrom(id, msg)
  -- Sensors bound to another manager: ignore their events.
  local boundTo = tonumber(msg.managerId)
  if boundTo and boundTo ~= os.getComputerID()
      and (t == MSG.PERIMETER_ENTER or t == "perimeter_enter"
        or t == MSG.PERIMETER_EXIT or t == "perimeter_exit"
        or t == MSG.PERIMETER_PULSE or t == "perimeter_pulse"
        or t == MSG.PERIMETER_HELLO or t == "perimeter_hello"
        or t == MSG.PERIMETER_ASSIGN_REQ or t == "perimeter_assign_req") then
    return
  end

  if t == MSG.PERIMETER_HELLO or t == "perimeter_hello" then
    if msg.kind == "sensor" or msg.kind == "perimeter_sensor"
        or msg.sensorId or msg.side or msg.x then
      local s = touchSensor(sid, msg)
      maybeAutoAssign(sid, s, msg)
      -- Bind sensor to this manager + sync ignore list.
      bindSensorToSelf(sid)
    end
  elseif t == MSG.PERIMETER_ASSIGN_REQ or t == "perimeter_assign_req" then
    local s = touchSensor(sid, msg)
    local ok, err = assignSensor(sid, s)
    if not ok then print("Assign #" .. tostring(sid) .. " failed: " .. tostring(err)) end
    bindSensorToSelf(sid)
  elseif t == MSG.PERIMETER_ENTER or t == "perimeter_enter" then
    if msg.player and not isIgnored(msg.player) then
      local ets = msg.eventTs or msg.ts
      local py = tonumber(msg.entryY) or tonumber(msg.playerY)
      touchPresent(msg.player, eventVia(msg), msg.gate, ets, msg.time, true, py)
      touchSensor(sid, msg)
    end
  elseif t == MSG.PERIMETER_EXIT or t == "perimeter_exit" then
    if msg.player and not isIgnored(msg.player) then
      local py = tonumber(msg.entryY) or tonumber(msg.playerY)
      markExit(msg.player, eventVia(msg), msg.gate, msg.eventTs or msg.ts, msg.time, py)
      if sensors[sid] then sensors[sid].seen = nowUtc() end
    end
  elseif t == MSG.PERIMETER_PULSE or t == "perimeter_pulse" then
    local s = touchSensor(sid, msg)
    if msg.rangeX then s.rangeX = msg.rangeX end
    if msg.rangeY then s.rangeY = msg.rangeY end
    if msg.rangeZ then s.rangeZ = msg.rangeZ end
    for _, name in ipairs(msg.players or {}) do
      if type(name) == "string" and not isIgnored(name) then
        touchPresent(name, eventVia(msg, s.side), msg.gate or s.gate,
          msg.eventTs or msg.ts, msg.time, false)
      end
    end
  elseif t == MSG.PERIMETER_LOG_REQ or t == "perimeter_log_req" then
    local from = tonumber(msg.from) or tonumber(id)
    -- Auto-learn admin tablet when it asks for the log.
    if from and not cfg.adminId then
      cfg.adminId = from
      saveCfg()
      print("Admin tablet auto-set to #" .. tostring(from))
    end
    replyPerimeterLog(from, msg)
  elseif t == MSG.PERIMETER_UPDATE_ACK or t == "perimeter_update_ack" then
    updateAcks[sid] = msg
    touchSensor(sid, msg)
    print(("[OTA] ACK #%d %s -> v%s"):format(
      sid, tostring(msg.gate or ""), tostring(msg.version or "?")))
  elseif t == MSG.PERIMETER_UPDATE_FAIL or t == "perimeter_update_fail" then
    updateFails[sid] = msg
    print(("[OTA] FAIL #%d: %s"):format(sid, tostring(msg.err or "?")))
  end
end

--------------------------------------------------------------------------------
-- Force-update perimeter fleet (rednet OTA, then SSH fallback)
--------------------------------------------------------------------------------
local function collectPerimeterTargets()
  local ids, seen = {}, {}
  local function add(id, label)
    id = tonumber(id)
    if not id or id == os.getComputerID() or seen[id] then return end
    seen[id] = true
    ids[#ids + 1] = { id = id, label = label or (sensors[id] and sensors[id].gate) or ("#" .. id) }
  end
  for id, s in pairs(sensors) do
    add(id, s.gate)
  end
  if titan.sshListPeers then
    local peers = titan.sshListPeers(2)
    for _, p in ipairs(peers) do
      local kind = tostring(p.kind or "")
      if kind == "perimeter_sensor" or kind:find("perimeter", 1, true) then
        add(p.id, p.name or p.hostname)
      end
    end
  end
  table.sort(ids, function(a, b) return a.id < b.id end)
  return ids
end

local function pushRednetUpdate(targets, targetVer)
  local payload = {
    type = MSG.PERIMETER_UPDATE or "perimeter_update",
    sensorId = "*",
    from = os.getComputerID(),
    targetVersion = targetVer,
    managerName = os.getComputerLabel(),
  }
  rednet.broadcast(payload, P)
  -- Also poke each sensor via the Titan router OTA channel (works on older sensors).
  local routerProto = titan.ROUTER_PROTOCOL or "titan_router"
  local mainId = titan.getMainRouterId and titan.getMainRouterId() or nil
  for _, t in ipairs(targets) do
    local one = {}
    for k, v in pairs(payload) do one[k] = v end
    one.sensorId = t.id
    rednet.send(t.id, one, P)
    hopViaMainRouter(t.id, one)
    rednet.send(t.id, {
      type = "update",
      from = os.getComputerID(),
      name = os.getComputerLabel(),
      mainRouterId = mainId,
      targetVersion = targetVer,
      perimeter = true,
    }, routerProto)
  end
end

local function sshForceUpdate(targetId, password)
  if not titan.sshOpenRouted then
    return false, "ssh not available (need lib/titan.lua)"
  end
  local hopId, token, info = titan.sshOpenRouted(targetId, password)
  if not token then
    return false, tostring(info)
  end
  local res = titan.sshExec(hopId, token, "update -y")
  titan.sshClose(hopId, token)
  if not res then return false, "no reply" end
  if res.ok then
    return true, res.out or "ok"
  end
  return false, res.out or "ssh update failed"
end

local function forceUpdatePerimeter(opts)
  opts = opts or {}
  local skipConfirm = opts.yes == true
  local targetVer = titan.systemVersion and titan.systemVersion() or "?"
  local targets = collectPerimeterTargets()

  print("== Perimeter force-update ==")
  print(("This board system v%s"):format(tostring(targetVer)))
  print(("Sensors to update: %d"):format(#targets))
  for _, t in ipairs(targets) do
    print(("  #%d  %s"):format(t.id, tostring(t.label)))
  end
  if not skipConfirm then
    write("Update this board + all listed sensors? [y/N] ")
    if (read() or ""):lower() ~= "y" then
      print("Cancelled.")
      return
    end
  end

  -- 1) Update this manager (no reboot yet — need to drive the campaign).
  print("Updating perimeter manager packages...")
  if titan.updateSelf then
    local uok, detail = titan.updateSelf({
      onProgress = function(path, good, msg)
        local name = titan.packageName and titan.packageName(path) or path
        if good then print(("  ok   %-20s %s"):format(name, tostring(msg)))
        else print(("  FAIL %-20s %s"):format(name, tostring(msg))) end
      end,
    })
    if uok then
      targetVer = titan.systemVersion() or targetVer
      print("Manager packages refreshed (v" .. tostring(targetVer) .. ").")
    else
      print("Manager self-update failed: " .. tostring(detail))
      print("Continuing to push sensors anyway...")
    end
  else
    print("No updateSelf — skip manager self-update.")
  end

  if #targets == 0 then
    print("No perimeter sensors known. Run sensors after they hello, or try again.")
    write("Reboot this manager now? [Y/n] ")
    local yn = (read() or ""):lower()
    if yn == "" or yn == "y" then os.reboot() end
    return
  end

  -- 2) Rednet force-update
  updateAcks, updateFails = {}, {}
  print("Pushing rednet OTA to sensors...")
  pushRednetUpdate(targets, targetVer)

  local waitSec = 12
  print(("Waiting %ds for ACKs..."):format(waitSec))
  local deadline = os.clock() + waitSec
  while os.clock() < deadline do
    local pending = 0
    for _, t in ipairs(targets) do
      if not updateAcks[t.id] and not updateFails[t.id] then pending = pending + 1 end
    end
    if pending == 0 then break end
    sleep(0.5)
  end

  local needSsh = {}
  for _, t in ipairs(targets) do
    if updateAcks[t.id] then
      print(("  #%d ACK ok"):format(t.id))
    elseif updateFails[t.id] then
      print(("  #%d rednet fail — will SSH"):format(t.id))
      needSsh[#needSsh + 1] = t
    else
      print(("  #%d no ACK — will SSH"):format(t.id))
      needSsh[#needSsh + 1] = t
    end
  end

  -- 3) SSH fallback for anyone that didn't ACK
  if #needSsh > 0 then
    print(("SSH force-update for %d sensor(s)..."):format(#needSsh))
    write("Master password (Parent Center): ")
    local password = read("*")
    if not password or password == "" then
      print("No password — skipping SSH fallback.")
    else
      for _, t in ipairs(needSsh) do
        print(("ssh #%d (%s)..."):format(t.id, tostring(t.label)))
        local ok, detail = sshForceUpdate(t.id, password)
        if not ok then
          print(("  #%d SSH failed (%s) — retry in 3s..."):format(t.id, tostring(detail)))
          sleep(3)
          ok, detail = sshForceUpdate(t.id, password)
        end
        if ok then
          updateAcks[t.id] = { via = "ssh", out = detail }
          updateFails[t.id] = nil
          print(("  #%d SSH ok"):format(t.id))
          if detail and detail ~= "" then print("  " .. tostring(detail):sub(1, 120)) end
        else
          updateFails[t.id] = { err = detail }
          print(("  #%d SSH failed: %s"):format(t.id, tostring(detail)))
        end
      end
    end
  end

  local okN, failN = 0, 0
  for _, t in ipairs(targets) do
    if updateAcks[t.id] then okN = okN + 1 else failN = failN + 1 end
  end
  print(("Done. sensors ok=%d fail=%d"):format(okN, failN))
  write("Reboot this manager to load new code? [Y/n] ")
  local yn = (read() or ""):lower()
  if yn == "" or yn == "y" then
    print("Rebooting...")
    sleep(0.5)
    os.reboot()
  end
end

local function broadcastManagerHello(opts)
  opts = opts or {}
  local payload = {
    type = MSG.PERIMETER_HELLO or "perimeter_hello",
    kind = "manager",
    name = os.getComputerLabel(),
    origin = cfg.origin,
    defaultRange = cfg.defaultRange or DEFAULT_SENSOR_RANGE,
    from = os.getComputerID(),
  }
  -- Sensors need a PROTO broadcast for discovery; MAIN only needs one hop.
  rednet.broadcast(payload, P)
  local mainId = titan.getMainRouterId and titan.getMainRouterId()
  if mainId and not opts.skipMain then
    rednet.send(mainId, payload, titan.ROUTER_PROTOCOL or "titan_router")
  end
end

local function setOriginHere()
  local x, y, z = gps.locate(3)
  if not x then
    print("No GPS signal.")
    return false
  end
  cfg.origin = { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
  saveCfg()
  print(("origin = %d,%d,%d"):format(cfg.origin.x, cfg.origin.y, cfg.origin.z))
  broadcastManagerHello()
  return true
end

local function findSensorRef(ref)
  if not ref then return nil end
  local id = tonumber(ref)
  if id and sensors[id] then return id end
  local want = tostring(ref):lower()
  if want == "all" or want == "*" then return "*" end
  for sid, s in pairs(sensors) do
    if s.gate and s.gate:lower() == want then return sid end
    if s.gate and s.gate:lower():find(want, 1, true) then return sid end
    if s.side and (normalizeSide(s.side) == normalizeSide(want) or sideShort(s.side):lower() == want) then
      return sid
    end
  end
  if id then return id end -- allow send even if not heard yet
  return nil
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------
local function findMonitor()
  local m = peripheral.find("monitor")
  if m then
    pcall(function()
      if m.setTextScale then m.setTextScale(0.5) end
    end)
  end
  return m
end

local function sortedPlayers()
  local list = {}
  for name, row in pairs(present) do
    list[#list + 1] = { name = name, row = row }
  end
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
  return list
end

local function drawOn(t)
  local w, h = t.getSize()
  t.setBackgroundColor(colors.black)
  t.clear()
  local function put(x, y, text, fg, bg)
    if y < 1 or y > h then return end
    if t.setTextColor and fg then t.setTextColor(fg) end
    if t.setBackgroundColor and bg then t.setBackgroundColor(bg) end
    t.setCursorPos(x, y)
    t.write(tostring(text or ""):sub(1, w - x + 1))
    if t.setBackgroundColor then t.setBackgroundColor(colors.black) end
  end

  put(1, 1, "== " .. tostring(cfg.title or "Territory") .. " ==", colors.yellow)
  local originTxt = cfg.origin
    and ("%d,%d,%d"):format(cfg.origin.x, cfg.origin.y, cfg.origin.z) or "origin unset"
  put(1, 2, (os.date("%Y-%m-%d %H:%M:%S") or "") .. "  " .. originTxt, colors.lightGray)

  local nSens = 0
  for _, s in pairs(sensors) do
    if (nowUtc() - (s.seen or 0)) < 45000 then nSens = nSens + 1 end
  end
  local inside = sortedPlayers()
  put(1, 3, ("Inside: %d   Gates: %d   grace=%ss  defRange=%s"):format(
    #inside, nSens, tostring(cfg.grace), tostring(cfg.defaultRange)), colors.lime)

  put(1, 5, "PLAYER           IN  Y    ENTERED             VIA GATE", colors.orange)
  local y = 6
  if #inside == 0 then
    put(1, y, "(no players in range)", colors.gray)
    y = y + 1
  else
    for _, e in ipairs(inside) do
      if y >= h - 6 then break end
      local r = e.row
      local yLvl = r.entryY or r.lastY
      local line = ("%-16s %-3s %-4s %-19s %s"):format(
        e.name:sub(1, 16),
        sideShort(r.entrySide),
        yLvl ~= nil and tostring(yLvl) or "?",
        tostring(r.enteredText or "?"):sub(1, 19),
        tostring(r.lastGate or r.entrySide or ""):sub(1, math.max(1, w - 48))
      )
      put(1, y, line, r.pendingExit and colors.yellow or colors.white)
      y = y + 1
    end
  end

  y = math.min(h - 5, y + 1)
  put(1, y, "RECENT EVENTS", colors.orange); y = y + 1
  for i = 1, math.min(#log, h - y) do
    local e = log[i]
    local fg = (e.kind == "ENTER") and colors.lime or colors.red
    local yLvl = e.playerY or e.entryY
    put(1, y, ("%s %-5s %-10s %-3s Y%-4s %s"):format(
      tostring(e.time):sub(-8), e.kind, tostring(e.player):sub(1, 10),
      sideShort(e.side),
      yLvl ~= nil and tostring(yLvl) or "?",
      tostring(e.gate or ""):sub(1, 10)), fg)
    y = y + 1
  end
end

local function drawAll()
  local mon = findMonitor()
  if mon then
    drawOn(mon)
  end
  if not mon then
    term.setBackgroundColor(colors.black)
    drawOn(term)
  end
  dirty = false
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function printHelp()
  print("Perimeter manager - territory board")
  print("ORIGIN: here | origin | setpos <x> <y> <z>")
  print("GATES : sensors | assign [id|all] | rename <id|gate> <label>")
  print("        set <id|all> side|range|name|poll|gpshost|autoname ...")
  print("        set <id|all> side clear")
  print("        set <id|all> range <n> | range x|y|z <n>")
  print("        set <id|all> gpshost on|off|here|<x> <y> <z>")
  print("        range <n> | range x|y|z <n>   push ranges to all sensors")
  print("IGNORE: ignore add|remove <name> | ignore list | ignore clear")
  print("ADMIN : admin <tabletId> | admin clear | admin")
  print("UPDATE: update | forceupdate [-y]   OTA board + all perimeter sensors")
  print("VIEW  : status | log [n] | logs | newlog | clear | grace <s> | title <name>")
  print("Sensors bind to this manager only; ENTER/EXIT forward to admin tablet.")
  print("Single sensor: leave side unset; ENTER shows approach bearing + Y.")
  print("Multi-gate: here then assign all (N/NE/E/... Gate from origin)")
end

local function handleCommand(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = (a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" or cmd == "?" then
    printHelp()
  elseif cmd == "here" or cmd == "origin" then
    if a[2] == nil or cmd == "here" then
      setOriginHere()
    end
  elseif cmd == "setpos" then
    local x, y, z = tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
    if not (x and y and z) then
      print("Usage: setpos <x> <y> <z>")
    else
      cfg.origin = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
      saveCfg()
      print(("origin = %d,%d,%d"):format(cfg.origin.x, cfg.origin.y, cfg.origin.z))
      broadcastManagerHello()
    end
  elseif cmd == "assign" or cmd == "auto" then
    local ref = a[2] or "all"
    if not cfg.origin then
      print("Set origin first: here")
      return true
    end
    if ref == "all" or ref == "*" then
      local n = 0
      for id, s in pairs(sensors) do
        if s.x and s.z then
          if assignSensor(id, s) then n = n + 1 end
        else
          print("#" .. id .. " has no GPS yet")
        end
      end
      print("Assigned " .. n .. " sensor(s).")
    else
      local id = findSensorRef(ref)
      if not id or id == "*" then print("Unknown sensor: " .. tostring(ref)); return true end
      local s = sensors[id] or {}
      local ok, err = assignSensor(id, s)
      if not ok then print(tostring(err)) end
    end
  elseif cmd == "set" then
    -- set <id|all> side <dir> | range <n> | name <label>
    local id = findSensorRef(a[2])
    local field = (a[3] or ""):lower()
    if not id or field == "" then
      print("Usage: set <id|all> side <dir|clear>")
      print("       set <id|all> range <n> | range x|y|z <n>")
      print("       set <id|all> name <label>")
      print("       set <id|all> poll <seconds>")
      print("       set <id|all> gpshost on|off|here|<x> <y> <z>")
      print("       set <id|all> autoname")
      return true
    end
    if field == "side" then
      local arg = (a[4] or ""):lower()
      if arg == "clear" or arg == "none" or arg == "area" or arg == "-" then
        sendConfig(id, { clearSide = true, side = false })
        if id == "*" then
          for _, s in pairs(sensors) do
            s.side = nil
            if s.autoName ~= false then s.gate = "Territory" end
          end
        elseif sensors[id] then
          sensors[id].side = nil
          if sensors[id].autoName ~= false then sensors[id].gate = "Territory" end
        end
        print("Cleared side (whole-area) -> " .. tostring(id))
        return true
      end
      local side = normalizeSide(a[4])
      if not side then print("side: n|ne|e|se|s|sw|w|nw|clear"); return true end
      -- Side only: auto-named sensors rename themselves; custom labels stay.
      sendConfig(id, { side = side })
      if id == "*" then
        for _, s in pairs(sensors) do
          s.side = side
          if s.autoName ~= false then s.gate = sidePretty(side) .. " Gate" end
        end
      elseif sensors[id] then
        sensors[id].side = side
        if sensors[id].autoName ~= false then
          sensors[id].gate = sidePretty(side) .. " Gate"
        end
      end
      print("Pushed side " .. sidePretty(side) .. " -> " .. tostring(id))
    elseif field == "range" or field == "rangex" or field == "rangey" or field == "rangez" then
      local axis, r
      if field == "rangex" then axis, r = "x", math.floor(tonumber(a[4]) or 0)
      elseif field == "rangey" then axis, r = "y", math.floor(tonumber(a[4]) or 0)
      elseif field == "rangez" then axis, r = "z", math.floor(tonumber(a[4]) or 0)
      else
        local a4 = (a[4] or ""):lower()
        if a4 == "x" or a4 == "y" or a4 == "z" then
          axis, r = a4, math.floor(tonumber(a[5]) or 0)
        else
          r = math.floor(tonumber(a[4]) or 0)
        end
      end
      if axis then
        if r < 1 then
          print("Usage: set <id|all> range " .. axis .. " <n>")
          return true
        end
        local key = "range" .. axis:upper()
        sendConfig(id, { [key] = r })
        if id ~= "*" and sensors[id] then sensors[id][key] = r end
        print(("Pushed %s=%d -> %s"):format(key, r, tostring(id)))
      else
        if r < 1 then print("Usage: set <id|all> range <n> | range x|y|z <n>"); return true end
        sendConfig(id, { range = r })
        if id == "*" then cfg.defaultRange = r; saveCfg() end
        if id ~= "*" and sensors[id] then
          sensors[id].range = r
          sensors[id].rangeX, sensors[id].rangeY, sensors[id].rangeZ = nil, nil, nil
        end
        print("Pushed range X=Y=Z " .. r .. " -> " .. tostring(id))
      end
    elseif field == "name" then
      if not a[4] then print("Usage: set <id|all> name <label>"); return true end
      local name = table.concat(a, " ", 4)
      sendConfig(id, { name = name, autoName = false })
      if id == "*" then
        for _, s in pairs(sensors) do s.gate = name; s.autoName = false end
      elseif sensors[id] then
        sensors[id].gate = name
        sensors[id].autoName = false
      end
      print("Renamed -> " .. tostring(id) .. " = " .. name)
    elseif field == "poll" then
      local p = tonumber(a[4])
      if not p or p < 0.2 then
        print("Usage: set <id|all> poll <seconds>  (min 0.2)")
        return true
      end
      sendConfig(id, { poll = p })
      if id ~= "*" and sensors[id] then sensors[id].poll = p end
      print(("Pushed poll=%.2fs -> %s"):format(p, tostring(id)))
    elseif field == "gpshost" or field == "gps" then
      local sub = (a[4] or ""):lower()
      if sub == "" then
        print("Usage: set <id|all> gpshost on|off|here|<x> <y> <z>")
        return true
      end
      if sub == "off" or sub == "disable" or sub == "false" then
        sendConfig(id, { gpsHost = false })
        if id == "*" then
          for _, s in pairs(sensors) do s.gpsHost = false end
        elseif sensors[id] then
          sensors[id].gpsHost = false
        end
        print("Pushed gpshost off -> " .. tostring(id))
      elseif sub == "on" or sub == "enable" or sub == "true" then
        sendConfig(id, { gpsHost = true })
        if id == "*" then
          for _, s in pairs(sensors) do s.gpsHost = true end
        elseif sensors[id] then
          sensors[id].gpsHost = true
        end
        print("Pushed gpshost on -> " .. tostring(id))
      elseif sub == "here" or sub == "auto" then
        -- Ask sensors to lock GPS host to their own current fix.
        sendConfig(id, { gpsHost = true, gpsHere = true })
        print("Pushed gpshost here (use sensor GPS) -> " .. tostring(id))
      else
        local x, y, z = tonumber(a[4]), tonumber(a[5]), tonumber(a[6])
        if not (x and y and z) then
          print("Usage: set <id|all> gpshost on|off|here|<x> <y> <z>")
          return true
        end
        local coords = {
          x = math.floor(x), y = math.floor(y), z = math.floor(z),
        }
        sendConfig(id, { gpsHost = true, gpsCoords = coords })
        if id == "*" then
          for _, s in pairs(sensors) do
            s.gpsHost = true
            s.gpsCoords = coords
          end
        elseif sensors[id] then
          sensors[id].gpsHost = true
          sensors[id].gpsCoords = coords
        end
        print(("Pushed gpshost @ %d,%d,%d -> %s"):format(
          coords.x, coords.y, coords.z, tostring(id)))
      end
    elseif field == "autoname" or field == "autolabel" then
      sendConfig(id, { autoName = true })
      if id == "*" then
        for _, s in pairs(sensors) do s.autoName = true end
      elseif sensors[id] then
        sensors[id].autoName = true
      end
      print("Pushed autoname on -> " .. tostring(id))
    else
      print("Unknown field. Use side|range|name|poll|gpshost|autoname")
    end
  elseif cmd == "rename" or cmd == "name" then
    -- rename <id|gate|side> <label...>
    local id = findSensorRef(a[2])
    if not id or id == "*" or not a[3] then
      print("Usage: rename <id|gate> <label>")
      print("       (use set all name <label> to rename every sensor)")
      return true
    end
    local name = table.concat(a, " ", 3)
    sendConfig(id, { name = name, autoName = false })
    if sensors[id] then
      sensors[id].gate = name
      sensors[id].autoName = false
    end
    dirty = true
    print(("Renamed #%s → %s"):format(tostring(id), name))
  elseif cmd == "range" then
    local a2 = (a[2] or ""):lower()
    if a2 == "x" or a2 == "y" or a2 == "z" then
      local r = math.floor(tonumber(a[3]) or 0)
      if r < 1 then
        print("Usage: range x|y|z <n>   (push axis to all sensors)")
      else
        local key = "range" .. a2:upper()
        sendConfig("*", { [key] = r })
        for _, s in pairs(sensors) do s[key] = r end
        print(("Pushed %s=%d to all sensors."):format(key, r))
      end
    else
      local r = math.floor(tonumber(a[2]) or 0)
      if r < 1 then
        print("defaultRange = " .. tostring(cfg.defaultRange))
        print("Usage: range <n>   or   range x|y|z <n>")
      else
        cfg.defaultRange = r
        saveCfg()
        sendConfig("*", { range = r })
        for _, s in pairs(sensors) do
          s.range = r
          s.rangeX, s.rangeY, s.rangeZ = nil, nil, nil
        end
        print("Pushed range X=Y=Z " .. r .. " to all sensors.")
      end
    end
  elseif cmd == "ignore" or cmd == "allow" then
    local sub = (a[2] or "list"):lower()
    if sub == "list" or sub == "ls" or sub == "show" then
      local list = ignoreListSorted()
      if #list == 0 then
        print("ignore: (none)")
      else
        print(("ignore (%d): %s"):format(#list, table.concat(list, ", ")))
      end
    elseif sub == "clear" or sub == "reset" then
      cfg.ignore = {}
      saveCfg()
      pushIgnoreToSensors("*")
      print("Ignore list cleared (pushed to sensors).")
    elseif sub == "add" or sub == "+" then
      if not a[3] then print("Usage: ignore add <player>"); return true end
      local name = table.concat(a, " ", 3):match("^%s*(.-)%s*$")
      cfg.ignore[ignoreKey(name)] = name
      saveCfg()
      local dropped = dropIgnoredPresent(name)
      pushIgnoreToSensors("*")
      print(("Ignored %s (pushed to sensors)%s"):format(
        name, dropped > 0 and (" - removed from board") or ""))
    elseif sub == "remove" or sub == "rm" or sub == "del" or sub == "-" then
      if not a[3] then print("Usage: ignore remove <player>"); return true end
      local name = table.concat(a, " ", 3):match("^%s*(.-)%s*$")
      local key = ignoreKey(name)
      if not cfg.ignore[key] then
        print("Not on ignore list: " .. name)
      else
        local was = cfg.ignore[key]
        cfg.ignore[key] = nil
        saveCfg()
        pushIgnoreToSensors("*")
        print("Removed from ignore: " .. tostring(was))
      end
    else
      -- Bare `ignore Steve` = add
      local name = table.concat(a, " ", 2):match("^%s*(.-)%s*$")
      if name == "" then
        print("Usage: ignore add|remove|list|clear <player>")
      else
        cfg.ignore[ignoreKey(name)] = name
        saveCfg()
        dropIgnoredPresent(name)
        pushIgnoreToSensors("*")
        print("Ignored " .. name .. " (pushed to sensors)")
      end
    end
  elseif cmd == "admin" or cmd == "tablet" then
    local sub = (a[2] or ""):lower()
    if sub == "" or sub == "status" or sub == "show" then
      print("admin tablet: #" .. tostring(cfg.adminId or "(unset)"))
      print("Usage: admin <id> | admin clear")
    elseif sub == "clear" or sub == "none" or sub == "off" then
      cfg.adminId = nil
      saveCfg()
      print("Admin tablet cleared.")
    else
      local id = tonumber(a[2])
      if not id then
        print("Usage: admin <tabletId> | admin clear")
      else
        cfg.adminId = id
        saveCfg()
        print("Admin tablet = #" .. tostring(id))
        -- Push a hello so the tablet can refresh its perimeter board.
        rednet.send(id, {
          type = MSG.PERIMETER_LOG or "perimeter_log",
          events = {},
          present = {},
          title = cfg.title,
          managerId = os.getComputerID(),
          from = os.getComputerID(),
          hello = true,
        }, P)
        hopViaMainRouter(id, {
          type = MSG.PERIMETER_LOG or "perimeter_log",
          events = {},
          present = {},
          title = cfg.title,
          managerId = os.getComputerID(),
          from = os.getComputerID(),
          hello = true,
        })
        replyPerimeterLog(id, { limit = 20, from = id })
      end
    end
  elseif cmd == "status" then
    local list = sortedPlayers()
    print(("Inside (%d):"):format(#list))
    if #list == 0 then print("  (none)") end
    for _, e in ipairs(list) do
      local r = e.row
      local yLvl = r.entryY or r.lastY
      print(("  %-16s entered %s from %s Y=%s  (%s)"):format(
        e.name, tostring(r.enteredText), sideShort(r.entrySide),
        yLvl ~= nil and tostring(yLvl) or "?",
        tostring(r.lastGate or "")))
    end
    local ign = ignoreListSorted()
    if #ign > 0 then
      print(("Ignored (%d): %s"):format(#ign, table.concat(ign, ", ")))
    end
  elseif cmd == "log" then
    local n = tonumber(a[2]) or 20
    if cfg.logFile then
      print("file: " .. tostring(logPath(cfg.logFile)))
    end
    for i = 1, math.min(n, #log) do
      local e = log[i]
      local yLvl = e.playerY or e.entryY
      print(("%s  %-5s  %-12s  %-4s  Y%-4s  %s"):format(
        e.time, e.kind, e.player, sideShort(e.side),
        yLvl ~= nil and tostring(yLvl) or "?",
        tostring(e.gate or "")))
    end
    if #log == 0 then print("(no events yet)") end
  elseif cmd == "logs" then
    local files = listLogFiles()
    if #files == 0 then
      print("(no log files in " .. LOG_DIR .. "/)")
    else
      print(("Logs in %s/  (max %d bytes):"):format(LOG_DIR, LOG_MAX_BYTES))
      for _, f in ipairs(files) do
        local mark = (cfg.logFile == f.name or cfg.logFile == f.path) and " *" or ""
        print(("  %-28s  %d bytes%s"):format(f.name, f.size, mark))
      end
      print("* = active")
    end
  elseif cmd == "newlog" then
    startNewLog()
  elseif cmd == "sensors" or cmd == "gates" then
    if requestRouterRoster() then
      print("Refreshing sensor list via MAIN router...")
      sleep(0.4)
    end
    if cfg.origin then
      print(("origin %d,%d,%d"):format(cfg.origin.x, cfg.origin.y, cfg.origin.z))
    else
      print("origin unset — run `here`")
    end
    local mainId = titan.getMainRouterId and titan.getMainRouterId()
    if mainId then
      print("mesh: MAIN router #" .. tostring(mainId) .. " (hop alerts enabled)")
    else
      print("mesh: no MAIN router yet — direct RF only")
    end
    local n = 0
    local ids = {}
    for id in pairs(sensors) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local s = sensors[id]
      local age = math.floor((nowUtc() - (s.seen or 0)) / 1000)
      local pos = (s.x and ("%d,%d,%d"):format(s.x, s.y or 0, s.z)) or "no-gps"
      local tag = (s.autoName == false) and "custom" or "auto"
      local via = s.viaRouter and " mesh" or ""
      print(("#%d  %-4s  %-16s  %-6s  range=%s  %s  %ss%s"):format(
        id, sideShort(s.side), tostring(s.gate or "?"):sub(1, 16), tag,
        tostring(s.range or "?"), pos, age, via))
      n = n + 1
    end
    if n == 0 then print("(no sensors heard — check mesh / run sensors again)") end
  elseif cmd == "clear" then
    present = {}
    dirty = true
    print("Cleared presence board. Disk log kept — use newlog to reset it.")
  elseif cmd == "grace" then
    if a[2] then
      cfg.grace = math.max(1, tonumber(a[2]) or 4)
      saveCfg()
    end
    print("grace = " .. tostring(cfg.grace) .. "s")
  elseif cmd == "title" then
    if a[2] then
      cfg.title = table.concat(a, " ", 2)
      saveCfg()
      dirty = true
    end
    print("title = " .. tostring(cfg.title))
  elseif cmd == "redraw" or cmd == "refresh" then
    dirty = true
    drawAll()
  elseif cmd == "update" or cmd == "forceupdate" or cmd == "upgrade" then
    local yes = false
    for i = 2, #a do
      local f = (a[i] or ""):lower()
      if f == "-y" or f == "--yes" or f == "yes" or f == "all" then yes = true end
    end
    forceUpdatePerimeter({ yes = yes })
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
os.setComputerLabel(os.getComputerLabel() or ("PerimeterMgr-" .. os.getComputerID()))

term.clear(); term.setCursorPos(1, 1)
print("== Perimeter Manager ==")
print("Default sensor range " .. DEFAULT_SENSOR_RANGE .. ". Single-sensor or multi-gate.")
if not cfg.origin then
  print("Tip: stand at territory center and type: here (multi-gate assign)")
else
  print(("origin %d,%d,%d"):format(cfg.origin.x, cfg.origin.y, cfg.origin.z))
end
do
  local ign = ignoreListSorted()
  if #ign > 0 then
    print(("ignore (%d): %s"):format(#ign, table.concat(ign, ", ")))
  end
end
local nLoaded = loadLogFromDisk()
if cfg.logFile then
  print(("Loaded %d event(s) from %s"):format(nLoaded, tostring(cfg.logFile)))
else
  print("No saved event log yet.")
end
print("Type help.  admin <tabletId>  |  ignore add <name>")
print("")

broadcastManagerHello()
requestRouterRoster()

local function netLoop()
  while true do
    -- Any protocol: titan_net alerts + titan_router hops/roster.
    local id, msg = rednet.receive(nil, 0.5)
    local batch = {}
    if type(msg) == "table" and id then batch[#batch + 1] = { id, msg } end
    for _ = 1, 16 do
      local id2, msg2 = rednet.receive(nil, 0)
      if not id2 then break end
      if type(msg2) == "table" then batch[#batch + 1] = { id2, msg2 } end
    end
    for bi = 1, #batch do
      handleMsg(batch[bi][1], batch[bi][2])
    end
  end
end

local function tickLoop()
  while true do
    confirmExits()
    if dirty then drawAll() end
    sleep(0.5)
  end
end

local function meshSyncLoop()
  if titan.netJitter then titan.netJitter(1.5) else sleep((((os.getComputerID() or 0) % 10) / 10)) end
  while true do
    broadcastManagerHello()
    requestRouterRoster()
    sleep(35)
  end
end

local function consoleLoop()
  while true do
    write("perimeter> ")
    local r = handleCommand(read())
    if r == "exit" then return end
  end
end

titan.setSshHandler(function(line)
  handleCommand(line)
  return true
end)

drawAll()

parallel.waitForAny(
  netLoop,
  tickLoop,
  meshSyncLoop,
  consoleLoop,
  function() titan.networkLoop("perimeter_manager") end
)
print("Perimeter manager stopped.")
