--[[
  lib/router_hub_net.lua  -  Titan hub networking / roster / OTA (part)
  Titan-Version: 1.4.2

  Loaded by router_main.lua into a shared env (setfenv). Do not run directly.
]]

function loadRouterCfg()
  if not fs.exists(RCFG) then return nil end
  local f = fs.open(RCFG, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  return type(d) == "table" and d or nil
end
function saveRouterCfg(c)
  local f = fs.open(RCFG, "w"); f.write(textutils.serialize(c)); f.close()
end
function patchRouterCfg(patch)
  local c = loadRouterCfg() or {}
  for k, v in pairs(patch) do c[k] = v end
  saveRouterCfg(c)
  return c
end
function isMain() return routerRole == "main" end
function isModemRole() return routerRole == "modem" end
function isBackbone() return routerRole == "main" or routerRole == "router" end
function roleKind()
  -- GLOBAL board only lists MAIN hubs. Extenders are "extender", RF cells "modem".
  if routerRole == "main" then return "main" end
  if routerRole == "router" then return "extender" end
  return "modem"
end

-- Active turtle fuel SOS alerts (drawn on every MAIN monitor).
sosAlerts = sosAlerts or {}   -- [id] = { name, x, y, z, reason, seen }
sosOverlay = false
SOS_FRESH_SECS = 20

--------------------------------------------------------------------------------
-- Network links: ender backbone peers + local modem cells
-- Persisted in router.cfg.netLinks
--------------------------------------------------------------------------------
netPeers = {}       -- [id] = { name, kind, seen }
netCells = {}       -- [modemId] = { name, seen }  (backbone only)
homeRouterId = nil  -- modem -> home MAIN/ROUTER id

function loadNetLinks()
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

function saveNetLinks()
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

function addNetPeer(id, name, kind)
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

function removeNetPeer(id)
  id = tonumber(id)
  if not id or not netPeers[id] then return false, "not linked" end
  netPeers[id] = nil
  saveNetLinks()
  return true
end

function setHomeRouter(id, name)
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

function addNetCell(id, name)
  id = tonumber(id)
  if not id or id == os.getComputerID() then return false, "bad id" end
  netCells[id] = {
    name = name or (netCells[id] and netCells[id].name) or ("#" .. id),
    seen = os.epoch("utc"),
  }
  saveNetLinks()
  return true
end

function removeNetCell(id)
  id = tonumber(id)
  if not id or not netCells[id] then return false, "not a cell" end
  netCells[id] = nil
  saveNetLinks()
  return true
end

function netLinkSnapshot()
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

function printNetLinks()
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

function broadcastNetHello()
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
function netHopDeliver(dest, payload, ttl)
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
buildBoardSnap = nil

function handleNetControl(id, msg)
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
    local role = tostring(msg.role or ""):lower()
    local kind = tostring(msg.kind or ""):lower()
    if role == "main" or kind == "main" or msg.main == true then
      if netPeers[id] or isBackbone() then
        netPeers[id] = netPeers[id] or { name = msg.name, kind = "main", seen = 0 }
        netPeers[id].name = msg.name or netPeers[id].name
        netPeers[id].kind = "main"
        netPeers[id].seen = os.epoch("utc")
        if not isMain() then
          patchRouterCfg({ mainRouterId = id })
        end
      end
    elseif role == "router" or kind == "router" or kind == "extender" then
      if netPeers[id] or isBackbone() then
        netPeers[id] = netPeers[id] or { name = msg.name, kind = "extender", seen = 0 }
        netPeers[id].name = msg.name or netPeers[id].name
        netPeers[id].kind = "extender"
        netPeers[id].seen = os.epoch("utc")
      end
    elseif role == "modem" or kind == "modem" then
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
function now() return os.epoch("utc") end
function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end
function isOnline(d)
  return d and d.seen and d.seen > 0 and ago(d.seen) < ONLINE_SECS
end

--------------------------------------------------------------------------------
-- Modem name registry (MAIN): unique names from a pool, persisted in router.cfg.
-- Modems hello -> main assigns a free name -> modem sets label and reboots.
--------------------------------------------------------------------------------
DEFAULT_NAME_POOL = {
  "North", "East", "South", "West",
  "NE", "SE", "SW", "NW", "Center",
  "North-2", "East-2", "South-2", "West-2",
  "NE-2", "SE-2", "SW-2", "NW-2",
  "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot",
}

-- nameAssign[id] = "North"  (persisted)
nameAssign = {}

function loadNameRegistry()
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

function saveNameRegistry(pool)
  local assign = {}
  for id, name in pairs(nameAssign) do
    assign[tostring(id)] = name
  end
  local patch = { nameAssign = assign }
  if pool then patch.namePool = pool end
  patchRouterCfg(patch)
end

function namePool()
  local c = loadRouterCfg() or {}
  if type(c.namePool) == "table" and #c.namePool > 0 then return c.namePool end
  return DEFAULT_NAME_POOL
end

function nameTaken(name, exceptId)
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
function preferredSectorName(x, z)
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
function allocateModemName(id, x, z, currentName)
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

function releaseModemName(id)
  loadNameRegistry()
  if nameAssign[id] then
    nameAssign[id] = nil
    saveNameRegistry()
  end
end

--------------------------------------------------------------------------------
-- GitHub version tracking + fleet OTA campaign (MAIN)
--------------------------------------------------------------------------------
DEFAULT_GH_BASE = "https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/"
ghState = {
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
updateCampaign = nil
otaOverlay = false           -- hard flag: monitor shows ACK board
paintUpdateAcks = nil
UPDATE_CAMPAIGN_TIMEOUT = 180  -- seconds; then restore monitor even if incomplete

function githubBase()
  local c = loadRouterCfg() or {}
  if type(c.githubBase) == "string" and c.githubBase ~= "" then
    return c.githubBase:find("/$") and c.githubBase or (c.githubBase .. "/")
  end
  if titanLib and titanLib.GITHUB_RAW_BASE then return titanLib.GITHUB_RAW_BASE end
  return DEFAULT_GH_BASE
end

function localSystemVersion()
  if titanLib and titanLib.systemVersion then return titanLib.systemVersion() end
  if fs.exists("versions.lua") then
    local ok, cat = pcall(dofile, "versions.lua")
    if ok and type(cat) == "table" then return cat.system end
  end
  return nil
end

function fetchGithubVersions()
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

function versionCmp(a, b)
  if titanLib and titanLib.versionCompare then return titanLib.versionCompare(a, b) end
  if tostring(a) == tostring(b) then return 0 end
  if tostring(a) < tostring(b) then return -1 end
  return 1
end

function copyScreenBoolMap(src)
  local out = {}
  for _, role in ipairs(SCREEN_ROLES) do
    out[role] = src[role] and true or false
  end
  return out
end

function noteDeviceVersion(id, version, name, kind, packages, isUpdateAck)
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

function noteUpdateFail(id, name, err)
  if not updateCampaign or updateCampaign.finishedAt or not id then return end
  local host = name or (seen[id] and (seen[id].hostname or seen[id].name)) or ("#" .. id)
  updateCampaign.failed[id] = {
    name = host, err = tostring(err or "failed"), at = os.epoch("utc"),
  }
end

function campaignCounts()
  if not updateCampaign then return nil end
  local exp, ack, fail = 0, 0, 0
  for _ in pairs(updateCampaign.expected) do exp = exp + 1 end
  for id in pairs(updateCampaign.expected) do
    if updateCampaign.acked[id] then ack = ack + 1
    elseif updateCampaign.failed[id] then fail = fail + 1 end
  end
  return exp, ack, fail, updateCampaign
end

function campaignStatus()
  local exp, ack, fail, camp = campaignCounts()
  if not camp then return nil end
  return exp, ack + fail, camp
end

function campaignResolved()
  local exp, ack, fail = campaignCounts()
  if not exp then return true end
  if exp == 0 then
    -- Nobody else online: wait until MAIN records its own self-update ACK.
    local selfId = os.getComputerID()
    return updateCampaign.acked[selfId] ~= nil or updateCampaign.failed[selfId] ~= nil
  end
  return (ack + fail) >= exp
end

function restoreUpdateMonitor()
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

function beginUpdateMonitor()
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

function finishUpdateCampaign(reason)
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

function maybeFinishUpdateCampaign()
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
function startUpdateCampaign(targetVersion, filterFn, scope)
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

function broadcastFleetUpdate(payload)
  -- Every Titan device that runs networkLoop listens on titan_router.
  rednet.broadcast(payload, PROTO_ROUTER)
  -- Also flood titan_net / titan_dc so Parent Center and any net-only listeners hear it.
  rednet.broadcast(payload, "titan_net")
  rednet.broadcast(payload, "titan_dc")
end

function isModemKind(kind)
  kind = tostring(kind or ""):lower()
  return kind == "modem"
end

function collectUpdateTargets(scope)
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

function unicastUpdate(targets, payload)
  for _, t in ipairs(targets) do
    rednet.send(t.id, payload, PROTO_ROUTER)
    rednet.send(t.id, payload, "titan_net")
  end
end

function sshForceUpdateDevice(targetId, password)
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
function runForceUpdate(scope, opts)
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

function noteTurtleSos(id, msg)
  id = tonumber(id)
  if not id or type(msg) ~= "table" then return end
  if msg.type == "quarry_sos_clear" or msg.sos == false then
    sosAlerts[id] = nil
    local any = false
    for _ in pairs(sosAlerts) do any = true; break end
    if not any then sosOverlay = false end
    return
  end
  sosAlerts[id] = {
    name = msg.name or msg.hostname or ("Turtle-" .. id),
    x = tonumber(msg.posX) or tonumber(msg.x),
    y = tonumber(msg.posY) or tonumber(msg.y),
    z = tonumber(msg.posZ) or tonumber(msg.z),
    reason = msg.reason or "out_of_fuel",
    seen = os.epoch("utc"),
  }
  sosOverlay = true
  -- Wake every board so the SOS is visible even if screensaver was up.
  if SCREEN_ROLES then
    for _, role in ipairs(SCREEN_ROLES) do
      screenOn[role] = true
    end
  end
  if boardWakeAt ~= nil then boardWakeAt = os.clock() end
  print(("[SOS] #%d %s out of fuel @ %s,%s,%s"):format(
    id, tostring(sosAlerts[id].name),
    tostring(sosAlerts[id].x or "?"),
    tostring(sosAlerts[id].y or "?"),
    tostring(sosAlerts[id].z or "?")))
end

function pruneSosAlerts()
  local nowMs = os.epoch("utc")
  for id, a in pairs(sosAlerts) do
    if not a.seen or (nowMs - a.seen) > (SOS_FRESH_SECS * 1000 * 3) then
      sosAlerts[id] = nil
    end
  end
  local any = false
  for _ in pairs(sosAlerts) do any = true; break end
  if not any then sosOverlay = false end
end

function claimMain()
  local rname = os.getComputerLabel() or ("Router-" .. os.getComputerID())
  local msg = {
    type = "main_claim", id = os.getComputerID(),
    label = rname, hostname = rname, kind = "main", role = "main", main = true,
  }
  if gpsCoords then
    msg.x, msg.y, msg.z = gpsCoords.x, gpsCoords.y, gpsCoords.z
  end
  rednet.broadcast(msg, PROTO_ROUTER)
end

-- Broadcast known router/modem positions for the pocket locator radar.
function broadcastFleetMap()
  local nodes = {}
  local rname = os.getComputerLabel() or ("Router-" .. os.getComputerID())
  if gpsCoords then
    nodes[#nodes + 1] = {
      id = os.getComputerID(), name = rname, kind = "main", main = true,
      x = gpsCoords.x, y = gpsCoords.y, z = gpsCoords.z,
    }
  end
  for id, d in pairs(seen) do
    local k = tostring(d.kind or "")
    if d.x and d.z and (k == "modem" or k == "main" or k == "router" or k == "extender") then
      nodes[#nodes + 1] = {
        id = id, name = d.hostname or d.name or ("#" .. id),
        kind = (k == "router" and d.role ~= "main" and not d.main) and "extender" or k,
        x = d.x, y = d.y, z = d.z,
      }
    end
  end
  rednet.broadcast({
    type = "fleet_map", from = os.getComputerID(), name = rname,
    x = gpsCoords and gpsCoords.x, y = gpsCoords and gpsCoords.y,
    z = gpsCoords and gpsCoords.z, nodes = nodes,
  }, PROTO_ROUTER)
end

function isWiredFresh(id)
  local t = wiredDirect[id]
  return type(t) == "number" and (os.clock() - t) < WIRED_FRESH
end

-- ONLINE = green, WIRED = cyan (online + on MAIN's cable), OFFLINE = red,
-- UNKNOWN = yellow (remembered, never heard live).
function statusOf(d, id)
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

function countOnlineOffline()
  local on, off, unk = 0, 0, 0
  for id, d in pairs(seen) do
    local st = statusOf(d, id)
    if st == "ONLINE" or st == "WIRED" then on = on + 1
    elseif st == "UNKNOWN" then unk = unk + 1
    else off = off + 1 end
  end
  return on, off, unk
end

function countWiredOnline()
  local n = 0
  for id, d in pairs(seen) do
    if statusOf(d, id) == "WIRED" then n = n + 1 end
  end
  return n
end

function deviceCount()
  local on = countOnlineOffline()
  return on
end

function statusRank(d, id)
  local st = statusOf(d, id)
  if st == "ONLINE" or st == "WIRED" then return 0 end
  if st == "UNKNOWN" then return 1 end
  return 2
end

-- Persist remembered systems so the monitor still lists them when offline.
-- Roster file is MAIN-only. Modems must not keep router_roster.cfg.
function saveRoster()
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

function loadRoster()
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

function clearRosterIfModem()
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
function sanitizeModemCfg(opts)
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
function resetRouting(mode)
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
function sortedIds()
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

function noteWiredDirect(id)
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

function refreshWiredFlags()
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
function classify(msg)
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

function isPerimeterTraffic(msg)
  if type(msg) ~= "table" or type(msg.type) ~= "string" then return false end
  local t = msg.type
  if t == "perimeter_fwd" or t == "perimeter_roster_req" or t == "perimeter_roster" then
    return false
  end
  return t:sub(1, 10) == "perimeter_"
end

function listOnlineKind(kind)
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
perimeterFwdSeen = {}
function perimeterFwdKey(originId, msg)
  return table.concat({
    tostring(originId or "?"),
    tostring(msg.type or "?"),
    tostring(msg.eventTs or msg.ts or msg.time or ""),
    tostring(msg.player or ""),
  }, "|")
end

-- Forward sensor perimeter_* traffic to online perimeter managers (mesh bridge).
function forwardPerimeterToManagers(originId, msg)
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

function deliverPerimeterFwd(msg)
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
function repeaterLoop()
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
function wiredLinkLoop()
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
function mainReplyBase()
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
function rosterTouch(id, msg, kind, doAssign)
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
-- GLOBAL lists Main routers only — extenders/modems stay off that board.
function ingestRemoteTopology(id, msg)
  if not isMain() or type(msg) ~= "table" then return end
  if id == os.getComputerID() then return end
  local role = tostring(msg.role or ""):lower()
  local kind = tostring(msg.kind or ""):lower()
  if role == "main" or kind == "main" or msg.main == true then
    rosterTouch(id, {
      hostname = msg.name, name = msg.name, kind = "main",
      x = msg.x, y = msg.y, z = msg.z,
      scope = "global", remote = true, role = "main", main = true,
    }, "main", false)
    -- Remember extender peers for mesh routing, but do NOT put them on GLOBAL.
    for _, peer in ipairs(msg.peers or {}) do
      local pid = tonumber(peer.id)
      if pid and pid ~= os.getComputerID() then
        local pkind = tostring(peer.kind or "extender"):lower()
        if pkind == "main" then
          rosterTouch(pid, {
            hostname = peer.name, name = peer.name, kind = "main",
            scope = "global", remote = true, via = id, main = true, role = "main",
          }, "main", false)
        else
          rosterTouch(pid, {
            hostname = peer.name, name = peer.name, kind = "extender",
            scope = "local", remote = false, via = id, role = "router",
          }, "extender", false)
        end
      end
    end
    for _, cell in ipairs(msg.cells or {}) do
      local cid = tonumber(cell.id)
      if cid then
        rosterTouch(cid, {
          hostname = cell.name, name = cell.name, kind = "modem",
          homeRouter = id, via = id, scope = "local",
          hub = msg.name,
        }, "modem", false)
      end
    end
  elseif role == "router" or kind == "router" or kind == "extender" then
    rosterTouch(id, {
      hostname = msg.name, name = msg.name, kind = "extender",
      x = msg.x, y = msg.y, z = msg.z,
      scope = "local", remote = false, role = "router",
    }, "extender", false)
  elseif role == "modem" or kind == "modem" then
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
        homeRouter = home, scope = "local",
        x = msg.x, y = msg.y, z = msg.z,
      }, "modem", false)
    end
  end
end

function directoryLoop()
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
      -- Urgent turtle fuel SOS — any protocol; show on all MAIN monitors.
      if msg.type == "quarry_sos" or msg.type == "quarry_sos_clear" then
        noteTurtleSos(id, msg)
      end
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
function normalizeScreenRole(role)
  role = tostring(role or ""):lower()
  if role == "local" or role == "cell" or role == "lan" then return "roster" end
  if role == "mesh" or role == "remote" or role == "wan" then return "global" end
  return role
end

function isScreenRole(role)
  role = normalizeScreenRole(role)
  for _, r in ipairs(SCREEN_ROLES) do
    if r == role then return true end
  end
  return false
end

-- Local = this hub's RF/wired cell + extender peers. Global = MAIN routers only.
function isMainDevice(id, d)
  if not d then return false end
  if id == os.getComputerID() then return isMain() end
  if d.main == true then return true end
  if tostring(d.role or ""):lower() == "main" then return true end
  if tostring(d.kind or ""):lower() == "main" then return true end
  return false
end

function isLocalDevice(id, d)
  if not d then return false end
  if isMainDevice(id, d) and id ~= os.getComputerID() then return false end
  if id == os.getComputerID() then return true end
  if d.scope == "local" then return true end
  if d.wired or isWiredFresh(id) then return true end
  if netCells[id] then return true end
  if tonumber(d.homeRouter) == os.getComputerID() then return true end
  local viaM = tonumber(d.viaModem)
  if viaM and netCells[viaM] then return true end
  local k = tostring(d.kind or ""):lower()
  if k == "extender" or k == "modem" or k == "device" then return true end
  -- Direct / unmarked online devices count as local to this hub.
  return not isMainDevice(id, d)
end

function isGlobalDevice(id, d)
  -- GLOBAL MESH = Main routers only (never extenders, modems, turtles, etc).
  return isMainDevice(id, d)
end

function sortedIdsScoped(scope)
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

function countScoped(scope)
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

function listMonitorNames()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

function wrapScreen(name)
  if not name or not peripheral.isPresent(name) then return nil end
  if peripheral.getType(name) ~= "monitor" then return nil end
  local m = peripheral.wrap(name)
  return m
end

--------------------------------------------------------------------------------
-- Monitor GUI: advanced (color) chrome + auto layout by screen size
--------------------------------------------------------------------------------
