--[[
  higher_lower.lua  -  Video Poker → Higher / Lower streak (CC: Tweaked)
  Titan-Version: 1.1.2

  Run:

      higher_lower
      higher_lower --launcher [--managed|--unmanaged]

  1) Bet, deal 5 cards, HOLD / DRAW (video poker — no dealer).
  2) Any paying hand (pair of Jacks+, two pair, trips, straight, flush, …)
     starts a Higher/Lower streak with those earnings.
     Jacks rule: need TWO Jacks (or a pair of Q/K/A) — a single Jack does not pay.
  3) Guess H/L up to 10 correct in a row for the JACKPOT.
     Wrong guess dumps your earnings into the jackpot.
     After each win (before 10) you may CASH OUT or CONTINUE.

  Bet: -100/-50/-10 and +10/+50/+100 (capped at balance).

  Controls:
    1-5 / tap   HOLD   D DRAW   H/L guess
    C cash out  G continue
    M mute   Q quit
]]

local CFG = "higher_lower.cfg"
local START_COINS = 100
local JACKPOT_SEED = 500
local STREAK_GOAL = 10

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
local JACKPOT = JACKPOT_SEED
local CASINO, USE_CASINO = nil, false
local USE_WALLET = false
local econ = nil
if fs.exists("lib/games_economy.lua") then
  local ok, e = pcall(dofile, "lib/games_economy.lua")
  if ok then econ = e; econ.load() end
end

local RANK_NAME = {
  [2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7",
  [8] = "8", [9] = "9", [10] = "10", [11] = "J", [12] = "Q", [13] = "K", [14] = "A",
}
local SUITS = {
  { id = "H", name = "Hearts",   ch = "h", red = true },
  { id = "D", name = "Diamonds", ch = "d", red = true },
  { id = "C", name = "Clubs",    ch = "c", red = false },
  { id = "S", name = "Spades",   ch = "s", red = false },
}

-- Video-poker payouts × bet (Jacks or Better style).
-- Lowest pair that pays: TWO Jacks (rank 11). One Jack / low pair = no pay.
local MIN_PAIR_RANK = 11 -- Jack
local PAY_TABLE = {
  { cat = 9, name = "Royal flush",   mult = 250 }, -- special
  { cat = 8, name = "Straight flush", mult = 50 },
  { cat = 7, name = "Four of a kind", mult = 25 },
  { cat = 6, name = "Full house",     mult = 9 },
  { cat = 5, name = "Flush",          mult = 6 },
  { cat = 4, name = "Straight",       mult = 4 },
  { cat = 3, name = "Three of a kind", mult = 3 },
  { cat = 2, name = "Two pair",       mult = 2 },
  { cat = 1, name = "Pair of Jacks+", mult = 1 },
}

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
      if w < 30 or h < 16 then m.setTextScale(0.5) end
    end
    if m.setBackgroundColor then m.setBackgroundColor(colors.black) end
    m.clear()
  end)
  term.redirect(m)
  USING_MONITOR = true
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
  JACKPOT = math.max(0, tonumber(d.jackpot) or JACKPOT_SEED)
  if d.music == false then MUSIC_ON = false end
end

local function saveCfg()
  if COINS > BEST then BEST = COINS end
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize({
    coins = COINS, best = BEST, music = MUSIC_ON, jackpot = JACKPOT,
  }))
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
  if kind == "deal" then playSoft("hat", 0.25, 14)
  elseif kind == "hold" then playSoft("hat", 0.2, 10)
  elseif kind == "win" then
    playSoft("chime", 0.4, 18); playSoft("pling", 0.3, 22)
  elseif kind == "big" then
    playSoft("chime", 0.5, 20); playSoft("flute", 0.35, 24)
  elseif kind == "lose" then playSoft("bass", 0.3, 1)
  elseif kind == "coin" then playSoft("pling", 0.25, 16)
  elseif kind == "flip" then playSoft("pling", 0.3, 12)
  end
end

--------------------------------------------------------------------------------
-- Deck / poker
--------------------------------------------------------------------------------
local function newDeck()
  local d = {}
  for s = 1, 4 do
    for r = 2, 14 do d[#d + 1] = { rank = r, suit = s } end
  end
  for i = #d, 2, -1 do
    local j = math.random(i)
    d[i], d[j] = d[j], d[i]
  end
  return d
end

local function drawCard(deck)
  return table.remove(deck)
end

local function cardLabel(c)
  if not c then return "??" end
  return (RANK_NAME[c.rank] or "?") .. (SUITS[c.suit] and SUITS[c.suit].ch or "?")
end

local function handCounts(hand)
  local byRank = {}
  for i = 1, #hand do
    local r = hand[i].rank
    byRank[r] = (byRank[r] or 0) + 1
  end
  local groups = {}
  for r, n in pairs(byRank) do
    groups[#groups + 1] = { r = r, c = n }
  end
  table.sort(groups, function(a, b)
    if a.c ~= b.c then return a.c > b.c end
    return a.r > b.r
  end)
  return groups
end

local function isFlush(hand)
  local s = hand[1].suit
  for i = 2, 5 do if hand[i].suit ~= s then return false end end
  return true
end

local function sortedRanks(hand)
  local t = {}
  for i = 1, #hand do t[i] = hand[i].rank end
  table.sort(t, function(a, b) return a > b end)
  return t
end

local function isStraight(ranksDesc)
  if ranksDesc[1] == 14 and ranksDesc[2] == 5 and ranksDesc[3] == 4
      and ranksDesc[4] == 3 and ranksDesc[5] == 2 then
    return true, 5
  end
  for i = 1, 4 do
    if ranksDesc[i] ~= ranksDesc[i + 1] + 1 then return false end
  end
  return true, ranksDesc[1]
end

-- Returns cat (0..9), name. cat 9 = royal flush.
local function evaluateHand(hand)
  if not hand or #hand < 5 then return 0, "—" end
  local groups = handCounts(hand)
  local ranks = sortedRanks(hand)
  local flush = isFlush(hand)
  local straight, straightHi = isStraight(ranks)

  if straight and flush and ranks[1] == 14 and ranks[5] == 10 then
    return 9, "Royal flush"
  elseif straight and flush then
    return 8, "Straight flush"
  elseif groups[1].c == 4 then
    return 7, "Four " .. (RANK_NAME[groups[1].r] or "?") .. "s"
  elseif groups[1].c == 3 and groups[2] and groups[2].c >= 2 then
    return 6, "Full house"
  elseif flush then
    return 5, "Flush"
  elseif straight then
    return 4, "Straight"
  elseif groups[1].c == 3 then
    return 3, "Three " .. (RANK_NAME[groups[1].r] or "?") .. "s"
  elseif groups[1].c == 2 and groups[2] and groups[2].c == 2 then
    return 2, "Two pair"
  elseif groups[1].c == 2 then
    -- Exactly one pair: pays only if it is TWO Jacks / Queens / Kings / Aces.
    local r = groups[1].r
    if r >= MIN_PAIR_RANK then
      return 1, "Pair " .. (RANK_NAME[r] or "?") .. "s"
    end
    return 0, "Pair " .. (RANK_NAME[r] or "?") .. "s"
  end
  -- High card only (including a lone Jack) never pays.
  return 0, (RANK_NAME[ranks[1]] or "?") .. " high"
end

local function pokerPayout(cat, bet)
  if cat <= 0 then return 0, nil end
  for _, row in ipairs(PAY_TABLE) do
    if row.cat == cat then
      return bet * row.mult, row.name
    end
  end
  return 0, nil
end

--------------------------------------------------------------------------------
-- Draw
--------------------------------------------------------------------------------
local function drawBtn(b, label, bg, fg)
  if not b then return end
  fill(b.x, b.y, b.w, b.h, bg)
  local lx = b.x + math.max(0, math.floor((b.w - #label) / 2))
  local ly = b.y + math.floor((b.h - 1) / 2)
  textAt(lx, ly, label:sub(1, b.w), fg or colors.white, bg)
end

local function inBtn(b, mx, my)
  return b and mx >= b.x and mx <= b.x + b.w - 1
    and my >= b.y and my <= b.y + b.h - 1
end

local function drawCardFace(x, y, w, h, card, held, hidden)
  local color = isColor()
  local border = held and (color and colors.yellow or colors.white)
    or (color and colors.white or colors.lightGray)
  fill(x, y, w, h, border)
  if hidden then
    fill(x + 1, y + 1, math.max(1, w - 2), math.max(1, h - 2),
      color and colors.blue or colors.gray)
    textAt(x + math.max(1, math.floor((w - 1) / 2)), y + math.floor(h / 2), "?",
      colors.white, color and colors.blue or colors.gray)
    return
  end
  if not card then
    fill(x + 1, y + 1, math.max(1, w - 2), math.max(1, h - 2), colors.black)
    return
  end
  local suit = SUITS[card.suit] or SUITS[1]
  local bg = color and colors.white or colors.lightGray
  local fg = color and (suit.red and colors.red or colors.black) or colors.black
  fill(x + 1, y + 1, math.max(1, w - 2), math.max(1, h - 2), bg)
  local lab = RANK_NAME[card.rank] or "?"
  textAt(x + math.max(1, math.floor((w - #lab) / 2)),
    y + math.floor(h / 2) - (h >= 4 and 1 or 0), lab, fg, bg)
  if h >= 4 then
    textAt(x + math.max(1, math.floor((w - 1) / 2)), y + math.floor(h / 2) + 1,
      suit.ch, fg, bg)
  end
  if held and h >= 3 then
    textAt(x + 1, y + h - 1, "H", colors.black, colors.yellow)
  end
end

local function layoutCards(tw, count, cardW, cardH, y)
  local gap = 1
  local total = count * cardW + (count - 1) * gap
  local ox = math.max(1, math.floor((tw - total) / 2) + 1)
  local boxes = {}
  for i = 1, count do
    boxes[i] = {
      x = ox + (i - 1) * (cardW + gap), y = y, w = cardW, h = cardH,
    }
  end
  return boxes
end

local function drawBetButtons(state, tw, th, color, dealLabel)
  local padH = math.max(2, math.min(2, 2))
  local by1 = th - padH * 3 + 1
  local by2 = th - padH * 2 + 1
  local by3 = th - padH + 1
  local bw3 = math.floor(tw / 3)
  local bw2 = math.floor(tw / 2)
  state.btns = {
    m100 = { x = 1, y = by1, w = bw3, h = padH },
    m50  = { x = bw3 + 1, y = by1, w = bw3, h = padH },
    m10  = { x = 2 * bw3 + 1, y = by1, w = tw - 2 * bw3, h = padH },
    b10  = { x = 1, y = by2, w = bw3, h = padH },
    b50  = { x = bw3 + 1, y = by2, w = bw3, h = padH },
    b100 = { x = 2 * bw3 + 1, y = by2, w = tw - 2 * bw3, h = padH },
    deal = { x = 1, y = by3, w = bw2, h = padH },
    quit = { x = bw2 + 1, y = by3, w = tw - bw2, h = padH },
  }
  drawBtn(state.btns.m100, " -100 ", color and colors.brown or colors.black)
  drawBtn(state.btns.m50, " -50 ", color and colors.brown or colors.black)
  drawBtn(state.btns.m10, " -10 ", color and colors.brown or colors.black)
  drawBtn(state.btns.b10, " +10 ", color and colors.gray or colors.black)
  drawBtn(state.btns.b50, " +50 ", color and colors.lightGray or colors.black)
  drawBtn(state.btns.b100, " +100 ", color and colors.white or colors.black, colors.black)
  drawBtn(state.btns.deal, dealLabel or " DEAL ",
    color and colors.lime or colors.white, colors.black)
  drawBtn(state.btns.quit, FROM_LAUNCHER and " CLOSE " or " QUIT ",
    color and colors.red or colors.black)
end

local function drawScreen(state)
  local tw, th = term.getSize()
  local color = isColor()
  fill(1, 1, tw, th, colors.black)

  local hdr = color and colors.cyan or colors.gray
  fill(1, 1, tw, 1, hdr)
  textAt(2, 1, " POKER → H/L ", colors.white, hdr)
  local unit = USE_CASINO and "Chips" or "Coins"
  textAt(2, 2, ("%s:%d Bet:%d JP:%d"):format(unit, COINS, state.bet, JACKPOT):sub(1, tw - 2),
    colors.yellow, colors.black)

  local phase = state.phase
  local cardW = math.max(3, math.min(5, math.floor((tw - 6) / 5)))
  local cardH = math.max(3, math.min(4, math.floor(th / 6)))
  state.cardBoxes = {}
  state.btns = {}

  if phase == "bet" or phase == "result" then
    textAt(2, 4, "2 Jacks+ poker → H/L streak", colors.lightGray, colors.black)
    textAt(2, 5, ("10 correct = jackpot (%d)"):format(JACKPOT):sub(1, tw - 2),
      colors.orange, colors.black)
    if state.message then
      local fg = (state.lastWin or 0) > 0 and colors.lime
        or ((state.lastWin or 0) < 0 and colors.red or colors.white)
      textAt(2, 7, tostring(state.message):sub(1, tw - 2), fg, colors.black)
    end
    drawBetButtons(state, tw, th, color, phase == "result" and " NEXT " or " DEAL ")

  elseif phase == "hold" then
    textAt(2, 3, ("Hand: " .. (state.playerName or "?")):sub(1, tw - 2),
      colors.white, colors.black)
    local pBoxes = layoutCards(tw, 5, cardW, cardH, 4)
    state.cardBoxes = pBoxes
    for i = 1, 5 do
      drawCardFace(pBoxes[i].x, pBoxes[i].y, pBoxes[i].w, pBoxes[i].h,
        state.player[i], state.held[i], false)
    end
    textAt(2, 4 + cardH + 1, tostring(state.message or "Hold, then DRAW"):sub(1, tw - 2),
      colors.yellow, colors.black)
    local padH = 2
    local by = th - padH + 1
    local half = math.floor(tw / 2)
    state.btns = {
      draw = { x = 1, y = by, w = half, h = padH },
      quit = { x = half + 1, y = by, w = tw - half, h = padH },
    }
    drawBtn(state.btns.draw, " DRAW ", color and colors.lime or colors.white, colors.black)
    drawBtn(state.btns.quit, FROM_LAUNCHER and " CLOSE " or " QUIT ",
      color and colors.red or colors.black)

  elseif phase == "hl" then
    textAt(2, 3, ("Earn:%d  Streak %d/%d  JP:%d"):format(
      state.earnings or 0, state.streak or 0, STREAK_GOAL, JACKPOT):sub(1, tw - 2),
      colors.lime, colors.black)
    local boxes = layoutCards(tw, 2, math.max(5, cardW + 1), math.max(3, cardH), 5)
    drawCardFace(boxes[1].x, boxes[1].y, boxes[1].w, boxes[1].h, state.shown, false, false)
    drawCardFace(boxes[2].x, boxes[2].y, boxes[2].w, boxes[2].h, state.hidden, false, true)
    textAt(boxes[1].x, boxes[1].y + boxes[1].h, "SHOWN", colors.lightGray, colors.black)
    textAt(boxes[2].x, boxes[2].y + boxes[2].h, "???", colors.lightGray, colors.black)
    textAt(2, boxes[1].y + boxes[1].h + 2,
      tostring(state.message or "Higher or Lower?"):sub(1, tw - 2),
      colors.yellow, colors.black)
    local padH = 2
    local by = th - padH + 1
    local bw = math.floor(tw / 3)
    state.btns = {
      high = { x = 1, y = by, w = bw, h = padH },
      low  = { x = bw + 1, y = by, w = bw, h = padH },
      quit = { x = 2 * bw + 1, y = by, w = tw - 2 * bw, h = padH },
    }
    drawBtn(state.btns.high, " HIGH ", color and colors.lime or colors.white, colors.black)
    drawBtn(state.btns.low, " LOW ", color and colors.orange or colors.white, colors.black)
    drawBtn(state.btns.quit, FROM_LAUNCHER and " CLOSE " or " QUIT ",
      color and colors.red or colors.black)

  elseif phase == "hl_choice" then
    textAt(2, 3, ("Correct! Streak %d/%d"):format(state.streak or 0, STREAK_GOAL):sub(1, tw - 2),
      colors.lime, colors.black)
    textAt(2, 5, ("Earnings: %d"):format(state.earnings or 0), colors.yellow, colors.black)
    textAt(2, 6, ("Jackpot:  %d"):format(JACKPOT), colors.orange, colors.black)
    textAt(2, 8, "Cash out now, or risk another", colors.lightGray, colors.black)
    textAt(2, 9, ("round for the jackpot (%d left)."):format(
      STREAK_GOAL - (state.streak or 0)):sub(1, tw - 2), colors.lightGray, colors.black)
    local padH = 3
    local by = th - padH + 1
    local half = math.floor(tw / 2)
    state.btns = {
      cash = { x = 1, y = by, w = half, h = padH },
      go   = { x = half + 1, y = by, w = tw - half, h = padH },
    }
    drawBtn(state.btns.cash, " CASH OUT ", color and colors.lime or colors.white, colors.black)
    drawBtn(state.btns.go, " GAMBLE ", color and colors.orange or colors.white, colors.black)
  end
end

--------------------------------------------------------------------------------
-- Logic
--------------------------------------------------------------------------------
local function dealHLCards(state)
  if not state.deck or #state.deck < 2 then state.deck = newDeck() end
  state.shown = drawCard(state.deck)
  state.hidden = drawCard(state.deck)
end

local function beginDeal(state)
  local ok, err = spendBet(state.bet)
  if not ok then
    state.message = USE_CASINO and ("Casino: " .. tostring(err)) or "Not enough chips!"
    return false
  end
  if not USE_CASINO then saveCfg() end
  state.deck = newDeck()
  state.player = {}
  state.held = { false, false, false, false, false }
  for i = 1, 5 do state.player[i] = drawCard(state.deck) end
  local cat, name = evaluateHand(state.player)
  state.playerCat, state.playerName = cat, name
  state.phase = "hold"
  state.earnings = 0
  state.streak = 0
  state.lastWin = 0
  state.message = "Hold (1-5), then DRAW"
  state.shown, state.hidden = nil, nil
  sfx("deal")
  return true
end

local function finishPoker(state)
  for i = 1, 5 do
    if not state.held[i] then
      state.player[i] = drawCard(state.deck)
    end
  end
  local cat, name = evaluateHand(state.player)
  state.playerCat, state.playerName = cat, name
  local pay, payName = pokerPayout(cat, state.bet)
  if pay <= 0 then
    state.phase = "result"
    state.lastWin = -state.bet
    state.message = "No hand — " .. tostring(name)
    sfx("lose")
    return
  end
  state.earnings = pay
  state.streak = 0
  state.phase = "hl"
  dealHLCards(state)
  state.message = (payName or name) .. " +" .. pay .. " → H/L"
  sfx("win")
end

local function cashOut(state)
  local n = math.floor(tonumber(state.earnings) or 0)
  if n > 0 then creditWin(n) end
  state.lastWin = n
  state.message = ("Cashed out +%d"):format(n)
  state.earnings = 0
  state.streak = 0
  state.phase = "result"
  sfx("coin")
  saveCfg()
end

local function startNextHL(state)
  state.phase = "hl"
  dealHLCards(state)
  state.message = ("Streak %d/%d — Higher or Lower?"):format(state.streak, STREAK_GOAL)
  sfx("deal")
end

local function resolveHL(state, guessHigher)
  if state.phase ~= "hl" then return end
  local shown, hidden = state.shown, state.hidden
  if not shown or not hidden then return end
  sfx("flip")
  local sr, hr = shown.rank, hidden.rank
  if hr == sr then
    -- Tie: redraw, same streak / earnings
    dealHLCards(state)
    state.message = ("Tie %s=%s — try again"):format(cardLabel(shown), cardLabel(hidden))
    sfx("coin")
    return
  end
  local correct = (hr > sr) == guessHigher
  if not correct then
    JACKPOT = JACKPOT + (state.earnings or 0)
    state.lastWin = -(state.earnings or 0)
    state.message = ("Wrong %s→%s — +%d to jackpot"):format(
      cardLabel(shown), cardLabel(hidden), state.earnings or 0)
    state.earnings = 0
    state.streak = 0
    state.phase = "result"
    sfx("lose")
    saveCfg()
    return
  end

  -- Correct: double earnings, advance streak
  state.earnings = math.floor((state.earnings or 0) * 2)
  state.streak = (state.streak or 0) + 1
  state.message = ("Yes! %s→%s  earn=%d"):format(
    cardLabel(shown), cardLabel(hidden), state.earnings)

  if state.streak >= STREAK_GOAL then
    local jp = JACKPOT
    creditWin(jp)
    state.lastWin = jp
    state.message = ("JACKPOT! +%d  (10 streak)"):format(jp)
    JACKPOT = JACKPOT_SEED
    state.earnings = 0
    state.streak = 0
    state.phase = "result"
    sfx("big")
    saveCfg()
    return
  end

  state.phase = "hl_choice"
  sfx("win")
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------
local function handleBetClick(state, b, mx, my)
  if inBtn(b.m10, mx, my) then addBet(state, -10); sfx("coin"); return true end
  if inBtn(b.m50, mx, my) then addBet(state, -50); sfx("coin"); return true end
  if inBtn(b.m100, mx, my) then addBet(state, -100); sfx("coin"); return true end
  if inBtn(b.b10, mx, my) then addBet(state, 10); sfx("coin"); return true end
  if inBtn(b.b50, mx, my) then addBet(state, 50); sfx("coin"); return true end
  if inBtn(b.b100, mx, my) then addBet(state, 100); sfx("coin"); return true end
  return false
end

local function main()
  attachMonitor()
  refreshSpeaker()
  initEconomy()
  local state = {
    phase = "bet",
    bet = clampBet(10),
    player = {},
    held = { false, false, false, false, false },
    message = "Bet ±10/50/100 — need 2 Jacks+ to play H/L",
    lastWin = 0,
    earnings = 0,
    streak = 0,
    btns = {},
    cardBoxes = {},
  }
  drawScreen(state)

  while true do
    local ev, p1, p2, p3 = pullEv()
    if ev == "term_resize" then
      drawScreen(state)
    elseif ev == "mouse_click" then
      local mx, my = p2, p3
      local b = state.btns
      if state.phase == "hold" then
        for i, box in ipairs(state.cardBoxes or {}) do
          if inBtn(box, mx, my) then
            state.held[i] = not state.held[i]
            sfx("hold"); drawScreen(state); break
          end
        end
        if inBtn(b.draw, mx, my) then
          finishPoker(state); drawScreen(state)
        elseif inBtn(b.quit, mx, my) then
          return
        end
      elseif state.phase == "hl" then
        if inBtn(b.high, mx, my) then
          resolveHL(state, true); drawScreen(state)
        elseif inBtn(b.low, mx, my) then
          resolveHL(state, false); drawScreen(state)
        elseif inBtn(b.quit, mx, my) then
          return
        end
      elseif state.phase == "hl_choice" then
        if inBtn(b.cash, mx, my) then
          cashOut(state); drawScreen(state)
        elseif inBtn(b.go, mx, my) then
          startNextHL(state); drawScreen(state)
        end
      elseif state.phase == "bet" or state.phase == "result" then
        if handleBetClick(state, b, mx, my) then
          drawScreen(state)
        elseif inBtn(b.deal, mx, my) then
          if state.phase == "result" then
            state.phase = "bet"
            state.bet = clampBet(state.bet)
            drawScreen(state)
          else
            state.bet = clampBet(state.bet)
            beginDeal(state); drawScreen(state)
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
      elseif state.phase == "hold" then
        if p1 == K.d then finishPoker(state); drawScreen(state)
        elseif p1 >= K.one and p1 <= K.five then
          local i = (p1 - K.one) + 1
          state.held[i] = not state.held[i]
          sfx("hold"); drawScreen(state)
        end
      elseif state.phase == "hl" then
        if p1 == K.h then resolveHL(state, true); drawScreen(state)
        elseif p1 == K.l then resolveHL(state, false); drawScreen(state)
        end
      elseif state.phase == "hl_choice" then
        if p1 == K.c then cashOut(state); drawScreen(state)
        elseif p1 == K.g or p1 == K.space or p1 == K.enter then
          startNextHL(state); drawScreen(state)
        end
      elseif state.phase == "result" then
        if p1 == K.space or p1 == K.enter then
          state.phase = "bet"; state.bet = clampBet(state.bet); drawScreen(state)
        end
      elseif state.phase == "bet" then
        if p1 == K.one then addBet(state, 10); drawScreen(state)
        elseif p1 == K.two then addBet(state, 50); drawScreen(state)
        elseif p1 == K.three then addBet(state, 100); drawScreen(state)
        elseif p1 == K.four then addBet(state, -10); drawScreen(state)
        elseif p1 == K.five then addBet(state, -50); drawScreen(state)
        elseif p1 == K.six then addBet(state, -100); drawScreen(state)
        elseif p1 == K.space or p1 == K.enter then
          state.bet = clampBet(state.bet)
          beginDeal(state); drawScreen(state)
        end
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "q" then return
      elseif ch == "m" then
        MUSIC_ON = not MUSIC_ON; saveCfg()
        if not MUSIC_ON then stopMusic() end
      elseif state.phase == "hold" then
        if ch == "d" then finishPoker(state); drawScreen(state)
        elseif ch >= "1" and ch <= "5" then
          local i = tonumber(ch)
          state.held[i] = not state.held[i]
          sfx("hold"); drawScreen(state)
        end
      elseif state.phase == "hl" then
        if ch == "h" then resolveHL(state, true); drawScreen(state)
        elseif ch == "l" then resolveHL(state, false); drawScreen(state)
        end
      elseif state.phase == "hl_choice" then
        if ch == "c" then cashOut(state); drawScreen(state)
        elseif ch == "g" then startNextHL(state); drawScreen(state)
        end
      elseif state.phase == "bet" then
        if ch == "1" then addBet(state, 10); drawScreen(state)
        elseif ch == "2" then addBet(state, 50); drawScreen(state)
        elseif ch == "3" then addBet(state, 100); drawScreen(state)
        elseif ch == "4" then addBet(state, -10); drawScreen(state)
        elseif ch == "5" then addBet(state, -50); drawScreen(state)
        elseif ch == "6" then addBet(state, -100); drawScreen(state)
        end
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
