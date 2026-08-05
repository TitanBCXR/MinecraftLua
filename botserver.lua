--[[
  botserver.lua  -  "Bots Computer" for the Titan network (CC: Tweaked)
  Titan-Version: 1.2.1

  Coordination hub for the three bot types:
    * builder  / gatherer  (worker.lua)
    * miner                (miner.lua)

  Tracks status + assignments and draws them on an attached monitor.
  Parent Center (datacenter.lua) handles deploy/auth; this machine is the
  live ops board and order desk.

  Console:
    bots | builders | gatherers | miners
    gathers | coal | builds | alerts | ping
    scan  <bot> <name> <W> <H> <L>
    build <bot> <name> [x y z]
    mine  <bot> | stop <bot>
    order <bot> goto <x> <y> <z>
    assign <bot> <text>   (ops note shown on monitor)
    help | exit
]]

local titan = dofile("lib/titan.lua")
local P   = titan.PROTOCOL
local MSG = titan.MSG

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Bots-" .. os.getComputerID()))

local BUILD_DIR = "builds"
if not fs.exists(BUILD_DIR) then fs.makeDir(BUILD_DIR) end

local BOT_TYPES = { builder = true, gatherer = true, miner = true }

local bots    = {}   -- [id] = { name, botType, x,y,z, fuel, state, task, assignment, dug, seen }
local gathers = {}   -- [id] = { id, pos, accepts, mode, deposit, seen }
local coal    = {}   -- [id] = { from, pos, seen }
local alerts  = {}   -- recent stuck alerts (newest first)
local assigns = {}   -- [id] = ops assignment note (optional override)

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

local function assignmentOf(id, b)
  if assigns[id] and assigns[id] ~= "" then return assigns[id] end
  if b.assignment and b.assignment ~= "" and b.assignment ~= "-" then return b.assignment end
  if b.task and b.task ~= "" and b.task ~= "-" then return b.task end
  return "-"
end

local function countByType()
  local n = { builder = 0, gatherer = 0, miner = 0, total = 0, busy = 0 }
  for _, b in pairs(bots) do
    if ago(b.seen) < 20 then
      n.total = n.total + 1
      local t = b.botType
      if n[t] ~= nil then n[t] = n[t] + 1 end
      local st = b.state or ""
      if st == "moving" or st == "working" or st == "mining" or st == "gathering" then
        n.busy = n.busy + 1
      end
    end
  end
  return n
end

local function sortedBotIds(filterType)
  local ids = {}
  for id, b in pairs(bots) do
    if not filterType or b.botType == filterType then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids, function(a, b)
    local da, db = bots[a], bots[b]
    local oa, ob = ago(da.seen) < 20, ago(db.seen) < 20
    if oa ~= ob then return oa end
    local na = tostring(da.name or "")
    local nb = tostring(db.name or "")
    if na ~= nb then return na:lower() < nb:lower() end
    return a < b
  end)
  return ids
end

--==============================================================================
-- Monitor — status + assignments for all three types
--==============================================================================
local function draw()
  local out = monitor or term
  if not monitor and term then
    -- Only paint term when no monitor (avoid fighting the console).
    return
  end
  local w, h = out.getSize()
  out.setBackgroundColor(colors.black); out.clear()
  local function line(y, text, c)
    if y < 1 or y > h then return end
    out.setCursorPos(1, y)
    out.setTextColor(c or colors.white)
    out.write(tostring(text):sub(1, w))
  end

  local n = countByType()
  line(1, "== TITAN BOTS ==", colors.yellow)
  line(2, ("active:%d  build:%d  gather:%d  mine:%d  busy:%d"):format(
    n.total, n.builder, n.gatherer, n.miner, n.busy), colors.lime)
  line(3, "NAME         TYPE     STATE    ASSIGNMENT          POS         FUEL", colors.lightGray)

  local y = 4
  local function drawType(title, btype, color)
    if y >= h - 4 then return end
    line(y, ("-- %s --"):format(title), color or colors.orange)
    y = y + 1
    local any = false
    for _, id in ipairs(sortedBotIds(btype)) do
      if y >= h - 3 then break end
      local b = bots[id]
      local online = ago(b.seen) < 20
      any = true
      local asg = assignmentOf(id, b):sub(1, 18)
      local pos = ("%d,%d,%d"):format(b.x or 0, b.y or 0, b.z or 0):sub(1, 11)
      line(y, ("%-12s %-8s %-8s %-18s %-11s %s"):format(
        (b.name or ("#" .. id)):sub(1, 12),
        (b.botType or "?"):sub(1, 8),
        tostring(b.state or "?"):sub(1, 8),
        asg, pos, tostring(b.fuel or "?"):sub(1, 5)),
        online and colors.white or colors.gray)
      y = y + 1
    end
    if not any then
      if y < h - 3 then
        line(y, "  (none online)", colors.gray)
        y = y + 1
      end
    end
  end

  drawType("BUILDERS", "builder", colors.cyan)
  drawType("GATHERERS", "gatherer", colors.lime)
  drawType("MINERS", "miner", colors.yellow)

  if y < h - 2 then
    y = y + 1
    local ng, nc = 0, 0
    for _ in pairs(gathers) do ng = ng + 1 end
    for _ in pairs(coal) do nc = nc + 1 end
    line(y, ("Posts gather:%d coal:%d builds:%d alerts:%d"):format(
      ng, nc, #listBuilds(), #alerts), colors.lightGray)
  end
  if #alerts > 0 and y < h then
    y = y + 1
    local a = alerts[1]
    line(y, ("!STUCK %s @ %d,%d,%d %s"):format(
      a.name or "?", a.x or 0, a.y or 0, a.z or 0, tostring(a.reason or ""):sub(1, 20)),
      colors.red)
  end
end

--==============================================================================
-- Network handling
--==============================================================================
local function touchBot(id, msg)
  local b = bots[id] or {}
  b.name = msg.name or msg.hostname or b.name
  b.botType = msg.botType or b.botType
  b.x, b.y, b.z = msg.x or b.x, msg.y or b.y, msg.z or b.z
  if msg.yLo ~= nil then b.yLo = msg.yLo end
  if msg.yHi ~= nil then b.yHi = msg.yHi end
  if msg.gpsSpreadY ~= nil then b.gpsSpreadY = msg.gpsSpreadY end
  if msg.gpsN ~= nil then b.gpsN = msg.gpsN end
  if msg.fuel ~= nil then b.fuel = msg.fuel end
  b.state = msg.state or b.state
  b.task = msg.task or b.task
  b.assignment = msg.assignment or msg.task or b.assignment
  if msg.dug ~= nil then b.dug = msg.dug end
  b.seen = now()
  bots[id] = b
  return b
end

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
  if t == MSG.BOT_REGISTER or t == MSG.REGISTER then
    local b = touchBot(id, msg)
    autoPostFromChest(id, msg.chest)
    if not b._announced then
      b._announced = true
      print(("[+] %s registered as %s (#%d)"):format(
        b.name or "?", b.botType or "?", id))
    end

  elseif t == MSG.STATUS then
    touchBot(id, msg)

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
    touchBot(id, msg)
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
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      monitor = peripheral.find("monitor")
      if monitor then monitor.setTextScale(0.5) end
    end
  end
end

local function printBots(filter)
  local n = 0
  for _, id in ipairs(sortedBotIds(filter)) do
    local b = bots[id]
    n = n + 1
    local pos = (b.x and ("%d,%d,%d"):format(b.x, b.y or 0, b.z or 0)) or "?"
    if b.yLo and b.yHi and b.yLo ~= b.yHi then
      pos = pos .. (" Y%.1f..%.1f"):format(b.yLo, b.yHi)
    end
    print(("  #%-3d %-12s %-8s %-8s @%s  %s fuel:%s  %ss"):format(
      id, b.name or "?", b.botType or "?", b.state or "?",
      pos, assignmentOf(id, b):sub(1, 16), tostring(b.fuel or "?"), ago(b.seen)))
  end
  if n == 0 then print("  (none)") end
end

--==============================================================================
-- Console
--==============================================================================
local function consoleLoop()
  print("Bots Computer online (builder / gatherer / miner). Type 'help'.")
  while true do
    write("bots> ")
    local a = {}
    for w in tostring(read()):gmatch("%S+") do a[#a + 1] = w end
    local cmd = (a[1] or ""):lower()

    if cmd == "" then
    elseif cmd == "help" then
      print("bots | builders | gatherers | miners")
      print("gathers | coal | builds | alerts | ping")
      print("scan <bot> <name> <W> <H> <L>")
      print("build <bot> <name> [x y z]")
      print("mine <bot> | stop <bot>")
      print("order <bot> goto <x> <y> <z>")
      print("assign <bot> <text> | unassign <bot>")
      print("exit")
    elseif cmd == "bots" then
      local n = countByType()
      print(("Active %d  build:%d gather:%d mine:%d busy:%d"):format(
        n.total, n.builder, n.gatherer, n.miner, n.busy))
      printBots(nil)
    elseif cmd == "builders" then
      printBots("builder")
    elseif cmd == "gatherers" then
      printBots("gatherer")
    elseif cmd == "miners" then
      printBots("miner")
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
        assigns[id] = "scan " .. a[3]
        print("Scan order sent to " .. a[2])
      else print("Usage: scan <bot> <name> <W> <H> <L>") end
    elseif cmd == "build" then
      local id = findBot(a[2])
      if id and a[3] then
        local x, y, z = tonumber(a[4]), tonumber(a[5]), tonumber(a[6])
        titan.send(id, MSG.BUILD_ORDER, { name = a[3], x = x, y = y, z = z })
        assigns[id] = "build " .. a[3]
        print("Build order sent to " .. a[2])
      else print("Usage: build <bot> <name> [x y z]") end
    elseif cmd == "mine" then
      local id = findBot(a[2])
      if not id then print("Usage: mine <bot>")
      elseif bots[id].botType ~= "miner" then print("That bot is not a miner.")
      else
        titan.send(id, MSG.COMMAND, { cmd = "mine" })
        assigns[id] = "mine volume"
        print("Mine order sent to " .. a[2])
      end
    elseif cmd == "stop" then
      local id = findBot(a[2])
      if id then
        titan.send(id, MSG.COMMAND, { cmd = "stop" })
        print("Stop sent to " .. a[2])
      else print("Usage: stop <bot>") end
    elseif cmd == "order" then
      local id = findBot(a[2])
      if id and (a[3] or ""):lower() == "goto" and a[6] then
        titan.send(id, MSG.COMMAND, { cmd = "goto", x = tonumber(a[4]), y = tonumber(a[5]), z = tonumber(a[6]) })
        assigns[id] = ("goto %s,%s,%s"):format(a[4], a[5], a[6])
      else print("Usage: order <bot> goto <x> <y> <z>") end
    elseif cmd == "assign" then
      local id = findBot(a[2])
      local text = table.concat(a, " ", 3)
      if id and text ~= "" then
        assigns[id] = text
        print(("Assigned #%d: %s"):format(id, text))
      else print("Usage: assign <bot> <text>") end
    elseif cmd == "unassign" then
      local id = findBot(a[2])
      if id then assigns[id] = nil; print("Cleared assignment for " .. a[2])
      else print("Usage: unassign <bot>") end
    elseif cmd == "ping" then
      titan.broadcast(MSG.PING, {}); print("Pinged.")
    elseif cmd == "exit" then
      return
    else
      print("Unknown: " .. cmd)
    end
  end
end

parallel.waitForAny(networkLoop, consoleLoop,
  function() titan.networkLoop("botserver") end)
if monitor then monitor.clear() end
print("Bots Computer stopped.")
