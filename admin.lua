--[[
  admin.lua  -  Titan admin console for a POCKET computer ("Live" tablet)
  Titan-Version: 1.2.1

  Pocket remote for the whole fleet. Keep it on you; it joins the mesh like
  every other Titan device (MAIN router + modem hops).

  Easy ops:
    connections | hosts | list   — who is reachable for SSH
    connect | ssh <id|label>     — remote shell (full device commands)
    bots / miners / loaders / markers
    pending | deploy | park | stop | mine | continue
    dc | center                  — jump to Parent Center
    flatten ...                  — run flatten on Parent Center via SSH
    live                         — full-screen roster

  Starts with a master-password prompt (same floppy as Parent Center). Empty
  password = monitor-only until you run `login`. Deploy / SSH / fleet control
  need an unlocked session.

  Requires: POCKET + wireless modem, lib/titan.lua, mesh in range.
  Run:  admin
]]

local titan = dofile("lib/titan.lua")
local MSG   = titan.MSG

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Admin-" .. os.getComputerID()))

--------------------------------------------------------------------------------
-- Shared live state
--------------------------------------------------------------------------------
local unlocked = false
local bots     = {}   -- [id] = roster row (miners, loaders, workers, markers…)
local systems  = {}   -- [id] = { name, kind, seen } from SSH pongs / hellos
local pois     = {}
local pending  = {}
local stuck    = {}

local function now() return os.epoch("utc") end
local function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end
local function pos(b) return ("%s,%s,%s"):format(b.x or "?", b.y or "?", b.z or "?") end

local function findBot(ref)
  if bots[tonumber(ref) or -1] then return tonumber(ref) end
  local want = tostring(ref or ""):lower()
  if want == "" then return nil end
  for id, b in pairs(bots) do
    if b.name and b.name:lower() == want then return id end
    if b.name and b.name:lower():find(want, 1, true) then return id end
  end
  for id, s in pairs(systems) do
    if s.name and s.name:lower() == want then return id end
  end
  return nil
end

local function touchSystem(id, name, kind)
  local s = systems[id] or {}
  s.name = name or s.name
  s.kind = kind or s.kind
  s.seen = now()
  systems[id] = s
end

--------------------------------------------------------------------------------
-- Network listener
--------------------------------------------------------------------------------
local function handle(id, msg)
  local t = msg.type
  if t == MSG.REGISTER or t == MSG.STATUS or t == MSG.BOT_REGISTER
      or t == MSG.PONG then
    local b = bots[id] or {}
    b.name = msg.botName or msg.label or msg.name or msg.hostname or b.name
    b.botType = msg.botType or msg.kind or b.botType
    b.kind = msg.kind or b.kind or b.botType
    b.x, b.y, b.z = msg.x or b.x, msg.y or b.y, msg.z or b.z
    if msg.fuel ~= nil then b.fuel = msg.fuel end
    b.state = msg.state or msg.status or b.state
    b.task = msg.task or b.task
    b.assignment = msg.assignment or b.assignment or b.task
    b.seen = now()
    bots[id] = b
    touchSystem(id, b.name, b.botType or b.kind)
    if b.botType then pending[id] = nil end

  elseif t == MSG.POI_REGISTER then
    pois[msg.poi or ("poi#" .. id)] = {
      x = msg.x, y = msg.y, z = msg.z, id = id, desc = msg.desc, seen = now() }

  elseif t == MSG.WORKER_AWAIT then
    pending[id] = {
      name = msg.name, kind = msg.kind or "worker",
      x = msg.x, y = msg.y, z = msg.z, seen = now(),
    }
    touchSystem(id, msg.name, msg.kind or "pending")

  elseif t == MSG.WORKER_DEPLOYED then
    pending[id] = nil
    if msg.name or msg.botType then
      local b = bots[id] or {}
      b.name = msg.name or b.name
      b.botType = msg.botType or b.botType
      b.state = "idle"
      b.seen = now()
      bots[id] = b
    end

  elseif t == MSG.STUCK then
    table.insert(stuck, 1, {
      name = msg.name or ("#" .. id), x = msg.x, y = msg.y, z = msg.z,
      reason = msg.reason,
    })
    while #stuck > 15 do table.remove(stuck) end

  elseif t == "hello" or t == "main_here" then
    touchSystem(id, msg.name or msg.hostname or msg.label, msg.kind or "router")
  end
end

local function listenerLoop()
  titan.broadcast(MSG.PING, {})
  while true do
    local id, msg = titan.recv(1)
    if msg then handle(id, msg) end
  end
end

--------------------------------------------------------------------------------
-- Auth
--------------------------------------------------------------------------------
local function tryUnlock(promptLabel)
  if unlocked then return true end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    unlocked = true
    return true
  end
  if titan.login(promptLabel or "Master password") then
    unlocked = true
    print("Unlocked.")
    return true
  end
  return false
end

-- Boot / lock screen: ask for the password immediately (no `login` command first).
-- Empty password keeps monitor-only mode; wrong password retries once more then stays locked.
local function promptUnlockAtStart()
  if unlocked then return end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    unlocked = true
    return
  end
  print("Master password required (Parent Center floppy).")
  print("Empty = monitor-only for now.")
  write("Master password: ")
  local pw = read("*")
  if pw == nil or pw == "" then
    print("Monitor-only. Type 'login' when you want to unlock.")
    return
  end
  if titan.checkPassword(pw) then
    unlocked = true
    print("Unlocked.")
  else
    print("Wrong password (need Parent Center master online).")
    write("Retry (empty = monitor-only): ")
    local pw2 = read("*")
    if pw2 and pw2 ~= "" and titan.checkPassword(pw2) then
      unlocked = true
      print("Unlocked.")
    else
      print("Monitor-only. Type 'login' to try again.")
    end
  end
end

local function requireAuth()
  if unlocked then return true end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    unlocked = true
    return true
  end
  print("Admin action - master password required.")
  if tryUnlock("Master password") then return true end
  print("Denied (need the Parent Center master online + correct password).")
  return false
end

local function needBot(ref)
  local id = findBot(ref)
  if not id then print("Unknown: " .. tostring(ref) .. "  (try bots / connections)") end
  return id
end

--------------------------------------------------------------------------------
-- Connection discovery (SSH-capable hosts on the mesh)
--------------------------------------------------------------------------------
local function listConnections(filter)
  print("Scanning mesh for SSH hosts...")
  local peers = titan.sshListPeers(2.0)
  local filter = tostring(filter or ""):lower()
  local n = 0
  local function match(row)
    if filter == "" then return true end
    local blob = (tostring(row.id) .. " " .. tostring(row.name or "") .. " " .. tostring(row.kind or "")):lower()
    return blob:find(filter, 1, true) ~= nil
  end

  -- Merge ssh peers into systems table
  for _, p in ipairs(peers) do
    touchSystem(p.id, p.name, p.kind)
  end

  print("ID    NAME              KIND         AGE")
  -- Prefer live ssh peers first
  local shown = {}
  for _, p in ipairs(peers) do
    if match(p) then
      n = n + 1
      shown[p.id] = true
      print(("#%-4d %-16s %-12s live"):format(
        p.id, tostring(p.name or "?"):sub(1, 16), tostring(p.kind or "?"):sub(1, 12)))
    end
  end
  -- Also show recently heard fleet members not in ssh list (offline for SSH)
  for id, b in pairs(bots) do
    if not shown[id] and ago(b.seen) < 60 then
      local row = { id = id, name = b.name, kind = b.botType or b.kind or "bot" }
      if match(row) then
        n = n + 1
        print(("#%-4d %-16s %-12s %ss"):format(
          id, tostring(row.name or "?"):sub(1, 16), tostring(row.kind):sub(1, 12), ago(b.seen)))
      end
    end
  end
  if n == 0 then
    print("(none — is MAIN router up? Are devices running networkLoop/SSH?)")
  else
    print(("(%d)  connect <id|name>   or   ssh <id|name>"):format(n))
  end
end

local function findByKind(kind)
  kind = tostring(kind or ""):lower()
  for id, b in pairs(bots) do
    local k = tostring(b.botType or b.kind or ""):lower()
    if k == kind and ago(b.seen) < 45 then return id, b end
  end
  local peers = titan.sshListPeers(1.5)
  for _, p in ipairs(peers) do
    if tostring(p.kind or ""):lower() == kind then return p.id, p end
    local name = tostring(p.name or ""):lower()
    if kind == "datacenter" and (name:find("parent") or name:find("center") or name:find("data")) then
      return p.id, p
    end
  end
  return nil
end

local function printBots(filterType)
  local ids = {}
  for id, b in pairs(bots) do
    if not filterType or b.botType == filterType or b.kind == filterType then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  local n = 0
  for _, id in ipairs(ids) do
    local b = bots[id]
    if ago(b.seen) < 120 then
      n = n + 1
      local asg = tostring(b.assignment or b.task or "-"):sub(1, 14)
      print(("#%-4d %-12s %-8s %-8s %s %s f:%s %ss"):format(
        id, tostring(b.name or "?"):sub(1, 12),
        tostring(b.botType or b.kind or "?"):sub(1, 8),
        tostring(b.state or "?"):sub(1, 8),
        pos(b), asg, tostring(b.fuel or "?"), ago(b.seen)))
    end
  end
  if n == 0 then print("(none)") end
end

--------------------------------------------------------------------------------
-- Live dashboard
--------------------------------------------------------------------------------
local function drawDash()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black); term.clear()
  local function line(y, txt, c)
    term.setCursorPos(1, y)
    if term.setTextColor then term.setTextColor(c or colors.white) end
    term.write(tostring(txt):sub(1, w))
  end

  local total, gath, build, mine, load, mark = 0, 0, 0, 0, 0, 0
  for _, b in pairs(bots) do
    if ago(b.seen) < 20 then
      total = total + 1
      if b.botType == "gatherer" then gath = gath + 1
      elseif b.botType == "builder" then build = build + 1
      elseif b.botType == "miner" then mine = mine + 1
      elseif b.botType == "loader" then load = load + 1
      elseif b.botType == "marker" or b.kind == "marker" then mark = mark + 1 end
    end
  end

  line(1, "== TITAN ADMIN == " .. (unlocked and "UNLOCKED" or "locked"), colors.yellow)
  line(2, ("bots:%d  B:%d G:%d M:%d L:%d site:%d"):format(
    total, build, gath, mine, load, mark), colors.lime)
  line(3, "connect/ssh <id>   connections   dc   help", colors.lightGray)

  local y = 5
  line(y, "ID   NAME         TYPE     STATE    POS", colors.orange); y = y + 1
  local ids = {}
  for id in pairs(bots) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    if y >= h - 1 then break end
    local b = bots[id]
    if ago(b.seen) < 30 then
      line(y, ("#%-3d %-12s %-8s %-8s %s"):format(
        id, tostring(b.name or "?"):sub(1, 12),
        tostring(b.botType or "?"):sub(1, 8),
        tostring(b.state or "?"):sub(1, 8), pos(b)),
        (b.state == "idle" or b.state == "parked") and colors.white or colors.cyan)
      y = y + 1
    end
  end
  local np = 0
  for _, w in pairs(pending) do if ago(w.seen) < 20 then np = np + 1 end end
  if np > 0 and y < h then line(y, ("+%d awaiting deploy"):format(np), colors.orange) end
end

local function liveView()
  local timer = os.startTimer(1)
  drawDash()
  while true do
    local ev, p1 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      drawDash()
      timer = os.startTimer(1)
    elseif ev == "key" or ev == "char" or ev == "mouse_click" or ev == "terminate" then
      term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
      if term.setTextColor then term.setTextColor(colors.white) end
      return
    end
  end
end

--------------------------------------------------------------------------------
-- SSH / connect helper
--------------------------------------------------------------------------------
local function doConnect(a)
  if not a[2] then
    print("Usage: connect <id|label> [command...]")
    print("       ssh <id|label> [command...]")
    print("List targets first:  connections")
    return true
  end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    print("Nested ssh from an SSH session is not supported.")
    return true
  end
  if not requireAuth() then return true end
  local target = a[2]
  local cmdline
  if a[3] then
    local parts = {}
    for i = 3, #a do parts[#parts + 1] = a[i] end
    cmdline = table.concat(parts, " ")
  end
  print(("Connecting to %s ..."):format(target))
  titan.sshConnect(target, cmdline)
  return true
end

local function sshOneShot(target, line)
  if not requireAuth() then return false end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    print("Nested ssh not supported — run that command after `connect`.")
    return false
  end
  titan.sshConnect(target, line)
  return true
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function handleCommand(a)
  local cmd = (a[1] or ""):lower()

  if cmd == "" then
    return true
  elseif cmd == "help" then
    print("VIEW  : live | bots | miners | loaders | markers | pending | stuck")
    print("NET   : connections | hosts | list [filter] | ping | who")
    print("SSH   : connect <id|name> [cmd...]   (alias: ssh)")
    print("BOT   : goto | return | park | refuel | stop | mine | continue")
    print("DEPLOY: deploy <id> <miner|loader|builder|gatherer> [auto] [x y z]")
    print("FLEET : dc | center          jump to Parent Center")
    print("        flatten <args...>    run flatten on Parent Center")
    print("        jobs                 Parent Center job list")
    print("BUILD : scan | build")
    print("login | lock | hostname | exit")

  elseif cmd == "hostname" or cmd == "host" then
    if not a[2] then
      print("hostname: " .. (os.getComputerLabel() or "?"))
    else
      local name, err = titan.setHostname(table.concat(a, " ", 2), "admin")
      if name then print("hostname set: " .. name) else print(tostring(err)) end
    end

  elseif cmd == "live" then
    if titan.sshIsAuthed and titan.sshIsAuthed() then
      print("live view is local-only. Use `bots` / `connections` over SSH.")
    else
      liveView()
    end

  elseif cmd == "connections" or cmd == "hosts" or cmd == "list" then
    listConnections(a[2])

  elseif cmd == "who" or cmd == "find" then
    local ref = a[2]
    if not ref then print("Usage: who <id|name>"); return true end
    local id = findBot(ref) or tonumber(ref)
    if not id then
      print("Scanning...")
      id = titan.sshResolve(ref, 2)
    end
    if not id then print("Not found: " .. tostring(ref)); return true end
    local b, s = bots[id], systems[id]
    print(("#%d  %s"):format(id, (b and b.name) or (s and s.name) or "?"))
    if b then
      print(("  type=%s  state=%s  pos=%s  fuel=%s  asg=%s  %ss"):format(
        tostring(b.botType or b.kind), tostring(b.state), pos(b),
        tostring(b.fuel), tostring(b.assignment or "-"), ago(b.seen)))
    elseif s then
      print(("  kind=%s  %ss"):format(tostring(s.kind), ago(s.seen)))
    end
    print("  connect " .. tostring(id))

  elseif cmd == "bots" then
    printBots(nil)
  elseif cmd == "miners" then
    printBots("miner")
  elseif cmd == "loaders" then
    printBots("loader")
  elseif cmd == "markers" or cmd == "sites" then
    printBots("marker")
  elseif cmd == "builders" then
    printBots("builder")
  elseif cmd == "gatherers" then
    printBots("gatherer")

  elseif cmd == "pois" then
    for name, p in pairs(pois) do
      print(("%s %d,%d,%d %s"):format(name, p.x or 0, p.y or 0, p.z or 0, p.desc or ""))
    end

  elseif cmd == "pending" then
    local n = 0
    for id, w in pairs(pending) do
      if ago(w.seen) < 30 then
        n = n + 1
        print(("#%d %s [%s] @ %s,%s,%s"):format(
          id, w.name or "?", w.kind or "?", w.x or "?", w.y or "?", w.z or "?"))
      end
    end
    if n == 0 then print("(none awaiting deployment)") end

  elseif cmd == "stuck" then
    for i, al in ipairs(stuck) do
      print(("%d) %s @ %d,%d,%d %s"):format(
        i, al.name or "?", al.x or 0, al.y or 0, al.z or 0, al.reason or ""))
    end

  elseif cmd == "ping" then
    titan.broadcast(MSG.PING, {})
    print("Pinged titan_net. Run `connections` for SSH hosts.")

  elseif cmd == "connect" or cmd == "ssh" or cmd == "c" then
    return doConnect(a)

  elseif cmd == "dc" or cmd == "center" or cmd == "datacenter" or cmd == "parent" then
    local id, row = findByKind("datacenter")
    if not id then
      print("Parent Center not found on mesh. Try: connections datacenter")
      print("Or: connect <ParentCenter-name>")
    else
      print(("Parent Center -> #%d %s"):format(id, (row and row.name) or "?"))
      a[2] = tostring(id)
      if a[3] then
        -- dc bots  => connect id bots
        local parts = { "connect", tostring(id) }
        for i = 3, #a do parts[#parts + 1] = a[i] end
        return doConnect(parts)
      end
      return doConnect({ "connect", tostring(id) })
    end

  elseif cmd == "flatten" or cmd == "minejob" then
    local id = findByKind("datacenter")
    if not id then print("No Parent Center found. Use: connections"); return true end
    if not a[2] then
      print("Usage: flatten <x> <z> <W>x<D> <yEnd> [nBots] [yStart] [yband|strip]")
      print("Runs on Parent Center via SSH.")
      return true
    end
    local line = table.concat(a, " ")
    print("Sending to Parent Center #" .. id)
    sshOneShot(tostring(id), line)

  elseif cmd == "jobs" then
    local id = findByKind("datacenter")
    if not id then print("No Parent Center found."); return true end
    sshOneShot(tostring(id), "jobs")

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
    elseif id then print("Usage: goto <bot> <x> <y> <z>") end

  elseif cmd == "return" or cmd == "home" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "return" })
      print("Recalled " .. a[2])
    end

  elseif cmd == "park" or cmd == "tostage" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "park" })
      print("Park/stage " .. a[2])
    end

  elseif cmd == "refuel" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "refuel" })
      print("Refuel " .. a[2])
    end

  elseif cmd == "stop" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "stop" })
      print("Stopped " .. a[2])
    end

  elseif cmd == "mine" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "mine" })
      print("Mine queued on " .. a[2])
    end

  elseif cmd == "continue" or cmd == "resume" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "continue" })
      print("Continue queued on " .. a[2])
    end

  elseif cmd == "deploy" then
    local id = findBot(a[2]) or tonumber(a[2])
    if not id then
      local want = tostring(a[2] or ""):lower()
      for pid, w in pairs(pending) do
        if w.name and w.name:lower() == want then id = pid; break end
      end
    end
    local btype = (a[3] or ""):lower()
    if btype == "mine" then btype = "miner" end
    if btype == "build" then btype = "builder" end
    if btype == "gather" then btype = "gatherer" end
    if btype == "chunk" or btype == "chunky" then btype = "loader" end
    local okType = btype == "builder" or btype == "gatherer"
      or btype == "miner" or btype == "loader"
    -- Name optional — unique Type-<id>
    local coordAt = 4
    if a[4] and tonumber(a[4]) then coordAt = 4
    elseif a[4] and (a[4]:lower() == "auto" or not tonumber(a[4])) then
      coordAt = 5
    end
    local name = titan.uniqueBotName(btype, id)
    if not id then
      print("Unknown worker: " .. tostring(a[2]) .. " (try 'pending')")
    elseif not okType then
      print("Usage: deploy <id> <miner|loader|builder|gatherer> [auto] [x y z]")
      print("Example: deploy 20 miner")
      print("Example: deploy 21 loader")
    elseif requireAuth() then
      local deposit
      if a[coordAt] and a[coordAt + 1] and a[coordAt + 2] then
        deposit = {
          x = tonumber(a[coordAt]), y = tonumber(a[coordAt + 1]), z = tonumber(a[coordAt + 2]),
        }
      end
      local payload = {
        botType = btype, name = name, deposit = deposit,
        storage = deposit, stage = (btype == "loader" or btype == "miner") and deposit or nil,
        cruiseY = 150,
      }
      titan.send(id, MSG.WORKER_DEPLOY, payload)
      print(("Deploy sent to #%d: %s '%s'"):format(id, btype, name))
    end

  elseif cmd == "scan" then
    local id = needBot(a[2])
    if id and a[3] and a[4] and a[5] and a[6] and requireAuth() then
      titan.send(id, MSG.SCAN_ORDER, {
        name = a[3], W = tonumber(a[4]), H = tonumber(a[5]), L = tonumber(a[6]),
      })
      print("Scan order sent.")
    elseif id then print("Usage: scan <bot> <name> <W> <H> <L>") end

  elseif cmd == "build" then
    local id = needBot(a[2])
    if id and a[3] and requireAuth() then
      titan.send(id, MSG.BUILD_ORDER, {
        name = a[3], x = tonumber(a[4]), y = tonumber(a[5]), z = tonumber(a[6]),
      })
      print("Build order sent.")
    elseif id then print("Usage: build <bot> <name> [x y z]") end

  elseif cmd == "login" or cmd == "password" then
    if unlocked then
      print("Already unlocked.")
    else
      promptUnlockAtStart()
    end
  elseif cmd == "lock" or cmd == "logout" then
    unlocked = false
    print("Locked.")
    promptUnlockAtStart()
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    return false
  end
  return true
end

local function consoleLoop()
  term.clear(); term.setCursorPos(1, 1)
  print("== Titan Admin (" .. (os.getComputerLabel() or ("#" .. os.getComputerID())) .. ") ==")
  print("Pocket remote. Type 'help'.")
  print("Quick:  connections   |   connect <name>   |   dc   |   miners")
  promptUnlockAtStart()
  while true do
    write((unlocked and "admin> ") or "titan> ")
    local a = {}
    for w in tostring(read()):gmatch("%S+") do a[#a + 1] = w end
    local r = handleCommand(a)
    if r == "exit" then return
    elseif r == false then
      print("Unknown: " .. tostring(a[1] or "") .. " (type 'help')")
    end
  end
end

titan.setSshHandler(function(line)
  local a = {}
  for w in tostring(line):gmatch("%S+") do a[#a + 1] = w end
  local r = handleCommand(a)
  if r == "exit" then
    print("Over SSH: type `exit` to disconnect (admin keeps running).")
    return true
  end
  if r == false then
    print("Unknown: " .. tostring(a[1] or "") .. " (type 'help')")
  end
  return true
end)

print("Titan admin tablet online.")
-- Network must be up before the password check (talks to Parent Center master).
parallel.waitForAny(
  listenerLoop,
  function() titan.networkLoop("admin") end,
  consoleLoop)
print("Admin console closed.")
