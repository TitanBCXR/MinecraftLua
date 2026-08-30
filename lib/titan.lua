--[[
  titan.lua  -  Shared library for the Titan bot network (CC: Tweaked)
  Titan-Version: 1.2.28

  Provides:
    * Rednet protocol constants + message type enum
    * Modem discovery / open helpers (wireless + wired)
    * send / broadcast / recv wrappers with a consistent envelope
    * GPS-based turtle navigation (moveTo, goHome, heading calibration)
    * Mesh storm control: announce prefers MAIN unicast + jittered registerLoop
    * Boot update check (host-only or GitHub via manifest.base — never hardcodes a public URL)
    * Host OTA / install discover over the titan_router mesh (not RF-local only)

  Drop this file at:  lib/titan.lua  on EVERY computer & turtle,
  or copy it around with `pastebin`, disks, or `wget`.

  Load it with:   local titan = require("lib.titan")
  (or, if you keep it next to your program: local titan = dofile("titan.lua"))
]]

local titan = {}

-- The rednet protocol name every device on the network shares.
titan.PROTOCOL = "titan_net"
-- Main-router wired-cable probe (must match router.lua WIRED_CH).
titan.WIRED_CH = 65012

-- Message types. All network traffic is a table with a `type` field.
titan.MSG = {
  REGISTER      = "register",       -- bot  -> hub : "I exist"
  STATUS        = "status",         -- bot  -> hub : periodic status update
  COMMAND       = "command",        -- hub  -> bot : do something
  ACK           = "ack",            -- bot  -> hub : command received/finished
  POI_REGISTER  = "poi_register",   -- poi  -> hub : "I am a location at x,y,z"
  DISPATCH      = "dispatch",       -- poi  -> hub : "send a bot here to do X"
  PING          = "ping",           -- anyone -> anyone
  PONG          = "pong",

  -- Worker network (builders & gatherers <-> the "Bots Computer")
  BOT_REGISTER    = "bot_register",    -- worker -> botserver : name, type, home, pos
  GATHER_POST     = "gather_post",     -- worker -> botserver : "collect from my chest"
  GATHER_LIST_REQ = "gather_list_req", -- gatherer -> botserver : send open gather jobs
  GATHER_LIST     = "gather_list",     -- botserver -> gatherer : the gather board
  GATHER_CLAIM    = "gather_claim",    -- gatherer -> botserver : I'm taking job X
  GATHER_DONE     = "gather_done",     -- gatherer -> botserver : job X collected
  COAL_NEED       = "coal_need",       -- worker -> botserver : I need coal at home
  COAL_LIST_REQ   = "coal_list_req",   -- gatherer -> botserver : who needs coal
  COAL_LIST       = "coal_list",       -- botserver -> gatherer : coal drop-offs
  COAL_DONE       = "coal_done",       -- gatherer -> botserver : delivered coal to X
  BUILD_STORE     = "build_store",     -- builder -> botserver : here's a scanned build
  BUILD_LIST_REQ  = "build_list_req",  -- anyone -> botserver : list preset builds
  BUILD_LIST      = "build_list",      -- botserver -> asker : names of preset builds
  BUILD_GET_REQ   = "build_get_req",   -- builder -> botserver : send build <name>
  BUILD_GET       = "build_get",       -- botserver -> builder : build data
  BUILD_ORDER     = "build_order",     -- botserver -> builder : build <name> at x,y,z
  SCAN_ORDER      = "scan_order",      -- botserver -> builder : scan a WxHxL box -> name
  STUCK           = "stuck",           -- gatherer -> monitor : I'm stuck at x,y,z

  -- Worker deployment (the Parent Center / datacenter.lua pushes the config;
  -- setup is gated by the master password lock on the Parent Center's disk).
  WORKER_AWAIT    = "worker_await",    -- worker -> parent center : unconfigured, awaiting deployment
  WORKER_DEPLOY   = "worker_deploy",   -- parent center -> worker : deploy config (type, name, deposit)
  WORKER_DEPLOYED = "worker_deployed", -- worker -> parent center : deployment applied

  -- StorageManager (Create stock / inventories) network API
  STORAGE_HELLO   = "storage_hello",   -- storage -> fleet : I am a storage node
  STORAGE_PING    = "storage_ping",    -- anyone -> storage : who/status?
  STORAGE_STATUS  = "storage_status",  -- storage -> asker : mode, counts, ticker
  STORAGE_STOCK_REQ = "storage_stock_req", -- anyone -> storage : filter?, limit?
  STORAGE_STOCK   = "storage_stock",   -- storage -> asker : item rows
  STORAGE_REQUEST = "storage_request", -- anyone -> storage : request Create package
  STORAGE_REQUEST_ACK = "storage_request_ack",

  -- Factory control (Vault Manager <-> Factory Clutches)
  FACTORY_REGISTER = "factory_register", -- factory -> manager : I produce <item>
  FACTORY_STATUS   = "factory_status",   -- factory -> manager : heartbeat + state
  FACTORY_COMMAND  = "factory_command",  -- manager -> factory : ON|OFF
  FACTORY_ACK      = "factory_ack",      -- factory -> manager : command received
  
  -- Factory Admin (Pocket Tablet <-> Storage Manager)
  FACTORY_ADMIN_REQ  = "factory_admin_req",  -- tablet -> manager : want snap
  FACTORY_ADMIN_SNAP = "factory_admin_snap", -- manager -> tablet : full state snapshot
  FACTORY_ADMIN_COMMAND = "factory_admin_command", -- tablet -> manager : {factoryId, command=ON|OFF}
  FACTORY_ADMIN_SET  = "factory_admin_set",  -- tablet -> manager : {itemId, maxShare?, daysBuffer?, demandRate?}
  FACTORY_ADMIN_MODE = "factory_admin_mode", -- tablet -> manager : {factoryMode=true|false}

  -- Fleet mine / flatten jobs + Create break permits (Parent Center)
  MINE_JOB        = "mine_job",        -- datacenter -> miner : strip to dig
  MINE_JOB_ACK    = "mine_job_ack",    -- miner -> datacenter
  PERMIT_SYNC     = "permit_sync",     -- datacenter -> fleet : allowed break list
  PERMIT_REQUEST  = "permit_request",  -- anyone -> datacenter : ask to allow a block
  LOADER_ASSIGN   = "loader_assign",   -- datacenter -> loader : escort this miner
  SITE_JOB        = "site_job",        -- marker -> datacenter : dig this marked box
  SITE_JOB_ACK    = "site_job_ack",    -- datacenter -> marker
  SITE_CONFIG     = "site_config",     -- botserver -> workers : storage + fuel chest
  SITE_CONFIG_REQ = "site_config_req", -- worker -> botserver : please send site_config

  -- Perimeter (Advanced Peripherals player detectors)
  PERIMETER_ENTER = "perimeter_enter", -- sensor -> manager : player entered range
  PERIMETER_EXIT  = "perimeter_exit",  -- sensor -> manager : player left range
  PERIMETER_PULSE = "perimeter_pulse", -- sensor -> manager : who's in range now
  PERIMETER_HELLO = "perimeter_hello", -- sensor/manager announce
  PERIMETER_CONFIG = "perimeter_config", -- manager -> sensor : side/range/name
  PERIMETER_ASSIGN_REQ = "perimeter_assign_req", -- sensor -> manager : please auto-assign me
  PERIMETER_UPDATE = "perimeter_update", -- manager -> sensor : force OTA
  PERIMETER_UPDATE_ACK = "perimeter_update_ack", -- sensor -> manager : OTA ok (rebooting)
  PERIMETER_UPDATE_FAIL = "perimeter_update_fail", -- sensor -> manager : OTA failed
  PERIMETER_ROSTER_REQ = "perimeter_roster_req", -- manager/sensor -> main : list perimeter peers
  PERIMETER_ROSTER = "perimeter_roster", -- main -> requester : sensors + managers
  PERIMETER_FWD = "perimeter_fwd", -- main <-> perimeter : hop a payload to dest id
  PERIMETER_LOG_REQ = "perimeter_log_req", -- admin -> manager : recent activity
  PERIMETER_LOG = "perimeter_log", -- manager -> admin : events + present
  PERIMETER_ALERT = "perimeter_alert", -- manager -> admin : ENTER/EXIT push

  -- Network topology (ender routers + local RF modems)
  NET_LINK = "net_link",           -- admin/router -> node : peer / home / cell
  NET_LINK_ACK = "net_link_ack",   -- node -> requester
  NET_LINK_HELLO = "net_link_hello", -- backbone announce peers + cells
  NET_TOPO_REQ = "net_topo_req",   -- admin -> mesh : ask for topology
  NET_TOPO = "net_topo",           -- node -> admin : local link view
  NET_HOP = "net_hop",             -- backbone -> backbone : deliver toward dest
}

-- Compass headings (Minecraft world axes).
--   NORTH = -Z, SOUTH = +Z, EAST = +X, WEST = -X
titan.NORTH, titan.EAST, titan.SOUTH, titan.WEST = 0, 1, 2, 3

-- Blocks that NO bot may ever break (safety). Extend to taste.
titan.RESTRICTED = {
  ["minecraft:bedrock"] = true,
  ["minecraft:chest"] = true, ["minecraft:trapped_chest"] = true,
  ["minecraft:barrel"] = true, ["minecraft:hopper"] = true,
  ["minecraft:spawner"] = true,
  ["minecraft:end_portal_frame"] = true, ["minecraft:end_portal"] = true,
  ["minecraft:obsidian"] = true,
  -- Rails / tracks (vanilla + common Create train track ids)
  ["minecraft:rail"] = true,
  ["minecraft:powered_rail"] = true,
  ["minecraft:detector_rail"] = true,
  ["minecraft:activator_rail"] = true,
}
-- Any block whose id starts with one of these prefixes is also protected
-- (keeps bots from mining computers, turtles, Create machines, train parts).
-- Override specific ids / prefixes with titan.allowPermit / PERMIT_SYNC.
titan.RESTRICTED_PREFIXES = {
  "computercraft:", "advancedperipherals:",
  "create:", "createaddition:", "railways:", "interiors:",
}

-- Temporary break permits from Parent Center: [id or "prefix:"] = expiresUtc|true
titan.permits = {}

function titan.clearPermits()
  titan.permits = {}
end

function titan.setPermits(map)
  titan.permits = type(map) == "table" and map or {}
end

function titan.allowPermit(key, expiresUtc)
  if not key or key == "" then return end
  titan.permits[tostring(key)] = expiresUtc or true
end

function titan.revokePermit(key)
  if key then titan.permits[tostring(key)] = nil end
end

function titan.isPermitted(name)
  if not name then return false end
  local now = os.epoch("utc")
  local exp = titan.permits[name]
  if exp == true then return true end
  if type(exp) == "number" and exp > now then return true end
  for key, e in pairs(titan.permits) do
    if type(key) == "string" and #key > 0 and name:sub(1, #key) == key then
      if e == true or (type(e) == "number" and e > now) then return true end
    end
  end
  return false
end

function titan.isRestricted(name)
  if not name then return false end
  if titan.isPermitted(name) then return false end
  if titan.RESTRICTED[name] then return true end
  for _, p in ipairs(titan.RESTRICTED_PREFIXES) do
    if name:sub(1, #p) == p then return true end
  end
  return false
end

-- Monitor redraw interval (seconds). Used by hub / botserver / datacenter /
-- marker / storage / router. Clamp keeps loops sane on busy servers.
titan.MONRATE_MIN, titan.MONRATE_MAX = 0.25, 120

function titan.normalizeMonRate(secs, defaultSecs)
  local d = tonumber(defaultSecs) or 1
  local n = tonumber(secs)
  if not n or n ~= n then return d end   -- NaN guard
  if n < titan.MONRATE_MIN then n = titan.MONRATE_MIN end
  if n > titan.MONRATE_MAX then n = titan.MONRATE_MAX end
  return n
end

-- Fleet bot labels: Type-<computerId> (never reuse a player-placed turtle name).
function titan.uniqueBotName(botType, computerId)
  local t = tostring(botType or "bot"):lower()
  local prefixes = {
    builder = "Builder", gatherer = "Gatherer", miner = "Miner",
    loader = "Loader", worker = "Worker", marker = "Site",
  }
  local p = prefixes[t] or "Bot"
  return p .. "-" .. tostring(computerId or os.getComputerID())
end

-- True if a label looks like a Titan-assigned unique name (Builder-12, etc.).
function titan.isUniqueBotName(name, botType)
  if type(name) ~= "string" or name == "" then return false end
  local prefix, id = name:match("^([A-Za-z]+)%-(%d+)$")
  if not prefix or not id then return false end
  if botType then
    return name == titan.uniqueBotName(botType, id)
  end
  local known = {
    Builder = true, Gatherer = true, Miner = true, Loader = true, Worker = true, Bot = true,
  }
  return known[prefix] == true
end

-- Decide whether a gatherer should pick up an item, given a gather request.
--   req.accepts == "all"           -> take everything
--   req.accepts == { "a", "b" }    -> take only those (whitelist)  [default]
--   req.mode    == "exclude"       -> take everything EXCEPT the list (blacklist)
function titan.itemAccepted(name, req)
  local acc = req.accepts
  if acc == nil or acc == "all" then return true end
  local inList = false
  for _, it in ipairs(acc) do if it == name then inList = true break end end
  if req.mode == "exclude" then return not inList end
  return inList
end

--------------------------------------------------------------------------------
-- Networking
--------------------------------------------------------------------------------

local function titanIsWiredModem(side)
  if not side or not peripheral.isPresent(side) then return false end
  if peripheral.getType(side) ~= "modem" then return false end
  local ok, wireless = pcall(peripheral.call, side, "isWireless")
  return ok and wireless == false
end

-- Open every attached modem for rednet AND the rednet repeat channel, so this
-- device can join the routing mesh (see titan.relayLoop / titan.networkLoop).
-- Supports wireless and wired modems. Returns the first modem side found.
function titan.openModem()
  local found = nil
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      -- CHANNEL_REPEAT (65533): CraftOS hop channel used by router.lua and every
      -- mesh peer. Opening it here lets relayLoop forward traffic for neighbours.
      pcall(peripheral.call, side, "open", rednet.CHANNEL_REPEAT)
      if titanIsWiredModem(side) then
        pcall(peripheral.call, side, "open", titan.WIRED_CH)
      end
      if not found then found = side end
    end
  end
  if not found then
    error("No modem attached. Place a wireless or wired modem on this device.", 0)
  end
  return found
end

-- List every modem side that is currently open for rednet (for relays).
function titan.modemSides()
  local sides = {}
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" and rednet.isOpen(side) then
      sides[#sides + 1] = side
    end
  end
  return sides
end

function titan.wiredModemSides()
  local sides = {}
  for _, side in ipairs(titan.modemSides()) do
    if titanIsWiredModem(side) then sides[#sides + 1] = side end
  end
  return sides
end

-- Answer MAIN's wired-cable probes so the roster can mark this device WIRED.
function titan.wiredLinkLoop(kind)
  for _, side in ipairs(titan.wiredModemSides()) do
    pcall(peripheral.call, side, "open", titan.WIRED_CH)
  end
  while true do
    local ev, side, ch, _, msg = os.pullEvent("modem_message")
    if ev and ch == titan.WIRED_CH and type(msg) == "table"
       and msg.type == "wired_probe" and titanIsWiredModem(side) then
      local pong = {
        type = "wired_pong",
        id = os.getComputerID(),
        name = titan.hostname(kind),
        kind = kind or "device",
      }
      for _, s in ipairs(titan.wiredModemSides()) do
        pcall(peripheral.call, s, "transmit", titan.WIRED_CH, titan.WIRED_CH, pong)
      end
    end
  end
end

-- Wrap a payload in a standard envelope and send it to a specific computer id.
function titan.send(id, msgType, data)
  local msg = data or {}
  msg.type = msgType
  msg.from = os.getComputerID()
  msg.name = titan.hostname()
  msg.hostname = msg.name
  msg.ts   = os.epoch("utc")
  rednet.send(id, msg, titan.PROTOCOL)
end

-- Broadcast a payload to everyone on the protocol.
function titan.broadcast(msgType, data)
  local msg = data or {}
  msg.type = msgType
  msg.from = os.getComputerID()
  msg.name = titan.hostname()
  msg.hostname = msg.name
  msg.ts   = os.epoch("utc")
  rednet.broadcast(msg, titan.PROTOCOL)
end

-- Receive the next protocol message. Returns senderId, msg (or nil on timeout).
function titan.recv(timeout)
  local id, msg = rednet.receive(titan.PROTOCOL, timeout)
  if type(msg) ~= "table" then return nil end
  return id, msg
end

--------------------------------------------------------------------------------
-- Routing mesh (see router.lua)
--
-- Every Titan device should join the mesh so messages hop across wireless range:
--   * announce  -> show up in the router's directory
--   * relayLoop -> re-transmit rednet hops (same mechanism as CraftOS `repeat`
--                 and router.lua), so a builder/gatherer/miner in range can
--                 forward traffic for peers that can't hear the main router
--   * OTA       -> accept fleet update broadcasts from the main router
--   * SSH host  -> accept remote shell sessions (see titan.sshConnect)
--
-- Use titan.networkLoop(kind) as one parallel task in every program.
--------------------------------------------------------------------------------
titan.ROUTER_PROTOCOL = "titan_router"
titan.DC_PROTOCOL     = "titan_dc"

-- Hostname shared on every network registration. Uses the computer label; if
-- none is set yet, assigns "<Kind>-<id>" (e.g. Worker-12) so the roster never
-- shows a blank name.
local lastAnnounceKind = "device"

function titan.hostname(kind)
  local label = os.getComputerLabel()
  if label and label ~= "" then return label end
  local prefix = "Device"
  if type(kind) == "string" and kind ~= "" then
    prefix = kind:sub(1, 1):upper() .. kind:sub(2)
  end
  label = prefix .. "-" .. os.getComputerID()
  os.setComputerLabel(label)
  return label
end

-- Set the network hostname (computer label) and re-announce to the router so
-- the roster updates immediately. Returns the new hostname, or nil + err.
function titan.setHostname(name, kind)
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil, "empty hostname" end
  if #name > 32 then return nil, "hostname too long (max 32)" end
  os.setComputerLabel(name)
  titan.announce(kind or lastAnnounceKind)
  return name
end

-- Persisted network membership (main router id, last auth).
titan.NET_CFG = ".titan-net"
-- Kinds that also re-auth with the Parent Center / data server.
titan.DC_AUTH_KINDS = { bot = true, worker = true, miner = true, storage = true }

function titan.readNetCfg()
  if not fs.exists(titan.NET_CFG) then return {} end
  local f = fs.open(titan.NET_CFG, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  return type(d) == "table" and d or {}
end

function titan.writeNetCfg(c)
  local f = fs.open(titan.NET_CFG, "w"); f.write(textutils.serialize(c)); f.close()
end

function titan.getMainRouterId()
  local c = titan.readNetCfg()
  return c.mainRouterId
end

function titan.setMainRouterId(id)
  local c = titan.readNetCfg()
  c.mainRouterId = id
  c.authedAt = os.epoch("utc")
  titan.writeNetCfg(c)
end

-- Discover the MAIN router (not modem-only repeaters). Returns id or nil.
function titan.findMainRouter(timeout)
  rednet.broadcast({ type = "where_main", name = os.getComputerLabel() }, titan.ROUTER_PROTOCOL)
  local deadline = os.clock() + (timeout or 3)
  while os.clock() < deadline do
    local id, msg = rednet.receive(titan.ROUTER_PROTOCOL, deadline - os.clock())
    if id and type(msg) == "table" and msg.type == "main_here" then
      titan.setMainRouterId(id)
      return id, msg
    end
  end
  -- Fall back to a remembered id.
  return titan.getMainRouterId()
end

function titan.systemVersion()
  local cat = titan.loadVersionCatalog()
  return (cat and cat.system) or nil
end

-- Stagger fleet chatter by computer id (same idea as quarry / router hubs).
function titan.netJitter(scale)
  scale = tonumber(scale) or 1
  if scale <= 0 then return end
  local id = os.getComputerID() or 0
  sleep((((id * 37) % 1000) / 1000) * scale)
end

-- opts.flood = true → force broadcast. Default: unicast MAIN when known (less RF storm);
-- broadcast when MAIN unknown so hop routers can still discover the device.
function titan.announce(kind, opts)
  opts = opts or {}
  if type(kind) == "string" and kind ~= "" then lastAnnounceKind = kind end
  local host = titan.hostname(lastAnnounceKind)
  local msg = {
    type = "hello", kind = lastAnnounceKind, name = host, hostname = host,
    mainRouterId = titan.getMainRouterId(),
    version = titan.systemVersion(),
  }
  local mainId = titan.getMainRouterId()
  if mainId and not opts.flood then
    rednet.send(mainId, msg, titan.ROUTER_PROTOCOL)
  else
    rednet.broadcast(msg, titan.ROUTER_PROTOCOL)
  end
end

-- After a successful OTA, leave a flag so the next boot can ACK the main router.
titan.UPDATED_FLAG = ".titan-updated"

-- Snapshot package path -> version for OTA ACK diffs.
function titan.packageVersionMap(paths)
  local catalog = titan.loadVersionCatalog()
  local map = {}
  if type(paths) ~= "table" then
    local list = titan.readPackageList()
    paths = list or titan.scanLocalScripts() or {}
  end
  for _, path in ipairs(paths) do
    if path and path ~= "" then
      if fs.exists(path) and not fs.isDir(path) then
        map[path] = titan.packageVersion(path, catalog) or "?"
      else
        map[path] = nil
      end
    end
  end
  return map
end

-- Build { name, path, from, to } rows for packages whose version changed.
function titan.diffPackageVersions(before, after)
  local keys, seen = {}, {}
  for path in pairs(before or {}) do
    if not seen[path] then seen[path] = true; keys[#keys + 1] = path end
  end
  for path in pairs(after or {}) do
    if not seen[path] then seen[path] = true; keys[#keys + 1] = path end
  end
  table.sort(keys)
  local changes = {}
  for _, path in ipairs(keys) do
    local from = before and before[path] or nil
    local to = after and after[path] or nil
    if tostring(from or "") ~= tostring(to or "") then
      changes[#changes + 1] = {
        name = titan.packageName(path),
        path = path,
        from = from ~= nil and tostring(from) or "—",
        to = to ~= nil and tostring(to) or "—",
      }
    end
  end
  return changes
end

function titan.markPendingUpdateAck(prevVersion, targetVersion, packages)
  local f = fs.open(titan.UPDATED_FLAG, "w")
  f.write(textutils.serialize({
    prev = prevVersion,
    target = targetVersion,
    packages = type(packages) == "table" and packages or {},
    at = os.epoch("utc"),
  }))
  f.close()
end

-- If we just finished an OTA reboot, tell the main router we are updated.
function titan.reportUpdatedIfPending(kind)
  if not fs.exists(titan.UPDATED_FLAG) then return false end
  local f = fs.open(titan.UPDATED_FLAG, "r")
  local d = textutils.unserialize(f.readAll()); f.close()
  pcall(fs.delete, titan.UPDATED_FLAG)
  local host = titan.hostname(kind)
  local ver = titan.systemVersion()
  local packages = type(d) == "table" and type(d.packages) == "table" and d.packages or {}
  -- Fallback row when we only know system versions.
  if #packages == 0 and type(d) == "table" and (d.prev or d.target or ver) then
    packages = { {
      name = "system", path = "versions.lua",
      from = tostring(d.prev or "—"), to = tostring(ver or d.target or "—"),
    } }
  end
  rednet.broadcast({
    type = "updated", kind = kind or lastAnnounceKind,
    name = host, hostname = host,
    version = ver,
    prev = type(d) == "table" and d.prev or nil,
    target = type(d) == "table" and d.target or nil,
    packages = packages,
    from = os.getComputerID(),
  }, titan.ROUTER_PROTOCOL)
  print(("[OTA] Reported updated -> v%s (%d package change(s))"):format(
    tostring(ver or "?"), #packages))
  return true
end

-- Re-auth with the Parent Center / data server (bots, workers, miners).
function titan.authWithDataCenter(kind)
  local host = titan.hostname(kind)
  rednet.broadcast({
    type = "device_auth", kind = kind or lastAnnounceKind,
    name = host, hostname = host, from = os.getComputerID(),
  }, titan.DC_PROTOCOL)
  local deadline = os.clock() + 3
  while os.clock() < deadline do
    local id, msg = rednet.receive(titan.DC_PROTOCOL, deadline - os.clock())
    if id and type(msg) == "table" and msg.type == "auth_ok" then
      local c = titan.readNetCfg()
      c.dataCenterId = id
      c.dcAuthedAt = os.epoch("utc")
      titan.writeNetCfg(c)
      return true, id
    end
  end
  return false, "no data center response"
end

-- Full network re-auth: find main router, announce, and (for bots) auth with DC.
-- Returns ok, detail.
function titan.reauth(kind)
  kind = kind or lastAnnounceKind or "device"
  local mainId, mainMsg = titan.findMainRouter(3)
  titan.announce(kind)
  -- Also send a directed hello if we know the main router.
  if mainId then
    rednet.send(mainId, {
      type = "hello", kind = kind, name = titan.hostname(kind),
      hostname = titan.hostname(kind), auth = true,
    }, titan.ROUTER_PROTOCOL)
  end

  local detail = { mainRouterId = mainId, mainLabel = mainMsg and (mainMsg.hostname or mainMsg.label) }
  if titan.DC_AUTH_KINDS[kind] then
    local ok, dcId = titan.authWithDataCenter(kind)
    detail.dataCenter = ok and dcId or nil
    detail.dcOk = ok
  end
  return mainId ~= nil, detail
end

-- Announce periodically AND listen for OTA update / forced reauth from main router.
function titan.registerLoop(kind, period)
  period = tonumber(period) or 35
  -- Re-auth immediately on boot / after OTA reboot (stagger so fleets don't sync-thump).
  titan.netJitter(1.5)
  print("[net] Re-authenticating with the network...")
  local ok, detail = titan.reauth(kind)
  if ok then
    print(("[net] Main router #%s (%s)"):format(
      tostring(detail.mainRouterId), tostring(detail.mainLabel or "?")))
  else
    print("[net] No main router found yet — will keep trying.")
  end
  if titan.DC_AUTH_KINDS[kind] then
    if detail and detail.dcOk then
      print(("[net] Data center auth ok (#%s)"):format(tostring(detail.dataCenter)))
    else
      print("[net] Data center auth pending (Parent Center offline?)")
    end
  end
  -- If this boot follows a fleet OTA, ACK the main router.
  titan.reportUpdatedIfPending(kind)

  local nextAnnounce = os.clock() + period + (((os.getComputerID() or 0) % 10))
  while true do
    if os.clock() >= nextAnnounce then
      titan.announce(kind)
      nextAnnounce = os.clock() + period
    end
    local id, msg = rednet.receive(titan.ROUTER_PROTOCOL, 0.4)
    local batch = {}
    if type(msg) == "table" and id then batch[#batch + 1] = { id, msg } end
    for _ = 1, 12 do
      local id2, msg2 = rednet.receive(titan.ROUTER_PROTOCOL, 0)
      if not id2 then break end
      if type(msg2) == "table" then batch[#batch + 1] = { id2, msg2 } end
    end
    for bi = 1, #batch do
      id, msg = batch[bi][1], batch[bi][2]
      -- Optional app hook (e.g. locator radar) — runs before built-in handlers.
      if type(titan.onRouterMessage) == "function" then
        pcall(titan.onRouterMessage, id, msg)
      end
      if msg.type == "main_claim" or msg.type == "main_here" then
        titan.setMainRouterId(id)
      elseif msg.type == "reauth" then
        print("[net] Re-auth requested by router #" .. tostring(id))
        titan.netJitter(1)
        titan.reauth(kind)
      elseif msg.type == "update" then
        print("")
        print(("[OTA] Fleet update from router #%s (target v%s) — downloading..."):format(
          tostring(id), tostring(msg.targetVersion or "?")))
        if msg.mainRouterId then titan.setMainRouterId(msg.mainRouterId) end
        local prev = titan.systemVersion()
        local uok, detail = titan.updateSelf()
        if uok then
          local pkgs = type(detail) == "table" and detail.packages or nil
          titan.markPendingUpdateAck(prev, msg.targetVersion or titan.systemVersion(), pkgs)
          print("[OTA] Updated. Rebooting in 2s (will ACK main on boot)..."); os.sleep(2); os.reboot()
        else
          print("[OTA] Update failed: " .. tostring(detail))
          rednet.send(id, {
            type = "update_fail", version = prev, err = tostring(detail),
            name = titan.hostname(kind), hostname = titan.hostname(kind),
          }, titan.ROUTER_PROTOCOL)
        end
      end
    end
  end
end

-- Optional GPS host coords for devices that also run relayLoop (e.g. perimeter
-- sensors). Same protocol as stock `gps host` / router gpshost.
titan._gpsHost = nil  -- { x, y, z } or nil/false to disable

function titan.setGpsHost(coords)
  if coords == false or coords == nil then
    titan._gpsHost = nil
    return nil
  end
  if type(coords) ~= "table" or coords.x == nil or coords.z == nil then
    return nil, "need {x,y,z}"
  end
  titan._gpsHost = {
    x = math.floor(tonumber(coords.x) + 0.5),
    y = math.floor(tonumber(coords.y or 0) + 0.5),
    z = math.floor(tonumber(coords.z) + 0.5),
  }
  return titan._gpsHost
end

function titan.getGpsHost()
  return titan._gpsHost
end

-- Mesh repeater: forward rednet hop packets on CHANNEL_REPEAT (de-duplicated).
-- Also answers gps.locate PINGs when titan.setGpsHost(...) is active (one
-- modem_message consumer — avoids racing a separate gpsHostLoop).
-- Faithful to CraftOS `repeat` / router.lua. Safe to run on every bot — if the
-- main router is out of range, nearby workers/miners keep the network linked.
function titan.relayLoop()
  local REPEAT = rednet.CHANNEL_REPEAT
  local GPS = gps.CHANNEL_GPS
  local relayed = {}   -- [nMessageID] = expireClock
  -- Ensure the repeat + GPS channels are open (in case openModem ran before an upgrade).
  for _, side in ipairs(titan.modemSides()) do
    pcall(peripheral.call, side, "open", REPEAT)
    pcall(peripheral.call, side, "open", GPS)
  end
  -- Only pull modem_message so keyboard/read() in parallel consoles is never starved.
  while true do
    local _, side, channel, replyChannel, message = os.pullEvent("modem_message")
    if channel == GPS and message == "PING" and replyChannel and titan._gpsHost then
      local c = titan._gpsHost
      pcall(peripheral.call, side, "transmit", replyChannel, GPS, { c.x, c.y, c.z })
    elseif channel == REPEAT and type(message) == "table"
       and message.nMessageID and message.nRecipient then
      local now = os.clock()
      for mid, exp in pairs(relayed) do
        if exp <= now then relayed[mid] = nil end
      end
      if not relayed[message.nMessageID] then
        relayed[message.nMessageID] = now + 30
        local sides = titan.modemSides()
        if #sides == 0 then sides = { side } end
        for _, m in ipairs(sides) do
          peripheral.call(m, "transmit", REPEAT, replyChannel, message)
          if message.nRecipient ~= REPEAT then
            peripheral.call(m, "transmit", message.nRecipient, replyChannel, message)
          end
        end
      end
    end
  end
end

-- Full mesh participation: announce + OTA listener + hop relay + SSH host.
-- Drop this into parallel.waitForAny as:  function() titan.networkLoop("worker") end
function titan.networkLoop(kind, period)
  parallel.waitForAny(
    function() titan.registerLoop(kind, period) end,
    function() titan.relayLoop() end,
    function() titan.sshHostLoop(kind) end,
    function() titan.wiredLinkLoop(kind) end
  )
end

--------------------------------------------------------------------------------
-- Remote shell ("SSH") over rednet
--
-- From console/admin/router:  ssh <id|label>           interactive session
--                             ssh <id|label> <command>  one-shot remote exec
--                             say <id|label> <message>  print on that device's screen
--
-- Jump: if the target is out of direct range, SSH hops through modem/router
-- shells (proxy sessions) until it reaches the destination — same idea as
-- jumping hosts. Auth: master password via the Parent Center.
--
-- Every device running titan.networkLoop (or sshHostLoop) hosts a shell.
-- Remote lines run the device's registered app commands (if any), then CraftOS
-- shell / turtle builtins. `reboot` acks then os.reboot; `exit` disconnects.
-- `say` is display-only (no password); it prints on term.native().
--------------------------------------------------------------------------------
titan.SSH_PROTOCOL = "titan_ssh"
titan.SSH_MAX_JUMPS = 8

local sshSessions   = {}   -- [token] = session table
local sshClientQ    = {}   -- inbox for replies (host loop + client share one receiver)
local sshHostPending = {}  -- host requests received while a dial/jump is in progress
local sshKind       = "device"
local sshAppHandler = nil  -- optional fn(line) -> false to fall through to shell
local sshExecActive = false

-- Programs with a local REPL should register so SSH can run the same commands.
-- handler(line): print normally; return false if unhandled (try shell next).
function titan.setSshHandler(handler)
  sshAppHandler = type(handler) == "function" and handler or nil
end

function titan.clearSshHandler()
  sshAppHandler = nil
end

-- True while an authenticated SSH exec is running on this host.
-- Use in requireAuth()-style gates: the session already checked the master password.
function titan.sshIsAuthed()
  return sshExecActive == true
end

local function sshSend(id, msg)
  rednet.send(id, msg, titan.SSH_PROTOCOL)
end

local function sshNewToken()
  return tostring(os.getComputerID()) .. "-" .. tostring(os.epoch("utc")) .. "-" .. tostring(math.random(1000, 9999))
end

local function sshIsClientReply(t)
  return t == "ssh_pong" or t == "ssh_ok" or t == "ssh_deny"
      or t == "ssh_result" or t == "ssh_say_ack"
end

-- Print a Say message on the real local screen (not a redirected monitor/SSH capture).
local function sshPrintSay(from, text)
  local native = (term.native and term.native()) or term
  local prev = (term.current and term.current()) or nil
  local redirected = prev and native and prev ~= native
  if redirected then term.redirect(native) end
  pcall(function()
    if term.setTextColor then term.setTextColor(colors.yellow) end
    print("")
    write("[Say from " .. tostring(from) .. "] ")
    if term.setTextColor then term.setTextColor(colors.white) end
    print(tostring(text))
  end)
  if redirected then term.redirect(prev) end
end

-- Wait for a client-bound reply. Also pumps rednet so nested jump dials work
-- while sshHostLoop is blocked inside a proxy handler.
local function sshClientWait(timeout, pred)
  local deadline = os.clock() + (timeout or 5)
  while os.clock() < deadline do
    for i = 1, #sshClientQ do
      local item = sshClientQ[i]
      if pred(item.id, item.msg) then
        table.remove(sshClientQ, i)
        return item.id, item.msg
      end
    end
    local remain = deadline - os.clock()
    if remain <= 0 then break end
    local id, msg = rednet.receive(titan.SSH_PROTOCOL, math.min(0.15, remain))
    if type(msg) == "table" and id then
      if sshIsClientReply(msg.type) then
        if pred(id, msg) then return id, msg end
        sshClientQ[#sshClientQ + 1] = { id = id, msg = msg }
      else
        sshHostPending[#sshHostPending + 1] = { id = id, msg = msg }
      end
    end
  end
  return nil, nil
end

-- Capture print/write output into a string buffer while running fn().
local function sshWithCapture(fn)
  local out, ox, oy = {}, 1, 1
  local fake = {}
  function fake.write(s) out[#out + 1] = tostring(s) end
  function fake.blit(t) out[#out + 1] = tostring(t) end
  function fake.clear() end
  function fake.clearLine() end
  function fake.getCursorPos() return ox, oy end
  function fake.setCursorPos(x, y) ox, oy = x or 1, y or 1 end
  function fake.getSize() return 51, 19 end
  function fake.scroll() out[#out + 1] = "\n" end
  function fake.setCursorBlink() end
  function fake.isColor() return term.isColor and term.isColor() or false end
  function fake.isColour() return fake.isColor() end
  function fake.getTextColor() return colors.white end
  function fake.getBackgroundColor() return colors.black end
  function fake.setTextColor() end
  function fake.setBackgroundColor() end
  function fake.getTextColour() return colors.white end
  function fake.getBackgroundColour() return colors.black end
  function fake.setTextColour() end
  function fake.setBackgroundColour() end
  -- Interactive prompts (confirmations / passwords) cannot be answered over SSH.
  local oldRead = read
  local function sshRead()
    out[#out + 1] = "\n[ssh] interactive input unavailable — cancelled\n"
    return ""
  end
  local oldTerm = term.redirect(fake)
  _G.read = sshRead
  sshExecActive = true
  local ok, a, b, c = pcall(fn)
  sshExecActive = false
  _G.read = oldRead
  term.redirect(oldTerm)
  local text = table.concat(out)
  if not ok then
    if text ~= "" then text = text .. "\n" end
    text = text .. "error: " .. tostring(a)
    return text, false, a, b, c
  end
  return text, true, a, b, c
end

local function sshTurtleBuiltin(low)
  if not turtle then return nil end
  local cmd, rest = low:match("^(%S+)%s*(.*)$")
  cmd = (cmd or ""):lower()
  rest = rest or ""
  if cmd == "fuel" then
    return "fuel: " .. tostring(turtle.getFuelLevel()), true
  elseif cmd == "refuel" then
    local fuelSlot = (titan.nav and titan.nav.FUEL_SLOT) or 16
    pcall(function()
      turtle.select(fuelSlot); turtle.refuel()
      for s = 1, 16 do
        if s ~= fuelSlot then turtle.select(s); turtle.refuel() end
      end
      turtle.select(1)
    end)
    return ("fuel: %s (fuel slot %d)"):format(tostring(turtle.getFuelLevel()), fuelSlot), true
  elseif cmd == "move" then
    local dir, n = rest:match("^(%S+)%s*(%d*)")
    dir = (dir or ""):lower()
    n = tonumber(n) or 1
    local moves = {
      forward = turtle.forward, back = turtle.back, up = turtle.up, down = turtle.down,
      left = turtle.turnLeft, right = turtle.turnRight,
    }
    local fn = moves[dir]
    if not fn then
      return "usage: move <forward|back|up|down|left|right> [n]", false
    end
    local moved = 0
    for i = 1, n do
      if not fn() then
        return ("blocked after %d"):format(moved), false
      end
      moved = moved + 1
    end
    return ("moved %s x%d"):format(dir, moved), true
  end
  return nil
end

-- Capture shell / builtin output. Returns out, ok [, doReboot]
local function sshCaptureRun(cmdline)
  local low = tostring(cmdline or ""):match("^%s*(.-)%s*$") or ""
  local lowl = low:lower()
  -- Never shell.run("reboot") — it won't return an ack to the SSH client.
  if lowl == "reboot" or lowl:match("^reboot%s") then
    return "Rebooting...", true, true
  end
  if lowl == "id" or lowl == "whoami" then
    return ("#%d %s"):format(os.getComputerID(), os.getComputerLabel() or ""), true, false
  end

  local turtleOut, turtleOk = sshTurtleBuiltin(low)
  if turtleOut ~= nil then
    return turtleOut, turtleOk, false
  end

  if not shell then
    return "(no shell on this device — app commands need a running Titan program)", false, false
  end
  local text, okCall, shellOk = sshWithCapture(function()
    return shell.run(low)
  end)
  if text == "" then text = shellOk and "(ok)" or "(failed)" end
  return text, (okCall and shellOk) and true or false, false
end

-- App handler (same commands as the local prompt), then CraftOS shell fallback.
local function sshRunLocal(line)
  local low = tostring(line or ""):match("^%s*(.-)%s*$") or ""
  local lowl = low:lower()
  if lowl == "reboot" or lowl:match("^reboot%s") then
    return "Rebooting...", true, true
  end
  if lowl == "id" or lowl == "whoami" then
    return ("#%d %s"):format(os.getComputerID(), os.getComputerLabel() or ""), true, false
  end
  -- Built-in package update so remote force-update works even without console.lua.
  if lowl == "update" or lowl == "upgrade"
      or lowl:match("^update%s") or lowl:match("^upgrade%s") then
    local text, callOk, uok, detail = sshWithCapture(function()
      print("[OTA] Remote update via SSH...")
      local ok, d = titan.updateSelf()
      if ok then
        local ver = titan.systemVersion()
        print("[OTA] Updated to v" .. tostring(ver or "?"))
      else
        print("[OTA] Failed: " .. tostring(d))
      end
      return ok, d
    end)
    if not callOk then return text, false, false end
    if uok then
      if text == "" then text = "Updated — rebooting..." end
      return text, true, true
    end
    return text, false, false
  end

  if sshAppHandler then
    local text, callOk, handled = sshWithCapture(function()
      return sshAppHandler(low)
    end)
    if not callOk then
      return text, false, false
    end
    -- handler may return false to fall through to shell/turtle builtins
    -- return "reboot" to ack the SSH client then reboot (for remote update -y)
    if handled == "reboot" then
      if text == "" then text = "Rebooting..." end
      return text, true, true
    end
    if handled ~= false then
      if text == "" then text = "(ok)" end
      return text, true, false
    end
    -- keep any "unhandled" prints, then append shell output
    local shellText, shellOk, doReboot = sshCaptureRun(low)
    if doReboot then return shellText, shellOk, true end
    if text ~= "" and text ~= "(ok)" then
      if shellText and shellText ~= "" then
        return text .. "\n" .. shellText, shellOk, false
      end
      return text, false, false
    end
    return shellText, shellOk, false
  end

  return sshCaptureRun(low)
end

local function sshVisitedHas(visited, id)
  if type(visited) ~= "table" then return false end
  for _, v in ipairs(visited) do
    if v == id then return true end
  end
  return false
end

local function sshVisitedNext(visited)
  local n = {}
  if type(visited) == "table" then
    for i, v in ipairs(visited) do n[i] = v end
  end
  n[#n + 1] = os.getComputerID()
  return n
end

-- Collect nearby SSH peers (for jump candidates). Prefer modem/router kinds.
function titan.sshListPeers(timeout)
  rednet.broadcast({ type = "ssh_ping", want = "", list = true }, titan.SSH_PROTOCOL)
  local found, seen = {}, {}
  local deadline = os.clock() + (timeout or 1.5)
  while os.clock() < deadline do
    local id, msg = sshClientWait(deadline - os.clock(), function(_, m)
      return type(m) == "table" and m.type == "ssh_pong"
    end)
    if id and msg and not seen[id] and id ~= os.getComputerID() then
      seen[id] = true
      found[#found + 1] = {
        id = id, name = msg.name or msg.hostname,
        kind = msg.kind or "device",
      }
    end
  end
  table.sort(found, function(a, b)
    local function rank(k)
      k = tostring(k or "")
      if k == "modem" or k == "router" then return 0 end
      if k == "console" or k == "admin" or k == "datacenter" then return 1 end
      return 2
    end
    local ra, rb = rank(a.kind), rank(b.kind)
    if ra ~= rb then return ra < rb end
    return (a.id or 0) < (b.id or 0)
  end)
  return found
end

-- Resolve a computer id or label to an id. Broadcasts a ping; peers reply.
function titan.sshResolve(ref, timeout)
  local asNum = tonumber(ref)
  if asNum then return asNum end
  local want = tostring(ref or ""):lower()
  if want == "" then return nil end
  rednet.broadcast({ type = "ssh_ping", want = want }, titan.SSH_PROTOCOL)
  local id = sshClientWait(timeout or 3, function(_, m)
    if type(m) ~= "table" or m.type ~= "ssh_pong" then return false end
    local name = tostring(m.name or m.hostname or ""):lower()
    return name == want or name:find(want, 1, true) ~= nil
      or tostring(m.id or "") == want
  end)
  return id
end

-- Low-level open (no password prompt). Used by clients and jump proxies.
local function sshDialOpen(hostId, password, timeout)
  sshSend(hostId, {
    type = "ssh_open", password = password,
    name = os.getComputerLabel(), from = os.getComputerID(),
  })
  local _, msg = sshClientWait(timeout or 4, function(sid, m)
    return sid == hostId and type(m) == "table" and (m.type == "ssh_ok" or m.type == "ssh_deny")
  end)
  if not msg then return nil, "timeout" end
  if msg.type == "ssh_ok" then return msg.token, msg end
  return nil, msg.reason or "denied"
end

-- Ask a hop to open a proxied session to target (may itself jump further).
local function sshDialProxy(hopId, password, targetRef, visited, timeout)
  sshSend(hopId, {
    type = "ssh_proxy", password = password,
    target = targetRef, visited = visited or { os.getComputerID() },
    from = os.getComputerID(), name = os.getComputerLabel(),
  })
  local _, msg = sshClientWait(timeout or 8, function(sid, m)
    return sid == hopId and type(m) == "table" and (m.type == "ssh_ok" or m.type == "ssh_deny")
  end)
  if not msg then return nil, "proxy timeout via #" .. tostring(hopId) end
  if msg.type == "ssh_ok" then return msg.token, msg end
  return nil, msg.reason or "proxy denied"
end

-- On this host: establish a path to target (direct or via further jumps).
-- Returns tokenForClient, infoMsg or nil, err. Caller registers session for clientId.
local function sshEstablishTo(targetRef, password, visited, clientId)
  local depth = type(visited) == "table" and #visited or 0
  if depth > titan.SSH_MAX_JUMPS then
    return nil, "too many jumps (max " .. titan.SSH_MAX_JUMPS .. ")"
  end

  local targetId = tonumber(targetRef) or titan.sshResolve(targetRef, 2)
  if not targetId then return nil, "target not found: " .. tostring(targetRef) end

  if targetId == os.getComputerID() then
    local token = sshNewToken()
    local host = titan.hostname(sshKind)
    sshSessions[token] = { clientId = clientId, expires = os.clock() + 600, isLocal = true }
    return token, {
      type = "ssh_ok", token = token, name = host, hostname = host,
      kind = sshKind, id = os.getComputerID(), jumps = 0,
    }
  end

  -- Direct dial to target.
  local token, info = sshDialOpen(targetId, password, 3)
  if token then
    local my = sshNewToken()
    sshSessions[my] = {
      clientId = clientId, expires = os.clock() + 600,
      proxyHop = targetId, proxyToken = token, proxyTo = targetId,
    }
    info = info or {}
    return my, {
      type = "ssh_ok", token = my,
      name = info.name or info.hostname, hostname = info.hostname or info.name,
      kind = info.kind, id = targetId, jumps = 1,
      via = { os.getComputerID() },
    }
  end

  -- Jump through other shell hosts (modems/routers first).
  local peers = titan.sshListPeers(1.2)
  local nextVisited = sshVisitedNext(visited)
  for _, p in ipairs(peers) do
    if p.id ~= targetId and p.id ~= clientId and not sshVisitedHas(nextVisited, p.id) then
      local ptok, pinfo = sshDialProxy(p.id, password, targetId, nextVisited, 8)
      if ptok then
        local my = sshNewToken()
        sshSessions[my] = {
          clientId = clientId, expires = os.clock() + 600,
          proxyHop = p.id, proxyToken = ptok, proxyTo = targetId,
        }
        local via = { os.getComputerID() }
        if type(pinfo.via) == "table" then
          for _, v in ipairs(pinfo.via) do via[#via + 1] = v end
        else
          via[#via + 1] = p.id
        end
        return my, {
          type = "ssh_ok", token = my,
          name = pinfo.name or pinfo.hostname, hostname = pinfo.hostname or pinfo.name,
          kind = pinfo.kind, id = pinfo.id or targetId,
          jumps = (pinfo.jumps or 1) + 1, via = via,
        }
      end
    end
  end
  return nil, "unreachable (tried direct + " .. tostring(#peers) .. " jumps)"
end

-- Host: accept SSH sessions / proxy jumps / name pings.
function titan.sshHostLoop(kind)
  kind = kind or "device"
  sshKind = kind
  while true do
    local id, msg
    if #sshHostPending > 0 then
      local item = table.remove(sshHostPending, 1)
      id, msg = item.id, item.msg
    else
      id, msg = rednet.receive(titan.SSH_PROTOCOL)
    end
    if type(msg) ~= "table" or not id then
      -- ignore
    elseif sshIsClientReply(msg.type) then
      sshClientQ[#sshClientQ + 1] = { id = id, msg = msg }

    elseif msg.type == "ssh_ping" then
      local name = titan.hostname(kind)
      local want = tostring(msg.want or ""):lower()
      if msg.list or want == "" or name:lower() == want
         or name:lower():find(want, 1, true)
         or tostring(os.getComputerID()) == want then
        sshSend(id, {
          type = "ssh_pong", name = name, hostname = name,
          kind = kind, id = os.getComputerID(),
        })
      end

    elseif msg.type == "ssh_say" then
      local text = tostring(msg.text or msg.message or "")
      local from = tostring(msg.fromName or msg.name or msg.from or id)
      if text ~= "" then
        sshPrintSay(from, text)
      end
      sshSend(id, { type = "ssh_say_ack", ok = text ~= "" })

    elseif msg.type == "ssh_open" then
      if type(msg.password) ~= "string" or not titan.checkPassword(msg.password) then
        sshSend(id, { type = "ssh_deny", reason = "auth failed (need master password + Parent Center online)" })
      else
        local token = sshNewToken()
        local host = titan.hostname(kind)
        sshSessions[token] = { clientId = id, expires = os.clock() + 600 }
        sshSend(id, {
          type = "ssh_ok", token = token,
          name = host, hostname = host,
          kind = kind, id = os.getComputerID(), jumps = 0,
        })
      end

    elseif msg.type == "ssh_proxy" then
      -- Jump request: open (or further-jump) a session to msg.target for this client.
      if type(msg.password) ~= "string" or not titan.checkPassword(msg.password) then
        sshSend(id, { type = "ssh_deny", reason = "auth failed (need master password + Parent Center online)" })
      elseif sshVisitedHas(msg.visited, os.getComputerID()) then
        sshSend(id, { type = "ssh_deny", reason = "jump loop" })
      else
        local token, info = sshEstablishTo(msg.target, msg.password, msg.visited, id)
        if not token then
          sshSend(id, { type = "ssh_deny", reason = tostring(info) })
        else
          info.token = token
          sshSend(id, info)
        end
      end

    elseif msg.type == "ssh_exec" then
      local sess = msg.token and sshSessions[msg.token]
      if not sess or sess.clientId ~= id or os.clock() > sess.expires then
        sshSend(id, { type = "ssh_result", ok = false, out = "session expired - reconnect with ssh" })
      else
        sess.expires = os.clock() + 600
        local line = tostring(msg.line or "")
        if line == "" then
          sshSend(id, { type = "ssh_result", ok = true, out = "" })
        elseif line:lower() == "exit" or line:lower() == "logout" then
          if sess.proxyHop and sess.proxyToken then
            sshSend(sess.proxyHop, { type = "ssh_close", token = sess.proxyToken })
          end
          sshSessions[msg.token] = nil
          sshSend(id, { type = "ssh_result", ok = true, out = "logged out", close = true })
        elseif sess.proxyHop and sess.proxyToken then
          -- Forward through the jump chain.
          sshSend(sess.proxyHop, {
            type = "ssh_exec", token = sess.proxyToken, line = line,
          })
          local _, res = sshClientWait(45, function(sid, m)
            return sid == sess.proxyHop and type(m) == "table" and m.type == "ssh_result"
          end)
          if not res then
            sshSend(id, { type = "ssh_result", ok = false, out = "jump timeout" })
          else
            if res.close then
              sshSessions[msg.token] = nil
            end
            sshSend(id, res)
          end
        else
          local out, ok, doReboot = sshRunLocal(line)
          sshSend(id, { type = "ssh_result", ok = ok, out = out })
          if doReboot then
            sleep(0.3)
            os.reboot()
          end
        end
      end

    elseif msg.type == "ssh_close" then
      local sess = msg.token and sshSessions[msg.token]
      if sess and sess.proxyHop and sess.proxyToken then
        sshSend(sess.proxyHop, { type = "ssh_close", token = sess.proxyToken })
      end
      if msg.token then sshSessions[msg.token] = nil end
    end
  end
end

-- Display-only: print `message` on the target device's native screen.
-- targetRef = computer id or label (same resolve rules as ssh). No password.
-- Returns true or false, err.
function titan.say(targetRef, message, timeout)
  timeout = timeout or 3
  local text = tostring(message or "")
  if text == "" then return false, "empty message" end
  pcall(titan.openModem)

  local targetId = tonumber(targetRef) or titan.sshResolve(targetRef, timeout)
  if not targetId then return false, "target not found: " .. tostring(targetRef) end

  local fromName = titan.hostname(sshKind)
  if targetId == os.getComputerID() then
    sshPrintSay(fromName, text)
    return true
  end

  sshSend(targetId, {
    type = "ssh_say",
    text = text,
    from = os.getComputerID(),
    fromName = fromName,
    name = fromName,
  })
  local _, ack = sshClientWait(timeout, function(sid, m)
    return sid == targetId and type(m) == "table" and m.type == "ssh_say_ack"
  end)
  if not ack then
    return false, "no response from #" .. tostring(targetId) .. " (offline / out of range?)"
  end
  return true
end

-- Client: open a session (prompts for master password). Returns token, hostMsg or nil, err.
function titan.sshOpen(hostId, password)
  if not password then
    write("Master password: ")
    password = read("*")
  end
  return sshDialOpen(hostId, password, 5)
end

function titan.sshExec(hostId, token, line)
  sshSend(hostId, { type = "ssh_exec", token = token, line = line })
  local _, msg = sshClientWait(45, function(sid, m)
    return sid == hostId and type(m) == "table" and m.type == "ssh_result"
  end)
  return msg or { ok = false, out = "timeout waiting for remote output" }
end

function titan.sshClose(hostId, token)
  if hostId and token then sshSend(hostId, { type = "ssh_close", token = token }) end
end

-- Open with automatic modem/router jumps when the target is not directly reachable.
-- Returns hopId, token, info or nil, err. hopId is who the client talks to (first hop).
function titan.sshOpenRouted(target, password)
  if not password then
    write("Master password: ")
    password = read("*")
  end

  local targetId = tonumber(target) or titan.sshResolve(target, 3)
  if not targetId then return nil, nil, "host not found: " .. tostring(target) end
  if targetId == os.getComputerID() then return nil, nil, "that is this computer" end

  -- 1) Direct
  print(("ssh: trying #%s direct..."):format(tostring(targetId)))
  local token, info = sshDialOpen(targetId, password, 3)
  if token then
    info = info or {}
    info.id = info.id or targetId
    info.jumps = 0
    return targetId, token, info
  end

  -- 2) Jump via modem/router (and other) shells
  print("ssh: direct failed — jumping through mesh shells...")
  local peers = titan.sshListPeers(1.5)
  local visited = { os.getComputerID() }
  for _, p in ipairs(peers) do
    if p.id ~= targetId then
      print(("ssh: jump via %s (#%d) [%s]..."):format(
        tostring(p.name or "?"), p.id, tostring(p.kind or "?")))
      local ptok, pinfo = sshDialProxy(p.id, password, targetId, visited, 10)
      if ptok then
        pinfo = pinfo or {}
        pinfo.id = pinfo.id or targetId
        local viaStr = ""
        if type(pinfo.via) == "table" and #pinfo.via > 0 then
          viaStr = " via " .. table.concat(pinfo.via, " -> ")
        else
          viaStr = (" via #%d"):format(p.id)
        end
        pinfo._viaNote = viaStr
        return p.id, ptok, pinfo
      end
    end
  end
  return nil, nil, "unreachable — no jump path (are modems/routers running shells?)"
end

-- Interactive (or one-shot) SSH client. target = id or label; cmdline optional.
function titan.sshConnect(target, cmdline)
  local hopId, token, info = titan.sshOpenRouted(target)
  if not token then
    printError("ssh: " .. tostring(info))
    return false
  end
  local destName = info.name or info.hostname or tostring(target)
  local destId = info.id or "?"
  print(("Connected to %s (#%s) [%s]%s"):format(
    destName, tostring(destId), tostring(info.kind or "?"),
    info._viaNote or (info.jumps and info.jumps > 0 and (" jumps=" .. info.jumps) or "")))
  print("Remote shell: device commands + CraftOS. Type help | exit")

  local function runLine(line)
    local res = titan.sshExec(hopId, token, line)
    if res.out and res.out ~= "" then print(res.out) end
    if res.close then return false end
    return true
  end

  if cmdline and cmdline ~= "" then
    runLine(cmdline)
    titan.sshClose(hopId, token)
    return true
  end

  while true do
    write(("ssh:%s> "):format(destName))
    local line = read()
    if not line then break end
    local low = line:lower():match("^%s*(.-)%s*$") or ""
    if low == "exit" or low == "logout" then
      runLine(line)
      break
    end
    if not runLine(line) then break end
  end
  titan.sshClose(hopId, token)
  print("Disconnected.")
  return true
end

--------------------------------------------------------------------------------
-- Packages + OTA self-update
--
-- Each installed device keeps a plain-text `packages` file listing the desired
-- package paths (one per line). `update` downloads everything in that list from
-- the install source recorded in `.titan-install`. Edit `packages` (or use
-- `packages add` / `packages remove`) to change what this computer should have.
--------------------------------------------------------------------------------
titan.MANIFEST      = ".titan-install"
titan.PACKAGES_FILE = "packages"
titan.VERSIONS_FILE = "versions.lua"

-- Skip these roots when scanning for local packages.
local SCAN_SKIP = {
  rom = true, [".git"] = true, disk = true, builds = true,
}

function titan.readManifest()
  if not fs.exists(titan.MANIFEST) then return nil end
  local f = fs.open(titan.MANIFEST, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  return type(d) == "table" and d or nil
end

function titan.writeManifest(m)
  local f = fs.open(titan.MANIFEST, "w"); f.write(textutils.serialize(m)); f.close()
end

-- Short package name for display (lib/titan.lua -> titan, console.lua -> console).
function titan.packageName(path)
  local base = fs.getName(path or "")
  base = base:gsub("%.lua$", ""):gsub("%.txt$", "")
  return base ~= "" and base or tostring(path)
end

-- Load local versions.lua catalog if present.
function titan.loadVersionCatalog()
  if not fs.exists(titan.VERSIONS_FILE) then return nil end
  local ok, cat = pcall(dofile, titan.VERSIONS_FILE)
  if ok and type(cat) == "table" then return cat end
  return nil
end

-- Optional GitHub raw root. Intentionally NOT hardcoded — host-only clients
-- (e.g. Tetris tablets) must never carry a public wget URL. Set only via
-- `.titan-install`.base (github_install) or an explicit titan.GITHUB_RAW_BASE
-- on your private update server / MAIN.
titan.GITHUB_RAW_BASE = nil

-- Resolve GitHub raw base from manifest or explicit override. Nil if host-only.
function titan.githubRawBase()
  local m = titan.readManifest()
  if m and type(m.base) == "string" and m.base ~= "" then
    local base = m.base
    if not base:find("/$") then base = base .. "/" end
    return base
  end
  if type(titan.GITHUB_RAW_BASE) == "string" and titan.GITHUB_RAW_BASE ~= "" then
    local base = titan.GITHUB_RAW_BASE
    if not base:find("/$") then base = base .. "/" end
    return base
  end
  return nil
end

-- HTTP GET helper for OTA / GitHub fetches (must be above fetchGithubVersions).
local function otaHttp(url)
  if not http then return nil, "http disabled" end
  local h = http.get(url)
  if not h then return nil, "request failed" end
  local code = h.getResponseCode and h.getResponseCode() or 200
  local data = h.readAll(); h.close()
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
  if not data or data == "" then return nil, "empty" end
  return data
end

local function parseVersionsData(data)
  if not data then return nil, "empty" end
  local loader, lerr = load(data, "@versions.lua", "t", {})
  if not loader then
    if loadstring then
      loader, lerr = loadstring(data)
      if loader then setfenv(loader, {}) end
    end
  end
  if not loader then return nil, "parse failed: " .. tostring(lerr) end
  local ok, cat = pcall(loader)
  if not ok or type(cat) ~= "table" then return nil, "invalid versions.lua" end
  return cat
end

-- Fetch versions.lua from a raw base URL. Returns catalog or nil, err.
function titan.fetchGithubVersions(base)
  base = base or titan.githubRawBase()
  if type(base) ~= "string" or base == "" then return nil, "no github base" end
  if not base:find("/$") then base = base .. "/" end
  local data, err = otaHttp(base .. "versions.lua?cb=" .. os.epoch("utc"))
  if not data then return nil, err end
  local cat, perr = parseVersionsData(data)
  if not cat then return nil, perr end
  return cat, base
end

-- Compare dotted versions: -1 if a<b, 0 equal, 1 if a>b.
function titan.versionCompare(a, b)
  local function parts(v)
    local t = {}
    for n in tostring(v or "0"):gmatch("%d+") do t[#t + 1] = tonumber(n) or 0 end
    if #t == 0 then t[1] = 0 end
    return t
  end
  local pa, pb = parts(a), parts(b)
  local n = math.max(#pa, #pb)
  for i = 1, n do
    local x, y = pa[i] or 0, pb[i] or 0
    if x < y then return -1 end
    if x > y then return 1 end
  end
  return 0
end

-- Read `-- Titan-Version: x.y.z` from the first lines of a file.
function titan.readFileVersion(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  for _ = 1, 40 do
    local line = f.readLine()
    if not line then break end
    local ver = line:match("[Tt]itan%-[Vv]ersion:%s*([%d%.]+)")
    if ver then f.close(); return ver end
    ver = line:match("^%-%-%s*[Vv]ersion:%s*([%d%.]+)")
    if ver then f.close(); return ver end
  end
  f.close()
  return nil
end

function titan.packageVersion(path, catalog)
  catalog = catalog or titan.loadVersionCatalog()
  if catalog and catalog.packages and catalog.packages[path] then
    return catalog.packages[path]
  end
  return titan.readFileVersion(path)
end

-- Resolve a short name ("console", "titan") or path to a package path.
function titan.resolvePackagePath(ref)
  ref = tostring(ref or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if ref == "" then return nil end
  if ref:find("[/\\.]") or ref:match("%.lua$") or ref:match("%.txt$") then
    return ref
  end
  local catalog = titan.loadVersionCatalog()
  if catalog and catalog.packages then
    local want = ref:lower()
    for path in pairs(catalog.packages) do
      if titan.packageName(path):lower() == want then return path end
    end
  end
  if fs.exists(ref .. ".lua") then return ref .. ".lua" end
  if fs.exists("lib/" .. ref .. ".lua") then return "lib/" .. ref .. ".lua" end
  return ref .. ".lua"
end

-- Write the desired-packages file (human-editable).
function titan.writePackageList(paths)
  local seen, list = {}, {}
  for _, path in ipairs(paths or {}) do
    if path and path ~= "" and not seen[path] then
      seen[path] = true
      list[#list + 1] = path
    end
  end
  table.sort(list)
  if not seen[titan.VERSIONS_FILE] then
    -- versions catalog should always be tracked
    list[#list + 1] = titan.VERSIONS_FILE
    table.sort(list)
  end
  local f = fs.open(titan.PACKAGES_FILE, "w")
  f.write("# Titan packages — desired packages for this computer\n")
  f.write("# One path per line. Edit this list, then run: update\n")
  f.write("# Commands: packages add <name> | packages remove <name>\n")
  f.write("#\n")
  for _, path in ipairs(list) do
    f.write(path .. "\n")
  end
  f.close()
  return list
end

-- Read desired packages from `packages`. Migrates from .titan-install if needed.
function titan.readPackageList()
  if fs.exists(titan.PACKAGES_FILE) and not fs.isDir(titan.PACKAGES_FILE) then
    local list, seen = {}, {}
    local f = fs.open(titan.PACKAGES_FILE, "r")
    while true do
      local line = f.readLine()
      if not line then break end
      line = line:match("^%s*(.-)%s*$") or ""
      if line ~= "" and not line:find("^#") then
        if not seen[line] then
          seen[line] = true
          list[#list + 1] = line
        end
      end
    end
    f.close()
    if #list > 0 then return list end
  end

  -- Migrate / seed from install manifest.
  local m = titan.readManifest()
  if m and type(m.files) == "table" and #m.files > 0 then
    return titan.writePackageList(m.files)
  end
  return nil
end

function titan.addPackage(ref)
  local path = titan.resolvePackagePath(ref)
  if not path then return nil, "invalid package" end
  local list = titan.readPackageList() or {}
  for _, p in ipairs(list) do if p == path then return path, "already listed" end end
  list[#list + 1] = path
  titan.writePackageList(list)
  local m = titan.readManifest()
  if m then
    m.files = titan.readPackageList()
    titan.writeManifest(m)
  end
  return path
end

function titan.removePackage(ref)
  local path = titan.resolvePackagePath(ref)
  if not path then return nil, "invalid package" end
  if path == titan.VERSIONS_FILE then return nil, "cannot remove versions.lua" end
  local list, kept = titan.readPackageList() or {}, {}
  local found = false
  for _, p in ipairs(list) do
    if p == path then found = true
    else kept[#kept + 1] = p end
  end
  if not found then return nil, "not in packages list" end
  titan.writePackageList(kept)
  local m = titan.readManifest()
  if m then
    m.files = titan.readPackageList()
    titan.writeManifest(m)
  end
  return path
end

-- Recursively find all .lua files (and known Titan extras) on this computer.
function titan.scanLocalScripts(dir, out)
  out = out or {}
  dir = dir or ""
  local ok, list = pcall(fs.list, dir == "" and "" or dir)
  if not ok or type(list) ~= "table" then return out end
  for _, name in ipairs(list) do
    if not SCAN_SKIP[name] and name ~= titan.PACKAGES_FILE then
      local path = (dir == "" or dir == "/") and name or (dir .. "/" .. name)
      if fs.isDir(path) then
        titan.scanLocalScripts(path, out)
      elseif name:match("%.lua$") or name == "exclude.txt" or name == "versions.lua" then
        out[#out + 1] = path
      end
    end
  end
  return out
end

-- List desired packages (from `packages` file) + any extra local scripts.
-- Display is name + version.
function titan.listPackages()
  local m = titan.readManifest()
  local catalog = titan.loadVersionCatalog()
  local desired = titan.readPackageList() or {}
  local inList, paths = {}, {}

  for _, path in ipairs(desired) do
    inList[path] = true
    paths[#paths + 1] = path
  end

  for _, path in ipairs(titan.scanLocalScripts()) do
    if not inList[path] then
      paths[#paths + 1] = path
      inList[path] = "extra"
    end
  end

  table.sort(paths)
  local packages = {}
  for _, path in ipairs(paths) do
    local present = fs.exists(path) and not fs.isDir(path)
    local ver = present and titan.packageVersion(path, catalog) or nil
    packages[#packages + 1] = {
      name = titan.packageName(path),
      version = ver or "—",
      path = path,
      present = present,
      extra = inList[path] == "extra",
      tracked = inList[path] == true,
    }
  end

  return {
    system = (catalog and catalog.system) or (m and m.version) or "—",
    source = m and m.source or nil,
    role = m and m.role or nil,
    run = m and m.run or nil,
    base = m and m.base or nil,
    packages = packages,
    desired = desired,
    files = packages,
  }
end

local function otaWriteFile(path, data)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w"); f.write(data); f.close()
end

titan.INSTALL_PROTOCOL = "titan_install"

local function otaRememberHost(id)
  id = tonumber(id)
  if not id then return end
  local c = titan.readNetCfg()
  c.installHostId = id
  titan.writeNetCfg(c)
end

local function otaCachedHost()
  local c = titan.readNetCfg()
  return tonumber(c.installHostId)
end

-- Find install host: local titan_install RF first, then titan_router mesh via MAIN.
function titan.findInstallHost(timeout)
  timeout = tonumber(timeout) or 5
  pcall(function()
    if titan.openModem then titan.openModem() end
  end)
  local me = os.getComputerID()
  local mainId = titan.getMainRouterId()
  if not mainId then
    mainId = select(1, titan.findMainRouter(2))
  end

  rednet.broadcast({ type = "discover" }, titan.INSTALL_PROTOCOL)
  rednet.broadcast({
    type = "install_discover", originId = me, from = me,
  }, titan.ROUTER_PROTOCOL)
  if mainId then
    rednet.send(mainId, {
      type = "install_discover", originId = me, from = me,
    }, titan.ROUTER_PROTOCOL)
    rednet.send(mainId, { type = "install_where", from = me }, titan.ROUTER_PROTOCOL)
  end

  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg, proto = rednet.receive(nil, deadline - os.clock())
    if type(msg) == "table" then
      if msg.type == "host_here" and (proto == titan.INSTALL_PROTOCOL or proto == nil) then
        otaRememberHost(id)
        return id, msg
      elseif msg.type == "install_host_here" then
        local hostId = tonumber(msg.hostId) or id
        if hostId then
          otaRememberHost(hostId)
          return hostId, msg
        end
      end
    end
  end

  local cached = otaCachedHost()
  if cached then
    return cached, { type = "install_host_here", hostId = cached, cached = true }
  end
  return nil
end

local function otaFindHost(timeout)
  return titan.findInstallHost(timeout)
end

-- Pull one file from the install host (direct RF + mesh hop through MAIN).
function titan.fetchFromInstallHost(hostId, path, timeout)
  hostId = tonumber(hostId)
  if not hostId or not path then return nil, "bad args" end
  timeout = tonumber(timeout) or 8
  local me = os.getComputerID()
  local mainId = titan.getMainRouterId()
  local req = {
    type = "install_get",
    path = path,
    replyTo = me,
    originId = me,
    dest = hostId,
    hostId = hostId,
    from = me,
  }
  rednet.send(hostId, { type = "get", path = path }, titan.INSTALL_PROTOCOL)
  rednet.send(hostId, req, titan.ROUTER_PROTOCOL)
  if mainId then
    rednet.send(mainId, req, titan.ROUTER_PROTOCOL)
    rednet.send(mainId, {
      type = "install_fwd",
      dest = hostId,
      payload = req,
      replyTo = me,
      from = me,
    }, titan.ROUTER_PROTOCOL)
  end

  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg, proto = rednet.receive(nil, deadline - os.clock())
    if type(msg) == "table" and msg.path == path then
      if msg.type == "file" and (proto == titan.INSTALL_PROTOCOL or id == hostId or msg.ok ~= nil) then
        if msg.ok and msg.data then return msg.data end
        return nil, "missing on host"
      elseif msg.type == "install_file" then
        if msg.ok and msg.data then return msg.data end
        return nil, "missing on host"
      end
    end
  end
  return nil, "timeout"
end

local function otaFromHost(hostId, path)
  return titan.fetchFromInstallHost(hostId, path, 8)
end

local function otaBuildGetter(m)
  if not m then return nil, "no install manifest (.titan-install) — install via an installer first" end
  if m.source == "github" then
    if not m.base then return nil, "manifest missing base url" end
    return function(path) return otaHttp(m.base .. path .. "?cb=" .. os.epoch("utc")) end
  elseif m.source == "pastebin" then
    return function(path)
      local code = m.codes and m.codes[path]
      if not code then return nil, "no pastebin code" end
      return otaHttp("https://pastebin.com/raw/" .. code .. "?cb=" .. os.epoch("utc"))
    end
  elseif m.source == "host" then
    local hostId, hostMsg = otaFindHost(5)
    if not hostId then return nil, "no install host online (run host.lua on the install computer)" end
    local hostFiles = {}
    if hostMsg and type(hostMsg.files) == "table" then
      for _, ent in ipairs(hostMsg.files) do
        if type(ent) == "table" and ent.path then hostFiles[ent.path] = true
        elseif type(ent) == "string" then hostFiles[ent] = true end
      end
    end
    return function(path)
      if next(hostFiles) and not hostFiles[path] then return nil, "not on host" end
      return otaFromHost(hostId, path)
    end, hostId
  end
  return nil, "unknown install source: " .. tostring(m.source)
end

-- Update set = whatever is listed in the `packages` file (desired packages).
local function otaCollectUpdatePaths()
  local list = titan.readPackageList()
  if not list or #list == 0 then return nil, "no packages file — install via an installer, or create a `packages` list" end
  local seen, paths = {}, {}
  for _, path in ipairs(list) do
    if path and path ~= "" and not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  if not seen[titan.VERSIONS_FILE] then
    paths[#paths + 1] = titan.VERSIONS_FILE
  end
  table.sort(paths, function(a, b)
    if a == titan.VERSIONS_FILE then return true end
    if b == titan.VERSIONS_FILE then return false end
    return a < b
  end)
  return paths
end

-- Fetch remote versions.lua from the install source.
-- opts.hostOnly = never touch HTTP / GitHub (rednet host only).
function titan.fetchRemoteCatalog(opts)
  opts = opts or {}
  local m = titan.readManifest()
  local hostOnly = opts.hostOnly or (m and m.source == "host" and m.hostOnly ~= false)

  if hostOnly or (m and m.source == "host") then
    local hostId = otaFindHost(5)
    if not hostId then return nil, "no install host online (run host.lua)" end
    local data, err = otaFromHost(hostId, titan.VERSIONS_FILE)
    if not data then return nil, err end
    return parseVersionsData(data)
  end

  if m and m.source == "github" then
    return titan.fetchGithubVersions(m.base or titan.githubRawBase())
  elseif m and m.source == "pastebin" then
    local code = m.codes and m.codes[titan.VERSIONS_FILE]
    if not code or code == "" then
      local base = titan.githubRawBase()
      if not base then return nil, "no pastebin versions code" end
      return titan.fetchGithubVersions(base)
    end
    local data, err = otaHttp("https://pastebin.com/raw/" .. code .. "?cb=" .. os.epoch("utc"))
    if not data then return nil, err end
    return parseVersionsData(data)
  end

  local base = titan.githubRawBase()
  if base then return titan.fetchGithubVersions(base) end
  -- Last resort: look for a rednet host (no URL required).
  local hostId = otaFindHost(5)
  if not hostId then return nil, "no update source (host offline, no github base)" end
  local data, err = otaFromHost(hostId, titan.VERSIONS_FILE)
  if not data then return nil, err end
  return parseVersionsData(data)
end

-- true, reason if any tracked package (or system) is behind remote catalog.
function titan.packagesNeedUpdate(remoteCat)
  if type(remoteCat) ~= "table" then return false, "no catalog" end
  local localCat = titan.loadVersionCatalog()
  local localSys = (localCat and localCat.system) or titan.systemVersion() or "0"
  local remoteSys = remoteCat.system
  if remoteSys and titan.versionCompare(localSys, remoteSys) < 0 then
    return true, "system " .. tostring(localSys) .. " -> " .. tostring(remoteSys)
  end
  local remotePkgs = remoteCat.packages or {}
  local paths = titan.readPackageList()
  if not paths or #paths == 0 then
    -- Fall back to whatever is on disk that remote knows about.
    paths = {}
    for path in pairs(remotePkgs) do
      if fs.exists(path) then paths[#paths + 1] = path end
    end
  end
  for _, path in ipairs(paths) do
    if path ~= titan.VERSIONS_FILE then
      local want = remotePkgs[path]
      if want then
        if not fs.exists(path) then
          return true, path .. " missing"
        end
        local have = titan.packageVersion(path, localCat) or titan.readFileVersion(path) or "0"
        if titan.versionCompare(have, want) < 0 then
          return true, path .. " " .. tostring(have) .. " -> " .. tostring(want)
        end
      end
    end
  end
  return false, "up to date"
end

-- Ensure a github install manifest exists so updateSelf can pull from GitHub.
-- Only call this on machines that are allowed to know the raw URL.
function titan.ensureGithubManifest(opts)
  opts = opts or {}
  local m = titan.readManifest()
  if m and m.source then return m end
  local base = opts.base or titan.githubRawBase()
  if type(base) ~= "string" or base == "" then
    return nil, "no github base (set opts.base or .titan-install.base)"
  end
  local files = opts.files
  if type(files) ~= "table" or #files == 0 then
    files = titan.readPackageList() or { "lib/titan.lua", "versions.lua" }
  end
  m = {
    source = "github",
    role = opts.role or "device",
    run = opts.run,
    files = files,
    base = base,
    version = titan.systemVersion(),
  }
  titan.writeManifest(m)
  if not titan.readPackageList() then
    titan.writePackageList(files)
  end
  return m
end

-- Host-only manifest: rednet install host, never stores a GitHub / wget URL.
function titan.ensureHostManifest(opts)
  opts = opts or {}
  local files = opts.files
  if type(files) ~= "table" or #files == 0 then
    files = titan.readPackageList() or { "lib/titan.lua", "versions.lua" }
  end
  local m = titan.readManifest() or {}
  m.source = "host"
  m.hostOnly = true
  m.role = opts.role or m.role or "device"
  m.run = opts.run or m.run
  m.files = files
  m.version = titan.systemVersion()
  -- Scrub any leaked URL fields from older builds / mistaken github installs.
  m.base = nil
  m.codes = nil
  titan.writeManifest(m)
  if not titan.readPackageList() then
    titan.writePackageList(files)
  end
  return m
end

-- Boot-time check: if remote catalog is newer, OTA + reboot.
-- Returns: updated(bool), detail(string)
-- opts.hostOnly = rednet host only (no GitHub URL written or used)
-- opts.quiet / opts.files / opts.run / opts.role for manifest seed.
function titan.bootUpdateCheck(opts)
  opts = opts or {}
  if opts.hostOnly then
    titan.ensureHostManifest(opts)
  elseif opts.files or opts.run then
    titan.ensureGithubManifest(opts)
  elseif not titan.readManifest() then
    -- Prefer host when no manifest — never invent a public URL.
    titan.ensureHostManifest(opts)
  end

  -- Keep host-only devices scrubbed even if an old base was on disk.
  if opts.hostOnly then
    local m = titan.readManifest()
    if m and (m.base or m.source == "github") then
      titan.ensureHostManifest(opts)
    end
  end

  local remote, err = titan.fetchRemoteCatalog({ hostOnly = opts.hostOnly })
  if not remote then
    return false, "check failed: " .. tostring(err or "no catalog")
  end
  local need, why = titan.packagesNeedUpdate(remote)
  if not need then
    return false, why or "up to date"
  end

  if not opts.quiet then
    print("[OTA] Update available (" .. tostring(why) .. ")")
    print("[OTA] Downloading from install host...")
  end
  local prev = titan.systemVersion()
  local progress = opts.quiet and nil or function(path, good, msg)
    local name = titan.packageName(path)
    if good then print(("  ok   %-16s %s"):format(name, tostring(msg)))
    else print(("  FAIL %-16s %s"):format(name, tostring(msg))) end
  end
  local ok, detail = titan.updateSelf({ onProgress = progress })
  -- Never fall back to GitHub for host-only clients (would write the URL).
  if not ok and not opts.hostOnly then
    local m = titan.readManifest()
    local base = titan.githubRawBase()
    if m and m.source ~= "github" and base then
      if not opts.quiet then
        print("[OTA] " .. tostring(detail) .. " — retrying via GitHub...")
      end
      m.source = "github"
      m.base = base
      titan.writeManifest(m)
      ok, detail = titan.updateSelf({ onProgress = progress })
    end
  end
  if not ok then
    return false, "update failed: " .. tostring(detail)
  end
  local pkgs = type(detail) == "table" and detail.packages or nil
  local ver = titan.systemVersion()
  if titan.markPendingUpdateAck then
    titan.markPendingUpdateAck(prev, ver, pkgs)
  end
  if not opts.quiet then
    print("[OTA] Updated to v" .. tostring(ver or "?") .. " — rebooting...")
  end
  sleep(opts.rebootDelay or 1.2)
  os.reboot()
  return true, "rebooting"
end

-- Re-download every package listed in the `packages` file from the install source.
-- opts.onProgress(path, ok, detail) optional. Returns ok, detail.
-- On success detail includes packages = { {name, path, from, to}, ... }.
function titan.updateSelf(opts)
  opts = opts or {}
  local m = titan.readManifest()
  local getter, gerr = otaBuildGetter(m)
  if not getter then return false, gerr end

  local paths, perr = otaCollectUpdatePaths()
  if not paths then return false, perr end

  local prevSystem = titan.systemVersion()
  local before = titan.packageVersionMap(paths)
  local failed, okCount = {}, 0

  for _, path in ipairs(paths) do
    local data, err = getter(path)
    if data then
      otaWriteFile(path, data)
      okCount = okCount + 1
      if opts.onProgress then
        local ver = data:match("[Tt]itan%-[Vv]ersion:%s*([%d%.]+)") or ""
        opts.onProgress(path, true, (#data .. "b") .. (ver ~= "" and (" v" .. ver) or ""))
      end
    else
      failed[#failed + 1] = path .. " (" .. tostring(err) .. ")"
      if opts.onProgress then opts.onProgress(path, false, tostring(err)) end
    end
  end

  -- Keep packages file + manifest in sync; refresh system version.
  local finalList = titan.writePackageList(paths)
  if m then
    local cat = titan.loadVersionCatalog()
    m.files = finalList
    m.version = (cat and cat.system) or m.version
    titan.writeManifest(m)
  end

  if #failed > 0 then return false, "failed: " .. table.concat(failed, ", ") end

  local after = titan.packageVersionMap(paths)
  local packages = titan.diffPackageVersions(before, after)
  local system = titan.systemVersion()
  if #packages == 0 and tostring(prevSystem or "") ~= tostring(system or "") then
    packages = { {
      name = "system", path = titan.VERSIONS_FILE,
      from = tostring(prevSystem or "—"), to = tostring(system or "—"),
    } }
  end
  return true, {
    updated = okCount, skipped = 0,
    packages = packages,
    prevSystem = prevSystem, system = system,
  }
end

--------------------------------------------------------------------------------
-- Turtle navigation (GPS based)
--
-- These functions only work on turtles that have:
--   * a wireless modem, and
--   * a working GPS constellation in range (see README).
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- GPS fix: multi-sample with high/low tracking for accurate block coords.
-- Y is especially noisy (modem offset + constellation error); sampling and
-- taking the median between the observed high/low cuts that error down.
--------------------------------------------------------------------------------
local function axisStats(vals)
  local sorted = {}
  for i = 1, #vals do sorted[i] = vals[i] end
  table.sort(sorted)
  local lo, hi = sorted[1], sorted[#sorted]
  local n = #sorted
  local med
  if n % 2 == 1 then
    med = sorted[(n + 1) / 2]
  else
    med = (sorted[n / 2] + sorted[n / 2 + 1]) / 2
  end
  -- Prefer the midpoint of the observed range when the spread is small
  -- (typical GPS flicker); otherwise trust the median.
  local mid = (lo + hi) / 2
  local pick = (hi - lo) <= 1.5 and mid or med
  return math.floor(pick + 0.5), lo, hi, med
end

-- opts: timeout (total budget secs), samples, bias {x,y,z}
-- Returns x, y, z, info  or  nil, err
-- info = { x,y,z, xLo,xHi,yLo,yHi,zLo,zHi, n, rawY, spreadY }
function titan.gpsFix(opts)
  opts = type(opts) == "table" and opts or {}
  local samples = math.max(1, math.floor(tonumber(opts.samples) or 5))
  local budget  = tonumber(opts.timeout) or 2.5
  local per     = math.max(0.25, budget / samples)
  local bias    = type(opts.bias) == "table" and opts.bias or {}
  local bx = tonumber(bias.x) or 0
  local by = tonumber(bias.y) or 0
  local bz = tonumber(bias.z) or 0

  local xs, ys, zs = {}, {}, {}
  for i = 1, samples do
    local x, y, z = gps.locate(per)
    if x then
      xs[#xs + 1] = x
      ys[#ys + 1] = y
      zs[#zs + 1] = z
      -- Early exit: 3 agreeing block samples → good enough.
      if #xs >= 3 then
        local ax = math.floor(xs[#xs] + 0.5)
        local ay = math.floor(ys[#ys] + 0.5)
        local az = math.floor(zs[#zs] + 0.5)
        local agree = 0
        for j = #xs - 2, #xs do
          if math.floor(xs[j] + 0.5) == ax
             and math.floor(ys[j] + 0.5) == ay
             and math.floor(zs[j] + 0.5) == az then
            agree = agree + 1
          end
        end
        if agree >= 3 then break end
      end
    end
    if i < samples then sleep(0.05) end
  end
  if #xs == 0 then return nil, "no gps fix" end

  local x, xLo, xHi = axisStats(xs)
  local y, yLo, yHi = axisStats(ys)
  local z, zLo, zHi = axisStats(zs)
  x = x + bx; y = y + by; z = z + bz

  local info = {
    x = x, y = y, z = z,
    xLo = xLo + bx, xHi = xHi + bx,
    yLo = yLo + by, yHi = yHi + by,
    zLo = zLo + bz, zHi = zHi + bz,
    n = #xs,
    rawY = (yLo + yHi) / 2 + by,
    spreadY = (yHi - yLo),
    spreadX = (xHi - xLo),
    spreadZ = (zHi - zLo),
  }
  return x, y, z, info
end

local nav = {}
titan.nav = nav

nav.heading = nil        -- current facing (titan.NORTH/EAST/SOUTH/WEST) once calibrated
nav.home    = nil        -- {x, y, z} set with nav.setHome()
nav.FUEL_SLOT = 16       -- bottom-right inventory slot — dedicated fuel slot for turtles
nav.GPS_SAMPLES = 5      -- samples per locate (status / movement)
nav.gpsBias = { x = 0, y = 0, z = 0 }  -- modem-body offset (top modem: y = -1)
nav.lastFix = nil        -- last gpsFix info (includes yLo / yHi)

function nav.setGpsBias(dx, dy, dz)
  nav.gpsBias = {
    x = tonumber(dx) or 0,
    y = tonumber(dy) or 0,
    z = tonumber(dz) or 0,
  }
  return nav.gpsBias
end

-- Locate via multi-sample GPS (tracks high/low, returns most accurate block).
-- Returns x, y, z or nil. Detail in nav.lastFix (yLo / yHi / spreadY).
function nav.locate(timeout)
  local samples = nav.GPS_SAMPLES or 5
  -- Movement path often passes timeout=1 or 2; keep it responsive.
  local budget = tonumber(timeout) or 2
  if budget < 1 then samples = math.min(samples, 3) end
  local x, y, z, info = titan.gpsFix({
    timeout = budget,
    samples = samples,
    bias = nav.gpsBias,
  })
  if not x then
    nav.lastFix = nil
    return nil
  end
  nav.lastFix = info
  return x, y, z
end

-- Extra-careful fix for set-home / deploy / corners (more samples).
function nav.locatePrecise(timeout)
  local x, y, z, info = titan.gpsFix({
    timeout = tonumber(timeout) or 4,
    samples = 9,
    bias = nav.gpsBias,
  })
  if not x then
    nav.lastFix = nil
    return nil
  end
  nav.lastFix = info
  return x, y, z
end

-- Movement helpers. `dig` controls whether we may break blocks to pass.
-- No block on titan.isRestricted() is ever broken, regardless of `dig`.
-- Returns true, or false + reason.
local function tryForward(dig)
  for _ = 1, 40 do
    if turtle.forward() then return true end
    if turtle.detect() then
      if not dig then return false, "blocked (no-dig)" end
      local ok, data = turtle.inspect()
      if ok and titan.isRestricted(data.name) then return false, "restricted:" .. data.name end
      turtle.dig()
    else
      turtle.attack()          -- something (a mob) is blocking us
    end
    os.sleep(0.2)
  end
  return false, "stuck forward"
end

local function tryUp(dig)
  for _ = 1, 40 do
    if turtle.up() then return true end
    if turtle.detectUp() then
      if not dig then return false, "blocked (no-dig)" end
      local ok, data = turtle.inspectUp()
      if ok and titan.isRestricted(data.name) then return false, "restricted:" .. data.name end
      turtle.digUp()
    else
      turtle.attackUp()
    end
    os.sleep(0.2)
  end
  return false, "stuck up"
end

local function tryDown(dig)
  for _ = 1, 40 do
    if turtle.down() then return true end
    if turtle.detectDown() then
      if not dig then return false, "blocked (no-dig)" end
      local ok, data = turtle.inspectDown()
      if ok and titan.isRestricted(data.name) then return false, "restricted:" .. data.name end
      turtle.digDown()
    else
      turtle.attackDown()
    end
    os.sleep(0.2)
  end
  return false, "stuck down"
end

-- Expose the low-level movers so programs (e.g. the scanner) can reuse them.
nav.tryForward, nav.tryUp, nav.tryDown = tryForward, tryUp, tryDown

-- Turn to face a target heading, keeping nav.heading in sync.
function nav.face(target)
  if nav.heading == nil then
    error("heading unknown - call titan.nav.calibrate() first", 0)
  end
  local diff = (target - nav.heading) % 4
  if diff == 1 then
    turtle.turnRight(); nav.heading = (nav.heading + 1) % 4
  elseif diff == 3 then
    turtle.turnLeft();  nav.heading = (nav.heading - 1) % 4
  elseif diff == 2 then
    turtle.turnRight(); turtle.turnRight(); nav.heading = (nav.heading + 2) % 4
  end
end

-- Work out which way the turtle is facing by taking one GPS-tracked step.
-- Needs fuel and at least one clear (or diggable) space around it.
-- Returns true on success.
function nav.calibrate(dig)
  if dig == nil then dig = true end
  local x1, y1, z1 = nav.locate(2)
  if not x1 then return false, "no GPS signal" end

  -- Find a direction we can actually move in.
  local moved = false
  for i = 0, 3 do
    if tryForward(dig) then moved = true; break end
    turtle.turnRight()
    if nav.heading then nav.heading = (nav.heading + 1) % 4 end
  end
  if not moved then return false, "boxed in - cannot calibrate" end

  local x2, _, z2 = nav.locate(2)
  if not x2 then return false, "no GPS signal after move" end

  local dx, dz = x2 - x1, z2 - z1
  if     dx ==  1 then nav.heading = titan.EAST
  elseif dx == -1 then nav.heading = titan.WEST
  elseif dz ==  1 then nav.heading = titan.SOUTH
  elseif dz == -1 then nav.heading = titan.NORTH
  else return false, "could not resolve heading" end

  -- Step back to where we started so calibration is non-destructive to position.
  turtle.back()
  return true
end

-- Ensure we have enough fuel; refuel from inventory if low. Returns level.
-- Prefers the dedicated fuel slot (bottom-right = 16), then other slots.
function nav.ensureFuel(min)
  min = min or 1
  if turtle.getFuelLevel() == "unlimited" then return "unlimited" end
  if turtle.getFuelLevel() < min then
    local order = { nav.FUEL_SLOT }
    for slot = 1, 16 do
      if slot ~= nav.FUEL_SLOT then order[#order + 1] = slot end
    end
    for _, slot in ipairs(order) do
      turtle.select(slot)
      if turtle.refuel(0) then       -- is this item a fuel?
        turtle.refuel()
        if turtle.getFuelLevel() >= min then break end
      end
    end
    turtle.select(1)
  end
  return turtle.getFuelLevel()
end

-- Move to an absolute world coordinate. Digs through obstacles by default.
-- opts = { dig = true/false }  (dig defaults to true)
-- Returns true, or false + reason.
function nav.moveTo(tx, ty, tz, opts)
  opts = opts or {}
  local dig = opts.dig
  if dig == nil then dig = true end
  if nav.heading == nil then
    local ok, err = nav.calibrate(dig)
    if not ok then return false, "calibrate failed: " .. tostring(err) end
  end

  local x, y, z = nav.locate(2)
  if not x then return false, "no GPS signal" end

  -- Vertical first (go up before crossing if ascending, keeps us clear of terrain).
  while y < ty do
    local ok, why = tryUp(dig)
    if not ok then return false, "up: " .. tostring(why), x, y, z end
    y = y + 1
  end

  -- East / West axis (X)
  if tx ~= x then
    nav.face(tx > x and titan.EAST or titan.WEST)
    while x ~= tx do
      local ok, why = tryForward(dig)
      if not ok then return false, "X: " .. tostring(why), x, y, z end
      x = x + (tx > x and 1 or -1)
    end
  end

  -- North / South axis (Z)
  if tz ~= z then
    nav.face(tz > z and titan.SOUTH or titan.NORTH)
    while z ~= tz do
      local ok, why = tryForward(dig)
      if not ok then return false, "Z: " .. tostring(why), x, y, z end
      z = z + (tz > z and 1 or -1)
    end
  end

  -- Descend last.
  while y > ty do
    local ok, why = tryDown(dig)
    if not ok then return false, "down: " .. tostring(why), x, y, z end
    y = y - 1
  end

  return true
end

function nav.setHome(x, y, z)
  if not x then x, y, z = nav.locate(2) end
  if not x then return false, "no GPS to set home" end
  nav.home = { x = x, y = y, z = z }
  return true, nav.home
end

function nav.goHome(opts)
  if not nav.home then return false, "no home set" end
  return nav.travelTo(nav.home.x, nav.home.y, nav.home.z, opts)
end

--------------------------------------------------------------------------------
-- Cruise-altitude travel with backfill
--
-- For long horizontal hops, bots climb to a high "cruise" altitude, fly across
-- open sky, then drop down onto the target. Vertical shafts they dig to leave /
-- arrive are remembered and re-filled so they don't leave permanent holes:
--   * blocks broken while climbing out are plugged back immediately, and
--   * the shaft dug to descend onto a spot is recorded and re-filled the next
--     time the bot leaves that spot (before it deposits, so it still has the
--     dug blocks on hand).
-- Restricted blocks are never broken; if the bot can't reach 250 it flies as
-- high as it can.
--------------------------------------------------------------------------------
nav.CRUISE_Y   = 250   -- preferred travel altitude (fleet miners often use 150)
nav.CRUISE_MIN = 12    -- only bother cruising for hops at least this far (horizontally)
nav.repair     = nil   -- { x, z, cells = { [worldY] = blockName } } from the last descent

local function selectExact(name)
  if not name then return false end
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == name then turtle.select(s); return true end
  end
  return false
end

-- Climb to targetY, plugging blocks we break and re-filling any recorded shaft
-- for this column. Returns true, reachedY.
function nav.ascendCruise(targetY)
  local x, y, z = nav.locate(2)
  if not y then return false, "no gps" end
  local rep = (nav.repair and nav.repair.x == x and nav.repair.z == z) and nav.repair.cells or nil
  local prevSolid, prevName = false, nil
  while y < targetY do
    local present, data = turtle.inspectUp()
    if present and titan.isRestricted(data.name) then break end   -- as high as we can
    if present then turtle.digUp() end
    if not turtle.up() then break end
    local vacated = y                                             -- cell we just left
    y = y + 1
    local wantName = (prevSolid and prevName) or (rep and rep[vacated])
    if wantName and selectExact(wantName) then turtle.placeDown() end
    prevSolid, prevName = present, present and data.name or nil
  end
  turtle.select(1)
  if rep then nav.repair = nil end
  return true, y
end

-- Drop to targetY, recording every block we break so we can re-fill on leaving.
-- Never breaks restricted blocks. Returns true, reachedY.
function nav.descendRecord(targetY)
  local x, y, z = nav.locate(2)
  if not y then return false, "no gps" end
  local cells = {}
  while y > targetY do
    local present, data = turtle.inspectDown()
    if present and titan.isRestricted(data.name) then break end
    if present then cells[y - 1] = data.name; turtle.digDown() end
    if not turtle.down() then break end
    y = y - 1
  end
  nav.repair = { x = x, z = z, cells = cells }
  return true, y
end

-- Travel to a coordinate. Long hops go via cruise altitude with backfill;
-- short hops use a direct moveTo. opts.dig controls horizontal digging only
-- (vertical shafts may be dug regardless, because they are re-filled).
function nav.travelTo(tx, ty, tz, opts)
  opts = opts or {}
  local dig = opts.dig
  if dig == nil then dig = true end
  if nav.heading == nil then
    local ok, e = nav.calibrate(dig)
    if not ok then return false, "calibrate: " .. tostring(e) end
  end
  local x, y, z = nav.locate(2)
  if not x then return false, "no gps" end

  if (math.abs(tx - x) + math.abs(tz - z)) < nav.CRUISE_MIN then
    return nav.moveTo(tx, ty, tz, opts)          -- short hop: go direct
  end

  local cruise = tonumber(opts.cruiseY) or nav.CRUISE_Y
  local _, reachedY = nav.ascendCruise(cruise)               -- 1) leave (+ repair old shaft)
  local ok, why = nav.moveTo(tx, reachedY, tz, { dig = dig }) -- 2) fly across at altitude
  if not ok then return false, why end
  local _, gotY = nav.descendRecord(ty)                      -- 3) drop onto target
  if gotY ~= ty then return false, "descent blocked at " .. tostring(gotY) end
  return true
end

--------------------------------------------------------------------------------
-- Master-password auth (talks to the Data Center master floppy, datacenter.lua)
--
-- Lets any program gate an action behind the shared master password without
-- ever storing or seeing the real password: it asks whichever computer holds
-- the master floppy to verify the attempt.  Returns false when no master is
-- online (so setup is denied unless a master exists).
--------------------------------------------------------------------------------
function titan.findMaster(timeout)
  rednet.broadcast({ type = "where_master" }, titan.DC_PROTOCOL)
  local deadline = os.clock() + (timeout or 2)
  while os.clock() < deadline do
    local id, msg = rednet.receive(titan.DC_PROTOCOL, deadline - os.clock())
    if id == nil then break end
    if type(msg) == "table" and msg.type == "master_here" then return id end
  end
  return nil
end

-- Verify a password against the master floppy. Returns true/false.
function titan.checkPassword(password)
  local masterId = titan.findMaster(2)
  if not masterId then return false end          -- no master -> deny
  rednet.send(masterId, { type = "auth", password = password }, titan.DC_PROTOCOL)
  local deadline = os.clock() + 3
  while os.clock() < deadline do
    local id, msg = rednet.receive(titan.DC_PROTOCOL, deadline - os.clock())
    if id == nil then break end
    if id == masterId and type(msg) == "table" and msg.type == "auth_result" then
      return msg.ok == true
    end
  end
  return false
end

-- Prompt for the master password on the terminal and verify it. Returns bool.
function titan.login(promptLabel)
  write((promptLabel or "Master password") .. ": ")
  local pw = read("*")
  return titan.checkPassword(pw)
end

return titan
