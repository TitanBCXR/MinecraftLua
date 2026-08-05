--[[
  host.lua  -  Titan install host (CC: Tweaked)

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
}

local function openModem()
  for _, side in ipairs(redstone.getSides()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      return side
    end
  end
  error("No modem attached. Place a (wireless) modem on this computer.", 0)
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
print("Press Ctrl+T to stop.")
print("")

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
