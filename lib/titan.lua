--[[
  titan.lua  -  Shared library for the Titan bot network (CC: Tweaked)
  Titan-Version: 1.1.6

  Provides:
    * Rednet protocol constants + message type enum
    * Modem discovery / open helpers
    * send / broadcast / recv wrappers with a consistent envelope
    * GPS-based turtle navigation (moveTo, goHome, heading calibration)

  Drop this file at:  lib/titan.lua  on EVERY computer & turtle,
  or copy it around with `pastebin`, disks, or `wget`.

  Load it with:   local titan = require("lib.titan")
  (or, if you keep it next to your program: local titan = dofile("titan.lua"))
]]

local titan = {}

-- The rednet protocol name every device on the network shares.
titan.PROTOCOL = "titan_net"

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
}
-- Any block whose id starts with one of these prefixes is also protected
-- (keeps bots from mining computers, turtles, drives, disk-carts, etc.).
titan.RESTRICTED_PREFIXES = { "computercraft:", "advancedperipherals:" }

function titan.isRestricted(name)
  if not name then return false end
  if titan.RESTRICTED[name] then return true end
  for _, p in ipairs(titan.RESTRICTED_PREFIXES) do
    if name:sub(1, #p) == p then return true end
  end
  return false
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

-- Open every attached modem for rednet AND the rednet repeat channel, so this
-- device can join the routing mesh (see titan.relayLoop / titan.networkLoop).
-- Returns the first modem side found.
function titan.openModem()
  local found = nil
  for _, side in ipairs(rs and rs.getSides() or redstone.getSides()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      -- CHANNEL_REPEAT (65533): CraftOS hop channel used by router.lua and every
      -- mesh peer. Opening it here lets relayLoop forward traffic for neighbours.
      pcall(peripheral.call, side, "open", rednet.CHANNEL_REPEAT)
      if not found then found = side end
    end
  end
  if not found then
    error("No modem attached. Place a (wireless) modem on this device.", 0)
  end
  return found
end

-- List every modem side that is currently open for rednet (for relays).
function titan.modemSides()
  local sides = {}
  for _, side in ipairs(rs and rs.getSides() or redstone.getSides()) do
    if peripheral.getType(side) == "modem" and rednet.isOpen(side) then
      sides[#sides + 1] = side
    end
  end
  return sides
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
titan.DC_AUTH_KINDS = { bot = true, worker = true, miner = true }

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

function titan.announce(kind)
  if type(kind) == "string" and kind ~= "" then lastAnnounceKind = kind end
  local host = titan.hostname(lastAnnounceKind)
  rednet.broadcast({
    type = "hello", kind = lastAnnounceKind, name = host, hostname = host,
    mainRouterId = titan.getMainRouterId(),
  }, titan.ROUTER_PROTOCOL)
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
  period = period or 20
  -- Re-auth immediately on boot / after OTA reboot.
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

  local nextAnnounce = os.clock() + period
  while true do
    if os.clock() >= nextAnnounce then
      titan.announce(kind)
      nextAnnounce = os.clock() + period
    end
    local id, msg = rednet.receive(titan.ROUTER_PROTOCOL, math.max(0.2, nextAnnounce - os.clock()))
    if type(msg) == "table" then
      -- Optional app hook (e.g. locator radar) — runs before built-in handlers.
      if type(titan.onRouterMessage) == "function" then
        pcall(titan.onRouterMessage, id, msg)
      end
      if msg.type == "main_claim" or msg.type == "main_here" then
        titan.setMainRouterId(id)
      elseif msg.type == "reauth" then
        print("[net] Re-auth requested by router #" .. tostring(id))
        titan.reauth(kind)
      elseif msg.type == "update" then
        print("")
        print(("[OTA] Update from router #%s — downloading, then reboot + re-auth..."):format(tostring(id)))
        if msg.mainRouterId then titan.setMainRouterId(msg.mainRouterId) end
        local uok, err = titan.updateSelf()
        if uok then
          print("[OTA] Updated. Rebooting in 2s (will re-auth on boot)..."); os.sleep(2); os.reboot()
        else
          print("[OTA] Update failed: " .. tostring(err))
        end
      end
    end
  end
end

-- Mesh repeater: forward rednet hop packets on CHANNEL_REPEAT (de-duplicated).
-- Faithful to CraftOS `repeat` / router.lua. Safe to run on every bot — if the
-- main router is out of range, nearby workers/miners keep the network linked.
function titan.relayLoop()
  local REPEAT = rednet.CHANNEL_REPEAT
  local relayed = {}   -- [nMessageID] = timerId
  -- Ensure the repeat channel is open (in case openModem ran before an upgrade).
  for _, side in ipairs(titan.modemSides()) do
    pcall(peripheral.call, side, "open", REPEAT)
  end
  while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
      local side, channel, replyChannel, message = p1, p2, p3, p4
      if channel == REPEAT and type(message) == "table"
         and message.nMessageID and message.nRecipient then
        if not relayed[message.nMessageID] then
          relayed[message.nMessageID] = os.startTimer(30)
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
    elseif event == "timer" then
      for mid, timer in pairs(relayed) do
        if timer == p1 then relayed[mid] = nil; break end
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
    function() titan.sshHostLoop(kind) end
  )
end

--------------------------------------------------------------------------------
-- Remote shell ("SSH") over rednet
--
-- From console/admin/router:  ssh <id|label>           interactive session
--                             ssh <id|label> <command>  one-shot remote exec
--
-- Jump: if the target is out of direct range, SSH hops through modem/router
-- shells (proxy sessions) until it reaches the destination — same idea as
-- jumping hosts. Auth: master password via the Parent Center.
--
-- Every device running titan.networkLoop (or sshHostLoop) hosts a shell.
-- Built-in remote command: `reboot` (acks, then os.reboot).
--------------------------------------------------------------------------------
titan.SSH_PROTOCOL = "titan_ssh"
titan.SSH_MAX_JUMPS = 8

local sshSessions   = {}   -- [token] = session table
local sshClientQ    = {}   -- inbox for replies (host loop + client share one receiver)
local sshHostPending = {}  -- host requests received while a dial/jump is in progress
local sshKind       = "device"

local function sshSend(id, msg)
  rednet.send(id, msg, titan.SSH_PROTOCOL)
end

local function sshNewToken()
  return tostring(os.getComputerID()) .. "-" .. tostring(os.epoch("utc")) .. "-" .. tostring(math.random(1000, 9999))
end

local function sshIsClientReply(t)
  return t == "ssh_pong" or t == "ssh_ok" or t == "ssh_deny" or t == "ssh_result"
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

-- Capture shell output by redirecting the terminal to a string buffer.
-- Returns out, ok [, doReboot]
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
  if not shell then
    return "(no shell on this device)", false, false
  end
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
  local old = term.redirect(fake)
  local ok = shell.run(low)
  term.redirect(old)
  local text = table.concat(out)
  if text == "" then text = ok and "(ok)" or "(failed)" end
  return text, ok and true or false, false
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

local function sshRunLocal(line)
  return sshCaptureRun(line)
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
  print("Remote shell. Commands: reboot | exit")

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

local function otaFindHost(timeout)
  rednet.broadcast({ type = "discover" }, "titan_install")
  local deadline = os.clock() + (timeout or 3)
  while os.clock() < deadline do
    local id, msg = rednet.receive("titan_install", deadline - os.clock())
    if id == nil then break end
    if type(msg) == "table" and msg.type == "host_here" then return id, msg end
  end
  return nil
end

local function otaFromHost(hostId, path)
  rednet.send(hostId, { type = "get", path = path }, "titan_install")
  local deadline = os.clock() + 6
  while os.clock() < deadline do
    local id, msg = rednet.receive("titan_install", deadline - os.clock())
    if id == hostId and type(msg) == "table" and msg.type == "file" and msg.path == path then
      if msg.ok and msg.data then return msg.data end
      return nil, "missing on host"
    end
  end
  return nil, "timeout"
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
    local hostId, hostMsg = otaFindHost(3)
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

-- Re-download every package listed in the `packages` file from the install source.
-- opts.onProgress(path, ok, detail) optional. Returns ok, detail.
function titan.updateSelf(opts)
  opts = opts or {}
  local m = titan.readManifest()
  local getter, gerr = otaBuildGetter(m)
  if not getter then return false, gerr end

  local paths, perr = otaCollectUpdatePaths()
  if not paths then return false, perr end

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
  return true, { updated = okCount, skipped = 0 }
end

--------------------------------------------------------------------------------
-- Turtle navigation (GPS based)
--
-- These functions only work on turtles that have:
--   * a wireless modem, and
--   * a working GPS constellation in range (see README).
--------------------------------------------------------------------------------

local nav = {}
titan.nav = nav

nav.heading = nil        -- current facing (titan.NORTH/EAST/SOUTH/WEST) once calibrated
nav.home    = nil        -- {x, y, z} set with nav.setHome()
nav.FUEL_SLOT = 16       -- bottom-right inventory slot — dedicated fuel slot for turtles

-- Locate ourselves via GPS. Returns x, y, z or nil.
function nav.locate(timeout)
  local x, y, z = gps.locate(timeout or 2)
  if not x then return nil end
  return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
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
nav.CRUISE_Y   = 250   -- preferred travel altitude
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

  local _, reachedY = nav.ascendCruise(nav.CRUISE_Y)         -- 1) leave (+ repair old shaft)
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
