--[[
  install.lua  -  Titan network installer (CC: Tweaked)
  Titan-Version: 1.1.13

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
    files = { "lib/titan.lua", "datacenter.lua" } },
  { key = "5", name = "Bots Computer (worker server)",     run = "botserver.lua",
    files = { "lib/titan.lua", "botserver.lua" } },
  { key = "6", name = "Worker (builder/gatherer turtle)",  run = "worker.lua",
    files = { "lib/titan.lua", "worker.lua", "miner.lua", "exclude.txt" } },
  { key = "7", name = "Terminal console (basic commands)",  run = "console.lua",
    files = { "lib/titan.lua", "console.lua" } },
  { key = "8", name = "Admin tablet (pocket console)",      run = "admin.lua",
    files = { "lib/titan.lua", "admin.lua" } },
  { key = "9", name = "GPS host (needs 4+ for navigation)", run = "gpshost.lua",
    files = { "lib/titan.lua", "gpshost.lua" } },
  { key = "10", name = "GPS locator (pocket)",              run = "locator.lua",
    files = { "lib/titan.lua", "locator.lua" } },
  { key = "11", name = "Network router (repeater + GPS)",    run = "router.lua",
    files = { "lib/titan.lua", "router.lua" } },
  { key = "12", name = "Miner (area quarry turtle)",         run = "miner.lua",
    files = { "lib/titan.lua", "miner.lua", "exclude.txt" } },
  { key = "13", name = "StorageManager (Create storage)",  run = "storage_manager.lua",
    files = { "lib/titan.lua", "storage_manager.lua" } },
  { key = "14", name = "Loader (chunk escort / Chunky Turtle)", run = "loader.lua",
    files = { "lib/titan.lua", "loader.lua" } },
  { key = "15", name = "Site marker (area + fleet job request)", run = "marker.lua",
    files = { "lib/titan.lua", "marker.lua" } },
  { key = "16", name = "Install host (share files to others)", run = "host.lua",
    files = { "lib/titan.lua", "hub.lua", "bot.lua", "poi.lua", "worker.lua", "botserver.lua",
              "datacenter.lua", "console.lua", "admin.lua", "gpshost.lua", "locator.lua", "router.lua",
              "miner.lua", "loader.lua", "marker.lua", "storage_manager.lua", "exclude.txt", "versions.lua", "install.lua" } },
  { key = "17", name = "Everything (all files, no auto-run)", run = nil,
    files = { "lib/titan.lua", "hub.lua", "bot.lua", "poi.lua", "worker.lua", "botserver.lua",
              "datacenter.lua", "console.lua", "admin.lua", "gpshost.lua", "locator.lua", "router.lua",
              "miner.lua", "loader.lua", "marker.lua", "storage_manager.lua", "exclude.txt", "versions.lua", "install.lua" } },
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

local function pickRole()
  local lastKey = ROLES[#ROLES].key
  while true do
    local idx = 1
    while idx <= #ROLES do
      local _, h = term.getSize()
      print("")
      print("What is this device?  (13=StorageManager)")
      local budget = math.max(4, (h or 13) - 6)
      local shown = 0
      local start = idx
      while idx <= #ROLES and shown < budget do
        local r = ROLES[idx]
        print("  " .. r.key .. ") " .. r.name)
        idx = idx + 1
        shown = shown + 1
      end
      if idx <= #ROLES then
        write("Enter #, or Enter=more (Q cancel): ")
      else
        write("Choose 1-" .. lastKey .. " (Q cancel): ")
      end
      local choice = tostring(read() or "")
      if choice:lower() == "q" then return nil end
      if choice ~= "" then
        for _, r in ipairs(ROLES) do
          if r.key == choice then return r end
        end
        print("Invalid choice.")
        idx = start
      elseif idx > #ROLES then
        idx = 1
      end
    end
  end
end

local role = pickRole()
if not role then print("Cancelled."); return end

-- Always ship the versions catalog with every role.
local files, hasVersions = {}, false
for _, path in ipairs(role.files) do
  files[#files + 1] = path
  if path == "versions.lua" then hasVersions = true end
end
if not hasVersions then files[#files + 1] = "versions.lua" end

print("")
print("Installing: " .. role.name)
local failed = {}
for _, path in ipairs(files) do
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

local sysVer = "1.1.0"
if fs.exists("versions.lua") then
  local ok, cat = pcall(dofile, "versions.lua")
  if ok and type(cat) == "table" and cat.system then sysVer = cat.system end
end

-- Desired packages list (`packages` file) — edit anytime, then run `update`.
if fs.exists("lib/titan.lua") then
  local ok, titan = pcall(dofile, "lib/titan.lua")
  if ok and titan and titan.writePackageList then files = titan.writePackageList(files) end
else
  local pf = fs.open("packages", "w")
  pf.write("# Titan packages — desired packages for this computer\n")
  pf.write("# One path per line. Edit this list, then run: update\n#\n")
  for _, path in ipairs(files) do pf.write(path .. "\n") end
  pf.close()
end

-- Record how this device was installed so it can self-update later when the
-- network router pushes an OTA update (see lib/titan.lua : titan.updateSelf).
-- Source is "host": on update it re-discovers a running host.lua over rednet.
writeFile(".titan-install", textutils.serialize({
  source = "host", role = role.name, run = role.run, files = files, version = sysVer,
}))

-- Give this device a role-based label if it doesn't have one yet.
local LABELS = {
  ["hub.lua"] = "Hub", ["bot.lua"] = "Bot", ["poi.lua"] = "POI",
  ["datacenter.lua"] = "ParentCenter", ["botserver.lua"] = "BotsComputer",
  ["worker.lua"] = "Worker", ["console.lua"] = "Console",
  ["admin.lua"] = "Admin", ["host.lua"] = "Host", ["gpshost.lua"] = "GPS",
  ["locator.lua"] = "Locator", ["router.lua"] = "Router", ["miner.lua"] = "Miner",
  ["loader.lua"] = "Loader", ["marker.lua"] = "SiteMarker",
  ["storage_manager.lua"] = "StorageManager",
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
