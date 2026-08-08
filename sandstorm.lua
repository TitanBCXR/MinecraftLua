--[[
  sandstorm.lua  -  Note-block Sandstorm knockoff + monitor pixel show
  Titan-Version: 1.0.1

  Run:

      sandstorm
      sandstorm --launcher   (from Games launcher: Close returns, no shutdown)

  Needs a speaker (or Noisy pocket). Advanced color monitor preferred for the
  visualizer; works on the computer screen too.

  Touch / keys:
    Space / Enter / tap PLAY  start·stop
    M mute   Q / CLOSE quit
]]

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
local PLAYING = false
local STEP = 1
local BEAT = 0
local ENERGY = 0
local TITLE_FLASH = 0

--------------------------------------------------------------------------------
-- Sandstorm-ish arrangement (chiptune knockoff — not the original recording).
-- Pitches 0..24. Fast 16ths ~140 BPM → beat ≈ 0.105s.
--------------------------------------------------------------------------------
local BEAT_SEC = 0.105

-- { pitch|false, beats, accent? }  accent drives the visualizer harder
local function n(p, b, a)
  return { p, b or 1, a == true }
end

local TRACK = {}
do
  local function add(seq)
    for i = 1, #seq do TRACK[#TRACK + 1] = seq[i] end
  end

  -- Intro: muted stabs building in
  for _ = 1, 2 do
    add({
      n(12, 1), n(false, 1), n(12, 1), n(false, 1),
      n(12, 1), n(false, 1), n(12, 1), n(false, 1),
      n(15, 1), n(false, 1), n(15, 1), n(false, 1),
      n(17, 1), n(false, 1), n(17, 1), n(false, 1),
    })
  end

  -- Main riff A (the recognizable sandstorm pulse)
  local function riffA(hi)
    local a, b, c = 12, 15, 17
    if hi then a, b, c = 17, 20, 22 end
    return {
      n(a, 1, true), n(a, 1), n(a, 1), n(a, 1),
      n(a, 1, true), n(a, 1), n(a, 1), n(a, 1),
      n(b, 1, true), n(b, 1), n(b, 1), n(b, 1),
      n(c, 1, true), n(c, 1), n(c, 1), n(c, 1),
    }
  end

  for _ = 1, 2 do add(riffA(false)) end

  -- Answer phrase
  add({
    n(17, 1, true), n(17, 1), n(17, 1), n(17, 1),
    n(17, 1, true), n(17, 1), n(17, 1), n(17, 1),
    n(15, 1, true), n(15, 1), n(15, 1), n(15, 1),
    n(12, 1, true), n(12, 1), n(12, 1), n(12, 1),
  })

  -- Lift / "du-du-du-du" higher register
  for _ = 1, 2 do add(riffA(true)) end

  -- Drop: denser doubles + hats feel via short notes
  for _ = 1, 2 do
    add({
      n(12, 1, true), n(12, 1, true), n(12, 1), n(12, 1),
      n(12, 1, true), n(12, 1, true), n(12, 1), n(12, 1),
      n(15, 1, true), n(15, 1, true), n(15, 1), n(15, 1),
      n(17, 1, true), n(17, 1, true), n(17, 1), n(17, 1),
      n(19, 1, true), n(19, 1), n(19, 1, true), n(19, 1),
      n(22, 1, true), n(22, 1), n(22, 1, true), n(22, 1),
      n(24, 1, true), n(22, 1), n(20, 1, true), n(17, 1),
      n(15, 1, true), n(12, 1), n(15, 1, true), n(17, 1),
    })
  end

  -- Outro fade (sparser)
  add({
    n(12, 2, true), n(false, 2), n(15, 2), n(false, 2),
    n(17, 2, true), n(false, 2), n(12, 4, true), n(false, 4),
  })
end

local BASS = {
  0, 0, 0, 0, 5, 5, 5, 5, 3, 3, 3, 3, 0, 0, 7, 7,
}

--------------------------------------------------------------------------------
-- Display
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
      m.setTextScale(0.5) -- denser pixel show
      local w, h = m.getSize()
      if w >= 40 and h >= 24 then m.setTextScale(1) end
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
    NATIVE.write("Sandstorm on monitor")
    NATIVE.setCursorPos(1, 2)
    NATIVE.write("Close UI — tap PLAY")
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

--------------------------------------------------------------------------------
-- Audio
--------------------------------------------------------------------------------
local function refreshSpeaker()
  SPEAKER = peripheral.find("speaker")
  return SPEAKER ~= nil
end

local function stopAudio()
  if SPEAKER then pcall(function() SPEAKER.stop() end) end
end

local function playNote(inst, vol, pitch)
  if not SPEAKER or pitch == nil or pitch < 0 or pitch > 24 then return end
  pcall(function() SPEAKER.playNote(inst, vol, pitch) end)
end

local function musicStep()
  if not MUSIC_ON then return 0.25, false, 0 end
  if not SPEAKER and not refreshSpeaker() then return 0.5, false, 0 end

  local note = TRACK[STEP] or n(false, 1)
  STEP = STEP + 1
  if STEP > #TRACK then STEP = 1 end

  local pitch, beats, accent = note[1], tonumber(note[2]) or 1, note[3] == true
  BEAT = BEAT + 1
  local bassPitch = BASS[((BEAT - 1) % #BASS) + 1]

  -- Layered "trance synth" knockoff
  playNote("bass", accent and 0.35 or 0.22, bassPitch)
  if pitch ~= false and pitch ~= nil then
    playNote("bit", accent and 0.55 or 0.38, pitch)
    playNote("pling", accent and 0.32 or 0.18, pitch)
    playNote("guitar", 0.14, math.max(0, pitch - 5))
    if accent then
      playNote("hat", 0.22, 18)
      playNote("flute", 0.12, math.min(24, pitch + 7))
    end
  else
    playNote("hat", 0.08, 8)
  end

  local energy = 0.25
  if pitch ~= false then energy = energy + (pitch / 24) * 0.45 end
  if accent then energy = energy + 0.35 end
  ENERGY = ENERGY * 0.55 + energy * 0.45
  if accent then TITLE_FLASH = 4 end

  return math.max(0.05, beats * BEAT_SEC * 0.92), accent, pitch ~= false and pitch or bassPitch
end

--------------------------------------------------------------------------------
-- Visualizer (pixel / block show)
--------------------------------------------------------------------------------
local dunes = {} -- phase offsets per column
local bars = {}

local function initViz(tw, th)
  dunes = {}
  bars = {}
  for x = 1, tw do
    dunes[x] = (x / 7) + math.random() * 0.5
    bars[x] = 0
  end
end

local function sandColor(level, flash)
  if not isColor() then return colors.white end
  if flash > 0 and level > 0.7 then return colors.white end
  if level > 0.85 then return colors.yellow
  elseif level > 0.65 then return colors.orange
  elseif level > 0.4 then return colors.brown
  elseif level > 0.2 then return colors.red
  else return colors.gray end
end

local function drawFrame(controls)
  local tw, th = term.getSize()
  local color = isColor()
  local padH = USING_MONITOR and math.max(3, math.floor(th * 0.18)) or 3
  local vizH = th - padH
  if vizH < 4 then vizH = th - 1; padH = 1 end

  if #dunes ~= tw then initViz(tw, th) end

  -- Sky / flash
  local sky = colors.black
  if color and TITLE_FLASH > 0 then
    sky = (TITLE_FLASH % 2 == 0) and colors.purple or colors.black
    TITLE_FLASH = TITLE_FLASH - 1
  end
  fill(1, 1, tw, vizH, sky)

  -- Title
  local title = " SANDSTORM "
  local tx = math.max(1, math.floor((tw - #title) / 2) + 1)
  local tfg = (TITLE_FLASH > 0 and color) and colors.yellow or colors.white
  local tbg = (TITLE_FLASH > 0 and color) and colors.red or colors.black
  textAt(tx, 1, title, tfg, tbg)
  textAt(2, 2, PLAYING and (MUSIC_ON and "PLAYING" or "MUTED") or "READY",
    color and colors.lime or colors.white, sky)

  -- Desert dunes (sine sand rows)
  local t = BEAT * 0.35
  for x = 1, tw do
    local wave = math.sin(dunes[x] + t) * 0.5 + math.sin(dunes[x] * 0.4 + t * 1.7) * 0.25
    local h = math.floor((vizH * 0.25) + wave * (vizH * 0.12) + ENERGY * (vizH * 0.2))
    h = math.max(1, math.min(vizH - 3, h))
    local y0 = vizH - h + 1
    for y = y0, vizH do
      local level = (y - y0 + 1) / h
      local c = sandColor(level * (0.5 + ENERGY), TITLE_FLASH)
      if color then
        term.setBackgroundColor(c)
        term.setCursorPos(x, y)
        term.write(" ")
      else
        term.setCursorPos(x, y)
        term.write(level > 0.6 and "#" or (level > 0.3 and "=" or "."))
      end
    end
  end

  -- Spectrum bars (top band)
  local barRow = 3
  local barMax = math.max(2, math.floor(vizH * 0.35))
  for x = 1, tw do
    local target = ENERGY * barMax * (0.55 + 0.45 * math.abs(math.sin(x * 0.4 + t * 2)))
    if PLAYING then
      bars[x] = (bars[x] or 0) * 0.65 + target * 0.35
    else
      bars[x] = (bars[x] or 0) * 0.85
    end
    local h = math.floor(bars[x] + 0.5)
    for y = 0, h - 1 do
      local yy = barRow + (barMax - 1 - y)
      if yy >= 3 and yy < vizH - 1 then
        local c = sandColor(0.4 + y / barMax, TITLE_FLASH)
        if color then
          term.setBackgroundColor(c)
          term.setCursorPos(x, yy)
          term.write(" ")
        else
          term.setCursorPos(x, yy)
          term.write("|")
        end
      end
    end
  end

  -- Lightning bolts on accents
  if TITLE_FLASH >= 3 and color and vizH > 8 then
    local lx = 2 + (BEAT * 7) % math.max(1, tw - 4)
    for i = 0, math.min(6, vizH - 4) do
      term.setBackgroundColor(colors.white)
      term.setCursorPos(lx + (i % 3) - 1, 3 + i)
      term.write(" ")
    end
  end

  -- Controls
  local playLabel = PLAYING and " STOP " or " PLAY "
  local muteLabel = MUSIC_ON and " MUTE " or " UNMUTE "
  local quitLabel = FROM_LAUNCHER and " CLOSE " or " QUIT "
  local y = th - padH + 1
  local bw = math.floor(tw / 3)
  controls.play = { x = 1, y = y, w = bw, h = padH, id = "play" }
  controls.mute = { x = bw + 1, y = y, w = bw, h = padH, id = "mute" }
  controls.quit = { x = 2 * bw + 1, y = y, w = tw - 2 * bw, h = padH, id = "quit" }

  local function drawBtn(b, label, bg)
    fill(b.x, b.y, b.w, b.h, bg)
    local lx = b.x + math.max(0, math.floor((b.w - #label) / 2))
    local ly = b.y + math.floor((b.h - 1) / 2)
    textAt(lx, ly, label:sub(1, b.w), colors.white, bg)
  end

  if color then
    drawBtn(controls.play, playLabel, PLAYING and colors.orange or colors.lime)
    drawBtn(controls.mute, muteLabel, MUSIC_ON and colors.gray or colors.yellow)
    drawBtn(controls.quit, quitLabel, colors.red)
  else
    fill(1, y, tw, padH, colors.black)
    textAt(1, y, playLabel .. muteLabel .. quitLabel, colors.white, colors.black)
  end
end

local function hitControl(controls, mx, my)
  for _, key in ipairs({ "play", "mute", "quit" }) do
    local b = controls[key]
    if b and mx >= b.x and mx <= b.x + b.w - 1
        and my >= b.y and my <= b.y + b.h - 1 then
      return b.id
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
local function main()
  attachMonitor()
  refreshSpeaker()
  local tw, th = term.getSize()
  initViz(tw, th)

  if not SPEAKER then
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    print("Sandstorm needs a speaker")
    print("(or Noisy pocket).")
    print("Attach one, then re-run.")
    sleep(3)
    return
  end

  local controls = {}
  local musicTimer = nil
  local vizTimer = os.startTimer(0.08)
  drawFrame(controls)

  local function startPlay()
    PLAYING = true
    STEP = 1
    BEAT = 0
    ENERGY = 0.4
    TITLE_FLASH = 3
    refreshSpeaker()
    musicTimer = os.startTimer(0.05)
  end

  local function stopPlay()
    PLAYING = false
    stopAudio()
    musicTimer = nil
    ENERGY = 0
  end

  while true do
    local ev, p1, p2, p3 = pullEv()
    if ev == "timer" and musicTimer and p1 == musicTimer then
      if PLAYING and MUSIC_ON then
        local wait = musicStep()
        musicTimer = os.startTimer(wait)
        drawFrame(controls)
      elseif PLAYING then
        musicTimer = os.startTimer(0.2)
      end
    elseif ev == "timer" and p1 == vizTimer then
      if PLAYING then
        -- Idle decay between music ticks
        ENERGY = ENERGY * 0.92
        drawFrame(controls)
      end
      vizTimer = os.startTimer(0.08)
    elseif ev == "term_resize" then
      tw, th = term.getSize()
      initViz(tw, th)
      drawFrame(controls)
    elseif ev == "mouse_click" then
      local id = hitControl(controls, p2, p3)
      if id == "play" then
        if PLAYING then stopPlay() else startPlay() end
        drawFrame(controls)
      elseif id == "mute" then
        MUSIC_ON = not MUSIC_ON
        if not MUSIC_ON then stopAudio() end
        drawFrame(controls)
      elseif id == "quit" then
        stopPlay()
        return
      elseif not id then
        -- Tap viz area = play/stop
        if PLAYING then stopPlay() else startPlay() end
        drawFrame(controls)
      end
    elseif ev == "key" then
      if p1 == keys.space or p1 == keys.enter then
        if PLAYING then stopPlay() else startPlay() end
        drawFrame(controls)
      elseif p1 == keys.m then
        MUSIC_ON = not MUSIC_ON
        if not MUSIC_ON then stopAudio() end
        drawFrame(controls)
      elseif p1 == keys.q or p1 == keys.backspace then
        stopPlay()
        return
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "m" then
        MUSIC_ON = not MUSIC_ON
        if not MUSIC_ON then stopAudio() end
        drawFrame(controls)
      elseif ch == "q" then
        stopPlay()
        return
      elseif ch == " " then
        if PLAYING then stopPlay() else startPlay() end
        drawFrame(controls)
      end
    elseif ev == "terminate" then
      stopPlay()
      return
    end
  end
end

math.randomseed(os.epoch("utc") % 2147483647)
local ok, err = pcall(main)
stopAudio()
detachMonitor()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok then error(err, 0) end
