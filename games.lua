--[[
  games.lua  -  Titan Games Launcher (CC: Tweaked)
  Titan-Version: 1.0.9

  Run:

      games

  Installs / updates every game from the GitHub catalog (`games_catalog.lua`),
  auto-adds newly published games, removes games dropped from the catalog,
  and launches them from a tap-friendly menu.

  First run: choose Managed (in-game casino currency) or Unmanaged (granted
  local chips). Settings (S): speaker/modem + economy reminder.

  Controls:
    Tap / Enter  play   U update   S settings   Q quit
]]

local RAW_FALLBACK = "https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/"
local CAT_FILE = "games_catalog.lua"
local VER_FILE = "versions.lua"
local STATE_FILE = "games_launcher.cfg"
local PREFER_MODEM = false -- false = speaker-only launch

local econ = nil
if fs.exists("lib/games_economy.lua") then
  local ok, e = pcall(dofile, "lib/games_economy.lua")
  if ok then econ = e; econ.load() end
end

-- Never delete these when pruning removed catalog games.
local PROTECTED = {
  ["games.lua"] = true,
  ["games_catalog.lua"] = true,
  ["versions.lua"] = true,
  ["games_install.lua"] = true,
  ["lib/titan.lua"] = true,
  ["lib/casino.lua"] = true,
  ["lib/games_economy.lua"] = true,
  ["games_economy.cfg"] = true,
  ["games_wallet.cfg"] = true,
  ["startup.lua"] = true,
  [STATE_FILE] = true,
}

local NATIVE = term.current()
local USING_MONITOR = false
local STATUS = "Ready"
local LAST_SYNC = 0
local MANAGED_FILES = {} -- path -> true (files last installed from catalog games)
local MANAGED_IDS = {}   -- game id -> true

--------------------------------------------------------------------------------
-- Display helpers
--------------------------------------------------------------------------------
local function isColor()
  local ok, c = pcall(function() return term.isColor and term.isColor() end)
  return ok and c == true
end

local function attachMonitor()
  if pocket then return false end
  local m = peripheral.find("monitor")
  if not m then return false end
  local okColor, col = pcall(function() return m.isColor and m.isColor() end)
  if not (okColor and col) then return false end
  pcall(function()
    if m.setTextScale then
      m.setTextScale(1)
      local w, h = m.getSize()
      if w < 26 or h < 14 then m.setTextScale(0.5) end
    end
    if m.setBackgroundColor then m.setBackgroundColor(colors.black) end
    m.clear()
  end)
  term.redirect(m)
  USING_MONITOR = true
  pcall(function()
    NATIVE.setBackgroundColor(colors.black)
    NATIVE.clear()
    NATIVE.setCursorPos(1, 1)
    if NATIVE.setTextColor then NATIVE.setTextColor(colors.lightGray) end
    NATIVE.write("Games launcher on monitor")
  end)
  return true
end

local function detachMonitor()
  if USING_MONITOR then
    pcall(term.redirect, NATIVE)
    USING_MONITOR = false
  end
end

local function pullEv()
  local ev, p1, p2, p3 = os.pullEvent()
  if ev == "monitor_touch" then return "mouse_click", 1, p2, p3 end
  if ev == "monitor_resize" then return "term_resize" end
  return ev, p1, p2, p3
end

local function hasModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then return true end
  end
  return false
end

local function fill(x, y, w, h, bg)
  if term.setBackgroundColor then term.setBackgroundColor(bg or colors.black) end
  for row = y, y + h - 1 do
    term.setCursorPos(x, row)
    term.write((" "):rep(math.max(0, w)))
  end
end

local function textAt(x, y, s, fg, bg)
  if term.setBackgroundColor then term.setBackgroundColor(bg or colors.black) end
  if term.setTextColor then term.setTextColor(fg or colors.white) end
  term.setCursorPos(x, y)
  term.write(tostring(s or ""))
end

--------------------------------------------------------------------------------
-- Config / versions
--------------------------------------------------------------------------------
local function loadState()
  if not fs.exists(STATE_FILE) then return end
  local f = fs.open(STATE_FILE, "r")
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return end
  LAST_SYNC = tonumber(d.lastSync) or 0
  PREFER_MODEM = d.preferModem == true
  MANAGED_FILES = {}
  if type(d.managedFiles) == "table" then
    for _, p in ipairs(d.managedFiles) do
      if type(p) == "string" then MANAGED_FILES[p] = true end
    end
    -- also allow map form
    for k, v in pairs(d.managedFiles) do
      if type(k) == "string" and v == true then MANAGED_FILES[k] = true end
    end
  end
  MANAGED_IDS = {}
  if type(d.managedIds) == "table" then
    for _, id in ipairs(d.managedIds) do
      if type(id) == "string" then MANAGED_IDS[id] = true end
    end
    for k, v in pairs(d.managedIds) do
      if type(k) == "string" and v == true then MANAGED_IDS[k] = true end
    end
  end
end

local function saveState()
  local files, ids = {}, {}
  for p in pairs(MANAGED_FILES) do files[#files + 1] = p end
  table.sort(files)
  for id in pairs(MANAGED_IDS) do ids[#ids + 1] = id end
  table.sort(ids)
  local f = fs.open(STATE_FILE, "w")
  f.write(textutils.serialize({
    lastSync = LAST_SYNC,
    managedFiles = files,
    managedIds = ids,
    preferModem = PREFER_MODEM == true,
  }))
  f.close()
end

local function drainEvents(secs)
  local t = os.startTimer(secs or 0.08)
  while true do
    local ev, p1 = os.pullEvent()
    if ev == "timer" and p1 == t then return end
  end
end

local function catalogGameFiles(catalog)
  local files, ids = {}, {}
  if not catalog or type(catalog.games) ~= "table" then return files, ids end
  for _, g in ipairs(catalog.games) do
    if type(g.id) == "string" then ids[g.id] = true end
    if type(g.run) == "string" then files[g.run] = true end
    for _, p in ipairs(g.files or {}) do
      if type(p) == "string" then files[p] = true end
    end
  end
  return files, ids
end

-- Delete game files that were managed / in the old catalog but not in the new one.
local function pruneRemovedGames(oldCat, newCat, onStatus)
  onStatus = onStatus or function() end
  local oldFiles, oldIds = catalogGameFiles(oldCat)
  local newFiles, newIds = catalogGameFiles(newCat)
  -- Include previously managed set (covers mid-upgrade cases).
  for p in pairs(MANAGED_FILES) do oldFiles[p] = true end
  for id in pairs(MANAGED_IDS) do oldIds[id] = true end

  local removed = 0
  for path in pairs(oldFiles) do
    if not newFiles[path] and not PROTECTED[path] then
      if fs.exists(path) and not fs.isDir(path) then
        onStatus("Removing " .. path)
        pcall(fs.delete, path)
        removed = removed + 1
      end
      MANAGED_FILES[path] = nil
    end
  end
  for id in pairs(oldIds) do
    if not newIds[id] then MANAGED_IDS[id] = nil end
  end
  -- Refresh managed set to match new catalog game files only.
  MANAGED_FILES, MANAGED_IDS = newFiles, newIds
  return removed
end

local function loadLocalVersions()
  if not fs.exists(VER_FILE) then return { packages = {} } end
  local ok, cat = pcall(dofile, VER_FILE)
  if ok and type(cat) == "table" then return cat end
  return { packages = {} }
end

local function loadLocalCatalog()
  if not fs.exists(CAT_FILE) then return nil end
  local ok, cat = pcall(dofile, CAT_FILE)
  if ok and type(cat) == "table" and type(cat.games) == "table" then return cat end
  return nil
end

local function cmpVer(a, b)
  a, b = tostring(a or "0"), tostring(b or "0")
  local function parts(v)
    local t = {}
    for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) or 0 end
    if #t == 0 then t[1] = 0 end
    return t
  end
  local pa, pb = parts(a), parts(b)
  local n = math.max(#pa, #pb)
  for i = 1, n do
    local x, y = pa[i] or 0, pb[i] or 0
    if x < y then return -1 end
    if x > y then return 1 end
  end
  return 0
end

--------------------------------------------------------------------------------
-- HTTP sync
--------------------------------------------------------------------------------
local function httpGet(url)
  if not http then return nil, "http disabled" end
  local h, err = http.get(url)
  if not h then return nil, err or "request failed" end
  local code = h.getResponseCode and h.getResponseCode() or 200
  local data = h.readAll()
  h.close()
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
  if not data or data == "" then return nil, "empty" end
  return data
end

local function writeFile(path, data)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  f.write(data)
  f.close()
end

local function loadStringTable(src, name)
  local loader, err = load(src, "@" .. (name or "chunk"), "t", {})
  if not loader then return nil, err end
  local ok, cat = pcall(loader)
  if not ok then return nil, cat end
  if type(cat) ~= "table" then return nil, "not a table" end
  return cat
end

local function rawBase(catalog)
  local base = (catalog and catalog.base) or RAW_FALLBACK
  if base:sub(-1) ~= "/" then base = base .. "/" end
  return base
end

local function fetchCatalog(base, save)
  local data, err = httpGet(base .. CAT_FILE .. "?cb=" .. os.epoch("utc"))
  if not data then return nil, err end
  local cat, cerr = loadStringTable(data, CAT_FILE)
  if not cat then return nil, cerr end
  if type(cat.games) ~= "table" then return nil, "bad catalog" end
  if save ~= false then writeFile(CAT_FILE, data) end
  return cat, data
end

local function fetchVersions(base, save)
  local data, err = httpGet(base .. VER_FILE .. "?cb=" .. os.epoch("utc"))
  if not data then return nil, err end
  local cat, cerr = loadStringTable(data, VER_FILE)
  if not cat then return nil, cerr end
  if save ~= false then writeFile(VER_FILE, data) end
  return cat, data
end

local function needFile(path, remoteVers, localVers)
  if not fs.exists(path) then return true, "missing" end
  local rv = remoteVers and remoteVers.packages and remoteVers.packages[path]
  local lv = localVers and localVers.packages and localVers.packages[path]
  if rv and (not lv or cmpVer(lv, rv) < 0) then return true, "update" end
  return false
end

local function downloadPath(base, path)
  local data, err = httpGet(base .. path .. "?cb=" .. os.epoch("utc"))
  if not data then return false, err end
  writeFile(path, data)
  return true
end

-- Sync launcher + every catalog game. Returns stats table.
local function syncAll(onStatus)
  onStatus = onStatus or function() end
  local localCat = loadLocalCatalog()
  local base = rawBase(localCat)
  onStatus("Fetching catalog…")
  local remoteCat, catData = fetchCatalog(base, false)
  if not remoteCat then
    if localCat then
      onStatus("Offline — using cached catalog")
      return { ok = true, offline = true, added = 0, updated = 0, removed = 0, failed = 0 }, localCat, loadLocalVersions()
    end
    return { ok = false, err = catData or "no catalog" }, nil, nil
  end
  base = rawBase(remoteCat)

  -- Drop games removed from the remote catalog (files + menu via new catalog).
  onStatus("Pruning removed games…")
  local removed = pruneRemovedGames(localCat, remoteCat, onStatus)

  if catData then writeFile(CAT_FILE, catData) end

  onStatus("Fetching versions…")
  local localVers = loadLocalVersions()
  local remoteVers, verData = fetchVersions(base, false)
  if not remoteVers then remoteVers = localVers end

  local updated, added, failed = 0, 0, 0
  local seen = {}

  local function syncPath(path)
    if seen[path] then return end
    seen[path] = true
    -- Never rewrite versions mid-pass via needFile side effects.
    if path == VER_FILE then return end
    local need, why = needFile(path, remoteVers, localVers)
    if not need then return end
    onStatus((why == "missing" and "New " or "Updating ") .. path)
    local ok = downloadPath(base, path)
    if ok then
      if why == "missing" then added = added + 1 else updated = updated + 1 end
      localVers.packages = localVers.packages or {}
      if remoteVers.packages and remoteVers.packages[path] then
        localVers.packages[path] = remoteVers.packages[path]
      end
    else
      failed = failed + 1
    end
  end

  -- Launcher bits first (so next boot has new catalog logic).
  local launchFiles = (remoteCat.launcher and remoteCat.launcher.files)
    or { "games.lua", "games_catalog.lua", "versions.lua" }
  for _, path in ipairs(launchFiles) do syncPath(path) end

  for _, g in ipairs(remoteCat.games) do
    for _, path in ipairs(g.files or { g.run }) do
      syncPath(path)
    end
  end

  -- Track current catalog game files for the next prune.
  MANAGED_FILES, MANAGED_IDS = catalogGameFiles(remoteCat)

  if verData then writeFile(VER_FILE, verData) end

  LAST_SYNC = os.epoch("utc")
  saveState()
  onStatus(("Sync +%d new %d upd -%d rem %d fail"):format(added, updated, removed, failed))
  remoteCat = loadLocalCatalog() or remoteCat
  return {
    ok = true,
    added = added,
    updated = updated,
    removed = removed,
    failed = failed,
  }, remoteCat, loadLocalVersions()
end

local function gameStatus(game, localVers, remoteVers)
  if not fs.exists(game.run) then return "NEW", colors.orange end
  local stale = false
  for _, path in ipairs(game.files or { game.run }) do
    if needFile(path, remoteVers, localVers) then stale = true; break end
  end
  if stale then return "UPD", colors.yellow end
  return "OK", colors.lime
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
local TILE = {
  tetris = colors.magenta,
  minesweeper = colors.lightGray,
  luigi_poker = colors.lime,
  higher_lower = colors.cyan,
  slots = colors.purple,
}

local function drawMenu(state)
  local tw, th = term.getSize()
  local color = isColor()
  fill(1, 1, tw, th, colors.black)
  fill(1, 1, tw, 1, color and colors.blue or colors.gray)
  textAt(2, 1, " TITAN GAMES ", colors.white, color and colors.blue or colors.gray)
  textAt(math.max(2, tw - 8), 1, "U=upd", colors.yellow, color and colors.blue or colors.gray)

  textAt(2, 2, STATUS:sub(1, tw - 2), colors.lightGray, colors.black)

  local games = state.catalog and state.catalog.games or {}
  -- On-screen UP/DOWN only on monitor setups; pockets use tap / keys / scroll.
  local showNav = USING_MONITOR == true
  local headerH = 3
  local footerH = showNav and 3 or 1
  local tileH = (th < 14) and 2 or 3
  local gap = 1
  local usable = th - headerH - footerH
  local rows = math.max(1, math.floor((usable + gap) / (tileH + gap)))
  local cols = (tw >= 30) and 2 or 1
  local page = rows * cols
  local tileW = math.floor((tw - (cols + 1)) / cols)

  if state.sel < 1 then state.sel = 1 end
  if state.sel > #games and #games > 0 then state.sel = #games end
  if state.sel <= state.scroll then state.scroll = math.max(0, state.sel - 1) end
  if state.sel > state.scroll + page then state.scroll = state.sel - page end
  local maxScroll = math.max(0, #games - page)
  if state.scroll > maxScroll then state.scroll = maxScroll end
  if state.scroll < 0 then state.scroll = 0 end

  state.page = page
  state.tileH = tileH
  state.tileW = tileW
  state.cols = cols
  state.headerH = headerH
  state.rects = {}
  state.upBtn, state.dnBtn = nil, nil

  for i = 1, #games do
    local localIdx = i - state.scroll
    if localIdx >= 1 then
      local row = math.floor((localIdx - 1) / cols)
      local col = (localIdx - 1) % cols
      if row < rows then
        local x = 2 + col * (tileW + 1)
        local y = headerH + 1 + row * (tileH + gap)
        local g = games[i]
        local bg = TILE[g.id] or colors.gray
        local tag, tagC = gameStatus(g, state.localVers, state.remoteVers)
        if i == state.sel then
          fill(x - 1, y, tileW + 2, tileH, colors.white)
        end
        fill(x, y, tileW, tileH, bg)
        textAt(x + 1, y, tostring(i), colors.yellow, bg)
        textAt(x + 3, y, tag, tagC, bg)
        textAt(x + 1, y + 1, tostring(g.name or g.run):sub(1, tileW - 2), colors.white, bg)
        if tileH >= 3 and g.desc then
          textAt(x + 1, y + 2, tostring(g.desc):sub(1, tileW - 2), colors.lightGray, bg)
        end
        state.rects[i] = { x = x, y = y, w = tileW, h = tileH }
      end
    end
  end

  if #games == 0 then
    textAt(2, 5, "No games yet — press U to sync", colors.orange, colors.black)
  end

  if showNav then
    local footY = th - footerH + 1
    local half = math.floor(tw / 2)
    state.upBtn = { x = 1, y = footY, w = half, h = footerH }
    state.dnBtn = { x = half + 1, y = footY, w = tw - half, h = footerH }
    local canUp = state.scroll > 0
    local canDn = state.scroll + page < #games
    fill(1, footY, half, footerH, canUp and colors.cyan or colors.gray)
    fill(half + 1, footY, tw - half, footerH, canDn and colors.cyan or colors.gray)
    textAt(2, footY + math.floor((footerH - 1) / 2), " UP ", colors.white, canUp and colors.cyan or colors.gray)
    textAt(half + 2, footY + math.floor((footerH - 1) / 2), " DOWN ", colors.white, canDn and colors.cyan or colors.gray)
  else
    -- Slim pocket footer hint (no nav buttons).
    fill(1, th, tw, 1, colors.gray)
    local mode = PREFER_MODEM and "modem" or "spk"
    textAt(2, th, ("Tap  U upd  S set(%s)  Q"):format(mode):sub(1, tw - 2),
      colors.white, colors.gray)
  end
end

local function inRect(mx, my, r)
  return r and mx >= r.x and mx <= r.x + r.w - 1 and my >= r.y and my <= r.y + r.h - 1
end

local function runEconomySetup()
  if not econ then return end
  while true do
    local tw, th = term.getSize()
    local color = isColor()
    fill(1, 1, tw, th, colors.black)
    fill(1, 1, tw, 1, color and colors.purple or colors.gray)
    textAt(2, 1, " ECONOMY SETUP ", colors.white, color and colors.purple or colors.gray)
    textAt(2, 3, "Is this a managed casino?", colors.white, colors.black)
    textAt(2, 5, "MANAGED", colors.lime, colors.black)
    textAt(2, 6, " In-game items via Currency", colors.lightGray, colors.black)
    textAt(2, 7, " Manager (mesh + password).", colors.lightGray, colors.black)
    textAt(2, 9, "UNMANAGED", colors.yellow, colors.black)
    textAt(2, 10, (" Local chips — grant %d"):format(econ.DEFAULT_GRANT or 10000),
      colors.lightGray, colors.black)
    textAt(2, 11, " once. Bet only what you have.", colors.lightGray, colors.black)
    local by = th - 3
    local half = math.floor(tw / 2)
    local mBtn = { x = 1, y = by, w = half, h = 3 }
    local uBtn = { x = half + 1, y = by, w = tw - half, h = 3 }
    fill(1, by, half, 3, color and colors.lime or colors.white)
    fill(half + 1, by, tw - half, 3, color and colors.orange or colors.gray)
    textAt(2, by + 1, " MANAGED ", colors.black, color and colors.lime or colors.white)
    textAt(half + 2, by + 1, " UNMANAGED ", colors.black, color and colors.orange or colors.gray)

    local ev, p1, p2, p3 = pullEv()
    if ev == "key" then
      if p1 == keys.one or p1 == keys.m then
        econ.setMode("managed")
        PREFER_MODEM = true
        saveState()
        STATUS = "Managed casino"
        return
      elseif p1 == keys.two or p1 == keys.u then
        econ.setMode("unmanaged")
        PREFER_MODEM = hasModem()
        saveState()
        STATUS = ("Unmanaged +%d chips"):format(econ.grant or 10000)
        return
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "1" or ch == "m" then
        econ.setMode("managed"); PREFER_MODEM = true; saveState()
        STATUS = "Managed casino"; return
      elseif ch == "2" or ch == "u" then
        econ.setMode("unmanaged"); PREFER_MODEM = hasModem(); saveState()
        STATUS = ("Unmanaged +%d chips"):format(econ.grant or 10000); return
      end
    elseif ev == "mouse_click" then
      if inRect(p2, p3, mBtn) then
        econ.setMode("managed"); PREFER_MODEM = true; saveState()
        STATUS = "Managed casino"; return
      elseif inRect(p2, p3, uBtn) then
        econ.setMode("unmanaged"); PREFER_MODEM = hasModem(); saveState()
        STATUS = ("Unmanaged +%d chips"):format(econ.grant or 10000); return
      end
    end
  end
end

local function runSettings()
  if econ then econ.load() end
  while true do
    local tw, th = term.getSize()
    local color = isColor()
    fill(1, 1, tw, th, colors.black)
    fill(1, 1, tw, 1, color and colors.orange or colors.gray)
    textAt(2, 1, " SETTINGS ", colors.white, color and colors.orange or colors.gray)
    textAt(2, 3, "Launch / mesh:", colors.white, colors.black)
    local modeLine = PREFER_MODEM
      and "Modem + global LB / casino"
      or "Speaker music (Tetris still syncs host LB when modem equipped)"
    textAt(2, 4, modeLine:sub(1, tw - 2),
      PREFER_MODEM and colors.lime or colors.yellow, colors.black)
    local econLine = "(economy not set)"
    if econ and econ.setupDone then
      econLine = econ.isManaged() and "Economy: MANAGED (in-game)"
        or ("Economy: UNMANAGED (%d chips)"):format(econ.getCoins() or econ.grant or 0)
    end
    textAt(2, 6, econLine:sub(1, tw - 2), colors.lightGray, colors.black)
    textAt(2, 8, "Space  toggle modem/speaker", colors.white, colors.black)
    textAt(2, 9, "E      re-run economy setup", colors.white, colors.black)
    textAt(2, 10, "Q      back", colors.white, colors.black)
    local by = th - 2
    local third = math.floor(tw / 3)
    local tog = { x = 1, y = by, w = third, h = 2 }
    local eco = { x = third + 1, y = by, w = third, h = 2 }
    local back = { x = 2 * third + 1, y = by, w = tw - 2 * third, h = 2 }
    fill(1, by, third, 2, color and colors.lime or colors.white)
    fill(third + 1, by, third, 2, color and colors.purple or colors.gray)
    fill(2 * third + 1, by, tw - 2 * third, 2, color and colors.red or colors.gray)
    textAt(2, by, " MESH ", colors.black, color and colors.lime or colors.white)
    textAt(third + 2, by, " ECON ", colors.white, color and colors.purple or colors.gray)
    textAt(2 * third + 2, by, " BACK ", colors.white, color and colors.red or colors.gray)

    local ev, p1, p2, p3 = pullEv()
    if ev == "key" then
      if p1 == keys.q or p1 == keys.backspace then return
      elseif p1 == keys.space or p1 == keys.enter then
        PREFER_MODEM = not PREFER_MODEM
        saveState()
      elseif p1 == keys.e then
        runEconomySetup()
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "q" then return
      elseif ch == " " or ch == "t" then
        PREFER_MODEM = not PREFER_MODEM
        saveState()
      elseif ch == "e" then
        runEconomySetup()
      end
    elseif ev == "mouse_click" then
      if inRect(p2, p3, tog) then
        PREFER_MODEM = not PREFER_MODEM
        saveState()
      elseif inRect(p2, p3, eco) then
        runEconomySetup()
      elseif inRect(p2, p3, back) then
        return
      end
    elseif ev == "terminate" then
      return
    end
  end
end

local function launchGame(game)
  if not game or not game.run then return end
  if not fs.exists(game.run) then
    STATUS = "Missing " .. game.run .. " — press U"
    return
  end
  if econ then econ.load() end
  detachMonitor()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("Starting " .. (game.name or game.run) .. "…")
  local econFlag = nil
  if econ and econ.isManaged() then
    econFlag = "--managed"
    print("(managed — casino currency)")
  elseif econ and econ.isUnmanaged() then
    econFlag = "--unmanaged"
    print("(unmanaged — local chip wallet)")
  end
  local isTetris = game.id == "tetris"
  local modemHere = hasModem()
  -- Tetris always prefers install-host LB when a modem is available.
  local useModem = isTetris and modemHere
    or PREFER_MODEM or (econ and econ.isManaged())
  if isTetris and modemHere then
    print("(host leaderboard sync at boot)")
  elseif useModem then
    print("(modem mode — Close returns here)")
  else
    print("(speaker mode — Close returns here)")
  end
  sleep(0.2)
  drainEvents(0.05)
  local args = { "--launcher" }
  if econFlag then args[#args + 1] = econFlag end
  -- Other games: speaker-only launch when mesh is off. Tetris never gets
  -- --speaker from the launcher — it auto-detects music + host LB separately.
  if not useModem and not isTetris then
    table.insert(args, 1, "--speaker")
  end
  shell.run(game.run, table.unpack(args))
  drainEvents(0.12)
  attachMonitor()
  STATUS = "Back from " .. (game.name or game.run)
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------
local function main()
  if not http then
    printError("HTTP is disabled. Enable it in the CC: Tweaked config.")
    return
  end

  loadState()
  attachMonitor()
  if econ then
    econ.load()
    if not econ.setupDone then
      runEconomySetup()
    end
  end

  local state = {
    catalog = loadLocalCatalog(),
    localVers = loadLocalVersions(),
    remoteVers = loadLocalVersions(),
    sel = 1,
    scroll = 0,
    rects = {},
  }

  local function doSync()
    STATUS = "Updating…"
    drawMenu(state)
    local stats, cat, vers = syncAll(function(msg)
      STATUS = msg
      drawMenu(state)
    end)
    if cat then state.catalog = cat end
    if vers then
      state.localVers = vers
      state.remoteVers = vers
    end
    -- Re-read remote vers snapshot for badges (best-effort from disk after sync)
    state.remoteVers = loadLocalVersions()
    state.localVers = loadLocalVersions()
    if not stats.ok then
      STATUS = "Sync failed: " .. tostring(stats.err)
    elseif stats.offline then
      STATUS = "Offline — cached games"
    else
      STATUS = ("Ready  +%d  ~%d  -%d"):format(
        stats.added or 0, stats.updated or 0, stats.removed or 0)
    end
  end

  -- Auto-sync on launch (or if never synced / catalog missing).
  local need = (not state.catalog) or (os.epoch("utc") - LAST_SYNC > 6 * 60 * 60 * 1000)
  if need then
    doSync()
  else
    STATUS = "Ready  (U = check updates)"
  end

  while true do
    drawMenu(state)
    local games = state.catalog and state.catalog.games or {}
    local ev, p1, p2, p3 = pullEv()
    if ev == "term_resize" then
      -- redraw
    elseif ev == "key" then
      local K = keys
      if p1 == K.up then
        state.sel = state.sel > 1 and state.sel - 1 or math.max(1, #games)
      elseif p1 == K.down then
        state.sel = state.sel < #games and state.sel + 1 or 1
      elseif p1 == K.enter or p1 == K.space then
        if games[state.sel] then launchGame(games[state.sel]) end
      elseif p1 == K.u then
        doSync()
      elseif p1 == K.s then
        runSettings()
        STATUS = PREFER_MODEM and "Modem mode on" or "Speaker mode on"
      elseif p1 == K.q then
        return
      elseif p1 == K.pageUp then
        state.sel = math.max(1, state.sel - (state.page or 1))
        state.scroll = math.max(0, state.scroll - (state.page or 1))
      elseif p1 == K.pageDown then
        state.sel = math.min(#games, state.sel + (state.page or 1))
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "q" then return
      elseif ch == "u" then doSync()
      elseif ch == "s" then
        runSettings()
        STATUS = PREFER_MODEM and "Modem mode on" or "Speaker mode on"
      elseif tonumber(ch) and games[tonumber(ch)] then
        launchGame(games[tonumber(ch)])
      end
    elseif ev == "mouse_click" then
      local mx, my = p2, p3
      if inRect(mx, my, state.upBtn) then
        state.scroll = math.max(0, state.scroll - (state.page or 1))
        state.sel = math.max(1, state.sel - (state.page or 1))
      elseif inRect(mx, my, state.dnBtn) then
        local maxScroll = math.max(0, #games - (state.page or 1))
        state.scroll = math.min(maxScroll, state.scroll + (state.page or 1))
        state.sel = math.min(#games, state.sel + (state.page or 1))
      else
        for i, r in pairs(state.rects) do
          if inRect(mx, my, r) then
            state.sel = i
            launchGame(games[i])
            break
          end
        end
      end
    elseif ev == "mouse_scroll" then
      if p1 < 0 then state.sel = math.max(1, state.sel - 1)
      elseif p1 > 0 then state.sel = math.min(#games, state.sel + 1) end
    elseif ev == "terminate" then
      return
    end
  end
end

local ok, err = pcall(main)
detachMonitor()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok then error(err, 0) end
