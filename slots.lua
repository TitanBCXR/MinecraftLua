--[[
  slots.lua  -  3-reel slots for CC: Tweaked
  Titan-Version: 1.0.8

  Run:

      slots
      slots --launcher [--managed|--unmanaged]
      slots --speaker --launcher --unmanaged

  Bet chips (no hard cap — only what you have). Buttons ±10 / ±50 / ±100.

  Controls:
    +10/+50/+100 and -10/-50/-100   change bet
    Space / SPIN   spin
    M mute   Q / CLOSE quit
]]

local CFG = "slots.cfg"
local START_COINS = 100

local NATIVE = term.current()
local USING_MONITOR = false
local FROM_LAUNCHER = false
local SPEAKER_ONLY = false
local FORCE_MANAGED = false
local FORCE_UNMANAGED = false
do
  local argv = { ... }
  for i = 1, #argv do
    local s = tostring(argv[i] or ""):lower()
    if s == "--launcher" or s == "launcher" then FROM_LAUNCHER = true end
    if s == "--speaker" or s == "speaker" then SPEAKER_ONLY = true end
    if s == "--managed" or s == "managed" then FORCE_MANAGED = true end
    if s == "--unmanaged" or s == "unmanaged" then FORCE_UNMANAGED = true end
  end
end
local SPEAKER = nil
local MUSIC_ON = true
local COINS = START_COINS
local BEST = START_COINS
local CASINO, USE_CASINO = nil, false
local USE_WALLET = false
local econ = nil
if fs.exists("lib/games_economy.lua") then
  local ok, e = pcall(dofile, "lib/games_economy.lua")
  if ok then econ = e; econ.load() end
end

local gm = nil
if fs.exists("lib/games_music.lua") then
  local ok, lib = pcall(dofile, "lib/games_music.lua")
  if ok and type(lib) == "table" then gm = lib; gm.loadSettings() end
end

local pp = nil
if fs.exists("lib/pocket_peripherals.lua") then
  local ok, lib = pcall(dofile, "lib/pocket_peripherals.lua")
  if ok and type(lib) == "table" then pp = lib end
end

local function equipMusicBack()
  if pp and pp.ensureSpeakerEquipped then pp.ensureSpeakerEquipped(nil) end
end

local function maybeEquipMusicBack()
  if SPEAKER_ONLY or not USE_CASINO or (pp and pp.hasSideModem and pp.hasSideModem()) then
    equipMusicBack()
  end
end

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
  if USE_WALLET and econ then econ.setCoins(COINS) end
end

loadCfg()

local function clampBet(bet)
  local max = math.max(0, COINS)
  if max < 1 then return 1 end
  bet = math.floor(tonumber(bet) or 1)
  if bet < 1 then bet = 1 end
  if bet > max then bet = max end
  return bet
end

local function addBet(state, delta)
  state.bet = clampBet((state.bet or 1) + delta)
end

local function initEconomy()
  local managed = FORCE_MANAGED or (econ and econ.isManaged() and not FORCE_UNMANAGED)
  local unmanaged = FORCE_UNMANAGED or (econ and econ.isUnmanaged() and not FORCE_MANAGED)
  if unmanaged and econ then
    USE_WALLET = true
    local w = econ.getCoins()
    if w == nil then w = econ.ensureWallet(econ.grant, false) end
    COINS = w
    if COINS > BEST then BEST = COINS end
    return
  end
  if managed and not SPEAKER_ONLY and fs.exists("lib/casino.lua") then
    if pp and pp.ensureModemEquipped then pp.ensureModemEquipped(nil) end
    local ok, c = pcall(dofile, "lib/casino.lua")
    if ok and type(c) == "table" then
      CASINO = c
      if CASINO.open and CASINO.open() then
        print("Casino mesh…")
        local bal = CASINO.ensurePlayer()
        if bal ~= nil then
          USE_CASINO = true
          COINS = bal
          local tag = CASINO.detected and "Detected" or "Player"
          print(("%s: %s"):format(tag, tostring(CASINO.player)))
          print(("Chips: %d"):format(COINS))
          sleep(0.6)
          return
        end
      end
    end
  end
end

local function spendBet(n)
  if USE_CASINO and CASINO then
    local ok, err = CASINO.bet(n)
    if not ok then return false, err end
    COINS = CASINO.chips()
    return true
  end
  if COINS < n then return false, "broke" end
  COINS = COINS - n
  if USE_WALLET and econ then econ.setCoins(COINS) end
  return true
end

local function creditWin(n)
  n = math.floor(tonumber(n) or 0)
  if USE_CASINO and CASINO then
    if n > 0 then CASINO.payout(n) end
    COINS = CASINO.chips()
    return
  end
  COINS = COINS + n
  if USE_WALLET and econ then econ.setCoins(COINS) end
end

--------------------------------------------------------------------------------
-- Audio (SFX + optional casino bed from lib/games_music.lua)
--------------------------------------------------------------------------------
local musicPlayer = gm and gm.newPlayer("slots") or nil

local function refreshSpeaker()
  if musicPlayer and musicPlayer.refreshSpeaker then
    SPEAKER = musicPlayer:refreshSpeaker() and peripheral.find("speaker") or nil
  else
    SPEAKER = peripheral.find("speaker")
  end
  return SPEAKER ~= nil
end

local function stopMusic()
  if musicPlayer then musicPlayer:stop() end
  if SPEAKER then pcall(function() SPEAKER.stop() end) end
end

local function playSoft(inst, vol, pitch)
  if not SPEAKER or pitch == nil or pitch < 0 or pitch > 24 then return end
  pcall(function() SPEAKER.playNote(inst, vol, pitch) end)
end

local function musicTick()
  if not MUSIC_ON then return 0.5 end
  if musicPlayer then return musicPlayer:step(MUSIC_ON) end
  return 0.5
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
  local unit = USE_CASINO and "Chips" or "Coins"
  textAt(2, 2, ("%s:%d  Bet:%d  Best:%d"):format(unit, COINS, state.bet, BEST):sub(1, tw - 2),
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

  -- Bet rows (±10/50/100) + action row (SPIN / CLOSE)
  local rows = 3
  local padH = math.max(2, math.min(2, math.floor((th - msgY - 1) / rows)))
  local byM = th - padH * 3 + 1
  local byP = th - padH * 2 + 1
  local byAct = th - padH + 1
  local bw3 = math.floor(tw / 3)
  local bw2 = math.floor(tw / 2)
  state.btns = {
    m100 = { x = 1, y = byM, w = bw3, h = padH },
    m50  = { x = bw3 + 1, y = byM, w = bw3, h = padH },
    m10  = { x = 2 * bw3 + 1, y = byM, w = tw - 2 * bw3, h = padH },
    b10  = { x = 1, y = byP, w = bw3, h = padH },
    b50  = { x = bw3 + 1, y = byP, w = bw3, h = padH },
    b100 = { x = 2 * bw3 + 1, y = byP, w = tw - 2 * bw3, h = padH },
    spin = { x = 1, y = byAct, w = bw2, h = padH },
    quit = { x = bw2 + 1, y = byAct, w = tw - bw2, h = padH },
  }
  local busy = state.spinning
  drawBtn(state.btns.m100, " -100 ", color and colors.brown or colors.black)
  drawBtn(state.btns.m50, " -50 ", color and colors.brown or colors.black)
  drawBtn(state.btns.m10, " -10 ", color and colors.brown or colors.black)
  drawBtn(state.btns.b10, " +10 ", color and colors.gray or colors.black)
  drawBtn(state.btns.b50, " +50 ", color and colors.lightGray or colors.black)
  drawBtn(state.btns.b100, " +100 ", color and colors.white or colors.black, colors.black)
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
  local ok, err = spendBet(state.bet)
  if not ok then
    state.message = USE_CASINO and ("Casino: " .. tostring(err)) or "Not enough coins!"
    return false
  end
  if not USE_CASINO then saveCfg() end
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
      creditWin(win)
      state.message = msg .. "  +" .. win
      if big then sfx("big") else sfx("win") end
    else
      state.message = msg
      sfx("lose")
    end
    if not USE_CASINO then saveCfg() end
    state.bet = clampBet(state.bet)
    return false
  end
  return true
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------
local function main()
  attachMonitor()
  initEconomy()
  maybeEquipMusicBack()
  refreshSpeaker()
  local state = {
    bet = clampBet(1),
    reels = { 1, 2, 3 },
    spinning = false,
    stopped = 3,
    message = "Bet +10/+50/+100 then SPIN",
    lastWin = 0,
    btns = {},
  }
  local spinTimer = nil
  if musicPlayer then musicPlayer:start("menu") end
  local musicTimer = os.startTimer(MUSIC_ON and 0.05 or 3600)
  drawScreen(state)

  while true do
    local ev, p1, p2, p3 = pullEv()
    if ev == "timer" and p1 == musicTimer then
      musicTimer = os.startTimer(musicTick())
    elseif ev == "timer" and spinTimer and p1 == spinTimer then
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
        if inBtn(b.m10, mx, my) then
          addBet(state, -10); sfx("coin"); drawScreen(state)
        elseif inBtn(b.m50, mx, my) then
          addBet(state, -50); sfx("coin"); drawScreen(state)
        elseif inBtn(b.m100, mx, my) then
          addBet(state, -100); sfx("coin"); drawScreen(state)
        elseif inBtn(b.b10, mx, my) then
          addBet(state, 10); sfx("coin"); drawScreen(state)
        elseif inBtn(b.b50, mx, my) then
          addBet(state, 50); sfx("coin"); drawScreen(state)
        elseif inBtn(b.b100, mx, my) then
          addBet(state, 100); sfx("coin"); drawScreen(state)
        elseif inBtn(b.spin, mx, my) then
          state.bet = clampBet(state.bet)
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
        if not MUSIC_ON then stopMusic() else musicTimer = os.startTimer(0.05) end
      elseif not state.spinning then
        if p1 == K.one then addBet(state, 10); drawScreen(state)
        elseif p1 == K.two then addBet(state, 50); drawScreen(state)
        elseif p1 == K.three then addBet(state, 100); drawScreen(state)
        elseif p1 == K.four then addBet(state, -10); drawScreen(state)
        elseif p1 == K.five then addBet(state, -50); drawScreen(state)
        elseif p1 == K.six then addBet(state, -100); drawScreen(state)
        elseif p1 == K.space or p1 == K.enter then
          state.bet = clampBet(state.bet)
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
        if not MUSIC_ON then stopMusic() else musicTimer = os.startTimer(0.05) end
      elseif not state.spinning and ch == "1" then
        addBet(state, 10); drawScreen(state)
      elseif not state.spinning and ch == "2" then
        addBet(state, 50); drawScreen(state)
      elseif not state.spinning and ch == "3" then
        addBet(state, 100); drawScreen(state)
      elseif not state.spinning and ch == "4" then
        addBet(state, -10); drawScreen(state)
      elseif not state.spinning and ch == "5" then
        addBet(state, -50); drawScreen(state)
      elseif not state.spinning and ch == "6" then
        addBet(state, -100); drawScreen(state)
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
