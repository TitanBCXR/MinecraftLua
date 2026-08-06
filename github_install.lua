--[[
  github_install.lua  -  Install the Titan system straight from a GitHub repo
  Titan-Version: 1.1.14

  Point RAW_BASE at your repo's raw content root, then on each Minecraft device:

      wget run https://raw.githubusercontent.com/YOU/REPO/main/github_install.lua

  (or `wget ... github_install.lua` then run it). It asks what the device is,
  pulls that role's files from GitHub (creating lib/ as needed), offers a
  startup.lua, and can launch it.

  GitHub is a public HTTPS host, so it's on CC: Tweaked's allow-list by default -
  no config changes needed. Use the RAW url (raw.githubusercontent.com), NOT the
  github.com "blob" page.
]]

--==============================================================================
-- 1) SET THIS to your repo's raw root (keep the trailing slash).
--    Format: https://raw.githubusercontent.com/<user>/<repo>/<branch>/
--==============================================================================
local RAW_BASE = "https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/"

--==============================================================================
-- 2) Roles -> which files they need + what to auto-run (matches the README)
--==============================================================================
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
  { key = "11", name = "Network router (repeater + GPS)",   run = "router.lua",
    files = { "lib/titan.lua", "router.lua" } },
  { key = "12", name = "Miner (area quarry turtle)",        run = "miner.lua",
    files = { "lib/titan.lua", "miner.lua", "exclude.txt" } },
  { key = "13", name = "Offline miner (no GPS/network)",   run = "offline_miner.lua",
    files = { "offline_miner.lua", "exclude.txt" } },
  { key = "14", name = "StorageManager (Create storage)",  run = "storage_manager.lua",
    files = { "lib/titan.lua", "storage_manager.lua" } },
  { key = "15", name = "Loader (chunk escort / Chunky Turtle)", run = "loader.lua",
    files = { "lib/titan.lua", "loader.lua" } },
  { key = "16", name = "Site marker (area + fleet job request)", run = "marker.lua",
    files = { "lib/titan.lua", "marker.lua" } },
  { key = "17", name = "Everything (all files, no auto-run)", run = nil,
    files = { "lib/titan.lua", "hub.lua", "bot.lua", "poi.lua", "worker.lua", "botserver.lua",
              "datacenter.lua", "console.lua", "admin.lua", "gpshost.lua", "locator.lua", "router.lua",
              "miner.lua", "offline_miner.lua", "loader.lua", "marker.lua", "storage_manager.lua",
              "exclude.txt", "versions.lua" } },
}

--==============================================================================
-- Download helpers
--==============================================================================
local function fetch(path)
  local url = RAW_BASE .. path .. "?cb=" .. os.epoch("utc")   -- cache-buster
  local h = http.get(url)
  if not h then return nil, "http request failed" end
  local code = h.getResponseCode and h.getResponseCode() or 200
  local data = h.readAll()
  h.close()
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
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
if RAW_BASE:find("YOURNAME/REPO") then
  printError("Edit RAW_BASE at the top of this file to point at your repo first.")
  return
end

local function pickRole(title, sourceLine)
  local lastKey = ROLES[#ROLES].key
  while true do
    local idx = 1
    while idx <= #ROLES do
      local _, h = term.getSize()
      term.clear(); term.setCursorPos(1, 1)
      print(title)
      if sourceLine then print(sourceLine) end
      print("What is this device?  (13=StorageManager)")
      print("")
      local budget = math.max(4, (h or 13) - 7)
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

local role = pickRole("== Titan GitHub Installer ==", "Source: " .. RAW_BASE)
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
  print("Check RAW_BASE, the branch name, and that the repo is public.")
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
writeFile(".titan-install", textutils.serialize({
  source = "github", role = role.name, run = role.run, files = files, base = RAW_BASE, version = sysVer,
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
