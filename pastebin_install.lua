--[[
  pastebin_install.lua  -  Pastebin bootstrap installer for the Titan system
  Titan-Version: 1.2.8

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
  ["datacenter.lua"]= "",
  ["console.lua"]   = "",
  ["admin.lua"]     = "",
  ["router.lua"]    = "",
  ["router_main.lua"] = "",
  ["router_modem.lua"] = "",
  ["lib/router_hub_net.lua"] = "",
  ["lib/router_hub_ui.lua"] = "",
  ["lib/router_hub_cmd.lua"] = "",
  ["offline_miner.lua"] = "",
  ["offline_site.lua"] = "",
  ["quarry/workers/offline_miner.lua"] = "",
  ["quarry/workers/strip_miner.lua"] = "",
  ["quarry/managers/offline_site.lua"] = "",
  ["perimeter_sensor.lua"] = "",
  ["perimeter_manager.lua"] = "",
  ["tetris.lua"]    = "",
  ["minesweeper.lua"] = "",
  ["sandstorm.lua"] = "",
  ["luigi_poker.lua"] = "",
  ["slots.lua"] = "",
  ["games.lua"] = "",
  ["games_catalog.lua"] = "",
  ["host.lua"]      = "",
  ["exclude.txt"]   = "",
  ["versions.lua"]  = "",
}

local KEEP_ALL = {
  "lib/titan.lua", "datacenter.lua", "console.lua", "admin.lua",
  "router.lua", "router_main.lua", "router_modem.lua",
  "lib/router_hub_net.lua", "lib/router_hub_ui.lua", "lib/router_hub_cmd.lua",
  "quarry/workers/offline_miner.lua", "quarry/workers/strip_miner.lua",
  "quarry/managers/offline_site.lua",
  "offline_miner.lua", "offline_site.lua", "exclude.txt",
  "perimeter_sensor.lua", "perimeter_manager.lua", "tetris.lua", "minesweeper.lua",
  "sandstorm.lua", "luigi_poker.lua", "slots.lua",
  "games.lua", "games_catalog.lua", "host.lua", "versions.lua",
}

local GAMES_SUITE = {
  "games.lua", "games_catalog.lua", "versions.lua", "lib/titan.lua",
  "tetris.lua", "minesweeper.lua", "luigi_poker.lua", "slots.lua",
}

--==============================================================================
-- 2) Roles -> which files they need + what to auto-run (matches the README)
--==============================================================================
local GAMES = {
  { key = "0", name = "Games launcher (all + auto-update)", run = "games.lua",
    files = GAMES_SUITE },
  { key = "1", name = "Tetris (pocket / monitor + music)", run = "tetris.lua",
    files = { "lib/titan.lua", "tetris.lua", "versions.lua" } },
  { key = "2", name = "Minesweeper (pocket / monitor)", run = "minesweeper.lua",
    files = { "minesweeper.lua" } },
  { key = "3", name = "Luigi Picture Poker (pocket)", run = "luigi_poker.lua",
    files = { "luigi_poker.lua" } },
  { key = "4", name = "Slots (3-reel)", run = "slots.lua",
    files = { "slots.lua" } },
}

local QUARRY_WORKERS = {
  { key = "1", name = "Cell quarry miner", run = "quarry/workers/offline_miner.lua",
    files = { "lib/titan.lua", "quarry/workers/offline_miner.lua", "offline_miner.lua", "exclude.txt" } },
  { key = "2", name = "Strip miner (branch tunnels)", run = "quarry/workers/strip_miner.lua",
    files = { "lib/titan.lua", "quarry/workers/strip_miner.lua", "exclude.txt" } },
}

local QUARRY_MANAGERS = {
  { key = "1", name = "Site board (cell fleet + geo)", run = "quarry/managers/offline_site.lua",
    files = { "lib/titan.lua", "quarry/managers/offline_site.lua", "offline_site.lua" } },
}

local QUARRY = {
  { key = "w", name = "Workers...", submenu = "quarry_workers" },
  { key = "m", name = "Managers...", submenu = "quarry_managers" },
}

local SUBMENUS = {
  games = GAMES,
  quarry = QUARRY,
  quarry_workers = QUARRY_WORKERS,
  quarry_managers = QUARRY_MANAGERS,
}

local ROLES = {
  { key = "1", name = "Parent Center (data center)",      run = "datacenter.lua",
    files = { "lib/titan.lua", "datacenter.lua" } },
  { key = "2", name = "Terminal console (basic commands)", run = "console.lua",
    files = { "lib/titan.lua", "console.lua" } },
  { key = "3", name = "Admin tablet (pocket console)",     run = "admin.lua",
    files = { "lib/titan.lua", "admin.lua" } },
  { key = "4", name = "Network router (repeater + GPS)",  run = "router.lua",
    files = { "lib/titan.lua", "router.lua", "router_main.lua", "router_modem.lua",
              "lib/router_hub_net.lua", "lib/router_hub_ui.lua", "lib/router_hub_cmd.lua",
              "versions.lua" } },
  { key = "q", name = "Quarry (workers & managers)...", submenu = "quarry" },
  { key = "7", name = "Perimeter sensor (Player Detector gate)", run = "perimeter_sensor.lua",
    files = { "lib/titan.lua", "perimeter_sensor.lua" } },
  { key = "8", name = "Perimeter manager (territory board)", run = "perimeter_manager.lua",
    files = { "lib/titan.lua", "perimeter_manager.lua" } },
  { key = "g", name = "Games launcher (all + auto-update)", run = "games.lua",
    files = GAMES_SUITE },
  { key = "i", name = "Install one game...", submenu = "games" },
  { key = "h", name = "Install / update host (serves files over rednet)", run = "host.lua",
    files = { "lib/titan.lua", "host.lua", "install.lua", "versions.lua" } },
  { key = "9", name = "Everything (kept files, no auto-run)", run = nil,
    files = KEEP_ALL },
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

local function pickFromList(list, opts)
  opts = opts or {}
  local title = opts.title or "== Titan Pastebin Installer =="
  local promptHint = opts.promptHint or "What is this device?"
  local cancelKey = (opts.cancelKey or "q"):lower()
  local backKey = opts.backKey and tostring(opts.backKey):lower() or nil
  while true do
    local idx = 1
    while idx <= #list do
      local _, h = term.getSize()
      term.clear(); term.setCursorPos(1, 1)
      print(title)
      print(promptHint)
      print("")
      local budget = math.max(4, (h or 13) - 6)
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

local function pickRole()
  local stack = { ROLES }
  local titles = { "== Titan Pastebin Install ==" }
  while true do
    local depth = #stack
    local list = stack[depth]
    local role = pickFromList(list, {
      title = titles[depth],
      promptHint = depth == 1 and "What is this device?  (q = Quarry, g = Games)"
        or "Pick an option:",
      backKey = depth > 1 and "b" or nil,
    })
    if role == nil then return nil end
    if role == false then
      if depth > 1 then table.remove(stack); table.remove(titles)
      else return nil end
    elseif role.submenu and SUBMENUS[role.submenu] then
      stack[#stack + 1] = SUBMENUS[role.submenu]
      titles[#titles + 1] = "== " .. tostring(role.name or role.submenu):gsub("%.%.%.$", "") .. " =="
    else
      return role
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
  ["datacenter.lua"] = "ParentCenter",
  ["console.lua"] = "Console",
  ["admin.lua"] = "Admin",
  ["router.lua"] = "Router",
  ["offline_miner.lua"] = "OfflineMiner",
  ["offline_site.lua"] = "QuarrySite",
  ["quarry/workers/offline_miner.lua"] = "OfflineMiner",
  ["quarry/workers/strip_miner.lua"] = "StripMiner",
  ["quarry/managers/offline_site.lua"] = "QuarrySite",
  ["perimeter_sensor.lua"] = "PerimSensor",
  ["perimeter_manager.lua"] = "PerimMgr",
  ["tetris.lua"] = "Tetris",
  ["minesweeper.lua"] = "Minesweeper",
  ["sandstorm.lua"] = "Sandstorm",
  ["luigi_poker.lua"] = "LuigiPoker",
  ["slots.lua"] = "Slots",
  ["games.lua"] = "Games",
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
