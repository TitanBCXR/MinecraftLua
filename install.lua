--[[
  install.lua  -  Titan network installer (CC: Tweaked)
  Titan-Version: 1.2.15

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
local KEEP_ALL = {
  "lib/titan.lua", "datacenter.lua", "console.lua", "admin.lua",
  "router.lua", "router_main.lua", "router_modem.lua",
  "lib/router_hub_net.lua", "lib/router_hub_ui.lua", "lib/router_hub_cmd.lua",
  "quarry/workers/offline_miner.lua", "quarry/workers/strip_miner.lua",
  "quarry/workers/cell_scanner.lua",
  "quarry/managers/offline_site.lua",
  "storage/managers/storage_manager.lua", "storage/workers/storage_builder.lua",
  "storage/managers/storage_atm.lua", "storage/managers/storage_clutch.lua",
  "storage_manager.lua", "storage_builder.lua", "storage_atm.lua", "storage_clutch.lua",
  "offline_miner.lua", "offline_site.lua", "exclude.txt",
  "perimeter_sensor.lua", "perimeter_manager.lua", "tetris.lua", "minesweeper.lua",
  "sandstorm.lua", "luigi_poker.lua", "higher_lower.lua", "slots.lua",
  "lib/casino.lua", "lib/games_economy.lua",
  "games/managers/currency_manager.lua", "currency_manager.lua",
  "games/managers/casino_atm.lua", "casino_atm.lua",
  "games.lua", "games_catalog.lua",
  "host.lua", "versions.lua", "install.lua",
}

local GAMES_SUITE = {
  "games.lua", "games_catalog.lua", "versions.lua", "lib/titan.lua",
  "lib/casino.lua", "lib/games_economy.lua",
  "tetris.lua", "minesweeper.lua", "luigi_poker.lua", "higher_lower.lua", "slots.lua",
}

local GAMES = {
  { key = "0", name = "Games launcher (all + auto-update)", run = "games.lua",
    files = GAMES_SUITE },
  { key = "1", name = "Tetris (pocket / monitor + music)", run = "tetris.lua",
    files = { "lib/titan.lua", "tetris.lua", "versions.lua" } },
  { key = "2", name = "Minesweeper (pocket / monitor)", run = "minesweeper.lua",
    files = { "minesweeper.lua" } },
  { key = "3", name = "Luigi Picture Poker (pocket)", run = "luigi_poker.lua",
    files = { "luigi_poker.lua", "lib/casino.lua" } },
  { key = "4", name = "Higher / Lower Poker", run = "higher_lower.lua",
    files = { "higher_lower.lua", "lib/casino.lua" } },
  { key = "5", name = "Slots (3-reel)", run = "slots.lua",
    files = { "slots.lua", "lib/casino.lua" } },
  { key = "c", name = "Currency Manager (casino ledger)", run = "games/managers/currency_manager.lua",
    files = { "lib/titan.lua", "games/managers/currency_manager.lua", "currency_manager.lua" } },
  { key = "a", name = "Casino ATM (deposit / Create ticker withdraw)", run = "games/managers/casino_atm.lua",
    files = { "lib/titan.lua", "games/managers/casino_atm.lua", "casino_atm.lua" } },
}

local QUARRY_WORKERS = {
  { key = "1", name = "Cell quarry miner", run = "quarry/workers/offline_miner.lua",
    files = { "lib/titan.lua", "quarry/workers/offline_miner.lua", "offline_miner.lua", "exclude.txt" } },
  { key = "2", name = "Strip miner (branch tunnels)", run = "quarry/workers/strip_miner.lua",
    files = { "lib/titan.lua", "quarry/workers/strip_miner.lua", "exclude.txt" } },
  { key = "3", name = "Cell scanner (place geo / map cells)", run = "quarry/workers/cell_scanner.lua",
    files = { "lib/titan.lua", "quarry/workers/cell_scanner.lua" } },
}

local QUARRY_MANAGERS = {
  { key = "1", name = "Site board (cell fleet + geo)", run = "quarry/managers/offline_site.lua",
    files = { "lib/titan.lua", "quarry/managers/offline_site.lua", "offline_site.lua" } },
}

local QUARRY = {
  { key = "w", name = "Workers...", submenu = "quarry_workers" },
  { key = "m", name = "Managers...", submenu = "quarry_managers" },
}

local STORAGE_WORKERS = {
  { key = "1", name = "Storage builder turtle", run = "storage/workers/storage_builder.lua",
    files = { "lib/titan.lua", "storage/workers/storage_builder.lua", "storage_builder.lua" } },
}

local STORAGE_MANAGERS = {
  { key = "1", name = "Storage Manager (vault + I/O)", run = "storage/managers/storage_manager.lua",
    files = { "lib/titan.lua", "storage/managers/storage_manager.lua", "storage_manager.lua" } },
  { key = "2", name = "Storage ATM (modem ↔ vault)", run = "storage/managers/storage_atm.lua",
    files = { "storage/managers/storage_atm.lua", "storage_atm.lua" } },
  { key = "3", name = "Storage Clutch (fill → redstone)", run = "storage/managers/storage_clutch.lua",
    files = { "storage/managers/storage_clutch.lua", "storage_clutch.lua" } },
}

local STORAGE = {
  { key = "w", name = "Workers...", submenu = "storage_workers" },
  { key = "m", name = "Managers...", submenu = "storage_managers" },
}

local SUBMENUS = {
  games = GAMES,
  quarry = QUARRY,
  quarry_workers = QUARRY_WORKERS,
  quarry_managers = QUARRY_MANAGERS,
  storage = STORAGE,
  storage_workers = STORAGE_WORKERS,
  storage_managers = STORAGE_MANAGERS,
}

local ROLES = {
  { key = "1", name = "Parent Center (data center)",       run = "datacenter.lua",
    files = { "lib/titan.lua", "datacenter.lua" } },
  { key = "2", name = "Terminal console (basic commands)",  run = "console.lua",
    files = { "lib/titan.lua", "console.lua" } },
  { key = "3", name = "Admin tablet (pocket console)",      run = "admin.lua",
    files = { "lib/titan.lua", "admin.lua" } },
  { key = "4", name = "Network router (repeater + GPS)",    run = "router.lua",
    files = { "lib/titan.lua", "router.lua", "router_main.lua", "router_modem.lua",
              "lib/router_hub_net.lua", "lib/router_hub_ui.lua", "lib/router_hub_cmd.lua",
              "versions.lua" } },
  { key = "q", name = "Quarry (workers & managers)...", submenu = "quarry" },
  { key = "s", name = "Storage (workers & managers)...", submenu = "storage" },
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

local function pickFromList(list, opts)
  opts = opts or {}
  local promptHint = opts.promptHint or "What is this device?"
  local cancelKey = (opts.cancelKey or "exit"):lower()
  local backKey = opts.backKey and tostring(opts.backKey):lower() or nil
  local clearFirst = opts.clearFirst
  while true do
    local idx = 1
    while idx <= #list do
      local _, h = term.getSize()
      if clearFirst then term.clear(); term.setCursorPos(1, 1) end
      if opts.title then print(opts.title) end
      print("")
      print(promptHint)
      local budget = math.max(4, (h or 13) - 6)
      local shown = 0
      local start = idx
      while idx <= #list and shown < budget do
        local r = list[idx]
        print("  " .. r.key .. ") " .. r.name)
        idx = idx + 1
        shown = shown + 1
      end
      local qHint = backKey and ("B back, exit quit") or "exit quit"
      if idx <= #list then
        write("Enter #, or Enter=more (" .. qHint .. "): ")
      else
        write("Choose (" .. qHint .. "): ")
      end
      local choice = tostring(read() or ""):lower()
      if choice == cancelKey or choice == "quit" then return nil end
      if backKey and choice == backKey then return false end
      if choice ~= "" then
        for _, r in ipairs(list) do
          if tostring(r.key):lower() == choice then return r end
        end
        print("Invalid choice.")
        idx = start
      elseif idx > #list then
        idx = 1
      end
    end
  end
end

local function pickRole()
  local stack = { ROLES }
  local titles = { "== Titan Install ==" }
  while true do
    local depth = #stack
    local list = stack[depth]
    local role = pickFromList(list, {
      title = titles[depth],
      promptHint = depth == 1 and "What is this device?  (q = Quarry, s = Storage, g = Games)"
        or "Pick an option:",
      backKey = depth > 1 and "b" or nil,
      clearFirst = true,
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
do
  local man = {
    source = "host", role = role.name, run = role.run, files = files, version = sysVer,
  }
  -- Tetris tablets: never store a GitHub/wget URL; boot OTA is host-only.
  if role.run == "tetris.lua" then
    man.hostOnly = true
  end
  writeFile(".titan-install", textutils.serialize(man))
end

-- Give this device a role-based label if it doesn't have one yet.
local LABELS = {
  ["datacenter.lua"] = "ParentCenter",
  ["console.lua"] = "Console",
  ["admin.lua"] = "Admin",
  ["router.lua"] = "Router",
  ["offline_miner.lua"] = "OfflineMiner",
  ["offline_site.lua"]  = "QuarrySite",
  ["quarry/workers/offline_miner.lua"] = "OfflineMiner",
  ["quarry/workers/strip_miner.lua"] = "StripMiner",
  ["quarry/workers/cell_scanner.lua"] = "CellScanner",
  ["quarry/managers/offline_site.lua"] = "QuarrySite",
  ["storage/managers/storage_manager.lua"] = "StorageManager",
  ["storage/managers/storage_atm.lua"] = "StorageATM",
  ["storage_atm.lua"] = "StorageATM",
  ["storage/managers/storage_clutch.lua"] = "StorageClutch",
  ["storage_clutch.lua"] = "StorageClutch",
  ["storage/workers/storage_builder.lua"] = "StorageBuilder",
  ["perimeter_sensor.lua"] = "PerimSensor",
  ["perimeter_manager.lua"] = "PerimMgr",
  ["tetris.lua"] = "Tetris",
  ["minesweeper.lua"] = "Mines",
  ["sandstorm.lua"] = "Sandstorm",
  ["luigi_poker.lua"] = "LuigiPoker",
  ["higher_lower.lua"] = "HigherLower",
  ["slots.lua"] = "Slots",
  ["games/managers/currency_manager.lua"] = "Casino",
  ["currency_manager.lua"] = "Casino",
  ["games/managers/casino_atm.lua"] = "ATM",
  ["casino_atm.lua"] = "ATM",
  ["games.lua"] = "Games",
  ["host.lua"] = "TitanHost",
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
