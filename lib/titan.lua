--[[
  titan.lua  -  Shared library for the Titan bot network (CC: Tweaked)

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

-- Open the first wireless (or wired) modem we can find. Returns the side.
function titan.openModem()
  -- Prefer an already-open modem.
  for _, side in ipairs(rs and rs.getSides() or redstone.getSides()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      return side
    end
  end
  error("No modem attached. Place a (wireless) modem on this device.", 0)
end

-- Wrap a payload in a standard envelope and send it to a specific computer id.
function titan.send(id, msgType, data)
  local msg = data or {}
  msg.type = msgType
  msg.from = os.getComputerID()
  msg.name = os.getComputerLabel()
  msg.ts   = os.epoch("utc")
  rednet.send(id, msg, titan.PROTOCOL)
end

-- Broadcast a payload to everyone on the protocol.
function titan.broadcast(msgType, data)
  local msg = data or {}
  msg.type = msgType
  msg.from = os.getComputerID()
  msg.name = os.getComputerLabel()
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
-- Router registration (see router.lua)
--
-- Any device announces itself to the network router so it shows in the router's
-- live directory. registerLoop() is meant to run as one of a program's parallel
-- tasks: it announces immediately, then re-announces periodically so the roster
-- stays fresh regardless of who booted first.
--------------------------------------------------------------------------------
titan.ROUTER_PROTOCOL = "titan_router"

function titan.announce(kind)
  rednet.broadcast({ type = "hello", kind = kind, name = os.getComputerLabel() }, titan.ROUTER_PROTOCOL)
end

-- Announce periodically AND listen for an OTA "update" command from a router.
-- Runs as one of a program's parallel tasks. When the network router broadcasts
-- an update (router's `update` console command), this re-downloads the device's
-- files from wherever it was installed and reboots. See titan.updateSelf below.
function titan.registerLoop(kind, period)
  period = period or 20
  local nextAnnounce = 0
  while true do
    if os.clock() >= nextAnnounce then
      titan.announce(kind)
      nextAnnounce = os.clock() + period
    end
    local id, msg = rednet.receive(titan.ROUTER_PROTOCOL, math.max(0.2, nextAnnounce - os.clock()))
    if type(msg) == "table" and msg.type == "update" then
      print("")
      print(("[OTA] Update requested by #%s. Re-downloading files..."):format(tostring(id)))
      local ok, err = titan.updateSelf()
      if ok then
        print("[OTA] Updated. Rebooting in 2s..."); os.sleep(2); os.reboot()
      else
        print("[OTA] Update failed: " .. tostring(err))
      end
    end
  end
end

--------------------------------------------------------------------------------
-- OTA self-update
--
-- Each installer records HOW this device was installed in `.titan-install`
-- (source + file list + where to fetch from). The network router can then push
-- an "update" to the whole fleet; every device re-downloads its own files from
-- the same source it came from and reboots. No per-device config needed.
--------------------------------------------------------------------------------
titan.MANIFEST = ".titan-install"

function titan.readManifest()
  if not fs.exists(titan.MANIFEST) then return nil end
  local f = fs.open(titan.MANIFEST, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  return type(d) == "table" and d or nil
end

function titan.writeManifest(m)
  local f = fs.open(titan.MANIFEST, "w"); f.write(textutils.serialize(m)); f.close()
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
    if type(msg) == "table" and msg.type == "host_here" then return id end
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

-- Re-download this device's files from its install source. Returns ok, err.
function titan.updateSelf()
  local m = titan.readManifest()
  if not m or type(m.files) ~= "table" then
    return false, "no install manifest (.titan-install) on this device"
  end

  local getter
  if m.source == "github" then
    if not m.base then return false, "manifest missing base url" end
    getter = function(path) return otaHttp(m.base .. path .. "?cb=" .. os.epoch("utc")) end
  elseif m.source == "pastebin" then
    getter = function(path)
      local code = m.codes and m.codes[path]
      if not code then return nil, "no pastebin code" end
      return otaHttp("https://pastebin.com/raw/" .. code .. "?cb=" .. os.epoch("utc"))
    end
  elseif m.source == "host" then
    local hostId = otaFindHost(3)
    if not hostId then return false, "no install host online" end
    getter = function(path) return otaFromHost(hostId, path) end
  else
    return false, "unknown install source: " .. tostring(m.source)
  end

  local failed = {}
  for _, path in ipairs(m.files) do
    local data, err = getter(path)
    if data then otaWriteFile(path, data)
    else failed[#failed + 1] = path .. " (" .. tostring(err) .. ")" end
  end
  if #failed > 0 then return false, "failed: " .. table.concat(failed, ", ") end
  return true
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
function nav.ensureFuel(min)
  min = min or 1
  if turtle.getFuelLevel() == "unlimited" then return "unlimited" end
  if turtle.getFuelLevel() < min then
    for slot = 1, 16 do
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
titan.DC_PROTOCOL = "titan_dc"

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
