--[[
  router_main.lua  -  Titan MAIN / ROUTER hub runtime (CC: Tweaked)
  Titan-Version: 1.4.0

  Hub roles (loaded by router.lua when role is main or router):

    MAIN   - directory, OTA, re-auth, GPS, ender backbone hub, monitor boards.
    ROUTER - ender backbone satellite; hosts local RF modem cells.

  MODEM cells use router_modem.lua instead. Prefer: run `router`.

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
-- Single monitor boards (main):
--   Default = TitanSystems screensaver.
--   `screen <role> on`   → show that board for saverIdleSecs (default 120), then saver.
--   `screen <role> perm` → show that board permanently.
--   Only one board is live at a time (switching replaces the previous).
-- roster = LOCAL cell (this hub's modems + nearby computers)
-- global = GLOBAL mesh (backbone peers + remote cells / devices)
local SCREEN_ROLES = { "roster", "global", "stats", "gps", "map" }
local screens = { roster = nil, global = nil, stats = nil, gps = nil, map = nil }
local screenNames = { roster = nil, global = nil, stats = nil, gps = nil, map = nil }
local screenOn   = { roster = false, global = false, stats = false, gps = false, map = false }
local screenPerm = { roster = false, global = false, stats = false, gps = false, map = false }
local screenFocus = "roster"   -- the one live board (when any is on)
local displayMon = nil         -- wrapped primary monitor
local displayMonName = nil
local SAVER_TEXT = "TitanSystems"
local saverIdleSecs = 120      -- temp boards auto-off after this many seconds
local monRate = 1              -- live board redraw interval (seconds)
local boardWakeAt = nil        -- os.clock() when a temp board was last woken
local saverActive = false
local saverState = {}          -- bounce state for the primary monitor

local function clampMonRate(secs)
  if titanLib and titanLib.normalizeMonRate then
    return titanLib.normalizeMonRate(secs, monRate)
  end
  local n = tonumber(secs)
  if not n or n ~= n then return monRate end
  if n < 0.25 then n = 0.25 end
  if n > 120 then n = 120 end
  return n
end

-- Router config (GPS host coords + role: "main" | "router" | "modem").
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
local function isModemRole() return routerRole == "modem" end
local function isBackbone() return routerRole == "main" or routerRole == "router" end
local function roleKind()
  if routerRole == "main" then return "router" end
  if routerRole == "router" then return "router" end
  return "modem"
end

--------------------------------------------------------------------------------
-- Network links: ender backbone peers + local modem cells
-- Persisted in router.cfg.netLinks
--------------------------------------------------------------------------------
local netPeers = {}       -- [id] = { name, kind, seen }
local netCells = {}       -- [modemId] = { name, seen }  (backbone only)
local homeRouterId = nil  -- modem -> home MAIN/ROUTER id

local function loadNetLinks()
  local c = loadRouterCfg() or {}
  local nl = type(c.netLinks) == "table" and c.netLinks or {}
  netPeers, netCells = {}, {}
  if type(nl.peers) == "table" then
    for id, info in pairs(nl.peers) do
      local nid = tonumber(id)
      if nid then
        if type(info) == "table" then
          netPeers[nid] = { name = info.name, kind = info.kind or "router", seen = info.seen or 0 }
        else
          netPeers[nid] = { name = tostring(info), kind = "router", seen = 0 }
        end
      end
    end
  end
  if type(nl.cells) == "table" then
    for id, info in pairs(nl.cells) do
      local nid = tonumber(id)
      if nid then
        if type(info) == "table" then
          netCells[nid] = { name = info.name, seen = info.seen or 0 }
        else
          netCells[nid] = { name = tostring(info), seen = 0 }
        end
      end
    end
  end
  homeRouterId = tonumber(nl.homeRouter) or tonumber(c.homeRouter)
end

local function saveNetLinks()
  local peers, cells = {}, {}
  for id, p in pairs(netPeers) do
    peers[id] = { name = p.name, kind = p.kind, seen = p.seen }
  end
  for id, c in pairs(netCells) do
    cells[id] = { name = c.name, seen = c.seen }
  end
  patchRouterCfg({
    netLinks = {
      peers = peers,
      cells = cells,
      homeRouter = homeRouterId,
    },
    homeRouter = homeRouterId,
  })
end

local function addNetPeer(id, name, kind)
  id = tonumber(id)
  if not id or id == os.getComputerID() then return false, "bad id" end
  netPeers[id] = {
    name = name or (netPeers[id] and netPeers[id].name) or ("#" .. id),
    kind = kind or "router",
    seen = os.epoch("utc"),
  }
  saveNetLinks()
  return true
end

local function removeNetPeer(id)
  id = tonumber(id)
  if not id or not netPeers[id] then return false, "not linked" end
  netPeers[id] = nil
  saveNetLinks()
  return true
end

local function setHomeRouter(id, name)
  id = tonumber(id)
  if not id then return false, "bad id" end
  homeRouterId = id
  saveNetLinks()
  -- Also keep mainRouterId for legacy hop paths when home is MAIN.
  if not isBackbone() then
    patchRouterCfg({ homeRouter = id, mainRouterId = id })
  end
  return true
end

local function addNetCell(id, name)
  id = tonumber(id)
  if not id or id == os.getComputerID() then return false, "bad id" end
  netCells[id] = {
    name = name or (netCells[id] and netCells[id].name) or ("#" .. id),
    seen = os.epoch("utc"),
  }
  saveNetLinks()
  return true
end

local function removeNetCell(id)
  id = tonumber(id)
  if not id or not netCells[id] then return false, "not a cell" end
  netCells[id] = nil
  saveNetLinks()
  return true
end

local function netLinkSnapshot()
  local peers, cells = {}, {}
  for id, p in pairs(netPeers) do
    peers[#peers + 1] = { id = id, name = p.name, kind = p.kind or "router" }
  end
  for id, c in pairs(netCells) do
    cells[#cells + 1] = { id = id, name = c.name, kind = "modem" }
  end
  table.sort(peers, function(a, b) return a.id < b.id end)
  table.sort(cells, function(a, b) return a.id < b.id end)
  local x, y, z = nil, nil, nil
  if gpsCoords then x, y, z = gpsCoords.x, gpsCoords.y, gpsCoords.z end
  return {
    type = "net_topo",
    id = os.getComputerID(),
    name = os.getComputerLabel() or ("#" .. os.getComputerID()),
    role = routerRole,
    kind = roleKind(),
    homeRouter = homeRouterId,
    peers = peers,
    cells = cells,
    x = x, y = y, z = z,
  }
end

local function printNetLinks()
  local snap = netLinkSnapshot()
  print(("== Network links  #%d [%s] %s =="):format(
    snap.id, tostring(snap.role):upper(), tostring(snap.name)))
  if snap.x then
    print(("GPS %d,%d,%d"):format(snap.x, snap.y or 0, snap.z))
  end
  if isModemRole() then
    print("Home router: " .. tostring(homeRouterId or "(none — run: link home <id>)"))
  end
  if isBackbone() then
    print(("Backbone peers (%d):"):format(#snap.peers))
    if #snap.peers == 0 then print("  (none — link routers with ender modems)") end
    for _, p in ipairs(snap.peers) do
      print(("  #%d  %s"):format(p.id, tostring(p.name)))
    end
    print(("Local modem cells (%d):"):format(#snap.cells))
    if #snap.cells == 0 then print("  (none — link modems: link modem <id>)") end
    for _, c in ipairs(snap.cells) do
      print(("  #%d  %s"):format(c.id, tostring(c.name)))
    end
  end
end

local function broadcastNetHello()
  local snap = netLinkSnapshot()
  snap.type = "net_link_hello"
  rednet.broadcast(snap, PROTO_ROUTER)
  for id in pairs(netPeers) do
    rednet.send(id, snap, PROTO_ROUTER)
  end
  if homeRouterId then
    rednet.send(homeRouterId, snap, PROTO_ROUTER)
  end
end

-- Deliver a payload toward dest via backbone peers / local cells.
local function netHopDeliver(dest, payload, ttl)
  dest = tonumber(dest)
  ttl = (tonumber(ttl) or 6) - 1
  if not dest or ttl < 0 or type(payload) ~= "table" then return false end
  if dest == os.getComputerID() then
    rednet.send(dest, payload, PROTO_ROUTER)
    return true
  end
  -- Direct try (ender backbone or local RF).
  rednet.send(dest, payload, PROTO_ROUTER)
  if payload._netProto == "titan_net" or payload.type and tostring(payload.type):sub(1, 10) == "perimeter_" then
    rednet.send(dest, payload, "titan_net")
  end
  -- Local cell modem
  if netCells[dest] then
    return true
  end
  -- Ask peers to continue the hop.
  local hop = {
    type = "net_hop",
    dest = dest,
    payload = payload,
    ttl = ttl,
    via = os.getComputerID(),
    from = os.getComputerID(),
  }
  for id in pairs(netPeers) do
    if id ~= dest then rednet.send(id, hop, PROTO_ROUTER) end
  end
  return true
end

-- Filled after roster helpers exist; used by board_req for admin tablets.
local buildBoardSnap

local function handleNetControl(id, msg)
  if type(msg) ~= "table" or not msg.type then return false end
  local t = msg.type
  if t == "net_topo_req" then
    rednet.send(id, netLinkSnapshot(), PROTO_ROUTER)
    return true
  elseif t == "board_req" then
    -- Admin / pocket tablets pull the same boards MAIN paints on monitors.
    if isMain() and buildBoardSnap then
      rednet.send(id, buildBoardSnap(), PROTO_ROUTER)
    elseif isBackbone() and buildBoardSnap then
      -- Non-MAIN hubs still answer with whatever local topology they know.
      rednet.send(id, buildBoardSnap(), PROTO_ROUTER)
    end
    return true
  elseif t == "net_link_hello" then
    if msg.role == "main" or msg.role == "router" or msg.kind == "router" then
      if netPeers[id] or isBackbone() then
        netPeers[id] = netPeers[id] or { name = msg.name, kind = "router", seen = 0 }
        netPeers[id].name = msg.name or netPeers[id].name
        netPeers[id].seen = os.epoch("utc")
        if msg.role == "main" and not isMain() then
          patchRouterCfg({ mainRouterId = id })
        end
      end
    elseif msg.role == "modem" or msg.kind == "modem" then
      if isBackbone() and (netCells[id] or tonumber(msg.homeRouter) == os.getComputerID()) then
        addNetCell(id, msg.name)
      end
    end
    return true
  elseif t == "net_link" then
    local action = tostring(msg.action or ""):lower()
    local withId = tonumber(msg.with) or tonumber(msg.peer) or tonumber(msg.home) or tonumber(msg.modem)
    local ok, err = false, "unknown action"
    if action == "peer" or action == "router" then
      ok, err = addNetPeer(withId, msg.withName or msg.name, "router")
      if ok then
        -- Reciprocate so the other side also stores us.
        rednet.send(withId, {
          type = "net_link", action = "peer_ack",
          with = os.getComputerID(),
          withName = os.getComputerLabel(),
          name = os.getComputerLabel(),
          role = routerRole,
        }, PROTO_ROUTER)
        broadcastNetHello()
      end
    elseif action == "peer_ack" then
      ok, err = addNetPeer(withId or id, msg.withName or msg.name, "router")
    elseif action == "home" or action == "modem_home" then
      if isModemRole() then
        ok, err = setHomeRouter(withId, msg.withName)
        if ok then
          rednet.send(withId, {
            type = "net_link", action = "cell",
            with = os.getComputerID(),
            withName = os.getComputerLabel(),
            name = os.getComputerLabel(),
          }, PROTO_ROUTER)
          broadcastNetHello()
        end
      else
        ok, err = false, "home is for modem role only"
      end
    elseif action == "cell" or action == "modem" then
      if isBackbone() then
        ok, err = addNetCell(withId or id, msg.withName or msg.name)
        if ok and withId then
          rednet.send(withId, {
            type = "net_link", action = "home",
            with = os.getComputerID(),
            withName = os.getComputerLabel(),
          }, PROTO_ROUTER)
        end
      else
        ok, err = false, "cells are for MAIN/ROUTER only"
      end
    elseif action == "unpeer" or action == "unlink" then
      ok, err = removeNetPeer(withId)
    elseif action == "unhome" then
      homeRouterId = nil
      saveNetLinks()
      ok = true
    elseif action == "uncell" then
      ok, err = removeNetCell(withId)
    else
      ok, err = false, "action: peer|home|cell|unpeer|uncell"
    end
    rednet.send(id, {
      type = "net_link_ack", ok = ok, err = err,
      action = action, with = withId,
      topo = netLinkSnapshot(),
    }, PROTO_ROUTER)
    return true
  elseif t == "net_hop" then
    local dest = tonumber(msg.dest)
    local payload = msg.payload
    if dest and type(payload) == "table" then
      if dest == os.getComputerID() then
        -- Deliver locally by re-injecting as normal router traffic when possible.
        rednet.send(dest, payload, PROTO_ROUTER)
      elseif netCells[dest] or netPeers[dest] then
        rednet.send(dest, payload, PROTO_ROUTER)
        rednet.send(dest, payload, "titan_net")
      else
        netHopDeliver(dest, payload, msg.ttl)
      end
    end
    return true
  end
  return false
end

loadNetLinks()

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
-- Active fleet update campaign:
--   version, sentAt, expected = { [id]=name },
--   acked = { [id]={ name, version, packages={...}, at } },
--   failed = { [id]={ name, err, at } },
--   showAcks, restore = previous monitor state
local updateCampaign = nil
local otaOverlay = false           -- hard flag: monitor shows ACK board
local paintUpdateAcks             -- forward decl; assigned with drawUpdateAcks
local UPDATE_CAMPAIGN_TIMEOUT = 180  -- seconds; then restore monitor even if incomplete

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

local function copyScreenBoolMap(src)
  local out = {}
  for _, role in ipairs(SCREEN_ROLES) do
    out[role] = src[role] and true or false
  end
  return out
end

local function noteDeviceVersion(id, version, name, kind, packages, isUpdateAck)
  if not id then return end
  local d = seen[id] or {}
  d.version = version or d.version
  d.hostname = name or d.hostname or d.name
  d.name = d.hostname
  d.kind = kind or d.kind or "device"
  d.seen = now()
  seen[id] = d
  rosterDirty = true
  -- Only explicit `updated` ACKs count toward the campaign (not ordinary hellos).
  if isUpdateAck and updateCampaign and not updateCampaign.finishedAt then
    local pkgs = type(packages) == "table" and packages or nil
    if (not pkgs or #pkgs == 0) and version then
      local prev = updateCampaign.prevById and updateCampaign.prevById[id]
      pkgs = { {
        name = "system", path = "versions.lua",
        from = tostring(prev or "?"), to = tostring(version),
      } }
    end
    updateCampaign.acked[id] = {
      name = d.hostname, version = version, packages = pkgs or {},
      at = os.epoch("utc"),
    }
    updateCampaign.failed[id] = nil
  end
end

local function noteUpdateFail(id, name, err)
  if not updateCampaign or updateCampaign.finishedAt or not id then return end
  local host = name or (seen[id] and (seen[id].hostname or seen[id].name)) or ("#" .. id)
  updateCampaign.failed[id] = {
    name = host, err = tostring(err or "failed"), at = os.epoch("utc"),
  }
end

local function campaignCounts()
  if not updateCampaign then return nil end
  local exp, ack, fail = 0, 0, 0
  for _ in pairs(updateCampaign.expected) do exp = exp + 1 end
  for id in pairs(updateCampaign.expected) do
    if updateCampaign.acked[id] then ack = ack + 1
    elseif updateCampaign.failed[id] then fail = fail + 1 end
  end
  return exp, ack, fail, updateCampaign
end

local function campaignStatus()
  local exp, ack, fail, camp = campaignCounts()
  if not camp then return nil end
  return exp, ack + fail, camp
end

local function campaignResolved()
  local exp, ack, fail = campaignCounts()
  if not exp then return true end
  if exp == 0 then
    -- Nobody else online: wait until MAIN records its own self-update ACK.
    local selfId = os.getComputerID()
    return updateCampaign.acked[selfId] ~= nil or updateCampaign.failed[selfId] ~= nil
  end
  return (ack + fail) >= exp
end

local function restoreUpdateMonitor()
  local camp = updateCampaign
  otaOverlay = false
  if not camp then return end
  camp.showAcks = false
  local r = camp.restore
  camp.restore = nil
  if not r then return end
  for _, role in ipairs(SCREEN_ROLES) do
    screenOn[role] = r.on[role] and true or false
    screenPerm[role] = r.perm[role] and true or false
  end
  screenFocus = r.focus or "roster"
  boardWakeAt = r.wakeAt
  saverActive = false
  saverState = {}
  ensureFocus()
  -- Do not persist the temporary ACK overlay into router.cfg.
end

local function beginUpdateMonitor()
  if not updateCampaign then return end
  updateCampaign.restore = {
    focus = screenFocus,
    on = copyScreenBoolMap(screenOn),
    perm = copyScreenBoolMap(screenPerm),
    wakeAt = boardWakeAt,
  }
  updateCampaign.showAcks = true
  otaOverlay = true
  saverActive = false
  saverState = {}
  print("[OTA] Monitor switched to ACK board (hostname + package from->to).")
  -- Paint immediately so the board changes even while updateSelf is running.
  if paintUpdateAcks then
    local ok, err = pcall(paintUpdateAcks)
    if not ok then print("[OTA] ACK board paint error: " .. tostring(err)) end
  end
end

local function finishUpdateCampaign(reason)
  if not updateCampaign then return end
  local exp, ack, fail = campaignCounts()
  print(("[OTA] Campaign done (%s): %d ok, %d fail / %d expected"):format(
    tostring(reason or "complete"), ack or 0, fail or 0, exp or 0))
  restoreUpdateMonitor()
  -- Keep campaign data for `update status` for a bit, but stop overlay.
  updateCampaign.finishedAt = os.epoch("utc")
  updateCampaign.showAcks = false
  otaOverlay = false
end

local function maybeFinishUpdateCampaign()
  if not updateCampaign or updateCampaign.finishedAt then return end
  if campaignResolved() then
    -- Hold the final ACK board ~2s so the last hostname paints, then restore.
    if not updateCampaign.completeAt then
      updateCampaign.completeAt = os.clock()
      print("[OTA] All ACKs in — restoring previous monitor board in 2s...")
    elseif os.clock() >= updateCampaign.completeAt + 2 then
      finishUpdateCampaign("all acks")
    end
  elseif updateCampaign.sentAt then
    local age = (os.epoch("utc") - updateCampaign.sentAt) / 1000
    if age >= UPDATE_CAMPAIGN_TIMEOUT then
      finishUpdateCampaign("timeout")
    end
  end
end

-- filterFn(id, d) optional — return true to include in the campaign.
local function startUpdateCampaign(targetVersion, filterFn, scope)
  local expected, prevById = {}, {}
  for id, d in pairs(seen) do
    if isOnline(d) and id ~= os.getComputerID() then
      if not filterFn or filterFn(id, d) then
        expected[id] = d.hostname or d.name or ("#" .. id)
        prevById[id] = d.version
      end
    end
  end
  updateCampaign = {
    version = targetVersion,
    scope = scope or "all",
    sentAt = os.epoch("utc"),
    expected = expected,
    prevById = prevById,
    acked = {},
    failed = {},
    showAcks = false,
    restore = nil,
    finishedAt = nil,
  }
  beginUpdateMonitor()
  return expected
end

local function broadcastFleetUpdate(payload)
  -- Every Titan device that runs networkLoop listens on titan_router.
  rednet.broadcast(payload, PROTO_ROUTER)
  -- Also flood titan_net / titan_dc so Parent Center and any net-only listeners hear it.
  rednet.broadcast(payload, "titan_net")
  rednet.broadcast(payload, "titan_dc")
end

local function isModemKind(kind)
  kind = tostring(kind or ""):lower()
  return kind == "modem"
end

local function collectUpdateTargets(scope)
  local ids, byId = {}, {}
  local function add(id, label, kind)
    id = tonumber(id)
    if not id or id == os.getComputerID() or byId[id] then return end
    if scope == "modems" and not isModemKind(kind) then return end
    byId[id] = true
    ids[#ids + 1] = {
      id = id,
      label = label or ("#" .. id),
      kind = kind or "device",
    }
  end
  for id, d in pairs(seen) do
    if isOnline(d) then
      add(id, d.hostname or d.name, d.kind)
    end
  end
  -- Pick up mesh modems that hello'd over SSH but aren't in roster yet.
  if titanLib and titanLib.sshListPeers then
    local peers = titanLib.sshListPeers(2)
    for _, p in ipairs(peers) do
      local kind = p.kind or "device"
      if scope ~= "modems" or isModemKind(kind) then
        add(p.id, p.name or p.hostname, kind)
      end
    end
  end
  table.sort(ids, function(a, b) return a.id < b.id end)
  return ids
end

local function unicastUpdate(targets, payload)
  for _, t in ipairs(targets) do
    rednet.send(t.id, payload, PROTO_ROUTER)
    rednet.send(t.id, payload, "titan_net")
  end
end

local function sshForceUpdateDevice(targetId, password)
  if not titanLib or not titanLib.sshOpenRouted then
    return false, "ssh not available"
  end
  local hopId, token, info = titanLib.sshOpenRouted(targetId, password)
  if not token then return false, tostring(info) end
  local res = titanLib.sshExec(hopId, token, "update -y")
  titanLib.sshClose(hopId, token)
  if not res then return false, "no reply" end
  if res.ok then return true, res.out or "ok" end
  return false, res.out or "ssh update failed"
end

-- scope: "modems" (default force) or "all"
local function runForceUpdate(scope, opts)
  opts = opts or {}
  local skipConfirm = opts.yes == true
  scope = (scope == "all" or scope == "fleet") and "all" or "modems"

  print("Checking GitHub versions...")
  local remote, err = fetchGithubVersions()
  local target = remote and remote.system or localSystemVersion()
  if not remote then
    print("GitHub check failed: " .. tostring(err))
    print("Will still push OTA using each device's install source.")
    target = localSystemVersion() or "unknown"
  else
    print(("GitHub Titan v%s  (local %s)"):format(
      tostring(remote.system), tostring(localSystemVersion() or "?")))
  end

  local targets = collectUpdateTargets(scope)
  local label = (scope == "modems") and "MODEMS (mesh extenders)" or "ALL online devices"
  print(("Force-update scope: %s"):format(label))
  print(("Targets: %d"):format(#targets))
  for _, t in ipairs(targets) do
    print(("  #%d  %-8s  %s"):format(t.id, tostring(t.kind), tostring(t.label)))
  end

  if not skipConfirm then
    write(("Push OTA to %s (target v%s)? [y/N] "):format(label, tostring(target)))
    if (read() or ""):lower() ~= "y" then
      print("Cancelled.")
      return
    end
  end

  local filterFn = nil
  if scope == "modems" then
    filterFn = function(_, d) return isModemKind(d.kind) end
  end
  local expected = startUpdateCampaign(target, filterFn, scope)
  -- Ensure campaign expected matches collected targets (incl. SSH-discovered).
  for _, t in ipairs(targets) do
    if not expected[t.id] then
      expected[t.id] = t.label
      updateCampaign.expected[t.id] = t.label
      updateCampaign.prevById[t.id] = seen[t.id] and seen[t.id].version
    end
  end

  local nExp = 0
  for _ in pairs(updateCampaign.expected) do nExp = nExp + 1 end
  local rname = os.getComputerLabel() or ("Router-" .. os.getComputerID())
  local payload = {
    type = "update", from = os.getComputerID(), name = rname,
    mainRouterId = os.getComputerID(), hostname = rname,
    targetVersion = target,
    aoe = (scope == "all"),
    all = (scope == "all"),
    modemsOnly = (scope == "modems"),
    githubBase = githubBase(),
  }

  if scope == "all" then
    broadcastFleetUpdate(payload)
    print(("Fleet update BROADCAST sent (v%s) on router+net+dc."):format(tostring(target)))
  else
    -- Unicast only — do not wake miners/workers/admin/etc.
    unicastUpdate(targets, payload)
    print(("Modem update UNICAST sent (v%s) to %d device(s)."):format(
      tostring(target), #targets))
  end
  print(("Expecting %d ACK(s). Monitor shows hostname + package from->to."):format(nExp))
  print("Watch: `update status`")

  -- Update MAIN itself (stay up to collect ACKs / run SSH).
  if titanLib and titanLib.updateSelf then
    print("Updating main router packages (no reboot)...")
    local prevMain = localSystemVersion()
    local uok, detail = titanLib.updateSelf()
    if uok then
      local pkgs = type(detail) == "table" and detail.packages or {}
      if #pkgs == 0 then
        pkgs = { {
          name = "system", path = "versions.lua",
          from = tostring(prevMain or "?"),
          to = tostring(localSystemVersion() or target),
        } }
      end
      updateCampaign.acked[os.getComputerID()] = {
        name = rname,
        version = localSystemVersion() or target,
        packages = pkgs,
        at = os.epoch("utc"),
      }
      print("Main router packages refreshed to v" .. tostring(localSystemVersion() or target))
      maybeFinishUpdateCampaign()
    else
      print("Main self-update failed: " .. tostring(detail))
    end
  elseif nExp == 0 then
    maybeFinishUpdateCampaign()
  end

  if #targets == 0 then
    print("No targets online for this scope.")
    return
  end

  -- Wait briefly for rednet ACKs, then SSH anyone still pending.
  local waitSec = (scope == "all") and 20 or 12
  print(("Waiting %ds for ACKs before SSH fallback..."):format(waitSec))
  local deadline = os.clock() + waitSec
  while os.clock() < deadline do
    local pending = 0
    for id in pairs(updateCampaign.expected) do
      if not updateCampaign.acked[id] and not updateCampaign.failed[id] then
        pending = pending + 1
      end
    end
    if pending == 0 then break end
    sleep(0.5)
  end

  local needSsh = {}
  for _, t in ipairs(targets) do
    if not updateCampaign.acked[t.id] and not updateCampaign.failed[t.id] then
      needSsh[#needSsh + 1] = t
    end
  end

  if #needSsh > 0 then
    print(("SSH force-update for %d device(s) that didn't ACK..."):format(#needSsh))
    write("Master password (Parent Center): ")
    local password = read("*")
    if not password or password == "" then
      print("No password — skipping SSH fallback. Campaign stays open for late ACKs.")
    else
      for _, t in ipairs(needSsh) do
        print(("ssh #%d (%s)..."):format(t.id, tostring(t.label)))
        local ok, detail = sshForceUpdateDevice(t.id, password)
        if not ok then
          print(("  #%d SSH failed (%s) — retry in 3s..."):format(t.id, tostring(detail)))
          sleep(3)
          ok, detail = sshForceUpdateDevice(t.id, password)
        end
        if ok then
          local prev = updateCampaign.prevById and updateCampaign.prevById[t.id]
          updateCampaign.acked[t.id] = {
            name = t.label,
            version = target,
            packages = { {
              name = "system", path = "versions.lua",
              from = tostring(prev or "?"), to = tostring(target),
            } },
            at = os.epoch("utc"),
            via = "ssh",
          }
          updateCampaign.failed[t.id] = nil
          print(("  #%d SSH ok"):format(t.id))
          if detail and detail ~= "" then print("  " .. tostring(detail):sub(1, 120)) end
        else
          noteUpdateFail(t.id, t.label, detail)
          print(("  #%d SSH failed: %s"):format(t.id, tostring(detail)))
        end
      end
      maybeFinishUpdateCampaign()
    end
  else
    print("All targets ACK'd over rednet (or failed explicitly).")
    maybeFinishUpdateCampaign()
  end
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

-- MODEM nodes only persist a slim cfg: role + routes + links (+ optional GPS/name).
-- ROUTER backbone keeps fuller cfg (peers/cells) but not MAIN roster/screens.
local function sanitizeModemCfg(opts)
  opts = opts or {}
  if isMain() then return nil end
  local c = loadRouterCfg() or {}
  if routerRole == "router" then
    -- Keep backbone link state; drop MAIN-only board keys if present.
    local keep = {
      role = "router",
      gps = c.gps,
      gpsHost = c.gpsHost,
      netLinks = c.netLinks,
      homeRouter = c.homeRouter,
      mainRouterId = c.mainRouterId,
      assignedName = c.assignedName,
      manualHostname = c.manualHostname,
    }
    saveRouterCfg(keep)
    return keep
  end
  local slim = { role = "modem" }
  if not opts.clearMain then
    local mid = tonumber(opts.mainRouterId) or tonumber(c.mainRouterId)
    if mid then slim.mainRouterId = mid end
    local home = tonumber(opts.homeRouter) or tonumber(c.homeRouter)
      or (c.netLinks and tonumber(c.netLinks.homeRouter))
    if home then slim.homeRouter = home end
  end
  if not opts.clearName then
    if type(c.assignedName) == "string" and c.assignedName ~= "" then
      slim.assignedName = c.assignedName
    end
    if c.manualHostname then slim.manualHostname = true end
  end
  if c.gps then slim.gps = c.gps end
  if c.gpsHost == false then slim.gpsHost = false end
  if type(c.netLinks) == "table" then slim.netLinks = c.netLinks end
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
  elseif t == "perimeter_hello" then
    if msg.kind == "manager" or msg.kind == "perimeter_manager" then
      return "perimeter_manager"
    end
    return "perimeter_sensor"
  elseif type(msg.kind) == "string" and msg.kind:find("perimeter", 1, true) then
    return msg.kind
  end
  return nil
end

local function isPerimeterTraffic(msg)
  if type(msg) ~= "table" or type(msg.type) ~= "string" then return false end
  local t = msg.type
  if t == "perimeter_fwd" or t == "perimeter_roster_req" or t == "perimeter_roster" then
    return false
  end
  return t:sub(1, 10) == "perimeter_"
end

local function listOnlineKind(kind)
  local out = {}
  for id, d in pairs(seen) do
    if isOnline(d) and tostring(d.kind or "") == kind then
      out[#out + 1] = {
        id = id,
        name = d.hostname or d.name or ("#" .. id),
        x = d.x, y = d.y, z = d.z,
      }
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- Dedup recent perimeter forwards (origin|type|eventTs|player).
local perimeterFwdSeen = {}
local function perimeterFwdKey(originId, msg)
  return table.concat({
    tostring(originId or "?"),
    tostring(msg.type or "?"),
    tostring(msg.eventTs or msg.ts or msg.time or ""),
    tostring(msg.player or ""),
  }, "|")
end

-- Forward sensor perimeter_* traffic to online perimeter managers (mesh bridge).
local function forwardPerimeterToManagers(originId, msg)
  if not isPerimeterTraffic(msg) then return 0 end
  local t = msg.type
  if t == "perimeter_config" or t == "perimeter_update" then return 0 end
  local key = perimeterFwdKey(originId, msg)
  local now = os.clock()
  if perimeterFwdSeen[key] and perimeterFwdSeen[key] > now then return 0 end
  perimeterFwdSeen[key] = now + 15
  if math.random(1, 20) == 1 then
    for k, exp in pairs(perimeterFwdSeen) do
      if exp <= now then perimeterFwdSeen[k] = nil end
    end
  end

  local managers = listOnlineKind("perimeter_manager")
  if #managers == 0 then return 0 end

  local fwd = {}
  for k, v in pairs(msg) do fwd[k] = v end
  fwd.hop = true
  fwd.originId = tonumber(msg.originId) or tonumber(msg.sensorId) or originId
  fwd.via = os.getComputerID()
  fwd.sensorId = fwd.originId

  local n = 0
  for _, m in ipairs(managers) do
    if m.id ~= originId and m.id ~= fwd.originId then
      rednet.send(m.id, fwd, "titan_net")
      rednet.send(m.id, {
        type = "perimeter_fwd",
        dest = m.id,
        originId = fwd.originId,
        payload = fwd,
        from = os.getComputerID(),
      }, PROTO_ROUTER)
      n = n + 1
    end
  end
  return n
end

local function deliverPerimeterFwd(msg)
  local dest = tonumber(msg.dest)
  local payload = msg.payload
  if not dest or type(payload) ~= "table" then return false end
  payload.hop = true
  payload.originId = tonumber(msg.originId) or tonumber(payload.originId)
    or tonumber(payload.sensorId) or payload.from
  payload.via = os.getComputerID()
  rednet.send(dest, payload, "titan_net")
  return true
end

--------------------------------------------------------------------------------
-- 1) Repeater  (faithful to the built-in `repeat` program)
-- Bridges wireless <-> wired by re-transmitting on every open modem.
--------------------------------------------------------------------------------
local function repeaterLoop()
  -- modem_message only (clock-based de-dup) so console read() is never starved.
  while true do
    local _, _, channel, replyChannel, message = os.pullEvent("modem_message")
    if channel == REPEAT and type(message) == "table"
       and message.nMessageID and message.nRecipient then
      local t = os.clock()
      for mid, exp in pairs(relayed) do
        if type(exp) == "number" and exp <= t then relayed[mid] = nil end
      end
      local prev = relayed[message.nMessageID]
      if not (type(prev) == "number" and prev > t) then
        relayed[message.nMessageID] = t + 30
        relayStats.relayed = relayStats.relayed + 1
        for _, m in ipairs(modems) do
          peripheral.call(m, "transmit", REPEAT, replyChannel, message)
          if message.nRecipient ~= REPEAT then
            peripheral.call(m, "transmit", message.nRecipient, replyChannel, message)
          end
        end
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
  local via = tonumber(msg.via) or (prev and prev.via)
  local viaModem = tonumber(msg.viaModem) or (prev and prev.viaModem)
  local home = tonumber(msg.homeRouter) or (prev and prev.homeRouter)
  local scope = msg.scope or (prev and prev.scope)
  local remote = msg.remote or (prev and prev.remote)
  if msg.remote or scope == "global" then
    scope, remote = "global", true
  elseif netCells[id] or home == os.getComputerID()
      or (viaModem and netCells[viaModem]) or isWiredFresh(id) then
    scope, remote = "local", nil
  elseif netPeers[id] or (via and netPeers[via])
      or (home and home ~= os.getComputerID()) then
    scope, remote = "global", true
  end
  seen[id] = {
    name = host, hostname = host,
    kind = kind or (prev and prev.kind) or "device",
    seen = now(), x = px, y = py, z = pz,
    version = msg.version or (prev and prev.version),
    -- Only MAIN's wired probe/pong marks a direct cable link (not RF relays).
    wired = isWiredFresh(id) or nil,
    via = via, viaModem = viaModem, homeRouter = home,
    scope = scope, remote = remote,
    hub = msg.hub or msg.viaName or (prev and prev.hub),
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

-- Fold a remote hub's topology into the GLOBAL roster (MAIN only).
local function ingestRemoteTopology(id, msg)
  if not isMain() or type(msg) ~= "table" then return end
  if id == os.getComputerID() then return end
  local role = tostring(msg.role or msg.kind or "")
  if role == "main" or role == "router" or msg.kind == "router" then
    rosterTouch(id, {
      hostname = msg.name, name = msg.name, kind = "router",
      x = msg.x, y = msg.y, z = msg.z,
      scope = "global", remote = true, role = msg.role,
    }, "router", false)
    for _, cell in ipairs(msg.cells or {}) do
      local cid = tonumber(cell.id)
      if cid then
        rosterTouch(cid, {
          hostname = cell.name, name = cell.name, kind = "modem",
          homeRouter = id, via = id, scope = "global", remote = true,
          hub = msg.name,
        }, "modem", false)
      end
    end
    for _, peer in ipairs(msg.peers or {}) do
      local pid = tonumber(peer.id)
      if pid and pid ~= os.getComputerID() then
        rosterTouch(pid, {
          hostname = peer.name, name = peer.name, kind = "router",
          scope = "global", remote = true, via = id,
        }, "router", false)
      end
    end
  elseif role == "modem" or msg.kind == "modem" then
    local home = tonumber(msg.homeRouter)
    if home == os.getComputerID() or netCells[id] then
      rosterTouch(id, {
        hostname = msg.name, name = msg.name, kind = "modem",
        homeRouter = os.getComputerID(), scope = "local",
        x = msg.x, y = msg.y, z = msg.z,
      }, "modem", false)
    elseif home then
      rosterTouch(id, {
        hostname = msg.name, name = msg.name, kind = "modem",
        homeRouter = home, scope = "global", remote = true,
        x = msg.x, y = msg.y, z = msg.z,
      }, "modem", false)
    end
  end
end

local function directoryLoop()
  rednet.broadcast({ type = "ping" }, "titan_net")
  rednet.broadcast({ type = "ping" }, "titan_dc")
  claimMain()
  broadcastFleetMap()
  broadcastNetHello()
  local nextLinkHello = os.clock() + 25
  while true do
    if os.clock() >= nextLinkHello then
      broadcastNetHello()
      nextLinkHello = os.clock() + 25
    end
    local id, msg, proto = rednet.receive(nil, math.max(0.2, nextLinkHello - os.clock()))
    if type(msg) == "table" and id then
      if proto == PROTO_ROUTER and handleNetControl(id, msg) then
        if msg.type == "net_link_hello" or msg.type == "net_topo" then
          ingestRemoteTopology(id, msg)
        end
      -- Hopped modem hello: peer modem forwarded a device that can't hear main.
      elseif proto == PROTO_ROUTER and msg.type == "hop_hello" and tonumber(msg.from) then
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
        if msg.type == "update_fail" then
          noteUpdateFail(id, host, msg.err)
          print(("[OTA] FAIL #%d %s: %s"):format(id, host, tostring(msg.err or "?")))
          maybeFinishUpdateCampaign()
        elseif msg.type == "updated" then
          noteDeviceVersion(id, msg.version, host, msg.kind or classify(msg), msg.packages, true)
          local nPkg = type(msg.packages) == "table" and #msg.packages or 0
          print(("[OTA] ACK #%d %s -> v%s (%d pkg)"):format(
            id, host, tostring(msg.version or "?"), nPkg))
          local exp, done = campaignStatus()
          if exp then
            print(("[OTA] Campaign v%s: %d / %d resolved"):format(
              tostring(updateCampaign.version), done, exp))
          end
          maybeFinishUpdateCampaign()
        else
          noteDeviceVersion(id, msg.version, host, msg.kind or classify(msg))
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

      elseif proto == PROTO_ROUTER and (msg.type == "perimeter_roster_req"
          or msg.type == "perimeter_fwd") then
        if msg.type == "perimeter_roster_req" then
          -- Seed roster from announce kind when requester identifies itself.
          if msg.kind then rosterTouch(id, msg, msg.kind, false) end
          local sensors = listOnlineKind("perimeter_sensor")
          local managers = listOnlineKind("perimeter_manager")
          rednet.send(id, {
            type = "perimeter_roster",
            from = os.getComputerID(),
            sensors = sensors,
            managers = managers,
          }, PROTO_ROUTER)
          -- Optional: flood a config/update to every known sensor via mesh.
          if type(msg.floodConfig) == "table" then
            for _, s in ipairs(sensors) do
              deliverPerimeterFwd({
                dest = s.id,
                originId = id,
                payload = msg.floodConfig,
              })
            end
          end
        else
          -- Explicit hop: deliver payload to dest (sensor or manager).
          deliverPerimeterFwd(msg)
        end

      else
        -- Perimeter alerts: bridge over the mesh to territory managers.
        if isPerimeterTraffic(msg) then
          local origin = tonumber(msg.originId) or tonumber(msg.sensorId) or id
          if msg.kind == "sensor" or msg.sensorId or tostring(msg.type or ""):find("perimeter_", 1, true) then
            local pk = "perimeter_sensor"
            if msg.kind == "manager" or msg.kind == "perimeter_manager" then
              pk = "perimeter_manager"
            end
            rosterTouch(origin, {
              kind = pk, hostname = msg.gate or msg.name or msg.hostname,
              x = msg.x, y = msg.y, z = msg.z,
            }, pk, false)
          end
          forwardPerimeterToManagers(origin, msg)
          -- Also fan-out to backbone peers (other ender routers).
          for peerId in pairs(netPeers) do
            if peerId ~= id and peerId ~= origin then
              local hop = {}
              for k, v in pairs(msg) do hop[k] = v end
              hop.hop = true
              hop.originId = origin
              hop.via = os.getComputerID()
              rednet.send(peerId, hop, "titan_net")
              rednet.send(peerId, hop, PROTO_ROUTER)
            end
          end
        end
        -- Other protocols: remember presence only (no modem naming).
        local kind = classify(msg)
        if kind then rosterTouch(id, msg, kind, false) end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Single-monitor dashboards (MAIN):
--   roster/local — this hub's modems + nearby computers
--   global       — backbone peers + remote mesh
--   stats / gps / map
--
-- One physical monitor. Screensaver by default; wake one board at a time.
-- Toggle:  screen <role> on|off|perm
-- Focus:   view <role>
--------------------------------------------------------------------------------
local function normalizeScreenRole(role)
  role = tostring(role or ""):lower()
  if role == "local" or role == "cell" or role == "lan" then return "roster" end
  if role == "mesh" or role == "remote" or role == "wan" then return "global" end
  return role
end

local function isScreenRole(role)
  role = normalizeScreenRole(role)
  for _, r in ipairs(SCREEN_ROLES) do
    if r == role then return true end
  end
  return false
end

-- Local = this hub's RF/wired cell. Global = backbone peers + remote mesh.
local function isLocalDevice(id, d)
  if not d then return false end
  if id == os.getComputerID() then return true end
  if d.scope == "local" then return true end
  if d.scope == "global" or d.remote then return false end
  if d.wired or isWiredFresh(id) then return true end
  if netCells[id] then return true end
  if tonumber(d.homeRouter) == os.getComputerID() then return true end
  local viaM = tonumber(d.viaModem)
  if viaM and netCells[viaM] then return true end
  local via = tonumber(d.via)
  if via and netPeers[via] then return false end
  -- Backbone peer hubs are global, not local.
  if netPeers[id] then return false end
  local k = tostring(d.kind or ""):lower()
  if k == "router" and id ~= os.getComputerID() then return false end
  -- Direct / unmarked online devices count as local to this hub.
  return true
end

local function isGlobalDevice(id, d)
  if not d then return false end
  if id == os.getComputerID() then return true end -- show self on global too as hub
  if d.scope == "global" or d.remote then return true end
  if netPeers[id] then return true end
  local k = tostring(d.kind or ""):lower()
  if k == "router" then return true end
  if tonumber(d.homeRouter) and tonumber(d.homeRouter) ~= os.getComputerID() then return true end
  local via = tonumber(d.via)
  if via and netPeers[via] then return true end
  local viaM = tonumber(d.viaModem)
  if viaM and not netCells[viaM] and viaM ~= os.getComputerID() then return true end
  return not isLocalDevice(id, d)
end

local function sortedIdsScoped(scope)
  local ids = {}
  for id, d in pairs(seen) do
    if scope == "local" then
      if isLocalDevice(id, d) then ids[#ids + 1] = id end
    elseif scope == "global" then
      if isGlobalDevice(id, d) then ids[#ids + 1] = id end
    else
      ids[#ids + 1] = id
    end
  end
  table.sort(ids, function(a, b)
    local da, db = seen[a], seen[b]
    local function rank(d, id)
      local st = statusOf(d, id)
      if st == "ONLINE" or st == "WIRED" then return 0 end
      if st == "UNKNOWN" then return 1 end
      return 2
    end
    local ra, rb = rank(da, a), rank(db, b)
    if ra ~= rb then return ra < rb end
    local ha = tostring(da.hostname or da.name or ""):lower()
    local hb = tostring(db.hostname or db.name or ""):lower()
    if ha ~= hb then return ha < hb end
    return a < b
  end)
  return ids
end

local function countScoped(scope)
  local on, off, unk = 0, 0, 0
  for _, id in ipairs(sortedIdsScoped(scope)) do
    local st = statusOf(seen[id], id)
    if st == "ONLINE" or st == "WIRED" then on = on + 1
    elseif st == "UNKNOWN" then unk = unk + 1
    else off = off + 1 end
  end
  return on, off, unk
end

-- Snapshot for admin tablets (pretty boards over rednet).
buildBoardSnap = function()
  local function rows(scope)
    local out = {}
    for _, id in ipairs(sortedIdsScoped(scope)) do
      local d = seen[id]
      if d then
        local st = statusOf(d, id)
        out[#out + 1] = {
          id = id,
          hostname = d.hostname or d.name or ("#" .. id),
          kind = d.kind or "device",
          status = st,
          seen = d.seen or 0,
          hub = d.hub,
          homeRouter = d.homeRouter,
          remote = d.remote and true or nil,
        }
      end
    end
    return out
  end
  local on, off, unk = countOnlineOffline()
  local lon, loff, lunk = countScoped("local")
  local gon, goff, gunk = countScoped("global")
  local kinds = {}
  local remembered = 0
  for _, d in pairs(seen) do
    remembered = remembered + 1
    local k = d.kind or "device"
    kinds[k] = (kinds[k] or 0) + 1
  end
  local nPeers, nCells = 0, 0
  for _ in pairs(netPeers) do nPeers = nPeers + 1 end
  for _ in pairs(netCells) do nCells = nCells + 1 end
  local nRf = wirelessModems and #wirelessModems or 0
  local nWire = wiredModems and #wiredModems or 0
  local nModems = modems and #modems or (nRf + nWire)
  return {
    type = "board_snap",
    role = routerRole,
    id = os.getComputerID(),
    name = os.getComputerLabel() or ("Router-" .. os.getComputerID()),
    localRows = rows("local"),
    globalRows = rows("global"),
    localCounts = { on = lon, off = loff, unk = lunk },
    globalCounts = { on = gon, off = goff, unk = gunk },
    peers = nPeers,
    cells = nCells,
    stats = {
      role = routerRole,
      hostname = os.getComputerLabel() or ("Router-" .. os.getComputerID()),
      uptimeSec = math.floor((os.epoch("utc") - BOOT_EPOCH) / 1000),
      modems = nModems, rf = nRf, wire = nWire,
      relayed = (relayStats and tonumber(relayStats.relayed)) or 0,
      online = on, offline = off, unknown = unk,
      wired = countWiredOnline(),
      remembered = remembered,
      kinds = kinds,
      peers = nPeers, cells = nCells,
    },
    gps = gpsCoords and {
      hosting = true, x = gpsCoords.x, y = gpsCoords.y, z = gpsCoords.z,
    } or { hosting = false },
  }
end

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
  return m
end

--------------------------------------------------------------------------------
-- Monitor GUI: advanced (color) chrome + auto layout by screen size
--------------------------------------------------------------------------------
local function monIsColor(out)
  local ok, c = pcall(function() return out.isColor and out.isColor() end)
  return ok and c == true
end

-- Pick text scale from monitor size so huge walls stay readable and
-- small monitors stay dense. Returns scale, w, h, color after applying.
local function monApplyScale(out)
  if not out then return 0.5, 0, 0, false end
  local color = monIsColor(out)
  -- Probe at 0.5 (max character density), then bump scale on huge walls.
  pcall(function() out.setTextScale(0.5) end)
  local w, h = out.getSize()
  local scale = 0.5
  if w >= 90 and h >= 36 then
    scale = 1 -- ~6x4+ advanced wall: prefer readable cells
  end
  pcall(function() out.setTextScale(scale) end)
  w, h = out.getSize()
  return scale, w, h, color
end

local function monLayout(out)
  local scale, w, h, color = monApplyScale(out)
  local tier
  if w < 20 or h < 8 then tier = "tiny"
  elseif w < 30 or h < 12 then tier = "small"
  elseif w < 50 or h < 18 then tier = "medium"
  else tier = "large" end
  return {
    out = out, w = w, h = h, scale = scale, color = color, tier = tier,
    -- Layout slots (leave last row for footer).
    headerH = (tier == "tiny") and 1 or ((tier == "small") and 2 or 3),
    footerH = 1,
    pad = (tier == "large" and color) and 1 or 0,
  }
end

local function guiFill(out, x, y, w, h, bg, fg)
  if not out then return end
  bg = bg or colors.black
  fg = fg or colors.white
  for row = y, y + h - 1 do
    out.setCursorPos(x, row)
    if out.setBackgroundColor then out.setBackgroundColor(bg) end
    if out.setTextColor then out.setTextColor(fg) end
    out.write(string.rep(" ", w))
  end
end

local function guiText(out, x, y, txt, fg, bg)
  if not out or y < 1 then return end
  local w = select(1, out.getSize())
  if x > w then return end
  txt = tostring(txt or "")
  if out.setBackgroundColor then out.setBackgroundColor(bg or colors.black) end
  if out.setTextColor then out.setTextColor(fg or colors.white) end
  out.setCursorPos(x, y)
  out.write(txt:sub(1, math.max(0, w - x + 1)))
end

local function guiBar(L, y, title, subtitle, accent)
  local out, w = L.out, L.w
  accent = accent or colors.cyan
  if L.color then
    guiFill(out, 1, y, w, 1, accent, colors.black)
    guiText(out, 2, y, title, colors.black, accent)
    if subtitle and L.tier ~= "tiny" and #title + #subtitle + 4 < w then
      guiText(out, math.max(1, w - #subtitle), y, subtitle, colors.gray, accent)
    end
  else
    guiText(out, 1, y, title, colors.white, colors.black)
    if subtitle and L.tier ~= "tiny" then
      guiText(out, math.max(1, w - #subtitle + 1), y, subtitle, colors.lightGray, colors.black)
    end
  end
end

local function guiChip(out, x, y, label, fg, bg, colorOk)
  label = " " .. tostring(label) .. " "
  if colorOk then
    guiText(out, x, y, label, fg or colors.white, bg or colors.gray)
  else
    guiText(out, x, y, "[" .. tostring(label):match("^%s*(.-)%s*$") .. "]", fg or colors.white, colors.black)
  end
  return x + #label + (colorOk and 1 or 0)
end

local function guiFooter(L, role)
  local out, w, h = L.out, L.w, L.h
  local left = ""
  if boardWakeAt and not screenPerm[role] then
    left = (" %ds"):format(math.max(0, math.floor(boardWakeAt + saverIdleSecs - os.clock())))
  elseif screenPerm[role] then
    left = " PERM"
  end
  local tag = (role == "roster") and "local" or tostring(role)
  local right = L.color and " ADV" or " MONO"
  right = right .. (" %dx%d"):format(w, h)
  local line = (" %s%s"):format(tag, left)
  if L.color then
    guiFill(out, 1, h, w, 1, colors.gray, colors.white)
    guiText(out, 1, h, line, colors.white, colors.gray)
    guiText(out, math.max(1, w - #right + 1), h, right, colors.lightGray, colors.gray)
  else
    guiText(out, 1, h, (line .. right):sub(1, w), colors.gray, colors.black)
  end
end

local function loadScreenAssignments()
  local c = loadRouterCfg() or {}
  local s = type(c.screens) == "table" and c.screens or {}
  for _, role in ipairs(SCREEN_ROLES) do
    if type(s[role]) == "string" and s[role] ~= "" and s[role] ~= "auto" then
      screenNames[role] = s[role]
    end
  end
  -- Only permanent boards survive reboot. Temp toggles always start as saver.
  if type(c.screenPerm) == "table" then
    for _, role in ipairs(SCREEN_ROLES) do
      screenPerm[role] = c.screenPerm[role] and true or false
      screenOn[role] = screenPerm[role] and true or false
    end
  else
    -- Migrate older cfgs that kept every board ON — default to screensaver.
    for _, role in ipairs(SCREEN_ROLES) do
      screenPerm[role] = false
      screenOn[role] = false
    end
  end
  if type(c.screenFocus) == "string" and isScreenRole(c.screenFocus) then
    screenFocus = c.screenFocus
  end
  if tonumber(c.saverIdleSecs) and tonumber(c.saverIdleSecs) >= 5 then
    saverIdleSecs = math.floor(tonumber(c.saverIdleSecs))
  end
  if c.monRate ~= nil then
    monRate = clampMonRate(c.monRate)
  end
  boardWakeAt = nil
end

local function saveScreenAssignments()
  local s, on, perm = {}, {}, {}
  for _, role in ipairs(SCREEN_ROLES) do
    if screenNames[role] then s[role] = screenNames[role] end
    on[role] = screenOn[role] and true or false
    perm[role] = screenPerm[role] and true or false
  end
  patchRouterCfg({
    screens = s, screenOn = on, screenPerm = perm,
    screenFocus = screenFocus, saverIdleSecs = saverIdleSecs,
    monRate = monRate,
  })
end

local function enabledRoles()
  local list = {}
  for _, role in ipairs(SCREEN_ROLES) do
    if screenOn[role] then list[#list + 1] = role end
  end
  return list
end

local function anyLiveBoard()
  return #enabledRoles() > 0
end

local function ensureFocus()
  local active = enabledRoles()
  if #active == 0 then return active end
  if screenOn[screenFocus] then return active end
  screenFocus = active[1]
  return active
end

local function expireTemporaryBoards()
  if not boardWakeAt then return false end
  if os.clock() < boardWakeAt + saverIdleSecs then return false end
  local changed = false
  for _, role in ipairs(SCREEN_ROLES) do
    if screenOn[role] and not screenPerm[role] then
      screenOn[role] = false
      changed = true
    end
  end
  boardWakeAt = nil
  if changed then
    ensureFocus()
    saveScreenAssignments()
  end
  return changed
end

local function wakeBoard(role, permanent)
  role = normalizeScreenRole(role)
  if not isScreenRole(role) then return false end
  -- Single-screen: exclusive — only this board is live.
  for _, r in ipairs(SCREEN_ROLES) do
    if r ~= role then
      screenOn[r] = false
      screenPerm[r] = false
    end
  end
  screenOn[role] = true
  screenPerm[role] = permanent and true or false
  screenFocus = role
  if permanent then
    boardWakeAt = nil
  else
    boardWakeAt = os.clock()
  end
  saverActive = false
  saverState = {}
  saveScreenAssignments()
  return true
end

-- Prefer an explicitly assigned monitor name; otherwise the first attached.
local function primaryMonitorName()
  local names = listMonitorNames()
  if #names == 0 then return nil end
  local want = screenNames[screenFocus]
  if want and peripheral.isPresent(want) and peripheral.getType(want) == "monitor" then
    return want
  end
  return names[1]
end

local function refreshScreens()
  local names = listMonitorNames()
  for _, role in ipairs(SCREEN_ROLES) do
    screens[role] = nil
  end
  displayMon, displayMonName = nil, nil

  local monName = primaryMonitorName()
  if not monName then return 0 end
  displayMonName = monName
  displayMon = wrapScreen(monName)

  local active = ensureFocus()
  if #active == 0 then return #names end

  local focus = screenFocus
  if not screenOn[focus] then focus = active[1]; screenFocus = focus end
  screens[focus] = displayMon
  screenNames[focus] = monName
  return #names
end

local function monLine(out, w, y, txt, c)
  out.setCursorPos(1, y)
  if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
  out.setTextColor(c or colors.white)
  out.write(tostring(txt):sub(1, w))
end

local function clearMon(out)
  if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
  if out.setTextColor then out.setTextColor(colors.white) end
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

local function drawStatusChips(L, y, on, off, unk)
  local out, w = L.out, L.w
  if L.tier == "tiny" then
    guiText(out, 1, y, ("ON:%d OFF:%d ?:%d"):format(on, off, unk), colors.white, colors.black)
    return
  end
  local x = 1
  if L.color then
    guiFill(out, 1, y, w, 1, colors.black, colors.white)
    x = guiChip(out, x, y, "ON " .. on, colors.black, colors.lime, true)
    x = guiChip(out, x, y, "OFF " .. off, colors.white, colors.red, true)
    guiChip(out, x, y, "? " .. unk, colors.black, colors.yellow, true)
  else
    guiText(out, 1, y,
      ("ONLINE:%d  OFFLINE:%d  UNKNOWN:%d"):format(on, off, unk),
      colors.white, colors.black)
  end
end

local function drawRosterScoped(out, scope, y0, y1)
  local L = monLayout(out)
  local w, h = L.w, L.h
  y0 = y0 or 1
  y1 = y1 or (h - L.footerH)
  local on, off, unk = countScoped(scope)
  local title = (scope == "global") and "GLOBAL MESH" or "LOCAL NETWORK"
  local accent = (scope == "global") and (colors.orange or colors.yellow) or (colors.cyan or colors.lightBlue)

  local y = y0
  guiBar(L, y, title, L.color and (L.tier ~= "tiny" and "ADV" or nil) or "MONO", accent)
  y = y + 1

  if y <= y1 then
    drawStatusChips(L, y, on, off, unk)
    y = y + 1
  end

  if L.headerH >= 3 and y <= y1 then
    local nPeers, nCells = 0, 0
    for _ in pairs(netPeers) do nPeers = nPeers + 1 end
    for _ in pairs(netCells) do nCells = nCells + 1 end
    local meta
    if scope == "global" then
      meta = ("backbone %d  cells %d"):format(nPeers, nCells)
    else
      meta = ("cells %d  peers %d"):format(nCells, nPeers)
    end
    if L.color then
      guiFill(out, 1, y, w, 1, colors.gray, colors.white)
      guiText(out, 2, y, meta, colors.white, colors.gray)
    else
      guiText(out, 1, y, meta, colors.lightGray, colors.black)
    end
    y = y + 1
  end

  -- Column plan by width.
  local showKind = w >= 28
  local showAge = w >= 36
  local idW = (w < 22) and 3 or 4
  local stW = (L.tier == "tiny") and 3 or 8
  if y <= y1 then
    local hdr
    if L.tier == "tiny" then
      hdr = "ID ST HOST"
    elseif not showKind then
      hdr = ("%-" .. idW .. "s %-8s HOST"):format("ID", "STATUS")
    elseif not showAge then
      hdr = ("%-" .. idW .. "s %-8s %-6s HOST"):format("ID", "STATUS", "KIND")
    else
      hdr = ("%-" .. idW .. "s %-8s %-8s HOST"):format("ID", "STATUS", "KIND")
    end
    local hbg = L.color and colors.lightGray or colors.black
    local hfg = L.color and colors.black or colors.lightGray
    if L.color then guiFill(out, 1, y, w, 1, hbg, hfg) end
    guiText(out, 1 + L.pad, y, hdr, hfg, hbg)
    y = y + 1
  end

  local listStart = y
  local ids = sortedIdsScoped(scope)
  for _, id in ipairs(ids) do
    if y > y1 then break end
    local d = seen[id]
    local host = d.hostname or d.name or "?"
    if scope == "global" and d.hub then
      host = host .. " @" .. tostring(d.hub):sub(1, 8)
    elseif scope == "global" and d.homeRouter and d.homeRouter ~= os.getComputerID() then
      host = host .. " →#" .. tostring(d.homeRouter)
    end
    local status, statusColor = statusOf(d, id)
    local stShort = status
    if L.tier == "tiny" then
      if status == "ONLINE" then stShort = "ON"
      elseif status == "OFFLINE" then stShort = "OFF"
      elseif status == "WIRED" then stShort = "WR"
      else stShort = "?" end
    end
    local age = d.seen and d.seen > 0 and (ago(d.seen) .. "s") or "-"
    local kind = (d.kind or "?"):sub(1, showKind and (w >= 40 and 8 or 6) or 0)
    local bg = colors.black
    if L.color and ((y - listStart) % 2 == 1) then bg = colors.gray end

    if L.color then guiFill(out, 1, y, w, 1, bg, colors.white) end

    local x = 1 + L.pad
    guiText(out, x, y, ("%-" .. idW .. "d"):format(id), colors.white, bg)
    x = x + idW + 1

    if L.color and L.tier ~= "tiny" then
      local chip = ("%-" .. math.min(stW, 8) .. "s"):format(stShort)
      local chipBg = statusColor
      local chipFg = colors.black
      if status == "OFFLINE" then chipFg = colors.white end
      if status == "UNKNOWN" then chipFg = colors.black end
      guiText(out, x, y, chip, chipFg, chipBg)
      x = x + #chip + 1
    else
      guiText(out, x, y, ("%-" .. stW .. "s"):format(stShort), statusColor, bg)
      x = x + stW + 1
    end

    local kindCol = colors.white
    if status == "WIRED" then kindCol = colors.cyan
    elseif d.remote or scope == "global" then kindCol = colors.orange or colors.yellow
    end
    if showKind and #kind > 0 then
      local kw = (w >= 40) and 8 or 6
      guiText(out, x, y, ("%-" .. kw .. "s"):format(kind), kindCol, bg)
      x = x + kw + 1
    end

    local ageStr = showAge and tostring(age) or ""
    local room = w - x - (showAge and (#ageStr + 1) or 0) - L.pad
    if room < 1 then room = math.max(0, w - x) end
    guiText(out, x, y, host:sub(1, room), colors.white, bg)
    if showAge and #ageStr > 0 then
      guiText(out, w - #ageStr + 1 - L.pad, y, ageStr, colors.lightGray, bg)
    end
    y = y + 1
  end

  if y == listStart and y <= y1 then
    local empty = (scope == "global")
      and "(no remote hubs — link peer <id>)"
      or "(no local devices — link modem <id>)"
    guiText(out, 1 + L.pad, y, empty, colors.gray, colors.black)
  end
end

local function drawRoster(out, y0, y1)
  drawRosterScoped(out, "local", y0, y1)
end

local function drawGlobal(out, y0, y1)
  drawRosterScoped(out, "global", y0, y1)
end

local function drawStats(out, y0, y1)
  local L = monLayout(out)
  local w, h = L.w, L.h
  y0 = y0 or 1
  y1 = y1 or (h - L.footerH)
  local on, off, unk = countOnlineOffline()
  local remembered = 0
  for _ in pairs(seen) do remembered = remembered + 1 end
  local cyan = colors.cyan or colors.lightBlue
  local nRf = wirelessModems and #wirelessModems or 0
  local nWire = wiredModems and #wiredModems or 0
  local nModems = modems and #modems or (nRf + nWire)
  local nRelayed = (relayStats and tonumber(relayStats.relayed)) or 0

  local y = y0
  guiBar(L, y, "STATS", ("#%d"):format(os.getComputerID()), cyan)
  y = y + 1

  if y <= y1 then
    drawStatusChips(L, y, on, off, unk)
    y = y + 1
  end

  local cards = {
    { "ROLE", tostring(routerRole or "?"):upper(), colors.white },
    { "HOST", tostring(os.getComputerLabel() or "?"):sub(1, 16), colors.lightGray },
    { "UP", uptimeStr(), colors.white },
    { "MODEMS", ("%d rf:%d wire:%d"):format(nModems, nRf, nWire), colors.white },
    { "RELAY", tostring(nRelayed), cyan },
    { "WIRED", tostring(countWiredOnline()), cyan },
    { "MEM", tostring(remembered), colors.white },
  }

  if L.color and L.tier ~= "tiny" and w >= 30 then
    -- Two-column key/value cards on advanced monitors.
    local colW = math.floor((w - 2) / 2)
    local i = 1
    while i <= #cards and y <= y1 do
      local a, b = cards[i], cards[i + 1]
      guiFill(out, 1, y, w, 1, colors.gray, colors.white)
      local left = (" %s %s"):format(a[1], a[2])
      guiText(out, 1, y, left:sub(1, colW), a[3], colors.gray)
      if b then
        local right = (" %s %s"):format(b[1], b[2])
        guiText(out, colW + 2, y, right:sub(1, colW), b[3], colors.gray)
        i = i + 2
      else
        i = i + 1
      end
      y = y + 1
    end
  else
    for _, c in ipairs(cards) do
      if y > y1 then break end
      local line = ("%s: %s"):format(c[1], c[2])
      if L.tier == "tiny" then line = ("%s %s"):format(c[1], c[2]) end
      guiText(out, 1 + L.pad, y, line, c[3], colors.black)
      y = y + 1
    end
  end

  if y <= y1 then
    if L.color then
      guiFill(out, 1, y, w, 1, colors.lightGray, colors.black)
      guiText(out, 2, y, "BY KIND", colors.black, colors.lightGray)
    else
      guiText(out, 1, y, "By kind:", colors.lightGray, colors.black)
    end
    y = y + 1
  end

  local kinds = kindCounts()
  local keys = {}
  for k in pairs(kinds) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if y > y1 then break end
    local n = kinds[k]
    if L.color and w >= 24 then
      local barW = math.max(1, math.min(w - 14, n))
      guiText(out, 1 + L.pad, y, ("%-10s %3d "):format(k:sub(1, 10), n), colors.white, colors.black)
      guiText(out, 16 + L.pad, y, string.rep(" ", barW), colors.black, cyan)
    else
      guiText(out, 1 + L.pad, y, ("%-10s %d"):format(k, n), colors.white, colors.black)
    end
    y = y + 1
  end
  if #keys == 0 and y <= y1 then
    guiText(out, 1 + L.pad, y, "(none)", colors.gray, colors.black)
  end
end

local function drawGps(out, y0, y1)
  local L = monLayout(out)
  local w, h = L.w, L.h
  y0 = y0 or 1
  y1 = y1 or (h - L.footerH)
  local y = y0
  guiBar(L, y, "GPS", gpsCoords and "HOSTING" or "IDLE", colors.yellow)
  y = y + 1

  local function put(txt, c, bg)
    if y > y1 then return end
    if L.color and bg then guiFill(out, 1, y, w, 1, bg, c or colors.white) end
    guiText(out, 1 + L.pad, y, txt, c or colors.white, bg or colors.black)
    y = y + 1
  end

  if gpsCoords then
    if L.color then
      put(" HOSTING ", colors.black, colors.lime)
      local box = ("  X %-6d  Y %-6d  Z %-6d"):format(gpsCoords.x, gpsCoords.y, gpsCoords.z)
      if L.tier == "tiny" then
        put(("%d,%d,%d"):format(gpsCoords.x, gpsCoords.y, gpsCoords.z), colors.white, colors.gray)
      else
        put(box, colors.white, colors.gray)
        put(("  %d, %d, %d"):format(gpsCoords.x, gpsCoords.y, gpsCoords.z), colors.cyan, colors.black)
      end
    else
      put("Hosting: YES", colors.lime)
      put(("X: %d"):format(gpsCoords.x), colors.white)
      put(("Y: %d"):format(gpsCoords.y), colors.white)
      put(("Z: %d"):format(gpsCoords.z), colors.white)
    end
  else
    put(L.color and " NOT HOSTING " or "Hosting: NO",
      L.color and colors.white or colors.red,
      L.color and colors.red or colors.black)
    put("Use: gpshost <x> <y> <z>", colors.lightGray)
  end

  if y <= y1 and L.tier ~= "tiny" then put("", colors.white) end
  put("Live locate", colors.lightGray, L.color and colors.gray or nil)
  local lx, ly, lz = gps.locate(0.3)
  if lx then
    lx = math.floor(lx + 0.5); ly = math.floor(ly + 0.5); lz = math.floor(lz + 0.5)
    put(("  %d, %d, %d"):format(lx, ly, lz), colors.lime)
  else
    put("  (no fix — need 4 hosts)", colors.orange or colors.yellow)
  end
  if L.tier ~= "tiny" then
    put("", colors.white)
    put("Constellation: place 4+ routers", colors.gray)
    put("with gpshost set.", colors.gray)
  end
end

local function setScreenOn(role, on)
  role = normalizeScreenRole(role)
  if not isScreenRole(role) then return false end
  if on then
    return wakeBoard(role, false)
  end
  screenOn[role] = false
  screenPerm[role] = false
  boardWakeAt = nil
  ensureFocus()
  saverActive = false
  saverState = {}
  saveScreenAssignments()
  return true
end

local function setScreenFocus(role)
  role = normalizeScreenRole(role)
  if not isScreenRole(role) then return false end
  return wakeBoard(role, false)
end

-- Forward-declared; body set after drawFleetMapOn.
local drawMapBoard
local drawBoards

-- Bounce "TitanSystems" on the primary monitor (erase old glyph only).
local function screensaverFrame(entering)
  refreshScreens()
  local mon = displayMon
  if not mon then return end
  local tw = #SAVER_TEXT
  local cyan = colors.cyan or colors.lightBlue
  local w, h = mon.getSize()
  local st = saverState
  if w < tw + 1 or h < 2 then
    if entering then clearMon(mon) end
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(cyan)
    mon.setCursorPos(math.max(1, math.floor((w - tw) / 2) + 1), math.max(1, math.floor(h / 2)))
    mon.write(SAVER_TEXT:sub(1, w))
    return
  end
  if entering or not st.w or st.w ~= w or st.h ~= h then
    clearMon(mon)
    local maxX = w - tw + 1
    st = {
      x = math.random(1, math.max(1, maxX)),
      y = math.random(1, h),
      dx = (math.random(0, 1) == 0) and -1 or 1,
      dy = (math.random(0, 1) == 0) and -1 or 1,
      w = w, h = h, tw = tw,
      prevX = nil, prevY = nil,
    }
    saverState = st
  else
    if st.prevX and st.prevY then
      mon.setBackgroundColor(colors.black)
      mon.setTextColor(colors.black)
      mon.setCursorPos(st.prevX, st.prevY)
      mon.write(string.rep(" ", st.tw))
    end
    st.x = st.x + st.dx
    st.y = st.y + st.dy
    local maxX = w - tw + 1
    if st.x <= 1 then st.x = 1; st.dx = 1
    elseif st.x >= maxX then st.x = maxX; st.dx = -1 end
    if st.y <= 1 then st.y = 1; st.dy = 1
    elseif st.y >= h then st.y = h; st.dy = -1 end
  end
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(cyan)
  mon.setCursorPos(st.x, st.y)
  mon.write(SAVER_TEXT)
  st.prevX, st.prevY = st.x, st.y
end

local function drawUpdateAcks(out)
  clearMon(out)
  local L = monLayout(out)
  local w, h = L.w, L.h
  local camp = updateCampaign
  if not camp then
    guiBar(L, 1, "OTA UPDATE", nil, colors.yellow)
    guiText(out, 1 + L.pad, 2, "(no active campaign)", colors.gray, colors.black)
    guiFooter(L, "update")
    return
  end
  local exp, ack, fail = campaignCounts()
  guiBar(L, 1, ("OTA v%s"):format(tostring(camp.version or "?")), nil, colors.yellow)
  local y = 2
  if L.color then
    local x = 1
    x = guiChip(out, x, y, "ACK " .. tostring(ack or 0), colors.black, colors.lime, true)
    x = guiChip(out, x, y, "FAIL " .. tostring(fail or 0), colors.white, colors.red, true)
    guiChip(out, x, y, "EXP " .. tostring(exp or 0), colors.black, colors.lightGray, true)
  else
    guiText(out, 1, y, ("ACKs %d  FAIL %d  / %d expected"):format(ack or 0, fail or 0, exp or 0), colors.lime, colors.black)
  end
  y = 3

  local ids = {}
  for id in pairs(camp.expected) do ids[#ids + 1] = id end
  table.sort(ids)
  if camp.acked[os.getComputerID()] then
    local selfId = os.getComputerID()
    local has = false
    for _, id in ipairs(ids) do if id == selfId then has = true; break end end
    if not has then table.insert(ids, 1, selfId) end
  end

  local function put(txt, c, bg)
    if y > h - 1 then return false end
    if L.color and bg then guiFill(out, 1, y, w, 1, bg, c or colors.white) end
    guiText(out, 1 + L.pad, y, txt, c or colors.white, bg or colors.black)
    y = y + 1
    return true
  end

  for _, id in ipairs(ids) do
    if y > h - 1 then
      put("...", colors.gray)
      break
    end
    local name = camp.expected[id]
      or (camp.acked[id] and camp.acked[id].name)
      or (seen[id] and (seen[id].hostname or seen[id].name))
      or ("#" .. id)
    local ainfo = camp.acked[id]
    local finfo = camp.failed[id]
    if ainfo then
      if not put(tostring(name), L.color and colors.black or colors.lime, L.color and colors.lime or nil) then break end
      local pkgs = ainfo.packages or {}
      if #pkgs == 0 then
        put(("  system - version: ? - %s"):format(tostring(ainfo.version or "?")), colors.white)
      else
        for _, p in ipairs(pkgs) do
          local line = ("%s - version: %s - %s"):format(
            tostring(p.name or p.path or "?"),
            tostring(p.from or "?"),
            tostring(p.to or "?"))
          if not put("  " .. line, colors.white) then break end
        end
      end
    elseif finfo then
      if not put(tostring(finfo.name or name), L.color and colors.white or colors.red, L.color and colors.red or nil) then break end
      put(("  FAIL: %s"):format(tostring(finfo.err or "?"):sub(1, w - 8)), colors.orange or colors.yellow)
    else
      if not put(tostring(name), colors.lightGray, L.color and colors.gray or nil) then break end
      put("  (waiting for ACK...)", colors.gray)
    end
    if y < h - 1 and L.tier ~= "tiny" then put("", colors.white) end
  end

  if #ids == 0 then
    put("(no online devices expected — main self-updated)", colors.gray)
  end

  local footer = camp.finishedAt and "done" or "collecting"
  guiFooter({ out = out, w = w, h = h, color = L.color, tier = L.tier }, "update")
  if L.color then
    guiText(out, math.max(1, w - #footer - 12), h, footer, colors.white, colors.gray)
  end
end

paintUpdateAcks = function()
  refreshScreens()
  local mon = displayMon
  if not mon then
    -- Still try the first attached monitor even if board focus is off.
    local names = listMonitorNames()
    if #names == 0 then return false, "no monitor" end
    mon = wrapScreen(names[1])
    displayMon, displayMonName = mon, names[1]
  end
  if not mon then return false, "no monitor" end
  drawUpdateAcks(mon)
  return true
end

drawBoards = function()
  if otaOverlay or (updateCampaign and updateCampaign.showAcks) then
    paintUpdateAcks()
    return
  end

  local n = refreshScreens()
  if n == 0 or not displayMon then return end

  if not anyLiveBoard() then return end

  local role = screenFocus
  if not screenOn[role] then
    local active = ensureFocus()
    if #active == 0 then return end
    role = screenFocus
  end

  local mon = displayMon
  clearMon(mon)
  local L = monLayout(mon)
  local contentBottom = math.max(1, L.h - L.footerH)

  if role == "stats" then
    drawStats(mon, 1, contentBottom)
  elseif role == "gps" then
    drawGps(mon, 1, contentBottom)
  elseif role == "map" then
    if drawMapBoard then drawMapBoard(mon) else
      guiBar(L, 1, "MAP", nil, colors.yellow)
      guiText(mon, 1, 2, "(map unavailable)", colors.gray, colors.black)
    end
  elseif role == "global" then
    drawGlobal(mon, 1, contentBottom)
  else
    -- roster / local
    drawRoster(mon, 1, contentBottom)
  end

  -- Map board has its own chrome; other boards share the adaptive footer.
  if L.h >= 2 and role ~= "map" then
    guiFooter(L, role)
  end
end

local function drawLoop()
  loadScreenAssignments()
  while true do
    refreshWiredFlags()
    if not otaOverlay then
      expireTemporaryBoards()
    end
    maybeFinishUpdateCampaign()
    if otaOverlay or (updateCampaign and updateCampaign.showAcks) then
      if saverActive then
        saverActive = false
        saverState = {}
      end
      local ok, err = pcall(paintUpdateAcks)
      if not ok then
        -- Keep trying; print once in a while via console if needed.
        if type(err) == "string" then
          -- swallow spam; beginUpdateMonitor already reports first failure
        end
      end
      if rosterDirty then saveRoster() end
      sleep(clampMonRate(monRate))
    elseif not anyLiveBoard() then
      local entering = not saverActive
      saverActive = true
      screensaverFrame(entering)
      if rosterDirty then saveRoster() end
      sleep(0.08)   -- ~12 fps bounce
    else
      if saverActive then
        saverActive = false
        saverState = {}
      end
      drawBoards()
      if rosterDirty then saveRoster() end
      sleep(clampMonRate(monRate))
    end
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
          print("[GitHub] Run `update` (modems) or `update all` (whole fleet).")
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

  local function hubId()
    return homeRouterId or mainId
  end

  local function announce()
    local x, y, z = ownPos()
    local name = assignedName or os.getComputerLabel()
      or ((routerRole == "router") and ("Router-" .. os.getComputerID())
          or ("Modem-pending-" .. os.getComputerID()))
    local kind = roleKind()
    local msg = {
      type = "hello", kind = kind, name = name, hostname = name,
      role = routerRole,
      autoName = (routerRole == "modem") and (not manualName) or false,
      needName = (routerRole == "modem") and (not manualName) and (assignedName == nil),
      homeRouter = homeRouterId,
    }
    if x then msg.x, msg.y, msg.z = x, y, z end
    -- Prefer home router (local hub), then MAIN, then broadcast.
    local hub = hubId()
    if hub then rednet.send(hub, msg, PROTO_ROUTER) end
    if mainId and mainId ~= hub then rednet.send(mainId, msg, PROTO_ROUTER) end
    for peerId in pairs(netPeers) do
      rednet.send(peerId, msg, PROTO_ROUTER)
    end
    rednet.broadcast(msg, PROTO_ROUTER)
    broadcastNetHello()
    if not mainId or (os.clock() - mainSeenAt) > MAIN_STALE then
      rednet.broadcast({
        type = "hop_find_main", from = os.getComputerID(),
        name = name, hostname = name,
      }, PROTO_ROUTER)
      if hub then
        rednet.send(hub, {
          type = "hop_find_main", from = os.getComputerID(),
          name = name, hostname = name,
        }, PROTO_ROUTER)
      end
    end
  end

  local function findMain()
    rednet.broadcast({ type = "where_main", name = os.getComputerLabel() }, PROTO_ROUTER)
    rednet.broadcast({
      type = "hop_find_main", from = os.getComputerID(),
      name = os.getComputerLabel(),
    }, PROTO_ROUTER)
    local hub = hubId()
    if hub then
      rednet.send(hub, { type = "where_main", name = os.getComputerLabel() }, PROTO_ROUTER)
    end
  end

  if routerRole == "modem" and not manualName and not assignedName then
    print("[name] Waiting for main router to assign a unique name...")
  end
  if routerRole == "router" then
    print("[backbone] ROUTER mode — ender peer to MAIN/other routers; host local modems.")
  else
    print("[hop] MODEM cell — links to home router, then backbone.")
  end
  if homeRouterId then
    print("[link] Home router #" .. tostring(homeRouterId))
  end
  findMain()
  announce()
  local nextAnn = os.clock() + 20
  while true do
    if os.clock() >= nextAnn then announce(); nextAnn = os.clock() + 20 end
    local id, msg = rednet.receive(PROTO_ROUTER, math.max(0.2, nextAnn - os.clock()))
    if type(msg) ~= "table" or not id then
      -- ignore
    elseif handleNetControl(id, msg) then
      -- topology / link / hop
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
      -- Peer looking for main: answer + forward via hub/peers.
      local hub = hubId()
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
        for peerId in pairs(netPeers) do
          if peerId ~= id then
            rednet.send(peerId, {
              type = "where_main", from = id, via = os.getComputerID(),
              name = msg.name or msg.hostname,
            }, PROTO_ROUTER)
          end
        end
      elseif hub and id ~= hub then
        rednet.send(hub, msg, PROTO_ROUTER)
      elseif mainId and id ~= mainId then
        rednet.send(mainId, msg, PROTO_ROUTER)
      end

    elseif msg.type == "hello" and (msg.kind == "modem" or msg.kind == "router" or msg.autoName) then
      -- Hop toward home hub / MAIN / backbone peers.
      local hub = hubId()
      if hub and id ~= hub and id ~= os.getComputerID() then
        rednet.send(hub, {
          type = "hop_hello", from = id, via = os.getComputerID(),
          hello = msg,
        }, PROTO_ROUTER)
      end
      if mainId and mainId ~= hub and id ~= mainId then
        rednet.send(mainId, {
          type = "hop_hello", from = id, via = os.getComputerID(),
          hello = msg,
        }, PROTO_ROUTER)
      end
      if isBackbone() and (msg.kind == "modem" or msg.role == "modem") then
        if tonumber(msg.homeRouter) == os.getComputerID() or netCells[id] then
          addNetCell(id, msg.name or msg.hostname)
        end
      end

    elseif msg.type == "update" and id ~= os.getComputerID() then
      print("")
      print(("[OTA] Fleet update from #%s (v%s) — downloading..."):format(
        tostring(id), tostring(msg.targetVersion or "?")))
      if titanLib and titanLib.updateSelf then
        local prev = titanLib.systemVersion and titanLib.systemVersion() or nil
        local ok, detail = titanLib.updateSelf()
        if ok then
          local pkgs = type(detail) == "table" and detail.packages or nil
          if titanLib.markPendingUpdateAck then
            titanLib.markPendingUpdateAck(prev, msg.targetVersion, pkgs)
          end
          print("[OTA] Updated. Rebooting (will ACK main)..."); sleep(2); os.reboot()
        else
          print("[OTA] Failed: " .. tostring(detail))
          rednet.send(id, {
            type = "update_fail", version = prev, err = tostring(detail),
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
    put(1, 2, "r=main  m=rf  w=wired  N=up   (map board)", colors.lightGray)
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

drawMapBoard = function(mon)
  if not mon then return end
  monApplyScale(mon)
  local w, h = mon.getSize()
  local nodes = fleetMapNodes()
  local ox, oz = mapOrigin(nodes)
  local scale = mapAutoScale(nodes, ox, oz, w, math.max(4, h - 4))
  drawFleetMapOn(mon, scale, { interactive = false })
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
-- Shared by local console and SSH. Returns "exit" / false / true.
local function handleRouterCommand(a)
  local cmd = (a[1] or ""):lower()

  if cmd == "" then
    return true
  elseif cmd == "help" then
      print("role     - show main / router / modem role")
      print("main     - make THIS the MAIN hub (directory + OTA)")
      print("router   - ender backbone satellite (long-haul peer)")
      print("modem    - local RF cell repeater (short range)")
      print("link                 show backbone peers + modem cells")
      print("link peer <id>       peer this node to another ROUTER/MAIN")
      print("link home <id>       MODEM: set home MAIN/ROUTER")
      print("link modem <id>      MAIN/ROUTER: attach a modem cell")
      print("link unpeer|uncell|unhome <id>")
      print("hostname [name|auto] - set name (modems: auto = accept main assign)")
      print("stats    - relay counts (+ roster if main)")
      print("gpshost [x y z] - show / set this router's GPS host coords")
      print("reset [routes|names|all|hard] - wipe routing data (confirm)")
      if isMain() then
        print("  routes = roster; names = name assigns; all = both")
        print("screens  - monitor status (single screen)")
        print("screen <role> on|off|perm   one board at a time")
        print(("  on = show %ds then saver;  perm = stay on"):format(saverIdleSecs))
        print("view <roster|global|stats|gps|map>")
        print("  roster/local = this hub's modems+computers")
        print("  global       = backbone peers + remote mesh")
        print("idle [seconds]  temp-board timeout (default 120)")
        print("monrate [secs]  live board refresh rate (default 1)")
        print("map on|off|perm|view")
        print("versions - local vs GitHub package versions")
        print("devices  - list remembered systems (ONLINE / OFFLINE)")
        print("forget <id|host> - remove a system from the remembered roster")
        print("names    - modem name pool + assignments")
        print("name <id|host> <newname>  - force-assign a modem name (reboots it)")
        print("namepool add|remove <name>  - edit the unique-name list")
        print("ping     - re-discover the network")
        print("update [modems]|status - OTA online MODEMS only (+ SSH fallback)")
        print("update all|fleet       - OTA EVERY online device (+ SSH fallback)")
        print("forceupdate [-y]       - same as update modems")
        print("reauth   - tell the fleet to re-auth now (no download)")
        print("github [url] - show / set GitHub raw base for versions")
      else
        print("  routes = keep MAIN/home; hard/all = also forget MAIN + name")
      end
      print("ssh <id|label> [cmd] - remote shell (full device commands)")
      print("exit")
  elseif cmd == "role" then
      print(("Role: %s  (id #%d)"):format(routerRole, os.getComputerID()))
      if isMain() then
        print("MAIN hub — OTA/directory. Use ender modem; peer routers with `link peer`.")
      elseif routerRole == "router" then
        print("ROUTER backbone — ender long-haul. Host local modems with `link modem`.")
      else
        print("MODEM cell — short-range RF. Set hub with `link home <routerId>`.")
      end
      printNetLinks()
    elseif cmd == "main" then
      if isMain() then
        claimMain()
        print("Already MAIN. Re-broadcast claim so devices refresh.")
      else
        write("Promote this node to MAIN hub? (other mains should run `modem`/`router`) [y/N] ")
        if read():lower() ~= "y" then print("Cancelled.") else
          patchRouterCfg({ role = "main" })
          print("Saved role=main. Rebooting..."); sleep(1); os.reboot()
        end
      end
    elseif cmd == "router" then
      if routerRole == "router" then
        print("Already a ROUTER backbone node.")
        printNetLinks()
      else
        write("Set role=ROUTER (ender backbone satellite, not MAIN)? [y/N] ")
        if read():lower() ~= "y" then print("Cancelled.") else
          if isMain() and fs.exists(ROSTER) then pcall(fs.delete, ROSTER) end
          patchRouterCfg({ role = "router" })
          print("Saved role=router. Use ender modem + `link peer <mainId>`. Rebooting...")
          sleep(1); os.reboot()
        end
      end
    elseif cmd == "modem" then
      if isModemRole() then
        print("Already a MODEM cell repeater.")
        printNetLinks()
      else
        write("Demote to MODEM (local RF cell)? [y/N] ")
        if read():lower() ~= "y" then print("Cancelled.") else
          patchRouterCfg({ role = "modem" })
          if fs.exists(ROSTER) then pcall(fs.delete, ROSTER) end
          print("Saved role=modem. Link home with `link home <routerId>`. Rebooting...")
          sleep(1); os.reboot()
        end
      end
    elseif cmd == "link" or cmd == "netlink" or cmd == "topology" then
      local sub = (a[2] or ""):lower()
      if sub == "" or sub == "status" or sub == "show" then
        printNetLinks()
        broadcastNetHello()
      elseif sub == "peer" or sub == "router" then
        local id = tonumber(a[3])
        if not id then
          print("Usage: link peer <routerId>")
          print("Peers this MAIN/ROUTER to another ender backbone node.")
        else
          local ok, err = addNetPeer(id, a[4])
          if not ok then print(tostring(err)) else
            rednet.send(id, {
              type = "net_link", action = "peer",
              with = os.getComputerID(),
              withName = os.getComputerLabel(),
              name = os.getComputerLabel(),
              role = routerRole,
            }, PROTO_ROUTER)
            broadcastNetHello()
            print(("Linked backbone peer #%d"):format(id))
          end
        end
      elseif sub == "home" then
        local id = tonumber(a[3])
        if not id then
          print("Usage: link home <mainOrRouterId>   (modem cells only)")
        elseif not isModemRole() then
          print("link home is for MODEM role. Use `modem` first, or `link modem` on the hub.")
        else
          local ok, err = setHomeRouter(id, a[4])
          if not ok then print(tostring(err)) else
            rednet.send(id, {
              type = "net_link", action = "cell",
              with = os.getComputerID(),
              withName = os.getComputerLabel(),
              name = os.getComputerLabel(),
            }, PROTO_ROUTER)
            broadcastNetHello()
            print(("Home router set to #%d"):format(id))
          end
        end
      elseif sub == "modem" or sub == "cell" then
        local id = tonumber(a[3])
        if not id then
          print("Usage: link modem <modemId>   (on MAIN/ROUTER)")
        elseif not isBackbone() then
          print("Only MAIN/ROUTER host modem cells.")
        else
          local ok, err = addNetCell(id, a[4])
          if not ok then print(tostring(err)) else
            rednet.send(id, {
              type = "net_link", action = "home",
              with = os.getComputerID(),
              withName = os.getComputerLabel(),
            }, PROTO_ROUTER)
            broadcastNetHello()
            print(("Attached modem cell #%d"):format(id))
          end
        end
      elseif sub == "unpeer" or sub == "unlink" then
        local ok, err = removeNetPeer(tonumber(a[3]))
        print(ok and "Removed peer." or tostring(err))
      elseif sub == "uncell" then
        local ok, err = removeNetCell(tonumber(a[3]))
        print(ok and "Removed cell." or tostring(err))
      elseif sub == "unhome" then
        homeRouterId = nil; saveNetLinks()
        print("Cleared home router.")
      elseif sub == "hello" or sub == "announce" then
        broadcastNetHello()
        print("Announced links on mesh.")
      else
        print("Usage: link | link peer <id> | link home <id> | link modem <id>")
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
    elseif cmd == "map" or cmd == "fmap" or cmd == "fleetmap" then
      if not isMain() then print("map is MAIN-only.")
      else
        local sub = (a[2] or ""):lower()
        if sub == "" or sub == "status" then
          local mode = not screenOn.map and "saver"
            or (screenPerm.map and "PERM" or ("temp %ds"):format(saverIdleSecs))
          print(("Map board: %s"):format(mode))
          print("  map on|off|perm  — temp / off / permanent")
          print("  map view         — interactive map on this terminal")
        elseif sub == "true" or sub == "on" or sub == "1" or sub == "yes" then
          wakeBoard("map", false)
          print(("Map ON for %ds, then screensaver."):format(saverIdleSecs))
          drawBoards()
        elseif sub == "perm" or sub == "permanent" or sub == "always" then
          wakeBoard("map", true)
          print("Map ON permanently.")
          drawBoards()
        elseif sub == "false" or sub == "off" or sub == "0" or sub == "no" then
          setScreenOn("map", false)
          print("Map OFF (screensaver).")
        elseif sub == "view" or sub == "term" or sub == "live" then
          fleetMapView()
        elseif sub == "toggle" then
          if screenOn.map then setScreenOn("map", false) else wakeBoard("map", false) end
          print(("Map board: %s"):format(screenOn.map and "ON" or "OFF"))
          drawBoards()
        else
          print("Usage: map on|off|perm|view|toggle")
        end
      end
    elseif cmd == "view" or cmd == "display" then
      if not isMain() then print("view is MAIN-only.")
      else
        local role = normalizeScreenRole(a[2] or "")
        if role == "" then
          local left = boardWakeAt and math.max(0, math.floor(boardWakeAt + saverIdleSecs - os.clock())) or 0
          local live = enabledRoles()
          print(("Active: %s  focus=%s  temp-timeout=%ds (left %ds)"):format(
            #live > 0 and table.concat(live, ",") or "(saver)",
            screenFocus, saverIdleSecs, left))
          print("Usage: view <roster|local|global|stats|gps|map>")
          print("  roster/local — this hub's cell   global — whole mesh")
        elseif not isScreenRole(role) then
          print("Usage: view <roster|local|global|stats|gps|map>")
        else
          wakeBoard(role, false)
          local label = (role == "roster") and "local" or role
          print(("%s ON for %ds, then screensaver."):format(label, saverIdleSecs))
          drawBoards()
        end
      end
    elseif cmd == "idle" or cmd == "saver" then
      if not isMain() then print("idle is MAIN-only.")
      else
        local sec = tonumber(a[2])
        if not a[2] or a[2]:lower() == "status" then
          print(("Temp boards return to screensaver after %ds."):format(saverIdleSecs))
          print("Usage: idle <seconds>   (min 5)")
        elseif not sec or sec < 5 then
          print("Usage: idle <seconds>   (min 5)")
        else
          saverIdleSecs = math.floor(sec)
          saveScreenAssignments()
          print(("Temp-board timeout set to %ds."):format(saverIdleSecs))
        end
      end
    elseif cmd == "monrate" or cmd == "mrate" or cmd == "monitorrate" or cmd == "refreshrate" then
      if not isMain() then print("monrate is MAIN-only.")
      else
        if a[2] then
          monRate = clampMonRate(a[2])
          saveScreenAssignments()
        end
        print(("Monitor refresh: %.2fs  (live boards; screensaver stays smooth)"):format(monRate))
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
        local mode = anyLiveBoard() and ("board:" .. screenFocus) or "screensaver"
        print(("Monitor: %s   mode=%s"):format(displayMonName or "(none)", mode))
        if #names > 1 then
          print(("(%d monitors attached — using primary %s)"):format(#names, displayMonName or "?"))
        end
        print(("Boards (single screen, temp timeout %ds):"):format(saverIdleSecs))
        for _, role in ipairs(SCREEN_ROLES) do
          local modeR = not screenOn[role] and "off"
            or (screenPerm[role] and "PERM" or "temp")
          local mark = (screenOn[role] and role == screenFocus) and " <<<" or ""
          print(("  %-6s %-4s%s"):format(role, modeR, mark))
        end
        if boardWakeAt then
          local left = math.max(0, math.floor(boardWakeAt + saverIdleSecs - os.clock()))
          print(("Returns to screensaver in %ds."):format(left))
        end
      end
    elseif cmd == "screen" then
      if not isMain() then print("Screens are MAIN-only."); else
        local role = (a[2] or ""):lower()
        local target = (a[3] or ""):lower()
        local flag = (a[4] or ""):lower()
        if not isScreenRole(role) then
          print("Usage: screen <roster|local|global|stats|gps|map> <on|off|perm>")
          print(("  on   = show %ds then screensaver"):format(saverIdleSecs))
          print("  perm = stay on permanently")
          print("  roster/local = this hub   global = whole mesh")
          print("Example: screen local on   |   screen global perm")
        elseif target == "" then
          print(("Usage: screen %s <on|off|perm>"):format(role))
        elseif target == "on" or target == "true" or target == "1" or target == "yes" then
          local permanent = (flag == "perm" or flag == "permanent" or flag == "always")
          wakeBoard(role, permanent)
          local label = (normalizeScreenRole(role) == "roster") and "local" or normalizeScreenRole(role)
          if permanent then
            print(label .. " on permanently (single screen).")
          else
            print(("%s on for %ds, then screensaver."):format(label, saverIdleSecs))
          end
          drawBoards()
        elseif target == "perm" or target == "permanent" or target == "always" then
          wakeBoard(role, true)
          local label = (normalizeScreenRole(role) == "roster") and "local" or normalizeScreenRole(role)
          print(label .. " on permanently (single screen).")
          drawBoards()
        elseif target == "off" or target == "false" or target == "0" or target == "no" then
          setScreenOn(role, false)
          print(normalizeScreenRole(role) .. " off — screensaver.")
          -- Drop back to saver immediately (drawLoop will animate next tick).
          refreshScreens()
          if displayMon then clearMon(displayMon) end
        else
          print("Usage: screen <roster|local|global|stats|gps|map> <on|off|perm>")
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
          if cmp < 0 then print("Status: GitHub is NEWER — run `update` (modems) or `update all`")
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
    elseif cmd == "update" or cmd == "forceupdate" or cmd == "upgrade" then
      if not isMain() then
        print("OTA update is MAIN-only. Run `main` on this machine, or use the main router.")
      else
        local yes, scope, statusOnly = false, nil, false
        for i = 2, #a do
          local s = (a[i] or ""):lower()
          if s == "-y" or s == "--yes" or s == "yes" then
            yes = true
          elseif s == "status" or s == "stat" then
            statusOnly = true
          elseif s == "all" or s == "fleet" or s == "aoe" or s == "everyone" then
            scope = "all"
          elseif s == "modems" or s == "modem" or s == "extenders" then
            scope = "modems"
          elseif s == "help" or s == "?" then
            print("Usage:")
            print("  update              force-update online MODEMS only (default)")
            print("  update modems [-y]  same — mesh extenders only, SSH if no ACK")
            print("  update all [-y]     every online Titan device (broadcast + SSH)")
            print("  update status       ACK progress / package version diffs")
            print("  forceupdate [-y]    alias for update modems")
            return true
          end
        end
        -- `forceupdate` with no scope → modems; bare `update` → modems
        if not scope then
          scope = "modems"
        end
        if statusOnly then
          local exp, done, camp = campaignStatus()
          if not camp then
            print("No active update campaign. Run `update` (modems) or `update all`.")
          else
            local _, ackN, failN = campaignCounts()
            print(("Campaign [%s] target v%s  ok %d  fail %d  / %d%s"):format(
              tostring(camp.scope or "?"), tostring(camp.version),
              ackN or 0, failN or 0, exp or 0,
              camp.finishedAt and " (finished)" or ""))
            for id, name in pairs(camp.expected) do
              local ainfo = camp.acked[id]
              local finfo = camp.failed[id]
              if ainfo then
                local via = ainfo.via and (" via " .. ainfo.via) or ""
                print(("  OK  #%-3d %s%s"):format(id, tostring(name), via))
                for _, p in ipairs(ainfo.packages or {}) do
                  print(("      %s - version: %s - %s"):format(
                    tostring(p.name or "?"), tostring(p.from or "?"), tostring(p.to or "?")))
                end
              elseif finfo then
                print(("  FAIL #%-3d %s: %s"):format(id, tostring(name), tostring(finfo.err)))
              else
                local d = seen[id]
                print(("  ... #%-3d %-16s have v%s"):format(
                  id, tostring(name):sub(1, 16), tostring(d and d.version or "?")))
              end
            end
          end
        else
          runForceUpdate(scope, { yes = yes })
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
      elseif titanLib and titanLib.sshIsAuthed and titanLib.sshIsAuthed() then
        print("Nested ssh from an SSH session is not supported.")
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
    return "exit"
  else
    return false
  end
  return true
end

local function consoleLoop()
  print(("Titan router #%d [%s]. %d modem(s) (rf:%d wire:%d). Type 'help'."):format(
    os.getComputerID(), routerRole:upper(), #modems, #wirelessModems, #wiredModems))
  while true do
    write(isMain() and "router> " or "modem> ")
    local a = {}
    for word in tostring(read()):gmatch("%S+") do a[#a + 1] = word end
    local r = handleRouterCommand(a)
    if r == "exit" then return
    elseif r == false then
      print("Unknown: " .. tostring(a[1] or ""))
    end
  end
end

--------------------------------------------------------------------------------
-- Boot (MAIN / ROUTER hub). Wrapped so top-level locals stay under Lua's 200 limit.
--------------------------------------------------------------------------------
local function runHub()
if fs.exists("lib/titan.lua") then
  titanLib = dofile("lib/titan.lua")
  if titanLib.setSshHandler then
    titanLib.setSshHandler(function(line)
      local a = {}
      for w in tostring(line):gmatch("%S+") do a[#a + 1] = w end
      local r = handleRouterCommand(a)
      if r == "exit" then
        print("Over SSH: type `exit` to disconnect (router keeps running).")
        return true
      end
      if r == false then
        print("Unknown: " .. tostring(a[1] or ""))
      end
      return true
    end)
  else
    print("[ssh] Update lib/titan.lua (run `update`) for full remote commands.")
  end
end

local rcfg = loadRouterCfg() or {}
if rcfg.role == "modem" then
  print("This file is the MAIN/ROUTER hub runtime.")
  print("Role is modem — run `router` to load router_modem.lua.")
  return
elseif rcfg.role == "main" or rcfg.role == "router" then
  routerRole = rcfg.role
else
  print("")
  print("Hub role for this computer:")
  print("  M = MAIN hub (directory + OTA) — use an ENDER modem")
  print("  R = ROUTER backbone satellite — ENDER modem, long-haul peer")
  print("  (MODEM cells: run `router` and pick N — uses router_modem.lua)")
  write("[M/r] ")
  local ans = read():lower()
  if ans == "r" or ans == "router" then
    routerRole = "router"
  else
    routerRole = "main"
  end
  rcfg = patchRouterCfg({ role = routerRole })
  print("Role saved: " .. routerRole)
end
loadNetLinks()

if rcfg.gps then
  gpsCoords = rcfg.gps
elseif rcfg.gpsHost == false then
  -- previously opted out
else
  print("")
  print("Routers double as GPS hosts (place 4+ spread out for a constellation).")
  print("Host coords = MODEM block (F3 Targeted Block on the modem).")
  local x, y, z, info
  if titanLib and titanLib.gpsFix then
    x, y, z, info = titanLib.gpsFix({ timeout = 4, samples = 9 })
  else
    x, y, z = gps.locate(2)
    if x then
      x = math.floor(x + 0.5); y = math.floor(y + 0.5); z = math.floor(z + 0.5)
    end
  end
  if x then
    if info then
      print(("Auto-located: %d, %d, %d  (n=%d  Y %.2f..%.2f)"):format(
        x, y, z, info.n, info.yLo, info.yHi))
    else
      print(("Auto-located: %d, %d, %d"):format(x, y, z))
    end
    gpsCoords = { x = x, y = y, z = z }
  else
    print("Enter this MODEM's coordinates to host GPS (blank X = skip).")
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

local tasks = { repeaterLoop, consoleLoop, wiredLinkLoop }
if isMain() then
  tasks[#tasks + 1] = directoryLoop
  tasks[#tasks + 1] = pingLoop
  tasks[#tasks + 1] = rosterSaveLoop
  tasks[#tasks + 1] = drawLoop
  tasks[#tasks + 1] = githubWatchLoop
else
  -- ROUTER backbone + MODEM cells share the mesh side loop.
  tasks[#tasks + 1] = modemLoop
  -- Hop perimeter / net traffic toward home hub, MAIN, and backbone peers.
  tasks[#tasks + 1] = function()
    while true do
      local id, msg = rednet.receive("titan_net", 1)
      if type(msg) == "table" and id and isPerimeterTraffic(msg) then
        local cfg = loadRouterCfg() or {}
        local targets = {}
        local function add(t)
          t = tonumber(t)
          if t and t ~= id and t ~= os.getComputerID() then targets[t] = true end
        end
        add(homeRouterId)
        add(cfg.mainRouterId)
        add(cfg.homeRouter)
        for peerId in pairs(netPeers) do add(peerId) end
        local hop = {}
        for k, v in pairs(msg) do hop[k] = v end
        hop.hop = true
        hop.originId = tonumber(msg.originId) or tonumber(msg.sensorId) or id
        hop.viaModem = os.getComputerID()
        for tid in pairs(targets) do
          rednet.send(tid, hop, "titan_net")
          rednet.send(tid, hop, PROTO_ROUTER)
        end
      end
    end
  end
end
if gpsCoords then tasks[#tasks + 1] = gpsHostLoop end
if titanLib then
  tasks[#tasks + 1] = function()
    titanLib.sshHostLoop(roleKind())
  end
  if not isMain() then
    tasks[#tasks + 1] = function()
      sleep(2)
      titanLib.reportUpdatedIfPending(roleKind())
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
  local nMon = refreshScreens()
  do
    local n = 0
    for _ in pairs(nameAssign) do n = n + 1 end
    if n > 0 then print(("Modem names: %d assigned. Type `names`."):format(n)) end
  end
  local onBits = {}
  for _, role in ipairs(SCREEN_ROLES) do
    local mode = not screenOn[role] and "off" or (screenPerm[role] and "perm" or "on")
    onBits[#onBits + 1] = role .. "=" .. mode
  end
  print("Boards: " .. table.concat(onBits, "  "))
  if nMon == 0 then
    print("No monitor yet — attach one for screensaver / boards.")
  else
    print(("Single screen on %s. Default=screensaver (%ds temp)."):format(
      displayMonName or "monitor", saverIdleSecs))
    print("Type `view local` / `view global` / `screen map perm`.")
  end
else
  -- ROUTER backbone (modem cells use router_modem.lua via bootstrap).
  print("ROUTER backbone — ender peers + local modem cells. Type `link`.")
  printNetLinks()
end
parallel.waitForAny(table.unpack(tasks))
for _, role in ipairs(SCREEN_ROLES) do
  local m = screens[role]
  if m then pcall(function() m.clear() end) end
end
if isMain() and rosterDirty then saveRoster() end
print("Router stopped.")
end -- runHub

runHub()
