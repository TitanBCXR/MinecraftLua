--[[
  storage/managers/storage_clutch.lua  -  Storage fill → Create clutch
  Titan-Version: 1.6.0

  Reads a Sophisticated Storage (or any inventory) over the wired modem
  network and drives a Create clutch via redstone.

  IMPORTANT: Wired modem cable does NOT carry redstone. Use one of:
    A) Local face — PC touching redstone dust / clutch
    B) Advanced Peripherals Redstone Integrator next to the clutch,
       with a wired modem on the same cable as the PC + storage

  Hardware (typical):
    [Sophisticated chest] --wired modem--+
    [Clutch + Integrator] --wired modem--+-- cable -- [PC + wired modem]
    (or PC redstone face → dust → clutch)

  Hysteresis (default Create: powered clutch = STOP shaft):
    off 60% → stop feed (redstone ON / clutch engaged) at/above 60%
    on  20% → resume feed (redstone OFF / clutch idle) at/below 20%
    Between those points the last state is held (no chatter).
    Use `invert` if your wiring is the opposite (powered = run).

  Display: steampunk instrument panel (arc gauge, brass tube, rate meter,
  RS lamp cell) on an attached color monitor, or the advanced computer term
  when no monitor is present.

  Setup:
    invs | integrators
    bind storage <side|name>
    bind redstone <side>                 -- local PC face
    bind integrator <name> [side]        -- remote Redstone Integrator
    on <percent>                         -- resume feed at/below this fill %
    off <percent>                        -- stop feed at/above this fill %
    invert on|off
    interval <seconds>
    run | status | monitor | test on|off | help
]]

local LOCAL_CFG = "storage_clutch.cfg"
local VERSION = "1.6.0"

local cfg = {
  storage = nil,           -- inventory peripheral name
  -- Redstone output (pick one):
  rsSide = nil,            -- local computer face
  integrator = nil,        -- redstoneIntegrator peripheral
  integratorSide = "front",
  -- Hysteresis (feed): resume at onPct, stop at offPct (hold between)
  -- Create default: stop = redstone ON, resume = redstone OFF
  onPct = 20,
  offPct = 60,
  invert = false,
  interval = 1,            -- seconds between polls
  label = nil,
}

-- Last desired redstone state (before invert) for the hysteresis band.
-- true = engage clutch / stop feed (Create default); false = run feed.
local latchedOn = false

-- Sliding window for fill-rate (pct/min, items/min)
local rateSamples = {}
local RATE_WINDOW_MS = 60000
local RATE_MAX_SAMPLES = 120

local SIDES = {
  left = true, right = true, front = true, back = true, top = true, bottom = true,
}

--------------------------------------------------------------------------------
local function loadCfg()
  if not fs.exists(LOCAL_CFG) then return end
  local f = fs.open(LOCAL_CFG, "r")
  if not f then return end
  local ok, d = pcall(textutils.unserialize, f.readAll())
  f.close()
  if ok and type(d) == "table" then
    for k, v in pairs(d) do cfg[k] = v end
  end
  -- Migrate legacy single-threshold configs → resume(on) / stop(off)
  if (cfg.onPct == nil or cfg.offPct == nil) and cfg.threshold ~= nil then
    local th = tonumber(cfg.threshold) or 90
    local when = tostring(cfg.when or "full"):lower()
    if when == "empty" or when == "below" then
      cfg.onPct = cfg.onPct or math.min(th, 20)
      cfg.offPct = cfg.offPct or math.max(th, 60)
    else
      -- old "full/above": stop near threshold, resume ~30% below
      cfg.offPct = cfg.offPct or th
      cfg.onPct = cfg.onPct or math.max(0, th - 30)
    end
  end
  cfg.onPct = math.max(0, math.min(100, tonumber(cfg.onPct) or 20))
  cfg.offPct = math.max(0, math.min(100, tonumber(cfg.offPct) or 60))
end

local function saveCfg()
  local f = fs.open(LOCAL_CFG, "w")
  if f then f.write(textutils.serialize(cfg)); f.close() end
end

local function isInventory(name)
  if not name or not peripheral.isPresent(name) then return false end
  if peripheral.hasType and peripheral.hasType(name, "inventory") then return true end
  local w = peripheral.wrap(name)
  return w and type(w.list) == "function"
end

local function isIntegrator(name)
  if not name or not peripheral.isPresent(name) then return false end
  local t = tostring(peripheral.getType(name) or ""):lower()
  if t:find("redstoneintegrator", 1, true) or t == "redstone_integrator" then
    return true
  end
  if peripheral.hasType then
    if peripheral.hasType(name, "redstoneIntegrator")
       or peripheral.hasType(name, "redstone_integrator") then
      return true
    end
  end
  local w = peripheral.wrap(name)
  return w and (type(w.setOutput) == "function" or type(w.setAnalogOutput) == "function")
      and type(w.list) ~= "function" -- avoid mistaking inventories
end

local function isSideName(name)
  return SIDES[tostring(name or ""):lower()] == true
end

local function collectNames(pred)
  local out, seen = {}, {}
  local function add(n)
    if n and not seen[n] and pred(n) then
      seen[n] = true
      out[#out + 1] = n
    end
  end
  for _, name in ipairs(peripheral.getNames()) do add(name) end
  for _, sideName in ipairs(peripheral.getNames()) do
    if peripheral.getType(sideName) == "modem" then
      local m = peripheral.wrap(sideName)
      if m and type(m.getNamesRemote) == "function" then
        for _, n in ipairs(m.getNamesRemote() or {}) do add(n) end
      end
    end
  end
  table.sort(out)
  return out
end

local function resolveByRef(ref, pred)
  if not ref or ref == "" then return nil end
  local s = tostring(ref)
  if pred(s) then return s end

  local side = s:lower()
  if SIDES[side] and peripheral.isPresent(side) then
    if pred(side) then return side end
    local t = peripheral.getType(side)
    local wrap = peripheral.wrap(side)
    if t == "modem" and wrap and type(wrap.getNamesRemote) == "function" then
      for _, n in ipairs(wrap.getNamesRemote() or {}) do
        if pred(n) then return n end
      end
    end
  end

  local want = s:lower()
  local hits = {}
  for _, n in ipairs(collectNames(pred)) do
    if n:lower():find(want, 1, true) then hits[#hits + 1] = n end
  end
  if #hits == 1 then return hits[1] end
  if #hits > 1 then return nil, hits end
  return nil
end

--------------------------------------------------------------------------------
-- Storage fill
--------------------------------------------------------------------------------
local function storageFill(name)
  local w = name and peripheral.wrap(name)
  if not w or type(w.list) ~= "function" then
    return nil, "storage missing"
  end
  local list = w.list() or {}
  local size = (type(w.size) == "function" and w.size()) or 0
  if size <= 0 then
    -- fallback: highest occupied slot
    for slot in pairs(list) do
      if type(slot) == "number" and slot > size then size = slot end
    end
    if size <= 0 then size = 27 end
  end
  local used, items = 0, 0
  for _, stack in pairs(list) do
    if type(stack) == "table" and (stack.count or 0) > 0 then
      used = used + 1
      items = items + (stack.count or 0)
    end
  end
  local pct = math.floor((used / size) * 100 + 0.5)
  return { used = used, size = size, items = items, pct = pct }
end

--- Desired redstone before invert.
--- Feed semantics: offPct = stop feeding, onPct = resume feeding.
--- Create clutch default (power = stop): stop → rs ON, resume → rs OFF.
local function desiredOn(fill)
  local pct = fill.pct
  local resumeP = tonumber(cfg.onPct) or 20
  local stopP = tonumber(cfg.offPct) or 60

  if resumeP == stopP then
    -- single trip: stop (rs ON) at/above, run (rs OFF) below
    latchedOn = (pct >= stopP)
    return latchedOn
  end

  if resumeP < stopP then
    -- Normal band: stop at/above off%, resume at/below on% (hold in between)
    if pct >= stopP then
      latchedOn = true
    elseif pct <= resumeP then
      latchedOn = false
    end
  else
    -- Swapped thresholds (on > off): stop at/above on%, resume at/below off%
    if pct >= resumeP then
      latchedOn = true
    elseif pct <= stopP then
      latchedOn = false
    end
  end
  return latchedOn
end

--------------------------------------------------------------------------------
-- Fill rate (sliding window)
--------------------------------------------------------------------------------
local function nowMs()
  if type(os.epoch) == "function" then
    return os.epoch("utc")
  end
  return math.floor(os.clock() * 1000)
end

local function recordFill(fill)
  if not fill then return end
  local t = nowMs()
  rateSamples[#rateSamples + 1] = {
    t = t,
    pct = fill.pct or 0,
    used = fill.used or 0,
    items = fill.items or 0,
  }
  local cutoff = t - RATE_WINDOW_MS
  while #rateSamples > 1 and rateSamples[1].t < cutoff do
    table.remove(rateSamples, 1)
  end
  while #rateSamples > RATE_MAX_SAMPLES do
    table.remove(rateSamples, 1)
  end
end

--- Returns { itemsPerMin, ready } or nil if not enough samples
local function fillRate()
  if #rateSamples < 2 then return nil end
  local a, b = rateSamples[1], rateSamples[#rateSamples]
  local dt = (b.t - a.t) / 1000
  if dt < 2 then return nil end
  return {
    itemsPerMin = ((b.items - a.items) / dt) * 60,
    dt = dt,
    ready = true,
  }
end

local function formatRate(rate)
  if not rate then return "rate …" end
  local it = rate.itemsPerMin or 0
  if math.abs(it) < 0.5 then return "0 it/m" end
  local sign = (it > 0 and "+") or ""
  if math.abs(it) >= 100 then
    return string.format("%s%.0f it/m", sign, it)
  end
  return string.format("%s%.1f it/m", sign, it)
end

local function rateColor(rate)
  if not rate then return colors.gray end
  local it = rate.itemsPerMin or 0
  if it > 1 then return colors.lime
  elseif it < -1 then return colors.orange
  else return colors.lightGray
  end
end

--------------------------------------------------------------------------------
-- Steampunk display (monitor or advanced computer term)
--------------------------------------------------------------------------------
local function findMonitor()
  local m = peripheral.find("monitor")
  if m then return m end
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "monitor" then
      return peripheral.wrap(side)
    end
  end
  return nil
end

local function outIsColor(out)
  local ok, c = pcall(function()
    return out.isColor and out.isColor()
  end)
  return ok and c == true
end

--- Resolve draw target: attached monitor, else color term (advanced PC).
local function resolveDisplay()
  local mon = findMonitor()
  if mon then return mon, "monitor" end
  if term and term.isColor and term.isColor() then
    return term, "term"
  end
  return nil, nil
end

-- Brass / copper / iron palette (color) with mono fallbacks
local function steamPalette(color)
  if color then
    return {
      bg = colors.black,
      frame = colors.orange,       -- brass
      rivet = colors.yellow,       -- polished brass
      iron = colors.lightGray,
      soot = colors.gray,
      copper = colors.brown,
      steam = colors.white,
      accent = colors.orange,
      danger = colors.red,
      ok = colors.lime,
      warn = colors.yellow,
      dim = colors.gray,
      lampOn = colors.lime,        -- RS ON  → green cell
      lampOff = colors.red,        -- RS OFF → red cell
    }
  end
  return {
    bg = colors.black,
    frame = colors.white,
    rivet = colors.white,
    iron = colors.white,
    soot = colors.black,
    copper = colors.white,
    steam = colors.white,
    accent = colors.white,
    danger = colors.white,
    ok = colors.white,
    warn = colors.white,
    dim = colors.white,
    lampOn = colors.white,
    lampOff = colors.black,
  }
end

local function gaugeColor(pct, pal, color)
  pct = math.max(0, math.min(100, tonumber(pct) or 0))
  if not color then return pal.steam end
  if pct >= 80 then return pal.danger
  elseif pct >= 60 then return pal.warn
  elseif pct >= 40 then return pal.accent
  else return pal.ok
  end
end

local function monWrite(out, x, y, text, fg, bg)
  if not out then return end
  local w, h = out.getSize()
  if y < 1 or y > h or x > w then return end
  if out.setBackgroundColor and bg then out.setBackgroundColor(bg) end
  if out.setTextColor and fg then out.setTextColor(fg) end
  out.setCursorPos(math.max(1, x), y)
  out.write(tostring(text):sub(1, w - math.max(1, x) + 1))
end

local function monCenter(out, y, text, fg, bg)
  local w = select(1, out.getSize())
  text = tostring(text or "")
  local x = math.max(1, math.floor((w - #text) / 2) + 1)
  monWrite(out, x, y, text, fg, bg)
end

--- One-cell RS lamp: green = redstone ON, red = redstone OFF.
local function drawRsLamp(out, x, y, rsOn, pal, color)
  local lampBg, lampFg
  if rsOn == true then
    lampBg = pal.lampOn
    lampFg = color and colors.black or colors.white
  elseif rsOn == false then
    lampBg = pal.lampOff
    lampFg = color and colors.white or colors.black
  else
    lampBg = pal.soot
    lampFg = pal.dim
  end
  monWrite(out, x, y, " ", lampFg, lampBg)
end

local function drawFrame(out, pal, title)
  local w, h = out.getSize()
  if w < 3 or h < 3 then return end
  local top = "o" .. string.rep("=", math.max(0, w - 2)) .. "o"
  local bot = "o" .. string.rep("=", math.max(0, w - 2)) .. "o"
  monWrite(out, 1, 1, top, pal.rivet, pal.bg)
  monWrite(out, 1, h, bot, pal.rivet, pal.bg)
  for y = 2, h - 1 do
    monWrite(out, 1, y, "|", pal.frame, pal.bg)
    monWrite(out, w, y, "|", pal.frame, pal.bg)
  end
  -- Corner + side rivets
  monWrite(out, 1, 1, "o", pal.rivet, pal.bg)
  monWrite(out, w, 1, "o", pal.rivet, pal.bg)
  monWrite(out, 1, h, "o", pal.rivet, pal.bg)
  monWrite(out, w, h, "o", pal.rivet, pal.bg)
  if h >= 8 then
    local mid = math.floor(h / 2)
    for _, y in ipairs({ 3, mid, h - 2 }) do
      if y > 1 and y < h then
        monWrite(out, 1, y, "+", pal.rivet, pal.bg)
        monWrite(out, w, y, "+", pal.rivet, pal.bg)
      end
    end
  end
  if title and h >= 3 and w >= 8 then
    local t = " " .. tostring(title) .. " "
    if #t > w - 4 then t = t:sub(1, w - 4) end
    local x = math.max(2, math.floor((w - #t) / 2) + 1)
    monWrite(out, x, 1, t, pal.accent, pal.bg)
  end
end

--- Brass pressure-tube bar with tick marks under the glass.
local function drawBrassTube(out, x, y, ww, pct, fillFg, pal, color)
  local W = select(1, out.getSize())
  ww = math.min(ww, W - x + 1)
  if ww < 4 then return end
  pct = math.max(0, math.min(100, tonumber(pct) or 0))
  local inner = ww - 2
  local filled = math.floor((pct / 100) * inner + 0.5)
  monWrite(out, x, y, "[", pal.iron, pal.bg)
  monWrite(out, x + 1, y, string.rep(" ", inner), pal.steam, pal.soot)
  if filled > 0 then
    -- Mixed brass fill chars for a tube look
    local chars = {}
    for i = 1, filled do
      if i == filled then
        chars[i] = ">"
      elseif (i % 3) == 0 then
        chars[i] = "#"
      else
        chars[i] = "="
      end
    end
    monWrite(out, x + 1, y, table.concat(chars), fillFg, pal.soot)
  end
  monWrite(out, x + ww - 1, y, "]", pal.iron, pal.bg)
  -- Tick marks on row below when space allows (caller may use y+1)
  return inner
end

local function drawTubeTicks(out, x, y, inner, pal)
  if inner < 4 then return end
  local ticks = {}
  for i = 1, inner do
    local p = (i / inner) * 100
    if math.abs(p - 0) < 0.1 or math.abs(p - 50) < (100 / inner)
       or math.abs(p - 100) < 0.1 or i == 1 or i == inner
       or math.abs(p - 25) < (100 / inner) or math.abs(p - 75) < (100 / inner) then
      ticks[i] = "|"
    else
      ticks[i] = "-"
    end
  end
  monWrite(out, x, y, "[", pal.dim, pal.bg)
  monWrite(out, x + 1, y, table.concat(ticks), pal.copper, pal.bg)
  monWrite(out, x + inner + 1, y, "]", pal.dim, pal.bg)
end

--- Small horizontal rate meter (items/min), needle-ish marker.
local function drawRateMeter(out, x, y, ww, rate, pal, color)
  local W = select(1, out.getSize())
  ww = math.min(ww, W - x + 1)
  if ww < 5 then return end
  local inner = ww - 2
  monWrite(out, x, y, "{", pal.iron, pal.bg)
  monWrite(out, x + 1, y, string.rep(".", inner), pal.dim, pal.soot)
  monWrite(out, x + ww - 1, y, "}", pal.iron, pal.bg)
  -- Center tick
  local mid = x + 1 + math.floor((inner - 1) / 2)
  monWrite(out, mid, y, "|", pal.rivet, pal.soot)
  if not rate then return end
  local it = rate.itemsPerMin or 0
  -- Map roughly ±120 it/m across the meter
  local span = 120
  local t = math.max(-1, math.min(1, it / span))
  local pos = math.floor(((t + 1) / 2) * (inner - 1) + 0.5)
  local nx = x + 1 + pos
  local nfg = rateColor(rate)
  if not color then nfg = pal.steam end
  monWrite(out, nx, y, "*", nfg, pal.soot)
end

local function boxCenter(out, boxX, boxW, y, text, fg, bg)
  text = tostring(text or "")
  local x = boxX + math.max(0, math.floor((boxW - #text) / 2))
  monWrite(out, x, y, text, fg, bg)
end

--- Arc-style circular gauge approximated with character cells.
--- Layout (width ~11–15, height 5):
---   .-'---'-.     ticks + rim
---  /    ^    \    needle toward fill %
--- |   XX%     |   big readout
---  \         /
---   '-.___.-'
local function drawArcGauge(out, x, y, gw, gh, pct, fillFg, pal, color)
  local W, H = out.getSize()
  if gw < 9 or gh < 4 then return false end
  if x + gw - 1 > W or y + gh - 1 > H then
    gw = math.min(gw, W - x + 1)
    gh = math.min(gh, H - y + 1)
  end
  if gw < 9 or gh < 4 then return false end
  pct = math.max(0, math.min(100, tonumber(pct) or 0))

  local function place(row, text, fg, bg)
    text = tostring(text or "")
    if #text > gw then text = text:sub(1, gw) end
    boxCenter(out, x, gw, row, text, fg, bg)
    return text
  end

  -- Rim / arc rows
  local rim = string.rep("-", math.max(3, gw - 4))
  place(y, ".-" .. rim .. "-.", pal.frame, pal.bg)

  -- Tick row with needle tip
  local tickInner = math.max(3, gw - 4)
  local ticks = {}
  for i = 1, tickInner do ticks[i] = "-" end
  ticks[1] = "0"
  if tickInner >= 5 then ticks[math.floor(tickInner / 2) + 1] = "^" end
  ticks[tickInner] = "F"
  local ni = math.max(1, math.min(tickInner, math.floor((pct / 100) * (tickInner - 1) + 0.5) + 1))
  ticks[ni] = "v"
  local tickLine = place(y + 1, "/" .. table.concat(ticks) .. "\\", pal.rivet, pal.bg)
  local needleX = x + math.floor((gw - #tickLine) / 2) + ni
  monWrite(out, needleX, y + 1, "v", fillFg, pal.bg)

  local pctText = string.format("%d%%", pct)
  if gh >= 5 then
    place(y + 2, "|" .. string.rep(" ", math.max(0, gw - 2)) .. "|", pal.frame, pal.bg)
    boxCenter(out, x, gw, y + 2, pctText, fillFg, pal.bg)
    place(y + 3, "\\_" .. string.rep("_", math.max(1, gw - 4)) .. "_/", pal.copper, pal.bg)
    if gh >= 6 then
      boxCenter(out, x, gw, y + 4, "GAUGE", pal.copper, pal.bg)
    end
  else
    boxCenter(out, x, gw, y + 2, pctText, fillFg, pal.bg)
    place(y + 3, "'-" .. string.rep("=", math.max(1, gw - 4)) .. "-'", pal.copper, pal.bg)
  end
  return true
end

--- Compact semicircle for narrow panels.
local function drawMiniArc(out, x, y, ww, pct, fillFg, pal)
  pct = math.max(0, math.min(100, tonumber(pct) or 0))
  local inner = math.max(3, ww - 2)
  local filled = math.floor((pct / 100) * inner + 0.5)
  local chars = {}
  for i = 1, inner do
    if i <= filled then
      chars[i] = (i == filled) and "v" or "="
    else
      chars[i] = "-"
    end
  end
  monWrite(out, x, y, "(" .. table.concat(chars) .. ")", pal.frame, pal.bg)
  if filled > 0 then
    monWrite(out, x + filled, y, (filled == inner and "=" or "v"), fillFg, pal.bg)
  end
end

--- Steampunk brass instrument panel. fill/rsOn optional.
local function drawMonitor(fill, rsOn)
  local out, kind = resolveDisplay()
  if not out then return false, "no monitor / color term" end

  if not fill and cfg.storage then
    fill = storageFill(cfg.storage)
    if fill then recordFill(fill) end
  end
  if rsOn == nil then
    rsOn = (latchedOn ~= not not cfg.invert)
  end

  local rate = fillRate()
  local color = outIsColor(out)
  local pal = steamPalette(color)

  if kind == "monitor" then
    pcall(function()
      if out.setTextScale then
        local chosen = 0.5
        for _, scale in ipairs({ 2, 1, 0.5 }) do
          out.setTextScale(scale)
          local ww, hh = out.getSize()
          if ww >= 26 and hh >= 12 then
            chosen = scale
            break
          end
        end
        out.setTextScale(chosen)
      end
    end)
  end

  local w, h = out.getSize()
  if out.setBackgroundColor then out.setBackgroundColor(pal.bg) end
  out.clear()

  local pct = fill and fill.pct or 0
  local gfg = gaugeColor(pct, pal, color)
  local pctText = fill and string.format("%d%%", pct) or "--%"
  local rateText = formatRate(rate)
  local rfg = rateColor(rate)
  if not color then rfg = pal.steam end

  local band = ("BAND stop%d/run%d"):format(cfg.offPct or 60, cfg.onPct or 20)
  local bins = fill and ("SLOTS %d/%d"):format(fill.used, fill.size) or "SLOTS --/--"
  local stock = "STOCK " .. rateText
  local x0 = 2
  local innerW = w - 2

  -- Tiny screens
  if w < 12 or h < 5 then
    drawFrame(out, pal, "GAUGE")
    monCenter(out, math.max(2, math.floor(h / 2)), pctText, gfg, pal.bg)
    if h >= 4 and w >= 6 then
      monWrite(out, 2, h - 1, "RS", pal.dim, pal.bg)
      drawRsLamp(out, 4, h - 1, rsOn, pal, color)
    end
    return true
  end

  drawFrame(out, pal, "BRASS PANEL")

  --------------------------------------------------------------------------
  -- Large instrument board (wide + tall)
  --------------------------------------------------------------------------
  if w >= 28 and h >= 12 then
    -- Left: arc gauge · Right: meters + clutch lamp
    local gaugeW = math.min(15, math.floor(innerW * 0.45))
    local gaugeH = math.min(6, h - 5)
    drawArcGauge(out, x0, 2, gaugeW, gaugeH, pct, gfg, pal, color)

    local rx = x0 + gaugeW + 1
    local rw = w - rx
    if rw < 8 then rx = x0; rw = innerW end

    monWrite(out, rx, 2, "PRESSURE", pal.copper, pal.bg)
    drawBrassTube(out, rx, 3, rw, pct, gfg, pal, color)
    if h >= 14 then
      drawTubeTicks(out, rx, 4, math.max(1, rw - 2), pal)
    end

    monWrite(out, rx, 5, "STOCK", pal.copper, pal.bg)
    monWrite(out, rx, 6, rateText:sub(1, rw), rfg, pal.bg)
    drawRateMeter(out, rx, 7, rw, rate, pal, color)

    monWrite(out, rx, 9, "CLUTCH", pal.copper, pal.bg)
    drawRsLamp(out, rx + 7, 9, rsOn, pal, color)

    monWrite(out, x0, h - 2, bins:sub(1, innerW), pal.iron, pal.bg)
    monWrite(out, x0, h - 1, band:sub(1, innerW), pal.dim, pal.bg)

  --------------------------------------------------------------------------
  -- Medium board
  --------------------------------------------------------------------------
  elseif h >= 10 then
    monWrite(out, x0, 2, "GAUGE", pal.copper, pal.bg)
    if w >= 20 and h >= 12 then
      -- Side-by-side: arc left, meters right
      local gw = math.min(13, math.floor(innerW * 0.5))
      drawArcGauge(out, x0, 3, gw, 5, pct, gfg, pal, color)
      local rx = x0 + gw + 1
      local rw = w - rx - 1
      monWrite(out, rx, 3, "TUBE", pal.copper, pal.bg)
      drawBrassTube(out, rx, 4, rw, pct, gfg, pal, color)
      monWrite(out, rx, 6, "STOCK", pal.copper, pal.bg)
      monWrite(out, rx, 7, rateText:sub(1, rw), rfg, pal.bg)
      drawRateMeter(out, rx, 8, rw, rate, pal, color)
      monWrite(out, rx, 9, "RS", pal.dim, pal.bg)
      drawRsLamp(out, rx + 3, 9, rsOn, pal, color)
    elseif w >= 16 then
      drawArcGauge(out, x0, 3, math.min(13, innerW), 4, pct, gfg, pal, color)
      drawBrassTube(out, x0, 7, innerW, pct, gfg, pal, color)
      monWrite(out, x0, 8, stock:sub(1, math.max(1, innerW - 6)), rfg, pal.bg)
      monWrite(out, w - 7, 8, "RS", pal.dim, pal.bg)
      drawRsLamp(out, w - 5, 8, rsOn, pal, color)
      if h >= 11 then
        drawRateMeter(out, x0, 9, math.min(innerW, 16), rate, pal, color)
      end
    else
      monCenter(out, 3, pctText, gfg, pal.bg)
      drawMiniArc(out, x0, 4, innerW, pct, gfg, pal)
      drawBrassTube(out, x0, 5, innerW, pct, gfg, pal, color)
      monWrite(out, x0, 6, stock:sub(1, math.max(1, innerW - 6)), rfg, pal.bg)
      monWrite(out, w - 7, 6, "RS", pal.dim, pal.bg)
      drawRsLamp(out, w - 5, 6, rsOn, pal, color)
      drawRateMeter(out, x0, 7, math.min(innerW, 14), rate, pal, color)
    end
    monWrite(out, x0, h - 2, bins:sub(1, innerW), pal.iron, pal.bg)
    monWrite(out, x0, h - 1, band:sub(1, innerW), pal.dim, pal.bg)

  --------------------------------------------------------------------------
  -- Compact (h 7–9)
  --------------------------------------------------------------------------
  elseif h >= 7 then
    monWrite(out, x0, 2, "GAUGE", pal.copper, pal.bg)
    monCenter(out, 3, pctText, gfg, pal.bg)
    if w >= 14 then
      drawMiniArc(out, x0, 4, innerW, pct, gfg, pal)
      drawBrassTube(out, x0, 5, innerW, pct, gfg, pal, color)
    else
      drawBrassTube(out, x0, 4, innerW, pct, gfg, pal, color)
    end
    local stockLine = stock
    monWrite(out, x0, h - 2, stockLine:sub(1, math.max(1, innerW - 6)), rfg, pal.bg)
    monWrite(out, w - 7, h - 2, "RS", pal.dim, pal.bg)
    drawRsLamp(out, w - 5, h - 2, rsOn, pal, color)
    monWrite(out, x0, h - 1, (bins .. " " .. band):sub(1, innerW), pal.dim, pal.bg)

  --------------------------------------------------------------------------
  -- Short (h 5–6)
  --------------------------------------------------------------------------
  else
    monCenter(out, 2, pctText, gfg, pal.bg)
    drawBrassTube(out, x0, 3, innerW, pct, gfg, pal, color)
    monWrite(out, x0, 4, stock:sub(1, math.max(1, innerW - 6)), rfg, pal.bg)
    monWrite(out, w - 7, 4, "RS", pal.dim, pal.bg)
    drawRsLamp(out, w - 5, 4, rsOn, pal, color)
    if h >= 6 then
      monWrite(out, x0, 5, band:sub(1, innerW), pal.dim, pal.bg)
    end
  end

  return true
end

--------------------------------------------------------------------------------
-- Redstone output
--------------------------------------------------------------------------------
local function setRedstone(on)
  on = not not on
  if cfg.invert then on = not on end

  if cfg.integrator and peripheral.isPresent(cfg.integrator) then
    local w = peripheral.wrap(cfg.integrator)
    local side = tostring(cfg.integratorSide or "front"):lower()
    if type(w.setOutput) == "function" then
      local ok, err = pcall(w.setOutput, side, on)
      if not ok then return false, err end
      return true, on, "integrator"
    elseif type(w.setAnalogOutput) == "function" then
      local ok, err = pcall(w.setAnalogOutput, side, on and 15 or 0)
      if not ok then return false, err end
      return true, on, "integrator"
    end
    return false, "integrator has no setOutput"
  end

  if cfg.rsSide and isSideName(cfg.rsSide) then
    redstone.setOutput(cfg.rsSide:lower(), on)
    return true, on, "local"
  end

  return false, "no redstone output bound"
end

local function getRedstoneState()
  if cfg.integrator and peripheral.isPresent(cfg.integrator) then
    local w = peripheral.wrap(cfg.integrator)
    local side = tostring(cfg.integratorSide or "front"):lower()
    if type(w.getOutput) == "function" then
      local ok, v = pcall(w.getOutput, side)
      if ok then return not not v, "integrator" end
    end
    if type(w.getAnalogOutput) == "function" then
      local ok, v = pcall(w.getAnalogOutput, side)
      if ok then return (tonumber(v) or 0) > 0, "integrator" end
    end
  end
  if cfg.rsSide and isSideName(cfg.rsSide) then
    return redstone.getOutput(cfg.rsSide:lower()), "local"
  end
  return nil, "unbound"
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function cmdInvs()
  print("Inventories on network:")
  local names = collectNames(isInventory)
  if #names == 0 then print("  (none)"); return end
  for _, n in ipairs(names) do
    local mark = (n == cfg.storage) and " *" or ""
    local fill = storageFill(n)
    if fill then
      print(("  %s  %d/%d (%d%%)%s"):format(n, fill.used, fill.size, fill.pct, mark))
    else
      print("  " .. n .. mark)
    end
  end
end

local function cmdIntegrators()
  print("Redstone Integrators on network:")
  local names = collectNames(isIntegrator)
  if #names == 0 then
    print("  (none) — place Advanced Peripherals Redstone Integrator")
    print("  next to the clutch, wired-modem it onto this cable.")
    return
  end
  for _, n in ipairs(names) do
    local mark = (n == cfg.integrator) and " *" or ""
    print("  " .. n .. mark)
  end
end

local function cmdBindStorage(ref)
  if not ref or ref == "" then
    print("Usage: bind storage <side|name|substring>")
    return
  end
  local n, hits = resolveByRef(ref, isInventory)
  if not n then
    if hits then
      print("Ambiguous — matches:")
      for _, h in ipairs(hits) do print("  " .. h) end
    else
      print("No inventory matched: " .. tostring(ref))
    end
    return
  end
  cfg.storage = n
  saveCfg()
  local fill = storageFill(n)
  print("Storage bound: " .. n)
  if fill then
    print(("  fill %d/%d slots (%d%%), %d items"):format(
      fill.used, fill.size, fill.pct, fill.items))
  end
end

local function cmdBindRedstone(side)
  side = tostring(side or ""):lower()
  if not isSideName(side) then
    print("Usage: bind redstone <left|right|front|back|top|bottom>")
    print("  Local PC face that feeds redstone to the clutch.")
    return
  end
  cfg.rsSide = side
  cfg.integrator = nil -- prefer explicit local when set
  saveCfg()
  print("Local redstone output: " .. side)
  print("(Integrator unbound — local face takes priority when set alone.)")
end

local function cmdBindIntegrator(ref, side)
  if not ref or ref == "" then
    print("Usage: bind integrator <name|substring> [outputSide]")
    print("  outputSide = face of the Integrator block toward the clutch")
    return
  end
  local n, hits = resolveByRef(ref, isIntegrator)
  if not n then
    if hits then
      print("Ambiguous — matches:")
      for _, h in ipairs(hits) do print("  " .. h) end
    else
      print("No Redstone Integrator matched: " .. tostring(ref))
      print("Run: integrators")
    end
    return
  end
  cfg.integrator = n
  if side and isSideName(side) then
    cfg.integratorSide = side:lower()
  end
  cfg.rsSide = nil
  saveCfg()
  print(("Integrator bound: %s (output %s)"):format(n, cfg.integratorSide))
end

local function clampPct(n)
  n = tonumber(n)
  if not n then return nil end
  return math.max(0, math.min(100, n))
end

local function cmdOn(pct)
  local n = clampPct(pct)
  if not n then
    print("Usage: on <percent>   — resume feed at/below this fill %")
    print(("  current run(on)=%d%%  stop(off)=%d%%"):format(cfg.onPct or 20, cfg.offPct or 60))
    return
  end
  cfg.onPct = n
  saveCfg()
  print(("on %d%% resume feed  (off %d%% stop)"):format(cfg.onPct, cfg.offPct or 60))
end

local function cmdOff(pct)
  local n = clampPct(pct)
  if not n then
    print("Usage: off <percent>  — stop feed at/above this fill %")
    print(("  current run(on)=%d%%  stop(off)=%d%%"):format(cfg.onPct or 20, cfg.offPct or 60))
    return
  end
  cfg.offPct = n
  saveCfg()
  print(("off %d%% stop feed  (on %d%% resume)"):format(cfg.offPct, cfg.onPct or 20))
end

local function cmdInvert(arg)
  arg = tostring(arg or ""):lower()
  if arg == "on" or arg == "true" or arg == "1" then
    cfg.invert = true
  elseif arg == "off" or arg == "false" or arg == "0" then
    cfg.invert = false
  else
    cfg.invert = not cfg.invert
  end
  saveCfg()
  print("invert: " .. (cfg.invert and "on" or "off"))
end

local function cmdInterval(sec)
  local n = tonumber(sec)
  if not n or n <= 0 then
    print("Usage: interval <seconds>")
    return
  end
  cfg.interval = math.max(0.2, n)
  saveCfg()
  print(("interval: %.1fs"):format(cfg.interval))
end

local function cmdStatus()
  print(("Storage Clutch v%s"):format(VERSION))
  print(("  storage:    %s"):format(cfg.storage or "(unbound)"))
  if cfg.integrator then
    print(("  output:     integrator %s face %s"):format(
      cfg.integrator, cfg.integratorSide or "?"))
  elseif cfg.rsSide then
    print(("  output:     local %s"):format(cfg.rsSide))
  else
    print("  output:     (unbound)")
  end
  local onP, offP = cfg.onPct or 20, cfg.offPct or 60
  local invNote = cfg.invert and " (inverted)" or ""
  if onP < offP then
    print(("  band:       stop >= %d%% , resume <= %d%%%s"):format(offP, onP, invNote))
  elseif onP > offP then
    print(("  band:       stop >= %d%% , resume <= %d%%%s"):format(onP, offP, invNote))
  else
    print(("  band:       stop >= %d%%%s"):format(offP, invNote))
  end
  print("  polarity:   Create default — rs ON=stop feed, OFF=run (use invert if wired opposite)")
  print(("  interval:   %.1fs"):format(cfg.interval or 1))

  if cfg.storage then
    local fill, err = storageFill(cfg.storage)
    if fill then
      print(("  fill:       %d/%d slots (%d%%), %d items"):format(
        fill.used, fill.size, fill.pct, fill.items))
      local want = desiredOn(fill)
      local applied = (want ~= cfg.invert)
      print(("  latched:    %s → redstone %s"):format(
        want and "STOP" or "RUN", applied and "ON" or "OFF"))
      recordFill(fill)
      local rate = fillRate()
      if rate then
        print("  rate:       " .. formatRate(rate))
      else
        print("  rate:       (need a few seconds of samples)")
      end
      -- Don't paint over console status on the advanced term; monitor only here.
      if findMonitor() then
        pcall(drawMonitor, fill, applied)
      end
    else
      print("  fill:       " .. tostring(err))
    end
  end
  local cur, src = getRedstoneState()
  if cur ~= nil then
    print(("  redstone:   %s (%s)"):format(cur and "ON" or "OFF", src))
  end
  local _, kind = resolveDisplay()
  if kind == "monitor" then
    print("  display:    steampunk panel (monitor)")
  elseif kind == "term" then
    print("  display:    steampunk panel (advanced term via run/monitor)")
  else
    print("  display:    (attach monitor or use advanced PC)")
  end
end

local function cmdTest(arg)
  arg = tostring(arg or ""):lower()
  local on
  if arg == "on" or arg == "1" then on = true
  elseif arg == "off" or arg == "0" then on = false
  else
    print("Usage: test on|off")
    return
  end
  -- bypass invert for direct test
  local saved = cfg.invert
  cfg.invert = false
  local ok, err = setRedstone(on)
  cfg.invert = saved
  if ok then
    latchedOn = on  -- keep hysteresis in sync with forced state
    print("Redstone forced " .. (on and "ON" or "OFF"))
  else
    print("Failed: " .. tostring(err))
  end
end

local function cmdHelp()
  print([[
Storage Clutch — Sophisticated Storage → Create clutch

  invs                         list inventories (+ fill %)
  integrators                  list Redstone Integrators
  bind storage <side|name>
  bind redstone <side>         local PC face → dust → clutch
  bind integrator <name> [side]
                               remote Integrator (side faces clutch)
  on <percent>                 resume feed at/below this fill % (default 20)
  off <percent>                stop feed at/above this fill %  (default 60)
  invert [on|off]              flip redstone polarity
  interval <seconds>
  status
  monitor                      redraw steampunk instrument panel
  test on|off                  force output (ignores invert)
  run                          watch loop (Ctrl+T to stop)
  help

  Default (Create: power=stop): stop >=60% (rs ON), resume <=20% (rs OFF),
  hold in between. invert if powered=run instead.
]])
  print("Wired modems share peripherals only — not redstone.")
  print("Use a local face OR an Advanced Peripherals Redstone Integrator.")
  print("Display: color monitor or advanced PC — brass gauges + RS lamp cell.")
  print("Fill % is slot occupancy (used/size), not item-count fullness.")
end

local function cmdMonitor()
  local ok, err = drawMonitor()
  if ok then
    print("Instrument panel updated.")
  else
    print("Display: " .. tostring(err or "failed"))
  end
end

local function applyOnce()
  if not cfg.storage then return false, "bind storage first" end
  if not cfg.rsSide and not cfg.integrator then
    return false, "bind redstone <side> or bind integrator <name>"
  end
  local fill, err = storageFill(cfg.storage)
  if not fill then return false, err end
  recordFill(fill)
  local want = desiredOn(fill)
  local ok, outOrErr, src = setRedstone(want)
  if not ok then return false, outOrErr end
  pcall(drawMonitor, fill, outOrErr)
  return true, fill, outOrErr, src
end

local function cmdRun()
  if not cfg.storage then print("bind storage first"); return end
  if not cfg.rsSide and not cfg.integrator then
    print("bind redstone <side> or bind integrator <name> first")
    return
  end
  rateSamples = {} -- fresh rate window when starting watch
  local _, kind = resolveDisplay()
  if kind == "monitor" then
    print("Steampunk panel → monitor")
  elseif kind == "term" then
    print("Steampunk panel → this screen (Ctrl+T to stop)")
  else
    print("No color display — console only")
  end
  print(("Watching %s — Ctrl+T to stop"):format(cfg.storage))
  local last = nil
  local useTermUi = (kind == "term")
  while true do
    local ok, a, b, c = applyOnce()
    if ok then
      local fill, on, src = a, b, c
      if not useTermUi then
        local rate = fillRate()
        local rateStr = rate and formatRate(rate) or "rate …"
        local line = ("%s  %3d%%  %s  %d/%d  rs=%s"):format(
          os.date("%H:%M:%S"), fill.pct, rateStr, fill.used, fill.size, on and "ON" or "OFF")
        if line ~= last then
          print(line)
          last = line
        end
      end
    else
      if not useTermUi then
        print(os.date("%H:%M:%S") .. "  ERR " .. tostring(a))
      end
      last = nil
      pcall(drawMonitor, nil, nil)
    end
    -- Re-resolve in case a monitor is attached mid-run
    local _, k2 = resolveDisplay()
    useTermUi = (k2 == "term")
    sleep(tonumber(cfg.interval) or 1)
  end
end

--------------------------------------------------------------------------------
local function dispatch(line)
  local args = {}
  for w in string.gmatch(line or "", "%S+") do args[#args + 1] = w end
  local cmd = (args[1] or ""):lower()
  if cmd == "" then return end
  if cmd == "invs" or cmd == "inventories" then cmdInvs()
  elseif cmd == "integrators" or cmd == "ri" then cmdIntegrators()
  elseif cmd == "bind" then
    local what = (args[2] or ""):lower()
    if what == "storage" or what == "chest" or what == "inv" then
      cmdBindStorage(args[3])
    elseif what == "redstone" or what == "rs" or what == "side" then
      cmdBindRedstone(args[3])
    elseif what == "integrator" or what == "ri" then
      cmdBindIntegrator(args[3], args[4])
    else
      print("bind storage|redstone|integrator …")
    end
  elseif cmd == "on" then cmdOn(args[2])
  elseif cmd == "off" then cmdOff(args[2])
  elseif cmd == "invert" then cmdInvert(args[2])
  elseif cmd == "interval" then cmdInterval(args[2])
  elseif cmd == "status" or cmd == "stat" then cmdStatus()
  elseif cmd == "monitor" or cmd == "mon" then cmdMonitor()
  elseif cmd == "test" then cmdTest(args[2])
  elseif cmd == "run" or cmd == "watch" or cmd == "start" then cmdRun()
  elseif cmd == "help" or cmd == "?" then cmdHelp()
  elseif cmd == "exit" or cmd == "quit" then return "exit"
  else
    print("Unknown. Type help")
  end
end

--------------------------------------------------------------------------------
loadCfg()
if cfg.label and cfg.label ~= "" then
  pcall(os.setComputerLabel, cfg.label)
end

print(("Storage Clutch v%s — type help"):format(VERSION))
if cfg.storage or cfg.rsSide or cfg.integrator then
  cmdStatus()
end

while true do
  write("> ")
  local line = read()
  if not line then break end
  local r = dispatch(line)
  if r == "exit" then break end
end
