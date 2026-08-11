--[[
  router_modem.lua  -  Titan MODEM cell runtime (CC: Tweaked)
  Titan-Version: 1.4.3

  Short-range RF repeater cell. Loaded by router.lua when role=modem.
  Prefer: run `router` (detects role and auto-installs this file).

  Fleet net: debounced net_link_hello + lighter announce / burst drain
  (same storm-control approach as quarry site + hub routers).

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
-- Monitor boards live on MAIN (router_main.lua), not modem cells.
local SCREEN_ROLES = {}
local screens, screenNames, screenOn, screenPerm = {}, {}, {}, {}
local screenFocus, displayMon, displayMonName = "roster", nil, nil
local SAVER_TEXT, saverIdleSecs, monRate = "TitanSystems", 120, 1
local boardWakeAt, saverActive, saverState = nil, false, {}


-- Router config (GPS host coords + role: "main" | "router" | "modem").
local RCFG      = "router.cfg"
local ROSTER    = "router_roster.cfg"
local gpsCoords = nil
local routerRole = "modem"  -- this module is MODEM-only
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

local NET_HELLO_MIN_MS = 2000
local netHelloDirty = false
local netHelloLastFlush = 0

local function broadcastNetHello(force)
  if force ~= true then
    netHelloDirty = true
    return
  end
  netHelloDirty = false
  netHelloLastFlush = os.epoch("utc")
  local snap = netLinkSnapshot()
  snap.type = "net_link_hello"
  rednet.broadcast(snap, PROTO_ROUTER)
  for id in pairs(netPeers) do
    rednet.send(id, snap, PROTO_ROUTER)
  end
  if homeRouterId and not netPeers[homeRouterId] then
    rednet.send(homeRouterId, snap, PROTO_ROUTER)
  end
end

local function flushNetHello()
  if not netHelloDirty then return end
  if (os.epoch("utc") - netHelloLastFlush) < NET_HELLO_MIN_MS then return end
  broadcastNetHello(true)
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

local function handleNetControl(id, msg)
  if type(msg) ~= "table" or not msg.type then return false end
  local t = msg.type
  if t == "net_topo_req" then
    rednet.send(id, netLinkSnapshot(), PROTO_ROUTER)
    return true
  elseif t == "board_req" then
    -- Hub answers board snapshots; modem cells ignore.
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

-- Bridge host.lua install / OTA (+ tetris LB) across cell -> home -> backbone.
local installFwdSeen = {}
local function installFwdDedup(key, ttl)
  local tnow = os.clock()
  if installFwdSeen[key] and installFwdSeen[key] > tnow then return false end
  installFwdSeen[key] = tnow + (ttl or 4)
  return true
end

local function handleInstallMesh(id, msg)
  if type(msg) ~= "table" or type(msg.type) ~= "string" then return false end
  local t = msg.type
  if t ~= "install_discover" and t ~= "install_where" and t ~= "install_get"
      and t ~= "install_file" and t ~= "install_host_here" and t ~= "install_fwd"
      and t ~= "tetris_lb_get" and t ~= "tetris_lb_submit" and t ~= "tetris_lb"
      and t ~= "games_lb_get" and t ~= "games_lb_submit" and t ~= "games_lb"
      and t ~= "games_lb_admin_get" and t ~= "games_lb_admin_setpass"
      and t ~= "games_lb_admin_edit" and t ~= "games_lb_admin_delete"
      and t ~= "games_lb_admin_clear" and t ~= "games_lb_admin" then
    return false
  end

  local hub = homeRouterId
  if not hub then
    local c = loadRouterCfg() or {}
    hub = tonumber(c.homeRouter) or tonumber(c.mainRouterId)
  end
  if t == "install_fwd" then
    local dest = tonumber(msg.dest) or tonumber(msg.replyTo)
    local payload = msg.payload
    local key = "fwd|" .. tostring(dest) .. "|" .. tostring(payload and payload.type)
      .. "|" .. tostring(payload and payload.path) .. "|" .. tostring(payload and payload.replyTo)
    if not installFwdDedup(key, 3) then return true end
    if dest then rednet.send(dest, payload, PROTO_ROUTER) end
    if hub then rednet.send(hub, msg, PROTO_ROUTER) end
    if dest then netHopDeliver(dest, payload, msg.ttl) end
    return true
  end

  if t == "install_discover" or t == "install_where" then
    local origin = tonumber(msg.originId) or tonumber(msg.replyTo) or id
    if not installFwdDedup(t .. "|" .. tostring(origin), 2) then return true end
    if hub then
      rednet.send(hub, {
        type = t, originId = origin, replyTo = origin, from = id, hop = true,
      }, PROTO_ROUTER)
    end
    return true
  end

  if t == "install_get" or t == "tetris_lb_get" or t == "tetris_lb_submit"
      or t == "games_lb_get" or t == "games_lb_submit"
      or t == "games_lb_admin_get" or t == "games_lb_admin_setpass"
      or t == "games_lb_admin_edit" or t == "games_lb_admin_delete"
      or t == "games_lb_admin_clear" then
    local dest = tonumber(msg.dest) or tonumber(msg.hostId)
    local origin = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    msg.replyTo, msg.originId, msg.dest = origin, origin, dest
    local key = t .. "|" .. tostring(dest) .. "|" .. tostring(origin) .. "|" .. tostring(msg.path or "")
    if not installFwdDedup(key, 3) then return true end
    if dest then rednet.send(dest, msg, PROTO_ROUTER) end
    if hub then
      rednet.send(hub, {
        type = "install_fwd", dest = dest, payload = msg, replyTo = origin, from = id,
      }, PROTO_ROUTER)
    end
    return true
  end

  if t == "install_file" or t == "install_host_here" or t == "tetris_lb"
      or t == "games_lb" or t == "games_lb_admin" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or tonumber(msg.dest)
    if not dest then return true end
    local key = t .. "|" .. tostring(dest) .. "|" .. tostring(msg.path or msg.hostId or "")
    if not installFwdDedup(key, 3) then return true end
    rednet.send(dest, msg, PROTO_ROUTER)
    if hub then
      rednet.send(hub, {
        type = "install_fwd", dest = dest, payload = msg, replyTo = dest, from = id,
      }, PROTO_ROUTER)
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





-- Preferred pool entry from GPS bearing (still unique via registry).

-- Assign or return the stable unique name for this modem id.
-- Returns name, isNew (true if first assignment or renamed).


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
local UPDATE_CAMPAIGN_TIMEOUT = 180  -- seconds; then restore monitor even if incomplete















-- filterFn(id, d) optional — return true to include in the campaign.






-- scope: "modems" (default force) or "all"


-- Broadcast known router/modem positions for the pocket locator radar.

local function isWiredFresh(id)
  local t = wiredDirect[id]
  return type(t) == "number" and (os.clock() - t) < WIRED_FRESH
end

-- ONLINE = green, WIRED = cyan (online + on MAIN's cable), OFFLINE = red,
-- UNKNOWN = yellow (remembered, never heard live).





-- Persist remembered systems so the monitor still lists them when offline.
-- Roster file is MAIN-only. Modems must not keep router_roster.cfg.


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


-- Dedup recent perimeter forwards (origin|type|eventTs|player).
local perimeterFwdSeen = {}

-- Forward sensor perimeter_* traffic to online perimeter managers (mesh bridge).


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

-- Register a device into the MAIN roster; optionally assign a modem name.
-- Returns assignHostname, assignReboot for the reply.

-- Fold a remote hub's topology into the GLOBAL roster (MAIN only).


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


-- Local = this hub's RF/wired cell. Global = backbone peers + remote mesh.




-- Snapshot for admin tablets (pretty boards over rednet).



--------------------------------------------------------------------------------
-- Monitor GUI: advanced (color) chrome + auto layout by screen size
--------------------------------------------------------------------------------

-- Pick text scale from monitor size so huge walls stay readable and
-- small monitors stay dense. Returns scale, w, h, color after applying.














-- Prefer an explicitly assigned monitor name; otherwise the first attached.














-- Forward-declared; body set after drawFleetMapOn.

-- Bounce "TitanSystems" on the primary monitor (erase old glyph only).





-- Persist roster even without a monitor.

-- Periodically nudge the network so devices that booted before us also register.

-- Poll GitHub versions.lua; alert when remote system version is newer.

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
    -- Prefer home/MAIN unicast; broadcast only if nothing to target.
    local hub = hubId()
    local sent = false
    if hub then rednet.send(hub, msg, PROTO_ROUTER); sent = true end
    if mainId and mainId ~= hub then rednet.send(mainId, msg, PROTO_ROUTER); sent = true end
    for peerId in pairs(netPeers) do
      rednet.send(peerId, msg, PROTO_ROUTER)
      sent = true
    end
    if not sent then rednet.broadcast(msg, PROTO_ROUTER) end
    broadcastNetHello()  -- debounced
    if not mainId or (os.clock() - mainSeenAt) > MAIN_STALE then
      if hub then
        rednet.send(hub, {
          type = "hop_find_main", from = os.getComputerID(),
          name = name, hostname = name,
        }, PROTO_ROUTER)
      else
        rednet.broadcast({
          type = "hop_find_main", from = os.getComputerID(),
          name = name, hostname = name,
        }, PROTO_ROUTER)
      end
    end
  end

  local function findMain()
    local hub = hubId()
    if hub then
      rednet.send(hub, { type = "where_main", name = os.getComputerLabel() }, PROTO_ROUTER)
    elseif mainId then
      rednet.send(mainId, { type = "where_main", name = os.getComputerLabel() }, PROTO_ROUTER)
    else
      rednet.broadcast({ type = "where_main", name = os.getComputerLabel() }, PROTO_ROUTER)
      rednet.broadcast({
        type = "hop_find_main", from = os.getComputerID(),
        name = os.getComputerLabel(),
      }, PROTO_ROUTER)
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
  sleep(((os.getComputerID() * 37) % 1000) / 1000)
  findMain()
  announce()
  broadcastNetHello(true)
  local nextAnn = os.clock() + 25
  while true do
    if os.clock() >= nextAnn then announce(); nextAnn = os.clock() + 25 end
    local id, msg = rednet.receive(PROTO_ROUTER, 0.4)
    local batch = {}
    if type(msg) == "table" and id then batch[#batch + 1] = { id, msg } end
    for _ = 1, 12 do
      local id2, msg2 = rednet.receive(PROTO_ROUTER, 0)
      if not id2 then break end
      if type(msg2) == "table" then batch[#batch + 1] = { id2, msg2 } end
    end
    for bi = 1, #batch do
      id, msg = batch[bi][1], batch[bi][2]
    if type(msg) ~= "table" or not id then
      -- ignore
    elseif handleInstallMesh(id, msg) then
      -- host OTA / tetris LB bridged to home router
    elseif handleNetControl(id, msg) then
      -- topology / link / hop
    elseif msg.type == "main_claim" or msg.type == "main_here" then
      rememberMain(id, msg)
      handleAssign(msg)
      -- Don't re-announce on every claim (mesh storm).

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
    end -- batch
    flushNetHello()
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




-- Background cell art from (-, _, |, \, /).

-- Draw fleet map onto any term/monitor (`out`). opts.interactive adds key hints.



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
        broadcastNetHello(true)
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
            broadcastNetHello(true)
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
            broadcastNetHello(true)
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
            broadcastNetHello(true)
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
        broadcastNetHello(true)
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
-- Boot (MODEM cell only)
--------------------------------------------------------------------------------
local function runModem()
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
    end
  end

  local rcfg = loadRouterCfg() or {}
  routerRole = "modem"
  if rcfg.role ~= "modem" then
    rcfg = patchRouterCfg({ role = "modem" })
  end
  loadNetLinks()

  if rcfg.gps then
    gpsCoords = rcfg.gps
  elseif rcfg.gpsHost ~= false then
    print("")
    print("Optional GPS host on this modem cell (blank X = skip).")
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
      print(("Auto-located: %d, %d, %d"):format(x, y, z))
      gpsCoords = { x = x, y = y, z = z }
      patchRouterCfg({ gps = gpsCoords })
    else
      write("X: "); local sx = read()
      if sx ~= "" then
        write("Y: "); local sy = read(); write("Z: "); local sz = read()
        gpsCoords = { x = tonumber(sx) or 0, y = tonumber(sy) or 0, z = tonumber(sz) or 0 }
        patchRouterCfg({ gps = gpsCoords })
      else
        patchRouterCfg({ gpsHost = false })
      end
    end
    if gpsCoords then
      print(("Hosting GPS at %d, %d, %d."):format(gpsCoords.x, gpsCoords.y, gpsCoords.z))
    end
  end

  local tasks = { repeaterLoop, consoleLoop, wiredLinkLoop, modemLoop }
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
  if gpsCoords then tasks[#tasks + 1] = gpsHostLoop end
  if titanLib then
    tasks[#tasks + 1] = function()
      titanLib.sshHostLoop("modem")
    end
    tasks[#tasks + 1] = function()
      sleep(2)
      titanLib.reportUpdatedIfPending("modem")
      while true do sleep(3600) end
    end
  end

  clearRosterIfModem()
  local slim = sanitizeModemCfg()
  print("Role: MODEM")
  if slim and slim.mainRouterId then
    print(("Mesh hop + relay. Route to MAIN #%d."):format(slim.mainRouterId))
  else
    print("Mesh hop + relay (no roster). Waiting for MAIN…")
  end
  print("Type `link home <id>` or use admin `link`. `reset` wipes routing data.")
  parallel.waitForAny(table.unpack(tasks))
  print("Modem router stopped.")
end

runModem()
