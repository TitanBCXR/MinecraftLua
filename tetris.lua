--[[
  tetris.lua  -  Standalone Tetris for CC: Tweaked (pocket / computer)
  Titan-Version: 1.0.3

  Drop on a pocket PC and run:

      tetris

  Main menu → Play. Q returns to the menu (or exits from the menu).

  Hidden Titan mesh (optional): if lib/titan.lua + a wireless modem are present,
  this joins your rednet mesh in the background — SSH + GPS beacons. No on-screen
  network chrome.

  Boot updates are HOST-ONLY over rednet (run host.lua on your update server).
  Tablets never store a GitHub / wget URL — only source=host in .titan-install.

  Install role `t` via install.lua (from host/disk). Keep host.lua online for OTAs.

  Controls (in game):
    ← / A / H     move left
    → / D / L     move right
    ↑ / W / K / X rotate
    ↓ / S / J     soft drop
    Space / Enter hard drop
    P             pause
    Q             quit to menu

  Color pocket: colored pieces. Mono: letter blocks.
]]

local CFG = "tetris.cfg"
local COLS, ROWS = 10, 18
local KIND = "tetris"

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

local function isColor()
  local ok, c = pcall(function() return term.isColor and term.isColor() end)
  return ok and c == true
end

local function loadHi()
  if not fs.exists(CFG) then return 0 end
  local f = fs.open(CFG, "r")
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) == "table" then return tonumber(d.hi) or 0 end
  return 0
end

local function saveHi(hi)
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize({ hi = hi }))
  f.close()
end

local HI = loadHi()

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
  local cellW = 1
  local boardW = COLS * cellW + 2 -- borders
  local boardH = ROWS + 2
  -- Shrink visible rows if screen is short (still play full logic; scroll top)
  local visRows = math.min(ROWS, th - 2)
  local ox = math.max(1, math.floor((tw - boardW - 12) / 2))
  if tw < boardW + 10 then ox = 1 end
  local oy = math.max(1, math.floor((th - (visRows + 2)) / 2))
  return {
    tw = tw, th = th, ox = ox, oy = oy,
    cellW = cellW, boardW = boardW, visRows = visRows,
    color = isColor(),
  }
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

  -- Side panel
  local px = L.ox + bw + 3
  if px + 8 > L.tw then px = math.max(1, L.tw - 9) end
  local py = L.oy
  text(px, py, "TETRIS", L.color and colors.cyan or colors.white, colors.black)
  text(px, py + 2, "SCORE", colors.lightGray, colors.black)
  text(px, py + 3, tostring(score), colors.white, colors.black)
  text(px, py + 5, "HI", colors.lightGray, colors.black)
  text(px, py + 6, tostring(math.max(HI, score)), colors.yellow, colors.black)
  text(px, py + 8, "LV " .. tostring(level), colors.lime, colors.black)
  text(px, py + 9, "LN " .. tostring(lines), colors.lightGray, colors.black)
  text(px, py + 11, "NEXT", colors.lightGray, colors.black)
  if nextKind then
    if L.color then
      fill(px, py + 12, 4, 2, PIECE_COLOR[nextKind] or colors.white, colors.black)
      text(px, py + 12, " " .. nextKind .. " ", colors.black, PIECE_COLOR[nextKind] or colors.white)
    else
      text(px, py + 12, nextKind, colors.white, colors.black)
    end
  end

  if paused then
    text(L.ox + 2, L.oy + math.floor(L.visRows / 2), " PAUSED ", colors.black, colors.yellow)
  end
  if over then
    text(L.ox + 1, L.oy + math.floor(L.visRows / 2), " GAME OVER ", colors.white, colors.red)
    text(L.ox + 1, L.oy + math.floor(L.visRows / 2) + 1, " Enter/Q ", colors.black, colors.white)
  end

  if L.th >= L.oy + L.visRows + 3 then
    text(1, L.th, "Arrows move  Up rotate  Spc drop  P pause  Q menu",
      colors.gray, colors.black)
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

  while true do
    TRACK.score, TRACK.level, TRACK.lines = score, level, lines
    if dirty then
      nextPeek = bag[1]
      drawBoard(L, grid, piece, nextPeek, score, level, lines, paused, over)
      dirty = false
    end

    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "term_resize" then
      L = layout()
      dirty = true
    elseif ev == "timer" and p1 == dropTimer then
      if not paused and not over and piece then
        if fits(grid, piece.kind, piece.rot, piece.x, piece.y + 1) then
          piece.y = piece.y + 1
        else
          lock(grid, piece.kind, piece.rot, piece.x, piece.y)
          local n = clearLines(grid)
          if n > 0 then
            score = score + lineScore(n, level)
            lines = lines + n
            level = math.floor(lines / 10)
            if score > HI then HI = score; saveHi(HI) end
          end
          piece, bag = spawn(grid, bag)
          if not piece then over = true end
        end
        dirty = true
      end
      if not over then
        dropTimer = os.startTimer(gravityMs(level) / 1000)
      end
    elseif ev == "key" and not over then
      local k = p1
      local K = keys
      if k == K.p then
        paused = not paused
        dirty = true
        if not paused then
          dropTimer = os.startTimer(gravityMs(level) / 1000)
        end
      elseif k == K.q then
        TRACK.playing = false
        TRACK.score = score
        return score
      elseif not paused and piece then
        if k == K.left or k == K.a or k == K.h then
          if fits(grid, piece.kind, piece.rot, piece.x - 1, piece.y) then
            piece.x = piece.x - 1; dirty = true
          end
        elseif k == K.right or k == K.d or k == K.l then
          if fits(grid, piece.kind, piece.rot, piece.x + 1, piece.y) then
            piece.x = piece.x + 1; dirty = true
          end
        elseif k == K.up or k == K.w or k == K.k or k == K.x then
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
        elseif k == K.down or k == K.s or k == K.j then
          if fits(grid, piece.kind, piece.rot, piece.x, piece.y + 1) then
            piece.y = piece.y + 1
            score = score + 1
            dirty = true
          end
        elseif k == K.space or k == K.enter then
          local dropped = 0
          while fits(grid, piece.kind, piece.rot, piece.x, piece.y + 1) do
            piece.y = piece.y + 1
            dropped = dropped + 1
          end
          score = score + dropped * 2
          lock(grid, piece.kind, piece.rot, piece.x, piece.y)
          local n = clearLines(grid)
          if n > 0 then
            score = score + lineScore(n, level)
            lines = lines + n
            level = math.floor(lines / 10)
          end
          if score > HI then HI = score; saveHi(HI) end
          piece, bag = spawn(grid, bag)
          if not piece then over = true end
          dirty = true
          dropTimer = os.startTimer(gravityMs(level) / 1000)
        end
      end
    elseif ev == "key" and over then
      if p1 == keys.enter or p1 == keys.q or p1 == keys.space then
        if score > HI then HI = score; saveHi(HI) end
        TRACK.playing = false
        TRACK.score = score
        return score
      end
    elseif ev == "char" and not over then
      local ch = tostring(p1 or ""):lower()
      if ch == "q" then
        TRACK.playing = false
        TRACK.score = score
        return score
      end
      if ch == "p" then
        paused = not paused
        dirty = true
      end
    elseif ev == "terminate" then
      TRACK.playing = false
      TRACK.score = score
      return score
    end
  end
end

--------------------------------------------------------------------------------
-- Main menu
--------------------------------------------------------------------------------
local function drawMenu(playBtn)
  local tw, th = term.getSize()
  local color = isColor()
  clearScreen(colors.black)

  local title = "TETRIS"
  local accent = color and colors.cyan or colors.white
  local headerH = 3
  fill(1, 1, tw, headerH, accent, colors.black)
  text(math.max(2, math.floor((tw - #title) / 2) + 1), 2, title, colors.black, accent)

  text(math.max(2, math.floor((tw - 14) / 2) + 1), headerH + 2,
    "Pocket edition", colors.lightGray, colors.black)
  text(math.max(2, math.floor((tw - 12) / 2) + 1), headerH + 3,
    "Hi  " .. tostring(HI), colors.yellow, colors.black)

  local label = "  PLAY  "
  local bx = math.max(2, math.floor((tw - #label) / 2) + 1)
  local by = math.min(th - 3, headerH + 6)
  local btnBg = color and colors.lime or colors.white
  fill(bx, by, #label, 1, btnBg, colors.black)
  text(bx, by, label, colors.black, btnBg)
  playBtn.x, playBtn.y, playBtn.w, playBtn.h = bx, by, #label, 1

  text(2, th - 1, "Enter / click Play", colors.gray, colors.black)
  text(2, th, "Q quit", colors.gray, colors.black)
end

local function mainMenu()
  local playBtn = {}
  while true do
    drawMenu(playBtn)
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "key" then
      if p1 == keys.enter or p1 == keys.space or p1 == keys.p then
        local score = runGame()
        if score and score > HI then HI = score; saveHi(HI) end
      elseif p1 == keys.q then
        clearScreen(colors.black)
        term.setCursorPos(1, 1)
        print("Bye.")
        return
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "q" then
        clearScreen(colors.black)
        term.setCursorPos(1, 1)
        print("Bye.")
        return
      elseif ch == "p" then
        local score = runGame()
        if score and score > HI then HI = score; saveHi(HI) end
      end
    elseif ev == "mouse_click" then
      local x, y = p2, p3
      if x >= playBtn.x and x < playBtn.x + playBtn.w
          and y >= playBtn.y and y < playBtn.y + playBtn.h then
        local score = runGame()
        if score and score > HI then HI = score; saveHi(HI) end
      end
    elseif ev == "term_resize" then
      -- redraw next loop
    elseif ev == "terminate" then
      clearScreen(colors.black)
      return
    end
  end
end

--------------------------------------------------------------------------------
-- Hidden Titan mesh tracker (SSH + GPS beacons). Silent if offline.
--------------------------------------------------------------------------------
local function sendTrackerBeacon()
  if not titan then return end
  local host = titan.hostname and titan.hostname(KIND) or (os.getComputerLabel() or ("Tetris-" .. os.getComputerID()))
  local msg = {
    type = "hello",
    kind = KIND,
    name = host,
    hostname = host,
    mainRouterId = titan.getMainRouterId and titan.getMainRouterId() or nil,
    version = titan.systemVersion and titan.systemVersion() or "1.0.3",
    game = "tetris",
    playing = TRACK.playing and true or false,
    score = TRACK.score,
    hi = HI,
    level = TRACK.level,
    lines = TRACK.lines,
    x = TRACK.x, y = TRACK.y, z = TRACK.z,
    from = os.getComputerID(),
  }
  local proto = titan.ROUTER_PROTOCOL or "titan_router"
  local mainId = titan.getMainRouterId and titan.getMainRouterId()
  if mainId then
    rednet.send(mainId, msg, proto)
  else
    rednet.broadcast(msg, proto)
  end
end

local function trackerLoop()
  if not titan then
    while true do sleep(3600) end
  end
  if titan.netJitter then titan.netJitter(1.2) end
  while true do
    local x, y, z = gps.locate(1.5)
    if x then
      TRACK.x = math.floor(x + 0.5)
      TRACK.y = math.floor(y + 0.5)
      TRACK.z = math.floor(z + 0.5)
      TRACK.fixAt = os.epoch("utc")
    end
    pcall(sendTrackerBeacon)
    -- Light cadence; registerLoop also announces without GPS.
    local id = os.getComputerID() or 0
    sleep(18 + ((id % 7)))
  end
end

local function setupMesh()
  if not titan then return false end
  pcall(function()
    if titan.openModem then titan.openModem() end
  end)
  if not os.getComputerLabel() or os.getComputerLabel() == "" then
    os.setComputerLabel("Tetris-" .. os.getComputerID())
  end
  if titan.setSshHandler then
    titan.setSshHandler(function(line)
      local cmd = tostring(line or ""):lower():match("^%s*(%S*)") or ""
      if cmd == "status" or cmd == "where" or cmd == "pos" or cmd == "track" then
        local pos = (TRACK.x and ("%d,%d,%d"):format(TRACK.x, TRACK.y, TRACK.z)) or "(no GPS)"
        print(("Tetris #%d  %s"):format(os.getComputerID(), os.getComputerLabel() or "?"))
        print(("pos %s"):format(pos))
        print(("playing=%s  score=%d  hi=%d  lv=%d  lines=%d"):format(
          TRACK.playing and "yes" or "no",
          tonumber(TRACK.score) or 0, tonumber(HI) or 0,
          tonumber(TRACK.level) or 0, tonumber(TRACK.lines) or 0))
        local mainId = titan.getMainRouterId and titan.getMainRouterId()
        print(("main #%s"):format(tostring(mainId or "?")))
        return true
      elseif cmd == "hi" or cmd == "hiscore" then
        print("hi-score " .. tostring(HI))
        return true
      elseif cmd == "help" then
        print("tetris ssh: status | where | hi | update | reboot | exit")
        return true
      end
      return false -- fall through (update / shell)
    end)
  end
  return true
end

math.randomseed(os.epoch("utc") % 2147483647)

-- Boot update check before the menu — rednet install host only (no URL on disk).
local function bootCheckUpdates()
  if not titan or not titan.bootUpdateCheck then return end
  clearScreen(colors.black)
  term.setCursorPos(1, 1)
  if term.setTextColor then term.setTextColor(colors.lightGray) end
  print("Tetris")
  print("Checking for updates...")
  if titan.openModem then pcall(titan.openModem) end
  if titan.writePackageList and not titan.readPackageList() then
    titan.writePackageList({ "lib/titan.lua", "tetris.lua", "versions.lua" })
  end
  local updated, detail = titan.bootUpdateCheck({
    quiet = false,
    hostOnly = true,
    role = "Tetris (pocket game + mesh tracker)",
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
    sleep(0.6)
  end
end

bootCheckUpdates()

if setupMesh() then
  parallel.waitForAny(
    function() titan.networkLoop(KIND) end,
    trackerLoop,
    mainMenu
  )
  clearScreen(colors.black)
  term.setCursorPos(1, 1)
else
  mainMenu()
end
