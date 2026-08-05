--[[
  admin.lua  -  Titan admin console for a POCKET computer ("Live" tablet)

  A mobile master terminal you keep on you. It listens to the whole Titan
  network and lets you monitor and command it from your pocket:

    * live roster of bots + builders/gatherers (position, state, fuel, type)
    * points of interest, workers awaiting deployment, and STUCK alerts
    * dispatch / recall / refuel / stop any bot
    * DEPLOY builder/gatherer workers (same push-deploy as the Parent Center)
    * order builder scans / builds

  ADMIN ACTIONS ARE GATED BY THE MASTER PASSWORD. Monitoring is open; anything
  that commands a bot requires `login` (verified against the Parent Center's
  master floppy, exactly like the disk-drive lock). No master online -> denied.

  Requires: a POCKET computer with a WIRELESS MODEM upgrade, `lib/titan.lua`,
  and a GPS constellation (only the bots need GPS; the tablet does not).

  Run:  admin
]]

local titan = dofile("lib/titan.lua")
local MSG   = titan.MSG

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Admin-" .. os.getComputerID()))

--------------------------------------------------------------------------------
-- Shared live state (kept fresh by the listener coroutine)
--------------------------------------------------------------------------------
local unlocked = false
local bots     = {}   -- [id] = { name, botType, x,y,z, fuel, state, task, seen }
local pois     = {}   -- [name] = { x,y,z, id, desc, seen }
local pending  = {}   -- [id] = { name, x,y,z, seen }  workers awaiting deployment
local stuck    = {}   -- newest-first list of alerts

local function now() return os.epoch("utc") end
local function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end
local function pos(b) return ("%s,%s,%s"):format(b.x or "?", b.y or "?", b.z or "?") end

local function findBot(ref)
  if bots[tonumber(ref) or -1] then return tonumber(ref) end
  for id, b in pairs(bots) do
    if b.name and b.name:lower() == tostring(ref):lower() then return id end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Network listener
--------------------------------------------------------------------------------
local function handle(id, msg)
  local t = msg.type
  if t == MSG.REGISTER or t == MSG.STATUS or t == MSG.BOT_REGISTER then
    local b = bots[id] or {}
    b.name    = msg.name or b.name
    b.botType = msg.botType or b.botType
    b.x, b.y, b.z = msg.x or b.x, msg.y or b.y, msg.z or b.z
    if msg.fuel ~= nil then b.fuel = msg.fuel end
    b.state = msg.state or b.state
    b.task  = msg.task or b.task
    b.seen  = now()
    bots[id] = b
    pending[id] = nil

  elseif t == MSG.POI_REGISTER then
    pois[msg.poi or ("poi#" .. id)] = {
      x = msg.x, y = msg.y, z = msg.z, id = id, desc = msg.desc, seen = now() }

  elseif t == MSG.WORKER_AWAIT then
    pending[id] = { name = msg.name, x = msg.x, y = msg.y, z = msg.z, seen = now() }

  elseif t == MSG.WORKER_DEPLOYED then
    pending[id] = nil

  elseif t == MSG.STUCK then
    table.insert(stuck, 1, { name = msg.name or ("#" .. id), x = msg.x, y = msg.y, z = msg.z, reason = msg.reason })
    while #stuck > 15 do table.remove(stuck) end
  end
end

local function listenerLoop()
  titan.broadcast(MSG.PING, {})
  while true do
    local id, msg = titan.recv()
    if msg then handle(id, msg) end
  end
end

--------------------------------------------------------------------------------
-- Auth gate
--------------------------------------------------------------------------------
local function requireAuth()
  if unlocked then return true end
  print("Admin action - master password required.")
  if titan.login("Master password") then unlocked = true; print("Unlocked."); return true end
  print("Denied (need the Parent Center master online + correct password).")
  return false
end

--------------------------------------------------------------------------------
-- Live full-screen dashboard (press any key to exit)
--------------------------------------------------------------------------------
local function drawDash()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black); term.clear()
  local function line(y, txt, c)
    term.setCursorPos(1, y)
    if term.setTextColor then term.setTextColor(c or colors.white) end
    term.write(tostring(txt):sub(1, w))
  end

  local total, gath, build = 0, 0, 0
  for _, b in pairs(bots) do
    if ago(b.seen) < 20 then
      total = total + 1
      if b.botType == "gatherer" then gath = gath + 1
      elseif b.botType == "builder" then build = build + 1 end
    end
  end

  line(1, ("TITAN b:%d g:%d B:%d"):format(total, gath, build), colors.yellow)
  local y = 2
  for id, b in pairs(bots) do
    if y >= h then break end
    if ago(b.seen) < 30 then
      line(y, ("%-8s %-5s %s"):format(
        (b.name or ("#" .. id)):sub(1, 8), (b.state or "?"):sub(1, 5), pos(b)),
        ago(b.seen) > 15 and colors.gray or colors.white)
      y = y + 1
    end
  end

  local np = 0; for _, w2 in pairs(pending) do if ago(w2.seen) < 20 then np = np + 1 end end
  if np > 0 and y < h then line(y, ("+%d awaiting deploy"):format(np), colors.orange); y = y + 1 end

  if #stuck > 0 and y < h then
    line(y, "STUCK:", colors.red); y = y + 1
    for i = 1, #stuck do
      if y >= h then break end
      local a = stuck[i]
      line(y, ("!%s %d,%d,%d"):format((a.name or "?"):sub(1, 8), a.x or 0, a.y or 0, a.z or 0), colors.red)
      y = y + 1
    end
  end
  if y < h then line(y, "[any key: exit]", colors.gray) end
end

local function liveView()
  local timer = os.startTimer(1)
  while true do
    drawDash()
    local ev, p1 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      timer = os.startTimer(1)
    elseif ev == "key" or ev == "char" or ev == "mouse_click" or ev == "terminate" then
      term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
      if term.setTextColor then term.setTextColor(colors.white) end
      return
    end
  end
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function needBot(ref)
  local id = findBot(ref)
  if not id then print("Unknown bot: " .. tostring(ref)) end
  return id
end

local function consoleLoop()
  term.clear(); term.setCursorPos(1, 1)
  print("== Titan Admin (" .. (os.getComputerLabel() or ("#" .. os.getComputerID())) .. ") ==")
  print("Type 'help'. 'login' to unlock admin actions.")
  while true do
    write((unlocked and "admin> ") or "titan> ")
    local a = {}
    for w in tostring(read()):gmatch("%S+") do a[#a + 1] = w end
    local cmd = (a[1] or ""):lower()

    if cmd == "" then
      -- ignore
    elseif cmd == "help" then
      print("VIEW : live | bots | pois | pending | stuck | ping")
      print("BOT  : send <bot> <poi> | goto <bot> <x y z>")
      print("       return <bot> | refuel <bot> | stop <bot>")
      print("DEPLOY: deploy <bot> <builder|gatherer> <name> [x y z]")
      print("BUILD: scan <bot> <name> <W H L> | build <bot> <name> [x y z]")
      print("ssh <id|label> [cmd...]  remote shell (master password)")
      print("login | lock | exit")

    elseif cmd == "live" then
      liveView()

    elseif cmd == "bots" then
      for id, b in pairs(bots) do
        print(("#%d %s [%s] %s %s f:%s %ss"):format(
          id, b.name or "?", b.botType or "-", b.state or "?", pos(b),
          tostring(b.fuel or "?"), ago(b.seen)))
      end

    elseif cmd == "pois" then
      for name, p in pairs(pois) do
        print(("%s %d,%d,%d %s"):format(name, p.x or 0, p.y or 0, p.z or 0, p.desc or ""))
      end

    elseif cmd == "pending" then
      local n = 0
      for id, w in pairs(pending) do
        if ago(w.seen) < 20 then
          n = n + 1
          print(("#%d %s @ %s,%s,%s"):format(id, w.name or "?", w.x or "?", w.y or "?", w.z or "?"))
        end
      end
      if n == 0 then print("(none awaiting deployment)") end

    elseif cmd == "stuck" then
      for i, al in ipairs(stuck) do
        print(("%d) %s @ %d,%d,%d %s"):format(i, al.name or "?", al.x or 0, al.y or 0, al.z or 0, al.reason or ""))
      end

    elseif cmd == "ping" then
      titan.broadcast(MSG.PING, {}); print("Pinged everyone.")

    -- ---- admin-gated control below ----
    elseif cmd == "send" then
      local id, p = needBot(a[2]), pois[a[3] or ""]
      if id and p and requireAuth() then
        titan.send(id, MSG.COMMAND, { cmd = "goto", x = p.x, y = p.y, z = p.z, poi = a[3] })
        print(("-> %s to POI %s"):format(a[2], a[3]))
      elseif id and not p then print("Unknown POI: " .. tostring(a[3])) end

    elseif cmd == "goto" then
      local id = needBot(a[2])
      local x, y, z = tonumber(a[3]), tonumber(a[4]), tonumber(a[5])
      if id and x and y and z and requireAuth() then
        titan.send(id, MSG.COMMAND, { cmd = "goto", x = x, y = y, z = z })
        print(("-> %s to %d,%d,%d"):format(a[2], x, y, z))
      elseif id and not (x and y and z) then print("Usage: goto <bot> <x> <y> <z>") end

    elseif cmd == "return" then
      local id = needBot(a[2])
      if id and requireAuth() then titan.send(id, MSG.COMMAND, { cmd = "return" }); print("Recalled " .. a[2]) end

    elseif cmd == "refuel" then
      local id = needBot(a[2])
      if id and requireAuth() then titan.send(id, MSG.COMMAND, { cmd = "refuel" }); print("Refuel " .. a[2]) end

    elseif cmd == "stop" then
      local id = needBot(a[2])
      if id and requireAuth() then titan.send(id, MSG.COMMAND, { cmd = "stop" }); print("Stopped " .. a[2]) end

    elseif cmd == "deploy" then
      -- resolve silently: a running worker (label/id) or a pending worker (id)
      local id = findBot(a[2]) or tonumber(a[2])
      if id and not bots[id] and not pending[id] then id = nil end
      local btype, name = (a[3] or ""):lower(), a[4]
      if not id then print("Unknown worker: " .. tostring(a[2]) .. " (try 'pending')")
      elseif btype ~= "builder" and btype ~= "gatherer" or not name then
        print("Usage: deploy <bot> <builder|gatherer> <name> [x y z]")
      elseif requireAuth() then
        local deposit
        if a[5] and a[6] and a[7] then
          deposit = { x = tonumber(a[5]), y = tonumber(a[6]), z = tonumber(a[7]) }
        end
        titan.send(id, MSG.WORKER_DEPLOY, { botType = btype, name = name, deposit = deposit })
        print(("Deploy sent to #%d: %s '%s'"):format(id, btype, name))
      end

    elseif cmd == "scan" then
      local id = needBot(a[2])
      if id and a[3] and a[4] and a[5] and a[6] and requireAuth() then
        titan.send(id, MSG.SCAN_ORDER, { name = a[3], W = tonumber(a[4]), H = tonumber(a[5]), L = tonumber(a[6]) })
        print("Scan order sent.")
      elseif id then print("Usage: scan <bot> <name> <W> <H> <L>") end

    elseif cmd == "build" then
      local id = needBot(a[2])
      if id and a[3] and requireAuth() then
        titan.send(id, MSG.BUILD_ORDER, { name = a[3], x = tonumber(a[4]), y = tonumber(a[5]), z = tonumber(a[6]) })
        print("Build order sent.")
      elseif id then print("Usage: build <bot> <name> [x y z]") end

    elseif cmd == "ssh" then
      if not a[2] then
        print("Usage: ssh <id|label> [command...]")
      elseif requireAuth() then
        local target = a[2]
        local cmdline
        if a[3] then
          local parts = {}
          for i = 3, #a do parts[#parts + 1] = a[i] end
          cmdline = table.concat(parts, " ")
        end
        -- Already unlocked locally; still need password on the wire for the host.
        titan.sshConnect(target, cmdline)
      end

    elseif cmd == "login" then
      requireAuth()
    elseif cmd == "lock" or cmd == "logout" then
      unlocked = false; print("Locked.")
    elseif cmd == "exit" or cmd == "quit" then
      return
    else
      print("Unknown: " .. cmd .. " (type 'help')")
    end
  end
end

print("Titan admin tablet online.")
parallel.waitForAny(listenerLoop, consoleLoop,
  function() titan.networkLoop("admin") end)
print("Admin console closed.")
