--[[
  slots.lua  -  3-reel slots for CC: Tweaked
  Titan-Version: 1.0.1

  Run:

      slots
      slots --launcher   (from Games launcher: Close returns, no shutdown)

  Bet coins, spin three reels, win on matching lines. Pocket / advanced PC;
  color monitor gets a tap UI with spinning reels.

  Controls:
    +/- or [ ]   change bet
    Space / SPIN spin
    M mute   Q / CLOSE quit
]]

local CFG = "slots.cfg"
local START_COINS = 100
local MAX_BET = 10

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
local SPEAKER = nil
local MUSIC_ON = true
local COINS = START_COINS
local BEST = START_COINS

-- Symbol weights (higher = more common). Payouts for 3-of-a-kind / 2-of-a-kind.
local SYMBOLS = {
  { id = 1, name = "Cherry", short = "CHY", ch = "C", bg = colors.red,      fg = colors.white, w = 28, pay3 = 3,  pay2 = 1 },
  { id = 2, name = "Lemon",  short = "LEM", ch = "L", bg = colors.yellow,   fg = colors.black, w = 24, pay3 = 4,  pay2 = 0 },
  { id = 3, name = "Bar",    short = "BAR", ch = "=", bg = colors.gray,     fg = colors.white, w = 18, pay3 = 6,  pay2 = 0 },
  { id = 4, name = "Bell",   short = "BEL", ch = "B", bg = colors.orange,   fg = colors.black, w = 14, pay3 = 10, pay2 = 0 },
  { id = 5, name = "Seven",  short = "777", ch = "7", bg = colors.magenta,  fg = colors.white, w = 8,  pay3 = 25, pay2 = 0 },
  { id = 6, name = "Diamond",short = "DIA", ch = "*", bg = colors.lightBlue,fg = colors.white, w = 5,  pay3 = 50, pay2 = 0 },
}

--------------------------------------------------------------------------------
local function isColor()
  local ok, c = pcall(function() return term.isColor and term.isColor() end)
  return ok and c == true
end

local function attachMonitor()
  local m = peripheral.find("monitor")
  if not m then return false end
  local okColor, col = pcall(function() return m.isColor and m.isColor() end)
  if not (okColor and col) then return false end
  pcall(function()
    if m.setTextScale then
      m.setTextScale(1)
      local w, h = m.getSize()
      if w < 28 or h < 14 then m.setTextScale(0.5) end
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
    NATIVE.write("Slots on monitor")
    NATIVE.setCursorPos(1, 2)
    NATIVE.write("Close UI — tap SPIN")
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

local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r")
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return end
  COINS = math.max(0, tonumber(d.coins) or START_COINS)
  BEST = math.max(COINS, tonumber(d.best) or COINS)
  if d.music == false then MUSIC_ON = false end
end

local function saveCfg()
  if COINS > BEST then BEST = COINS end
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize({ coins = COINS, best = BEST, music = MUSIC_ON }))
  f.close()
end

loadCfg()

--------------------------------------------------------------------------------
-- Audio
--------------------------------------------------------------------------------
local function refreshSpeaker()
  SPEAKER = peripheral.find("speaker")
  return SPEAKER ~= nil
end

local function stopMusic()
  if SPEAKER then pcall(function() SPEAKER.stop() end) end
end

local function playSoft(inst, vol, pitch)
  if not SPEAKER or pitch == nil or pitch < 0 or pitch > 24 then return end
  pcall(function() SPEAKER.playNote(inst, vol, pitch) end)
end

local function sfx(kind)
  if not MUSIC_ON or not refreshSpeaker() then return end
  if kind == "tick" then playSoft("hat", 0.18, 12 + math.random(0, 4))
  elseif kind == "stop" then playSoft("pling", 0.28, 10)
  elseif kind == "win" then
    playSoft("chime", 0.45, 20); playSoft("pling", 0.35, 24)
  elseif kind == "big" then
    playSoft("chime", 0.5, 18); playSoft("flute", 0.4, 22); playSoft("pling", 0.4, 24)
  elseif kind == "lose" then playSoft("bass", 0.28, 1)
  elseif kind == "coin" then playSoft("pling", 0.22, 15)
  elseif kind == "spin" then playSoft("hat", 0.25, 8)
  end
end

--------------------------------------------------------------------------------
-- Reels / pay
--------------------------------------------------------------------------------
local WEIGHT_SUM = 0
for i = 1, #SYMBOLS do WEIGHT_SUM = WEIGHT_SUM + SYMBOLS[i].w end

local function rollSymbol()
  local r = math.random(WEIGHT_SUM)
  local acc = 0
  for i = 1, #SYMBOLS do
    acc = acc + SYMBOLS[i].w
    if r <= acc then return i end
  end
  return 1
end

local function payout(a, b, c, bet)
  local sa, sb, sc = SYMBOLS[a], SYMBOLS[b], SYMBOLS[c]
  if a == b and b == c then
    return bet * sa.pay3, ("3x %s!"):format(sa.name), sa.pay3 >= 25
  end
  -- Any two matching cherries (or leftmost pair) for small pay
  if a == b and sa.pay2 > 0 then
    return bet * sa.pay2, ("2x %s"):format(sa.name), false
  end
  if b == c and sb.pay2 > 0 then
    return bet * sb.pay2, ("2x %s"):format(sb.name), false
  end
  if a == c and sa.pay2 > 0 then
    return bet * sa.pay2, ("2x %s"):format(sa.name), false
  end
  return 0, "No win", false
end

--------------------------------------------------------------------------------
-- Draw
--------------------------------------------------------------------------------
local function drawReelWindow(x, y, w, h, symId, blur)
  local color = isColor()
  local border = color and colors.white or colors.lightGray
  fill(x, y, w, h, border)
  fill(x + 1, y + 1, math.max(1, w - 2), math.max(1, h - 2), colors.black)
  if blur then
    local r = SYMBOLS[math.random(#SYMBOLS)]
    local bg = color and r.bg or colors.gray
    fill(x + 1, y + 1, math.max(1, w - 2), math.max(1, h - 2), bg)
    textAt(x + math.max(1, math.floor(w / 2)), y + math.floor(h / 2),
      "?", colors.white, bg)
    return
  end
  local s = SYMBOLS[symId] or SYMBOLS[1]
  local bg = color and s.bg or colors.gray
  local fg = color and s.fg or colors.white
  fill(x + 1, y + 1, math.max(1, w - 2), math.max(1, h - 2), bg)
  local label = (w >= 7) and s.short or s.ch
  textAt(x + math.max(1, math.floor((w - #label) / 2)),
    y + math.floor(h / 2), label:sub(1, w - 2), fg, bg)
  if h >= 5 and w >= 6 then
    textAt(x + 2, y + 2, s.ch, fg, bg)
  end
end

local function drawBtn(b, label, bg, fg)
  fill(b.x, b.y, b.w, b.h, bg)
  local lx = b.x + math.max(0, math.floor((b.w - #label) / 2))
  local ly = b.y + math.floor((b.h - 1) / 2)
  textAt(lx, ly, label:sub(1, b.w), fg or colors.white, bg)
end

local function inBtn(b, mx, my)
  return b and mx >= b.x and mx <= b.x + b.w - 1
    and my >= b.y and my <= b.y + b.h - 1
end

local function drawScreen(state)
  local tw, th = term.getSize()
  local color = isColor()
  fill(1, 1, tw, th, colors.black)

  local hdr = color and colors.purple or colors.gray
  fill(1, 1, tw, 1, hdr)
  textAt(2, 1, " SLOTS ", colors.white, hdr)
  textAt(2, 2, ("Coins:%d  Bet:%d  Best:%d"):format(COINS, state.bet, BEST):sub(1, tw - 2),
    colors.yellow, colors.black)

  -- Three reels
  local reelH = math.max(4, math.min(7, math.floor(th * 0.4)))
  local reelW = math.max(5, math.min(10, math.floor((tw - 8) / 3)))
  local gap = 2
  local total = 3 * reelW + 2 * gap
  local ox = math.max(2, math.floor((tw - total) / 2) + 1)
  local oy = math.max(4, math.floor(th * 0.28))
  state.reelGeom = { ox = ox, oy = oy, w = reelW, h = reelH, gap = gap }

  for i = 1, 3 do
    local rx = ox + (i - 1) * (reelW + gap)
    local spinning = state.spinning and (i > state.stopped)
    local sym = state.reels[i] or 1
    drawReelWindow(rx, oy, reelW, reelH, sym, spinning)
  end

  -- Payline marker
  local midY = oy + math.floor(reelH / 2)
  if color then
    textAt(math.max(1, ox - 1), midY, ">", colors.lime, colors.black)
    textAt(ox + total, midY, "<", colors.lime, colors.black)
  end

  local msgY = oy + reelH + 1
  if state.message then
    local fg = (state.lastWin or 0) > 0 and colors.lime or colors.lightGray
    textAt(2, msgY, tostring(state.message):sub(1, tw - 2), fg, colors.black)
  else
    textAt(2, msgY, "3 Diamonds = 50x   3 Sevens = 25x", colors.gray, colors.black)
  end

  -- Buttons
  local padH = math.max(2, math.min(4, th - (msgY + 1)))
  local by = th - padH + 1
  local bw = math.floor(tw / 4)
  state.btns = {
    minus = { x = 1, y = by, w = bw, h = padH },
    plus  = { x = bw + 1, y = by, w = bw, h = padH },
    spin  = { x = 2 * bw + 1, y = by, w = bw, h = padH },
    quit  = { x = 3 * bw + 1, y = by, w = tw - 3 * bw, h = padH },
  }
  local busy = state.spinning
  drawBtn(state.btns.minus, " -BET ", color and colors.gray or colors.black)
  drawBtn(state.btns.plus, " +BET ", color and colors.gray or colors.black)
  drawBtn(state.btns.spin, busy and " ..." or " SPIN ",
    color and (busy and colors.gray or colors.lime) or colors.white, colors.black)
  drawBtn(state.btns.quit, FROM_LAUNCHER and " CLOSE " or " QUIT ",
    color and colors.red or colors.black)
end

--------------------------------------------------------------------------------
-- Spin animation (cooperative with event loop)
--------------------------------------------------------------------------------
local function beginSpin(state)
  if state.spinning then return false end
  if COINS < state.bet then
    state.message = "Not enough coins!"
    return false
  end
  COINS = COINS - state.bet
  saveCfg()
  state.spinning = true
  state.stopped = 0
  state.reels = { rollSymbol(), rollSymbol(), rollSymbol() }
  state.final = { rollSymbol(), rollSymbol(), rollSymbol() }
  state.ticks = 0
  state.stopAt = { 8, 14, 20 } -- tick counts when each reel locks
  state.message = "Good luck..."
  state.lastWin = 0
  sfx("spin")
  return true
end

local function spinTick(state)
  if not state.spinning then return false end
  state.ticks = state.ticks + 1
  for i = 1, 3 do
    if i > state.stopped then
      state.reels[i] = rollSymbol()
    end
  end
  sfx("tick")
  for i = 1, 3 do
    if state.stopped < i and state.ticks >= state.stopAt[i] then
      state.stopped = i
      state.reels[i] = state.final[i]
      sfx("stop")
    end
  end
  if state.stopped >= 3 then
    state.spinning = false
    local win, msg, big = payout(state.reels[1], state.reels[2], state.reels[3], state.bet)
    state.lastWin = win
    if win > 0 then
      COINS = COINS + win
      state.message = msg .. "  +" .. win
      if big then sfx("big") else sfx("win") end
    else
      state.message = msg
      sfx("lose")
    end
    if COINS <= 0 then
      COINS = START_COINS
      state.message = (state.message or "") .. "  (refilled)"
    end
    saveCfg()
    return false
  end
  return true
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------
local function main()
  attachMonitor()
  refreshSpeaker()
  local state = {
    bet = 1,
    reels = { 1, 2, 3 },
    spinning = false,
    stopped = 3,
    message = "Tap SPIN to play",
    lastWin = 0,
    btns = {},
  }
  local spinTimer = nil
  drawScreen(state)

  while true do
    local ev, p1, p2, p3 = pullEv()
    if ev == "timer" and spinTimer and p1 == spinTimer then
      if spinTick(state) then
        spinTimer = os.startTimer(0.09)
      else
        spinTimer = nil
      end
      drawScreen(state)
    elseif ev == "term_resize" then
      drawScreen(state)
    elseif ev == "mouse_click" then
      if state.spinning then
        -- ignore taps mid-spin
      else
        local b = state.btns
        local mx, my = p2, p3
        if inBtn(b.minus, mx, my) then
          state.bet = math.max(1, state.bet - 1); sfx("coin"); drawScreen(state)
        elseif inBtn(b.plus, mx, my) then
          state.bet = math.min(MAX_BET, state.bet + 1, math.max(1, COINS))
          sfx("coin"); drawScreen(state)
        elseif inBtn(b.spin, mx, my) then
          if beginSpin(state) then
            drawScreen(state)
            spinTimer = os.startTimer(0.09)
          else
            drawScreen(state)
          end
        elseif inBtn(b.quit, mx, my) then
          return
        end
      end
    elseif ev == "key" then
      local K = keys
      if p1 == K.q then return
      elseif p1 == K.m then
        MUSIC_ON = not MUSIC_ON; saveCfg()
        if not MUSIC_ON then stopMusic() end
      elseif not state.spinning then
        if p1 == K.left or p1 == K.minus then
          state.bet = math.max(1, state.bet - 1); drawScreen(state)
        elseif p1 == K.right or p1 == K.equals then
          state.bet = math.min(MAX_BET, state.bet + 1, math.max(1, COINS)); drawScreen(state)
        elseif p1 == K.space or p1 == K.enter then
          if beginSpin(state) then
            drawScreen(state)
            spinTimer = os.startTimer(0.09)
          else
            drawScreen(state)
          end
        end
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "q" then return
      elseif ch == "m" then
        MUSIC_ON = not MUSIC_ON; saveCfg()
        if not MUSIC_ON then stopMusic() end
      elseif not state.spinning and (ch == "+" or ch == "]") then
        state.bet = math.min(MAX_BET, state.bet + 1, math.max(1, COINS)); drawScreen(state)
      elseif not state.spinning and (ch == "-" or ch == "[") then
        state.bet = math.max(1, state.bet - 1); drawScreen(state)
      end
    elseif ev == "terminate" then
      return
    end
  end
end

math.randomseed(os.epoch("utc") % 2147483647)
local ok, err = pcall(main)
stopMusic()
saveCfg()
detachMonitor()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok then error(err, 0) end
