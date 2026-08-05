--[[
  host.lua  -  Titan install host (CC: Tweaked)
  Titan-Version: 1.1.0

  Run this on the ONE computer that already has all the Titan `.lua` files.
  It serves those files to other in-game devices over rednet, so you can install
  the whole system across your network without pastebin or an external web host.

  Usage:
    1. Put every Titan file on this computer (this `host.lua`, `install.lua`,
       `lib/titan.lua`, `hub.lua`, `bot.lua`, `poi.lua`, `worker.lua`,
       `botserver.lua`, `datacenter.lua`).
    2. Attach a wireless (ideally ender) modem and run:  host.lua
    3. On every other device, seed `install.lua` once (pastebin get / floppy /
       type it in) and run it - it finds this host and pulls what it needs.

  Only serves files it actually has, read-only. Ctrl+T to stop.
]]

local PROTOCOL = "titan_install"

-- Files this host is willing to serve (relative paths). Missing ones are skipped.
local FILES = {
  "install.lua",          -- so a freshly-installed device can re-share the installer
  "lib/titan.lua",
  "hub.lua", "bot.lua", "poi.lua",
  "worker.lua", "botserver.lua",
  "datacenter.lua",
  "console.lua", "admin.lua", "gpshost.lua", "locator.lua", "router.lua",
  "miner.lua", "exclude.txt", "versions.lua",
}

local function openModem()
  local found = nil
  for _, side in ipairs(redstone.getSides()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      pcall(peripheral.call, side, "open", rednet.CHANNEL_REPEAT)
      if not found then found = side end
    end
  end
  if not found then error("No modem attached. Place a (wireless) modem on this computer.", 0) end
  return found
end

-- Relay install traffic across the mesh so distant devices can still reach us.
local function relayLoop()
  local REPEAT, relayed = rednet.CHANNEL_REPEAT, {}
  while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
      local side, channel, replyChannel, message = p1, p2, p3, p4
      if channel == REPEAT and type(message) == "table"
         and message.nMessageID and message.nRecipient and not relayed[message.nMessageID] then
        relayed[message.nMessageID] = os.startTimer(30)
        for _, s in ipairs(redstone.getSides()) do
          if peripheral.getType(s) == "modem" and rednet.isOpen(s) then
            peripheral.call(s, "transmit", REPEAT, replyChannel, message)
            if message.nRecipient ~= REPEAT then
              peripheral.call(s, "transmit", message.nRecipient, replyChannel, message)
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

-- Build the manifest of available files (path + size).
local function manifest()
  local m = {}
  for _, path in ipairs(FILES) do
    if fs.exists(path) and not fs.isDir(path) then
      m[#m + 1] = { path = path, size = fs.getSize(path) }
    end
  end
  return m
end

-- Only files on our published list may be read (no arbitrary path access).
local function isServable(path)
  for _, p in ipairs(FILES) do if p == path then return true end end
  return false
end

local function readFile(path)
  if not isServable(path) or not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  local data = f.readAll()
  f.close()
  return data
end

openModem()
os.setComputerLabel(os.getComputerLabel() or ("TitanHost-" .. os.getComputerID()))

term.clear(); term.setCursorPos(1, 1)
print("== Titan Install Host ==")
print(("Serving %d files as '%s' (#%d)."):format(#manifest(), os.getComputerLabel(), os.getComputerID()))
print("Run 'install.lua' on other devices to pull them.")
print("Mesh relay on — install traffic hops through the routing network.")
print("Press Ctrl+T to stop.")
print("")

local function serveLoop()
  while true do
    local id, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" then
      if msg.type == "discover" then
        rednet.send(id, {
          type  = "host_here",
          label = os.getComputerLabel(),
          files = manifest(),
        }, PROTOCOL)
        print(("[discover] #%d"):format(id))

      elseif msg.type == "get" then
        local data = readFile(msg.path)
        rednet.send(id, {
          type = "file", path = msg.path, ok = data ~= nil, data = data,
        }, PROTOCOL)
        print(("[get] %s -> #%d (%s)"):format(
          tostring(msg.path), id, data and (#data .. "b") or "missing"))
      end
    end
  end
end

parallel.waitForAny(serveLoop, relayLoop)
