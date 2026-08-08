--[[
  minesweeper.lua  -  Lightweight Minesweeper for CC: Tweaked
  Titan-Version: 1.2.2

  Run:

      minesweeper
      minesweeper --launcher   (from Games launcher: Close returns, no shutdown)

  Works on pocket PCs and advanced computers. If a monitor is attached, the
  game draws there. On monitors the bottom half is a touch bar (Open/Flag mode,
  mute, new, quit) so you can close the computer UI and play from the screen.
  Keys still work on the PC. Color monitors / advanced pockets get colored numbers.

  Music (speaker / Noisy pocket): calm menu bed + tense in-game pulse.
  M mutes. Tiny note-block tracks only (no audio files).

  Controls:
    Mouse / monitor touch  left = open   right = flag (mouse)
    Monitor pad            OPEN/FLAG toggles tap mode on the board
    Keys   arrows move cursor   Space/Enter open   F flag   M mute
           1/2/3 difficulty on menu   N new game   Q quit
]]

local CFG = "mines.cfg"
local BEST = {} -- [diffKey] = best seconds
local MUSIC_ON = true
local NATIVE = term.current()
local USING_MONITOR = false
local FROM_LAUNCHER = false
do
  local argv = { ... }
  for i = 1, #argv do
    local s = tostring(argv[i] or ""):lower()
    if s == "--launcher" or s == "launcher" then FROM_LAUNCHER = true end
  end
end

local DIFFS = {
  { key = "1", name = "Easy",   w = 9,  h = 9,  mines = 10 },
  { key = "2", name = "Medium", w = 12, h = 10, mines = 22 },
  { key = "3", name = "Hard",   w = 16, h = 12, mines = 40 },
}

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
      -- Prefer readable cells; shrink only if the board won't fit.
      if h < 14 or w < 18 then m.setTextScale(0.5) end
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
    NATIVE.write("Minesweeper on monitor")
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

-- Monitor touch -> left click so shared handlers work.
local function pullGameEvent()
  local ev, p1, p2, p3 = os.pullEvent()
  if ev == "monitor_touch" then
    return "mouse_click", 1, p2, p3
  end
  return ev, p1, p2, p3
end

local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r")
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return end
  if type(d.best) == "table" then BEST = d.best end
  if d.music == false then MUSIC_ON = false end
end

local function saveCfg()
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize({ best = BEST, music = MUSIC_ON }))
  f.close()
end

loadCfg()

--------------------------------------------------------------------------------
-- Speaker music (menu + gameplay). No audio files — tiny note tables.
--------------------------------------------------------------------------------
local SPEAKER = nil
local musicIdx = 1
local musicBassPulse = 0
local musicTrackName = "menu"
local TRACKS = {
  -- Soft curious menu bed.
  menu = {
    beat = 0.22,
    legato = 0.82,
    style = "menu",
    bass = { 2, 2, 2, 2, 5, 5, 5, 5, 0, 0, 7, 7, 2, 2, 5, 5 },
    melody = {
      {7, 2}, {9, 2}, {12, 3}, {9, 2}, {7, 2}, {5, 3},
      {false, 1},
      {5, 2}, {7, 2}, {11, 3}, {7, 2}, {5, 2}, {2, 4},
      {false, 2},
      {9, 2}, {12, 2}, {14, 3}, {12, 2}, {9, 2}, {7, 4},
      {false, 2},
    },
  },
  -- Tense in-game pulse (different mood from the menu).
  game = {
    beat = 0.15,
    legato = 0.74,
    style = "game",
    bass = { 0, 0, 3, 3, 5, 5, 3, 3, 0, 0, 7, 7, 5, 5, 3, 3 },
    melody = {
      {12, 1}, {false, 1}, {12, 1}, {11, 1}, {9, 2}, {7, 2},
      {9, 1}, {11, 1}, {12, 2}, {14, 2}, {12, 2},
      {false, 1},
      {14, 1}, {12, 1}, {11, 2}, {9, 2}, {7, 2}, {9, 3},
      {false, 2},
      {7, 1}, {9, 1}, {11, 1}, {12, 2}, {11, 1}, {9, 2}, {7, 3},
      {false, 2},
    },
  },
}

local function refreshSpeaker()
  SPEAKER = peripheral.find("speaker")
  return SPEAKER ~= nil
end

local function stopMusic()
  if SPEAKER then pcall(function() SPEAKER.stop() end) end
end

local function startMusic(trackName)
  trackName = trackName or musicTrackName or "menu"
  if trackName ~= musicTrackName then stopMusic() end
  musicTrackName = trackName
  musicIdx = 1
  musicBassPulse = 0
  return MUSIC_ON and refreshSpeaker()
end

local function playSoft(instrument, volume, pitch)
  if not SPEAKER or pitch == nil or pitch < 0 or pitch > 24 then return end
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
  playSoft("bass", tr.style == "menu" and 0.14 or 0.20, bassPitch)

  if tr.style == "menu" then
    if pitch ~= false and pitch ~= nil then
      playSoft("chime", 0.22, pitch)
      playSoft("guitar", 0.12, math.max(0, pitch - 5))
    else
      playSoft("harp", 0.08, math.min(24, bassPitch + 12))
    end
  else
    -- Sparse tense lead + soft hat tick for "sweeper" feel.
    if pitch ~= false and pitch ~= nil then
      playSoft("pling", 0.28, pitch)
      playSoft("guitar", 0.12, math.max(0, pitch - 7))
    end
    if musicBassPulse % 2 == 0 then
      playSoft("hat", 0.10, 18)
    end
  end

  return math.max(0.06, beats * (tr.beat or 0.16) * (tr.legato or 0.75))
end

local function sfxOpen()
  if MUSIC_ON and refreshSpeaker() then playSoft("hat", 0.18, 14) end
end

local function sfxFlag()
  if MUSIC_ON and refreshSpeaker() then playSoft("snare", 0.16, 8) end
end

local function sfxBoom()
  if MUSIC_ON and refreshSpeaker() then
    playSoft("basedrum", 0.7, 2)
    playSoft("bass", 0.5, 0)
  end
end

local function sfxWin()
  if MUSIC_ON and refreshSpeaker() then
    playSoft("chime", 0.4, 12)
    playSoft("bell", 0.35, 16)
    playSoft("chime", 0.3, 19)
  end
end

local function padHeight(th)
  if not USING_MONITOR or th < 12 then return 0 end
  local padH = math.max(4, math.floor(th / 2))
  if th - padH < 6 then padH = math.max(3, th - 6) end
  return padH
end

local function clampBoard(diff)
  local tw, th = term.getSize()
  local padH = padHeight(th)
  -- Reserve HUD row + footer (or bottom touch pad on monitors).
  local reserved = (padH > 0) and (1 + padH) or 2
  local maxW, maxH = math.max(5, tw), math.max(5, th - reserved)
  local w = math.min(diff.w, maxW)
  local h = math.min(diff.h, maxH)
  -- Large advanced monitors: grow medium/hard toward the board area.
  if maxW >= 28 and maxH >= 10 and diff.key ~= "1" then
    if diff.key == "3" then
      w, h = maxW, maxH
    else
      w = math.min(maxW, math.max(diff.w, math.floor(maxW * 0.7)))
      h = math.min(maxH, math.max(diff.h, math.floor(maxH * 0.7)))
    end
  end
  local cells = w * h
  local density = (diff.key == "3" and 0.18) or (diff.key == "2" and 0.15) or 0.12
  local mines = math.min(
    math.max(diff.mines, math.floor(cells * density)),
    math.max(1, cells - 9))
  return w, h, mines
end

local function touchPadButtons(tw, th, flagMode)
  local padH = padHeight(th)
  if padH < 3 then return {}, 0 end
  local y0 = th - padH + 1
  local bw = math.max(4, math.floor(tw / 4))
  local defs = {
    { "open", flagMode and "OPEN" or ">OPEN<" },
    { "flag", flagMode and ">FLAG<" or "FLAG" },
    { "mute", MUSIC_ON and "MUTE" or "UNMUTE" },
    { "new", "NEW" },
    { "quit", FROM_LAUNCHER and "CLOSE" or "QUIT" },
  }
  -- 2 rows: OPEN FLAG MUTE on top, NEW QUIT on bottom (or 5 across if wide).
  local buttons = {}
  if tw >= 30 then
    local n = #defs
    bw = math.floor(tw / n)
    for i = 1, n do
      local x = (i - 1) * bw + 1
      local w = (i == n) and (tw - x + 1) or bw
      buttons[#buttons + 1] = {
        id = defs[i][1], label = defs[i][2],
        x = x, y = y0, w = w, h = padH,
      }
    end
  else
    local row1 = { defs[1], defs[2], defs[3] }
    local row2 = { defs[4], defs[5] }
    local bh = math.max(1, math.floor(padH / 2))
    for i = 1, #row1 do
      local x = (i - 1) * bw + 1
      local w = (i == #row1) and (tw - x + 1) or bw
      buttons[#buttons + 1] = {
        id = row1[i][1], label = row1[i][2],
        x = x, y = y0, w = w, h = bh,
      }
    end
    local bw2 = math.floor(tw / 2)
    for i = 1, #row2 do
      local x = (i - 1) * bw2 + 1
      local w = (i == #row2) and (tw - x + 1) or bw2
      buttons[#buttons + 1] = {
        id = row2[i][1], label = row2[i][2],
        x = x, y = y0 + bh, w = w,
        h = math.max(1, y0 + padH - (y0 + bh)),
      }
    end
  end
  return buttons, padH
end

local function drawTouchPad(tw, th, flagMode)
  local buttons = touchPadButtons(tw, th, flagMode)
  if #buttons == 0 then return buttons end
  for i = 1, #buttons do
    local b = buttons[i]
    local bg = colors.gray
    if b.id == "open" and not flagMode then bg = colors.lime
    elseif b.id == "flag" and flagMode then bg = colors.orange
    elseif b.id == "quit" then bg = colors.red
    elseif b.id == "mute" and not MUSIC_ON then bg = colors.orange
    elseif b.id == "new" then bg = colors.blue
    end
    for row = b.y, b.y + b.h - 1 do
      if term.setBackgroundColor then term.setBackgroundColor(bg) end
      if term.setTextColor then term.setTextColor(colors.white) end
      term.setCursorPos(b.x, row)
      term.write(string.rep(" ", b.w))
    end
    local label = b.label:sub(1, b.w)
    local lx = b.x + math.max(0, math.floor((b.w - #label) / 2))
    local ly = b.y + math.floor((b.h - 1) / 2)
    if term.setBackgroundColor then term.setBackgroundColor(bg) end
    if term.setTextColor then term.setTextColor(colors.white) end
    term.setCursorPos(lx, ly)
    term.write(label)
  end
  return buttons
end

local function hitTouchPad(buttons, mx, my)
  for i = 1, #buttons do
    local b = buttons[i]
    if mx >= b.x and mx <= b.x + b.w - 1
        and my >= b.y and my <= b.y + b.h - 1 then
      return b.id
    end
  end
  return nil
end

local function idx(x, y, w)
  return (y - 1) * w + x
end

local function inBounds(x, y, w, h)
  return x >= 1 and y >= 1 and x <= w and y <= h
end

local function neighbors(x, y, w, h)
  local out = {}
  for dy = -1, 1 do
    for dx = -1, 1 do
      if not (dx == 0 and dy == 0) then
        local nx, ny = x + dx, y + dy
        if inBounds(nx, ny, w, h) then
          out[#out + 1] = { nx, ny }
        end
      end
    end
  end
  return out
end

local function newGrid(w, h)
  local g = {}
  for i = 1, w * h do
    g[i] = { mine = false, open = false, flag = false, n = 0 }
  end
  return g
end

local function placeMines(grid, w, h, mines, safeX, safeY)
  local forbidden = {}
  for _, p in ipairs(neighbors(safeX, safeY, w, h)) do
    forbidden[idx(p[1], p[2], w)] = true
  end
  forbidden[idx(safeX, safeY, w)] = true
  local placed = 0
  local guard = 0
  while placed < mines and guard < 10000 do
    guard = guard + 1
    local x = math.random(1, w)
    local y = math.random(1, h)
    local i = idx(x, y, w)
    if not forbidden[i] and not grid[i].mine then
      grid[i].mine = true
      placed = placed + 1
    end
  end
  for y = 1, h do
    for x = 1, w do
      local i = idx(x, y, w)
      if not grid[i].mine then
        local c = 0
        for _, p in ipairs(neighbors(x, y, w, h)) do
          if grid[idx(p[1], p[2], w)].mine then c = c + 1 end
        end
        grid[i].n = c
      end
    end
  end
end

local function floodOpen(grid, w, h, x, y)
  local stack = { { x, y } }
  while #stack > 0 do
    local cur = table.remove(stack)
    local cx, cy = cur[1], cur[2]
    if inBounds(cx, cy, w, h) then
      local cell = grid[idx(cx, cy, w)]
      if not cell.open and not cell.flag and not cell.mine then
        cell.open = true
        if cell.n == 0 then
          for _, p in ipairs(neighbors(cx, cy, w, h)) do
            stack[#stack + 1] = p
          end
        end
      end
    end
  end
end

local function countFlags(grid)
  local n = 0
  for i = 1, #grid do if grid[i].flag then n = n + 1 end end
  return n
end

local function won(grid)
  for i = 1, #grid do
    local c = grid[i]
    if not c.mine and not c.open then return false end
  end
  return true
end

local NUM_FG = {
  [1] = colors.blue,
  [2] = colors.green,
  [3] = colors.red,
  [4] = colors.purple,
  [5] = colors.brown,
  [6] = colors.cyan,
  [7] = colors.black,
  [8] = colors.gray,
}

local function drawGame(state)
  local tw, th = term.getSize()
  local color = isColor()
  term.setBackgroundColor(colors.black)
  term.clear()

  local left = state.mines - countFlags(state.grid)
  local elapsed = math.floor((os.clock() - state.t0))
  if state.over then elapsed = state.finalTime or elapsed end
  local mode = state.flagMode and "FLAG" or "OPEN"
  local hud = ("Mines %-3d  Time %-4d  %s  %s"):format(
    left, elapsed, state.diff.name, USING_MONITOR and mode or "")
  if term.setTextColor then term.setTextColor(colors.white) end
  term.setCursorPos(1, 1)
  term.write(hud:sub(1, tw))

  for y = 1, state.h do
    for x = 1, state.w do
      local cell = state.grid[idx(x, y, state.w)]
      local ch, fg, bg = "?", colors.white, colors.gray
      if cell.open then
        bg = colors.lightGray
        if cell.mine then
          ch, fg, bg = "*", colors.white, colors.red
        elseif cell.n == 0 then
          ch, fg = " ", colors.lightGray
        else
          ch = tostring(cell.n)
          fg = (color and NUM_FG[cell.n]) or colors.white
        end
      elseif cell.flag then
        ch, fg, bg = "F", colors.white, colors.orange
      else
        ch, fg, bg = "#", colors.white, colors.gray
      end
      if state.cursorX == x and state.cursorY == y and not state.over then
        bg = colors.yellow
        if fg == colors.white then fg = colors.black end
      end
      if color then
        term.setBackgroundColor(bg)
        term.setTextColor(fg)
      end
      term.setCursorPos(x, y + 1)
      term.write(ch)
    end
  end

  if color then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
  end

  state.buttons = drawTouchPad(tw, th, state.flagMode)
  if #(state.buttons or {}) == 0 then
    local foot = USING_MONITOR
      and "Touch open  F flag  M mute  N new  Q"
      or "Spc open  F flag  M mute  N new  Q"
    if state.over then
      foot = state.won and "Cleared!  N new  Q menu" or "Boom!  N new  Q menu"
    end
    term.setCursorPos(1, th)
    term.write(foot:sub(1, tw))
  end
end

local function openCell(state, x, y)
  if state.over then return end
  if not inBounds(x, y, state.w, state.h) then return end
  local cell = state.grid[idx(x, y, state.w)]
  if cell.open or cell.flag then return end

  if not state.started then
    placeMines(state.grid, state.w, state.h, state.mines, x, y)
    state.started = true
    state.t0 = os.clock()
  end

  if cell.mine then
    cell.open = true
    state.over = true
    state.won = false
    state.finalTime = math.floor(os.clock() - state.t0)
    stopMusic()
    sfxBoom()
    -- Reveal all mines.
    for i = 1, #state.grid do
      if state.grid[i].mine then state.grid[i].open = true end
    end
    return
  end

  floodOpen(state.grid, state.w, state.h, x, y)
  sfxOpen()
  if won(state.grid) then
    state.over = true
    state.won = true
    state.finalTime = math.floor(os.clock() - state.t0)
    stopMusic()
    sfxWin()
    local prev = tonumber(BEST[state.diff.key])
    if not prev or state.finalTime < prev then
      BEST[state.diff.key] = state.finalTime
      saveCfg()
    end
    for i = 1, #state.grid do
      if state.grid[i].mine then state.grid[i].flag = true end
    end
  end
end

local function toggleFlag(state, x, y)
  if state.over then return end
  if not inBounds(x, y, state.w, state.h) then return end
  local cell = state.grid[idx(x, y, state.w)]
  if cell.open then return end
  cell.flag = not cell.flag
  sfxFlag()
end

local function newState(diff)
  local w, h, mines = clampBoard(diff)
  return {
    diff = diff,
    w = w, h = h, mines = mines,
    grid = newGrid(w, h),
    cursorX = math.floor((w + 1) / 2),
    cursorY = math.floor((h + 1) / 2),
    started = false,
    over = false,
    won = false,
    t0 = os.clock(),
    finalTime = nil,
    flagMode = false,
    buttons = {},
  }
end

local function drainInput()
  local t = os.startTimer(0)
  while true do
    local ev, p1 = os.pullEvent()
    if ev == "timer" and p1 == t then return end
  end
end

local function runGame(diff)
  local state = newState(diff)
  local tick = os.startTimer(0.5)
  startMusic("game")
  local musicTimer = os.startTimer(MUSIC_ON and refreshSpeaker() and 0.05 or 3600)

  local function toggleMute()
    MUSIC_ON = not MUSIC_ON
    saveCfg()
    if MUSIC_ON and not state.over then
      startMusic("game")
      musicTimer = os.startTimer(0.05)
    else
      stopMusic()
    end
    drawGame(state)
  end

  local function newRound()
    local keepFlag = state.flagMode
    state = newState(diff)
    state.flagMode = keepFlag
    startMusic("game")
    musicTimer = os.startTimer(MUSIC_ON and 0.05 or 3600)
    drawGame(state)
  end

  local function padAction(id)
    if not id then return false end
    if id == "open" then
      state.flagMode = false; drawGame(state)
    elseif id == "flag" then
      state.flagMode = true; drawGame(state)
    elseif id == "mute" then
      toggleMute()
    elseif id == "new" then
      newRound()
    elseif id == "quit" then
      stopMusic()
      drainInput()
      return true
    end
    return false
  end

  drawGame(state)
  while true do
    local ev, p1, p2, p3 = pullGameEvent()
    if ev == "timer" and p1 == musicTimer then
      if MUSIC_ON and not state.over then
        musicTimer = os.startTimer(musicStepSeconds())
      else
        musicTimer = os.startTimer(0.4)
      end
    elseif ev == "timer" and p1 == tick then
      if not state.over then drawGame(state) end
      tick = os.startTimer(0.5)
    elseif ev == "term_resize" or ev == "monitor_resize" then
      drawGame(state)
    elseif ev == "mouse_click" then
      local btn, mx, my = p1, p2, p3
      local padId = hitTouchPad(state.buttons, mx, my)
      if padId then
        if padAction(padId) then return end
      else
        local x, y = mx, my - 1
        if inBounds(x, y, state.w, state.h) then
          state.cursorX, state.cursorY = x, y
          if btn == 2 or (btn == 1 and state.flagMode) then
            toggleFlag(state, x, y)
          else
            openCell(state, x, y)
          end
          drawGame(state)
        end
      end
    elseif ev == "key" then
      local K = keys
      if p1 == K.up then
        state.cursorY = math.max(1, state.cursorY - 1); drawGame(state)
      elseif p1 == K.down then
        state.cursorY = math.min(state.h, state.cursorY + 1); drawGame(state)
      elseif p1 == K.left then
        state.cursorX = math.max(1, state.cursorX - 1); drawGame(state)
      elseif p1 == K.right then
        state.cursorX = math.min(state.w, state.cursorX + 1); drawGame(state)
      elseif p1 == K.space or p1 == K.enter then
        openCell(state, state.cursorX, state.cursorY); drawGame(state)
      elseif p1 == K.f then
        toggleFlag(state, state.cursorX, state.cursorY); drawGame(state)
      elseif p1 == K.m then
        toggleMute()
      elseif p1 == K.n then
        newRound()
      elseif p1 == K.q or p1 == K.backspace then
        stopMusic()
        drainInput()
        return
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "f" then
        toggleFlag(state, state.cursorX, state.cursorY); drawGame(state)
      elseif ch == "m" then
        toggleMute()
      elseif ch == "n" then
        newRound()
      elseif ch == "q" then
        stopMusic()
        drainInput()
        return
      end
    elseif ev == "terminate" then
      stopMusic()
      return
    end
  end
end

local function drawMenu(sel)
  local tw, th = term.getSize()
  local color = isColor()
  term.setBackgroundColor(colors.black)
  term.clear()
  if color then
    term.setBackgroundColor(colors.lime)
    term.setTextColor(colors.black)
    term.setCursorPos(1, 1)
    term.clearLine()
    term.write(" MINESWEEPER ")
    term.setBackgroundColor(colors.black)
  else
    term.setCursorPos(1, 1)
    term.write("MINESWEEPER")
  end

  local y = 3
  if term.setTextColor then term.setTextColor(colors.white) end
  for i, d in ipairs(DIFFS) do
    local w, h, mines = clampBoard(d)
    local best = BEST[d.key]
    local bestTxt = best and (tostring(best) .. "s") or "--"
    local mark = (sel == i) and ">" or " "
    local line = ("%s %s  %dx%d %d mines  best %s"):format(
      mark, d.name, w, h, mines, bestTxt)
    if color and sel == i then term.setTextColor(colors.yellow)
    elseif color then term.setTextColor(colors.lightGray) end
    term.setCursorPos(2, y)
    term.write(line:sub(1, tw - 2))
    y = y + 1
  end

  if color then term.setTextColor(colors.gray) end
  term.setCursorPos(2, th)
  term.write("1-3 play   M mute   Q quit")
end

local function mainMenu()
  local sel = 1
  startMusic("menu")
  local musicTimer = os.startTimer(MUSIC_ON and refreshSpeaker() and 0.05 or 3600)

  local function resumeMenuMusic()
    startMusic("menu")
    musicTimer = os.startTimer(MUSIC_ON and SPEAKER and 0.05 or 3600)
  end

  local function playDiff(diff)
    stopMusic()
    runGame(diff)
    resumeMenuMusic()
  end

  while true do
    drawMenu(sel)
    local ev, p1, p2, p3 = pullGameEvent()
    if ev == "timer" and p1 == musicTimer then
      if MUSIC_ON then
        musicTimer = os.startTimer(musicStepSeconds())
      else
        musicTimer = os.startTimer(0.5)
      end
    elseif ev == "key" then
      if p1 == keys.up then sel = sel > 1 and sel - 1 or #DIFFS
      elseif p1 == keys.down then sel = sel < #DIFFS and sel + 1 or 1
      elseif p1 == keys.enter or p1 == keys.space then
        playDiff(DIFFS[sel])
      elseif p1 == keys.one then playDiff(DIFFS[1])
      elseif p1 == keys.two then playDiff(DIFFS[2])
      elseif p1 == keys.three then playDiff(DIFFS[3])
      elseif p1 == keys.m then
        MUSIC_ON = not MUSIC_ON
        saveCfg()
        if MUSIC_ON then resumeMenuMusic() else stopMusic() end
      elseif p1 == keys.q or p1 == keys.backspace then
        stopMusic()
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
        return
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "1" then playDiff(DIFFS[1])
      elseif ch == "2" then playDiff(DIFFS[2])
      elseif ch == "3" then playDiff(DIFFS[3])
      elseif ch == "m" then
        MUSIC_ON = not MUSIC_ON
        saveCfg()
        if MUSIC_ON then resumeMenuMusic() else stopMusic() end
      elseif ch == "q" then
        stopMusic()
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
        return
      end
    elseif ev == "mouse_click" then
      -- Tap a difficulty row (y=3..5).
      local y = p3
      if y >= 3 and y <= 2 + #DIFFS then
        playDiff(DIFFS[y - 2])
      end
    elseif ev == "term_resize" or ev == "monitor_resize" then
      -- redraw
    elseif ev == "terminate" then
      stopMusic()
      return
    end
  end
end

math.randomseed(os.epoch("utc") % 2147483647)
attachMonitor()
local ok, err = pcall(mainMenu)
stopMusic()
detachMonitor()
if not ok then error(err, 0) end
