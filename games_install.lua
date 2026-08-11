--[[
  games_install.lua  -  Titan Games suite installer (CC: Tweaked)
  Titan-Version: 1.0.4

  Games only — not the fleet / router installer.

  On a pocket or computer with HTTP:

      wget run https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/games_install.lua

  Installs the Games launcher + catalog + every game, then can launch `games`.
  Updates later: run `games` and press U (HTTP, no modem).
]]

local RAW_BASE = "https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/"

-- Keep in sync with games_catalog.lua / github_install GAMES_SUITE.
local FILES = {
  "games.lua",
  "games_catalog.lua",
  "versions.lua",
  "lib/titan.lua",
  "lib/pocket_peripherals.lua",
  "lib/games_music.lua",
  "tetris.lua",
  "minesweeper.lua",
  "luigi_poker.lua",
  "higher_lower.lua",
  "slots.lua",
  "lib/casino.lua",
  "lib/games_economy.lua",
}

local function fetch(path)
  local url = RAW_BASE .. path .. "?cb=" .. os.epoch("utc")
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

local function askYesNo(q, defaultYes)
  write(q .. (defaultYes and " [Y/n] " or " [y/N] "))
  local yn = tostring(read() or ""):lower()
  if yn == "" then return defaultYes ~= false end
  return yn == "y" or yn == "yes"
end

if not http then
  printError("HTTP is disabled. Enable the http API in the CC: Tweaked config.")
  return
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if term.isColor and term.isColor() then
  term.setBackgroundColor(colors.magenta)
  term.setTextColor(colors.white)
  term.clearLine()
  print(" TITAN GAMES INSTALL ")
  term.setBackgroundColor(colors.black)
else
  print("== Titan Games Install ==")
end
print("Source: " .. RAW_BASE)
print("Pocket mesh + speaker games (modem in inventory for managed/unmanaged).")
print("")

-- Prefer live catalog file list when available (auto-adds new games).
local liveFiles = {}
do
  local data = fetch("games_catalog.lua")
  if data then
    writeFile("games_catalog.lua", data)
    local loader = load(data, "@games_catalog.lua", "t", {})
    local ok, cat = loader and pcall(loader)
    if ok and type(cat) == "table" and type(cat.games) == "table" then
      local seen = {}
      local function add(path)
        if type(path) == "string" and path ~= "" and not seen[path] then
          seen[path] = true
          liveFiles[#liveFiles + 1] = path
        end
      end
      for _, p in ipairs((cat.launcher and cat.launcher.files) or {}) do add(p) end
      add("games.lua")
      add("games_catalog.lua")
      add("versions.lua")
      for _, g in ipairs(cat.games) do
        for _, p in ipairs(g.files or { g.run }) do add(p) end
      end
    end
  end
end

local files = (#liveFiles > 0) and liveFiles or FILES
print("Installing " .. #files .. " file(s)…")
local failed = {}
for _, path in ipairs(files) do
  write("  " .. path .. " ... ")
  local data, err = fetch(path)
  if data then
    writeFile(path, data)
    print("ok")
  else
    print("FAIL (" .. tostring(err) .. ")")
    failed[#failed + 1] = path
  end
end

if #failed > 0 then
  print("")
  print("Failed: " .. table.concat(failed, ", "))
  print("Check that the repo is public and HTTP is allowed.")
  return
end

writeFile(".titan-install", textutils.serialize({
  source = "github",
  role = "Games launcher",
  run = "games.lua",
  files = files,
  base = RAW_BASE,
  gamesSuite = true,
}))

if not os.getComputerLabel() or os.getComputerLabel() == "" then
  os.setComputerLabel("Games-" .. os.getComputerID())
  print("Label: " .. os.getComputerLabel())
end

print("")
print("Games suite installed.")
print("Run:  games")
print("Updates: open launcher, press U")

if askYesNo("Auto-run games on boot?", true) then
  writeFile("startup.lua", 'shell.run("games.lua")\n')
  print("Wrote startup.lua")
end

if askYesNo("Run games launcher now?", true) then
  return shell.run("games.lua")
end

print("Done.")
