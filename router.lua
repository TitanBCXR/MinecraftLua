--[[
  router.lua  -  Titan network router / repeater (CC: Tweaked)
  Titan-Version: 1.1.5

  Place one (or several) of these to tie the whole network together over
  wireless. Roles:

    MAIN  - directory, OTA update, re-auth authority, GPS host, repeater.
            Devices re-auth to the main router after boot / fleet update.
            Attach up to 3+ monitors for ROSTER / STATS / GPS boards.
    MODEM - repeater (+ optional GPS host) only. Use for coverage; not the
            network authority. Set with `modem` / promote with `main`.

    1. REPEATER - re-transmits rednet traffic (same idea as `repeat`) so devices
       out of direct range still reach each other. Both roles do this.

    2. DIRECTORY (main only) - registry of seen systems; multi-monitor boards
       (roster / stats / gps); answers hello / where_main for fleet re-auth.

    3. GPS HOST - routers can host GPS. Place 4+ spread out for a constellation.

  Requirements: wireless modem (ender recommended). Optional monitors (main).

  Run:  router
]]

local PROTO_ROUTER = "titan_router"           -- discovery / register handshake
local REPEAT       = rednet.CHANNEL_REPEAT     -- 65533
local BROADCAST    = rednet.CHANNEL_BROADCAST  -- 65535
local titanLib     = nil                       -- optional lib/titan.lua (SSH)

--------------------------------------------------------------------------------
-- Modems: open normal rednet (id + broadcast) AND the repeat channel.
--------------------------------------------------------------------------------
local modems = {}
for _, side in ipairs(peripheral.getNames()) do
  if peripheral.getType(side) == "modem" then
    modems[#modems + 1] = side
    if not rednet.isOpen(side) then rednet.open(side) end   -- so we can hear the roster
    peripheral.call(side, "open", REPEAT)                    -- so we can relay
  end
end
if #modems == 0 then error("No modem attached. Put a (wireless) modem on this computer.", 0) end

os.setComputerLabel(os.getComputerLabel() or ("Router-" .. os.getComputerID()))

local BOOT_EPOCH = os.epoch("utc")

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local seen    = {}   -- [id] = { name, hostname, kind, seen }
local relayed = {}   -- [nMessageID] = timerId  (de-dup with 30s expiry)
local stats   = { relayed = 0 }
local rosterDirty = false
local ONLINE_SECS = 45   -- heard within this window => ONLINE on the board
-- Multi-monitor boards (main): roster / stats / gps. Names from peripheral.getName.
local screens = { roster = nil, stats = nil, gps = nil }  -- wrapped monitors
local screenNames = { roster = nil, stats = nil, gps = nil }

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

-- Compass sector from main GPS toward (x,z). MC: N=-Z, E=+X.
-- Cardinals -> North/East/South/West; diagonals -> NE/SE/SW/NW (numbered).
local function sectorInfo(x, z)
  if not gpsCoords or not x or not z then return nil end
  local dx, dz = x - gpsCoords.x, z - gpsCoords.z
  if dx == 0 and dz == 0 then
    return { oct = -1, base = "Center", cardinal = true }
  end
  local a = (math.deg(math.atan2(dx, -dz)) + 360) % 360
  local oct = math.floor((a + 22.5) / 45) % 8
  local bases = {
    [0] = "North", [1] = "NE", [2] = "East", [3] = "SE",
    [4] = "South", [5] = "SW", [6] = "West", [7] = "NW",
  }
  return { oct = oct, base = bases[oct], cardinal = (oct % 2 == 0) }
end

-- Unique hostname for a modem/router at (x,z) relative to main.
local function allocateSectorName(x, z, id)
  local info = sectorInfo(x, z)
  if not info then return "Modem-" .. tostring(id) end
  if info.base == "Center" then return "Center" end
  local peers = { id }
  for sid, d in pairs(seen) do
    if sid ~= id and d.x and d.z
       and (d.kind == "modem" or d.kind == "router") then
      local o = sectorInfo(d.x, d.z)
      if o and o.oct == info.oct then peers[#peers + 1] = sid end
    end
  end
  table.sort(peers)
  local rank = 1
  for i, sid in ipairs(peers) do
    if sid == id then rank = i; break end
  end
  if info.cardinal and rank == 1 then return info.base end
  return info.base .. "-" .. tostring(rank)
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

local function now() return os.epoch("utc") end
local function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end

local function isOnline(d)
  return d and d.seen and d.seen > 0 and ago(d.seen) < ONLINE_SECS
end

-- ONLINE = green, OFFLINE = red, UNKNOWN = yellow (remembered, never heard live).
local function statusOf(d)
  if not d or not d.seen or d.seen <= 0 then
    return "UNKNOWN", colors.yellow
  end
  if ago(d.seen) < ONLINE_SECS then
    return "ONLINE", colors.lime
  end
  return "OFFLINE", colors.red
end

local function countOnlineOffline()
  local on, off, unk = 0, 0, 0
  for _, d in pairs(seen) do
    local st = statusOf(d)
    if st == "ONLINE" then on = on + 1
    elseif st == "UNKNOWN" then unk = unk + 1
    else off = off + 1 end
  end
  return on, off, unk
end

local function deviceCount()
  local on = countOnlineOffline()
  return on
end

local function statusRank(d)
  local st = statusOf(d)
  if st == "ONLINE" then return 0 end
  if st == "UNKNOWN" then return 1 end
  return 2
end

-- Persist remembered systems so the monitor still lists them when offline.
local function saveRoster()
  local list = {}
  for id, d in pairs(seen) do
    list[tostring(id)] = {
      hostname = d.hostname or d.name,
      name = d.hostname or d.name,
      kind = d.kind,
      seen = d.seen or 0,
      x = d.x, y = d.y, z = d.z,
    }
  end
  local f = fs.open(ROSTER, "w"); f.write(textutils.serialize(list)); f.close()
  rosterDirty = false
end

local function loadRoster()
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
      }
      n = n + 1
    end
  end
  return n
end

-- Sorted id list: ONLINE, UNKNOWN, OFFLINE, then hostname, then id.
local function sortedIds()
  local ids = {}
  for id in pairs(seen) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b)
    local da, db = seen[a], seen[b]
    local ra, rb = statusRank(da), statusRank(db)
    if ra ~= rb then return ra < rb end
    local na = tostring(da.hostname or da.name or "")
    local nb = tostring(db.hostname or db.name or "")
    if na ~= nb then return na:lower() < nb:lower() end
    return a < b
  end)
  return ids
end

local remembered = loadRoster()
if remembered > 0 then
  print(("Loaded %d remembered system(s) from %s."):format(remembered, ROSTER))
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
          stats.relayed = stats.relayed + 1
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
-- 2) Directory  (roster + register / main-router handshake) — MAIN only
--------------------------------------------------------------------------------
local function directoryLoop()
  rednet.broadcast({ type = "ping" }, "titan_net")   -- nudge everyone to announce
  rednet.broadcast({ type = "ping" }, "titan_dc")
  claimMain()
  broadcastFleetMap()
  while true do
    local id, msg, proto = rednet.receive()
    if type(msg) == "table" and id then
      local kind = classify(msg)
      local prev = seen[id]
      -- Prefer explicit hostname from registration; fall back to name / prior.
      local host = msg.hostname or msg.name or (prev and (prev.hostname or prev.name))
      local wasOnline = prev and isOnline(prev)
      local px = tonumber(msg.x) or (prev and prev.x)
      local py = tonumber(msg.y) or (prev and prev.y)
      local pz = tonumber(msg.z) or (prev and prev.z)
      -- Main assigns compass hostnames to modems (and unnamed routers) with GPS.
      local assignHostname = nil
      if proto == PROTO_ROUTER and msg.type == "hello"
         and px and pz and (kind == "modem" or msg.kind == "modem"
           or (kind == "router" and msg.autoName)) then
        assignHostname = allocateSectorName(px, pz, id)
        host = assignHostname
      end
      seen[id] = {
        name = host,
        hostname = host,
        kind = kind or (prev and prev.kind) or "device",
        seen = now(),
        x = px, y = py, z = pz,
      }
      rosterDirty = true
      if not prev then
        print(("[+] %s #%d (%s) ONLINE"):format(seen[id].hostname or "?", id, seen[id].kind))
      elseif host and prev.hostname ~= host and prev.name ~= host then
        print(("[~] #%d hostname -> %s"):format(id, host))
      elseif prev and not wasOnline then
        print(("[*] %s #%d back ONLINE"):format(host or "?", id))
      end
      if proto == PROTO_ROUTER then
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
        if assignHostname then reply.assignHostname = assignHostname end
        if msg.type == "hello" then
          reply.type = "here"
          rednet.send(id, reply, PROTO_ROUTER)
        elseif msg.type == "where_main" then
          reply.type = "main_here"
          rednet.send(id, reply, PROTO_ROUTER)
        elseif msg.type == "map_req" then
          broadcastFleetMap()
        end
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
    local status, statusColor = statusOf(d)
    local age = d.seen and d.seen > 0 and (ago(d.seen) .. "s") or "-"
    -- ID + STATUS (colored) + KIND + HOSTNAME
    out.setCursorPos(1, y)
    out.setTextColor(colors.white)
    out.write(("%-4d "):format(id))
    out.setTextColor(statusColor)
    out.write(("%-8s "):format(status))
    out.setTextColor(statusColor)
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
  monLine(out, w, y0, "== STATS ==", colors.white)
  local rows = {
    { ("Router #%d  [%s]"):format(os.getComputerID(), routerRole:upper()), colors.white },
    { ("Hostname: %s"):format(os.getComputerLabel() or "?"), colors.lightGray },
    { ("Uptime: %s"):format(uptimeStr()), colors.white },
    { ("Modems: %d"):format(#modems), colors.white },
    { ("Relayed: %d"):format(stats.relayed), colors.cyan },
    { ("Online: %d"):format(on), colors.lime },
    { ("Offline: %d"):format(off), colors.red },
    { ("Unknown: %d"):format(unk), colors.yellow },
    { ("Remembered: %d"):format(remembered), colors.white },
  }
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
    monLine(out, w, y, ("  %-10s %d"):format(k, kinds[k]), colors.white)
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
    put("  (no fix — need 4 hosts)", colors.orange)
  end
  put("", colors.white)
  put("Constellation: place 4+", colors.gray)
  put("routers with gpshost set.", colors.gray)
end

local function drawBoards()
  local n = refreshScreens()
  if n == 0 then return end

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

local function drawLoop()
  loadScreenAssignments()
  while true do
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

-- MODEM routers: GPS-aware naming (North/East/…) + announce + OTA.
local function modemLoop()
  local mainPos = nil   -- { id, x, y, z }
  local manualName = false
  do
    local c = loadRouterCfg() or {}
    if c.manualHostname then manualName = true end
  end

  local function ownPos()
    if gpsCoords then return gpsCoords.x, gpsCoords.y, gpsCoords.z end
    local x, y, z = gps.locate(1)
    if x then
      return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
    end
    return nil
  end

  local function localSectorName(mx, mz, x, z)
    local dx, dz = x - mx, z - mz
    if dx == 0 and dz == 0 then return "Center" end
    local a = (math.deg(math.atan2(dx, -dz)) + 360) % 360
    local oct = math.floor((a + 22.5) / 45) % 8
    local bases = {
      [0] = "North", [1] = "NE", [2] = "East", [3] = "SE",
      [4] = "South", [5] = "SW", [6] = "West", [7] = "NW",
    }
    local base = bases[oct]
    if oct % 2 == 0 then return base end
    return base .. "-" .. tostring(os.getComputerID())
  end

  local function applyName(name)
    if not name or name == "" or manualName then return end
    local cur = os.getComputerLabel()
    if cur ~= name then
      os.setComputerLabel(name)
      print("[gps] Hostname -> " .. name)
    end
  end

  local function announce()
    local x, y, z = ownPos()
    if not manualName and mainPos and mainPos.x and x then
      applyName(localSectorName(mainPos.x, mainPos.z, x, z))
    end
    local name = os.getComputerLabel() or ("Modem-" .. os.getComputerID())
    local msg = {
      type = "hello", kind = "modem", name = name, hostname = name,
      autoName = not manualName,
    }
    if x then msg.x, msg.y, msg.z = x, y, z end
    rednet.broadcast(msg, PROTO_ROUTER)
  end

  rednet.broadcast({ type = "where_main" }, PROTO_ROUTER)
  announce()
  local nextAnn = os.clock() + 20
  while true do
    if os.clock() >= nextAnn then announce(); nextAnn = os.clock() + 20 end
    local id, msg = rednet.receive(PROTO_ROUTER, math.max(0.2, nextAnn - os.clock()))
    if type(msg) == "table" then
      if (msg.type == "main_claim" or msg.type == "main_here" or msg.type == "here") then
        if msg.x then mainPos = { id = id, x = msg.x, y = msg.y, z = msg.z } end
        if msg.assignHostname then applyName(msg.assignHostname) end
        if msg.type == "main_claim" or msg.type == "main_here" then
          announce()
        end
      elseif msg.type == "update" and id ~= os.getComputerID() then
        print("")
        print(("[OTA] Update from main #%s — downloading, then reboot..."):format(tostring(id)))
        if titanLib and titanLib.updateSelf then
          local ok, err = titanLib.updateSelf()
          if ok then
            print("[OTA] Updated. Rebooting..."); sleep(2); os.reboot()
          else
            print("[OTA] Failed: " .. tostring(err) .. " — rebooting anyway...")
            sleep(2); os.reboot()
          end
        else
          print("[OTA] No install source — rebooting..."); sleep(1); os.reboot()
        end
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
-- Console
--------------------------------------------------------------------------------
local function consoleLoop()
  print(("Titan router #%d [%s]. %d modem(s) repeating. Type 'help'."):format(
    os.getComputerID(), routerRole:upper(), #modems))
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
      print("hostname [name|auto] - set name (modems: auto = GPS North/East/…)")
      print("stats    - relay counts (+ roster if main)")
      print("gpshost [x y z] - show / set this router's GPS host coords")
      if isMain() then
        print("devices  - list remembered systems (ONLINE / OFFLINE)")
        print("forget <id|host> - remove a system from the remembered roster")
        print("screens  - list monitors + roster/stats/gps assignments")
        print("screen <roster|stats|gps> <name|side|auto>  assign a board")
        print("ping     - re-discover the network")
        print("update   - OTA: fleet re-download, reboot, re-auth to main")
        print("reauth   - tell the fleet to re-auth now (no download)")
      end
      print("ssh <id|label> [cmd] - remote shell (needs lib/titan.lua + master pw)")
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
          print("Saved role=modem. Rebooting..."); sleep(1); os.reboot()
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
          local st = statusOf(d)
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
            rosterDirty = true
            saveRoster()
          else
            print("Unknown system: " .. tostring(ref))
          end
        end
      end
    elseif cmd == "hostname" or cmd == "host" then
      if not a[2] then
        print("hostname: " .. (os.getComputerLabel() or "(none)"))
        local c = loadRouterCfg() or {}
        if not isMain() then
          print(c.manualHostname and "Naming: manual (GPS auto-name off)"
            or "Naming: auto from GPS vs main (North/East/…)")
        end
      else
        local name = table.concat(a, " ", 2)
        if name:lower() == "auto" and not isMain() then
          patchRouterCfg({ manualHostname = false })
          print("GPS auto-naming re-enabled. Reboot or wait for next announce.")
        else
          os.setComputerLabel(name)
          if not isMain() then patchRouterCfg({ manualHostname = true }) end
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
          if not isMain() then print("(manual — use `hostname auto` to resume GPS names)") end
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
        print(("[%s] Relayed %d. ONLINE:%d OFFLINE:%d. %d modem(s)."):format(
          routerRole:upper(), stats.relayed, on, off, #modems))
      else
        print(("[MODEM] Relayed %d messages. %d modem(s)."):format(stats.relayed, #modems))
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
    elseif cmd == "update" then
      if not isMain() then
        print("OTA update is MAIN-only. Run `main` on this machine, or use the main router.")
      else
        write("Push OTA update? Fleet will download, reboot, and re-auth to this main. [y/N] ")
        if read():lower() ~= "y" then print("Cancelled."); else
          local rname = os.getComputerLabel() or ("Router-" .. os.getComputerID())
          rednet.broadcast({
            type = "update", from = os.getComputerID(), name = rname,
            mainRouterId = os.getComputerID(), hostname = rname,
          }, PROTO_ROUTER)
          print("Update broadcast sent. Devices will re-download, reboot, and re-auth.")
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

local tasks = { repeaterLoop, consoleLoop }
if isMain() then
  tasks[#tasks + 1] = directoryLoop
  tasks[#tasks + 1] = pingLoop
  tasks[#tasks + 1] = rosterSaveLoop
  tasks[#tasks + 1] = drawLoop
else
  tasks[#tasks + 1] = modemLoop
end
if gpsCoords then tasks[#tasks + 1] = gpsHostLoop end
if titanLib then
  tasks[#tasks + 1] = function()
    titanLib.sshHostLoop(isMain() and "router" or "modem")
  end
end

print(("Role: %s"):format(routerRole:upper()))
if isMain() then
  loadScreenAssignments()
  local nMon = refreshScreens()
  if nMon == 0 then
    print("No monitors yet — attach 1–3 for roster / stats / gps boards.")
  elseif nMon == 1 then
    print("1 monitor: stacked roster + stats + gps. Type `screens`.")
  elseif nMon == 2 then
    print("2 monitors: roster | stats+gps. Type `screens` / `screen`.")
  else
    print(("%d monitors: roster | stats | gps. Type `screens` / `screen`."):format(nMon))
  end
else
  print("MODEM mode: repeating traffic only (no directory / OTA). Use `main` to promote.")
end
parallel.waitForAny(table.unpack(tasks))
for _, role in ipairs(SCREEN_ROLES) do
  local m = screens[role]
  if m then pcall(function() m.clear() end) end
end
if rosterDirty then saveRoster() end
print("Router stopped.")
