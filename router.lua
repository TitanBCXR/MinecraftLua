--[[
  router.lua  -  Titan network router / repeater (CC: Tweaked)

  Place one (or several) of these to tie the whole network together over
  wireless. It does two jobs:

    1. REPEATER - it re-transmits rednet traffic (the same mechanism as the
       built-in `repeat` program), so devices that are out of direct modem range
       still reach each other. This relays BOTH broadcasts and directed messages
       (bot commands, worker deploys, auth checks, ...). Chain several routers to
       cover a large base; duplicate messages are de-duplicated so they don't
       loop forever.

    2. DIRECTORY - it listens to every Titan protocol and keeps a live registry
       of who's online (bots, workers, hubs, POIs, data center, tablets). Any
       device can `net`-register/confirm it's connected (see console.lua's `net`
       command). With a monitor attached it shows the roster + relay stats.

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
local seen    = {}   -- [id] = { name, kind, seen }
local relayed = {}   -- [nMessageID] = timerId  (de-dup with 30s expiry)
local stats   = { relayed = 0 }

-- Router config (persists this router's GPS host coordinates so it re-hosts on boot).
local RCFG      = "router.cfg"
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

local function deviceCount()
  local n = 0
  for _, d in pairs(seen) do if ago(d.seen) < 30 then n = n + 1 end end
  return n
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
      seen[id] = {
        name = msg.name or (prev and prev.name),
        kind = kind or (prev and prev.kind) or "device",
        seen = now(),
      }
      if not prev then
        print(("[+] %s #%d (%s)"):format(seen[id].name or "?", id, seen[id].kind))
      end
      -- Answer register/discovery so a device can confirm it's on the network.
      if proto == PROTO_ROUTER and msg.type == "hello" then
        rednet.send(id, {
          type = "here", label = os.getComputerLabel(), devices = deviceCount(),
        }, PROTO_ROUTER)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Dashboard (only when a monitor is attached, to avoid fighting the console)
--------------------------------------------------------------------------------
local function draw()
  local out = monitor
  local w, h = out.getSize()
  out.setBackgroundColor(colors.black); out.clear()
  local function line(y, txt, c)
    out.setCursorPos(1, y); out.setTextColor(c or colors.white); out.write(tostring(txt):sub(1, w))
  end
  line(1, ("== TITAN ROUTER #%d ==  modems:%d"):format(os.getComputerID(), #modems), colors.yellow)
  line(2, ("relayed:%d  online:%d%s"):format(stats.relayed, deviceCount(),
    gpsCoords and ("  GPS " .. gpsCoords.x .. "," .. gpsCoords.y .. "," .. gpsCoords.z) or ""), colors.lime)
  line(3, "ID   KIND     NAME            AGE", colors.lightGray)
  local y = 4
  for id, d in pairs(seen) do
    if y >= h then break end
    if ago(d.seen) < 60 then
      line(y, ("%-4d %-8s %-15s %ss"):format(id, (d.kind or "?"):sub(1, 8), (d.name or "?"):sub(1, 15), ago(d.seen)),
        ago(d.seen) > 30 and colors.gray or colors.white)
      y = y + 1
    end
  end
end

local function drawLoop()
  while true do draw(); sleep(1) end
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
      print("devices  - list everyone the router has heard")
      print("ping     - re-discover the network")
      print("stats    - relay + device counts")
      print("gpshost [x y z] - show / set this router's GPS host coords")
      print("update   - OTA: tell every device to re-download its files & reboot")
      print("ssh <id|label> [cmd] - remote shell (needs lib/titan.lua + master pw)")
      print("exit")
    elseif cmd == "devices" or cmd == "list" then
      local n = 0
      for id, d in pairs(seen) do
        if ago(d.seen) < 60 then
          n = n + 1
          print(("#%-3d %-8s %-14s %ss"):format(id, d.kind or "?", d.name or "?", ago(d.seen)))
        end
      end
      if n == 0 then print("(no devices heard yet)") end
    elseif cmd == "ping" then
      rednet.broadcast({ type = "ping" }, "titan_net")
      rednet.broadcast({ type = "ping" }, "titan_dc")
      print("Pinged.")
    elseif cmd == "stats" then
      print(("Relayed %d messages. %d devices online. %d modem(s)."):format(
        stats.relayed, deviceCount(), #modems))
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

local tasks = { repeaterLoop, directoryLoop, pingLoop, consoleLoop }
if gpsCoords then tasks[#tasks + 1] = gpsHostLoop end
if monitor then tasks[#tasks + 1] = drawLoop end
if titanLib then tasks[#tasks + 1] = function() titanLib.sshHostLoop("router") end end
parallel.waitForAny(table.unpack(tasks))
if monitor then monitor.clear() end
print("Router stopped.")
