--[[
  github_install.lua  -  Install the Titan system straight from a GitHub repo
  Titan-Version: 1.2.2

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
local KEEP_ALL = {
  "lib/titan.lua", "datacenter.lua", "console.lua", "admin.lua",
  "router.lua", "router_main.lua", "router_modem.lua",
  "lib/router_hub_net.lua", "lib/router_hub_ui.lua", "lib/router_hub_cmd.lua",
  "offline_miner.lua", "offline_site.lua", "exclude.txt",
  "perimeter_sensor.lua", "perimeter_manager.lua", "tetris.lua", "minesweeper.lua",
  "host.lua", "versions.lua",
}

local GAMES = {
  { key = "1", name = "Tetris (pocket + music/mesh)", run = "tetris.lua",
    files = { "lib/titan.lua", "tetris.lua", "versions.lua" } },
  { key = "2", name = "Minesweeper (lightweight pocket)", run = "minesweeper.lua",
    files = { "minesweeper.lua" } },
}

local ROLES = {
  { key = "1", name = "Parent Center (data center)",       run = "datacenter.lua",
    files = { "lib/titan.lua", "datacenter.lua" } },
  { key = "2", name = "Terminal console (basic commands)",  run = "console.lua",
    files = { "lib/titan.lua", "console.lua" } },
  { key = "3", name = "Admin tablet (pocket console)",      run = "admin.lua",
    files = { "lib/titan.lua", "admin.lua" } },
  { key = "4", name = "Network router (repeater + GPS)",   run = "router.lua",
    files = { "lib/titan.lua", "router.lua", "router_main.lua", "router_modem.lua",
              "lib/router_hub_net.lua", "lib/router_hub_ui.lua", "lib/router_hub_cmd.lua",
              "versions.lua" } },
  { key = "5", name = "Offline miner (cell quarry turtle)", run = "offline_miner.lua",
    files = { "lib/titan.lua", "offline_miner.lua", "exclude.txt" } },
  { key = "6", name = "Offline quarry site board",        run = "offline_site.lua",
    files = { "offline_site.lua", "lib/titan.lua" } },
  { key = "7", name = "Perimeter sensor (Player Detector gate)", run = "perimeter_sensor.lua",
    files = { "lib/titan.lua", "perimeter_sensor.lua" } },
  { key = "8", name = "Perimeter manager (territory board)", run = "perimeter_manager.lua",
    files = { "lib/titan.lua", "perimeter_manager.lua" } },
  { key = "g", name = "Games...", submenu = "games" },
  { key = "h", name = "Install / update host (serves files over rednet)", run = "host.lua",
    files = { "lib/titan.lua", "host.lua", "install.lua", "versions.lua" } },
  { key = "9", name = "Everything (kept files, no auto-run)", run = nil,
    files = KEEP_ALL },
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

-- Pick from a role list. cancelKey returns nil; backKey (optional) returns false.
local function pickFromList(list, opts)
  opts = opts or {}
  local title = opts.title or "== Install =="
  local sourceLine = opts.sourceLine
  local promptHint = opts.promptHint or "What is this device?"
  local cancelKey = (opts.cancelKey or "q"):lower()
  local backKey = opts.backKey and tostring(opts.backKey):lower() or nil
  local lastKey = list[#list].key
  while true do
    local idx = 1
    while idx <= #list do
      local _, h = term.getSize()
      term.clear(); term.setCursorPos(1, 1)
      print(title)
      if sourceLine then print(sourceLine) end
      print(promptHint)
      print("")
      local budget = math.max(4, (h or 13) - 7)
      local shown = 0
      while idx <= #list and shown < budget do
        local r = list[idx]
        print("  " .. r.key .. ") " .. r.name)
        idx = idx + 1
        shown = shown + 1
      end
      print("")
      local qHint = backKey and ("B back, " .. cancelKey:upper() .. " cancel")
        or (cancelKey:upper() .. " cancel")
      if idx <= #list then
        write("Enter #, or Enter=more (" .. qHint .. "): ")
      else
        write("Choose (" .. qHint .. "): ")
      end
      local choice = tostring(read() or ""):lower()
      if choice == cancelKey then return nil end
      if backKey and choice == backKey then return false end
      if choice ~= "" then
        for _, r in ipairs(list) do
          if tostring(r.key):lower() == choice then return r end
        end
        print("Invalid choice."); sleep(1.2)
        idx = 1
      elseif idx > #list then
        idx = 1
      end
    end
  end
end

local function pickRole(title, sourceLine)
  while true do
    local role = pickFromList(ROLES, {
      title = title,
      sourceLine = sourceLine,
      promptHint = "What is this device?  (g = Games)",
    })
    if role == nil then return nil end
    if role.submenu == "games" then
      local game = pickFromList(GAMES, {
        title = "== Games ==",
        promptHint = "Pick a game:",
        backKey = "b",
      })
      if game then return game end
      -- nil = cancel all; false = back to main menu
      if game == nil then return nil end
    else
      return role
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
  ["datacenter.lua"] = "ParentCenter",
  ["console.lua"] = "Console",
  ["admin.lua"] = "Admin",
  ["router.lua"] = "Router",
  ["offline_miner.lua"] = "OfflineMiner",
  ["offline_site.lua"]  = "QuarrySite",
  ["perimeter_sensor.lua"] = "PerimSensor",
  ["perimeter_manager.lua"] = "PerimMgr",
  ["tetris.lua"] = "Tetris",
  ["minesweeper.lua"] = "Minesweeper",
  ["host.lua"] = "TitanHost",
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
