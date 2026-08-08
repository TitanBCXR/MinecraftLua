--[[
  luigi_poker.lua  -  Luigi Picture Poker (SMB3-style) for CC: Tweaked
  Titan-Version: 1.2.0

  Run:

      luigi_poker

  Beat Luigi: he shows a 5-card hand you must beat. Hold/draw once, then
  compare. Win pays 2x (or more if you also hit a bonus hand). Push returns
  the bet. Pocket-first tap UI; desk PCs may use a color monitor.

  Cards (low → high): Cloud  Mushroom  Flower  Star  Mario  Luigi

  Controls:
    1-5 / tap card   toggle HOLD
    D / DRAW         redraw unheld cards
    +/- or [ ]       change bet (before deal)
    Space / DEAL     deal or next hand
    M mute   Q quit
]]

local CFG = "luigi_poker.cfg"
local START_COINS = 100
local MAX_BET = 5

local NATIVE = term.current()
local USING_MONITOR = false
local IS_POCKET = (pocket ~= nil)
local SPEAKER = nil
local MUSIC_ON = true
local COINS = START_COINS
local BEST = START_COINS

-- Rank id 1..6 (Cloud lowest, Luigi highest)
local RANKS = {
  { id = 1, name = "Cloud",    short = "CLD", ch = "~", bg = colors.lightBlue, fg = colors.white },
  { id = 2, name = "Mushroom", short = "MUSH", ch = "M", bg = colors.red, fg = colors.white },
  { id = 3, name = "Flower",   short = "FLW", ch = "F", bg = colors.orange, fg = colors.black },
  { id = 4, name = "Star",     short = "STR", ch = "*", bg = colors.yellow, fg = colors.black },
  { id = 5, name = "Mario",    short = "MAR", ch = "A", bg = colors.red, fg = colors.yellow },
  { id = 6, name = "Luigi",    short = "LUI", ch = "L", bg = colors.lime, fg = colors.black },
}

-- Payout multipliers × bet (SMB3-inspired, tuned for fun)
local PAYOUTS = {
  { name = "Five Luigi!",  mult = 50, test = "five", rank = 6 },
  { name = "Five of kind", mult = 25, test = "five" },
  { name = "Four Luigi",   mult = 20, test = "four", rank = 6 },
  { name = "Four of kind", mult = 10, test = "four" },
  { name = "Full house",   mult = 6,  test = "full" },
  { name = "Three Luigi",  mult = 5,  test = "three", rank = 6 },
  { name = "Three of kind",mult = 3,  test = "three" },
  { name = "Two pair",     mult = 2,  test = "two_pair" },
  { name = "Luigi pair",   mult = 2,  test = "pair", rank = 6 },
  { name = "Pair+",        mult = 1,  test = "pair_high" }, -- Mario+ pair
}

--------------------------------------------------------------------------------
local function isColor()
  local ok, c = pcall(function() return term.isColor and term.isColor() end)
  return ok and c == true
end

local function isPocketLayout()
  if IS_POCKET then return true end
  local tw, th = term.getSize()
  return tw <= 26 or th <= 20
end

local function attachMonitor()
  -- Keep gameplay on the pocket screen (that's the point of the pocket build).
  if IS_POCKET then return false end
  local m = peripheral.find("monitor")
  if not m then return false end
  local okColor, col = pcall(function() return m.isColor and m.isColor() end)
  if not (okColor and col) then return false end
  pcall(function()
    if m.setTextScale then
      m.setTextScale(1)
      local w, h = m.getSize()
      if w < 30 or h < 16 then m.setTextScale(0.5) end
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
    NATIVE.write("Luigi Picture Poker")
    NATIVE.setCursorPos(1, 2)
    NATIVE.write("Close UI — tap cards")
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
-- Tiny casino bed (optional speaker)
--------------------------------------------------------------------------------
local musicIdx = 1
local MENU_NOTES = {
  { 7, 2 }, { 10, 2 }, { 12, 2 }, { 10, 2 },
  { 7, 2 }, { 5, 2 }, { 7, 3 }, { false, 1 },
  { 10, 2 }, { 12, 2 }, { 14, 2 }, { 12, 2 },
  { 10, 2 }, { 7, 3 }, { false, 2 },
}

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

local function musicTick()
  if not MUSIC_ON then return 0.4 end
  if not SPEAKER and not refreshSpeaker() then return 1.0 end
  local note = MENU_NOTES[musicIdx] or { false, 1 }
  musicIdx = musicIdx + 1
  if musicIdx > #MENU_NOTES then musicIdx = 1 end
  local pitch, beats = note[1], note[2] or 1
  playSoft("bass", 0.12, 2)
  if pitch then
    playSoft("pling", 0.22, pitch)
    playSoft("guitar", 0.10, math.max(0, pitch - 5))
  end
  return math.max(0.08, beats * 0.16)
end

local function sfx(kind)
  if not MUSIC_ON or not refreshSpeaker() then return end
  if kind == "deal" then playSoft("hat", 0.25, 14)
  elseif kind == "hold" then playSoft("hat", 0.2, 10)
  elseif kind == "win" then
    playSoft("chime", 0.4, 18); playSoft("pling", 0.3, 22)
  elseif kind == "lose" then playSoft("bass", 0.3, 1)
  elseif kind == "coin" then playSoft("pling", 0.25, 16)
  end
end

--------------------------------------------------------------------------------
-- Deck / hands
--------------------------------------------------------------------------------
local function newDeck()
  local d = {}
  -- 4 of each picture (24 cards) — enough for one hand without reshuffle issues
  for r = 1, #RANKS do
    for _ = 1, 4 do d[#d + 1] = r end
  end
  for i = #d, 2, -1 do
    local j = math.random(i)
    d[i], d[j] = d[j], d[i]
  end
  return d
end

local function counts(hand)
  local c = { 0, 0, 0, 0, 0, 0 }
  for i = 1, #hand do c[hand[i]] = c[hand[i]] + 1 end
  return c
end

-- Bonus multipliers when you beat Luigi (on top of base 2x).
local function bonusMult(hand)
  local c = counts(hand)
  local trips, pairs, four, five = {}, {}, nil, nil
  for r = 6, 1, -1 do
    if c[r] == 5 then five = r
    elseif c[r] == 4 then four = r
    elseif c[r] == 3 then trips[#trips + 1] = r
    elseif c[r] == 2 then pairs[#pairs + 1] = r
    end
  end
  for _, p in ipairs(PAYOUTS) do
    if p.test == "five" and five and (not p.rank or p.rank == five) then
      return p.mult
    elseif p.test == "four" and four and (not p.rank or p.rank == four) then
      return p.mult
    elseif p.test == "full" and #trips > 0 and #pairs > 0 then
      return p.mult
    elseif p.test == "three" and #trips > 0 and (not p.rank or p.rank == trips[1]) then
      return p.mult
    elseif p.test == "two_pair" and #pairs >= 2 then
      return p.mult
    elseif p.test == "pair" and #pairs >= 1 and p.rank and pairs[1] == p.rank then
      return p.mult
    elseif p.test == "pair_high" and #pairs >= 1 and pairs[1] >= 5 then
      return p.mult
    end
  end
  return 0
end

-- Comparable strength for beating Luigi (higher = better).
local function handRank(hand)
  if not hand or #hand < 5 then return 0, "—" end
  local c = counts(hand)
  local groups = {}
  for r = 1, 6 do
    if c[r] > 0 then groups[#groups + 1] = { c = c[r], r = r } end
  end
  table.sort(groups, function(a, b)
    if a.c ~= b.c then return a.c > b.c end
    return a.r > b.r
  end)

  local cat, name = 0, "High card"
  if groups[1].c == 5 then
    cat, name = 6, "Five " .. RANKS[groups[1].r].name
  elseif groups[1].c == 4 then
    cat, name = 5, "Four " .. RANKS[groups[1].r].name
  elseif groups[1].c == 3 and groups[2] and groups[2].c >= 2 then
    cat, name = 4, "Full house"
  elseif groups[1].c == 3 then
    cat, name = 3, "Three " .. RANKS[groups[1].r].name
  elseif groups[1].c == 2 and groups[2] and groups[2].c == 2 then
    cat, name = 2, "Two pair"
  elseif groups[1].c == 2 then
    cat, name = 1, "Pair " .. RANKS[groups[1].r].name
  else
    local hi = 0
    for i = 1, 5 do if hand[i] > hi then hi = hand[i] end end
    name = RANKS[hi].name .. " high"
  end

  local score = cat
  for i = 1, #groups do
    score = score * 10 + groups[i].c
    score = score * 10 + groups[i].r
  end
  local cards = { hand[1], hand[2], hand[3], hand[4], hand[5] }
  table.sort(cards, function(a, b) return a > b end)
  for i = 1, 5 do
    score = score * 7 + cards[i]
  end
  return score, name
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
local function drawCard(x, y, w, h, rankId, held, faceUp, pocket)
  local color = isColor()
  local r = RANKS[rankId] or RANKS[1]
  local bg = colors.white
  local fg = colors.black
  if color then
    bg = faceUp and r.bg or colors.blue
    fg = faceUp and r.fg or colors.white
  end
  if held then
    fill(x, y, w, h, color and colors.yellow or colors.white)
    local ix = (w >= 4) and 1 or 0
    local iy = (h >= 3) and 1 or 0
    fill(x + ix, y + iy, math.max(1, w - ix * 2), math.max(1, h - iy * 2), bg)
  else
    fill(x, y, w, h, bg)
  end
  if faceUp then
    local label = pocket and r.ch or r.short
    if (not pocket) and w < 5 then label = r.ch end
    if pocket and w >= 4 then label = r.ch end
    local ly = y + math.floor((h - 1) / 2)
    textAt(x + math.max(0, math.floor((w - #label) / 2)), ly, label:sub(1, w), fg, bg)
  else
    textAt(x + math.max(0, math.floor((w - 1) / 2)), y + math.floor((h - 1) / 2),
      "?", fg, bg)
  end
end

local function rowRects(tw, oy, cardW, cardH, gap)
  local n = 5
  local total = n * cardW + (n + 1) * gap
  local ox = math.max(1, math.floor((tw - total) / 2) + 1)
  local rects = {}
  for i = 1, n do
    rects[i] = {
      x = ox + gap + (i - 1) * (cardW + gap),
      y = oy, w = cardW, h = cardH,
    }
  end
  return rects
end

-- Luigi row (top) + player row (bottom, tappable).
local function layoutCards(tw, th)
  local n = 5
  local pocket = isPocketLayout()
  local gap = 1
  local padH = pocket and 3 or math.max(2, math.min(3, math.floor(th * 0.18)))
  local cardW = math.max(3, math.floor((tw - (n + 1) * gap) / n))
  -- Reserve: header(2) + L label(1) + L cards + gap + You label(1) + You cards + msg(1) + pad
  local luigiH = pocket and 2 or math.max(2, math.min(3, math.floor(th * 0.18)))
  local playerH = pocket and 3 or math.max(3, math.min(5, math.floor(th * 0.28)))
  local luigiY = 4
  local playerY = luigiY + luigiH + 2
  -- Shrink if overflowing small screens
  while playerY + playerH + 1 + padH > th and (luigiH > 2 or playerH > 2) do
    if playerH > luigiH and playerH > 2 then playerH = playerH - 1
    elseif luigiH > 2 then luigiH = luigiH - 1
    else playerH = math.max(2, playerH - 1) end
    playerY = luigiY + luigiH + 2
  end
  local luigiRects = rowRects(tw, luigiY, cardW, luigiH, gap)
  local playerRects = rowRects(tw, playerY, cardW, playerH, gap)
  local below = playerY + playerH + 1
  return playerRects, luigiRects, below, pocket, padH, luigiY - 1, playerY - 1
end

local function hit(rects, mx, my)
  for i = 1, #rects do
    local r = rects[i]
    if mx >= r.x and mx <= r.x + r.w - 1
        and my >= r.y and my <= r.y + r.h - 1 then
      return i
    end
  end
  return nil
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
  local cardRects, luigiRects, below, pocket, padH, luigiLabelY, youLabelY =
    layoutCards(tw, th)
  state.cardRects = cardRects
  state.luigiRects = luigiRects
  fill(1, 1, tw, th, colors.black)

  local hdrBg = color and colors.lime or colors.gray
  fill(1, 1, tw, 1, hdrBg)
  local title = pocket and " LUIGI POKER " or " LUIGI PICTURE POKER "
  textAt(2, 1, title:sub(1, tw - 2), colors.black, hdrBg)
  local coinTxt = pocket
    and ("$%d  bet%d  hi%d"):format(COINS, state.bet, BEST)
    or ("Coins:%d  Bet:%d  Best:%d"):format(COINS, state.bet, BEST)
  textAt(2, 2, coinTxt:sub(1, tw - 2), colors.yellow, colors.black)

  -- Luigi's hand (always face-up once dealt — what you must beat)
  local _, luigiHandName = handRank(state.luigi)
  textAt(2, luigiLabelY,
    (pocket and "LUIGI " or "LUIGI'S HAND ") .. (state.phase == "bet" and "" or ("(" .. luigiHandName .. ")")),
    color and colors.lime or colors.white, colors.black)
  for i = 1, 5 do
    local r = luigiRects[i]
    local rank = state.luigi and state.luigi[i]
    if rank and state.phase ~= "bet" then
      drawCard(r.x, r.y, r.w, r.h, rank, false, true, true)
    else
      drawCard(r.x, r.y, r.w, r.h, 1, false, false, true)
    end
  end

  textAt(2, youLabelY, pocket and "YOU" or "YOUR HAND",
    color and colors.yellow or colors.white, colors.black)
  for i = 1, 5 do
    local rank = state.hand[i]
    local face = state.phase ~= "bet"
    local held = state.held[i] == true and state.phase == "hold"
    local r = cardRects[i]
    if rank then
      drawCard(r.x, r.y, r.w, r.h, rank, held, face, pocket)
    else
      drawCard(r.x, r.y, r.w, r.h, 1, false, false, pocket)
    end
    if pocket and state.phase == "hold" then
      local tag = held and "H" or tostring(i)
      local tx = r.x + math.floor((r.w - 1) / 2)
      local ty = r.y + r.h
      if ty < th - padH + 1 and ty < below then
        textAt(tx, ty, tag, held and colors.yellow or colors.gray, colors.black)
      end
    end
  end

  if state.phase == "bet" then
    textAt(2, below, pocket and "Bet · DEAL vs Luigi" or "Set bet, DEAL — beat Luigi's hand",
      colors.lightGray, colors.black)
  elseif state.phase == "hold" then
    textAt(2, below, pocket and "HOLD · beat Luigi · DRAW" or "Hold cards, then DRAW to beat Luigi",
      colors.white, colors.black)
  else
    local msg = state.resultName or "—"
    local win = state.win or 0
    local fg = colors.lightGray
    if state.outcome == "win" then fg = colors.lime
    elseif state.outcome == "lose" then fg = colors.red
    elseif state.outcome == "push" then fg = colors.yellow end
    local extra = ""
    if state.outcome == "win" then extra = " +" .. win
    elseif state.outcome == "push" then extra = " +" .. win .. " back"
    end
    textAt(2, below, (msg .. extra):sub(1, tw - 2), fg, colors.black)
  end

  padH = math.max(pocket and 3 or 2, math.min(pocket and 3 or 4, padH))
  local by = th - padH + 1
  local bw = math.floor(tw / 4)
  state.btns = {}
  if state.phase == "bet" then
    state.btns.minus = { x = 1, y = by, w = bw, h = padH }
    state.btns.plus = { x = bw + 1, y = by, w = bw, h = padH }
    state.btns.deal = { x = 2 * bw + 1, y = by, w = bw, h = padH }
    state.btns.quit = { x = 3 * bw + 1, y = by, w = tw - 3 * bw, h = padH }
    drawBtn(state.btns.minus, pocket and " - " or " -BET ", color and colors.gray or colors.black)
    drawBtn(state.btns.plus, pocket and " + " or " +BET ", color and colors.gray or colors.black)
    drawBtn(state.btns.deal, " DEAL ", color and colors.lime or colors.white, colors.black)
    drawBtn(state.btns.quit, pocket and " Q " or " QUIT ", color and colors.red or colors.black)
  elseif state.phase == "hold" then
    state.btns.draw = { x = 1, y = by, w = math.floor(tw * 2 / 3), h = padH }
    state.btns.quit = { x = state.btns.draw.w + 1, y = by, w = tw - state.btns.draw.w, h = padH }
    drawBtn(state.btns.draw, " DRAW ", color and colors.orange or colors.white, colors.black)
    drawBtn(state.btns.quit, pocket and " Q " or " QUIT ", color and colors.red or colors.black)
  else
    state.btns.deal = { x = 1, y = by, w = math.floor(tw * 2 / 3), h = padH }
    state.btns.quit = { x = state.btns.deal.w + 1, y = by, w = tw - state.btns.deal.w, h = padH }
    drawBtn(state.btns.deal, COINS > 0 and " NEXT " or " BROKE ",
      color and colors.lime or colors.white, colors.black)
    drawBtn(state.btns.quit, pocket and " Q " or " QUIT ", color and colors.red or colors.black)
  end
end

--------------------------------------------------------------------------------
-- Game flow
--------------------------------------------------------------------------------
local function newState()
  return {
    phase = "bet", -- bet | hold | result
    bet = 1,
    deck = {},
    hand = {},
    luigi = {},
    held = { false, false, false, false, false },
    resultName = nil,
    win = 0,
    outcome = nil, -- win | lose | push
    cardRects = {},
    luigiRects = {},
    btns = {},
  }
end

local function dealHand(state)
  if COINS < state.bet then return false end
  COINS = COINS - state.bet
  saveCfg()
  state.deck = newDeck()
  state.hand = {}
  state.luigi = {}
  state.held = { false, false, false, false, false }
  -- Luigi's hand first (face-up target), then yours.
  for i = 1, 5 do
    state.luigi[i] = table.remove(state.deck)
  end
  for i = 1, 5 do
    state.hand[i] = table.remove(state.deck)
  end
  state.phase = "hold"
  state.resultName, state.win, state.outcome = nil, 0, nil
  sfx("deal")
  return true
end

local function doDraw(state)
  for i = 1, 5 do
    if not state.held[i] then
      state.hand[i] = table.remove(state.deck) or state.hand[i]
    end
  end
  local pScore, pName = handRank(state.hand)
  local lScore, lName = handRank(state.luigi)
  if pScore > lScore then
    local bonus = bonusMult(state.hand)
    local mult = math.max(2, bonus > 0 and bonus or 2)
    state.win = state.bet * mult
    state.outcome = "win"
    state.resultName = "Beat Luigi! " .. pName
    COINS = COINS + state.win
    sfx("win")
  elseif pScore == lScore then
    state.win = state.bet
    state.outcome = "push"
    state.resultName = "Push — " .. pName
    COINS = COINS + state.win
    sfx("coin")
  else
    state.win = 0
    state.outcome = "lose"
    state.resultName = "Luigi: " .. lName
    sfx("lose")
  end
  saveCfg()
  state.phase = "result"
end

local function main()
  attachMonitor()
  refreshSpeaker()
  local state = newState()
  local musicTimer = os.startTimer(MUSIC_ON and 0.05 or 3600)
  drawScreen(state)

  local function bankruptReset()
    if COINS <= 0 then
      COINS = START_COINS
      saveCfg()
      state.bet = 1
    end
  end

  while true do
    local ev, p1, p2, p3 = pullEv()
    if ev == "timer" and p1 == musicTimer then
      musicTimer = os.startTimer(musicTick())
    elseif ev == "term_resize" then
      drawScreen(state)
    elseif ev == "mouse_click" then
      local mx, my = p2, p3
      local b = state.btns
      if state.phase == "hold" then
        local c = hit(state.cardRects, mx, my)
        if c then
          state.held[c] = not state.held[c]
          sfx("hold")
          drawScreen(state)
        elseif inBtn(b.draw, mx, my) then
          doDraw(state)
          drawScreen(state)
        elseif inBtn(b.quit, mx, my) then
          return
        end
      elseif state.phase == "bet" then
        if inBtn(b.minus, mx, my) then
          state.bet = math.max(1, state.bet - 1); sfx("coin"); drawScreen(state)
        elseif inBtn(b.plus, mx, my) then
          state.bet = math.min(MAX_BET, state.bet + 1, COINS); sfx("coin"); drawScreen(state)
        elseif inBtn(b.deal, mx, my) then
          if dealHand(state) then drawScreen(state) end
        elseif inBtn(b.quit, mx, my) then
          return
        end
      else
        if inBtn(b.deal, mx, my) then
          bankruptReset()
          state.phase = "bet"
          state.hand, state.luigi = {}, {}
          state.outcome = nil
          drawScreen(state)
        elseif inBtn(b.quit, mx, my) then
          return
        end
      end
    elseif ev == "key" then
      local K = keys
      if p1 == K.q then return
      elseif p1 == K.m then
        MUSIC_ON = not MUSIC_ON
        saveCfg()
        if not MUSIC_ON then stopMusic() end
      elseif state.phase == "bet" then
        if p1 == K.left or p1 == K.minus then
          state.bet = math.max(1, state.bet - 1); drawScreen(state)
        elseif p1 == K.right or p1 == K.equals or p1 == K.plus then
          state.bet = math.min(MAX_BET, state.bet + 1, COINS); drawScreen(state)
        elseif p1 == K.space or p1 == K.enter then
          if dealHand(state) then drawScreen(state) end
        elseif p1 == K.one then state.bet = math.min(1, COINS); drawScreen(state)
        elseif p1 == K.two then state.bet = math.min(2, COINS, MAX_BET); drawScreen(state)
        elseif p1 == K.three then state.bet = math.min(3, COINS, MAX_BET); drawScreen(state)
        elseif p1 == K.four then state.bet = math.min(4, COINS, MAX_BET); drawScreen(state)
        elseif p1 == K.five then state.bet = math.min(5, COINS, MAX_BET); drawScreen(state)
        end
      elseif state.phase == "hold" then
        if p1 == K.one then state.held[1] = not state.held[1]; sfx("hold"); drawScreen(state)
        elseif p1 == K.two then state.held[2] = not state.held[2]; sfx("hold"); drawScreen(state)
        elseif p1 == K.three then state.held[3] = not state.held[3]; sfx("hold"); drawScreen(state)
        elseif p1 == K.four then state.held[4] = not state.held[4]; sfx("hold"); drawScreen(state)
        elseif p1 == K.five then state.held[5] = not state.held[5]; sfx("hold"); drawScreen(state)
        elseif p1 == K.d or p1 == K.space or p1 == K.enter then
          doDraw(state); drawScreen(state)
        end
      else
        if p1 == K.space or p1 == K.enter then
          bankruptReset()
          state.phase = "bet"
          state.hand, state.luigi = {}, {}
          state.outcome = nil
          drawScreen(state)
        end
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "q" then return
      elseif ch == "m" then
        MUSIC_ON = not MUSIC_ON; saveCfg()
        if not MUSIC_ON then stopMusic() end
      elseif state.phase == "hold" and ch == "d" then
        doDraw(state); drawScreen(state)
      elseif state.phase == "bet" and (ch == "+" or ch == "]") then
        state.bet = math.min(MAX_BET, state.bet + 1, COINS); drawScreen(state)
      elseif state.phase == "bet" and (ch == "-" or ch == "[") then
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
