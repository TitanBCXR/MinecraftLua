--[[
  minesweeper.lua  -  Lightweight Minesweeper for CC: Tweaked
  Titan-Version: 1.1.0

  Run:

      minesweeper

  Works on pocket PCs and advanced computers. If a monitor is attached, the
  game draws there (keys still work on the computer). Color monitors / advanced
  pockets get colored numbers.

  Controls:
    Mouse / monitor touch  left = open   right = flag (mouse)
    Keys   arrows move cursor   Space/Enter open   F flag
           1/2/3 difficulty on menu   N new game   Q quit
]]

local CFG = "mines.cfg"
local BEST = {} -- [diffKey] = best seconds
local NATIVE = term.current()
local USING_MONITOR = false

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
    NATIVE.write("Keys work on this PC")
    NATIVE.setCursorPos(1, 3)
    NATIVE.write("Touch=open  F=flag")
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
  if type(d) == "table" and type(d.best) == "table" then BEST = d.best end
end

local function saveCfg()
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize({ best = BEST }))
  f.close()
end

loadCfg()

local function clampBoard(diff)
  local tw, th = term.getSize()
  -- Reserve 2 rows for HUD / footer.
  local maxW, maxH = math.max(5, tw), math.max(5, th - 2)
  local w = math.min(diff.w, maxW)
  local h = math.min(diff.h, maxH)
  -- Large advanced monitors: grow medium/hard toward the screen.
  if maxW >= 28 and maxH >= 16 and diff.key ~= "1" then
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
  local hud = ("Mines %-3d  Time %-4d  %s"):format(
    left, elapsed, state.diff.name)
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
  local foot = USING_MONITOR
    and "Touch open  F flag  N new  Q menu"
    or "Spc/click open  F flag  N new  Q menu"
  if state.over then
    foot = state.won and "Cleared!  N new  Q menu" or "Boom!  N new  Q menu"
  end
  term.setCursorPos(1, th)
  term.write(foot:sub(1, tw))
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
    -- Reveal all mines.
    for i = 1, #state.grid do
      if state.grid[i].mine then state.grid[i].open = true end
    end
    return
  end

  floodOpen(state.grid, state.w, state.h, x, y)
  if won(state.grid) then
    state.over = true
    state.won = true
    state.finalTime = math.floor(os.clock() - state.t0)
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
  if state.over or not state.started then
    -- Allow flags before first open too.
  end
  if state.over then return end
  if not inBounds(x, y, state.w, state.h) then return end
  local cell = state.grid[idx(x, y, state.w)]
  if cell.open then return end
  cell.flag = not cell.flag
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
  drawGame(state)
  while true do
    local ev, p1, p2, p3 = pullGameEvent()
    if ev == "timer" and p1 == tick then
      if not state.over then drawGame(state) end
      tick = os.startTimer(0.5)
    elseif ev == "term_resize" or ev == "monitor_resize" then
      drawGame(state)
    elseif ev == "mouse_click" then
      local btn, mx, my = p1, p2, p3
      local x, y = mx, my - 1
      if inBounds(x, y, state.w, state.h) then
        state.cursorX, state.cursorY = x, y
        if btn == 1 then openCell(state, x, y)
        elseif btn == 2 then toggleFlag(state, x, y) end
        drawGame(state)
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
      elseif p1 == K.n then
        state = newState(diff); drawGame(state)
      elseif p1 == K.q or p1 == K.backspace then
        drainInput()
        return
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "f" then
        toggleFlag(state, state.cursorX, state.cursorY); drawGame(state)
      elseif ch == "n" then
        state = newState(diff); drawGame(state)
      elseif ch == "q" then
        drainInput()
        return
      end
    elseif ev == "terminate" then
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
  term.write("1-3 / Enter play   Q quit")
end

local function mainMenu()
  local sel = 1
  while true do
    drawMenu(sel)
    local ev, p1, p2, p3 = pullGameEvent()
    if ev == "key" then
      if p1 == keys.up then sel = sel > 1 and sel - 1 or #DIFFS
      elseif p1 == keys.down then sel = sel < #DIFFS and sel + 1 or 1
      elseif p1 == keys.enter or p1 == keys.space then
        runGame(DIFFS[sel])
      elseif p1 == keys.one then runGame(DIFFS[1])
      elseif p1 == keys.two then runGame(DIFFS[2])
      elseif p1 == keys.three then runGame(DIFFS[3])
      elseif p1 == keys.q or p1 == keys.backspace then
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
        return
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "1" then runGame(DIFFS[1])
      elseif ch == "2" then runGame(DIFFS[2])
      elseif ch == "3" then runGame(DIFFS[3])
      elseif ch == "q" then
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
        return
      end
    elseif ev == "mouse_click" then
      -- Tap a difficulty row (y=3..5).
      local y = p3
      if y >= 3 and y <= 2 + #DIFFS then
        runGame(DIFFS[y - 2])
      end
    elseif ev == "term_resize" or ev == "monitor_resize" then
      -- redraw
    elseif ev == "terminate" then
      return
    end
  end
end

math.randomseed(os.epoch("utc") % 2147483647)
attachMonitor()
local ok, err = pcall(mainMenu)
detachMonitor()
if not ok then error(err, 0) end
