--[[
  router.lua  -  Titan network router / repeater (CC: Tweaked)
  Titan-Version: 1.2.5

  Place one (or several) of these to tie the whole network together over
  wireless and/or wired modems. Roles:

    MAIN  - directory, OTA update, re-auth authority, GPS host, repeater.
            Tracks GitHub versions.lua; `update aoe` pushes fleet OTA and
            collects `updated` ACKs after devices reboot.
            Attach up to 3+ monitors for ROSTER / STATS / GPS boards.
            Devices on the same wired cable as MAIN show as WIRED on roster.
    MODEM - repeater (+ optional GPS host) only. Use for coverage; not the
            network authority. Main assigns each a unique name from a pool;
            the modem sets it and reboots once. Set with `modem` / `main`.

    1. REPEATER - re-transmits rednet traffic (same idea as `repeat`) so devices
       out of direct range still reach each other. Both roles do this.
       Relays across wireless <-> wired so mixed networks stay linked.

    2. DIRECTORY (main only) - registry of seen systems; multi-monitor boards
       (roster / stats / gps); answers hello / where_main for fleet re-auth.

    3. GPS HOST - routers can host GPS. Place 4+ spread out for a constellation.

  Requirements: modem (wireless and/or wired). Optional monitors (main).

  Run:  router
]]

local PROTO_ROUTER = "titan_router"           -- discovery / register handshake
local REPEAT       = rednet.CHANNEL_REPEAT     -- 65533
local BROADCAST    = rednet.CHANNEL_BROADCAST  -- 65535
local WIRED_CH     = 65012                    -- main <-> peer wired-link probe
local WIRED_FRESH  = 45                       -- seconds a wired pong stays valid
local titanLib     = nil                       -- optional lib/titan.lua (SSH)

--------------------------------------------------------------------------------
-- Modems: open normal rednet (id + broadcast) AND the repeat channel.
-- Wired and wireless are both supported; the repeater bridges between them.
--------------------------------------------------------------------------------
local modems, wiredModems, wirelessModems = {}, {}, {}
local wiredDirect = {}   -- [id] = os.clock() when last wired_pong heard on MAIN

local function isWiredSide(side)
  if not side or not peripheral.isPresent(side) then return false end
  if peripheral.getType(side) ~= "modem" then return false end
  local ok, wireless = pcall(peripheral.call, side, "isWireless")
  return ok and wireless == false
end

for _, side in ipairs(peripheral.getNames()) do
  if peripheral.getType(side) == "modem" then
    modems[#modems + 1] = side
    if not rednet.isOpen(side) then rednet.open(side) end   -- so we can hear the roster
    peripheral.call(side, "open", REPEAT)                    -- so we can relay
    if isWiredSide(side) then
      wiredModems[#wiredModems + 1] = side
      peripheral.call(side, "open", WIRED_CH)
    else
      wirelessModems[#wirelessModems + 1] = side
    end
  end
end
if #modems == 0 then
  error("No modem attached. Put a wireless or wired modem on this computer.", 0)
end

os.setComputerLabel(os.getComputerLabel() or ("Router-" .. os.getComputerID()))

local BOOT_EPOCH = os.epoch("utc")

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local seen    = {}   -- [id] = { name, hostname, kind, seen }
local relayed = {}   -- [nMessageID] = timerId  (de-dup with 30s expiry)
-- Relay counters (named relayStats so it never clashes with screens.stats).
local relayStats = { relayed = 0 }
local rosterDirty = false
local ONLINE_SECS = 45   -- heard within this window => ONLINE on the board
-- Multi-monitor boards (main): roster / stats / gps. Names from peripheral.getName.
local screens = { roster = nil, stats = nil, gps = nil }  -- wrapped monitors
local screenNames = { roster = nil, stats = nil, gps = nil }
-- When true, monitors show the fleet map instead of roster/stats/gps boards.
local displayMap = false

-- Router config (GPS host coords + role: "main" | "modem").
local RCFG      = "router.cfg"
local ROSTER    = "router_roster.cfg"
local gpsCoords = nil
local routerRole = "main"   -- default: main (backward compatible)
local function loadRouterCfg()
  if not fs.exists(RCFG) then return nil end
  local f = fs.open(RCFG, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  return type(d) == "table" and d or nil
end
local function saveRouterCfg(c)
  local f = fs.open(RCFG, "w"); f.write(textutils.serialize(c)); f.close()
end
local function patchRouterCfg(patch)
  local c = loadRouterCfg() or {}
  for k, v in pairs(patch) do c[k] = v end
  saveRouterCfg(c)
  return c
end
local function isMain() return routerRole == "main" end

-- Time helpers (must be above noteDeviceVersion / startUpdateCampaign).
local function now() return os.epoch("utc") end
local function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end
local function isOnline(d)
  return d and d.seen and d.seen > 0 and ago(d.seen) < ONLINE_SECS
end

--------------------------------------------------------------------------------
-- Modem name registry (MAIN): unique names from a pool, persisted in router.cfg.
-- Modems hello -> main assigns a free name -> modem sets label and reboots.
--------------------------------------------------------------------------------
local DEFAULT_NAME_POOL = {
  "North", "East", "South", "West",
  "NE", "SE", "SW", "NW", "Center",
  "North-2", "East-2", "South-2", "West-2",
  "NE-2", "SE-2", "SW-2", "NW-2",
  "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot",
}

-- nameAssign[id] = "North"  (persisted)
local nameAssign = {}

local function loadNameRegistry()
  local c = loadRouterCfg() or {}
  nameAssign = {}
  if type(c.nameAssign) == "table" then
    for k, v in pairs(c.nameAssign) do
      local id = tonumber(k) or k
      if type(v) == "string" and v ~= "" then nameAssign[id] = v end
    end
  end
  if type(c.namePool) == "table" and #c.namePool > 0 then
    return c.namePool
  end
  return DEFAULT_NAME_POOL
end

local function saveNameRegistry(pool)
  local assign = {}
  for id, name in pairs(nameAssign) do
    assign[tostring(id)] = name
  end
  local patch = { nameAssign = assign }
  if pool then patch.namePool = pool end
  patchRouterCfg(patch)
end

local function namePool()
  local c = loadRouterCfg() or {}
  if type(c.namePool) == "table" and #c.namePool > 0 then return c.namePool end
  return DEFAULT_NAME_POOL
end

local function nameTaken(name, exceptId)
  if not name then return true end
  local want = name:lower()
  for id, n in pairs(nameAssign) do
    if id ~= exceptId and tostring(n):lower() == want then return true end
  end
  for id, d in pairs(seen) do
    if id ~= exceptId and d.kind == "modem" then
      local h = tostring(d.hostname or d.name or ""):lower()
      if h == want then return true end
    end
  end
  return false
end

-- Preferred pool entry from GPS bearing (still unique via registry).
local function preferredSectorName(x, z)
  if not gpsCoords or not x or not z then return nil end
  local dx, dz = x - gpsCoords.x, z - gpsCoords.z
  if dx == 0 and dz == 0 then return "Center" end
  local a = (math.deg(math.atan2(dx, -dz)) + 360) % 360
  local oct = math.floor((a + 22.5) / 45) % 8
  local bases = {
    [0] = "North", [1] = "NE", [2] = "East", [3] = "SE",
    [4] = "South", [5] = "SW", [6] = "West", [7] = "NW",
  }
  return bases[oct]
end

-- Assign or return the stable unique name for this modem id.
-- Returns name, isNew (true if first assignment or renamed).
local function allocateModemName(id, x, z, currentName)
  loadNameRegistry()
  if nameAssign[id] then
    return nameAssign[id], (currentName ~= nameAssign[id])
  end
  -- Keep current label if it's already a unique registry-style name we issued.
  if currentName and currentName ~= "" and not nameTaken(currentName, id)
     and not tostring(currentName):lower():match("^modem%-pending")
     and not tostring(currentName):lower():match("^modem%-" .. tostring(id) .. "$")
     and not tostring(currentName):lower():match("^router%-") then
    -- Only reclaim if it looks like a pool name or was previously ours.
    local poolHit = false
    for _, n in ipairs(namePool()) do
      if n:lower() == currentName:lower() then poolHit = true; break end
    end
    if poolHit then
      nameAssign[id] = currentName
      saveNameRegistry()
      return currentName, false
    end
  end

  local candidates = {}
  local pref = preferredSectorName(x, z)
  if pref then
    candidates[#candidates + 1] = pref
    for i = 2, 9 do candidates[#candidates + 1] = pref .. "-" .. i end
  end
  for _, n in ipairs(namePool()) do candidates[#candidates + 1] = n end
  candidates[#candidates + 1] = "Modem-" .. tostring(id)

  for _, n in ipairs(candidates) do
    if not nameTaken(n, id) then
      nameAssign[id] = n
      saveNameRegistry()
      return n, true
    end
  end
  local fallback = "Modem-" .. tostring(id) .. "-" .. tostring(os.epoch("utc") % 10000)
  nameAssign[id] = fallback
  saveNameRegistry()
  return fallback, true
end

local function releaseModemName(id)
  loadNameRegistry()
  if nameAssign[id] then
    nameAssign[id] = nil
    saveNameRegistry()
  end
end

--------------------------------------------------------------------------------
-- GitHub version tracking + fleet OTA campaign (MAIN)
--------------------------------------------------------------------------------
local DEFAULT_GH_BASE = "https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/"
local ghState = {
  base = DEFAULT_GH_BASE,
  remote = nil,       -- last fetched catalog
  checkedAt = 0,
  lastAlert = nil,    -- last remote.system we alerted about
}
-- Active AoE update: { version, sentAt, expected = { [id]=name }, acked = { [id]={...} } }
local updateCampaign = nil

local function githubBase()
  local c = loadRouterCfg() or {}
  if type(c.githubBase) == "string" and c.githubBase ~= "" then
    return c.githubBase:find("/$") and c.githubBase or (c.githubBase .. "/")
  end
  if titanLib and titanLib.GITHUB_RAW_BASE then return titanLib.GITHUB_RAW_BASE end
  return DEFAULT_GH_BASE
end

local function localSystemVersion()
  if titanLib and titanLib.systemVersion then return titanLib.systemVersion() end
  if fs.exists("versions.lua") then
    local ok, cat = pcall(dofile, "versions.lua")
    if ok and type(cat) == "table" then return cat.system end
  end
  return nil
end

local function fetchGithubVersions()
  local base = githubBase()
  ghState.base = base
  if titanLib and titanLib.fetchGithubVersions then
    local cat, err = titanLib.fetchGithubVersions(base)
    if not cat then return nil, err end
    ghState.remote = cat
    ghState.checkedAt = os.epoch("utc")
    return cat
  end
  -- Fallback without lib helpers.
  if not http then return nil, "http disabled (enable in ComputerCraft config)" end
  local h = http.get(base .. "versions.lua?cb=" .. os.epoch("utc"))
  if not h then return nil, "request failed" end
  local data = h.readAll(); h.close()
  if not data or data == "" then return nil, "empty response" end
  local loader = load(data, "@versions.lua", "t", {})
  if not loader then return nil, "parse failed" end
  local ok, cat = pcall(loader)
  if not ok or type(cat) ~= "table" then return nil, "invalid versions.lua" end
  ghState.remote = cat
  ghState.checkedAt = os.epoch("utc")
  return cat
end

local function versionCmp(a, b)
  if titanLib and titanLib.versionCompare then return titanLib.versionCompare(a, b) end
  if tostring(a) == tostring(b) then return 0 end
  if tostring(a) < tostring(b) then return -1 end
  return 1
end

local function noteDeviceVersion(id, version, name, kind)
  if not id then return end
  local d = seen[id] or {}
  d.version = version or d.version
  d.hostname = name or d.hostname or d.name
  d.name = d.hostname
  d.kind = kind or d.kind or "device"
  d.seen = now()
  seen[id] = d
  rosterDirty = true
  if updateCampaign and version
     and tostring(version) == tostring(updateCampaign.version) then
    updateCampaign.acked[id] = {
      name = d.hostname, version = version, at = os.epoch("utc"),
    }
  end
end

local function startUpdateCampaign(targetVersion)
  local expected = {}
  for id, d in pairs(seen) do
    if isOnline(d) and id ~= os.getComputerID() then
      expected[id] = d.hostname or d.name or ("#" .. id)
    end
  end
  updateCampaign = {
    version = targetVersion,
    sentAt = os.epoch("utc"),
    expected = expected,
    acked = {},
  }
  return expected
end

local function campaignStatus()
  if not updateCampaign then return nil end
  local exp, ack = 0, 0
  for _ in pairs(updateCampaign.expected) do exp = exp + 1 end
  for _ in pairs(updateCampaign.acked) do ack = ack + 1 end
  return exp, ack, updateCampaign
end

local function claimMain()
  local rname = os.getComputerLabel() or ("Router-" .. os.getComputerID())
  local msg = {
    type = "main_claim", id = os.getComputerID(),
    label = rname, hostname = rname, kind = "router",
  }
  if gpsCoords then
    msg.x, msg.y, msg.z = gpsCoords.x, gpsCoords.y, gpsCoords.z
  end
  rednet.broadcast(msg, PROTO_ROUTER)
end

-- Broadcast known router/modem positions for the pocket locator radar.
local function broadcastFleetMap()
  local nodes = {}
  local rname = os.getComputerLabel() or ("Router-" .. os.getComputerID())
  if gpsCoords then
    nodes[#nodes + 1] = {
      id = os.getComputerID(), name = rname, kind = "router",
      x = gpsCoords.x, y = gpsCoords.y, z = gpsCoords.z,
    }
  end
  for id, d in pairs(seen) do
    if d.x and d.z and (d.kind == "modem" or d.kind == "router") then
      nodes[#nodes + 1] = {
        id = id, name = d.hostname or d.name or ("#" .. id),
        kind = d.kind, x = d.x, y = d.y, z = d.z,
      }
    end
  end
  rednet.broadcast({
    type = "fleet_map", from = os.getComputerID(), name = rname,
    x = gpsCoords and gpsCoords.x, y = gpsCoords and gpsCoords.y,
    z = gpsCoords and gpsCoords.z, nodes = nodes,
  }, PROTO_ROUTER)
end

local function isWiredFresh(id)
  local t = wiredDirect[id]
  return type(t) == "number" and (os.clock() - t) < WIRED_FRESH
end

-- ONLINE = green, WIRED = cyan (online + on MAIN's cable), OFFLINE = red,
-- UNKNOWN = yellow (remembered, never heard live).
local function statusOf(d, id)
  if not d or not d.seen or d.seen <= 0 then
    return "UNKNOWN", colors.yellow
  end
  if ago(d.seen) < ONLINE_SECS then
    if d.wired or (id and isWiredFresh(id)) then
      return "WIRED", colors.cyan
    end
    return "ONLINE", colors.lime
  end
  return "OFFLINE", colors.red
end

local function countOnlineOffline()
  local on, off, unk = 0, 0, 0
  for id, d in pairs(seen) do
    local st = statusOf(d, id)
    if st == "ONLINE" or st == "WIRED" then on = on + 1
    elseif st == "UNKNOWN" then unk = unk + 1
    else off = off + 1 end
  end
  return on, off, unk
end

local function countWiredOnline()
  local n = 0
  for id, d in pairs(seen) do
    if statusOf(d, id) == "WIRED" then n = n + 1 end
  end
  return n
end

local function deviceCount()
  local on = countOnlineOffline()
  return on
end

local function statusRank(d, id)
  local st = statusOf(d, id)
  if st == "ONLINE" or st == "WIRED" then return 0 end
  if st == "UNKNOWN" then return 1 end
  return 2
end

-- Persist remembered systems so the monitor still lists them when offline.
-- Roster file is MAIN-only. Modems must not keep router_roster.cfg.
local function saveRoster()
  if not isMain() then return end
  local list = {}
  for id, d in pairs(seen) do
    list[tostring(id)] = {
      hostname = d.hostname or d.name,
      name = d.hostname or d.name,
      kind = d.kind,
      seen = d.seen or 0,
      x = d.x, y = d.y, z = d.z,
      wired = d.wired and true or nil,
    }
  end
  local f = fs.open(ROSTER, "w"); f.write(textutils.serialize(list)); f.close()
  rosterDirty = false
end

local function loadRoster()
  if not isMain() then return 0 end
  if not fs.exists(ROSTER) then return 0 end
  local f = fs.open(ROSTER, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  if type(d) ~= "table" then return 0 end
  local n = 0
  for sid, e in pairs(d) do
    local id = tonumber(sid)
    if id and type(e) == "table" then
      local host = e.hostname or e.name or ("#" .. id)
      seen[id] = {
        hostname = host, name = host,
        kind = e.kind or "device",
        seen = tonumber(e.seen) or 0,
        x = tonumber(e.x), y = tonumber(e.y), z = tonumber(e.z),
        wired = e.wired and true or nil,
      }
      n = n + 1
    end
  end
  return n
end

local function clearRosterIfModem()
  if isMain() then return end
  seen = {}
  rosterDirty = false
  if fs.exists(ROSTER) then
    pcall(fs.delete, ROSTER)
    print("Removed " .. ROSTER .. " (MAIN-only).")
  end
end

-- MODEM routers only persist a slim cfg: role + route to MAIN (+ optional
-- GPS / assigned hostname). Strip MAIN-only keys (roster, name pool, screens…).
local function sanitizeModemCfg(opts)
  opts = opts or {}
  if isMain() then return nil end
  local c = loadRouterCfg() or {}
  local slim = { role = "modem" }
  if not opts.clearMain then
    local mid = tonumber(opts.mainRouterId) or tonumber(c.mainRouterId)
    if mid then slim.mainRouterId = mid end
  end
  if not opts.clearName then
    if type(c.assignedName) == "string" and c.assignedName ~= "" then
      slim.assignedName = c.assignedName
    end
    if c.manualHostname then slim.manualHostname = true end
  end
  if c.gps then slim.gps = c.gps end
  if c.gpsHost == false then slim.gpsHost = false end
  saveRouterCfg(slim)
  return slim
end

-- Wipe routing data. MAIN: roster (+ optional name registry).
-- MODEM: in-memory state + slim cfg keeping only the path to MAIN.
local function resetRouting(mode)
  mode = (mode or "routes"):lower()
  if mode == "" then mode = "routes" end
  local clearNames = (mode == "all" or mode == "names")
  local clearMain = (mode == "all" or mode == "hard")
  if mode == "names" and not isMain() then
    return false, "name registry is MAIN-only"
  end
  if mode ~= "routes" and mode ~= "all" and mode ~= "names" and mode ~= "hard" then
    return false, "usage: reset [routes|names|all|hard]"
  end

  if isMain() then
    if mode ~= "names" then
      seen = {}
      wiredDirect = {}
      rosterDirty = false
      if fs.exists(ROSTER) then pcall(fs.delete, ROSTER) end
      updateCampaign = nil
    end
    if clearNames then
      nameAssign = {}
      saveNameRegistry(namePool())
    end
    if mode == "names" then
      return true, "Cleared modem name assignments."
    elseif clearNames then
      return true, "Cleared roster + modem name assignments."
    end
    return true, "Cleared roster / routing data (names kept). Use `reset all` to also clear names."
  end

  -- MODEM
  seen = {}
  wiredDirect = {}
  rosterDirty = false
  if fs.exists(ROSTER) then pcall(fs.delete, ROSTER) end
  local slim = sanitizeModemCfg({ clearMain = clearMain, clearName = clearNames or clearMain })
  local mid = slim and slim.mainRouterId
  if clearMain then
    return true, "Cleared modem routing. Will rediscover MAIN on next hello."
  end
  if mid then
    return true, ("Cleared modem routing. Kept route to MAIN #%d."):format(mid)
  end
  return true, "Cleared modem routing. No MAIN id stored yet — run and wait for hello."
end

-- Sorted id list: ONLINE, UNKNOWN, OFFLINE, then hostname, then id.
local function sortedIds()
  local ids = {}
  for id in pairs(seen) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b)
    local da, db = seen[a], seen[b]
    local ra, rb = statusRank(da, a), statusRank(db, b)
    if ra ~= rb then return ra < rb end
    local na = tostring(da.hostname or da.name or "")
    local nb = tostring(db.hostname or db.name or "")
    if na ~= nb then return na:lower() < nb:lower() end
    return a < b
  end)
  return ids
end

local function noteWiredDirect(id)
  id = tonumber(id)
  if not id or id == os.getComputerID() then return end
  wiredDirect[id] = os.clock()
  local d = seen[id]
  if d and not d.wired then
    d.wired = true
    rosterDirty = true
  elseif d then
    d.wired = true
  end
end

local function refreshWiredFlags()
  for id, d in pairs(seen) do
    local fresh = isWiredFresh(id)
    if d.wired and not fresh and not isOnline(d) then
      d.wired = nil
      rosterDirty = true
    elseif fresh and not d.wired then
      d.wired = true
      rosterDirty = true
    elseif not fresh and d.wired and isOnline(d) then
      -- Pong went stale while still online over RF — clear wired mark.
      d.wired = nil
      rosterDirty = true
    end
  end
end

-- Guess a device's role from the message it sent.
local function classify(msg)
  local t = msg.type
  if t == "poi_register" then return "poi"
  elseif t == "bot_register" then return "worker"
  elseif t == "register" or t == "status" then return msg.botType and "worker" or "bot"
  elseif t == "worker_await" then return "worker?"
  elseif t == "pong" or t == "master_here" then return "computer"
  elseif t == "hello" then return msg.kind or "device"
  end
  return nil
end

--------------------------------------------------------------------------------
-- 1) Repeater  (faithful to the built-in `repeat` program)
-- Bridges wireless <-> wired by re-transmitting on every open modem.
--------------------------------------------------------------------------------
local function repeaterLoop()
  while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
      local _, channel, replyChannel, message = p1, p2, p3, p4
      if channel == REPEAT and type(message) == "table"
         and message.nMessageID and message.nRecipient then
        if not relayed[message.nMessageID] then
          relayed[message.nMessageID] = os.startTimer(30)
          relayStats.relayed = relayStats.relayed + 1
          for _, m in ipairs(modems) do
            peripheral.call(m, "transmit", REPEAT, replyChannel, message)
            if message.nRecipient ~= REPEAT then
              peripheral.call(m, "transmit", message.nRecipient, replyChannel, message)
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

--------------------------------------------------------------------------------
-- Wired-link probe (MAIN): only peers on the same networking-cable segment
-- answer. Their roster status becomes WIRED (not merely ONLINE over RF).
--------------------------------------------------------------------------------
local function wiredLinkLoop()
  if #wiredModems == 0 then
    while true do sleep(3600) end
  end
  local nextProbe = 0
  while true do
    if isMain() and os.clock() >= nextProbe then
      local probe = {
        type = "wired_probe",
        mainId = os.getComputerID(),
        t = os.epoch("utc"),
      }
      for _, side in ipairs(wiredModems) do
        pcall(peripheral.call, side, "transmit", WIRED_CH, WIRED_CH, probe)
      end
      nextProbe = os.clock() + 8
      refreshWiredFlags()
    end
    local timeout = isMain() and math.max(0.2, nextProbe - os.clock()) or 5
    local timer = os.startTimer(timeout)
    while true do
      local ev, p1, p2, p3, p4 = os.pullEvent()
      if ev == "timer" and p1 == timer then break end
      if ev == "modem_message" and p2 == WIRED_CH and type(p4) == "table" then
        local side, msg = p1, p4
        if isWiredSide(side) then
          if msg.type == "wired_probe" and not isMain() then
            local pong = {
              type = "wired_pong",
              id = os.getComputerID(),
              name = os.getComputerLabel(),
              kind = "modem",
            }
            for _, s in ipairs(wiredModems) do
              pcall(peripheral.call, s, "transmit", WIRED_CH, WIRED_CH, pong)
            end
          elseif msg.type == "wired_pong" and isMain() then
            noteWiredDirect(msg.id)
          end
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 2) Directory  (roster + register / main-router handshake) — MAIN only
-- Roster (router_roster.cfg) lives ONLY on the main router.
--------------------------------------------------------------------------------
local function mainReplyBase()
  local rname = os.getComputerLabel() or ("Router-" .. os.getComputerID())
  local on, off = countOnlineOffline()
  local reply = {
    label = rname, hostname = rname,
    main = true, mainRouterId = os.getComputerID(),
    devices = on, online = on, offline = off,
  }
  if gpsCoords then
    reply.x, reply.y, reply.z = gpsCoords.x, gpsCoords.y, gpsCoords.z
  end
  return reply
end

-- Register a device into the MAIN roster; optionally assign a modem name.
-- Returns assignHostname, assignReboot for the reply.
local function rosterTouch(id, msg, kind, doAssign)
  local prev = seen[id]
  local host = msg.hostname or msg.name or (prev and (prev.hostname or prev.name))
  local wasOnline = prev and isOnline(prev)
  local px = tonumber(msg.x) or (prev and prev.x)
  local py = tonumber(msg.y) or (prev and prev.y)
  local pz = tonumber(msg.z) or (prev and prev.z)
  local assignHostname, assignReboot = nil, false
  local isModem = (kind == "modem" or msg.kind == "modem")
  if doAssign and isModem and msg.autoName ~= false then
    local name, isNew = allocateModemName(id, px, pz, host)
    assignHostname = name
    host = name
    local cur = tostring(msg.hostname or msg.name or "")
    assignReboot = isNew or (cur:lower() ~= name:lower())
  end
  seen[id] = {
    name = host, hostname = host,
    kind = kind or (prev and prev.kind) or "device",
    seen = now(), x = px, y = py, z = pz,
    version = msg.version or (prev and prev.version),
    -- Only MAIN's wired probe/pong marks a direct cable link (not RF relays).
    wired = isWiredFresh(id) or nil,
  }
  rosterDirty = true
  if not prev then
    print(("[+] %s #%d (%s) ONLINE"):format(seen[id].hostname or "?", id, seen[id].kind))
  elseif host and prev.hostname ~= host and prev.name ~= host then
    print(("[~] #%d hostname -> %s"):format(id, host))
  elseif prev and not wasOnline then
    print(("[*] %s #%d back ONLINE"):format(host or "?", id))
  end
  if assignHostname and assignReboot then
    print(("[name] #%d <- %s (modem will reboot)"):format(id, assignHostname))
  end
  return assignHostname, assignReboot
end

local function directoryLoop()
  rednet.broadcast({ type = "ping" }, "titan_net")
  rednet.broadcast({ type = "ping" }, "titan_dc")
  claimMain()
  broadcastFleetMap()
  while true do
    local id, msg, proto = rednet.receive()
    if type(msg) == "table" and id then
      -- Hopped modem hello: peer modem forwarded a device that can't hear main.
      if proto == PROTO_ROUTER and msg.type == "hop_hello" and tonumber(msg.from) then
        local src = tonumber(msg.from)
        local hello = type(msg.hello) == "table" and msg.hello or msg
        hello.kind = hello.kind or "modem"
        local assignHostname, assignReboot = rosterTouch(src, hello, "modem", true)
        local reply = mainReplyBase()
        reply.type = "hop_reply"
        reply.dest = src
        reply.via = id
        if assignHostname then
          reply.assignHostname = assignHostname
          reply.reboot = assignReboot and true or false
        end
        rednet.send(id, reply, PROTO_ROUTER)

      elseif proto == PROTO_ROUTER and (msg.type == "updated" or msg.type == "update_fail"
          or msg.type == "version_report") then
        local host = msg.hostname or msg.name or ("#" .. id)
        noteDeviceVersion(id, msg.version, host, msg.kind or classify(msg))
        if msg.type == "updated" then
          print(("[OTA] ACK #%d %s -> v%s"):format(id, host, tostring(msg.version or "?")))
          local exp, ack = campaignStatus()
          if exp then
            print(("[OTA] Campaign v%s: %d / %d acked"):format(
              tostring(updateCampaign.version), ack, exp))
          end
        elseif msg.type == "update_fail" then
          print(("[OTA] FAIL #%d %s: %s"):format(id, host, tostring(msg.err or "?")))
        end

      elseif proto == PROTO_ROUTER and (msg.type == "hello" or msg.type == "where_main"
          or msg.type == "map_req" or msg.type == "hop_find_main") then
        local kind = classify(msg)
        local assignHostname, assignReboot = nil, false
        if msg.type == "hello" then
          assignHostname, assignReboot = rosterTouch(id, msg, kind, true)
          if msg.version then noteDeviceVersion(id, msg.version, assignHostname or msg.hostname, kind) end
        else
          rosterTouch(id, msg, kind, false)
        end
        local reply = mainReplyBase()
        if assignHostname then
          reply.assignHostname = assignHostname
          reply.reboot = assignReboot and true or false
        end
        if msg.type == "hello" then
          reply.type = "here"
          rednet.send(id, reply, PROTO_ROUTER)
        elseif msg.type == "where_main" or msg.type == "hop_find_main" then
          reply.type = "main_here"
          rednet.send(id, reply, PROTO_ROUTER)
        elseif msg.type == "map_req" then
          broadcastFleetMap()
        end

      else
        -- Other protocols: remember presence only (no modem naming).
        local kind = classify(msg)
        if kind then rosterTouch(id, msg, kind, false) end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Multi-monitor dashboards (main): ROSTER / STATS / GPS
--
-- Auto-assign by sorted peripheral name (1st=roster, 2nd=stats, 3rd=gps).
-- Override with `screen <roster|stats|gps> <name|side>` (saved in router.cfg).
-- 1 monitor: all three panels stacked. 2: roster + stats (GPS on stats). 3+: split.
--------------------------------------------------------------------------------
local SCREEN_ROLES = { "roster", "stats", "gps" }

local function listMonitorNames()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

local function wrapScreen(name)
  if not name or not peripheral.isPresent(name) then return nil end
  if peripheral.getType(name) ~= "monitor" then return nil end
  local m = peripheral.wrap(name)
  if m then pcall(function() m.setTextScale(0.5) end) end
  return m
end

local function loadScreenAssignments()
  local c = loadRouterCfg() or {}
  local s = type(c.screens) == "table" and c.screens or {}
  for _, role in ipairs(SCREEN_ROLES) do
    if type(s[role]) == "string" and s[role] ~= "" and s[role] ~= "auto" then
      screenNames[role] = s[role]
    end
  end
end

local function saveScreenAssignments()
  local s = {}
  for _, role in ipairs(SCREEN_ROLES) do
    if screenNames[role] then s[role] = screenNames[role] end
  end
  patchRouterCfg({ screens = s })
end

local function refreshScreens()
  local names = listMonitorNames()
  local used = {}
  -- Apply saved assignments first (keep names if a monitor is briefly missing).
  for _, role in ipairs(SCREEN_ROLES) do
    local want = screenNames[role]
    local m = want and wrapScreen(want) or nil
    screens[role] = m
    if want then used[want] = true end
  end
  -- Auto-fill remaining roles from leftover monitors (sorted).
  local free = {}
  for _, n in ipairs(names) do
    if not used[n] then free[#free + 1] = n end
  end
  local fi = 1
  for _, role in ipairs(SCREEN_ROLES) do
    if not screens[role] and free[fi] then
      screenNames[role] = free[fi]
      screens[role] = wrapScreen(free[fi])
      used[free[fi]] = true
      fi = fi + 1
    end
  end
  -- Single monitor: drive all three roles from the same wrap (stacked draw).
  if #names == 1 then
    local only = wrapScreen(names[1])
    screens.roster, screens.stats, screens.gps = only, only, only
    screenNames.roster, screenNames.stats, screenNames.gps = names[1], names[1], names[1]
  elseif #names == 2 then
    -- Prefer roster on one; stack stats+GPS on the other.
    if screens.roster and not screens.stats then
      for _, n in ipairs(names) do
        if n ~= screenNames.roster then
          screenNames.stats = n
          screens.stats = wrapScreen(n)
          break
        end
      end
    end
    if screens.stats then
      screens.gps = screens.stats
      screenNames.gps = screenNames.stats
    end
  end
  return #names
end

local function monLine(out, w, y, txt, c)
  out.setCursorPos(1, y)
  out.setTextColor(c or colors.white)
  out.write(tostring(txt):sub(1, w))
end

local function clearMon(out)
  out.setBackgroundColor(colors.black)
  out.clear()
end

local function kindCounts()
  local c = {}
  for _, d in pairs(seen) do
    local k = d.kind or "device"
    c[k] = (c[k] or 0) + 1
  end
  return c
end

local function uptimeStr()
  local sec = math.floor((os.epoch("utc") - BOOT_EPOCH) / 1000)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then return ("%dh %dm"):format(h, m) end
  if m > 0 then return ("%dm %ds"):format(m, s) end
  return ("%ds"):format(s)
end

local function drawStatusHeader(out, w, y, on, off, unk)
  -- Color-coded counts: green ONLINE, red OFFLINE, yellow UNKNOWN.
  out.setCursorPos(1, y)
  local function writePart(txt, c)
    out.setTextColor(c)
    out.write(txt)
  end
  writePart("ONLINE:" .. tostring(on), colors.lime)
  writePart("  ", colors.white)
  writePart("OFFLINE:" .. tostring(off), colors.red)
  writePart("  ", colors.white)
  writePart("UNKNOWN:" .. tostring(unk), colors.yellow)
  -- Clear remainder of the line.
  local cx = out.getCursorPos()
  if cx <= w then
    out.setTextColor(colors.white)
    out.write(string.rep(" ", w - cx + 1))
  end
end

local function drawRoster(out, y0, y1)
  local w, h = out.getSize()
  y0 = y0 or 1
  y1 = y1 or h
  local on, off, unk = countOnlineOffline()
  monLine(out, w, y0, "== ROSTER ==", colors.white)
  if y0 + 1 <= y1 then
    drawStatusHeader(out, w, y0 + 1, on, off, unk)
  end
  if y0 + 2 <= y1 then
    monLine(out, w, y0 + 2, "ID   STATUS   KIND     HOSTNAME", colors.lightGray)
  end
  local y = y0 + 3
  for _, id in ipairs(sortedIds()) do
    if y > y1 then break end
    local d = seen[id]
    local host = d.hostname or d.name or "?"
    local status, statusColor = statusOf(d, id)
    local age = d.seen and d.seen > 0 and (ago(d.seen) .. "s") or "-"
    -- ID + STATUS (colored) + KIND + HOSTNAME
    out.setCursorPos(1, y)
    out.setTextColor(colors.white)
    out.write(("%-4d "):format(id))
    out.setTextColor(statusColor)
    out.write(("%-8s "):format(status))
    out.setTextColor(status == "WIRED" and colors.cyan or colors.white)
    local rest = ("%-8s %s"):format((d.kind or "?"):sub(1, 8), host)
    local used = 4 + 1 + 8 + 1
    local room = w - used - 6
    if room < 8 then room = math.max(0, w - used) end
    out.write(rest:sub(1, room))
    local ageStr = tostring(age)
    local rowLen = used + math.min(#rest, room)
    if w >= rowLen + #ageStr + 1 then
      out.setCursorPos(w - #ageStr + 1, y)
      out.setTextColor(colors.gray)
      out.write(ageStr)
    end
    y = y + 1
  end
  if y == y0 + 3 and y <= y1 then
    monLine(out, w, y, "(no systems registered yet)", colors.gray)
  end
end

local function drawStats(out, y0, y1)
  local w, h = out.getSize()
  y0 = y0 or 1
  y1 = y1 or h
  local on, off, unk = countOnlineOffline()
  local remembered = 0
  for _ in pairs(seen) do remembered = remembered + 1 end
  local cyan = colors.cyan or colors.lightBlue
  local nRf = wirelessModems and #wirelessModems or 0
  local nWire = wiredModems and #wiredModems or 0
  local nModems = modems and #modems or (nRf + nWire)
  local nRelayed = (relayStats and tonumber(relayStats.relayed)) or 0
  monLine(out, w, y0, "== STATS ==", colors.white)
  local rows = {}
  local function addRow(txt, col)
    rows[#rows + 1] = { txt, col }
  end
  addRow(string.format("Router #%d  [%s]", os.getComputerID(), tostring(routerRole or "?"):upper()), colors.white)
  addRow(string.format("Hostname: %s", tostring(os.getComputerLabel() or "?")), colors.lightGray)
  addRow(string.format("Uptime: %s", uptimeStr()), colors.white)
  addRow(string.format("Modems: %d  (rf:%d wire:%d)", nModems, nRf, nWire), colors.white)
  addRow(string.format("Relayed: %d", nRelayed), cyan)
  addRow(string.format("Online: %d", on), colors.lime)
  addRow(string.format("Wired: %d", countWiredOnline()), cyan)
  addRow(string.format("Offline: %d", off), colors.red)
  addRow(string.format("Unknown: %d", unk), colors.yellow)
  addRow(string.format("Remembered: %d", remembered), colors.white)
  local y = y0 + 1
  for _, r in ipairs(rows) do
    if y > y1 then return end
    monLine(out, w, y, r[1], r[2]); y = y + 1
  end
  if y <= y1 then monLine(out, w, y, "By kind:", colors.lightGray); y = y + 1 end
  local kinds = kindCounts()
  local keys = {}
  for k in pairs(kinds) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if y > y1 then break end
    monLine(out, w, y, string.format("  %-10s %d", k, kinds[k]), colors.white)
    y = y + 1
  end
  if #keys == 0 and y <= y1 then
    monLine(out, w, y, "  (none)", colors.gray)
  end
end

local function drawGps(out, y0, y1)
  local w, h = out.getSize()
  y0 = y0 or 1
  y1 = y1 or h
  monLine(out, w, y0, "== GPS ==", colors.yellow)
  local y = y0 + 1
  local function put(txt, c)
    if y > y1 then return end
    monLine(out, w, y, txt, c); y = y + 1
  end
  if gpsCoords then
    put("Hosting: YES", colors.lime)
    put(("X: %d"):format(gpsCoords.x), colors.white)
    put(("Y: %d"):format(gpsCoords.y), colors.white)
    put(("Z: %d"):format(gpsCoords.z), colors.white)
    put(("Pos: %d, %d, %d"):format(gpsCoords.x, gpsCoords.y, gpsCoords.z), colors.cyan)
  else
    put("Hosting: NO", colors.red)
    put("Use: gpshost <x> <y> <z>", colors.lightGray)
  end
  put("", colors.white)
  put("Live locate:", colors.lightGray)
  local lx, ly, lz = gps.locate(0.2)
  if lx then
    put(("  %.1f, %.1f, %.1f"):format(lx, ly, lz), colors.lime)
  else
    put("  (no fix - need 4 hosts)", colors.orange)
  end
  put("", colors.white)
  put("Constellation: place 4+", colors.gray)
  put("routers with gpshost set.", colors.gray)
end

local function loadDisplayMap()
  local c = loadRouterCfg() or {}
  displayMap = c.displayMap == true
  return displayMap
end

local function setDisplayMap(on)
  displayMap = on and true or false
  patchRouterCfg({ displayMap = displayMap })
  return displayMap
end

-- Forward-declared; body set after drawFleetMapOn is defined.
local drawMapOnMonitors

local function drawStatsBoards()
  local roster, statsM, gpsM = screens.roster, screens.stats, screens.gps
  local same = (roster == statsM) and (statsM == gpsM)

  if same and roster then
    -- One physical monitor: stack all three panels.
    local w, h = roster.getSize()
    clearMon(roster)
    local h1 = math.max(4, math.floor(h * 0.50))
    local h2 = math.max(3, math.floor(h * 0.25))
    local yRoster = 1
    local yStats = h1 + 1
    local yGps = h1 + h2 + 1
    if yGps > h then yGps = h end
    drawRoster(roster, yRoster, math.min(h1, h))
    if yStats <= h then
      monLine(roster, w, yStats, string.rep("-", w), colors.gray)
      drawStats(roster, yStats + 1, math.min(yGps - 1, h))
    end
    if yGps <= h then
      monLine(roster, w, yGps, string.rep("-", w), colors.gray)
      drawGps(roster, yGps + 1, h)
    end
    return
  end

  -- Two monitors: GPS shares stats screen (stacked on stats).
  local statsSharesGps = statsM and gpsM and statsM == gpsM and roster ~= statsM

  if roster then
    clearMon(roster)
    drawRoster(roster)
  end
  if statsM then
    clearMon(statsM)
    if statsSharesGps then
      local w, h = statsM.getSize()
      local mid = math.max(2, math.floor(h / 2))
      drawStats(statsM, 1, mid)
      monLine(statsM, w, mid, string.rep("-", w), colors.gray)
      drawGps(statsM, mid + 1, h)
    else
      drawStats(statsM)
    end
  end
  if gpsM and not statsSharesGps and gpsM ~= roster then
    clearMon(gpsM)
    drawGps(gpsM)
  end
end

local function drawBoards()
  local n = refreshScreens()
  if n == 0 then return end
  if displayMap then
    if drawMapOnMonitors then drawMapOnMonitors() end
  else
    drawStatsBoards()
  end
end

local function drawLoop()
  loadScreenAssignments()
  loadDisplayMap()
  while true do
    refreshWiredFlags()
    drawBoards()
    if rosterDirty then saveRoster() end
    sleep(1)
  end
end

-- Persist roster even without a monitor.
local function rosterSaveLoop()
  while true do
    if rosterDirty then saveRoster() end
    sleep(5)
  end
end

-- Periodically nudge the network so devices that booted before us also register.
local function pingLoop()
  while true do
    rednet.broadcast({ type = "ping" }, "titan_net")
    rednet.broadcast({ type = "ping" }, "titan_dc")
    if isMain() then
      claimMain()
      broadcastFleetMap()
    end
    sleep(15)
  end
end

-- Poll GitHub versions.lua; alert when remote system version is newer.
local function githubWatchLoop()
  sleep(5)
  while true do
    if isMain() then
      local cat, err = fetchGithubVersions()
      if cat and cat.system then
        local localVer = localSystemVersion()
        if versionCmp(localVer, cat.system) < 0
           and ghState.lastAlert ~= cat.system then
          ghState.lastAlert = cat.system
          print("")
          print(("[GitHub] New Titan v%s available (local %s)."):format(
            tostring(cat.system), tostring(localVer or "?")))
          print("[GitHub] Run `update aoe` to push fleet OTA from GitHub packages.")
        end
      elseif err then
        -- Quiet unless first failure after boot.
        if not ghState.remote then
          print("[GitHub] Version check failed: " .. tostring(err))
        end
      end
    end
    sleep(300)  -- every 5 minutes
  end
end

-- MODEM routers: mesh hop to MAIN (no local roster), accept unique name, reboot.
-- rednet CHANNEL_REPEAT already relays; we also app-hop hello/where_main when
-- a peer cannot hear main directly.
local function modemLoop()
  local manualName = false
  local assignedName = nil
  local mainId = nil
  local mainInfo = nil   -- last main_here fields
  local mainSeenAt = 0
  local MAIN_STALE = 90  -- seconds without hearing main => rediscover via hops

  do
    local c = loadRouterCfg() or {}
    if c.manualHostname then manualName = true end
    if type(c.assignedName) == "string" and c.assignedName ~= "" then
      assignedName = c.assignedName
      if os.getComputerLabel() ~= assignedName then
        os.setComputerLabel(assignedName)
      end
    end
    if tonumber(c.mainRouterId) then mainId = tonumber(c.mainRouterId) end
  end

  local function ownPos()
    if gpsCoords then return gpsCoords.x, gpsCoords.y, gpsCoords.z end
    local x, y, z = gps.locate(1)
    if x then
      return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
    end
    return nil
  end

  local function rememberMain(id, msg)
    if not id or not msg then return end
    if msg.main or msg.type == "main_claim" or msg.type == "main_here"
       or msg.mainRouterId then
      mainId = tonumber(msg.mainRouterId) or id
      mainInfo = msg
      mainSeenAt = os.clock()
      patchRouterCfg({ mainRouterId = mainId })
    end
  end

  local function applyAssignedName(name, shouldReboot)
    if not name or name == "" or manualName then return false end
    local cur = os.getComputerLabel()
    if cur == name and assignedName == name then
      return false
    end
    os.setComputerLabel(name)
    assignedName = name
    patchRouterCfg({ assignedName = name, manualHostname = false })
    print("[name] Main router assigned: " .. name)
    if shouldReboot ~= false then
      print("[name] Rebooting with new hostname...")
      sleep(1)
      os.reboot()
    end
    return true
  end

  local function handleAssign(msg)
    if not msg or not msg.assignHostname then return end
    local needReboot = msg.reboot == true
      or (os.getComputerLabel() ~= msg.assignHostname)
      or (assignedName ~= msg.assignHostname)
    applyAssignedName(msg.assignHostname, needReboot)
  end

  local function announce()
    local x, y, z = ownPos()
    local name = assignedName or os.getComputerLabel()
      or ("Modem-pending-" .. os.getComputerID())
    local msg = {
      type = "hello", kind = "modem", name = name, hostname = name,
      autoName = not manualName,
      needName = (not manualName) and (assignedName == nil),
    }
    if x then msg.x, msg.y, msg.z = x, y, z end
    -- Prefer directed hello to main when known; also broadcast for mesh/repeat.
    if mainId then
      rednet.send(mainId, msg, PROTO_ROUTER)
    end
    rednet.broadcast(msg, PROTO_ROUTER)
    -- If main is stale/unknown, ask peers to hop us a path.
    if not mainId or (os.clock() - mainSeenAt) > MAIN_STALE then
      rednet.broadcast({
        type = "hop_find_main", from = os.getComputerID(),
        name = name, hostname = name,
      }, PROTO_ROUTER)
    end
  end

  local function findMain()
    rednet.broadcast({ type = "where_main", name = os.getComputerLabel() }, PROTO_ROUTER)
    rednet.broadcast({
      type = "hop_find_main", from = os.getComputerID(),
      name = os.getComputerLabel(),
    }, PROTO_ROUTER)
  end

  if not manualName and not assignedName then
    print("[name] Waiting for main router to assign a unique name...")
  end
  print("[hop] Mesh relay on — will hop to MAIN when out of direct range.")
  findMain()
  announce()
  local nextAnn = os.clock() + 20
  while true do
    if os.clock() >= nextAnn then announce(); nextAnn = os.clock() + 20 end
    local id, msg = rednet.receive(PROTO_ROUTER, math.max(0.2, nextAnn - os.clock()))
    if type(msg) ~= "table" or not id then
      -- ignore
    elseif msg.type == "main_claim" or msg.type == "main_here" then
      rememberMain(id, msg)
      handleAssign(msg)
      announce()

    elseif msg.type == "here" then
      rememberMain(id, msg)
      handleAssign(msg)

    elseif msg.type == "hop_reply" then
      -- Reply from main via another modem (or for us to forward).
      if tonumber(msg.dest) == os.getComputerID() then
        rememberMain(msg.mainRouterId or id, msg)
        handleAssign(msg)
      elseif msg.dest then
        rednet.send(tonumber(msg.dest), msg, PROTO_ROUTER)
      end

    elseif msg.type == "where_main" or msg.type == "hop_find_main" then
      -- Peer looking for main: if we know it, answer + forward their query.
      if mainId and mainInfo and id ~= mainId then
        local reply = {
          type = "main_here",
          main = true,
          mainRouterId = mainId,
          label = mainInfo.label or mainInfo.hostname,
          hostname = mainInfo.hostname or mainInfo.label,
          x = mainInfo.x, y = mainInfo.y, z = mainInfo.z,
          via = os.getComputerID(),
          hop = true,
        }
        rednet.send(id, reply, PROTO_ROUTER)
        rednet.send(mainId, {
          type = "where_main", from = id, via = os.getComputerID(),
          name = msg.name or msg.hostname,
        }, PROTO_ROUTER)
      elseif mainId and id ~= mainId then
        rednet.send(mainId, msg, PROTO_ROUTER)
      end

    elseif msg.type == "hello" and (msg.kind == "modem" or msg.autoName) then
      -- Peer modem hello: if we can reach main and they might not, hop it.
      if mainId and id ~= mainId and id ~= os.getComputerID() then
        rednet.send(mainId, {
          type = "hop_hello", from = id, via = os.getComputerID(),
          hello = msg,
        }, PROTO_ROUTER)
      end

      elseif msg.type == "update" and id ~= os.getComputerID() then
      print("")
      print(("[OTA] AoE update from #%s (v%s) — downloading..."):format(
        tostring(id), tostring(msg.targetVersion or "?")))
      if titanLib and titanLib.updateSelf then
        local prev = titanLib.systemVersion and titanLib.systemVersion() or nil
        local ok, err = titanLib.updateSelf()
        if ok then
          if titanLib.markPendingUpdateAck then
            titanLib.markPendingUpdateAck(prev, msg.targetVersion)
          end
          print("[OTA] Updated. Rebooting (will ACK main)..."); sleep(2); os.reboot()
        else
          print("[OTA] Failed: " .. tostring(err))
          rednet.send(id, {
            type = "update_fail", version = prev, err = tostring(err),
            name = os.getComputerLabel(), hostname = os.getComputerLabel(),
          }, PROTO_ROUTER)
        end
      else
        print("[OTA] No titan updateSelf — rebooting..."); sleep(1); os.reboot()
      end
    end
  end
end

-- Routers double as GPS hosts: answer gps.locate PINGs with our coordinates.
-- (Faithful to the built-in `gps host` protocol.) Only run when gpsCoords is set.
local function gpsHostLoop()
  for _, side in ipairs(modems) do peripheral.call(side, "open", gps.CHANNEL_GPS) end
  while true do
    local _, side, ch, reply, message = os.pullEvent("modem_message")
    if ch == gps.CHANNEL_GPS and message == "PING" and reply then
      peripheral.call(side, "transmit", reply, gps.CHANNEL_GPS,
        { gpsCoords.x, gpsCoords.y, gpsCoords.z })
    end
  end
end

--------------------------------------------------------------------------------
-- Fleet map (MAIN): zoomed-out ASCII grid of routers/modems
-- Grid lines use - _ | \ /   Markers: r = main, m = modem
--------------------------------------------------------------------------------
local mapScale = 16  -- blocks per cell (zoomed out by default)

local function fleetMapNodes()
  local list = {}
  local myId = os.getComputerID()
  local rname = os.getComputerLabel() or ("Router-" .. myId)
  if gpsCoords then
    list[#list + 1] = {
      id = myId, name = rname, kind = "router",
      x = gpsCoords.x, y = gpsCoords.y, z = gpsCoords.z, main = true,
    }
  end
  for id, d in pairs(seen) do
    if id ~= myId and d.x and d.z
       and (d.kind == "modem" or d.kind == "router") then
      list[#list + 1] = {
        id = id,
        name = d.hostname or d.name or ("#" .. id),
        kind = d.kind,
        x = d.x, y = d.y, z = d.z,
        main = false,
        wired = d.wired or isWiredFresh(id) or nil,
      }
    end
  end
  return list
end

local function mapOrigin(nodes)
  if gpsCoords then return gpsCoords.x, gpsCoords.z end
  if #nodes == 0 then return 0, 0 end
  local sx, sz = 0, 0
  for _, n in ipairs(nodes) do sx = sx + n.x; sz = sz + n.z end
  return math.floor(sx / #nodes + 0.5), math.floor(sz / #nodes + 0.5)
end

local function mapAutoScale(nodes, ox, oz, gw, gh)
  local maxD = 8
  for _, n in ipairs(nodes) do
    maxD = math.max(maxD, math.abs(n.x - ox), math.abs(n.z - oz))
  end
  local half = math.max(2, math.floor(math.min(gw, gh) / 2) - 1)
  return math.max(2, math.ceil(maxD / half))
end

-- Background cell art from (-, _, |, \, /).
local function mapGridChar(relX, relZ)
  if relX == 0 and relZ == 0 then return "+" end
  if relX == 0 then return "|" end
  if relZ == 0 then return "-" end
  if relX == relZ then return "\\" end
  if relX == -relZ then return "/" end
  if relZ % 4 == 0 then return "_" end
  if relX % 4 == 0 then return "|" end
  if (relX + relZ) % 6 == 0 then return "/" end
  if (relX - relZ) % 6 == 0 then return "\\" end
  if relZ % 2 == 0 then return "-" end
  return " "
end

-- Draw fleet map onto any term/monitor (`out`). opts.interactive adds key hints.
local function drawFleetMapOn(out, scale, opts)
  opts = opts or {}
  local tw, th = out.getSize()
  out.setBackgroundColor(colors.black)
  out.clear()
  local colorOk = out.isColor and out.isColor()
  local function put(x, y, ch, fg)
    if x < 1 or y < 1 or x > tw or y > th then return end
    out.setCursorPos(x, y)
    if colorOk then
      out.setTextColor(fg or colors.white)
      out.setBackgroundColor(colors.black)
    end
    out.write(ch)
  end

  local nodes = fleetMapNodes()
  local ox, oz = mapOrigin(nodes)
  if not gpsCoords and #nodes == 0 then
    put(1, 1, "No GPS / modem positions yet.", colors.red)
    put(1, 2, "Set gpshost; wait for modem hellos.", colors.gray)
    if opts.interactive then put(1, 4, "[Q] quit", colors.gray) end
    return nodes, ox, oz, scale or mapScale
  end

  local top, bottom = 3, th - 3
  local left, right = 1, tw
  local gw, gh = right - left + 1, bottom - top + 1
  if gh < 4 then top, bottom = 2, th - 1 end
  gw, gh = right - left + 1, bottom - top + 1
  if not scale then
    scale = mapAutoScale(nodes, ox, oz, gw, math.max(4, gh))
  end
  mapScale = scale

  put(1, 1, ("FLEET MAP  origin %d,%d  %dm/cell"):format(ox, oz, scale), colors.yellow)
  if opts.interactive then
    put(1, 2, "r=main  m=rf  w=wired  N=up  +/- zoom  F fit  Q quit", colors.lightGray)
  else
    put(1, 2, "r=main  m=rf  w=wired  N=up   (map true — monitors)", colors.lightGray)
  end

  local cx = left + math.floor(gw / 2)
  local cy = top + math.floor(gh / 2)

  for gy = top, bottom do
    for gx = left, right do
      put(gx, gy, mapGridChar(gx - cx, gy - cy), colors.gray)
    end
  end
  put(cx, top, "N", colors.white)
  put(right, cy, "E", colors.white)
  put(cx, bottom, "S", colors.white)
  put(left, cy, "W", colors.white)

  local function cellOf(wx, wz)
    return cx + math.floor((wx - ox) / scale + 0.5),
           cy + math.floor((wz - oz) / scale + 0.5)
  end

  table.sort(nodes, function(a, b)
    if a.main ~= b.main then return not a.main end
    return (a.id or 0) < (b.id or 0)
  end)
  for _, n in ipairs(nodes) do
    local sx, sy = cellOf(n.x, n.z)
    if n.main or (n.kind == "router" and n.id == os.getComputerID()) then
      put(sx, sy, "r", colors.cyan)
    elseif n.wired then
      put(sx, sy, "w", colors.cyan)
    else
      put(sx, sy, "m", colors.lime)
    end
  end

  local y = th - 2
  if y < 1 then y = th end
  local parts = {}
  for _, n in ipairs(nodes) do
    local tag = (n.main or n.id == os.getComputerID()) and "r" or (n.wired and "w" or "m")
    parts[#parts + 1] = ("%s:%s"):format(tag, tostring(n.name):sub(1, 10))
  end
  put(1, y, table.concat(parts, "  "):sub(1, tw), colors.white)
  if opts.interactive then
    put(1, th, ("nodes:%d  scale:%d  [+/-] [F]fit [Q]"):format(#nodes, scale), colors.gray)
  else
    put(1, th, ("nodes:%d  scale:%d  `map false` for stats"):format(#nodes, scale), colors.gray)
  end

  if colorOk then
    out.setTextColor(colors.white)
    out.setBackgroundColor(colors.black)
  end
  return nodes, ox, oz, scale
end

drawMapOnMonitors = function()
  local drawn = {}
  local function drawOne(mon)
    if not mon or drawn[mon] then return end
    drawn[mon] = true
    local w, h = mon.getSize()
    local nodes = fleetMapNodes()
    local ox, oz = mapOrigin(nodes)
    local scale = mapAutoScale(nodes, ox, oz, w, math.max(4, h - 4))
    drawFleetMapOn(mon, scale, { interactive = false })
  end
  -- Primary map on roster (or first) screen; mirror onto others.
  drawOne(screens.roster)
  drawOne(screens.stats)
  drawOne(screens.gps)
  -- Any leftover attached monitors not assigned.
  for _, name in ipairs(listMonitorNames()) do
    drawOne(wrapScreen(name))
  end
end

local function fleetMapView()
  if not isMain() then
    print("map view is MAIN-only.")
    return
  end
  local nodes = fleetMapNodes()
  local ox, oz = mapOrigin(nodes)
  local tw, th = term.getSize()
  local scale = mapAutoScale(nodes, ox, oz, tw, math.max(5, th - 6))
  local timer = os.startTimer(2)
  while true do
    drawFleetMapOn(term, scale, { interactive = true })
    local ev, p1 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      timer = os.startTimer(2)
    elseif ev == "key" then
      if p1 == keys.q or p1 == keys.x or p1 == keys.escape then break
      elseif p1 == keys.equals or p1 == keys.numPadAdd then
        scale = math.max(2, math.floor(scale / 2))
      elseif p1 == keys.minus or p1 == keys.numPadSubtract then
        scale = math.min(256, scale * 2)
      elseif p1 == keys.f then
        nodes = fleetMapNodes()
        ox, oz = mapOrigin(nodes)
        scale = mapAutoScale(nodes, ox, oz, tw, math.max(5, th - 6))
      end
      timer = os.startTimer(0.1)
    elseif ev == "char" then
      if p1 == "q" or p1 == "Q" then break
      elseif p1 == "+" or p1 == "=" then scale = math.max(2, math.floor(scale / 2))
      elseif p1 == "-" then scale = math.min(256, scale * 2)
      elseif p1 == "f" or p1 == "F" then
        nodes = fleetMapNodes()
        ox, oz = mapOrigin(nodes)
        scale = mapAutoScale(nodes, ox, oz, tw, math.max(5, th - 6))
      end
      timer = os.startTimer(0.1)
    elseif ev == "terminate" then
      break
    end
  end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  if term.setTextColor then term.setTextColor(colors.white) end
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function consoleLoop()
  print(("Titan router #%d [%s]. %d modem(s) (rf:%d wire:%d). Type 'help'."):format(
    os.getComputerID(), routerRole:upper(), #modems, #wirelessModems, #wiredModems))
  while true do
    write(isMain() and "router> " or "modem> ")
    local a = {}
    for word in tostring(read()):gmatch("%S+") do a[#a + 1] = word end
    local cmd = (a[1] or ""):lower()

    if cmd == "" then
      -- ignore
    elseif cmd == "help" then
      print("role     - show main / modem role")
      print("main     - make THIS the main router (directory + OTA authority)")
      print("modem    - demote to modem-only repeater (reboot)")
      print("hostname [name|auto] - set name (modems: auto = accept main assign)")
      print("stats    - relay counts (+ roster if main)")
      print("gpshost [x y z] - show / set this router's GPS host coords")
      print("reset [routes|names|all|hard] - wipe routing data (confirm)")
      if isMain() then
        print("  routes = roster; names = name assigns; all = both")
        print("map [true|false|view] - monitors: map vs stats boards (default false)")
        print("versions - local vs GitHub package versions")
        print("devices  - list remembered systems (ONLINE / OFFLINE)")
        print("forget <id|host> - remove a system from the remembered roster")
        print("names    - modem name pool + assignments")
        print("name <id|host> <newname>  - force-assign a modem name (reboots it)")
        print("namepool add|remove <name>  - edit the unique-name list")
        print("screens  - list monitors + roster/stats/gps assignments")
        print("screen <roster|stats|gps> <name|side|auto>  assign a board")
        print("ping     - re-discover the network")
        print("update [aoe|status] - fleet OTA from GitHub; track reboot ACKs")
        print("reauth   - tell the fleet to re-auth now (no download)")
        print("github [url] - show / set GitHub raw base for versions")
      else
        print("  routes = keep MAIN id; hard/all = also forget MAIN + name")
      end
      print("ssh <id|label> [cmd] - remote shell; jumps via modems (reboot ok)")
      print("exit")
    elseif cmd == "role" then
      print(("Role: %s  (id #%d)"):format(routerRole, os.getComputerID()))
      if isMain() then
        print("This is the MAIN router — devices re-auth here after update/reboot.")
      else
        print("This is a MODEM repeater — use `main` to promote it.")
      end
    elseif cmd == "main" then
      if isMain() then
        claimMain()
        print("Already MAIN. Re-broadcast claim so devices refresh.")
      else
        write("Promote this modem to MAIN router? (other mains should run `modem`) [y/N] ")
        if read():lower() ~= "y" then print("Cancelled.") else
          patchRouterCfg({ role = "main" })
          print("Saved role=main. Rebooting..."); sleep(1); os.reboot()
        end
      end
    elseif cmd == "modem" then
      if not isMain() then
        print("Already a MODEM repeater.")
      else
        write("Demote this MAIN router to MODEM-only repeater? [y/N] ")
        if read():lower() ~= "y" then print("Cancelled.") else
          patchRouterCfg({ role = "modem" })
          if fs.exists(ROSTER) then pcall(fs.delete, ROSTER) end
          print("Saved role=modem (roster removed). Rebooting..."); sleep(1); os.reboot()
        end
      end
    elseif cmd == "devices" or cmd == "list" then
      if not isMain() then print("Roster is MAIN-only. Use `main` to promote."); else
        local on, off, unk = countOnlineOffline()
        print(("Remembered — ONLINE:%d  OFFLINE:%d  UNKNOWN:%d"):format(on, off, unk))
        local n = 0
        for _, id in ipairs(sortedIds()) do
          local d = seen[id]
          n = n + 1
          local st = statusOf(d, id)
          local age = (d.seen and d.seen > 0) and (ago(d.seen) .. "s ago") or "never"
          print(("#%-3d %-8s %-8s %-18s %s"):format(
            id, st, d.kind or "?", d.hostname or d.name or "?", age))
        end
        if n == 0 then print("(none yet — wait for devices to register)") end
      end
    elseif cmd == "forget" then
      if not isMain() then print("Roster is MAIN-only."); else
        local ref = a[2]
        if not ref then print("Usage: forget <id|hostname>"); else
          local id = tonumber(ref)
          if not id then
            local want = ref:lower()
            for sid, d in pairs(seen) do
              local host = tostring(d.hostname or d.name or ""):lower()
              if host == want or host:find(want, 1, true) then id = sid; break end
            end
          end
          if id and seen[id] then
            print(("Forgot %s (#%d)."):format(seen[id].hostname or "?", id))
            seen[id] = nil
            releaseModemName(id)
            rosterDirty = true
            saveRoster()
          else
            print("Unknown system: " .. tostring(ref))
          end
        end
      end
    elseif cmd == "reset" then
      local mode = (a[2] or "routes"):lower()
      if mode == "route" then mode = "routes" end
      local label
      if isMain() then
        if mode == "names" then
          label = "Clear modem NAME assignments on MAIN?"
        elseif mode == "all" or mode == "hard" then
          label = "Clear MAIN roster AND modem name assignments?"
          mode = "all"
        else
          label = "Clear MAIN roster / routing data? (keeps modem names)"
          mode = "routes"
        end
      else
        if mode == "all" or mode == "hard" then
          label = "Clear modem routing AND forget MAIN id + assigned name?"
          mode = "hard"
        else
          label = "Clear modem routing data? (keeps route to MAIN)"
          mode = "routes"
        end
      end
      write(label .. " [y/N] ")
      if read():lower() ~= "y" then
        print("Cancelled.")
      else
        local ok, msg = resetRouting(mode)
        if ok then
          print(msg)
          if isMain() then
            claimMain()
            print("Re-broadcast MAIN claim. Devices will re-register on next hello.")
          else
            print("Rebooting modem to reload slim cfg...")
            sleep(1)
            os.reboot()
          end
        else
          print(tostring(msg))
        end
      end
    elseif cmd == "map" or cmd == "fmap" or cmd == "fleetmap" or cmd == "display" then
      if not isMain() then print("map is MAIN-only.")
      else
        local sub = (a[2] or ""):lower()
        -- `display map` / `display stats` aliases
        if cmd == "display" then
          if sub == "map" then sub = "true"
          elseif sub == "stats" or sub == "boards" then sub = "false"
          elseif sub == "" then sub = "" end
        end
        if sub == "" or sub == "status" then
          loadDisplayMap()
          print(("Monitor display: map=%s"):format(tostring(displayMap)))
          print("  map false  — roster / stats / gps boards (default)")
          print("  map true   — fleet map on monitors (r/m grid)")
          print("  map view   — interactive map on this terminal")
        elseif sub == "true" or sub == "on" or sub == "1" or sub == "yes" then
          setDisplayMap(true)
          print("Monitors: MAP mode (fleet map).")
          drawBoards()
        elseif sub == "false" or sub == "off" or sub == "0" or sub == "no" or sub == "stats" then
          setDisplayMap(false)
          print("Monitors: STATS mode (roster / stats / gps).")
          drawBoards()
        elseif sub == "view" or sub == "term" or sub == "live" then
          fleetMapView()
        elseif sub == "toggle" then
          setDisplayMap(not displayMap)
          print(("Monitors: map=%s"):format(tostring(displayMap)))
          drawBoards()
        else
          print("Usage: map true | map false | map view | map toggle")
        end
      end
    elseif cmd == "names" then
      if not isMain() then print("Name registry is MAIN-only."); else
        loadNameRegistry()
        print("Modem name assignments:")
        local any = false
        local ids = {}
        for id in pairs(nameAssign) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
        for _, id in ipairs(ids) do
          any = true
          print(("  #%d -> %s"):format(id, nameAssign[id]))
        end
        if not any then print("  (none yet)") end
        print("Name pool:")
        print("  " .. table.concat(namePool(), ", "))
      end
    elseif cmd == "name" then
      if not isMain() then print("Name assign is MAIN-only."); else
        local ref, newName = a[2], a[3] and table.concat(a, " ", 3) or nil
        if not ref or not newName then
          print("Usage: name <id|hostname> <newname>")
        else
          local id = tonumber(ref)
          if not id then
            local want = ref:lower()
            for sid, d in pairs(seen) do
              local host = tostring(d.hostname or d.name or ""):lower()
              if host == want or host:find(want, 1, true) then id = sid; break end
            end
            for sid, n in pairs(nameAssign) do
              if tostring(n):lower() == want then id = sid; break end
            end
          end
          if not id then
            print("Unknown modem: " .. tostring(ref))
          elseif nameTaken(newName, id) then
            print("Name already in use: " .. newName)
          else
            loadNameRegistry()
            nameAssign[id] = newName
            saveNameRegistry()
            if seen[id] then
              seen[id].hostname = newName
              seen[id].name = newName
              rosterDirty = true
            end
            rednet.send(id, {
              type = "here", assignHostname = newName, reboot = true,
              main = true, mainRouterId = os.getComputerID(),
              label = os.getComputerLabel(), hostname = os.getComputerLabel(),
            }, PROTO_ROUTER)
            print(("Assigned #%d -> %s (reboot sent)"):format(id, newName))
          end
        end
      end
    elseif cmd == "namepool" then
      if not isMain() then print("Name pool is MAIN-only."); else
        local sub = (a[2] or ""):lower()
        local pool = {}
        for _, n in ipairs(namePool()) do pool[#pool + 1] = n end
        if sub == "add" and a[3] then
          local n = table.concat(a, " ", 3)
          local exists = false
          for _, p in ipairs(pool) do if p:lower() == n:lower() then exists = true; break end end
          if exists then print("Already in pool: " .. n)
          else
            pool[#pool + 1] = n
            saveNameRegistry(pool)
            print("Added to pool: " .. n)
          end
        elseif sub == "remove" and a[3] then
          local n = table.concat(a, " ", 3):lower()
          local out = {}
          for _, p in ipairs(pool) do
            if p:lower() ~= n then out[#out + 1] = p end
          end
          saveNameRegistry(out)
          print("Removed from pool (if present): " .. table.concat(a, " ", 3))
        else
          print("Usage: namepool add <name> | namepool remove <name>")
          print("Pool: " .. table.concat(pool, ", "))
        end
      end
    elseif cmd == "hostname" or cmd == "host" then
      if not a[2] then
        print("hostname: " .. (os.getComputerLabel() or "(none)"))
        local c = loadRouterCfg() or {}
        if not isMain() then
          if c.manualHostname then
            print("Naming: manual")
          elseif c.assignedName then
            print("Naming: assigned by main (" .. c.assignedName .. ")")
          else
            print("Naming: waiting for main router unique-name assign")
          end
        end
      else
        local name = table.concat(a, " ", 2)
        if name:lower() == "auto" and not isMain() then
          patchRouterCfg({ manualHostname = false, assignedName = nil })
          print("Will accept next name from main router (announce + reboot).")
          rednet.broadcast({
            type = "hello", kind = "modem",
            name = "Modem-pending-" .. os.getComputerID(),
            hostname = "Modem-pending-" .. os.getComputerID(),
            autoName = true, needName = true,
          }, PROTO_ROUTER)
        else
          os.setComputerLabel(name)
          if not isMain() then
            patchRouterCfg({ manualHostname = true, assignedName = name })
          end
          if titanLib then
            local ok, err = titanLib.setHostname(name, isMain() and "router" or "modem")
            if ok then print("hostname set: " .. ok) else print(tostring(err)) end
          else
            rednet.broadcast({
              type = "hello", kind = isMain() and "router" or "modem",
              name = name, hostname = name, autoName = false,
            }, PROTO_ROUTER)
            print("hostname set: " .. name)
          end
          if isMain() then claimMain() end
          if not isMain() then print("(manual — use `hostname auto` to resume main assign)") end
        end
      end
    elseif cmd == "ping" then
      if not isMain() then print("Ping/discover is MAIN-only."); else
        rednet.broadcast({ type = "ping" }, "titan_net")
        rednet.broadcast({ type = "ping" }, "titan_dc")
        rednet.broadcast({ type = "ping" }, PROTO_ROUTER)
        print("Pinged.")
      end
    elseif cmd == "stats" then
      if isMain() then
        local on, off = countOnlineOffline()
        print(("[%s] Relayed %d. ONLINE:%d WIRED:%d OFFLINE:%d. rf:%d wire:%d"):format(
          routerRole:upper(), relayStats.relayed, on, countWiredOnline(), off,
          #wirelessModems, #wiredModems))
      else
        print(("[MODEM] Relayed %d messages. rf:%d wire:%d"):format(
          relayStats.relayed, #wirelessModems, #wiredModems))
      end
    elseif cmd == "screens" or cmd == "monitors" then
      if not isMain() then print("Screens are MAIN-only."); else
        refreshScreens()
        local names = listMonitorNames()
        print(("Attached monitors: %d"):format(#names))
        for i, n in ipairs(names) do
          local roles = {}
          for _, role in ipairs(SCREEN_ROLES) do
            if screenNames[role] == n then roles[#roles + 1] = role end
          end
          print(("  %d) %-16s %s"):format(i, n, #roles > 0 and table.concat(roles, "+") or "(unused)"))
        end
        print("Boards:")
        for _, role in ipairs(SCREEN_ROLES) do
          local n = screenNames[role]
          local ok = n and peripheral.isPresent(n)
          print(("  %-6s -> %s%s"):format(
            role, n or "(none)", ok == false and " [MISSING]" or ""))
        end
        if #names == 0 then
          print("Attach monitors (wired modem network ok). Auto: 1=stack, 2=roster+stats/gps, 3=split.")
        elseif #names == 1 then
          print("1 monitor: roster/stats/gps stacked on one screen.")
        elseif #names == 2 then
          print("2 monitors: roster | stats+gps.")
        else
          print("3+ monitors: roster | stats | gps.")
        end
      end
    elseif cmd == "screen" then
      if not isMain() then print("Screens are MAIN-only."); else
        local role = (a[2] or ""):lower()
        local target = a[3]
        if role ~= "roster" and role ~= "stats" and role ~= "gps" then
          print("Usage: screen <roster|stats|gps> <name|side|auto>")
          print("Example: screen roster left   or   screen gps monitor_2")
        elseif not target then
          print("Usage: screen " .. role .. " <name|side|auto>")
        elseif target:lower() == "auto" or target:lower() == "clear" then
          screenNames[role] = nil
          screens[role] = nil
          saveScreenAssignments()
          refreshScreens()
          print(role .. " set to auto.")
        else
          if not peripheral.isPresent(target) or peripheral.getType(target) ~= "monitor" then
            print("Not a monitor: " .. target)
            print("Available: " .. table.concat(listMonitorNames(), ", "))
          else
            screenNames[role] = target
            saveScreenAssignments()
            refreshScreens()
            print(("%s -> %s"):format(role, target))
          end
        end
      end
    elseif cmd == "gpshost" then
      if a[2] and a[3] and a[4] then
        patchRouterCfg({ gps = { x = tonumber(a[2]), y = tonumber(a[3]), z = tonumber(a[4]) } })
        print("Saved GPS coords. Rebooting to start hosting..."); sleep(1); os.reboot()
      elseif gpsCoords then
        print(("Hosting GPS at %d, %d, %d."):format(gpsCoords.x, gpsCoords.y, gpsCoords.z))
      else
        print("Not hosting GPS. Usage: gpshost <x> <y> <z>")
      end
    elseif cmd == "versions" or cmd == "ver" then
      if not isMain() then print("versions is MAIN-only."); else
        print("Checking GitHub...")
        local remote, err = fetchGithubVersions()
        local localVer = localSystemVersion()
        print(("Local system:  %s"):format(tostring(localVer or "?")))
        if not remote then
          print("GitHub:        (failed) " .. tostring(err))
          print("Base: " .. githubBase())
        else
          print(("GitHub system: %s"):format(tostring(remote.system or "?")))
          print("Base: " .. ghState.base)
          local cmp = versionCmp(localVer, remote.system)
          if cmp < 0 then print("Status: GitHub is NEWER — run `update aoe`")
          elseif cmp > 0 then print("Status: local is ahead of GitHub")
          else print("Status: up to date with GitHub") end
          if type(remote.packages) == "table" then
            local localCat = nil
            if fs.exists("versions.lua") then
              local ok, c = pcall(dofile, "versions.lua")
              if ok then localCat = c end
            end
            local diffs = 0
            for path, ver in pairs(remote.packages) do
              local lv = localCat and localCat.packages and localCat.packages[path]
              if tostring(lv or "") ~= tostring(ver) then
                if diffs == 0 then print("Package diffs (local -> github):") end
                diffs = diffs + 1
                print(("  %-22s %s -> %s"):format(path, tostring(lv or "—"), tostring(ver)))
              end
            end
            if diffs == 0 then print("All listed packages match GitHub.") end
          end
        end
        -- Fleet versions from roster
        print("Fleet (online):")
        local any = false
        for _, id in ipairs(sortedIds()) do
          local d = seen[id]
          if isOnline(d) then
            any = true
            print(("  #%-3d %-16s v%s"):format(
              id, tostring(d.hostname or "?"):sub(1, 16), tostring(d.version or "?")))
          end
        end
        if not any then print("  (none online yet)") end
      end
    elseif cmd == "github" then
      if not isMain() then print("github is MAIN-only."); else
        if a[2] then
          local url = table.concat(a, " ", 2)
          if not url:find("/$") then url = url .. "/" end
          patchRouterCfg({ githubBase = url })
          print("GitHub base saved: " .. url)
        else
          print("GitHub base: " .. githubBase())
          print("Usage: github <raw-base-url/>")
        end
      end
    elseif cmd == "update" then
      if not isMain() then
        print("OTA update is MAIN-only. Run `main` on this machine, or use the main router.")
      else
        local sub = (a[2] or "aoe"):lower()
        if sub == "status" then
          local exp, ack, camp = campaignStatus()
          if not camp then
            print("No active update campaign. Run `update aoe`.")
          else
            print(("Campaign target v%s  acked %d / %d"):format(
              tostring(camp.version), ack, exp))
            for id, name in pairs(camp.expected) do
              local ainfo = camp.acked[id]
              if ainfo then
                print(("  OK  #%-3d %-16s v%s"):format(id, tostring(name):sub(1, 16), tostring(ainfo.version)))
              else
                local d = seen[id]
                print(("  ... #%-3d %-16s have v%s"):format(
                  id, tostring(name):sub(1, 16), tostring(d and d.version or "?")))
              end
            end
          end
        else
          -- update / update aoe — check GitHub then broadcast fleet OTA
          print("Checking GitHub versions...")
          local remote, err = fetchGithubVersions()
          local target = remote and remote.system or localSystemVersion()
          if not remote then
            print("GitHub check failed: " .. tostring(err))
            print("Will still broadcast OTA using local packages / device install sources.")
            target = localSystemVersion() or "unknown"
          else
            print(("GitHub Titan v%s  (local %s)"):format(
              tostring(remote.system), tostring(localSystemVersion() or "?")))
          end
          write(("Push AoE OTA to fleet (target v%s)? Devices download, reboot, ACK. [y/N] "):format(
            tostring(target)))
          if read():lower() ~= "y" then print("Cancelled."); else
            local expected = startUpdateCampaign(target)
            local nExp = 0
            for _ in pairs(expected) do nExp = nExp + 1 end
            local rname = os.getComputerLabel() or ("Router-" .. os.getComputerID())
            rednet.broadcast({
              type = "update", from = os.getComputerID(), name = rname,
              mainRouterId = os.getComputerID(), hostname = rname,
              targetVersion = target, aoe = true,
              githubBase = githubBase(),
            }, PROTO_ROUTER)
            print(("AoE update broadcast sent (v%s). Expecting up to %d ACK(s)."):format(
              tostring(target), nExp))
            print("Devices will reply `updated` after reboot. Watch with `update status`.")
            -- Update this main router too (no reboot — stay up to collect ACKs).
            if titanLib and titanLib.updateSelf then
              print("Updating main router packages (no reboot)...")
              local uok, uerr = titanLib.updateSelf()
              if uok then
                print("Main router packages refreshed to v" .. tostring(localSystemVersion() or target))
              else
                print("Main self-update failed: " .. tostring(uerr))
              end
            end
          end
        end
      end
    elseif cmd == "reauth" then
      if not isMain() then print("reauth is MAIN-only."); else
        local rname = os.getComputerLabel() or ("Router-" .. os.getComputerID())
        rednet.broadcast({
          type = "reauth", from = os.getComputerID(), name = rname,
          mainRouterId = os.getComputerID(),
        }, PROTO_ROUTER)
        claimMain()
        print("Re-auth broadcast sent. Devices will re-auth to this main (bots also hit data server).")
      end
    elseif cmd == "ssh" then
      if not a[2] then print("Usage: ssh <id|label> [command...]")
      elseif not titanLib then
        print("ssh needs lib/titan.lua on this router (re-install router role).")
      else
        local target = a[2]
        local parts = {}
        for i = 3, #a do parts[#parts + 1] = a[i] end
        local cmdline = #parts > 0 and table.concat(parts, " ") or nil
        titanLib.sshConnect(target, cmdline)
      end
    elseif cmd == "exit" or cmd == "quit" then
      return
    else
      print("Unknown: " .. cmd)
    end
  end
end

--------------------------------------------------------------------------------
-- Config: role + GPS hosting.
--------------------------------------------------------------------------------
local rcfg = loadRouterCfg() or {}
if rcfg.role == "modem" or rcfg.role == "main" then
  routerRole = rcfg.role
else
  -- First boot / upgrade: ask once.
  print("")
  print("Is this the MAIN router? (Y = directory + OTA / N = modem repeater only)")
  write("[Y/n] ")
  local ans = read():lower()
  routerRole = (ans == "n" or ans == "no") and "modem" or "main"
  rcfg = patchRouterCfg({ role = routerRole })
  print("Role saved: " .. routerRole)
end

if rcfg.gps then
  gpsCoords = rcfg.gps
elseif rcfg.gpsHost == false then
  -- previously opted out
else
  print("")
  print("Routers double as GPS hosts (place 4+ spread out for a constellation).")
  local x, y, z = gps.locate(2)
  if x then
    x, y, z = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
    print(("Auto-located: %d, %d, %d"):format(x, y, z))
    gpsCoords = { x = x, y = y, z = z }
  else
    print("Enter this router's coordinates to host GPS (blank X = skip).")
    write("X: "); local sx = read()
    if sx ~= "" then
      write("Y: "); local sy = read(); write("Z: "); local sz = read()
      gpsCoords = { x = tonumber(sx) or 0, y = tonumber(sy) or 0, z = tonumber(sz) or 0 }
    end
  end
  if gpsCoords then
    patchRouterCfg({ gps = gpsCoords })
  else
    patchRouterCfg({ gpsHost = false })
  end
  if gpsCoords then print(("Hosting GPS at %d, %d, %d."):format(gpsCoords.x, gpsCoords.y, gpsCoords.z)) end
end

--------------------------------------------------------------------------------
-- Shared lib instance (SSH host + client must share one reply inbox).
if fs.exists("lib/titan.lua") then
  titanLib = dofile("lib/titan.lua")
end

local tasks = { repeaterLoop, consoleLoop, wiredLinkLoop }
if isMain() then
  tasks[#tasks + 1] = directoryLoop
  tasks[#tasks + 1] = pingLoop
  tasks[#tasks + 1] = rosterSaveLoop
  tasks[#tasks + 1] = drawLoop
  tasks[#tasks + 1] = githubWatchLoop
else
  tasks[#tasks + 1] = modemLoop
end
if gpsCoords then tasks[#tasks + 1] = gpsHostLoop end
if titanLib then
  tasks[#tasks + 1] = function()
    titanLib.sshHostLoop(isMain() and "router" or "modem")
  end
  if not isMain() then
    -- Modem also reports OTA ACK after reboot (same as networkLoop devices).
    tasks[#tasks + 1] = function()
      sleep(2)
      titanLib.reportUpdatedIfPending("modem")
      -- Keep announcing version via modemLoop hello; nothing else here.
      while true do sleep(3600) end
    end
  end
end

print(("Role: %s"):format(routerRole:upper()))
if isMain() then
  local remembered = loadRoster()
  if remembered > 0 then
    print(("Loaded %d remembered system(s) from %s."):format(remembered, ROSTER))
  end
  loadNameRegistry()
  loadScreenAssignments()
  loadDisplayMap()
  local nMon = refreshScreens()
  do
    local n = 0
    for _ in pairs(nameAssign) do n = n + 1 end
    if n > 0 then print(("Modem names: %d assigned. Type `names`."):format(n)) end
  end
  print(("Monitor mode: map=%s  (`map true` / `map false`)"):format(tostring(displayMap)))
  if nMon == 0 then
    print("No monitors yet — attach 1–3 for boards or fleet map.")
  elseif displayMap then
    print(("%d monitor(s): FLEET MAP. Type `map false` for stats boards."):format(nMon))
  elseif nMon == 1 then
    print("1 monitor: stacked roster + stats + gps. Type `screens` / `map true`.")
  elseif nMon == 2 then
    print("2 monitors: roster | stats+gps. Type `screens` / `map true`.")
  else
    print(("%d monitors: roster | stats | gps. Type `screens` / `map true`."):format(nMon))
  end
else
  clearRosterIfModem()
  local slim = sanitizeModemCfg()
  if slim and slim.mainRouterId then
    print(("MODEM mode: mesh hop + relay. Route to MAIN #%d."):format(slim.mainRouterId))
  else
    print("MODEM mode: mesh hop + relay (no roster). Waiting for MAIN…")
  end
  print("Cfg stores only MAIN route (+ name/GPS). Type `reset` to wipe routing data.")
end
parallel.waitForAny(table.unpack(tasks))
for _, role in ipairs(SCREEN_ROLES) do
  local m = screens[role]
  if m then pcall(function() m.clear() end) end
end
if isMain() and rosterDirty then saveRoster() end
print("Router stopped.")
