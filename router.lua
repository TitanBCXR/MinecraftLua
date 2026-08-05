--[[
  router.lua  -  Titan network router / repeater (CC: Tweaked)
  Titan-Version: 1.1.0

  Place one (or several) of these to tie the whole network together over
  wireless. It does two jobs:

    1. REPEATER - it re-transmits rednet traffic (the same mechanism as the
       built-in `repeat` program), so devices that are out of direct modem range
       still reach each other. This relays BOTH broadcasts and directed messages
       (bot commands, worker deploys, auth checks, ...). Chain several routers to
       cover a large base; duplicate messages are de-duplicated so they don't
       loop forever.

    2. DIRECTORY - it listens to every Titan protocol and keeps a registry of
       systems it has seen. The roster is REMEMBERED across reboots
       (router_roster.cfg). Attach a monitor for a live board that shows each
       hostname as ONLINE or OFFLINE. Any device can `net`-register/confirm
       it's connected (see console.lua's `net` command).

    3. GPS HOST - routers double as GPS hosts. On first run it asks for this
       router's coordinates (or auto-detects if a constellation already exists)
       and then answers gps.locate PINGs. Place 4+ routers, spread out, and they
       ARE your GPS constellation as well as the network backbone.

  Requirements: a computer with at least one WIRELESS modem (ENDER modems give
  unlimited range and are strongly recommended for a backbone router). Optional
  monitor for the dashboard. Self-contained - no lib needed.

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

local monitor = peripheral.find("monitor")
if monitor then monitor.setTextScale(0.5) end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local seen    = {}   -- [id] = { name, hostname, kind, seen }
local relayed = {}   -- [nMessageID] = timerId  (de-dup with 30s expiry)
local stats   = { relayed = 0 }
local rosterDirty = false
local ONLINE_SECS = 45   -- heard within this window => ONLINE on the board

-- Router config (persists this router's GPS host coordinates so it re-hosts on boot).
local RCFG      = "router.cfg"
local ROSTER    = "router_roster.cfg"
local gpsCoords = nil
local function loadRouterCfg()
  if not fs.exists(RCFG) then return nil end
  local f = fs.open(RCFG, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  return type(d) == "table" and d or nil
end
local function saveRouterCfg(c)
  local f = fs.open(RCFG, "w"); f.write(textutils.serialize(c)); f.close()
end

local function now() return os.epoch("utc") end
local function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end

local function isOnline(d)
  return d and d.seen and ago(d.seen) < ONLINE_SECS
end

local function countOnlineOffline()
  local on, off = 0, 0
  for _, d in pairs(seen) do
    if isOnline(d) then on = on + 1 else off = off + 1 end
  end
  return on, off
end

local function deviceCount()
  local on = countOnlineOffline()
  return on
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
      }
      n = n + 1
    end
  end
  return n
end

-- Sorted id list: ONLINE first, then hostname, then id.
local function sortedIds()
  local ids = {}
  for id in pairs(seen) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b)
    local da, db = seen[a], seen[b]
    local oa, ob = isOnline(da), isOnline(db)
    if oa ~= ob then return oa end
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
-- 2) Directory  (roster + register handshake)
--------------------------------------------------------------------------------
local function directoryLoop()
  rednet.broadcast({ type = "ping" }, "titan_net")   -- nudge everyone to announce
  rednet.broadcast({ type = "ping" }, "titan_dc")
  while true do
    local id, msg, proto = rednet.receive()
    if type(msg) == "table" and id then
      local kind = classify(msg)
      local prev = seen[id]
      -- Prefer explicit hostname from registration; fall back to name / prior.
      local host = msg.hostname or msg.name or (prev and (prev.hostname or prev.name))
      local wasOnline = prev and isOnline(prev)
      seen[id] = {
        name = host,
        hostname = host,
        kind = kind or (prev and prev.kind) or "device",
        seen = now(),
      }
      rosterDirty = true
      if not prev then
        print(("[+] %s #%d (%s) ONLINE"):format(seen[id].hostname or "?", id, seen[id].kind))
      elseif host and prev.hostname ~= host and prev.name ~= host then
        print(("[~] #%d hostname -> %s"):format(id, host))
      elseif prev and not wasOnline then
        print(("[*] %s #%d back ONLINE"):format(host or "?", id))
      end
      -- Answer register/discovery so a device can confirm it's on the network.
      if proto == PROTO_ROUTER and msg.type == "hello" then
        local rname = os.getComputerLabel() or ("Router-" .. os.getComputerID())
        local on, off = countOnlineOffline()
        rednet.send(id, {
          type = "here", label = rname, hostname = rname,
          devices = on, online = on, offline = off,
        }, PROTO_ROUTER)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Dashboard (monitor): remembered systems with ONLINE / OFFLINE status
--------------------------------------------------------------------------------
local function draw()
  -- Pick up a monitor attached after boot.
  if not monitor then
    monitor = peripheral.find("monitor")
    if monitor then monitor.setTextScale(0.5) end
  end
  if not monitor then return end

  local out = monitor
  local w, h = out.getSize()
  out.setBackgroundColor(colors.black); out.clear()
  local function line(y, txt, c)
    out.setCursorPos(1, y); out.setTextColor(c or colors.white); out.write(tostring(txt):sub(1, w))
  end

  local on, off = countOnlineOffline()
  local gpsStr = gpsCoords and ("  GPS " .. gpsCoords.x .. "," .. gpsCoords.y .. "," .. gpsCoords.z) or ""
  line(1, ("== TITAN ROUTER #%d ==  modems:%d%s"):format(os.getComputerID(), #modems, gpsStr), colors.yellow)
  line(2, ("ONLINE:%d  OFFLINE:%d  relayed:%d"):format(on, off, stats.relayed),
    on > 0 and colors.lime or colors.orange)
  line(3, "ID   STATUS   KIND     HOSTNAME", colors.lightGray)

  local y = 4
  for _, id in ipairs(sortedIds()) do
    if y > h then break end
    local d = seen[id]
    local host = d.hostname or d.name or "?"
    local online = isOnline(d)
    local status = online and "ONLINE" or "OFFLINE"
    local age = d.seen and d.seen > 0 and (ago(d.seen) .. "s") or "-"
    local row = ("%-4d %-8s %-8s %s"):format(id, status, (d.kind or "?"):sub(1, 8), host)
    if #row > w - 6 then row = row:sub(1, w - 6) end
    line(y, row, online and colors.lime or colors.red)
    -- age tucked on the right if there's room
    local ageStr = tostring(age)
    if w >= #row + #ageStr + 1 then
      out.setCursorPos(w - #ageStr + 1, y)
      out.setTextColor(colors.gray)
      out.write(ageStr)
    end
    y = y + 1
  end
  if y == 4 then
    line(4, "(no systems registered yet)", colors.gray)
  end
end

local function drawLoop()
  while true do
    draw()
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
    sleep(15)
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
  print(("Titan router #%d online. %d modem(s) repeating. Type 'help'."):format(
    os.getComputerID(), #modems))
  while true do
    write("router> ")
    local a = {}
    for word in tostring(read()):gmatch("%S+") do a[#a + 1] = word end
    local cmd = (a[1] or ""):lower()

    if cmd == "" then
      -- ignore
    elseif cmd == "help" then
      print("devices  - list remembered systems (ONLINE / OFFLINE)")
      print("forget <id|host> - remove a system from the remembered roster")
      print("hostname [name] - get or set this router's hostname")
      print("ping     - re-discover the network")
      print("stats    - relay + online/offline counts")
      print("gpshost [x y z] - show / set this router's GPS host coords")
      print("update   - OTA: tell every device to re-download its files & reboot")
      print("ssh <id|label> [cmd] - remote shell (needs lib/titan.lua + master pw)")
      print("exit")
    elseif cmd == "devices" or cmd == "list" then
      local on, off = countOnlineOffline()
      print(("Remembered systems — ONLINE:%d  OFFLINE:%d"):format(on, off))
      local n = 0
      for _, id in ipairs(sortedIds()) do
        local d = seen[id]
        n = n + 1
        local st = isOnline(d) and "ONLINE" or "OFFLINE"
        local age = (d.seen and d.seen > 0) and (ago(d.seen) .. "s ago") or "never"
        print(("#%-3d %-8s %-8s %-18s %s"):format(
          id, st, d.kind or "?", d.hostname or d.name or "?", age))
      end
      if n == 0 then print("(none yet — wait for devices to register)") end
    elseif cmd == "forget" then
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
    elseif cmd == "hostname" or cmd == "host" then
      if not a[2] then
        print("hostname: " .. (os.getComputerLabel() or "(none)"))
      else
        local name = table.concat(a, " ", 2)
        if titanLib then
          local ok, err = titanLib.setHostname(name, "router")
          if ok then print("hostname set: " .. ok) else print(tostring(err)) end
        else
          os.setComputerLabel(name)
          rednet.broadcast({ type = "hello", kind = "router", name = name, hostname = name }, PROTO_ROUTER)
          print("hostname set: " .. name)
        end
      end
    elseif cmd == "ping" then
      rednet.broadcast({ type = "ping" }, "titan_net")
      rednet.broadcast({ type = "ping" }, "titan_dc")
      rednet.broadcast({ type = "ping" }, PROTO_ROUTER)
      print("Pinged.")
    elseif cmd == "stats" then
      local on, off = countOnlineOffline()
      print(("Relayed %d messages. ONLINE:%d OFFLINE:%d. %d modem(s)."):format(
        stats.relayed, on, off, #modems))
    elseif cmd == "gpshost" then
      if a[2] and a[3] and a[4] then
        saveRouterCfg({ gps = { x = tonumber(a[2]), y = tonumber(a[3]), z = tonumber(a[4]) } })
        print("Saved GPS coords. Rebooting to start hosting..."); sleep(1); os.reboot()
      elseif gpsCoords then
        print(("Hosting GPS at %d, %d, %d."):format(gpsCoords.x, gpsCoords.y, gpsCoords.z))
      else
        print("Not hosting GPS. Usage: gpshost <x> <y> <z>")
      end
    elseif cmd == "update" then
      -- Broadcast OTA to every device running titan.networkLoop (they re-download
      -- from their install source via .titan-install and reboot).
      write("Push OTA update to the whole fleet? [y/N] ")
      if read():lower() ~= "y" then print("Cancelled."); else
        rednet.broadcast({
          type = "update", from = os.getComputerID(), name = os.getComputerLabel(),
        }, PROTO_ROUTER)
        print("Update broadcast sent. Devices with .titan-install will re-download & reboot.")
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
-- GPS hosting setup (routers double as GPS hosts). First run only; saved to cfg.
--------------------------------------------------------------------------------
local rcfg = loadRouterCfg()
if rcfg and rcfg.gps then
  gpsCoords = rcfg.gps
elseif rcfg and rcfg.gpsHost == false then
  -- previously opted out; leave GPS hosting off
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
  saveRouterCfg(gpsCoords and { gps = gpsCoords } or { gpsHost = false })
  if gpsCoords then print(("Hosting GPS at %d, %d, %d."):format(gpsCoords.x, gpsCoords.y, gpsCoords.z)) end
end

--------------------------------------------------------------------------------
-- Shared lib instance (SSH host + client must share one reply inbox).
if fs.exists("lib/titan.lua") then
  titanLib = dofile("lib/titan.lua")
end

local tasks = { repeaterLoop, directoryLoop, pingLoop, consoleLoop, rosterSaveLoop, drawLoop }
if gpsCoords then tasks[#tasks + 1] = gpsHostLoop end
if titanLib then tasks[#tasks + 1] = function() titanLib.sshHostLoop("router") end end
if monitor then
  print("Monitor attached — showing ONLINE/OFFLINE system board.")
else
  print("No monitor yet — attach one anytime; the board will appear.")
end
parallel.waitForAny(table.unpack(tasks))
if monitor then pcall(function() monitor.clear() end) end
if rosterDirty then saveRoster() end
print("Router stopped.")
