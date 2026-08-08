--[[
  host.lua  -  Titan install / update host (CC: Tweaked)
  Titan-Version: 1.2.0

  Run this on ONE computer that already has the Titan files (your "update
  server"). It serves those files over rednet so pockets and other devices can
  install / OTA without storing any GitHub / wget URL on the clients.

  Usage:
    1. Keep this machine updated (you may wget/GitHub here — clients never see it).
    2. Wireless (or ender) modem + run:  host
    3. Give out tablets installed via install.lua role `t` (or disk copy).
       Their `.titan-install` is source=host only — updates pull over rednet.

  Only serves files on the published list. Ctrl+T to stop.
]]

local PROTOCOL = "titan_install"

local FILES = {
  "install.lua",
  "lib/titan.lua",
  "versions.lua",
  "datacenter.lua",
  "console.lua",
  "admin.lua",
  "router.lua",
  "router_main.lua",
  "router_modem.lua",
  "lib/router_hub_net.lua",
  "lib/router_hub_ui.lua",
  "lib/router_hub_cmd.lua",
  "offline_miner.lua",
  "offline_site.lua",
  "perimeter_sensor.lua",
  "perimeter_manager.lua",
  "tetris.lua",
  "host.lua",
  "exclude.txt",
  "github_install.lua",
  "pastebin_install.lua",
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
  if not found then error("No modem attached. Place a (wireless) modem on this device.", 0) end
  return found
end

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

local function manifest()
  local m = {}
  for _, path in ipairs(FILES) do
    if fs.exists(path) and not fs.isDir(path) then
      m[#m + 1] = { path = path, size = fs.getSize(path) }
    end
  end
  return m
end

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
print("Clients update over rednet (no GitHub URL on tablets).")
print("Run install.lua on other devices, or let Tetris boot-check pull updates.")
print("Mesh relay on. Ctrl+T to stop.")
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

local tasks = { serveLoop, relayLoop }
if fs.exists("lib/titan.lua") then
  local titan = dofile("lib/titan.lua")
  tasks[#tasks + 1] = function() titan.networkLoop("host") end
end
parallel.waitForAny(table.unpack(tasks))
