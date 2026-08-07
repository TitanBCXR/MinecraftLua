--[[
  perimeter_manager.lua  -  Territory board for perimeter sensors
  Titan-Version: 1.1.0

  Central display for perimeter_sensor.lua gates. Shows who is inside the
  territory, which sector they entered from (N NE E SE S SW W NW), enter time,
  and a rolling enter/exit log with timestamps.

  Auto-assign: set this computer as the territory origin (`here` / GPS). Sensors
  report their GPS; the manager maps them to an 8-way sector and pushes config.

  Remote control of sensors:
    assign [id|all]              auto side from GPS vs origin
    set <id|all> side <dir>
    set <id|all> range <n>
    set <id|all> name <label>
    range <n>                    shorthand: set all range
    origin / here / setpos       territory center

  Requires: modem, GPS (for auto-assign), lib/titan.lua, optional monitor
]]

local titan = dofile("lib/titan.lua")
local MSG = titan.MSG
local P = titan.PROTOCOL

titan.openModem()

local CFG = "perimeter_manager.cfg"
local LOG_MAX = 80
local DEFAULT_SENSOR_RANGE = 50
local cfg = {
  title = "Territory",
  grace = 4,
  defaultRange = DEFAULT_SENSOR_RANGE,
  origin = nil,  -- {x,y,z} manager / territory center
}

local present = {}
local log = {}
local sensors = {}      -- [id] = { side, gate, seen, players, x,y,z, range }
local dirty = true

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

local function pushLog(kind, player, side, gate, ts, timeText)
  table.insert(log, 1, {
    kind = kind,
    player = player,
    side = side,
    gate = gate,
    ts = ts or nowUtc(),
    time = formatTime(ts, timeText),
  })
  while #log > LOG_MAX do log[#log] = nil end
  dirty = true
  print(("[%s] %s %-12s %-5s %s"):format(
    formatTime(ts, timeText), kind, tostring(player),
    sideShort(side), tostring(gate or "")))
end

local function touchPresent(player, side, gate, ts, timeText, isEnter)
  local row = present[player]
  if not row then
    row = {
      entrySide = side,
      enteredAt = ts or nowUtc(),
      enteredText = formatTime(ts, timeText),
      lastSide = side,
      lastGate = gate,
      lastSeen = ts or nowUtc(),
    }
    present[player] = row
    pushLog("ENTER", player, side, gate, ts, timeText)
  else
    row.lastSide = side or row.lastSide
    row.lastGate = gate or row.lastGate
    row.lastSeen = ts or nowUtc()
    row.pendingExit = nil
    if isEnter and not row.entrySide then
      row.entrySide = side
      row.enteredAt = ts or nowUtc()
      row.enteredText = formatTime(ts, timeText)
    end
  end
  dirty = true
end

local function markExit(player, side, gate, ts, timeText)
  local row = present[player]
  if not row then
    pushLog("EXIT", player, side, gate, ts, timeText)
    return
  end
  row.pendingExit = true
  row.pendingSide = side or row.lastSide
  row.pendingGate = gate or row.lastGate
  row.pendingTs = ts or nowUtc()
  row.pendingText = formatTime(ts, timeText)
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
        row.pendingGate or row.lastGate, row.pendingTs, row.pendingText)
      remove[#remove + 1] = name
    elseif stale and not row.pendingExit then
      pushLog("EXIT", name, row.lastSide, row.lastGate, t, formatTime(t))
      remove[#remove + 1] = name
    end
  end
  for _, name in ipairs(remove) do
    present[name] = nil
    dirty = true
  end
end

local function sendConfig(targetId, fields)
  local msg = {
    type = MSG.PERIMETER_CONFIG or "perimeter_config",
    sensorId = targetId,
    from = os.getComputerID(),
    name = titan.hostname and titan.hostname() or os.getComputerLabel(),
  }
  for k, v in pairs(fields or {}) do msg[k] = v end
  if targetId == "*" or targetId == "all" then
    msg.sensorId = "*"
    rednet.broadcast(msg, P)
  else
    rednet.send(tonumber(targetId), msg, P)
    rednet.broadcast(msg, P) -- mesh hop friendly
  end
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
  local gateName = opts.name or (sidePretty(side) .. " Gate")
  sendConfig(id, {
    side = side,
    range = range,
    name = gateName,
    autoName = true,
  })
  s.side = side
  s.range = range
  s.gate = gateName
  dirty = true
  print(("Assigned #%d @ %d,%d → %s (dx=%d dz=%d) range=%d"):format(
    id, s.x, s.z, sidePretty(side), dx, dz, range))
  return true, side
end

local function touchSensor(id, msg)
  local s = sensors[id] or {}
  if msg.side then s.side = normalizeSide(msg.side) or msg.side end
  if msg.gate then s.gate = msg.gate end
  if msg.range then s.range = msg.range end
  if msg.x then s.x, s.y, s.z = msg.x, msg.y, msg.z end
  s.seen = nowUtc()
  if type(msg.players) == "table" then s.players = msg.players end
  sensors[id] = s
  dirty = true
  return s
end

local function maybeAutoAssign(id, s, msg)
  if not msg.wantAssign and s.side then return end
  if not cfg.origin then return end
  if not (s.x and s.z) then return end
  -- Re-assign when requested, or when side missing.
  if msg.wantAssign or not s.side then
    assignSensor(id, s)
  end
end

local function handleMsg(id, msg)
  if type(msg) ~= "table" or not msg.type then return end
  local t = msg.type
  if t == MSG.PERIMETER_HELLO or t == "perimeter_hello" then
    if msg.kind == "sensor" or msg.sensorId or msg.side or msg.x then
      local s = touchSensor(id, msg)
      maybeAutoAssign(id, s, msg)
    end
  elseif t == MSG.PERIMETER_ASSIGN_REQ or t == "perimeter_assign_req" then
    local s = touchSensor(id, msg)
    local ok, err = assignSensor(id, s)
    if not ok then print("Assign #" .. tostring(id) .. " failed: " .. tostring(err)) end
  elseif t == MSG.PERIMETER_ENTER or t == "perimeter_enter" then
    if msg.player then
      local ets = msg.eventTs or msg.ts
      touchPresent(msg.player, msg.side, msg.gate, ets, msg.time, true)
      touchSensor(id, msg)
    end
  elseif t == MSG.PERIMETER_EXIT or t == "perimeter_exit" then
    if msg.player then
      markExit(msg.player, msg.side, msg.gate, msg.eventTs or msg.ts, msg.time)
      if sensors[id] then sensors[id].seen = nowUtc() end
    end
  elseif t == MSG.PERIMETER_PULSE or t == "perimeter_pulse" then
    local s = touchSensor(id, msg)
    for _, name in ipairs(msg.players or {}) do
      if type(name) == "string" then
        touchPresent(name, msg.side or s.side, msg.gate or s.gate, msg.eventTs or msg.ts, msg.time, false)
      end
    end
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
  rednet.broadcast({
    type = MSG.PERIMETER_HELLO or "perimeter_hello",
    kind = "manager",
    name = os.getComputerLabel(),
    origin = cfg.origin,
    defaultRange = cfg.defaultRange,
  }, P)
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

  put(1, 5, "PLAYER           IN  ENTERED             VIA GATE", colors.orange)
  local y = 6
  if #inside == 0 then
    put(1, y, "(no players in range)", colors.gray)
    y = y + 1
  else
    for _, e in ipairs(inside) do
      if y >= h - 6 then break end
      local r = e.row
      local line = ("%-16s %-3s %-19s %s"):format(
        e.name:sub(1, 16),
        sideShort(r.entrySide),
        tostring(r.enteredText or "?"):sub(1, 19),
        tostring(r.lastGate or r.entrySide or ""):sub(1, math.max(1, w - 42))
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
    put(1, y, ("%s %-5s %-12s %-4s %s"):format(
      tostring(e.time):sub(-8), e.kind, tostring(e.player):sub(1, 12),
      sideShort(e.side),
      tostring(e.gate or ""):sub(1, 12)), fg)
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
  print("Perimeter manager — territory board")
  print("ORIGIN: here | origin | setpos <x> <y> <z>")
  print("GATES : sensors | assign [id|all] | set <id|all> side|range|name ...")
  print("        range <n>     push detection range to all sensors")
  print("VIEW  : status | log [n] | clear | grace <s> | title <name>")
  print("Sides : n ne e se s sw w nw  (auto from GPS vs origin)")
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
      rednet.broadcast({
        type = MSG.PERIMETER_HELLO or "perimeter_hello",
        kind = "manager", origin = cfg.origin, defaultRange = cfg.defaultRange,
      }, P)
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
      print("Usage: set <id|all> side <dir>")
      print("       set <id|all> range <n>")
      print("       set <id|all> name <label>")
      return true
    end
    if field == "side" then
      local side = normalizeSide(a[4])
      if not side then print("side: n|ne|e|se|s|sw|w|nw"); return true end
      sendConfig(id, { side = side, name = sidePretty(side) .. " Gate", autoName = true })
      if id ~= "*" and sensors[id] then
        sensors[id].side = side
        sensors[id].gate = sidePretty(side) .. " Gate"
      end
      print("Pushed side " .. sidePretty(side) .. " → " .. tostring(id))
    elseif field == "range" then
      local r = math.floor(tonumber(a[4]) or 0)
      if r < 1 then print("Usage: set <id|all> range <n>"); return true end
      sendConfig(id, { range = r })
      if id == "*" then cfg.defaultRange = r; saveCfg() end
      if id ~= "*" and sensors[id] then sensors[id].range = r end
      print("Pushed range " .. r .. " → " .. tostring(id))
    elseif field == "name" then
      if not a[4] then print("Usage: set <id|all> name <label>"); return true end
      local name = table.concat(a, " ", 4)
      sendConfig(id, { name = name, autoName = false })
      if id ~= "*" and sensors[id] then sensors[id].gate = name end
      print("Pushed name → " .. tostring(id))
    else
      print("Unknown field. Use side|range|name")
    end
  elseif cmd == "range" then
    local r = math.floor(tonumber(a[2]) or 0)
    if r < 1 then
      print("defaultRange = " .. tostring(cfg.defaultRange))
      print("Usage: range <n>   (push to all sensors)")
    else
      cfg.defaultRange = r
      saveCfg()
      sendConfig("*", { range = r })
      for _, s in pairs(sensors) do s.range = r end
      print("Pushed range " .. r .. " to all sensors.")
    end
  elseif cmd == "status" then
    local list = sortedPlayers()
    print(("Inside (%d):"):format(#list))
    if #list == 0 then print("  (none)") end
    for _, e in ipairs(list) do
      local r = e.row
      print(("  %-16s entered %s from %s  (%s)"):format(
        e.name, tostring(r.enteredText), sideShort(r.entrySide),
        tostring(r.lastGate or "")))
    end
  elseif cmd == "log" then
    local n = tonumber(a[2]) or 20
    for i = 1, math.min(n, #log) do
      local e = log[i]
      print(("%s  %-5s  %-12s  %-4s  %s"):format(
        e.time, e.kind, e.player, sideShort(e.side), tostring(e.gate or "")))
    end
    if #log == 0 then print("(no events yet)") end
  elseif cmd == "sensors" or cmd == "gates" then
    if cfg.origin then
      print(("origin %d,%d,%d"):format(cfg.origin.x, cfg.origin.y, cfg.origin.z))
    else
      print("origin unset — run `here`")
    end
    local n = 0
    local ids = {}
    for id in pairs(sensors) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local s = sensors[id]
      local age = math.floor((nowUtc() - (s.seen or 0)) / 1000)
      local pos = (s.x and ("%d,%d,%d"):format(s.x, s.y or 0, s.z)) or "no-gps"
      print(("#%d  %-4s  %-16s  range=%s  %s  %ss"):format(
        id, sideShort(s.side), tostring(s.gate or "?"):sub(1, 16),
        tostring(s.range or "?"), pos, age))
      n = n + 1
    end
    if n == 0 then print("(no sensors heard)") end
  elseif cmd == "clear" then
    present, log = {}, {}
    dirty = true
    print("Cleared presence and log.")
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
print("8-way auto-assign from origin. Default sensor range " .. DEFAULT_SENSOR_RANGE .. ".")
if not cfg.origin then
  print("Tip: stand at territory center and type: here")
else
  print(("origin %d,%d,%d"):format(cfg.origin.x, cfg.origin.y, cfg.origin.z))
end
print("Type help.")
print("")

rednet.broadcast({
  type = MSG.PERIMETER_HELLO or "perimeter_hello",
  kind = "manager",
  name = os.getComputerLabel(),
  origin = cfg.origin,
  defaultRange = cfg.defaultRange or DEFAULT_SENSOR_RANGE,
}, P)

local function netLoop()
  while true do
    local id, msg = rednet.receive(P, 0.5)
    if msg then handleMsg(id, msg) end
  end
end

local function tickLoop()
  while true do
    confirmExits()
    if dirty then drawAll() end
    sleep(0.5)
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
  consoleLoop,
  function() titan.networkLoop("perimeter_manager") end
)
print("Perimeter manager stopped.")
