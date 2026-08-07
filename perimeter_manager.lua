--[[
  perimeter_manager.lua  -  Territory board for perimeter sensors
  Titan-Version: 1.0.0

  Central display for perimeter_sensor.lua gates. Shows who is inside the
  territory, which side they entered from (N/E/S/W), enter time, and a rolling
  enter/exit log with timestamps.

  Setup:
    * Computer with wireless modem (+ optional monitor)
    * Perimeter sensors on the mesh, each configured with `side north|...`

  Commands:
    status | clear | log | sensors | help
    grace <seconds>     how long after last sighting before marking EXIT
    title <name>

  Requires: modem, lib/titan.lua
]]

local titan = dofile("lib/titan.lua")
local MSG = titan.MSG
local P = titan.PROTOCOL

titan.openModem()

local CFG = "perimeter_manager.cfg"
local LOG_MAX = 80
local cfg = {
  title = "Territory",
  grace = 4,   -- seconds without any sensor pulse before confirmed exit
}

-- present[player] = {
--   entrySide, enteredAt, enteredText, lastSide, lastGate, lastSeen,
--   pendingExit, pendingSide, pendingText
-- }
local present = {}
local log = {}          -- newest first
local sensors = {}      -- [id] = { side, gate, seen, players={} }
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
end

local function nowUtc() return os.epoch("utc") end

local function formatTime(utc, fallback)
  if fallback and fallback ~= "" then return fallback end
  local ok, text = pcall(os.date, "!%Y-%m-%d %H:%M:%S", math.floor((utc or 0) / 1000))
  if ok and type(text) == "string" then return text end
  ok, text = pcall(os.date, "%H:%M:%S")
  return (ok and text) or tostring(utc or "?")
end

local function sideShort(s)
  s = tostring(s or "?"):lower()
  if s == "north" then return "N" end
  if s == "east" then return "E" end
  if s == "south" then return "S" end
  if s == "west" then return "W" end
  return s:sub(1, 1):upper()
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
    tostring(side or "?"):upper(), tostring(gate or "")))
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
    -- First sighting always logs ENTER (pulse or enter event).
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
  -- Overlapping gates: wait for grace unless forced by confirmed leave.
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
      -- Lost all pulses without an explicit exit event.
      pushLog("EXIT", name, row.lastSide, row.lastGate, t, formatTime(t))
      remove[#remove + 1] = name
    end
  end
  for _, name in ipairs(remove) do
    present[name] = nil
    dirty = true
  end
end

local function handleMsg(id, msg)
  if type(msg) ~= "table" or not msg.type then return end
  local t = msg.type
  if t == MSG.PERIMETER_HELLO or t == "perimeter_hello" then
    if msg.kind == "sensor" or msg.side then
      sensors[id] = sensors[id] or {}
      sensors[id].side = msg.side or sensors[id].side
      sensors[id].gate = msg.gate or sensors[id].gate
      sensors[id].range = msg.range or sensors[id].range
      sensors[id].seen = nowUtc()
      dirty = true
    end
  elseif t == MSG.PERIMETER_ENTER or t == "perimeter_enter" then
    if msg.player then
      local ets = msg.eventTs or msg.ts
      touchPresent(msg.player, msg.side, msg.gate, ets, msg.time, true)
      sensors[id] = sensors[id] or {}
      sensors[id].side = msg.side or sensors[id].side
      sensors[id].gate = msg.gate or sensors[id].gate
      sensors[id].seen = nowUtc()
    end
  elseif t == MSG.PERIMETER_EXIT or t == "perimeter_exit" then
    if msg.player then
      markExit(msg.player, msg.side, msg.gate, msg.eventTs or msg.ts, msg.time)
      if sensors[id] then sensors[id].seen = nowUtc() end
    end
  elseif t == MSG.PERIMETER_PULSE or t == "perimeter_pulse" then
    sensors[id] = sensors[id] or {}
    sensors[id].side = msg.side or sensors[id].side
    sensors[id].gate = msg.gate or sensors[id].gate
    sensors[id].seen = nowUtc()
    sensors[id].players = msg.players or {}
    for _, name in ipairs(msg.players or {}) do
      if type(name) == "string" then
        touchPresent(name, msg.side, msg.gate, msg.eventTs or msg.ts, msg.time, false)
      end
    end
    dirty = true
  end
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
  put(1, 2, os.date("%Y-%m-%d %H:%M:%S") or "", colors.lightGray)

  local nSens = 0
  for _, s in pairs(sensors) do
    if (nowUtc() - (s.seen or 0)) < 30000 then nSens = nSens + 1 end
  end
  local inside = sortedPlayers()
  put(1, 3, ("Inside: %d   Gates online: %d   grace=%ss"):format(
    #inside, nSens, tostring(cfg.grace)), colors.lime)

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
      local fg = r.pendingExit and colors.yellow or colors.white
      put(1, y, line, fg)
      y = y + 1
    end
  end

  y = math.min(h - 5, y + 1)
  put(1, y, "RECENT EVENTS", colors.orange); y = y + 1
  for i = 1, math.min(#log, h - y) do
    local e = log[i]
    local fg = (e.kind == "ENTER") and colors.lime or colors.red
    put(1, y, ("%s %-5s %-12s %-5s %s"):format(
      tostring(e.time):sub(-8), e.kind, tostring(e.player):sub(1, 12),
      tostring(e.side or "?"):upper():sub(1, 5),
      tostring(e.gate or ""):sub(1, 12)), fg)
    y = y + 1
  end
end

local function drawAll()
  local mon = findMonitor()
  if mon then
    drawOn(mon)
  end
  -- Keep terminal as a compact status when not using monitor-only.
  if not mon then
    term.setBackgroundColor(colors.black)
    drawOn(term)
  elseif dirty then
    -- Small terminal heartbeat
    term.setCursorPos(1, 1)
  end
  dirty = false
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function printHelp()
  print("Perimeter manager — territory board")
  print("  status     show who's inside")
  print("  log [n]    recent enter/exit events")
  print("  sensors    list perimeter gates")
  print("  clear      clear presence + log")
  print("  grace <s>  exit confirm delay (default 4)")
  print("  title <name>")
  print("  help")
end

local function handleCommand(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = (a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" or cmd == "?" then
    printHelp()
  elseif cmd == "status" then
    local list = sortedPlayers()
    print(("Inside (%d):"):format(#list))
    if #list == 0 then print("  (none)") end
    for _, e in ipairs(list) do
      local r = e.row
      print(("  %-16s entered %s from %s  (%s)"):format(
        e.name, tostring(r.enteredText), tostring(r.entrySide):upper(),
        tostring(r.lastGate or "")))
    end
  elseif cmd == "log" then
    local n = tonumber(a[2]) or 20
    for i = 1, math.min(n, #log) do
      local e = log[i]
      print(("%s  %-5s  %-12s  %-5s  %s"):format(
        e.time, e.kind, e.player, tostring(e.side):upper(), tostring(e.gate or "")))
    end
    if #log == 0 then print("(no events yet)") end
  elseif cmd == "sensors" or cmd == "gates" then
    local n = 0
    for id, s in pairs(sensors) do
      local age = math.floor((nowUtc() - (s.seen or 0)) / 1000)
      print(("#%d  %-5s  %-16s  %ss ago  range=%s"):format(
        id, tostring(s.side or "?"):upper(), tostring(s.gate or "?"),
        age, tostring(s.range or "?")))
      n = n + 1
    end
    if n == 0 then print("(no sensors heard — check mesh + sensor scripts)") end
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
print("Listening for perimeter_sensor gates on the mesh.")
print("Attach a monitor for the full board. Type help.")
print("")

rednet.broadcast({
  type = MSG.PERIMETER_HELLO or "perimeter_hello",
  kind = "manager",
  name = os.getComputerLabel(),
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
