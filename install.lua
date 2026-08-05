--[[
  install.lua  -  Titan network installer (CC: Tweaked)

  Downloads the Titan bot-network system onto this device from a running
  `host.lua` on the same rednet network (no pastebin / external web host).

  How to get this file onto a fresh device (pick one, one-time seed):
    * pastebin:  pastebin get <code> install.lua
    * floppy:    copy install.lua onto a disk, then `cp disk/install.lua .`
    * type it:   edit install.lua  (paste it in)

  Then just run:  install.lua
  It finds the host, lets you pick this device's role, pulls the right files,
  optionally writes a startup.lua, and can launch it.

  Requirements: a wireless modem on this device and on the host, in range.
]]

local PROTOCOL = "titan_install"

-- Role -> which files it needs + which program it runs.
-- (Matches the device table in the README.)
local ROLES = {
  { key = "1", name = "Hub (control computer)",           run = "hub.lua",
    files = { "lib/titan.lua", "hub.lua" } },
  { key = "2", name = "Bot (basic turtle)",               run = "bot.lua",
    files = { "lib/titan.lua", "bot.lua" } },
  { key = "3", name = "POI (location computer)",           run = "poi.lua",
    files = { "lib/titan.lua", "poi.lua" } },
  { key = "4", name = "Parent Center (data center)",       run = "datacenter.lua",
    files = { "datacenter.lua" } },
  { key = "5", name = "Bots Computer (worker server)",     run = "botserver.lua",
    files = { "lib/titan.lua", "botserver.lua" } },
  { key = "6", name = "Worker (builder/gatherer turtle)",  run = "worker.lua",
    files = { "lib/titan.lua", "worker.lua" } },
  { key = "7", name = "Terminal console (basic commands)",  run = "console.lua",
    files = { "console.lua" } },
  { key = "8", name = "Admin tablet (pocket console)",      run = "admin.lua",
    files = { "lib/titan.lua", "admin.lua" } },
  { key = "9", name = "GPS host (needs 4+ for navigation)", run = "gpshost.lua",
    files = { "gpshost.lua" } },
  { key = "10", name = "GPS locator (pocket)",              run = "locator.lua",
    files = { "lib/titan.lua", "locator.lua" } },
  { key = "11", name = "Install host (share files to others)", run = "host.lua",
    files = { "lib/titan.lua", "hub.lua", "bot.lua", "poi.lua", "worker.lua", "botserver.lua",
              "datacenter.lua", "console.lua", "admin.lua", "gpshost.lua", "locator.lua", "install.lua" } },
  { key = "12", name = "Everything (all files, no auto-run)", run = nil,
    files = { "lib/titan.lua", "hub.lua", "bot.lua", "poi.lua", "worker.lua", "botserver.lua",
              "datacenter.lua", "console.lua", "admin.lua", "gpshost.lua", "locator.lua", "install.lua" } },
}

local function openModem()
  for _, side in ipairs(redstone.getSides()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      return side
    end
  end
  error("No modem attached. Place a (wireless) modem on this device.", 0)
end

-- Find a host on the network. Returns hostId, hostMsg or nil.
local function findHost(timeout)
  rednet.broadcast({ type = "discover" }, PROTOCOL)
  local deadline = os.clock() + (timeout or 3)
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTOCOL, deadline - os.clock())
    if id == nil then break end
    if type(msg) == "table" and msg.type == "host_here" then return id, msg end
  end
  return nil
end

-- Fetch one file's contents from the host. Returns string or nil.
local function fetch(hostId, path)
  rednet.send(hostId, { type = "get", path = path }, PROTOCOL)
  local deadline = os.clock() + 6
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTOCOL, deadline - os.clock())
    if id == hostId and type(msg) == "table" and msg.type == "file" and msg.path == path then
      return msg.ok and msg.data or nil
    end
  end
  return nil
end

local function writeFile(path, data)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  f.write(data)
  f.close()
end

--==============================================================================
-- Main
--==============================================================================
openModem()
term.clear(); term.setCursorPos(1, 1)
print("== Titan Network Installer ==")
print("Searching for an install host...")

local hostId, hostMsg = findHost(3)
if not hostId then
  print("")
  print("No host found. On the computer that has the files:")
  print("  1) attach a modem in range of this device")
  print("  2) run  host.lua")
  print("then run install.lua here again.")
  return
end

print(("Host: %s (#%d) - %d files available."):format(
  hostMsg.label or "?", hostId, #(hostMsg.files or {})))
print("")
print("What is this device?")
for _, r in ipairs(ROLES) do print("  " .. r.key .. ") " .. r.name) end
print("")
write("Choose 1-" .. #ROLES .. " (or Q to cancel): ")
local choice = read()
if choice:lower() == "q" then print("Cancelled."); return end

local role
for _, r in ipairs(ROLES) do if r.key == choice then role = r; break end end
if not role then print("Invalid choice. Cancelled."); return end

print("")
print("Installing: " .. role.name)
local failed = {}
for _, path in ipairs(role.files) do
  write("  " .. path .. " ... ")
  local data = fetch(hostId, path)
  if data then
    writeFile(path, data)
    print("ok (" .. #data .. "b)")
  else
    print("FAILED")
    failed[#failed + 1] = path
  end
end

if #failed > 0 then
  print("")
  print("Some files failed: " .. table.concat(failed, ", "))
  print("Check the host is still running and retry.")
  return
end

print("")
print("Install complete.")

-- Give this device a role-based label if it doesn't have one yet.
local LABELS = {
  ["hub.lua"] = "Hub", ["bot.lua"] = "Bot", ["poi.lua"] = "POI",
  ["datacenter.lua"] = "ParentCenter", ["botserver.lua"] = "BotsComputer",
  ["worker.lua"] = "Worker", ["console.lua"] = "Console",
  ["admin.lua"] = "Admin", ["host.lua"] = "Host", ["gpshost.lua"] = "GPS",
  ["locator.lua"] = "Locator",
}
local lbl = role.run and LABELS[role.run]
if lbl and not os.getComputerLabel() then
  os.setComputerLabel(lbl .. "-" .. os.getComputerID())
  print("Label set: " .. os.getComputerLabel())
end

-- Optional auto-run on boot + launch now.
if role.run then
  write("Auto-run " .. role.run .. " on boot? [Y/n] ")
  local yn = read():lower()
  if yn == "" or yn == "y" then
    writeFile("startup.lua", ('shell.run("%s")\n'):format(role.run))
    print("Wrote startup.lua.")
  end
  write("Run " .. role.run .. " now? [Y/n] ")
  local yn2 = read():lower()
  if yn2 == "" or yn2 == "y" then
    return shell.run(role.run)
  end
end

print("Done. Files are installed on this device.")
