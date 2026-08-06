--[[
  datacenter.lua  -  Titan Data Center (CC: Tweaked)   [ single, self-contained script ]
  Titan-Version: 1.2.11

  ONE script that every computer/terminal in your data center runs. It works out
  its own role automatically:

    * MASTER  - the computer that has the "master floppy disk" inserted (a floppy
                containing the file `master.pw`). It stores the master password(s)
                and the registry of every station, and it answers login checks.
                `master.pw` may list SEVERAL passwords separated by commas - any
                one of them is accepted (e.g.  alice123,bob456,ops789).
    * STATION - any other computer. It's locked in "bot" mode until a player logs
                in with the master password, after which it becomes an "admin"
                terminal for that session.

  LOGIN FLOW:
    1. A locked station prompts for the master password immediately (no need to
       type `password` / `login` first). Same after `lock` / `logout`.
    2. It reads the interacting player's display name (via an Advanced
       Peripherals Player Detector, if present).
    3. The password is checked against the MASTER password:
         - if THIS computer holds the master floppy -> check locally,
         - else broadcast to find which computer holds it, and ask that master to
           verify the attempt (the real password never travels the network),
         - if NO master is found/online -> always "Wrong password".
    4. On success the station unlocks into the admin terminal for that player.
       On failure you can retry, or use locked helpers (`initmaster`, `help`).

  NAMING & REGISTRY:
    * Each station is named on first run (saved to `station.cfg`) and registers
      itself with the master, which lists every station on its screen/monitor.

  STORAGE:
    * Admin command `storage` / `find <item>` scans attached inventory peripherals
      (chests, barrels, drawers, ME/RS bridges exposed as inventories, ...).

  WORKER / BOT DEPLOYMENT (this is the "Parent Center" role):
    * Manages bot types: builder, gatherer (worker.lua), miner (miner.lua),
      and loader (loader.lua + Chunky Turtle). Unconfigured turtles wait.
    * `deploy <id> <builder|gatherer|miner|loader> [auto] [dep] [stage]`
      ADMIN only. Unique name Type-<id> (player turtle labels ignored).
    * `flatten <x> <z> <W>x<D> <yEnd> [nBots] [yStart] [yband|strip]`
      yband = staggered Y bands (default); strip = X strips. Also accepts
      `site_job` from marker.lua computers.
    * `permit <id|prefix>` / `unpermit` / `permits` — allow breaking Create/etc
      (shown on the master monitor). Create:* is protected by default.

  BOOTSTRAP (first master password):
    * Insert a blank floppy in a master-to-be computer and run `initmaster` from
      the locked screen once. After that, changing it requires an admin login.

  DEPENDENCIES:
    * A wireless modem on every computer (ender modem = unlimited range).
    * OPTIONAL: Advanced Peripherals "Player Detector" next to a station to read
      the interacting player's name. Without it, logins fall back to "operator".
]]

--==============================================================================
-- Constants & state
--==============================================================================
local PROTOCOL     = "titan_dc"
local NET_PROTOCOL = "titan_net"    -- the bot network (bots, botserver, hub share this)
local MASTER_FILE  = "master.pw"    -- presence of this file on a floppy = master
local STATION_CFG  = "station.cfg"
local PLAYER_RANGE = 4              -- blocks: how close a player must be to "interact"

local MSG = {
  WHERE_MASTER = "where_master",   -- anyone -> all : who holds the master floppy?
  MASTER_HERE  = "master_here",    -- master -> asker : "I do"
  AUTH         = "auth",           -- station -> master : verify this password
  AUTH_RESULT  = "auth_result",    -- master -> station : ok = true/false
  REGISTER     = "register",       -- station -> master : my name
  REGISTRY_REQ = "registry_req",   -- station -> master : send me the station list
  REGISTRY     = "registry",       -- master -> station : the station list
  DEVICE_AUTH  = "device_auth",    -- bot/worker -> data server : re-auth after boot/OTA
  AUTH_OK      = "auth_ok",        -- data server -> bot : acknowledged
  PING         = "ping",
  PONG         = "pong",
}

local registry = {}                          -- [id] = { name, seen, master }
local session  = { mode = "bot", user = nil } -- mode: "bot" (locked) | "admin"
local station  = { name = nil }
local monRate  = 2                           -- monitor redraw interval (seconds)
local BOT_TYPES = { builder = true, gatherer = true, miner = true, loader = true }
local netbots  = {}                          -- [id] = { name, botType, x,y,z, fuel, state, task, seen, assignment }
local pending  = {}                          -- [id] = { name, x,y,z, seen, kind } awaiting deployment
local authed   = {}                          -- [id] = { name, kind, hostname, seen } bots authed with this DC
local mineJobs = {}                          -- newest-first job summaries for the monitor
local permits  = {}                          -- [blockId or prefix] = true | expiresUtc
local permitReqs = {}                        -- pending human-visible permit requests
local PERMIT_FILE = "break_permits.cfg"
local nextJobId = 1
local lastSiteJob = { sig = "", at = 0 }  -- de-dupe marker broadcasts

--==============================================================================
-- Small helpers
--==============================================================================
local function trim(s) return (tostring(s):gsub("[\r\n%s]+$", "")) end

local function openModem()
  local found = nil
  for _, side in ipairs(redstone.getSides()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      -- Join the routing mesh so Parent Center traffic can hop via nearby peers.
      pcall(peripheral.call, side, "open", rednet.CHANNEL_REPEAT)
      if not found then found = side end
    end
  end
  if not found then error("No modem attached. Place a (wireless) modem on this computer.", 0) end
  return found
end

-- Mesh repeater (same hop protocol as router.lua / CraftOS `repeat`).
local function relayLoop()
  local REPEAT, relayed = rednet.CHANNEL_REPEAT, {}
  while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
      local side, channel, replyChannel, message = p1, p2, p3, p4
      if channel == REPEAT and type(message) == "table"
         and message.nMessageID and message.nRecipient and not relayed[message.nMessageID] then
        relayed[message.nMessageID] = os.startTimer(30)
        for _, s in ipairs(redstone.getSides()) do
          if peripheral.getType(s) == "modem" and rednet.isOpen(s) then
            peripheral.call(s, "transmit", REPEAT, replyChannel, message)
            if message.nRecipient ~= REPEAT then
              peripheral.call(s, "transmit", message.nRecipient, replyChannel, message)
            end
          end
        end
      end
    elseif event == "timer" then
      for mid, timer in pairs(relayed) do
        if timer == p1 then relayed[mid] = nil; break end
      end
    end
  end
end

local function loadConfig()
  if not fs.exists(STATION_CFG) then return nil end
  local f = fs.open(STATION_CFG, "r")
  local data = textutils.unserialize(f.readAll())
  f.close()
  return data
end

-- Merge-write so monRate / other prefs survive rename.
local function saveConfig(cfg)
  local cur = loadConfig() or {}
  if type(cfg) == "table" then
    for k, v in pairs(cfg) do cur[k] = v end
  end
  local f = fs.open(STATION_CFG, "w")
  f.write(textutils.serialize(cur))
  f.close()
end

local function clampMonRate(secs)
  local n = tonumber(secs)
  if not n or n ~= n then return monRate end
  if n < 0.25 then n = 0.25 end
  if n > 120 then n = 120 end
  return n
end

--==============================================================================
-- Master floppy handling
--==============================================================================

-- Return drive-name, mount-path for the LOCAL master floppy (has MASTER_FILE), or nil.
local function findMasterDrive()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
      local d = peripheral.wrap(name)
      if d.isDiskPresent() and d.getMountPath() then
        local path = d.getMountPath()
        if fs.exists(fs.combine(path, MASTER_FILE)) then
          return name, path
        end
      end
    end
  end
  return nil
end

-- Return drive-name, mount-path for ANY local floppy with a filesystem (used by initmaster).
local function findAnyDrive()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
      local d = peripheral.wrap(name)
      if d.isDiskPresent() and d.getMountPath() then
        return name, d.getMountPath()
      end
    end
  end
  return nil
end

local function readMasterPassword(path)
  local file = fs.combine(path, MASTER_FILE)
  if not fs.exists(file) then return nil end
  local f = fs.open(file, "r")
  local pw = f.readAll()
  f.close()
  return trim(pw)
end

-- master.pw may hold SEVERAL passwords separated by commas; any one is valid.
-- Each entry is trimmed of surrounding whitespace; empty entries are ignored,
-- and an empty attempt never matches.
local function passwordMatches(stored, attempt)
  if not stored or attempt == nil or attempt == "" then return false end
  for candidate in tostring(stored):gmatch("[^,]+") do
    candidate = candidate:gsub("^%s+", ""):gsub("%s+$", "")
    if candidate ~= "" and candidate == attempt then return true end
  end
  return false
end

local function isLocalMaster() return findMasterDrive() ~= nil end

--==============================================================================
-- Player detection (Advanced Peripherals - Player Detector)
--==============================================================================
local function getInteractingPlayer()
  local pd = peripheral.find("playerDetector")
  if not pd then return nil end
  -- Nearest players first (block-centric). Different AP versions expose different names.
  local ok, players = pcall(function() return pd.getPlayersInRange(PLAYER_RANGE) end)
  if ok and type(players) == "table" and #players > 0 then return players[1] end
  local ok2, online = pcall(function() return pd.getOnlinePlayers() end)
  if ok2 and type(online) == "table" and #online > 0 then return online[1] end
  return nil
end

--==============================================================================
-- Networking: master discovery, auth, registry
--==============================================================================

-- Wait for a specific message type until a deadline. Returns senderId, msg or nil.
local function awaitType(wantType, timeout, fromId)
  local deadline = os.clock() + timeout
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then return nil end
    local id, msg = rednet.receive(PROTOCOL, remaining)
    if type(msg) == "table" and msg.type == wantType and (not fromId or id == fromId) then
      return id, msg
    end
    if id == nil then return nil end   -- timed out
  end
end

-- Find the id of the computer holding the master floppy (nil if none online).
local function discoverMaster(timeout)
  rednet.broadcast({ type = MSG.WHERE_MASTER }, PROTOCOL)
  local id = awaitType(MSG.MASTER_HERE, timeout or 2)
  return id
end

-- Validate a password attempt. Returns true/false. Never true when no master exists.
local function validatePassword(pw)
  -- Case 1: we ARE the master -> check locally.
  local _, path = findMasterDrive()
  if path then
    local stored = readMasterPassword(path)
    return passwordMatches(stored, pw)
  end
  -- Case 2: find the master over the network and ask it to verify.
  local masterId = discoverMaster(2)
  if not masterId then return false end        -- no master online -> "wrong password"
  rednet.send(masterId, { type = MSG.AUTH, password = pw }, PROTOCOL)
  local _, resp = awaitType(MSG.AUTH_RESULT, 3, masterId)
  return resp ~= nil and resp.ok == true
end

-- Get the station registry (local table if master, else request it from the master).
local function getRegistry()
  if isLocalMaster() then return registry end
  local masterId = discoverMaster(2)
  if not masterId then return nil end
  rednet.send(masterId, { type = MSG.REGISTRY_REQ }, PROTOCOL)
  local _, resp = awaitType(MSG.REGISTRY, 3, masterId)
  return resp and resp.registry or nil
end

--==============================================================================
-- Commands
--==============================================================================

local function attemptLogin()
  local player = getInteractingPlayer()
  if player then
    print("Player at terminal: " .. player)
  else
    player = "operator"
    print("No Player Detector nearby - session user = 'operator'.")
  end
  write("Master password: ")
  local pw = read("*")
  if validatePassword(pw) then
    session.mode = "admin"
    session.user = player
    print("")
    print("Access granted. Welcome, " .. player .. ".")
    sleep(1)
  else
    print("Wrong password.")
    sleep(1.2)
  end
end

-- First-time bootstrap of a master floppy (allowed while locked, only if unset).
local function cmdInitMaster()
  local _, path = findAnyDrive()
  if not path then
    print("Insert a blank floppy disk to store the master password.")
    return
  end
  if fs.exists(fs.combine(path, MASTER_FILE)) then
    local existing = readMasterPassword(path)
    if existing and existing ~= "" then
      print("This floppy is already a master. Log in and use 'setmaster' to change it.")
      return
    end
  end
  print("(Tip: enter several passwords comma-separated to allow more than one.)")
  write("Set NEW master password: ")
  local a = read("*")
  write("Confirm password:      ")
  local b = read("*")
  if a ~= b or a == "" then print("Passwords empty or did not match."); return end
  local f = fs.open(fs.combine(path, MASTER_FILE), "w")
  f.write(a)
  f.close()
  print("Master password written to the floppy. This computer is now the MASTER.")
  sleep(1.5)
end

-- Change the master password (admin only, must hold the floppy locally).
local function cmdSetMaster()
  local _, path = findMasterDrive()
  if not path then
    print("Only the computer holding the master floppy can change the password.")
    return
  end
  print("(Tip: comma-separate several passwords to allow more than one.)")
  write("New master password: ")
  local a = read("*")
  write("Confirm password:    ")
  local b = read("*")
  if a ~= b or a == "" then print("Passwords empty or did not match."); return end
  local f = fs.open(fs.combine(path, MASTER_FILE), "w")
  f.write(a)
  f.close()
  print("Master password updated.")
end

local function cmdStations()
  local reg = getRegistry()
  if not reg then print("No master online - station list unavailable."); return end
  print("Registered stations:")
  local count = 0
  for id, s in pairs(reg) do
    count = count + 1
    local age = s.seen and math.floor((os.epoch("utc") - s.seen) / 1000) or "?"
    print(("  #%-3d %-16s %s%ss ago"):format(
      id, s.name or "?", s.master and "[MASTER] " or "", tostring(age)))
  end
  if count == 0 then print("  (none yet)") end
end

local function cmdStorage(filter)
  local invs = { peripheral.find("inventory") }
  if #invs == 0 then print("No storage (inventory) peripherals attached."); return end
  local totals = {}
  for _, inv in ipairs(invs) do
    local ok, list = pcall(inv.list)
    if ok and list then
      for _, item in pairs(list) do
        totals[item.name] = (totals[item.name] or 0) + item.count
      end
    end
  end
  -- Sort by count desc.
  local rows = {}
  for name, count in pairs(totals) do
    if not filter or name:lower():find(filter:lower(), 1, true) then
      rows[#rows + 1] = { name = name, count = count }
    end
  end
  table.sort(rows, function(a, b) return a.count > b.count end)
  print(("Storage across %d inventories:"):format(#invs))
  if #rows == 0 then print("  (no matching items)"); return end
  for i = 1, math.min(#rows, 20) do
    print(("  %6d  %s"):format(rows[i].count, rows[i].name))
  end
  if #rows > 20 then print(("  ...and %d more item types"):format(#rows - 20)) end
end

local function cmdScan()
  print("Scanning network...")
  rednet.broadcast({ type = MSG.PING }, PROTOCOL)
  rednet.broadcast({ type = MSG.WHERE_MASTER }, PROTOCOL)
  local seen, masters = {}, {}
  local deadline = os.clock() + 2
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTOCOL, deadline - os.clock())
    if type(msg) == "table" and id then
      if msg.type == MSG.PONG then seen[id] = msg.name or ("#" .. id) end
      if msg.type == MSG.MASTER_HERE then masters[id] = msg.label or ("#" .. id) end
    end
  end
  print("Computers online:")
  for id, name in pairs(seen) do print(("  #%-3d %s"):format(id, name)) end
  if isLocalMaster() then print(("  #%-3d %s [THIS - MASTER]"):format(os.getComputerID(), station.name)) end
  print("Master floppy holders:")
  local any = false
  for id, label in pairs(masters) do any = true; print(("  #%-3d %s"):format(id, label)) end
  if isLocalMaster() then any = true; print(("  #%-3d %s [THIS]"):format(os.getComputerID(), station.name)) end
  if not any then print("  (none - logins will be denied)") end
end

local function cmdRename(newName)
  if not newName or newName == "" then print("Usage: rename <new name>  (or: hostname <new name)"); return end
  station.name = newName
  saveConfig({ name = newName })
  os.setComputerLabel(newName)
  -- Re-register immediately with Parent Center master + network router.
  if isLocalMaster() then
    registry[os.getComputerID()] = { name = newName, seen = os.epoch("utc"), master = true }
  else
    local mId = discoverMaster(1)
    if mId then rednet.send(mId, { type = MSG.REGISTER, name = newName }, PROTOCOL) end
  end
  rednet.broadcast({
    type = "hello", kind = "datacenter", name = newName, hostname = newName,
  }, "titan_router")
  print("hostname set: " .. newName)
end

local function printStatus()
  print("Station : " .. tostring(station.name) .. "  (#" .. os.getComputerID() .. ")")
  print("Role    : " .. (isLocalMaster() and "MASTER (holds floppy)" or "station"))
  print("Mode    : " .. session.mode .. (session.user and ("  user=" .. session.user) or ""))
  local m = isLocalMaster() and "this computer" or (discoverMaster(1) and "online" or "NONE")
  print("Master  : " .. m)
end

--==============================================================================
-- Worker deployment (admin only -> gated behind the disk-drive password lock)
--==============================================================================

-- List turtles that are powered on but unconfigured (awaiting deploy).
local function cmdPending()
  local nowMs, count = os.epoch("utc"), 0
  print("Bots awaiting deployment (builder / gatherer / miner):")
  for id, w in pairs(pending) do
    if (nowMs - (w.seen or 0)) < 20000 then
      count = count + 1
      local age = math.floor((nowMs - (w.seen or 0)) / 1000)
      local pos = w.x and ("%d,%d,%d"):format(w.x, w.y, w.z) or "?"
      local kind = w.kind or "worker"
      print(("  #%-3d %-10s %-14s @ %-14s (%ss)"):format(
        id, kind, w.name or "?", pos, age))
    end
  end
  if count == 0 then
    print("  (none — boot worker.lua or miner.lua with no deploy name)")
  end
end

-- Push deploy config:
--   deploy <id> <builder|gatherer|miner|loader> [auto|<ignoredName>] [depX depY depZ] [stage...]
-- Names are always unique Type-<computerId> (player labels ignored).
local function cmdDeploy(rest)
  local a = {}
  for w in tostring(rest):gmatch("%S+") do a[#a + 1] = w end
  local ref, btype = a[1], (a[2] or ""):lower()
  -- Aliases
  if btype == "mine" then btype = "miner" end
  if btype == "build" then btype = "builder" end
  if btype == "gather" then btype = "gatherer" end
  if btype == "chunk" or btype == "chunky" then btype = "loader" end

  if not ref or not btype or btype == "" then
    print("Usage: deploy <id|name> <builder|gatherer|miner|loader> [auto] [depX depY depZ] [stageX stageY stageZ]")
    print("Example: deploy 12 miner")
    print("Example: deploy 12 builder auto 100 64 200")
    print("Names are always unique (Builder-12, Miner-12) — player turtle labels are ignored.")
    return
  end
  if not BOT_TYPES[btype] then
    print(("Unknown type '%s'. Use: builder, gatherer, miner, or loader"):format(tostring(a[2] or "")))
    return
  end

  local targetId = tonumber(ref)
  if not targetId then
    for id, w in pairs(pending) do
      if w.name and w.name:lower() == ref:lower() then targetId = id; break end
    end
  end
  if not targetId then print("No pending bot '" .. ref .. "' (try 'pending')."); return end

  local pend = pending[targetId]
  if pend and pend.kind then
    local k = tostring(pend.kind):lower()
    if btype == "miner" and (k == "worker" or k == "worker?") then
      print("Note: that turtle is running worker.lua — it will hand off to miner.lua if installed.")
    elseif btype == "loader" and k ~= "loader" then
      print("Note: install/run loader.lua on that turtle (Chunky Turtle upgrade recommended).")
    elseif (btype == "builder" or btype == "gatherer") and k == "miner" then
      print("Note: that turtle is running miner.lua — install/run worker.lua for builder/gatherer.")
    end
  end

  -- Optional name token is ignored for uniqueness; coords may start at a[3] or a[4].
  local coordAt = 3
  if a[3] and not tonumber(a[3]) then
    coordAt = 4  -- skip auto/custom name token
  end
  local prefixes = {
    builder = "Builder", gatherer = "Gatherer", miner = "Miner", loader = "Loader",
  }
  local name = (prefixes[btype] or "Bot") .. "-" .. tostring(targetId)

  local deposit, stage
  if a[coordAt] and a[coordAt + 1] and a[coordAt + 2] then
    local p = {
      x = tonumber(a[coordAt]), y = tonumber(a[coordAt + 1]), z = tonumber(a[coordAt + 2]),
    }
    if p.x and p.y and p.z then
      if btype == "loader" then stage = p else deposit = p end
    end
  end
  if a[coordAt + 3] and a[coordAt + 4] and a[coordAt + 5] then
    stage = {
      x = tonumber(a[coordAt + 3]), y = tonumber(a[coordAt + 4]), z = tonumber(a[coordAt + 5]),
    }
  end

  rednet.send(targetId,
    { type = "worker_deploy", botType = btype, name = name, deposit = deposit,
      storage = deposit, stage = stage, cruiseY = 150 }, NET_PROTOCOL)
  local extra = ""
  if deposit then
    extra = extra .. ("  deposit %d,%d,%d"):format(deposit.x, deposit.y, deposit.z)
  end
  if stage then
    extra = extra .. ("  stage %d,%d,%d"):format(stage.x, stage.y, stage.z)
  end
  print(("Deploy sent to #%d: %s '%s'%s"):format(targetId, btype, name, extra))
  local deadline = os.clock() + 8
  while os.clock() < deadline do
    local id, msg = rednet.receive(NET_PROTOCOL, deadline - os.clock())
    if id == targetId and type(msg) == "table" and msg.type == "worker_deployed" then
      if msg.ok == false then
        print("Bot rejected: " .. tostring(msg.err))
        if tostring(msg.err or ""):find("miner%.lua") then
          print("Tip: install miner.lua on that turtle (installer option / host copy), then redeploy.")
        end
      else
        print(("Deployed: %s is now a %s."):format(msg.name or ("#" .. id), msg.botType or btype))
        if msg.handoff then
          print("(Turtle is switching to miner.lua and rebooting.)")
        end
        netbots[targetId] = netbots[targetId] or {}
        netbots[targetId].name = msg.name or name
        netbots[targetId].botType = msg.botType or btype
        netbots[targetId].state = "idle"
        netbots[targetId].task = "-"
        netbots[targetId].assignment = "-"
        netbots[targetId].seen = os.epoch("utc")
      end
      pending[targetId] = nil
      return
    end
  end
  print("(No confirmation yet - the bot may still be calibrating / rebooting into miner.lua.)")
end

--------------------------------------------------------------------------------
-- Break permits (Create / trains protected unless listed)
--------------------------------------------------------------------------------
local function loadPermits()
  if not fs.exists(PERMIT_FILE) then return end
  local f = fs.open(PERMIT_FILE, "r")
  local d = textutils.unserialize(f.readAll()); f.close()
  if type(d) == "table" then permits = d end
end

local function savePermits()
  local f = fs.open(PERMIT_FILE, "w"); f.write(textutils.serialize(permits)); f.close()
end

local function broadcastPermits()
  rednet.broadcast({ type = "permit_sync", permits = permits }, NET_PROTOCOL)
end

local function cmdPermits()
  print("Break permits (Create/rails protected unless listed):")
  local n = 0
  for k, v in pairs(permits) do
    n = n + 1
    if v == true then print("  " .. k)
    else print(("  %s  (until %s)"):format(k, tostring(v))) end
  end
  if n == 0 then print("  (none)") end
  if #permitReqs > 0 then
    print("Open requests:")
    for i, r in ipairs(permitReqs) do
      print(("  %d) %s  from %s"):format(i, r.key, tostring(r.from or "?")))
    end
  end
end

local function cmdPermit(rest)
  local key = tostring(rest or ""):match("^%s*(%S+)")
  if not key then
    print("Usage: permit <blockId|prefix:>")
    print("Example: permit create:  OR  permit create:track")
    return
  end
  if key == "create" then key = "create:" end
  permits[key] = true
  savePermits()
  broadcastPermits()
  print("Permitted break: " .. key)
  -- clear matching requests
  local kept = {}
  for _, r in ipairs(permitReqs) do
    if r.key ~= key then kept[#kept + 1] = r end
  end
  permitReqs = kept
end

local function cmdUnpermit(rest)
  local key = tostring(rest or ""):match("^%s*(%S+)")
  if not key then print("Usage: unpermit <blockId|prefix:>"); return end
  if key == "create" then key = "create:" end
  permits[key] = nil
  savePermits()
  broadcastPermits()
  print("Revoked: " .. key)
end

--------------------------------------------------------------------------------
-- Fleet flatten / mine jobs
--------------------------------------------------------------------------------
local function isIdleState(st)
  st = tostring(st or ""):lower()
  -- Miners historically sent `status` while DC read `state` — treat empty as idle
  -- once the bot is known and freshly seen.
  return st == "" or st == "nil" or st == "idle" or st == "authed"
    or st == "online" or st == "-" or st == "parked"
end

local function idleOfType(botType)
  local nowMs, list = os.epoch("utc"), {}
  for id, b in pairs(netbots) do
    if b.botType == botType and (nowMs - (b.seen or 0)) < 20000 then
      if isIdleState(b.state) then
        -- Fleet job ids look like J12-3; keep those busy until they finish.
        local asg = tostring(b.assignment or "")
        if not asg:match("^J%d") then
          list[#list + 1] = id
        end
      end
    end
  end
  table.sort(list)
  return list
end

local function idleMiners() return idleOfType("miner") end
local function idleLoaders() return idleOfType("loader") end

local function rosterHint(botType)
  local nowMs, lines, n = os.epoch("utc"), {}, 0
  for id, b in pairs(netbots) do
    if b.botType == botType then
      n = n + 1
      local age = math.floor((nowMs - (b.seen or 0)) / 1000)
      lines[#lines + 1] = ("#%d %s state=%s asg=%s %ds"):format(
        id, tostring(b.name or "?"), tostring(b.state or "?"),
        tostring(b.assignment or "-"):sub(1, 12), age)
    end
  end
  if n == 0 then
    return "none on roster — miners must be deployed and in modem range of the mesh"
  end
  return table.concat(lines, " | ")
end

-- Split XZ box into up to n vertical strips (along X).
local function splitStrips(x, z, w, d, n)
  n = math.max(1, math.min(n, w))
  local strips, base, rem = {}, math.floor(w / n), w % n
  local cursor = x
  for i = 1, n do
    local sw = base + (i <= rem and 1 or 0)
    if sw < 1 then break end
    strips[#strips + 1] = {
      x1 = cursor, z1 = z,
      x2 = cursor + sw - 1, z2 = z + d - 1,
    }
    cursor = cursor + sw
  end
  return strips
end

-- Split vertical range into n contiguous Y bands (top -> bottom). Staggers miners
-- so they are not all chewing the same layer at once.
local function splitYBands(yTop, yEnd, n)
  yTop, yEnd = math.floor(yTop), math.floor(yEnd)
  if yEnd > yTop then yTop, yEnd = yEnd, yTop end
  local height = yTop - yEnd + 1
  n = math.max(1, math.min(n, height))
  local bands, base, rem = {}, math.floor(height / n), height % n
  local cursor = yTop
  for i = 1, n do
    local h = base + (i <= rem and 1 or 0)
    if h < 1 then break end
    local ys, ye = cursor, cursor - h + 1
    bands[#bands + 1] = { yStart = ys, yEnd = ye }
    cursor = ye - 1
  end
  return bands
end

-- Core fleet dispatch used by flatten + site markers.
-- opts: yStart, mode ("yband"|"strip"), cruiseY, returnStage, source, name, replyTo
local function dispatchAreaJobs(x, z, w, d, yEnd, nBots, opts)
  opts = opts or {}
  local yStart = tonumber(opts.yStart)
  local mode = tostring(opts.mode or "yband"):lower()
  if mode == "xz" or mode == "x" then mode = "strip" end
  if mode == "y" or mode == "layer" or mode == "layers" then mode = "yband" end
  local cruiseY = tonumber(opts.cruiseY) or 150
  local returnStage = opts.returnStage ~= false

  local idle = idleMiners()
  if #idle == 0 then
    return false, "No idle miners online. Roster: " .. rosterHint("miner")
  end

  x, z, w, d, yEnd = math.floor(x), math.floor(z), math.floor(w), math.floor(d), math.floor(yEnd)
  if not yStart then
    -- Default top = max(nearby miner Y, yEnd+1) — marker should send yStart.
    yStart = yEnd + math.max(1, math.min(64, d))
  end
  yStart = math.floor(yStart)
  if yEnd > yStart then yStart, yEnd = yEnd, yStart end

  if mode == "strip" then
    nBots = nBots or math.min(#idle, math.max(1, math.ceil(w / 5)))
    nBots = math.min(nBots, #idle, w)
  else
    local height = yStart - yEnd + 1
    nBots = nBots or math.min(#idle, math.max(1, math.min(height, math.ceil(height / 8))))
    nBots = math.min(nBots, #idle, height)
    mode = "yband"
  end

  local jobId = "J" .. tostring(nextJobId)
  nextJobId = nextJobId + 1
  local pieces = {}
  if mode == "strip" then
    local strips = splitStrips(x, z, w, d, nBots)
    for i, s in ipairs(strips) do
      pieces[#pieces + 1] = {
        x1 = s.x1, z1 = s.z1, x2 = s.x2, z2 = s.z2,
        yStart = yStart, yEnd = yEnd,
        -- Stagger approach/start so strip bots don't all land on the same Y tick.
        approachY = yStart - (i - 1),
        label = ("X[%d..%d] Z[%d..%d] Y[%d->%d]"):format(
          s.x1, s.x2, s.z1, s.z2, yStart, yEnd),
      }
    end
  else
    local bands = splitYBands(yStart, yEnd, nBots)
    local x2, z2 = x + w - 1, z + d - 1
    for i, b in ipairs(bands) do
      pieces[#pieces + 1] = {
        x1 = x, z1 = z, x2 = x2, z2 = z2,
        yStart = b.yStart, yEnd = b.yEnd,
        approachY = b.yStart,
        label = ("XZ full  Y[%d->%d]"):format(b.yStart, b.yEnd),
      }
    end
  end

  print(("Job %s [%s]: %dx%d @ %d,%d  Y%d->%d  %d miners%s"):format(
    jobId, mode, w, d, x, z, yStart, yEnd, #pieces,
    opts.name and ("  (" .. opts.name .. ")") or ""))

  local loaders = idleLoaders()
  for i, piece in ipairs(pieces) do
    local id = idle[i]
    local payload = {
      type = "mine_job",
      jobId = jobId .. "-" .. i,
      parentJob = jobId,
      x1 = piece.x1, z1 = piece.z1, x2 = piece.x2, z2 = piece.z2,
      yStart = piece.yStart, yEnd = piece.yEnd,
      approachY = piece.approachY,
      cruiseY = cruiseY, returnStage = returnStage,
      mode = mode,
    }
    rednet.send(id, payload, NET_PROTOCOL)
    netbots[id] = netbots[id] or {}
    netbots[id].assignment = payload.jobId
    netbots[id].task = mode
    netbots[id].state = "queued"
    print(("  -> miner #%d %s  %s"):format(
      id, netbots[id].name or "?", piece.label))
    local lid = loaders[i]
    if lid then
      local midX = math.floor((piece.x1 + piece.x2) / 2)
      local midZ = math.floor((piece.z1 + piece.z2) / 2)
      rednet.send(lid, {
        type = "loader_assign",
        jobId = payload.jobId,
        minerId = id,
        followGap = 2,   -- stay 2 blocks from miner (don't block digging)
        x = midX, y = piece.approachY or cruiseY, z = midZ,
        x1 = piece.x1, z1 = piece.z1, x2 = piece.x2, z2 = piece.z2,
        cruiseY = cruiseY, returnStage = true,
      }, NET_PROTOCOL)
      netbots[lid] = netbots[lid] or {}
      netbots[lid].assignment = payload.jobId
      netbots[lid].task = "escort"
      netbots[lid].state = "queued"
      print(("  -> loader #%d escort"):format(lid))
    end
  end
  if #loaders < #pieces then
    print(("Note: %d loader(s) for %d piece(s). Chunky Turtle recommended."):format(
      #loaders, #pieces))
  end

  table.insert(mineJobs, 1, {
    id = jobId, x = x, z = z, w = w, d = d,
    yStart = yStart, yEnd = yEnd, mode = mode,
    bots = #pieces, loaders = math.min(#loaders, #pieces),
    source = opts.source or "admin", name = opts.name,
    at = os.epoch("utc"), status = "dispatched",
  })
  while #mineJobs > 12 do mineJobs[#mineJobs] = nil end

  if opts.replyTo then
    rednet.send(opts.replyTo, {
      type = "site_job_ack", ok = true, jobId = jobId,
      bots = #pieces, mode = mode, yStart = yStart, yEnd = yEnd,
    }, NET_PROTOCOL)
  end
  return true, jobId, #pieces
end

-- flatten <x> <z> <W>x<D> <yEnd> [nBots] [yStart] [mode]
local function cmdFlatten(rest)
  local a = {}
  for w in tostring(rest or ""):gmatch("%S+") do a[#a + 1] = w end
  local x, z = tonumber(a[1]), tonumber(a[2])
  local w, d, yEnd, nBots, yStart, mode
  if a[3] and a[3]:find("[xX]") then
    w, d = a[3]:match("^(%d+)[xX](%d+)$")
    w, d = tonumber(w), tonumber(d)
    yEnd = tonumber(a[4])
    nBots = tonumber(a[5])
    yStart = tonumber(a[6])
    mode = a[7]
  else
    w, d, yEnd, nBots = tonumber(a[3]), tonumber(a[4]), tonumber(a[5]), tonumber(a[6])
    yStart = tonumber(a[7])
    mode = a[8]
  end
  if not (x and z and w and d and yEnd) then
    print("Usage: flatten <x> <z> <W>x<D> <yEnd> [nBots] [yStart] [yband|strip]")
    print("Example: flatten 100 200 40x40 -59 8 80 yband")
    print("  yband = each bot owns a Y band (staggered layers, default)")
    print("  strip = each bot owns an X strip (full height)")
    return
  end
  local ok, err = dispatchAreaJobs(x, z, w, d, yEnd, nBots, {
    yStart = yStart, mode = mode or "yband", source = "flatten",
  })
  if not ok then print(tostring(err)) end
end

local function handleSiteJob(id, msg)
  local x1, z1 = tonumber(msg.x1), tonumber(msg.z1)
  local x2, z2 = tonumber(msg.x2), tonumber(msg.z2)
  local yEnd = tonumber(msg.yEnd or msg.y)
  local yStart = tonumber(msg.yStart or msg.yTop)
  if not (x1 and z1 and x2 and z2 and yEnd and yStart) then
    rednet.send(id, { type = "site_job_ack", ok = false, err = "need x1,z1,x2,z2,yStart,yEnd" }, NET_PROTOCOL)
    return
  end
  local minX, maxX = math.min(x1, x2), math.max(x1, x2)
  local minZ, maxZ = math.min(z1, z2), math.max(z1, z2)
  local w, d = maxX - minX + 1, maxZ - minZ + 1
  local ok, errOrId, n = dispatchAreaJobs(minX, minZ, w, d, yEnd, tonumber(msg.nBots), {
    yStart = yStart,
    mode = msg.mode or "yband",
    cruiseY = msg.cruiseY,
    returnStage = msg.returnStage ~= false,
    source = "marker",
    name = msg.name or msg.site,
    replyTo = id,
  })
  if not ok then
    rednet.send(id, { type = "site_job_ack", ok = false, err = errOrId }, NET_PROTOCOL)
  end
end

local function botStats()
  local nowMs, total, gath, build, mine, load, working = os.epoch("utc"), 0, 0, 0, 0, 0, 0
  for _, b in pairs(netbots) do
    if (nowMs - (b.seen or 0)) < 15000 then
      total = total + 1
      if b.botType == "gatherer" then gath = gath + 1
      elseif b.botType == "builder" then build = build + 1
      elseif b.botType == "miner" then mine = mine + 1
      elseif b.botType == "loader" then load = load + 1 end
      if b.state == "moving" or b.state == "working" or b.state == "mining"
          or b.state == "escorting" or b.state == "queued" then
        working = working + 1
      end
    end
  end
  return total, gath, build, mine, load, working
end

--==============================================================================
-- Command handlers
--==============================================================================
local function handleLocked(cmd, rest)
  if cmd == "password" or cmd == "login" then
    attemptLogin()
  elseif cmd == "initmaster" then
    cmdInitMaster()
  elseif cmd == "whoami" then
    print("Player at terminal: " .. (getInteractingPlayer() or "none (need Player Detector)"))
  elseif cmd == "status" then
    printStatus()
  elseif cmd == "help" then
    print("Locked terminal. Commands:")
    print("  password|login  prompt for the master password")
    print("  whoami          show the interacting player")
    print("  status          show this station's status")
    print("  initmaster      set master password on a blank floppy (first-time only)")
  elseif cmd == "" then
    -- ignore (empty returns to the password prompt)
  else
    print("Locked. Enter the password at the prompt, or: password | initmaster | help")
  end
end

local function handleAdmin(cmd, rest)
  if cmd == "stations" or cmd == "list" then
    cmdStations()
  elseif cmd == "storage" then
    cmdStorage(nil)
  elseif cmd == "find" then
    cmdStorage(rest)
  elseif cmd == "scan" then
    cmdScan()
  elseif cmd == "bots" then
    local total, gath, build, mine, load, working = botStats()
    print(("Bots active: %d  (build:%d gather:%d mine:%d load:%d busy:%d)"):format(
      total, build, gath, mine, load, working))
    local nowMs = os.epoch("utc")
    for id, b in pairs(netbots) do
      local age = math.floor((nowMs - (b.seen or 0)) / 1000)
      local asg = b.assignment or b.task or "-"
      print(("  #%-3d %-12s %-8s %-8s %s @ %d,%d,%d (%ss)"):format(
        id, b.name or "?", b.botType or "?", b.state or "?",
        tostring(asg):sub(1, 18), b.x or 0, b.y or 0, b.z or 0, age))
    end
  elseif cmd == "pending" then
    cmdPending()
  elseif cmd == "deploy" then
    cmdDeploy(rest)
  elseif cmd == "flatten" or cmd == "minejob" or cmd == "mine" then
    cmdFlatten(rest)
  elseif cmd == "permit" then
    cmdPermit(rest)
  elseif cmd == "unpermit" or cmd == "revoke" then
    cmdUnpermit(rest)
  elseif cmd == "permits" then
    cmdPermits()
  elseif cmd == "jobs" then
    if #mineJobs == 0 then print("(no recent flatten jobs)") end
    for _, j in ipairs(mineJobs) do
      print(("%s  %dx%d @ %d,%d -> Y%d  bots:%d  %s"):format(
        j.id, j.w, j.d, j.x, j.z, j.yEnd, j.bots, j.status or "?"))
    end
  elseif cmd == "bot" or cmd == "locate" then
    local ref, found = rest, nil
    for id, b in pairs(netbots) do
      if tostring(id) == ref or (b.name and b.name:lower() == tostring(ref):lower()) then
        found = { id = id, b = b }; break
      end
    end
    if not found then
      print("No such bot: " .. tostring(ref) .. "  (try 'bots')")
    else
      local b = found.b
      print(("Bot %s (#%d)  type: %s"):format(b.name or "?", found.id, b.botType or "?"))
      print(("  location: %d, %d, %d"):format(b.x or 0, b.y or 0, b.z or 0))
      print(("  state: %s   assignment: %s   fuel: %s"):format(
        b.state or "?", b.assignment or b.task or "-", tostring(b.fuel or "?")))
    end
  elseif cmd == "rename" or cmd == "hostname" or cmd == "host" then
    cmdRename(rest)
  elseif cmd == "setmaster" then
    cmdSetMaster()
  elseif cmd == "who" then
    print("Logged in as: " .. tostring(session.user))
    printStatus()
  elseif cmd == "status" then
    printStatus()
  elseif cmd == "monrate" or cmd == "mrate" or cmd == "monitorrate" or cmd == "refreshrate" then
    if rest and rest ~= "" then
      monRate = clampMonRate(rest:match("%S+"))
      saveConfig({ monRate = monRate })
    end
    print(("Monitor refresh: %.2fs  (range 0.25–120s)"):format(monRate))
  elseif cmd == "lock" or cmd == "logout" then
    session.mode = "bot"; session.user = nil
    print("Locked.")
  elseif cmd == "reboot" then
    os.reboot()
  elseif cmd == "help" then
    print("Admin terminal. Commands:")
    print("  stations           list every registered station")
    print("  storage            scan attached storage")
    print("  find <item>        search storage for an item")
    print("  scan               find online computers & master floppy")
    print("  bots               live roster (builder/gatherer/miner/loader)")
    print("  bot <name>         location, state, assignment")
    print("  locate <name>      alias of 'bot'")
    print("  pending            bots awaiting deployment")
    print("  deploy <id> <builder|gatherer|miner|loader> [auto] [dep] [stage]")
    print("                     (unique name Type-<id>; player labels ignored)")
    print("  flatten <x> <z> <W>x<D> <yEnd> [nBots] [yStart] [yband|strip]")
    print("  jobs               recent flatten / marker jobs")
    print("  permit <id|prefix:>   allow breaking Create/etc (shows on monitor)")
    print("  unpermit <id|prefix:> | permits")
    print("  monrate [secs]     monitor refresh rate (default 2s)")
    print("  rename|hostname <name>  rename this station (updates router roster)")
    print("  setmaster          change master password (master only)")
    print("  who | status       session / station info")
    print("  lock | logout      re-lock this terminal")
    print("  reboot             restart this computer")
  elseif cmd == "" then
    -- ignore
  else
    print("Unknown command: " .. cmd .. "  (type 'help')")
  end
end

--==============================================================================
-- Background loops
--==============================================================================

-- Answer network requests (master duties + ping replies). Always running.
local function serviceLoop()
  while true do
    local id, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" and id then
      local t = msg.type
      if t == MSG.WHERE_MASTER then
        if isLocalMaster() then
          rednet.send(id, { type = MSG.MASTER_HERE, label = station.name }, PROTOCOL)
        end
      elseif t == MSG.AUTH then
        if isLocalMaster() then
          local _, path = findMasterDrive()
          local stored = path and readMasterPassword(path)
          local ok = passwordMatches(stored, msg.password)
          rednet.send(id, { type = MSG.AUTH_RESULT, ok = ok }, PROTOCOL)
        end
      elseif t == MSG.REGISTER then
        if isLocalMaster() then
          registry[id] = { name = msg.name, seen = os.epoch("utc") }
        end
      elseif t == MSG.REGISTRY_REQ then
        if isLocalMaster() then
          rednet.send(id, { type = MSG.REGISTRY, registry = registry }, PROTOCOL)
        end
      elseif t == MSG.PING then
        rednet.send(id, { type = MSG.PONG, name = station.name }, PROTOCOL)
      elseif t == MSG.DEVICE_AUTH or t == "device_auth" then
        -- Bots / workers / miners re-auth with the Parent Center after boot or OTA.
        local name = msg.hostname or msg.name or ("#" .. id)
        local kind = msg.kind or "bot"
        authed[id] = { name = name, hostname = name, kind = kind, seen = os.epoch("utc") }
        if kind == "worker" or kind == "worker?" or kind == "miner" then
          -- Keep pending visible until deploy if we only have an auth ping.
          if not netbots[id] and not pending[id] then
            pending[id] = { name = name, kind = kind, seen = os.epoch("utc") }
          end
        elseif kind == "storage" then
          -- StorageManager nodes: track as online systems, never "pending deploy".
          local prev = netbots[id] or {}
          netbots[id] = {
            name = name, botType = "storage",
            x = prev.x, y = prev.y, z = prev.z,
            fuel = prev.fuel, state = "online",
            task = prev.task or "stock", assignment = "storage",
            seen = os.epoch("utc"),
          }
          pending[id] = nil
        else
          local prev = netbots[id] or {}
          netbots[id] = {
            name = name, botType = prev.botType or kind,
            x = prev.x, y = prev.y, z = prev.z,
            fuel = prev.fuel, state = prev.state or "authed",
            task = prev.task, assignment = prev.assignment or prev.task,
            seen = os.epoch("utc"),
          }
        end
        rednet.send(id, {
          type = MSG.AUTH_OK, name = station.name, station = station.name,
        }, PROTOCOL)
        print(("[auth] %s #%d (%s)"):format(name, id, kind))
      end
    end
  end
end

-- Register ourselves with the master periodically.
local function registerLoop()
  while true do
    if isLocalMaster() then
      registry[os.getComputerID()] = { name = station.name, seen = os.epoch("utc"), master = true }
    else
      local mId = discoverMaster(1)
      if mId then rednet.send(mId, { type = MSG.REGISTER, name = station.name }, PROTOCOL) end
    end
    -- Announce to the network router's directory (always share hostname).
    local host = station.name or os.getComputerLabel() or ("ParentCenter-" .. os.getComputerID())
    rednet.broadcast({
      type = "hello", kind = "datacenter", name = host, hostname = host,
    }, "titan_router")
    sleep(15)
  end
end

-- Listen to the bot network (titan_net) so this computer can display and query
-- the live bot roster (builder / gatherer / miner status + assignments).
local function botLoop()
  while true do
    local id, msg = rednet.receive(NET_PROTOCOL)
    if type(msg) == "table" and id then
      if msg.type == "bot_register" or msg.type == "status" or msg.type == "register"
          or msg.type == "pong" then
        local b = netbots[id] or {}
        -- Prefer bot's own label fields; titan.broadcast may stamp hostname on `name`.
        b.name = msg.botName or msg.label or msg.name or msg.hostname or b.name
        b.botType = msg.botType or b.botType
        b.x, b.y, b.z = msg.x or b.x, msg.y or b.y, msg.z or b.z
        b.fuel = msg.fuel ~= nil and msg.fuel or b.fuel
        -- Miners used `status`; workers use `state`. Accept both.
        b.state = msg.state or msg.status or b.state
        b.task = msg.task or b.task
        if msg.assignment ~= nil then
          b.assignment = msg.assignment
        elseif msg.task and not b.assignment then
          b.assignment = msg.task
        end
        if msg.dug ~= nil then b.dug = msg.dug end
        b.seen = os.epoch("utc")
        netbots[id] = b
        if b.botType and BOT_TYPES[b.botType] then pending[id] = nil end
      elseif msg.type == "worker_await" then
        pending[id] = {
          name = msg.name, kind = msg.kind or "worker",
          x = msg.x, y = msg.y, z = msg.z, seen = os.epoch("utc"),
        }
      elseif msg.type == "worker_deployed" then
        pending[id] = nil
        netbots[id] = netbots[id] or {}
        netbots[id].name = msg.name or netbots[id].name
        netbots[id].botType = msg.botType or netbots[id].botType
        netbots[id].state = "idle"
        netbots[id].seen = os.epoch("utc")
      elseif msg.type == "mine_job_ack" then
        local b = netbots[id] or {}
        b.state = msg.ok and (msg.queued and "queued" or "working") or (b.state or "error")
        if msg.err then b.task = tostring(msg.err) end
        if msg.jobId then b.assignment = msg.jobId end
        if msg.dug ~= nil then b.dug = msg.dug end
        b.seen = os.epoch("utc")
        netbots[id] = b
        if msg.ok and not msg.queued then
          for _, j in ipairs(mineJobs) do
            if msg.jobId and tostring(msg.jobId):find("^" .. j.id) then
              j.status = "active"
            end
          end
        end
      elseif msg.type == "permit_request" then
        local key = tostring(msg.key or msg.block or "")
        if key ~= "" then
          local dup = false
          for _, r in ipairs(permitReqs) do
            if r.key == key then dup = true; break end
          end
          if not dup then
            permitReqs[#permitReqs + 1] = {
              key = key, from = msg.from or msg.name or ("#" .. id),
              at = os.epoch("utc"),
            }
            while #permitReqs > 24 do table.remove(permitReqs, 1) end
            print(("Permit request: %s  (from %s) — admin: permit %s"):format(
              key, tostring(msg.from or id), key))
          end
        end
      elseif msg.type == "permit_sync" and msg.want then
        rednet.send(id, { type = "permit_sync", permits = permits }, NET_PROTOCOL)
      elseif msg.type == "site_job" then
        local sig = table.concat({
          tostring(msg.x1), tostring(msg.z1), tostring(msg.x2), tostring(msg.z2),
          tostring(msg.yStart), tostring(msg.yEnd), tostring(msg.nBots), tostring(id),
        }, ",")
        local now = os.epoch("utc")
        if lastSiteJob.sig == sig and (now - (lastSiteJob.at or 0)) < 5000 then
          -- ignore duplicate burst
        else
          lastSiteJob.sig, lastSiteJob.at = sig, now
          print(("Site job from #%d %s — dispatching..."):format(
            id, tostring(msg.name or "?")))
          handleSiteJob(id, msg)
        end
      end
    end
  end
end

-- Count active bots (seen recently) by type.
-- If a monitor is attached, show the station list (on the master) or a lock screen.
-- NOTE: never return - parallel.waitForAny stops everything if any task finishes.
local function drawMonitor(mon)
  mon.setTextScale(0.5)
  mon.setBackgroundColor(colors.black); mon.clear(); mon.setCursorPos(1, 1)
  local w = mon.getSize()
  local function line(y, text, c)
    mon.setCursorPos(1, y); mon.setTextColor(c or colors.white); mon.write(text:sub(1, w))
  end
  if isLocalMaster() then
    line(1, "== TITAN DATA CENTER : MASTER ==", colors.yellow)
    line(2, "Station                 ID    Last seen", colors.lightGray)
    local y = 3
    for id, s in pairs(registry) do
      local age = s.seen and math.floor((os.epoch("utc") - s.seen) / 1000) or 0
      line(y, ("%-22s #%-4d %ds%s"):format(
        (s.name or "?"):sub(1, 22), id, age, s.master and "  [MASTER]" or ""),
        age > 45 and colors.gray or colors.white)
      y = y + 1
    end
    -- Bot network summary + fleet jobs / Create break permits.
    local total, gath, build, mine, load, working = botStats()
    y = y + 1
    line(y, "-- BOT NETWORK --", colors.orange); y = y + 1
    line(y, ("Active:%d  build:%d gather:%d mine:%d load:%d busy:%d"):format(
      total, build, gath, mine, load, working), colors.lime); y = y + 1
    local nowMs2, npend = os.epoch("utc"), 0
    for _, w in pairs(pending) do if (nowMs2 - (w.seen or 0)) < 20000 then npend = npend + 1 end end
    if npend > 0 then
      line(y, ("Awaiting deploy: %d  (admin: pending / deploy)"):format(npend), colors.orange)
      y = y + 1
    end
    if #mineJobs > 0 then
      line(y, "-- FLEET JOBS --", colors.orange); y = y + 1
      for i = 1, math.min(3, #mineJobs) do
        if y >= select(2, mon.getSize()) - 4 then break end
        local j = mineJobs[i]
        line(y, ("%s %dx%d->Y%d bots:%d %s"):format(
          j.id, j.w, j.d, j.yEnd, j.bots, j.status or "?"), colors.cyan)
        y = y + 1
      end
    end
    do
      local pn = 0
      for _ in pairs(permits) do pn = pn + 1 end
      if pn > 0 or #permitReqs > 0 then
        line(y, "-- BREAK PERMITS --", colors.orange); y = y + 1
        if pn > 0 then
          local buf = {}
          for k in pairs(permits) do buf[#buf + 1] = k end
          table.sort(buf)
          line(y, ("OK: %s"):format(table.concat(buf, ", "):sub(1, w - 4)), colors.lime)
          y = y + 1
        end
        for i = 1, math.min(4, #permitReqs) do
          if y >= select(2, mon.getSize()) - 2 then break end
          local r = permitReqs[i]
          line(y, ("REQ %s (%s)"):format(r.key, tostring(r.from or "?")):sub(1, w), colors.red)
          y = y + 1
        end
      end
    end
    line(y, "NAME         TYPE     STATE    ASSIGNMENT", colors.lightGray); y = y + 1
    local h = select(2, mon.getSize())
    for id, b in pairs(netbots) do
      if y >= h then break end
      if (os.epoch("utc") - (b.seen or 0)) < 15000 then
        local asg = tostring(b.assignment or b.task or "-"):sub(1, 16)
        line(y, ("%-12s %-8s %-8s %s"):format(
          (b.name or ("#" .. id)):sub(1, 12), (b.botType or "?"):sub(1, 8),
          tostring(b.state or "?"):sub(1, 8), asg),
          (b.state == "idle" or b.state == "authed" or b.state == "parked") and colors.white or colors.cyan)
        y = y + 1
      end
    end
  else
    line(1, "== " .. tostring(station.name) .. " ==", colors.yellow)
    line(3, session.mode == "admin" and ("UNLOCKED - " .. tostring(session.user))
      or "LOCKED - login required", session.mode == "admin" and colors.lime or colors.red)
  end
end

local function displayLoop()
  while true do
    local mon = peripheral.find("monitor")
    if mon then drawMonitor(mon) end
    sleep(monRate)
  end
end

-- The interactive terminal.
-- Locked: prompt for the master password immediately (no "password" command first).
-- After a failed attempt, one locked> line for helpers (initmaster / help), then
-- the password prompt comes back on the next loop.
local function uiLoop()
  while true do
    term.setBackgroundColor(colors.black)
    if session.mode == "bot" then
      print("")
      print("[" .. tostring(station.name) .. "] LOCKED")
      attemptLogin()
      if session.mode == "bot" then
        print("Denied. Press Enter to retry, or: initmaster | help | password")
        write("locked> ")
        local input = read()
        local cmd, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
        cmd = (cmd or ""):lower()
        if cmd ~= "" then handleLocked(cmd, rest) end
      end
    else
      write("[" .. tostring(session.user) .. "@" .. tostring(station.name) .. "]$ ")
      local input = read()
      local cmd, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
      cmd = (cmd or ""):lower()
      handleAdmin(cmd, rest)
    end
  end
end

--==============================================================================
-- Startup
--==============================================================================
local function ensureStationName()
  local cfg = loadConfig()
  if cfg and cfg.name then
    station.name = cfg.name
    if cfg.monRate then monRate = clampMonRate(cfg.monRate) end
    return
  end
  term.clear(); term.setCursorPos(1, 1)
  print("== New Data Center Station ==")
  write("Name this station: ")
  local n = read()
  if n == "" then n = "Station-" .. os.getComputerID() end
  station.name = n
  saveConfig({ name = n, monRate = monRate })
end

openModem()
ensureStationName()
os.setComputerLabel(station.name)
do
  local cfg = loadConfig()
  if cfg and cfg.monRate then monRate = clampMonRate(cfg.monRate) end
end
loadPermits()
broadcastPermits()

term.clear(); term.setCursorPos(1, 1)
print("Titan Data Center - '" .. station.name .. "'")
if isLocalMaster() then
  print("This computer holds the MASTER floppy.")
elseif not discoverMaster(1) then
  print("No master online yet (logins will be denied until one appears).")
end
if next(permits) then
  local n = 0; for _ in pairs(permits) do n = n + 1 end
  print(("Break permits loaded: %d (broadcast to fleet)"):format(n))
end

local tasks = { serviceLoop, registerLoop, displayLoop, botLoop, uiLoop, relayLoop }
-- Inbound SSH + fleet OTA when lib is present (Parent Center ships lib/titan.lua).
local dcTitan = nil
if fs.exists("lib/titan.lua") then
  dcTitan = dofile("lib/titan.lua")
  -- SSH already checked the master password — run admin commands directly.
  -- Needs lib/titan.lua >= 1.2.8.
  if dcTitan.setSshHandler then
    dcTitan.setSshHandler(function(line)
      local cmd, rest = tostring(line or ""):match("^%s*(%S*)%s*(.-)%s*$")
      cmd = (cmd or ""):lower()
      if cmd == "" then return true end
      if cmd == "exit" or cmd == "quit" then
        print("Over SSH: type `exit` to disconnect (Parent Center keeps running).")
        return true
      end
      if cmd == "password" or cmd == "login" then
        print("Already authenticated over SSH.")
        session.mode = "admin"
        session.user = session.user or "ssh"
        return true
      end
      if cmd == "lock" or cmd == "logout" then
        print("Over SSH: lock ignored (session stays authed until disconnect).")
        return true
      end
      session.mode = "admin"
      session.user = session.user or "ssh"
      handleAdmin(cmd, rest)
      return true
    end)
  end
  tasks[#tasks + 1] = function() dcTitan.sshHostLoop("datacenter") end

  -- Fleet OTA from MAIN (`update all`): listen on titan_router (and ACK after reboot).
  local otaBusy = false
  tasks[#tasks + 1] = function()
    sleep(1)
    if dcTitan.reportUpdatedIfPending then
      dcTitan.reportUpdatedIfPending("datacenter")
    end
    while true do
      local id, msg = rednet.receive("titan_router")
      if type(msg) == "table" and msg.type == "update" and id ~= os.getComputerID()
          and not otaBusy and dcTitan.updateSelf then
        otaBusy = true
        print("")
        print(("[OTA] Fleet update from router #%s (v%s) — downloading..."):format(
          tostring(id), tostring(msg.targetVersion or "?")))
        local prev = dcTitan.systemVersion and dcTitan.systemVersion() or nil
        local ok, detail = dcTitan.updateSelf()
        if ok then
          local pkgs = type(detail) == "table" and detail.packages or nil
          if dcTitan.markPendingUpdateAck then
            dcTitan.markPendingUpdateAck(prev, msg.targetVersion, pkgs)
          end
          print("[OTA] Updated. Rebooting (will ACK main)..."); sleep(2); os.reboot()
        else
          print("[OTA] Failed: " .. tostring(detail))
          rednet.send(id, {
            type = "update_fail", version = prev, err = tostring(detail),
            name = station.name, hostname = station.name, kind = "datacenter",
          }, "titan_router")
          otaBusy = false
        end
      end
    end
  end
end
parallel.waitForAny(table.unpack(tasks))
