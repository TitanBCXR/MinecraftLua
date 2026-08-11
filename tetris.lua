--[[
  tetris.lua  -  Standalone Tetris for CC: Tweaked (pocket / computer)
  Titan-Version: 1.2.9

  Drop on a pocket PC or advanced computer and run:

      tetris
      tetris --launcher          (Games launcher: Close returns to menu)

  Main menu: top-3 leaderboard, Play, Controls (C). Q shuts down (or Close
  back to Games launcher when started with --launcher).
  In-game / Controls screen: Q always returns to the main menu.
  Mid-game Q abandons the run (score is not kept).

  Display: if a monitor is attached, the game draws there. On monitors the
  bottom half is a touch pad (move / rotate / drop / pause / mute / quit) so
  you can close the computer UI and play from the screen. Keys still work on
  the PC. Advanced color monitors / pockets get colored pieces.

  Network: one boot sync (OTA + host leaderboard) then the board is cached
  locally (`tetris_lb.cfg` is cache only — install host is authority) and the
  session goes fully offline — no more rednet calls (avoids pocket crashes
  with speaker music). New scores update the local top-3 and queue for the next
  boot sync. R reloads the local cache only.
  Host LB sync runs whenever a wireless modem is present (direct or router
  mesh), including with a speaker / Noisy pocket. `--no-modem` skips mesh.

  Music (speaker / Noisy pocket): two in-script note tracks — calm menu bed +
  retro Korobeiniki in-game. M mutes. Speaker + modem together: on an advanced
  PC attach both peripherals; on a pocket equip modem for boot sync, then U
  to swap to speaker for music (scores queue locally until next boot sync).

  Player name: uses Advanced Peripherals Player Detector when present; otherwise
  prompts for a name after a game (saved in tetris.cfg). That name is what
  appears on the shared leaderboard.

  Boot: host-only OTA over the titan_router mesh + leaderboard sync + 5s
  Q-disclaimer (run host.lua on your update server; join the router mesh).

  Color pocket: colored pieces. Mono: letter blocks.
]]

local CFG = "tetris.cfg"
local LB_CACHE = "tetris_lb.cfg"
local COLS, ROWS = 10, 18
local KIND = "tetris"
local INSTALL_PROTO = "titan_install"
local ROUTER_PROTO = "titan_router"
local SIDE_W = 5 -- compact HUD column (score uses K/M/B/T)
local LB_TOP = 3 -- only show top 3 on menu
local PLAYER_RANGE = 8

-- --launcher = Close returns to Games menu. --no-modem = skip host LB/OTA.
-- --speaker is legacy (music hint only; does not disable host LB).
local FROM_LAUNCHER = false
local NO_MODEM = false
do
  local argv = { ... }
  for i = 1, #argv do
    local s = tostring(argv[i] or ""):lower()
    if s == "--no-modem" or s == "no-modem" or s == "--offline" or s == "offline" then
      NO_MODEM = true
    elseif s == "--launcher" or s == "launcher" then
      FROM_LAUNCHER = true
    end
    -- --speaker accepted for launcher compat; ignored for mesh.
  end
end

-- Cached host leaderboard (disk + RAM). After boot sync, NET_LOCKED stops all rednet.
local LEADERBOARD = {}
local PENDING_SCORE = nil -- best score waiting for next boot submit
local LB_SYNCED_AT = 0
local NET_LOCKED = false
local PLAYER_NAME = nil -- Minecraft / typed display name for the board

-- Live state for SSH / mesh beacons (updated by the game loop).
local TRACK = {
  playing = false,
  score = 0,
  level = 0,
  lines = 0,
  x = nil, y = nil, z = nil,
  fixAt = 0,
}

local titan = nil
if fs.exists("lib/titan.lua") then
  local ok, lib = pcall(dofile, "lib/titan.lua")
  if ok and type(lib) == "table" then titan = lib end
end

local NATIVE = term.current()
local USING_MONITOR = false

local function isColor()
  local ok, c = pcall(function() return term.isColor and term.isColor() end)
  return ok and c == true
end

local function attachMonitor()
  local m = peripheral.find("monitor")
  if not m then return false end
  pcall(function()
    if m.setTextScale then
      m.setTextScale(1)
      local w, h = m.getSize()
      -- Need room for 18-row board + HUD; shrink scale on small panels.
      if h < 20 or w < 24 then m.setTextScale(0.5) end
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
    NATIVE.write("Tetris on monitor")
    NATIVE.setCursorPos(1, 2)
    NATIVE.write("Close this UI — play")
    NATIVE.setCursorPos(1, 3)
    NATIVE.write("via touch pad below")
  end)
  return true
end

local function detachMonitor()
  if USING_MONITOR then
    pcall(term.redirect, NATIVE)
    USING_MONITOR = false
  end
end

local function pullGameEvent()
  local ev, p1, p2, p3 = os.pullEvent()
  if ev == "monitor_touch" then
    return "mouse_click", 1, p2, p3
  end
  return ev, p1, p2, p3
end

local MUSIC_ON = true -- persisted; M toggles

local function loadCfg()
  local hi, name = 0, nil
  if not fs.exists(CFG) then return hi, name end
  local f = fs.open(CFG, "r")
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) == "table" then
    hi = tonumber(d.hi) or 0
    if type(d.playerName) == "string" and d.playerName:match("%S") then
      name = d.playerName:match("^%s*(.-)%s*$")
    end
    if d.music == false then MUSIC_ON = false end
  end
  return hi, name
end

local function saveCfg()
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize({
    hi = HI,
    playerName = PLAYER_NAME,
    music = MUSIC_ON,
  }))
  f.close()
end

local HI
HI, PLAYER_NAME = loadCfg()

--------------------------------------------------------------------------------
-- Speaker music (Noisy pocket) + modem detection for mesh
--------------------------------------------------------------------------------
local SPEAKER = nil
local musicIdx = 1
local musicBassPulse = 0
local musicTrackName = "menu"
-- Two tiny note-block tracks (no audio files).
local TRACKS = {
  -- Calm menu bed (soft arpeggios — different mood from the game theme).
  menu = {
    beat = 0.20,
    legato = 0.80,
    style = "menu",
    bass = { 4, 4, 4, 4, 2, 2, 2, 2, 0, 0, 0, 0, 4, 4, 7, 7 },
    melody = {
      {9, 2}, {12, 2}, {16, 3}, {12, 2}, {9, 2}, {7, 3},
      {false, 1},
      {7, 2}, {11, 2}, {14, 3}, {11, 2}, {7, 2}, {4, 3},
      {false, 1},
      {4, 2}, {7, 2}, {12, 3}, {9, 2}, {7, 2}, {9, 4},
      {false, 2},
      {12, 2}, {16, 2}, {19, 3}, {16, 2}, {12, 2}, {9, 4},
      {false, 3},
    },
  },
  -- In-game: retro Korobeiniki (public-domain folk melody).
  game = {
    beat = 0.13,
    legato = 0.72,
    style = "game",
    bass = { 4, 4, 2, 2, 0, 0, 4, 4, 7, 7, 4, 4, 0, 0, 4, 4 },
    melody = {
      {16, 2}, {11, 1}, {12, 1}, {14, 2}, {12, 1}, {11, 1},
      {9, 2}, {9, 1}, {12, 1}, {16, 2}, {14, 1}, {12, 1},
      {11, 2}, {11, 1}, {12, 1}, {14, 2}, {16, 2},
      {12, 2}, {9, 2}, {9, 4},
      {false, 2},
      {14, 2}, {17, 1}, {21, 2}, {19, 1}, {17, 1},
      {16, 3}, {12, 1}, {16, 2}, {14, 1}, {12, 1},
      {11, 2}, {11, 1}, {12, 1}, {14, 2}, {16, 2},
      {12, 2}, {9, 2}, {9, 4},
      {false, 4},
    },
  },
}
local LEGACY_MUSIC_FILE = "tetris_lofi.dfpwm"

local function refreshSpeaker()
  SPEAKER = peripheral.find("speaker")
  return SPEAKER ~= nil
end

local function hasModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then return true end
  end
  return false
end

local function meshStatusLine()
  local sp = refreshSpeaker()
  local md = hasModem()
  if NO_MODEM then
    return sp and "local (no modem)" or "local cache"
  end
  if sp and md then return "notes+host LB"
  elseif sp then return "notes (U=modem)"
  elseif md then return "host LB"
  else return "local cache"
  end
end

-- Swap pocket back upgrade (speaker <-> wireless modem in inventory).
-- Select the upgrade slot you want before pressing U for best results.
local function swapPocketUpgrade()
  if not pocket or type(pocket.equipBack) ~= "function" then
    return false, "not a pocket PC"
  end
  local ok, err = pocket.equipBack()
  refreshSpeaker()
  if hasModem() and titan and titan.openModem then
    pcall(titan.openModem)
  end
  return ok, err
end

local function stopMusic()
  -- Only cut audio on pause/mute/exit / track switch — never between notes.
  if SPEAKER then pcall(function() SPEAKER.stop() end) end
end

local function startMusic(trackName)
  trackName = trackName or musicTrackName or "menu"
  if trackName ~= musicTrackName then
    stopMusic()
  end
  musicTrackName = trackName
  musicIdx = 1
  musicBassPulse = 0
  return MUSIC_ON and refreshSpeaker()
end

local function playSoft(instrument, volume, pitch)
  if not SPEAKER then return end
  if pitch == nil or pitch < 0 or pitch > 24 then return end
  pcall(function() SPEAKER.playNote(instrument, volume, pitch) end)
end

local function musicStepSeconds()
  if not MUSIC_ON then return 0.5 end
  if not SPEAKER and not refreshSpeaker() then return 1.0 end
  local tr = TRACKS[musicTrackName] or TRACKS.game
  local melody, bass = tr.melody, tr.bass
  local note = melody[musicIdx] or { false, 1 }
  musicIdx = musicIdx + 1
  if musicIdx > #melody then musicIdx = 1 end
  local pitch, beats = note[1], tonumber(note[2]) or 1

  musicBassPulse = musicBassPulse + 1
  local bassPitch = bass[((musicBassPulse - 1) % #bass) + 1]

  if tr.style == "menu" then
    -- Softer, airier menu bed.
    playSoft("bass", 0.16, bassPitch)
    if pitch ~= false and pitch ~= nil then
      playSoft("flute", 0.28, pitch)
      playSoft("chime", 0.12, pitch)
      playSoft("guitar", 0.12, math.max(0, pitch - 5))
    else
      playSoft("harp", 0.08, math.min(24, bassPitch + 12))
    end
  else
    -- Brighter in-game theme.
    playSoft("bass", 0.22, bassPitch)
    if pitch ~= false and pitch ~= nil then
      playSoft("harp", 0.42, pitch)
      playSoft("pling", 0.18, pitch)
      local harmony = pitch - 5
      if harmony < 0 then harmony = pitch + 3 end
      playSoft("guitar", 0.16, harmony)
      if beats >= 2 then
        playSoft("flute", 0.14, math.min(24, pitch + 7))
      end
    else
      playSoft("guitar", 0.10, bassPitch + 12 <= 24 and bassPitch + 12 or bassPitch)
    end
  end

  local wait = beats * (tr.beat or 0.14) * (tr.legato or 0.75)
  return math.max(0.06, wait)
end

local function sfxLineClear(n)
  if not MUSIC_ON or not SPEAKER then return end
  n = math.max(1, math.min(4, tonumber(n) or 1))
  -- Quiet click — avoid SPEAKER.stop() which would cut the song.
  playSoft("hat", 0.2, 10 + n)
end

-- Advanced Peripherals Player Detector (optional on pockets / desks).
local function detectNearbyPlayer()
  local pd = peripheral.find("playerDetector") or peripheral.find("player_detector")
  if not pd then return nil end
  local ok, players = pcall(function() return pd.getPlayersInRange(PLAYER_RANGE) end)
  if ok and type(players) == "table" and #players > 0 then
    local p = players[1]
    if type(p) == "string" then return p end
    if type(p) == "table" then return p.name or p.displayName or p.username end
  end
  local ok2, online = pcall(function() return pd.getOnlinePlayers() end)
  if ok2 and type(online) == "table" and #online > 0 then
    local p = online[1]
    if type(p) == "string" then return p end
    if type(p) == "table" then return p.name or p.displayName or p.username end
  end
  return nil
end

local function sanitizeName(name)
  name = tostring(name or ""):gsub("[%c%z]", ""):match("^%s*(.-)%s*$") or ""
  name = name:gsub("[%[%]%{%}%|=,;]", "")
  if #name > 16 then name = name:sub(1, 16) end
  if name == "" then return nil end
  return name
end

-- Compact score: 999 → 999, 1400 → 1.4K, 14000 → 14K, etc.
local function formatScore(n)
  n = math.floor(tonumber(n) or 0)
  local neg = ""
  if n < 0 then neg, n = "-", -n end
  if n < 1000 then return neg .. tostring(n) end
  local div, suf
  if n >= 1e12 then div, suf = 1e12, "T"
  elseif n >= 1e9 then div, suf = 1e9, "B"
  elseif n >= 1e6 then div, suf = 1e6, "M"
  else div, suf = 1e3, "K" end
  local v = n / div
  if v >= 100 then
    return neg .. tostring(math.floor(v + 0.5)) .. suf
  end
  if v >= 10 then
    return neg .. tostring(math.floor(v + 0.5)) .. suf
  end
  local tenths = math.floor(v * 10 + 0.5)
  if tenths % 10 == 0 then
    return neg .. tostring(math.floor(tenths / 10)) .. suf
  end
  return neg .. string.format("%d.%d%s", math.floor(tenths / 10), tenths % 10, suf)
end

local function saveLbCache()
  local f = fs.open(LB_CACHE, "w")
  if not f then return end
  f.write(textutils.serialize({
    entries = LEADERBOARD,
    pendingScore = PENDING_SCORE,
    syncedAt = LB_SYNCED_AT,
    playerName = PLAYER_NAME,
  }))
  f.close()
end

local function loadLbCache()
  if not fs.exists(LB_CACHE) then return false end
  local f = fs.open(LB_CACHE, "r")
  if not f then return false end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return false end
  if type(d.entries) == "table" then LEADERBOARD = d.entries end
  if d.pendingScore ~= nil then PENDING_SCORE = tonumber(d.pendingScore) end
  LB_SYNCED_AT = tonumber(d.syncedAt) or 0
  if type(d.playerName) == "string" and not PLAYER_NAME then
    PLAYER_NAME = sanitizeName(d.playerName)
  end
  return #LEADERBOARD > 0
end

-- Merge a local score into the cached top board (no network).
local function applyLocalScore(score, playerName)
  score = math.floor(tonumber(score) or 0)
  if score <= 0 then return end
  local name = sanitizeName(playerName)
    or sanitizeName(PLAYER_NAME)
    or ("P" .. tostring(os.getComputerID()))
  local me = os.getComputerID()
  local found = false
  for i = 1, #LEADERBOARD do
    local e = LEADERBOARD[i]
    if e and (tonumber(e.id) == me or tostring(e.name or ""):lower() == name:lower()) then
      if score > (tonumber(e.score) or 0) then
        e.score = score
        e.name = name
        e.id = me
      end
      found = true
      break
    end
  end
  if not found then
    LEADERBOARD[#LEADERBOARD + 1] = { id = me, name = name, score = score }
  end
  table.sort(LEADERBOARD, function(a, b)
    return (tonumber(a.score) or 0) > (tonumber(b.score) or 0)
  end)
  while #LEADERBOARD > 40 do LEADERBOARD[#LEADERBOARD] = nil end
  PENDING_SCORE = math.max(tonumber(PENDING_SCORE) or 0, score)
  saveLbCache()
end

local function closeAllModems()
  for _, side in ipairs(redstone.getSides()) do
    if peripheral.getType(side) == "modem" then
      pcall(rednet.close, side)
    end
  end
end

-- After boot OTA/LB: no more rednet for this run (speaker + mesh fights crash pockets).
local function lockNetworkOffline()
  NET_LOCKED = true
  closeAllModems()
end

local function findInstallHost(timeout)
  if NET_LOCKED then return nil end
  if titan and titan.findInstallHost then
    return titan.findInstallHost(timeout or 5)
  end
  timeout = tonumber(timeout) or 5
  local me = os.getComputerID()
  local mainId = titan and titan.getMainRouterId and titan.getMainRouterId()
  rednet.broadcast({ type = "discover" }, INSTALL_PROTO)
  rednet.broadcast({ type = "install_discover", originId = me, from = me }, ROUTER_PROTO)
  if mainId then
    rednet.send(mainId, { type = "install_discover", originId = me, from = me }, ROUTER_PROTO)
    rednet.send(mainId, { type = "install_where", from = me }, ROUTER_PROTO)
  end
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg, proto = rednet.receive(nil, deadline - os.clock())
    if type(msg) == "table" then
      if msg.type == "host_here" then return id, msg end
      if msg.type == "install_host_here" then
        return tonumber(msg.hostId) or id, msg
      end
    end
  end
  return nil
end

-- Pull board; optionally submit a score under playerName. Returns entries or nil.
-- Blocked once NET_LOCKED (use local cache / applyLocalScore instead).
local function syncLeaderboard(submitScore, playerName)
  if NET_LOCKED then
    return (#LEADERBOARD > 0) and LEADERBOARD or nil, "offline"
  end
  if not hasModem() then
    return (#LEADERBOARD > 0) and LEADERBOARD or nil, "no modem"
  end
  local hostId = findInstallHost(5)
  if not hostId then
    return (#LEADERBOARD > 0) and LEADERBOARD or nil, "no host"
  end
  local name = sanitizeName(playerName)
    or sanitizeName(PLAYER_NAME)
    or sanitizeName(detectNearbyPlayer())
    or ("P" .. tostring(os.getComputerID()))
  local me = os.getComputerID()
  local mainId = titan and titan.getMainRouterId and titan.getMainRouterId()
  local score = math.floor(tonumber(submitScore) or 0)
  if score <= 0 then score = math.floor(tonumber(PENDING_SCORE) or 0) end
  local req
  if score > 0 then
    req = {
      type = "tetris_lb_submit",
      playerId = me,
      name = name,
      score = score,
      replyTo = me,
      originId = me,
      dest = hostId,
      hostId = hostId,
    }
  else
    req = {
      type = "tetris_lb_get",
      replyTo = me,
      originId = me,
      dest = hostId,
      hostId = hostId,
    }
  end
  rednet.send(hostId, req, INSTALL_PROTO)
  rednet.send(hostId, req, ROUTER_PROTO)
  if mainId then
    rednet.send(mainId, req, ROUTER_PROTO)
    rednet.send(mainId, {
      type = "install_fwd", dest = hostId, payload = req, replyTo = me, from = me,
    }, ROUTER_PROTO)
  end
  local deadline = os.clock() + 5
  while os.clock() < deadline do
    local id, msg = rednet.receive(nil, deadline - os.clock())
    if type(msg) == "table" and msg.type == "tetris_lb" then
      if type(msg.entries) == "table" then
        LEADERBOARD = msg.entries
      end
      LB_SYNCED_AT = os.epoch("utc") or os.clock()
      if score > 0 then PENDING_SCORE = nil end
      saveLbCache()
      return LEADERBOARD
    end
  end
  return (#LEADERBOARD > 0) and LEADERBOARD or nil, "timeout"
end

-- SRS-ish shapes (4x4, 0-based cells as {x,y} relative)
local SHAPES = {
  I = {
    { {0,1},{1,1},{2,1},{3,1} },
    { {2,0},{2,1},{2,2},{2,3} },
    { {0,2},{1,2},{2,2},{3,2} },
    { {1,0},{1,1},{1,2},{1,3} },
  },
  O = {
    { {1,0},{2,0},{1,1},{2,1} },
    { {1,0},{2,0},{1,1},{2,1} },
    { {1,0},{2,0},{1,1},{2,1} },
    { {1,0},{2,0},{1,1},{2,1} },
  },
  T = {
    { {1,0},{0,1},{1,1},{2,1} },
    { {1,0},{1,1},{2,1},{1,2} },
    { {0,1},{1,1},{2,1},{1,2} },
    { {1,0},{0,1},{1,1},{1,2} },
  },
  S = {
    { {1,0},{2,0},{0,1},{1,1} },
    { {1,0},{1,1},{2,1},{2,2} },
    { {1,1},{2,1},{0,2},{1,2} },
    { {0,0},{0,1},{1,1},{1,2} },
  },
  Z = {
    { {0,0},{1,0},{1,1},{2,1} },
    { {2,0},{1,1},{2,1},{1,2} },
    { {0,1},{1,1},{1,2},{2,2} },
    { {1,0},{0,1},{1,1},{0,2} },
  },
  J = {
    { {0,0},{0,1},{1,1},{2,1} },
    { {1,0},{2,0},{1,1},{1,2} },
    { {0,1},{1,1},{2,1},{2,2} },
    { {1,0},{1,1},{0,2},{1,2} },
  },
  L = {
    { {2,0},{0,1},{1,1},{2,1} },
    { {1,0},{1,1},{1,2},{2,2} },
    { {0,1},{1,1},{2,1},{0,2} },
    { {0,0},{1,0},{1,1},{1,2} },
  },
}

local BAG_ORDER = { "I", "O", "T", "S", "Z", "J", "L" }

local PIECE_COLOR = {
  I = colors.cyan,
  O = colors.yellow,
  T = colors.purple,
  S = colors.lime,
  Z = colors.red,
  J = colors.blue,
  L = colors.orange,
}

local PIECE_CHAR = {
  I = "I", O = "O", T = "T", S = "S", Z = "Z", J = "J", L = "L",
}

local function fill(x, y, w, h, bg, fg)
  for row = y, y + h - 1 do
    term.setCursorPos(x, row)
    if term.setBackgroundColor then term.setBackgroundColor(bg or colors.black) end
    if term.setTextColor then term.setTextColor(fg or colors.white) end
    term.write(string.rep(" ", w))
  end
end

local function text(x, y, s, fg, bg)
  if term.setBackgroundColor then term.setBackgroundColor(bg or colors.black) end
  if term.setTextColor then term.setTextColor(fg or colors.white) end
  term.setCursorPos(x, y)
  term.write(tostring(s))
end

local function clearScreen(bg)
  bg = bg or colors.black
  if term.setBackgroundColor then term.setBackgroundColor(bg) end
  if term.setTextColor then term.setTextColor(colors.white) end
  term.clear()
end

local function shuffle(t)
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

local function newBag()
  local bag = {}
  for i = 1, #BAG_ORDER do bag[i] = BAG_ORDER[i] end
  return shuffle(bag)
end

local function emptyGrid()
  local g = {}
  for y = 1, ROWS do
    g[y] = {}
    for x = 1, COLS do g[y][x] = false end
  end
  return g
end

local function cellsOf(kind, rot, ox, oy)
  local shape = SHAPES[kind][rot + 1]
  local out = {}
  for i = 1, #shape do
    out[i] = { shape[i][1] + ox, shape[i][2] + oy }
  end
  return out
end

local function fits(grid, kind, rot, ox, oy)
  local cells = cellsOf(kind, rot, ox, oy)
  for i = 1, #cells do
    local x, y = cells[i][1] + 1, cells[i][2] + 1 -- 1-based board
    if x < 1 or x > COLS or y > ROWS then return false end
    if y >= 1 and grid[y][x] then return false end
  end
  return true
end

local function lock(grid, kind, rot, ox, oy)
  local cells = cellsOf(kind, rot, ox, oy)
  for i = 1, #cells do
    local x, y = cells[i][1] + 1, cells[i][2] + 1
    if y >= 1 and y <= ROWS and x >= 1 and x <= COLS then
      grid[y][x] = kind
    end
  end
end

local function clearLines(grid)
  local cleared = 0
  local y = ROWS
  while y >= 1 do
    local full = true
    for x = 1, COLS do
      if not grid[y][x] then full = false; break end
    end
    if full then
      cleared = cleared + 1
      for yy = y, 2, -1 do
        for x = 1, COLS do grid[yy][x] = grid[yy - 1][x] end
      end
      for x = 1, COLS do grid[1][x] = false end
      -- stay on same y to re-check after collapse
    else
      y = y - 1
    end
  end
  return cleared
end

local function lineScore(n, level)
  local base = ({ 0, 100, 300, 500, 800 })[n + 1] or 0
  return base * (level + 1)
end

local function gravityMs(level)
  return math.max(80, 800 - level * 70)
end

--------------------------------------------------------------------------------
-- Layout helpers (fit pocket ~26x20 and larger screens)
--------------------------------------------------------------------------------
local function layout()
  local tw, th = term.getSize()
  -- Monitor: reserve bottom half for an on-screen touch pad.
  local padH, gameH = 0, th
  if USING_MONITOR and th >= 12 then
    padH = math.max(6, math.floor(th / 2))
    if th - padH < 10 then padH = math.max(5, th - 10) end
    gameH = th - padH
  end
  local cellW = 1
  local boardW = COLS * cellW + 2 -- borders
  -- Shrink visible rows if screen is short (still play full logic; scroll top)
  local visRows = math.min(ROWS, math.max(6, gameH - 2))
  -- Leave a slim HUD column on the right (SIDE_W), not a wide score box.
  local totalW = boardW + 1 + SIDE_W
  local ox = math.max(1, math.floor((tw - totalW) / 2) + 1)
  if ox + totalW - 1 > tw then ox = 1 end
  local oy = math.max(1, math.floor((gameH - (visRows + 2)) / 2))
  local px = ox + boardW + 1
  if px + SIDE_W - 1 > tw then px = math.max(1, tw - SIDE_W + 1) end
  return {
    tw = tw, th = th, ox = ox, oy = oy, px = px,
    cellW = cellW, boardW = boardW, visRows = visRows,
    color = isColor(),
    padH = padH, padTop = gameH + 1, gameH = gameH,
    buttons = {},
  }
end

local function touchPadButtons(L)
  if not L or (L.padH or 0) < 4 then return {} end
  local y0, tw, padH = L.padTop, L.tw, L.padH
  local bw = math.max(3, math.floor(tw / 3))
  local bh = math.max(1, math.floor(padH / 3))
  local defs = {
    { "left", "<" }, { "rot", "ROT" }, { "right", ">" },
    { "soft", "v" }, { "drop", "DROP" }, { "pause", "P" },
    { "mute", "MUTE" }, { "noop", "" },
    { "quit", FROM_LAUNCHER and "CLOSE" or "QUIT" },
  }
  local buttons = {}
  for i = 1, #defs do
    local id, label = defs[i][1], defs[i][2]
    if id ~= "noop" then
      local col = (i - 1) % 3
      local row = math.floor((i - 1) / 3)
      local x = col * bw + 1
      local w = (col == 2) and (tw - x + 1) or bw
      local y = y0 + row * bh
      local h = (row == 2) and (y0 + padH - y) or bh
      if h < 1 then h = 1 end
      buttons[#buttons + 1] = { id = id, x = x, y = y, w = w, h = h, label = label }
    end
  end
  return buttons
end

local function drawTouchPad(L, paused)
  local buttons = touchPadButtons(L)
  L.buttons = buttons
  if #buttons == 0 then return end
  for i = 1, #buttons do
    local b = buttons[i]
    local bg = colors.gray
    if b.id == "drop" then bg = colors.blue
    elseif b.id == "quit" then bg = colors.red
    elseif b.id == "pause" and paused then bg = colors.yellow
    elseif b.id == "mute" and not MUSIC_ON then bg = colors.orange
    elseif b.id == "rot" then bg = colors.purple
    end
    fill(b.x, b.y, b.w, b.h, bg, colors.white)
    local label = b.label
    if b.id == "mute" then label = MUSIC_ON and "MUTE" or "UNMUTE" end
    if b.id == "pause" then label = paused and "PLAY" or "P" end
    label = label:sub(1, b.w)
    local lx = b.x + math.max(0, math.floor((b.w - #label) / 2))
    local ly = b.y + math.floor((b.h - 1) / 2)
    text(lx, ly, label, colors.white, bg)
  end
end

local function hitTouchPad(L, mx, my)
  local buttons = L and L.buttons or {}
  for i = 1, #buttons do
    local b = buttons[i]
    if mx >= b.x and mx <= b.x + b.w - 1
        and my >= b.y and my <= b.y + b.h - 1 then
      return b.id
    end
  end
  return nil
end

local function drawCell(L, bx, by, kind, ghost)
  -- bx,by are 1-based board coords
  local top = ROWS - L.visRows + 1
  if by < top or by > ROWS then return end
  local sx = L.ox + 1 + (bx - 1) * L.cellW
  local sy = L.oy + 1 + (by - top)
  if ghost then
    if L.color then
      text(sx, sy, "·", colors.lightGray, colors.black)
    else
      text(sx, sy, ".", colors.lightGray, colors.black)
    end
    return
  end
  if not kind then
    text(sx, sy, " ", colors.white, colors.black)
    return
  end
  if L.color then
    local c = PIECE_COLOR[kind] or colors.white
    fill(sx, sy, L.cellW, 1, c, colors.black)
  else
    text(sx, sy, PIECE_CHAR[kind] or "#", colors.white, colors.black)
  end
end

local function ghostY(grid, kind, rot, ox, oy)
  local y = oy
  while fits(grid, kind, rot, ox, y + 1) do y = y + 1 end
  return y
end

local function drawBoard(L, grid, piece, nextKind, score, level, lines, paused, over)
  clearScreen(colors.black)
  local top = ROWS - L.visRows + 1

  -- Border
  local bw = COLS * L.cellW
  if L.color then
    fill(L.ox, L.oy, bw + 2, 1, colors.gray, colors.white)
    fill(L.ox, L.oy + L.visRows + 1, bw + 2, 1, colors.gray, colors.white)
    for r = 1, L.visRows do
      text(L.ox, L.oy + r, " ", colors.white, colors.gray)
      text(L.ox + bw + 1, L.oy + r, " ", colors.white, colors.gray)
    end
  else
    text(L.ox, L.oy, "+" .. string.rep("-", bw) .. "+", colors.white, colors.black)
    text(L.ox, L.oy + L.visRows + 1, "+" .. string.rep("-", bw) .. "+", colors.white, colors.black)
    for r = 1, L.visRows do
      text(L.ox, L.oy + r, "|", colors.white, colors.black)
      text(L.ox + bw + 1, L.oy + r, "|", colors.white, colors.black)
    end
  end

  -- Settled cells
  for y = top, ROWS do
    for x = 1, COLS do
      drawCell(L, x, y, grid[y][x], false)
    end
  end

  -- Ghost + active piece
  if piece and not over then
    local gy = ghostY(grid, piece.kind, piece.rot, piece.x, piece.y)
    if gy ~= piece.y then
      local gcells = cellsOf(piece.kind, piece.rot, piece.x, gy)
      for i = 1, #gcells do
        local x, y = gcells[i][1] + 1, gcells[i][2] + 1
        if y >= top and not grid[y][x] then
          drawCell(L, x, y, piece.kind, true)
        end
      end
    end
    local cells = cellsOf(piece.kind, piece.rot, piece.x, piece.y)
    for i = 1, #cells do
      local x, y = cells[i][1] + 1, cells[i][2] + 1
      if y >= 1 then drawCell(L, x, y, piece.kind, false) end
    end
  end

  -- Slim HUD (right of well) — short labels + truncated scores
  local px, py = L.px, L.oy
  local sc = formatScore(score):sub(1, SIDE_W)
  local hi = formatScore(math.max(HI, score)):sub(1, SIDE_W)
  text(px, py, "TET", L.color and colors.cyan or colors.white, colors.black)
  text(px, py + 1, sc, colors.white, colors.black)
  text(px, py + 2, "HI", colors.lightGray, colors.black)
  text(px, py + 3, hi, colors.yellow, colors.black)
  text(px, py + 5, ("L%-3s"):format(tostring(level)):sub(1, SIDE_W), colors.lime, colors.black)
  text(px, py + 6, ("n%-3s"):format(tostring(lines)):sub(1, SIDE_W), colors.lightGray, colors.black)
  if nextKind then
    text(px, py + 8, "NXT", colors.lightGray, colors.black)
    if L.color then
      fill(px, py + 9, math.min(SIDE_W, 3), 1, PIECE_COLOR[nextKind] or colors.white, colors.black)
      text(px, py + 9, (" %s "):format(nextKind):sub(1, SIDE_W),
        colors.black, PIECE_COLOR[nextKind] or colors.white)
    else
      text(px, py + 9, tostring(nextKind):sub(1, SIDE_W), colors.white, colors.black)
    end
  end

  if paused then
    text(L.ox + 2, L.oy + math.floor(L.visRows / 2), " PAUSED ", colors.black, colors.yellow)
  end
  if over then
    text(L.ox + 1, L.oy + math.floor(L.visRows / 2), " GAME OVER ", colors.white, colors.red)
    text(L.ox + 1, L.oy + math.floor(L.visRows / 2) + 1,
      USING_MONITOR and " Tap pad " or " Enter/Q ",
      colors.black, colors.white)
  end

  if (L.padH or 0) >= 4 then
    drawTouchPad(L, paused)
  else
    L.buttons = {}
    if L.th >= L.oy + L.visRows + 3 then
      text(1, L.th, "Arrows  Up=rot  Spc=drop  P  Q",
        colors.gray, colors.black)
    end
  end
end

--------------------------------------------------------------------------------
-- Game loop
--------------------------------------------------------------------------------
local function spawn(grid, bag)
  if #bag == 0 then bag = newBag() end
  local kind = table.remove(bag, 1)
  if #bag == 0 then
    local more = newBag()
    for i = 1, #more do bag[#bag + 1] = more[i] end
  end
  local piece = { kind = kind, rot = 0, x = 3, y = 0 }
  if not fits(grid, piece.kind, piece.rot, piece.x, piece.y) then
    return nil, bag
  end
  return piece, bag
end

local function runGame()
  local L = layout()
  local grid = emptyGrid()
  local bag = newBag()
  local piece, nextPeek
  piece, bag = spawn(grid, bag)
  nextPeek = bag[1]
  local score, level, lines = 0, 0, 0
  local paused, over = false, false
  local dropTimer = os.startTimer(gravityMs(level) / 1000)
  local dirty = true
  TRACK.playing, TRACK.score, TRACK.level, TRACK.lines = true, 0, 0, 0

  if not piece then over = true end

  refreshSpeaker()
  startMusic("game")
  local musicTimer = os.startTimer(MUSIC_ON and SPEAKER and 0.05 or 3600)

  local function finish(keepScore)
    stopMusic()
    TRACK.playing = false
    TRACK.score = keepScore and score or 0
    return keepScore and score or 0
  end

  local function togglePause()
    paused = not paused
    dirty = true
    if paused then
      if SPEAKER then pcall(function() SPEAKER.stop() end) end
    else
      dropTimer = os.startTimer(gravityMs(level) / 1000)
      if MUSIC_ON then
        startMusic("game")
        musicTimer = os.startTimer(0.05)
      end
    end
  end

  local function toggleMute()
    MUSIC_ON = not MUSIC_ON
    saveCfg()
    if MUSIC_ON and SPEAKER and not paused and not over then
      startMusic("game")
      musicTimer = os.startTimer(0.05)
    else
      stopMusic()
    end
    dirty = true
  end

  local function lockAndSpawn()
    lock(grid, piece.kind, piece.rot, piece.x, piece.y)
    local n = clearLines(grid)
    if n > 0 then
      score = score + lineScore(n, level)
      lines = lines + n
      level = math.floor(lines / 10)
      sfxLineClear(n)
    end
    piece, bag = spawn(grid, bag)
    if not piece then over = true end
    dirty = true
  end

  local function doLeft()
    if paused or over or not piece then return end
    if fits(grid, piece.kind, piece.rot, piece.x - 1, piece.y) then
      piece.x = piece.x - 1; dirty = true
    end
  end

  local function doRight()
    if paused or over or not piece then return end
    if fits(grid, piece.kind, piece.rot, piece.x + 1, piece.y) then
      piece.x = piece.x + 1; dirty = true
    end
  end

  local function doRot()
    if paused or over or not piece then return end
    local nr = (piece.rot + 1) % 4
    if fits(grid, piece.kind, nr, piece.x, piece.y)
        or fits(grid, piece.kind, nr, piece.x - 1, piece.y)
        or fits(grid, piece.kind, nr, piece.x + 1, piece.y) then
      if not fits(grid, piece.kind, nr, piece.x, piece.y) then
        if fits(grid, piece.kind, nr, piece.x - 1, piece.y) then
          piece.x = piece.x - 1
        else
          piece.x = piece.x + 1
        end
      end
      piece.rot = nr
      dirty = true
    end
  end

  local function doSoft()
    if paused or over or not piece then return end
    if fits(grid, piece.kind, piece.rot, piece.x, piece.y + 1) then
      piece.y = piece.y + 1
      score = score + 1
      dirty = true
    end
  end

  local function doDrop()
    if paused or over or not piece then return end
    local dropped = 0
    while fits(grid, piece.kind, piece.rot, piece.x, piece.y + 1) do
      piece.y = piece.y + 1
      dropped = dropped + 1
    end
    score = score + dropped * 2
    lockAndSpawn()
    dropTimer = os.startTimer(gravityMs(level) / 1000)
  end

  local function padAction(id)
    if not id then return nil end
    if over then
      if id == "mute" then toggleMute(); return nil end
      return finish(true)
    end
    if id == "left" then doLeft()
    elseif id == "right" then doRight()
    elseif id == "rot" then doRot()
    elseif id == "soft" then doSoft()
    elseif id == "drop" then doDrop()
    elseif id == "pause" then togglePause()
    elseif id == "mute" then toggleMute()
    elseif id == "quit" then return finish(false)
    end
    return nil
  end

  while true do
    TRACK.score, TRACK.level, TRACK.lines = score, level, lines
    if dirty then
      nextPeek = bag[1]
      drawBoard(L, grid, piece, nextPeek, score, level, lines, paused, over)
      dirty = false
    end

    local ev, p1, p2, p3 = pullGameEvent()
    if ev == "term_resize" or ev == "monitor_resize" then
      L = layout()
      dirty = true
    elseif ev == "timer" and p1 == musicTimer then
      if not paused and not over and MUSIC_ON then
        musicTimer = os.startTimer(musicStepSeconds())
      else
        musicTimer = os.startTimer(0.35)
      end
    elseif ev == "timer" and p1 == dropTimer then
      if not paused and not over and piece then
        if fits(grid, piece.kind, piece.rot, piece.x, piece.y + 1) then
          piece.y = piece.y + 1
        else
          lockAndSpawn()
        end
        dirty = true
      end
      if not over then
        dropTimer = os.startTimer(gravityMs(level) / 1000)
      end
    elseif ev == "mouse_click" then
      local ret = padAction(hitTouchPad(L, p2, p3))
      if ret ~= nil then return ret end
    elseif ev == "key" and not over then
      local k = p1
      local K = keys
      if k == K.p or (K.pause and k == K.pause) then
        togglePause()
      elseif k == K.m then
        toggleMute()
      elseif k == K.q then
        return finish(false)
      elseif k == K.left or k == K.a or k == K.h then
        doLeft()
      elseif k == K.right or k == K.d or k == K.l then
        doRight()
      elseif k == K.up or k == K.w or k == K.k or k == K.x then
        doRot()
      elseif k == K.down or k == K.s or k == K.j then
        doSoft()
      elseif k == K.space or k == K.enter then
        doDrop()
      end
    elseif ev == "key" and over then
      if p1 == keys.enter or p1 == keys.q or p1 == keys.space then
        return finish(true)
      end
    elseif ev == "char" and not over then
      -- Q only here as a fallback; pause is key-only so CC's paired
      -- key+char for "p" does not toggle pause twice (appear broken).
      local ch = tostring(p1 or ""):lower()
      if ch == "q" then
        return finish(false)
      elseif ch == "m" then
        toggleMute()
      end
    elseif ev == "terminate" then
      return finish(false)
    end
  end
end

--------------------------------------------------------------------------------
-- Main menu (leaderboard + play)
--------------------------------------------------------------------------------
-- CC queues both key + char for the same press; flush so a leftover "q" from
-- the game does not immediately quit the main menu.
local function drainInputEvents()
  local t = os.startTimer(0)
  while true do
    local ev, p1 = os.pullEvent()
    if ev == "timer" and p1 == t then return end
  end
end

-- After a run: prefer detector, else saved name, else typed prompt.
local function resolvePlayerName(score)
  local detected = sanitizeName(detectNearbyPlayer())
  if detected then
    PLAYER_NAME = detected
    saveCfg()
    return PLAYER_NAME
  end
  if (tonumber(score) or 0) <= 0 then
    return PLAYER_NAME
  end
  clearScreen(colors.black)
  term.setCursorPos(1, 1)
  if term.setTextColor then term.setTextColor(colors.white) end
  print("Game over")
  print("Score  " .. formatScore(score))
  print("")
  print("Name for the leaderboard:")
  if PLAYER_NAME then
    print("(Enter keeps \"" .. PLAYER_NAME .. "\")")
  else
    print("(Player Detector auto-fills when attached)")
  end
  print("")
  local def = PLAYER_NAME or ""
  write("Name" .. (def ~= "" and (" [" .. def .. "]") or "") .. ": ")
  local typed = sanitizeName(read() or "")
  if not typed then typed = def end
  if not typed or typed == "" then typed = "Player" end
  PLAYER_NAME = typed
  saveCfg()
  drainInputEvents()
  return PLAYER_NAME
end

local function afterGame(score)
  score = tonumber(score) or 0
  if score > HI then
    HI = score
  end
  local name = nil
  if score > 0 then
    name = resolvePlayerName(score)
  else
    name = sanitizeName(detectNearbyPlayer()) or PLAYER_NAME
    if name then PLAYER_NAME = name; saveCfg() end
  end
  saveCfg()
  -- Offline session: update local board only (queued for next boot sync).
  if score > 0 then
    applyLocalScore(score, name)
  end
  drainInputEvents()
end

local function hitBtn(btn, x, y)
  return btn and btn.x and x >= btn.x and x < btn.x + btn.w
      and y >= btn.y and y < btn.y + btn.h
end

local function drawMenu(playBtn, ctrlBtn)
  local tw, th = term.getSize()
  local color = isColor()
  clearScreen(colors.black)

  local accent = color and colors.cyan or colors.white
  fill(1, 1, tw, 1, accent, colors.black)
  text(2, 1, "TETRIS", colors.black, accent)
  local who = PLAYER_NAME or "guest"
  local you = (who .. " " .. formatScore(HI)):sub(1, tw - 9)
  text(math.max(2, tw - #you), 1, you, colors.black, accent)

  local y = 3
  text(2, y, "TOP 3", color and colors.yellow or colors.white, colors.black)
  y = y + 1
  text(2, y, "#  NAME         SCORE", color and colors.lightGray or colors.white, colors.black)
  y = y + 1
  local myName = PLAYER_NAME and PLAYER_NAME:lower()
  if #LEADERBOARD == 0 then
    text(2, y, "(no scores yet — be #1)", colors.gray, colors.black)
    y = y + 1
  else
    for i = 1, math.min(LB_TOP, #LEADERBOARD) do
      local e = LEADERBOARD[i]
      local name = tostring(e.name or ("#" .. tostring(e.id))):sub(1, 12)
      local sc = formatScore(e.score or 0)
      local line = ("%-2d %-12s %5s"):format(i, name, sc)
      local fg = colors.white
      if myName and tostring(e.name or ""):lower() == myName then
        fg = color and colors.lime or colors.white
      elseif i == 1 then
        fg = colors.yellow
      end
      text(2, y, line:sub(1, tw - 2), fg, colors.black)
      y = y + 1
    end
  end

  local playLabel = "  PLAY  "
  local ctrlLabel = " CONTROLS "
  local gap = 2
  local total = #playLabel + gap + #ctrlLabel
  local rowY = math.min(th - 2, y + 1)
  local startX = math.max(2, math.floor((tw - total) / 2) + 1)
  local playBg = color and colors.lime or colors.white
  local ctrlBg = color and colors.orange or colors.lightGray
  fill(startX, rowY, #playLabel, 1, playBg, colors.black)
  text(startX, rowY, playLabel, colors.black, playBg)
  playBtn.x, playBtn.y, playBtn.w, playBtn.h = startX, rowY, #playLabel, 1
  local cx = startX + #playLabel + gap
  fill(cx, rowY, #ctrlLabel, 1, ctrlBg, colors.black)
  text(cx, rowY, ctrlLabel, colors.black, ctrlBg)
  ctrlBtn.x, ctrlBtn.y, ctrlBtn.w, ctrlBtn.h = cx, rowY, #ctrlLabel, 1

  local net = NET_LOCKED and "local LB" or meshStatusLine()
  local foot = FROM_LAUNCHER
    and ("Enter play  C  M  R  Q=Close  %s"):format(net)
    or ("Enter play  C ctrl  M mute  R local  Q=off  %s"):format(net)
  text(2, th, foot:sub(1, tw - 2), colors.gray, colors.black)
end

local function controlsScreen()
  while true do
    local tw, th = term.getSize()
    local color = isColor()
    clearScreen(colors.black)
    local accent = color and colors.orange or colors.white
    fill(1, 1, tw, 1, accent, colors.black)
    text(2, 1, "CONTROLS", colors.black, accent)

    local lines = {
      { "Left",  "A / H / ←" },
      { "Right", "D / L / →" },
      { "Rotate","W / K / X / ↑" },
      { "Soft",  "S / J / ↓" },
      { "Hard",  "Space / Enter" },
      { "Pause", "P" },
      { "Mute",  "M (note music)" },
      { "Swap",  "U (modem <-> speaker)" },
      { "Board", "R reload local cache" },
      { "Menu",  FROM_LAUNCHER and "Q / Close (back to launcher)" or "Q (always)" },
    }
    local y = 3
    for i = 1, #lines do
      if y >= th - 2 then break end
      local row = lines[i]
      text(2, y, row[1], color and colors.yellow or colors.white, colors.black)
      text(10, y, row[2], colors.white, colors.black)
      y = y + 1
    end
    y = y + 1
    if y < th then
      text(2, y, "Q mid-game abandons score.", color and colors.red or colors.white, colors.black)
      y = y + 1
    end
    if y < th then
      text(2, y, ("Now: %s"):format(meshStatusLine()), colors.gray, colors.black)
    end
    text(2, th, "Q  main menu", colors.gray, colors.black)

    local ev, p1 = pullGameEvent()
    if ev == "key" and (p1 == keys.q or p1 == keys.backspace) then
      drainInputEvents()
      return
    elseif ev == "char" and tostring(p1 or ""):lower() == "q" then
      drainInputEvents()
      return
    elseif ev == "mouse_click" then
      -- ignore taps; Q to leave
    elseif ev == "terminate" then
      return
    end
  end
end

local function editPlayerName()
  clearScreen(colors.black)
  term.setCursorPos(1, 1)
  print("Leaderboard name")
  local det = sanitizeName(detectNearbyPlayer())
  if det then print("Detected: " .. det) end
  local def = det or PLAYER_NAME or ""
  write("Name" .. (def ~= "" and (" [" .. def .. "]") or "") .. ": ")
  local typed = sanitizeName(read() or "")
  if not typed then typed = def end
  if typed and typed ~= "" then
    PLAYER_NAME = typed
    saveCfg()
  end
  drainInputEvents()
end

local function showQuitDisclaimer()
  clearScreen(colors.black)
  local tw, th = term.getSize()
  local color = isColor()
  local accent = color and colors.red or colors.white
  fill(1, 1, tw, 1, accent, colors.black)
  text(2, 1, "NOTICE", colors.black, accent)
  local y = 3
  local msg = {
    "Pressing Q during a game",
    "returns you to the menu.",
    "",
    "That run's score is NOT kept.",
    "Finish the game to save it.",
  }
  for i = 1, #msg do
    text(2, y, msg[i], colors.white, colors.black)
    y = y + 1
  end
  text(2, th, "Continuing in 5s...", colors.gray, colors.black)
  sleep(5)
  drainInputEvents()
end

local function mainMenu()
  local playBtn, ctrlBtn = {}, {}
  -- Soft detect on menu open.
  local det = sanitizeName(detectNearbyPlayer())
  if det then PLAYER_NAME = det; saveCfg() end
  startMusic("menu")
  local musicTimer = os.startTimer(MUSIC_ON and refreshSpeaker() and 0.05 or 3600)

  local function resumeMenuMusic()
    startMusic("menu")
    musicTimer = os.startTimer(MUSIC_ON and SPEAKER and 0.05 or 3600)
  end

  local function playRound()
    stopMusic()
    local score = runGame()
    afterGame(score)
    resumeMenuMusic()
  end

  while true do
    drawMenu(playBtn, ctrlBtn)
    local ev, p1, p2, p3 = pullGameEvent()
    if ev == "timer" and p1 == musicTimer then
      if MUSIC_ON then
        musicTimer = os.startTimer(musicStepSeconds())
      else
        musicTimer = os.startTimer(0.5)
      end
    elseif ev == "key" then
      if p1 == keys.enter or p1 == keys.space or p1 == keys.p then
        playRound()
      elseif p1 == keys.c then
        stopMusic()
        controlsScreen()
        resumeMenuMusic()
      elseif p1 == keys.r then
        -- Offline-safe: reload disk cache only (no rednet after boot).
        loadLbCache()
      elseif p1 == keys.n then
        stopMusic()
        editPlayerName()
        resumeMenuMusic()
      elseif p1 == keys.m then
        MUSIC_ON = not MUSIC_ON
        saveCfg()
        if MUSIC_ON then resumeMenuMusic() else stopMusic() end
      elseif p1 == keys.u then
        local ok, err = swapPocketUpgrade()
        if not ok then
          clearScreen(colors.black)
          term.setCursorPos(1, 1)
          print("Upgrade swap failed: " .. tostring(err or "none in hotbar"))
          print("Select a wireless modem or speaker, then U.")
          sleep(1.6)
          drainInputEvents()
        end
        resumeMenuMusic()
      elseif p1 == keys.q then
        stopMusic()
        clearScreen(colors.black)
        term.setCursorPos(1, 1)
        if FROM_LAUNCHER then
          print("Closing…")
          sleep(0.15)
          return
        end
        print("Shutting down...")
        sleep(0.2)
        os.shutdown()
        return
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "q" then
        stopMusic()
        clearScreen(colors.black)
        term.setCursorPos(1, 1)
        if FROM_LAUNCHER then
          print("Closing…")
          sleep(0.15)
          return
        end
        print("Shutting down...")
        sleep(0.2)
        os.shutdown()
        return
      elseif ch == "p" then
        playRound()
      elseif ch == "c" then
        stopMusic()
        controlsScreen()
        resumeMenuMusic()
      elseif ch == "r" then
        loadLbCache()
      elseif ch == "n" then
        stopMusic()
        editPlayerName()
        resumeMenuMusic()
      elseif ch == "m" then
        MUSIC_ON = not MUSIC_ON
        saveCfg()
        if MUSIC_ON then resumeMenuMusic() else stopMusic() end
      elseif ch == "u" then
        local ok, err = swapPocketUpgrade()
        if not ok then
          clearScreen(colors.black)
          term.setCursorPos(1, 1)
          print("Upgrade swap failed: " .. tostring(err or "none in hotbar"))
          print("Select a wireless modem or speaker, then U.")
          sleep(1.6)
          drainInputEvents()
        end
        resumeMenuMusic()
      end
    elseif ev == "mouse_click" then
      local x, y = p2, p3
      if hitBtn(playBtn, x, y) then
        playRound()
      elseif hitBtn(ctrlBtn, x, y) then
        stopMusic()
        controlsScreen()
        resumeMenuMusic()
      end
    elseif ev == "term_resize" then
      -- redraw
    elseif ev == "terminate" then
      stopMusic()
      clearScreen(colors.black)
      return
    end
  end
end

--------------------------------------------------------------------------------
-- Hidden Titan mesh tracker (SSH + GPS beacons). Silent if offline.
--------------------------------------------------------------------------------
math.randomseed(os.epoch("utc") % 2147483647)

-- Boot: one network window (OTA + LB), cache to disk, then go offline.
local function bootCheckUpdates()
  clearScreen(colors.black)
  term.setCursorPos(1, 1)
  if term.setTextColor then term.setTextColor(colors.lightGray) end
  print("Tetris")
  loadLbCache()
  if #LEADERBOARD > 0 then
    print(("Local board: %d player%s"):format(
      #LEADERBOARD, #LEADERBOARD == 1 and "" or "s"))
  end
  -- Drop any old downloaded DFPWM cache (music is in-script notes only now).
  if fs.exists(LEGACY_MUSIC_FILE) then pcall(fs.delete, LEGACY_MUSIC_FILE) end
  print(meshStatusLine())

  if NO_MODEM or not hasModem() then
    if NO_MODEM then
      print("No-modem mode — cached leaderboard only.")
    else
      print("No modem — cached leaderboard only.")
      print("(Equip wireless modem for host sync; U swaps pocket upgrade.)")
    end
    lockNetworkOffline()
    sleep(0.55)
    showQuitDisclaimer()
    return
  end

  -- Need modem for host OTA + leaderboard even without full mesh lib.
  if titan and titan.openModem then
    pcall(titan.openModem)
  else
    for _, side in ipairs(redstone.getSides()) do
      if peripheral.getType(side) == "modem" and not rednet.isOpen(side) then
        pcall(rednet.open, side)
      end
    end
  end

  if not os.getComputerLabel() or os.getComputerLabel() == "" then
    os.setComputerLabel("Tetris-" .. os.getComputerID())
  end

  -- Join mesh first so host OTA can hop through MAIN / cell modems.
  if titan and titan.findMainRouter then
    print("Finding mesh router...")
    local mainId = titan.findMainRouter(3)
    if mainId then
      print("Main router #" .. tostring(mainId))
      if titan.announce then pcall(titan.announce, KIND) end
    else
      print("No main router yet — trying host anyway.")
    end
  end

  if titan and titan.bootUpdateCheck then
    print("Checking for updates (host via mesh)...")
    if titan.writePackageList then
      -- Always keep tetris on the desired list (old installs sometimes omitted it).
      titan.writePackageList({ "lib/titan.lua", "tetris.lua", "versions.lua" })
    end
    if titan.ensureHostManifest then
      titan.ensureHostManifest({
        role = "Tetris (pocket + music/mesh)",
        run = "tetris.lua",
        files = { "lib/titan.lua", "tetris.lua", "versions.lua" },
      })
    end
    local updated, detail = titan.bootUpdateCheck({
      quiet = false,
      hostOnly = true,
      role = "Tetris (pocket + music/mesh)",
      run = "tetris.lua",
      files = { "lib/titan.lua", "tetris.lua", "versions.lua" },
    })
    if not updated then
      local msg = tostring(detail or "")
      if msg:find("up to date") then
        print("Up to date.")
      elseif msg:find("no install host") or msg:find("check failed") then
        print("Host offline — play without update.")
      elseif msg:find("failed") then
        print("Update skipped: " .. msg)
      else
        print(msg)
      end
    end
  else
    print("lib/titan.lua missing OTA — reinstall role t from host.")
  end

  print("Syncing leaderboard (once)...")
  do
    local det = sanitizeName(detectNearbyPlayer())
    if det then PLAYER_NAME = det; saveCfg() end
  end
  local submit = math.max(tonumber(HI) or 0, tonumber(PENDING_SCORE) or 0)
  local board, err
  if submit > 0 and PLAYER_NAME then
    board, err = syncLeaderboard(submit, PLAYER_NAME)
  else
    board, err = syncLeaderboard(nil, PLAYER_NAME)
  end
  if board then
    print(("Leaderboard: %d player%s — saved locally"):format(
      #board, #board == 1 and "" or "s"))
  else
    print("Leaderboard offline (" .. tostring(err or "?") .. ")")
    if #LEADERBOARD > 0 then
      print("Using cached board.")
    end
  end

  print("Going offline for play...")
  lockNetworkOffline()
  sleep(0.55)
  showQuitDisclaimer()
end

bootCheckUpdates()
attachMonitor()
local okRun, errRun = pcall(mainMenu)
detachMonitor()
pcall(function()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
end)
if not okRun then error(errRun, 0) end
