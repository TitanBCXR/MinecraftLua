--[[
  botserver.lua  -  "Bots Computer" for the Titan network (CC: Tweaked)

  The coordination hub for builder & gatherer bots (worker.lua). Runs on a
  computer with a wireless modem (and optionally a monitor).

  It:
    * tracks every bot, its type, position, fuel and state;
    * keeps the GATHER BOARD (chests waiting to be emptied to storage);
    * keeps the COAL board (start points that asked for fuel);
    * stores PRESET BUILDS uploaded by scanning builders (builds/<name>.txt);
    * shows STUCK alerts reported by gatherers;
    * lets an admin push scan/build orders to builders.

  Console commands:
    bots                       list bots and their types
    gathers                    list open gather posts
    coal                       list coal drop-off requests
    builds                     list stored preset builds
    alerts                     list recent STUCK alerts
    scan  <bot> <name> <W> <H> <L>   order a builder to scan a box into a preset
    build <bot> <name> [x y z]       order a builder to build a preset
    order <bot> goto <x> <y> <z>     move a bot
    ping                       re-discover everyone
    help | exit
]]

local titan = dofile("lib/titan.lua")
local P   = titan.PROTOCOL
local MSG = titan.MSG

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Bots-" .. os.getComputerID()))

local BUILD_DIR = "builds"
if not fs.exists(BUILD_DIR) then fs.makeDir(BUILD_DIR) end

local bots    = {}   -- [id] = { name, botType, x,y,z, fuel, state, task, seen }
local gathers = {}   -- [id] = { id, pos, accepts, mode, deposit, seen }
local coal    = {}   -- [id] = { from, pos, seen }
local alerts  = {}   -- recent stuck alerts (newest first)
local monitor = peripheral.find("monitor")
if monitor then monitor.setTextScale(0.5) end

local function now() return os.epoch("utc") end
local function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end
local function fmt(p) return p and ("%d,%d,%d"):format(p.x or 0, p.y or 0, p.z or 0) or "?" end

local function findBot(ref)
  if bots[tonumber(ref) or -1] then return tonumber(ref) end
  for id, b in pairs(bots) do
    if b.name and b.name:lower() == tostring(ref):lower() then return id end
  end
  return nil
end

local function listBuilds()
  local names = {}
  for _, f in ipairs(fs.list(BUILD_DIR)) do
    if f:sub(-4) == ".txt" then names[#names + 1] = f:sub(1, -5) end
  end
  return names
end

--==============================================================================
-- Monitor
--==============================================================================
local function draw()
  local out = monitor or term
  local w, h = out.getSize()
  out.setBackgroundColor(colors.black); out.clear()
  local function line(y, text, c)
    out.setCursorPos(1, y); out.setTextColor(c or colors.white); out.write(text:sub(1, w))
  end
  local total, gath, build = 0, 0, 0
  for _, b in pairs(bots) do
    if ago(b.seen) < 15 then
      total = total + 1
      if b.botType == "gatherer" then gath = gath + 1 elseif b.botType == "builder" then build = build + 1 end
    end
  end
  line(1, ("== TITAN BOTS ==  active:%d  gather:%d  build:%d"):format(total, gath, build), colors.yellow)
  line(2, "NAME        TYPE     POS            FUEL  STATE", colors.lightGray)
  local y = 3
  for id, b in pairs(bots) do
    if y >= h - 6 then break end
    line(y, ("%-11s %-8s %-14s %-5s %s"):format(
      (b.name or ("#" .. id)):sub(1, 11), (b.botType or "?"):sub(1, 8),
      ("%d,%d,%d"):format(b.x or 0, b.y or 0, b.z or 0):sub(1, 14),
      tostring(b.fuel or "?"):sub(1, 5), (b.state or "?")),
      ago(b.seen) > 15 and colors.gray or colors.white)
    y = y + 1
  end
  y = y + 1
  local ng = 0; for _ in pairs(gathers) do ng = ng + 1 end
  local nc = 0; for _ in pairs(coal) do nc = nc + 1 end
  line(y, ("Gather posts: %d   Coal requests: %d   Builds: %d"):format(ng, nc, #listBuilds()), colors.lime)
  y = y + 1
  line(y, "-- STUCK ALERTS --", colors.orange); y = y + 1
  for i = 1, math.min(#alerts, h - y) do
    local a = alerts[i]
    line(y, ("!%s @ %d,%d,%d %s"):format(a.name or "?", a.x or 0, a.y or 0, a.z or 0, a.reason or ""), colors.red)
    y = y + 1
  end
end

--==============================================================================
-- Network handling
--==============================================================================
local function autoPostFromChest(id, chest, deposit)
  if not chest then return end
  gathers[id] = gathers[id] or {}
  gathers[id].id      = id
  gathers[id].pos     = chest
  gathers[id].accepts = gathers[id].accepts or { "minecraft:coal", "minecraft:charcoal" }
  gathers[id].mode    = gathers[id].mode or "exclude"
  if deposit then gathers[id].deposit = deposit end
  gathers[id].seen    = now()
end

local function handle(id, msg)
  local t = msg.type
  if t == MSG.BOT_REGISTER then
    bots[id] = bots[id] or {}
    bots[id].name, bots[id].botType = msg.name, msg.botType
    bots[id].seen = now()
    autoPostFromChest(id, msg.chest)
    print(("[+] %s registered as %s (#%d)"):format(msg.name or "?", msg.botType or "?", id))

  elseif t == MSG.STATUS then
    local b = bots[id] or {}
    b.name = msg.name or b.name; b.botType = msg.botType or b.botType
    b.x, b.y, b.z = msg.x or b.x, msg.y or b.y, msg.z or b.z
    b.fuel = msg.fuel; b.state = msg.state; b.task = msg.task; b.seen = now()
    bots[id] = b

  elseif t == MSG.GATHER_POST then
    gathers[msg.id or id] = {
      id = msg.id or id, pos = msg.pos, accepts = msg.accepts, mode = msg.mode,
      deposit = msg.deposit, seen = now(),
    }
    print(("[+] gather post @ %s"):format(fmt(msg.pos)))

  elseif t == MSG.GATHER_LIST_REQ then
    titan.send(id, MSG.GATHER_LIST, { gathers = gathers })

  elseif t == MSG.GATHER_DONE then
    if gathers[msg.post] then gathers[msg.post].seen = now() end

  elseif t == MSG.COAL_NEED then
    coal[id] = { from = id, pos = msg.pos, seen = now() }

  elseif t == MSG.COAL_LIST_REQ then
    titan.send(id, MSG.COAL_LIST, { coal = coal })

  elseif t == MSG.COAL_DONE then
    coal[msg.target] = nil

  elseif t == MSG.BUILD_STORE then
    local path = fs.combine(BUILD_DIR, msg.name .. ".txt")
    local f = fs.open(path, "w"); f.write(textutils.serialize(msg.blocks)); f.close()
    print(("[+] stored build '%s' (%d blocks)"):format(msg.name, #(msg.blocks or {})))

  elseif t == MSG.BUILD_LIST_REQ then
    titan.send(id, MSG.BUILD_LIST, { builds = listBuilds() })

  elseif t == MSG.BUILD_GET_REQ then
    local path = fs.combine(BUILD_DIR, tostring(msg.name) .. ".txt")
    if fs.exists(path) then
      local f = fs.open(path, "r"); local blocks = textutils.unserialize(f.readAll()); f.close()
      titan.send(id, MSG.BUILD_GET, { name = msg.name, blocks = blocks })
    end

  elseif t == MSG.STUCK then
    table.insert(alerts, 1, { name = msg.name, x = msg.x, y = msg.y, z = msg.z, reason = msg.reason })
    while #alerts > 20 do table.remove(alerts) end
    print(("[STUCK] %s @ %d,%d,%d : %s"):format(
      msg.name or ("#" .. id), msg.x or 0, msg.y or 0, msg.z or 0, msg.reason or "?"))

  elseif t == MSG.PONG then
    -- discovered; STATUS/REGISTER carry the details
  end
end

local function networkLoop()
  titan.broadcast(MSG.PING, {})
  local drawT = os.startTimer(1)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "rednet_message" and p3 == P and type(p2) == "table" then
      handle(p1, p2)
    elseif ev == "timer" and p1 == drawT then
      draw(); drawT = os.startTimer(1)
    end
  end
end

--==============================================================================
-- Console
--==============================================================================
local function consoleLoop()
  print("Bots Computer online. Type 'help'.")
  while true do
    write("bots> ")
    local a = {}
    for w in tostring(read()):gmatch("%S+") do a[#a + 1] = w end
    local cmd = (a[1] or ""):lower()

    if cmd == "" then
    elseif cmd == "help" then
      print("bots | gathers | coal | builds | alerts | ping")
      print("scan <bot> <name> <W> <H> <L>")
      print("build <bot> <name> [x y z] | order <bot> goto <x> <y> <z> | exit")
    elseif cmd == "bots" then
      for id, b in pairs(bots) do
        print(("  #%-3d %-12s %-8s %s fuel:%s %ss"):format(
          id, b.name or "?", b.botType or "?",
          ("%d,%d,%d"):format(b.x or 0, b.y or 0, b.z or 0), tostring(b.fuel or "?"), ago(b.seen)))
      end
    elseif cmd == "gathers" then
      for gid, g in pairs(gathers) do
        print(("  #%-3d chest %s accepts=%s mode=%s"):format(
          gid, fmt(g.pos), type(g.accepts) == "table" and table.concat(g.accepts, ",") or tostring(g.accepts),
          tostring(g.mode or "include")))
      end
    elseif cmd == "coal" then
      for cid, c in pairs(coal) do print(("  #%-3d needs coal @ %s"):format(cid, fmt(c.pos))) end
    elseif cmd == "builds" then
      for _, n in ipairs(listBuilds()) do print("  " .. n) end
    elseif cmd == "alerts" then
      for i, al in ipairs(alerts) do
        print(("  %2d) %s @ %d,%d,%d %s"):format(i, al.name or "?", al.x or 0, al.y or 0, al.z or 0, al.reason or ""))
      end
    elseif cmd == "scan" then
      local id = findBot(a[2])
      if id and a[3] and a[4] and a[5] and a[6] then
        titan.send(id, MSG.SCAN_ORDER, { name = a[3], W = tonumber(a[4]), H = tonumber(a[5]), L = tonumber(a[6]) })
        print("Scan order sent to " .. a[2])
      else print("Usage: scan <bot> <name> <W> <H> <L>") end
    elseif cmd == "build" then
      local id = findBot(a[2])
      if id and a[3] then
        local x, y, z = tonumber(a[4]), tonumber(a[5]), tonumber(a[6])
        titan.send(id, MSG.BUILD_ORDER, { name = a[3], x = x, y = y, z = z })
        print("Build order sent to " .. a[2])
      else print("Usage: build <bot> <name> [x y z]") end
    elseif cmd == "order" then
      local id = findBot(a[2])
      if id and (a[3] or ""):lower() == "goto" and a[6] then
        titan.send(id, MSG.COMMAND, { cmd = "goto", x = tonumber(a[4]), y = tonumber(a[5]), z = tonumber(a[6]) })
      else print("Usage: order <bot> goto <x> <y> <z>") end
    elseif cmd == "ping" then
      titan.broadcast(MSG.PING, {}); print("Pinged.")
    elseif cmd == "exit" then
      return
    else
      print("Unknown: " .. cmd)
    end
  end
end

parallel.waitForAny(networkLoop, consoleLoop)
if monitor then monitor.clear() end
print("Bots Computer stopped.")
