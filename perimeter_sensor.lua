--[[
  perimeter_sensor.lua  -  Territory edge sensor (Advanced Peripherals Player Detector)
  Titan-Version: 1.0.0

  Place on a computer at a perimeter gate with:
    * Advanced Peripherals Player Detector (adjacent / networked)
    * Wireless modem (joins the Titan mesh)

  Configure which compass face this gate covers, then it polls the detector and
  reports enter/exit events to the perimeter manager.

  Setup:
    side north|east|south|west   which edge of your territory this is
    range <n>                    detection radius (blocks from the detector)
    name <label>                 e.g. North Gate
    status | help

  Requires: modem, playerDetector / player_detector, lib/titan.lua
  Pair with: perimeter_manager.lua
]]

local titan = dofile("lib/titan.lua")
local MSG = titan.MSG
local P = titan.PROTOCOL

titan.openModem()

local CFG = "perimeter_sensor.cfg"
local cfg = {
  side = nil,       -- north|east|south|west
  range = 8,
  name = nil,
  poll = 0.5,       -- seconds between scans
}

local seen = {}     -- [player] = true  (currently in range)
local detector = nil

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

local function normalizeSide(s)
  s = tostring(s or ""):lower()
  if s == "n" then s = "north" end
  if s == "e" then s = "east" end
  if s == "s" then s = "south" end
  if s == "w" then s = "west" end
  if s == "north" or s == "east" or s == "south" or s == "west" then
    return s
  end
  return nil
end

local function findDetector()
  local d = peripheral.find("playerDetector")
  if d then return d, "playerDetector" end
  d = peripheral.find("player_detector")
  if d then return d, "player_detector" end
  return nil, nil
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
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do payload[k] = v end
  end
  titan.broadcast(msgType, payload)
end

local function listInRange()
  if not detector then return {} end
  local ok, list = pcall(function()
    return detector.getPlayersInRange(tonumber(cfg.range) or 8)
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
      print(("[%s] ENTER %s via %s"):format(os.date("%H:%M:%S") or "?", name, cfg.side:upper()))
      sendEvent(MSG.PERIMETER_ENTER or "perimeter_enter", name)
    end
  end
  for name in pairs(seen) do
    if not nowSet[name] then
      seen[name] = nil
      print(("[%s] EXIT  %s via %s"):format(os.date("%H:%M:%S") or "?", name, cfg.side:upper()))
      sendEvent(MSG.PERIMETER_EXIT or "perimeter_exit", name)
    end
  end
  -- Heartbeat roster for the manager (debounce overlapping gates).
  local utc, text = stamp()
  rednet.broadcast({
    type = MSG.PERIMETER_PULSE or "perimeter_pulse",
    side = cfg.side,
    gate = gateLabel(),
    sensorId = os.getComputerID(),
    players = list,
    ts = utc,
    time = text,
  }, P)
end

local function printHelp()
  print("Perimeter sensor — Player Detector gate")
  print("  side <north|east|south|west>   which territory edge")
  print("  range <blocks>                 default 8")
  print("  name <label>                   gate display name")
  print("  poll <seconds>                 scan rate (default 0.5)")
  print("  status | help")
end

local function printStatus()
  print("gate: " .. gateLabel())
  print("side: " .. tostring(cfg.side or "(set with: side north)"))
  print("range: " .. tostring(cfg.range) .. "  poll: " .. tostring(cfg.poll))
  local d, kind = findDetector()
  print("detector: " .. (d and kind or "NOT FOUND — place Player Detector on this computer"))
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  print(("in range now: %d"):format(n))
  for name in pairs(seen) do print("  - " .. name) end
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
      print("Usage: side north|east|south|west")
    else
      cfg.side = s
      saveCfg()
      print("side = " .. s)
    end
  elseif cmd == "range" then
    local n = tonumber(a[2])
    if not n or n < 1 then
      print("Usage: range <blocks>")
    else
      cfg.range = math.floor(n)
      saveCfg()
      print("range = " .. cfg.range)
    end
  elseif cmd == "name" or cmd == "label" then
    if not a[2] then
      print("name = " .. gateLabel())
    else
      cfg.name = table.concat(a, " ", 2)
      saveCfg()
      os.setComputerLabel(cfg.name)
      print("name = " .. cfg.name)
    end
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
os.setComputerLabel(os.getComputerLabel() or cfg.name or ("Perimeter-" .. os.getComputerID()))
cfg.name = cfg.name or os.getComputerLabel()
saveCfg()

detector = findDetector()

term.clear(); term.setCursorPos(1, 1)
print("== Perimeter Sensor ==")
print(gateLabel() .. "  #" .. os.getComputerID())
if not detector then
  print("WARNING: No playerDetector / player_detector found.")
  print("Attach an Advanced Peripherals Player Detector.")
else
  print("Detector OK.")
end
if not cfg.side then
  print("")
  print("First-time setup — which edge is this gate?")
  print("  north / east / south / west")
  write("side> ")
  local s = normalizeSide(read())
  if s then
    cfg.side = s
    saveCfg()
    print("side = " .. s)
  else
    print("Set later with: side north")
  end
end
print("")
print(("Reporting %s  range=%s. Type help."):format(
  tostring(cfg.side or "?"), tostring(cfg.range)))
print("")

local function scanLoop()
  while true do
    local ok, err = pcall(scanOnce)
    if not ok then print("scan error: " .. tostring(err)) end
    sleep(tonumber(cfg.poll) or 0.5)
  end
end

local function helloLoop()
  while true do
    rednet.broadcast({
      type = MSG.PERIMETER_HELLO or "perimeter_hello",
      kind = "sensor",
      side = cfg.side,
      gate = gateLabel(),
      sensorId = os.getComputerID(),
      range = cfg.range,
    }, P)
    sleep(15)
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
  consoleLoop,
  function() titan.networkLoop("perimeter_sensor") end
)
print("Perimeter sensor stopped.")
