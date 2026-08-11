--[[
  luigi_poker.lua  -  Luigi Picture Poker (SMB3-style) for CC: Tweaked
  Titan-Version: 1.2.9

  Run:

      luigi_poker
      luigi_poker --launcher [--managed|--unmanaged]

  Beat Luigi: he shows a 5-card hand you must beat. Hold/draw once, then
  compare. Win pays 2x (or more if you also hit a bonus hand). Push returns
  the bet. Bet with ±10 / ±50 / ±100 (capped at balance).

  Cards (low → high): Cloud  Mushroom  Flower  Star  Mario  Luigi

  Controls:
    1-5 / tap card   toggle HOLD
    D / DRAW         redraw unheld cards
    ±10/50/100       change bet
    Space / DEAL     deal or next hand
    M mute   Q quit
]]

local CFG = "luigi_poker.cfg"
local START_COINS = 100

local NATIVE = term.current()
local USING_MONITOR = false
local IS_POCKET = (pocket ~= nil)
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
-- Casino bed (lib/games_music.lua)
--------------------------------------------------------------------------------
local musicPlayer = gm and gm.newPlayer("luigi_poker") or nil

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
  if not MUSIC_ON then return 0.4 end
  if musicPlayer then return musicPlayer:step(MUSIC_ON) end
  if not SPEAKER and not refreshSpeaker() then return 1.0 end
  return 0.4
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

-- Comparable key: { category, …tiebreak ranks }. Higher category always wins.
-- (Old packed integers were wrong: high-card hands could outscore pairs.)
local function handRank(hand)
  if not hand or #hand < 5 then return { -1 }, "—" end
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

  local cards = { hand[1], hand[2], hand[3], hand[4], hand[5] }
  table.sort(cards, function(a, b) return a > b end)

  -- Fixed-length key: category, then up to 5 (count,rank) slots, then 5 kickers.
  local key = { cat }
  for i = 1, 5 do
    local g = groups[i]
    key[#key + 1] = g and g.c or 0
    key[#key + 1] = g and g.r or 0
  end
  for i = 1, 5 do
    key[#key + 1] = cards[i] or 0
  end
  return key, name
end

-- -1 if a<b, 0 equal, 1 if a>b
local function cmpHandKey(a, b)
  a, b = a or {}, b or {}
  local n = math.max(#a, #b)
  for i = 1, n do
    local x, y = a[i] or 0, b[i] or 0
    if x < y then return -1 end
    if x > y then return 1 end
  end
  return 0
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

  padH = math.max(pocket and 2 or 2, math.min(3, padH))
  local by = th - padH + 1
  local bw = math.floor(tw / 4)
  state.btns = {}
  if state.phase == "bet" then
    local bw3 = math.floor(tw / 3)
    local bw2 = math.floor(tw / 2)
    padH = 2
    local byM = th - padH * 3 + 1
    local byP = th - padH * 2 + 1
    local byAct = th - padH + 1
    state.btns.m100 = { x = 1, y = byM, w = bw3, h = padH }
    state.btns.m50  = { x = bw3 + 1, y = byM, w = bw3, h = padH }
    state.btns.m10  = { x = 2 * bw3 + 1, y = byM, w = tw - 2 * bw3, h = padH }
    state.btns.b10  = { x = 1, y = byP, w = bw3, h = padH }
    state.btns.b50  = { x = bw3 + 1, y = byP, w = bw3, h = padH }
    state.btns.b100 = { x = 2 * bw3 + 1, y = byP, w = tw - 2 * bw3, h = padH }
    state.btns.deal = { x = 1, y = byAct, w = bw2, h = padH }
    state.btns.quit = { x = bw2 + 1, y = byAct, w = tw - bw2, h = padH }
    drawBtn(state.btns.m100, " -100 ", color and colors.brown or colors.black)
    drawBtn(state.btns.m50, " -50 ", color and colors.brown or colors.black)
    drawBtn(state.btns.m10, " -10 ", color and colors.brown or colors.black)
    drawBtn(state.btns.b10, " +10 ", color and colors.gray or colors.black)
    drawBtn(state.btns.b50, " +50 ", color and colors.lightGray or colors.black)
    drawBtn(state.btns.b100, " +100 ", color and colors.white or colors.black, colors.black)
    drawBtn(state.btns.deal, " DEAL ", color and colors.lime or colors.white, colors.black)
    local qLab = FROM_LAUNCHER and (pocket and " X " or " CLOSE ") or (pocket and " Q " or " QUIT ")
    drawBtn(state.btns.quit, qLab, color and colors.red or colors.black)
  elseif state.phase == "hold" then
    state.btns.draw = { x = 1, y = by, w = math.floor(tw * 2 / 3), h = padH }
    state.btns.quit = { x = state.btns.draw.w + 1, y = by, w = tw - state.btns.draw.w, h = padH }
    drawBtn(state.btns.draw, " DRAW ", color and colors.orange or colors.white, colors.black)
    local qLab = FROM_LAUNCHER and (pocket and " X " or " CLOSE ") or (pocket and " Q " or " QUIT ")
    drawBtn(state.btns.quit, qLab, color and colors.red or colors.black)
  else
    state.btns.deal = { x = 1, y = by, w = math.floor(tw * 2 / 3), h = padH }
    state.btns.quit = { x = state.btns.deal.w + 1, y = by, w = tw - state.btns.deal.w, h = padH }
    drawBtn(state.btns.deal, COINS > 0 and " NEXT " or " BROKE ",
      color and colors.lime or colors.white, colors.black)
    local qLab = FROM_LAUNCHER and (pocket and " X " or " CLOSE ") or (pocket and " Q " or " QUIT ")
    drawBtn(state.btns.quit, qLab, color and colors.red or colors.black)
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
  local ok = spendBet(state.bet)
  if not ok then return false end
  if not USE_CASINO then saveCfg() end
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
  local pKey, pName = handRank(state.hand)
  local lKey, lName = handRank(state.luigi)
  local cmp = cmpHandKey(pKey, lKey)
  if cmp > 0 then
    local bonus = bonusMult(state.hand)
    local mult = math.max(2, bonus > 0 and bonus or 2)
    state.win = state.bet * mult
    state.outcome = "win"
    state.resultName = "Beat Luigi! " .. pName
    creditWin(state.win)
    sfx("win")
  elseif cmp == 0 then
    state.win = state.bet
    state.outcome = "push"
    state.resultName = "Push — " .. pName
    creditWin(state.win)
    sfx("coin")
  else
    state.win = 0
    state.outcome = "lose"
    state.resultName = "Luigi wins — " .. lName
    sfx("lose")
  end
  if not USE_CASINO then saveCfg() end
  state.phase = "result"
end

local function main()
  attachMonitor()
  initEconomy()
  maybeEquipMusicBack()
  refreshSpeaker()
  if musicPlayer then musicPlayer:start("menu") end
  local state = newState()
  state.bet = clampBet(state.bet or 1)
  local musicTimer = os.startTimer(MUSIC_ON and 0.05 or 3600)
  drawScreen(state)

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
          state.bet = clampBet(state.bet)
          drawScreen(state)
        elseif inBtn(b.quit, mx, my) then
          return
        end
      elseif state.phase == "bet" then
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
        elseif inBtn(b.deal, mx, my) then
          state.bet = clampBet(state.bet)
          if dealHand(state) then drawScreen(state) end
        elseif inBtn(b.quit, mx, my) then
          return
        end
      else
        if inBtn(b.deal, mx, my) then
          state.phase = "bet"
          state.hand, state.luigi = {}, {}
          state.outcome = nil
          state.bet = clampBet(state.bet)
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
        if p1 == K.one then addBet(state, 10); drawScreen(state)
        elseif p1 == K.two then addBet(state, 50); drawScreen(state)
        elseif p1 == K.three then addBet(state, 100); drawScreen(state)
        elseif p1 == K.four then addBet(state, -10); drawScreen(state)
        elseif p1 == K.five then addBet(state, -50); drawScreen(state)
        elseif p1 == K.six then addBet(state, -100); drawScreen(state)
        elseif p1 == K.space or p1 == K.enter then
          state.bet = clampBet(state.bet)
          if dealHand(state) then drawScreen(state) end
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
          state.phase = "bet"
          state.hand, state.luigi = {}, {}
          state.outcome = nil
          state.bet = clampBet(state.bet)
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
      elseif state.phase == "bet" and ch == "1" then
        addBet(state, 10); drawScreen(state)
      elseif state.phase == "bet" and ch == "2" then
        addBet(state, 50); drawScreen(state)
      elseif state.phase == "bet" and ch == "3" then
        addBet(state, 100); drawScreen(state)
      elseif state.phase == "bet" and ch == "4" then
        addBet(state, -10); drawScreen(state)
      elseif state.phase == "bet" and ch == "5" then
        addBet(state, -50); drawScreen(state)
      elseif state.phase == "bet" and ch == "6" then
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
