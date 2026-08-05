--[[
  hub.lua  -  Control computer for the Titan bot network (CC: Tweaked)

  Runs on a normal (or advanced) computer that has:
    * a wireless modem  (to talk to bots & POIs)
    * a monitor         (optional but recommended - shows live status)

  It does two things at once:
    1. Listens to the network, tracks every bot and POI, and redraws the
       monitor with live status.
    2. Gives you a command console (in the computer's own terminal) to
       dispatch bots.

  Console commands:
    list                     - list bots and POIs
    send   <bot> <poi>       - send a bot to a named POI
    goto   <bot> <x> <y> <z> - send a bot to raw coordinates
    return <bot>             - send a bot to its home position
    refuel <bot>             - tell a bot to refuel from its inventory
    stop   <bot>             - cancel a bot's current task
    ping                     - ping everyone
    help                     - show this list
    exit                     - quit the hub

  <bot> may be the turtle's label OR its computer id.
]]

local titan = dofile("lib/titan.lua")

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Hub-" .. os.getComputerID()))

-- Optional monitor.
local monitor = peripheral.find("monitor")
if monitor then
  monitor.setTextScale(0.5)
end

-- Live state -----------------------------------------------------------------
local bots  = {}  -- [id] = { name, x, y, z, fuel, state, task, seen }
local pois  = {}  -- [name] = { x, y, z, id, desc, seen }
local stuck = {}  -- recent STUCK alerts (newest first)

local function now() return os.epoch("utc") end
local function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end

-- Resolve a user-typed bot reference (label or id) to a bot id.
local function findBot(ref)
  if bots[tonumber(ref) or -1] then return tonumber(ref) end
  for id, b in pairs(bots) do
    if b.name and b.name:lower() == tostring(ref):lower() then return id end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Monitor rendering
--------------------------------------------------------------------------------
local function draw()
  local out = monitor or term
  local w, h = out.getSize()
  out.setBackgroundColor(colors.black)
  out.clear()
  out.setCursorPos(1, 1)

  local function line(y, text, color)
    out.setCursorPos(1, y)
    out.setTextColor(color or colors.white)
    out.write(text:sub(1, w))
  end

  line(1, "== TITAN CONTROL ==  bots:" .. (function()
    local n = 0; for _ in pairs(bots) do n = n + 1 end; return n
  end)() .. "  pois:" .. (function()
    local n = 0; for _ in pairs(pois) do n = n + 1 end; return n
  end)(), colors.yellow)

  line(2, "NAME        POS            FUEL   STATE     TASK", colors.lightGray)

  local y = 3
  for id, b in pairs(bots) do
    if y >= h - 3 then break end
    local stale = ago(b.seen) > 15
    local pos = ("%d,%d,%d"):format(b.x or 0, b.y or 0, b.z or 0)
    local row = ("%-11s %-14s %-6s %-9s %s"):format(
      (b.name or ("#" .. id)):sub(1, 11),
      pos:sub(1, 14),
      tostring(b.fuel or "?"):sub(1, 6),
      (b.state or "?"):sub(1, 9),
      (b.task or "-"))
    line(y, row, stale and colors.gray or colors.white)
    y = y + 1
  end

  y = y + 1
  line(y, "-- POINTS OF INTEREST --", colors.orange); y = y + 1
  for name, p in pairs(pois) do
    if y >= h - 2 then break end
    line(y, ("%-12s %d,%d,%d  %s"):format(
      name:sub(1, 12), p.x, p.y, p.z, (p.desc or "")), colors.lime)
    y = y + 1
  end

  if #stuck > 0 then
    y = y + 1
    line(y, "-- STUCK ALERTS --", colors.red); y = y + 1
    for i = 1, math.min(#stuck, h - y) do
      local a = stuck[i]
      line(y, ("!%s @ %d,%d,%d %s"):format(
        a.name or "?", a.x or 0, a.y or 0, a.z or 0, a.reason or ""), colors.red)
      y = y + 1
    end
  end
end

--------------------------------------------------------------------------------
-- Network loop
--------------------------------------------------------------------------------
local function handle(id, msg)
  if msg.type == titan.MSG.REGISTER or msg.type == titan.MSG.STATUS then
    local b = bots[id] or {}
    b.name  = msg.name or b.name
    b.x, b.y, b.z = msg.x or b.x, msg.y or b.y, msg.z or b.z
    b.fuel  = msg.fuel  ~= nil and msg.fuel  or b.fuel
    b.state = msg.state or b.state
    b.task  = msg.task  or b.task
    b.seen  = now()
    bots[id] = b
    if msg.type == titan.MSG.REGISTER then
      print(("[+] bot registered: %s (#%d)"):format(b.name or "?", id))
    end

  elseif msg.type == titan.MSG.POI_REGISTER then
    pois[msg.poi or ("poi#" .. id)] = {
      x = msg.x, y = msg.y, z = msg.z, id = id, desc = msg.desc, seen = now(),
    }
    print(("[+] POI registered: %s @ %d,%d,%d"):format(
      msg.poi or "?", msg.x or 0, msg.y or 0, msg.z or 0))

  elseif msg.type == titan.MSG.STUCK then
    table.insert(stuck, 1, { name = msg.name or ("#" .. id), x = msg.x, y = msg.y, z = msg.z, reason = msg.reason })
    while #stuck > 15 do table.remove(stuck) end
    print(("[STUCK] %s @ %d,%d,%d : %s"):format(
      msg.name or ("#" .. id), msg.x or 0, msg.y or 0, msg.z or 0, msg.reason or "?"))

  elseif msg.type == titan.MSG.DISPATCH then
    -- A POI is requesting a bot. Pick the first idle bot (or any bot).
    local target = pois[msg.poi]
    if target then
      local chosen
      for bid, b in pairs(bots) do
        if b.state == "idle" then chosen = bid; break end
        chosen = chosen or bid
      end
      if chosen then
        titan.send(chosen, titan.MSG.COMMAND, {
          cmd = "goto", x = target.x, y = target.y, z = target.z,
          job = msg.job, poi = msg.poi,
        })
        print(("[>] dispatched #%d to POI %s"):format(chosen, msg.poi))
      else
        print("[!] dispatch requested but no bots available")
      end
    end

  elseif msg.type == titan.MSG.ACK then
    if msg.task then bots[id] = bots[id] or {}; bots[id].task = msg.task end

  elseif msg.type == titan.MSG.PONG then
    print(("[pong] #%d %s"):format(id, msg.name or ""))
  end
end

local function networkLoop()
  titan.broadcast(titan.MSG.PING, {})   -- ask everyone to announce themselves
  local drawTimer = os.startTimer(1)
  while true do
    local event, p1, p2, p3 = os.pullEvent()
    if event == "rednet_message" and p3 == titan.PROTOCOL and type(p2) == "table" then
      handle(p1, p2)
    elseif event == "timer" and p1 == drawTimer then
      draw()
      drawTimer = os.startTimer(1)
    end
  end
end

--------------------------------------------------------------------------------
-- Command console
--------------------------------------------------------------------------------
local function needBot(ref)
  local id = findBot(ref)
  if not id then print("[!] unknown bot: " .. tostring(ref)) end
  return id
end

local function consoleLoop()
  print("Titan hub online. Type 'help' for commands.")
  while true do
    write("titan> ")
    local input = read()
    local args = {}
    for w in tostring(input):gmatch("%S+") do args[#args + 1] = w end
    local cmd = (args[1] or ""):lower()

    if cmd == "" then
      -- ignore
    elseif cmd == "help" then
      print("list | send <bot> <poi> | goto <bot> <x> <y> <z> |")
      print("return <bot> | refuel <bot> | stop <bot> | ping | exit")
    elseif cmd == "list" then
      print("Bots:")
      for id, b in pairs(bots) do
        print(("  %s (#%d) %s @ %d,%d,%d fuel:%s"):format(
          b.name or "?", id, b.state or "?", b.x or 0, b.y or 0, b.z or 0,
          tostring(b.fuel or "?")))
      end
      print("POIs:")
      for name, p in pairs(pois) do
        print(("  %s @ %d,%d,%d %s"):format(name, p.x, p.y, p.z, p.desc or ""))
      end
    elseif cmd == "send" then
      local id = needBot(args[2])
      local poi = pois[args[3] or ""]
      if id and poi then
        titan.send(id, titan.MSG.COMMAND,
          { cmd = "goto", x = poi.x, y = poi.y, z = poi.z, poi = args[3] })
        print(("[>] %s -> POI %s"):format(args[2], args[3]))
      elseif id then print("[!] unknown POI: " .. tostring(args[3])) end
    elseif cmd == "goto" then
      local id = needBot(args[2])
      local x, y, z = tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
      if id and x and y and z then
        titan.send(id, titan.MSG.COMMAND, { cmd = "goto", x = x, y = y, z = z })
        print(("[>] %s -> %d,%d,%d"):format(args[2], x, y, z))
      elseif id then print("[!] usage: goto <bot> <x> <y> <z>") end
    elseif cmd == "return" then
      local id = needBot(args[2])
      if id then titan.send(id, titan.MSG.COMMAND, { cmd = "return" }) end
    elseif cmd == "refuel" then
      local id = needBot(args[2])
      if id then titan.send(id, titan.MSG.COMMAND, { cmd = "refuel" }) end
    elseif cmd == "stop" then
      local id = needBot(args[2])
      if id then titan.send(id, titan.MSG.COMMAND, { cmd = "stop" }) end
    elseif cmd == "ping" then
      titan.broadcast(titan.MSG.PING, {})
      print("[>] pinged everyone")
    elseif cmd == "exit" then
      return
    else
      print("[!] unknown command: " .. cmd)
    end
  end
end

parallel.waitForAny(networkLoop, consoleLoop,
  function() titan.networkLoop("hub") end)
if monitor then monitor.clear() end
print("Titan hub stopped.")
