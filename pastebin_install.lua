--[[
  pastebin_install.lua  -  Pastebin bootstrap installer for the Titan system
  Titan-Version: 1.1.15

  Pulls the Titan files straight from Pastebin (no in-game host needed). Upload
  each file to pastebin.com once, paste its CODE into the table below, then
  upload THIS file too. In Minecraft each device just runs:

      pastebin get <this-file's-code> install
      install

  It asks what the device is, downloads that role's files (creating lib/ as
  needed), offers a startup.lua, and can launch it.

  A pastebin "code" is the bit after the slash in the URL:
  https://pastebin.com/AbCdEfGh   ->   code is  AbCdEfGh
]]

--==============================================================================
-- 1) FILL THESE IN with your paste codes (leave a value "" if you didn't upload it)
--==============================================================================
local CODES = {
  ["lib/titan.lua"] = "",
  ["hub.lua"]       = "",
  ["bot.lua"]       = "",
  ["poi.lua"]       = "",
  ["worker.lua"]    = "",
  ["botserver.lua"] = "",
  ["datacenter.lua"]= "",
  ["console.lua"]   = "",
  ["admin.lua"]     = "",
  ["gpshost.lua"]   = "",
  ["locator.lua"]   = "",
  ["router.lua"]    = "",
  ["miner.lua"]     = "",
  ["offline_miner.lua"] = "",
  ["loader.lua"]    = "",
  ["marker.lua"]    = "",
  ["storage_manager.lua"] = "",
  ["perimeter_sensor.lua"] = "",
  ["perimeter_manager.lua"] = "",
  ["exclude.txt"]   = "",
  ["versions.lua"]  = "",
}

--==============================================================================
-- 2) Roles -> which files they need + what to auto-run (matches the README)
--==============================================================================
local ROLES = {
  { key = "1", name = "Hub (control computer)",          run = "hub.lua",
    files = { "lib/titan.lua", "hub.lua" } },
  { key = "2", name = "Bot (basic turtle)",              run = "bot.lua",
    files = { "lib/titan.lua", "bot.lua" } },
  { key = "3", name = "POI (location computer)",          run = "poi.lua",
    files = { "lib/titan.lua", "poi.lua" } },
  { key = "4", name = "Parent Center (data center)",      run = "datacenter.lua",
    files = { "lib/titan.lua", "datacenter.lua" } },
  { key = "5", name = "Bots Computer (worker server)",    run = "botserver.lua",
    files = { "lib/titan.lua", "botserver.lua" } },
  { key = "6", name = "Worker (builder/gatherer turtle)", run = "worker.lua",
    files = { "lib/titan.lua", "worker.lua", "miner.lua", "exclude.txt" } },
  { key = "7", name = "Terminal console (basic commands)", run = "console.lua",
    files = { "lib/titan.lua", "console.lua" } },
  { key = "8", name = "Admin tablet (pocket console)",     run = "admin.lua",
    files = { "lib/titan.lua", "admin.lua" } },
  { key = "9", name = "GPS host (needs 4+ for navigation)", run = "gpshost.lua",
    files = { "lib/titan.lua", "gpshost.lua" } },
  { key = "10", name = "GPS locator (pocket)",             run = "locator.lua",
    files = { "lib/titan.lua", "locator.lua" } },
  { key = "11", name = "Network router (repeater + GPS)",  run = "router.lua",
    files = { "lib/titan.lua", "router.lua" } },
  { key = "12", name = "Miner (area quarry turtle)",       run = "miner.lua",
    files = { "lib/titan.lua", "miner.lua", "exclude.txt" } },
  { key = "13", name = "Offline miner (no GPS/network)",  run = "offline_miner.lua",
    files = { "offline_miner.lua", "exclude.txt" } },
  { key = "14", name = "StorageManager (Create storage)", run = "storage_manager.lua",
    files = { "lib/titan.lua", "storage_manager.lua" } },
  { key = "15", name = "Loader (chunk escort / Chunky Turtle)", run = "loader.lua",
    files = { "lib/titan.lua", "loader.lua" } },
  { key = "16", name = "Site marker (area + fleet job request)", run = "marker.lua",
    files = { "lib/titan.lua", "marker.lua" } },
  { key = "17", name = "Perimeter sensor (Player Detector gate)", run = "perimeter_sensor.lua",
    files = { "lib/titan.lua", "perimeter_sensor.lua" } },
  { key = "18", name = "Perimeter manager (territory board)", run = "perimeter_manager.lua",
    files = { "lib/titan.lua", "perimeter_manager.lua" } },
  { key = "19", name = "Everything (all files, no auto-run)", run = nil,
    files = { "lib/titan.lua", "hub.lua", "bot.lua", "poi.lua", "worker.lua", "botserver.lua",
              "datacenter.lua", "console.lua", "admin.lua", "gpshost.lua", "locator.lua", "router.lua",
              "miner.lua", "offline_miner.lua", "loader.lua", "marker.lua", "storage_manager.lua",
              "perimeter_sensor.lua", "perimeter_manager.lua",
              "exclude.txt", "versions.lua" } },
}

--==============================================================================
-- Download helpers
--==============================================================================
local function fetch(path)
  local code = CODES[path]
  if not code or code == "" then return nil, "no paste code set" end
  local url = "https://pastebin.com/raw/" .. code .. "?cb=" .. os.epoch("utc")
  local h = http.get(url)
  if not h then return nil, "http request failed" end
  local data = h.readAll()
  h.close()
  if not data or data == "" then return nil, "empty response" end
  return data
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
if not http then
  printError("HTTP is disabled. Enable the http API in the CC: Tweaked config.")
  return
end

local function pickRole()
  local lastKey = ROLES[#ROLES].key
  while true do
    local idx = 1
    while idx <= #ROLES do
      local _, h = term.getSize()
      term.clear(); term.setCursorPos(1, 1)
      print("== Titan Pastebin Installer ==")
      print("What is this device?  (13=StorageManager)")
      print("")
      local budget = math.max(4, (h or 13) - 6)
      local shown = 0
      while idx <= #ROLES and shown < budget do
        local r = ROLES[idx]
        print("  " .. r.key .. ") " .. r.name)
        idx = idx + 1
        shown = shown + 1
      end
      print("")
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
        print("Invalid choice."); sleep(1.2)
        idx = 1
      elseif idx > #ROLES then
        idx = 1
      end
    end
  end
end

local role = pickRole()
if not role then print("Cancelled."); return end

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
  local data, err = fetch(path)
  if data then
    writeFile(path, data)
    print("ok (" .. #data .. "b)")
  else
    print("FAILED (" .. tostring(err) .. ")")
    failed[#failed + 1] = path
  end
end

if #failed > 0 then
  print("")
  print("Failed: " .. table.concat(failed, ", "))
  print("Check the paste CODES at the top of this installer.")
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
-- We keep only the paste codes this role actually needs.
local roleCodes = {}
for _, path in ipairs(files) do roleCodes[path] = CODES[path] end
writeFile(".titan-install", textutils.serialize({
  source = "pastebin", role = role.name, run = role.run, files = files, codes = roleCodes, version = sysVer,
}))

-- Give this device a role-based label if it doesn't have one yet.
local LABELS = {
  ["hub.lua"] = "Hub", ["bot.lua"] = "Bot", ["poi.lua"] = "POI",
  ["datacenter.lua"] = "ParentCenter", ["botserver.lua"] = "BotsComputer",
  ["worker.lua"] = "Worker", ["console.lua"] = "Console",
  ["admin.lua"] = "Admin", ["host.lua"] = "Host", ["gpshost.lua"] = "GPS",
  ["locator.lua"] = "Locator", ["router.lua"] = "Router", ["miner.lua"] = "Miner",
  ["offline_miner.lua"] = "OfflineMiner",
  ["loader.lua"] = "Loader", ["marker.lua"] = "SiteMarker",
  ["storage_manager.lua"] = "StorageManager",
}
local lbl = role.run and LABELS[role.run]
if lbl and not os.getComputerLabel() then
  os.setComputerLabel(lbl .. "-" .. os.getComputerID())
  print("Label set: " .. os.getComputerLabel())
end

if role.run then
  write("Auto-run " .. role.run .. " on boot? [Y/n] ")
  local yn = read():lower()
  if yn == "" or yn == "y" then
    writeFile("startup.lua", ('shell.run("%s")\n'):format(role.run))
    print("Wrote startup.lua.")
  end
  write("Run " .. role.run .. " now? [Y/n] ")
  local yn2 = read():lower()
  if yn2 == "" or yn2 == "y" then return shell.run(role.run) end
end
print("Done.")
