--[[
  storage/managers/storage_clutch.lua  -  Storage fill → Create clutch
  Titan-Version: 1.8.9

  Reads a Sophisticated Storage (or any inventory) over the wired modem
  network and drives Create clutch(es) via redstone.

  IMPORTANT: Wired modem cable does NOT carry redstone. Use one of:
    A) Local face — PC touching redstone dust / clutch
    B) Advanced Peripherals Redstone Integrator(s) next to clutch(es),
       with a wired modem on the same cable as the PC + storage

  Hardware (typical):
    [Sophisticated chest] --wired modem--+
    [Clutch + Integrator] --wired modem--+
    [Clutch + Integrator] --wired modem--+-- cable -- [PC + wired modem + monitor]
    (or PC redstone face → dust → clutch)

  AUTO-DISCOVERY: On boot, the clutch automatically discovers and links:
    - All Redstone Integrators on the network (multiple outputs supported)
    - Monitor (if attached)
    - Storage inventory (if only one candidate exists)
    Manual binding still available via bind commands.

  Hysteresis (default Create: powered clutch = STOP shaft):
    off 60% → stop feed (redstone ON / clutch engaged) at/above 60%
    on  20% → resume feed (redstone OFF / clutch idle) at/below 20%
    Between those points the last state is held (no chatter).
    Use `invert` if your wiring is the opposite (powered = run).
    Latch (`latchedOn` in storage_clutch.cfg) persists across reboots so
    the hold band resumes correctly (default RUN / latchedOn=false).

  Boot: when storage + redstone output are bound, `run` starts automatically
  (autoRun=true in cfg; `autorun off` to disable and stay at the `>` prompt).

  Display: steampunk board (brass header, riveted panels, pressure gauge,
  status chips, RS lamp cell) on an attached color monitor, or the
  advanced computer term when no monitor is present.

  Setup (auto-discovery on boot, or manual):
    discover                             -- scan and auto-link everything
    invs | integrators
    bind storage <side|name>
    bind redstone <side>                 -- local PC face
    bind integrator <name> [side]        -- add one Redstone Integrator
    unbind integrator <name>             -- remove one
    on <percent>                         -- resume feed at/below this fill %
    off <percent>                        -- stop feed at/above this fill %
    invert on|off
    interval <seconds>
    autorun on|off                       -- auto-start watch on boot (default on)
    run | status | monitor | test on|off | help
]]

local LOCAL_CFG = "storage_clutch.cfg"
local VERSION = "1.8.9"

local cfg = {
  storage = nil,           -- inventory peripheral name
  -- Redstone outputs (multiple supported):
  rsSide = nil,            -- local computer face (legacy/fallback)
  integrators = {},        -- array of {name=..., side=...} for multiple outputs
  -- Legacy single integrator (migrated to integrators array on load):
  integrator = nil,
  integratorSide = "front",
  -- Hysteresis (feed): resume at onPct, stop at offPct (hold between)
  -- Create default: stop = redstone ON, resume = redstone OFF
  onPct = 20,
  offPct = 60,
  invert = false,
  interval = 1,            -- seconds between polls
  label = nil,
  -- Last desired redstone state (before invert) for the hysteresis band.
  -- Persisted in storage_clutch.cfg. true = STOP feed; false = RUN feed.
  latchedOn = false,
  -- Start the watch loop (`run`) automatically when fully bound (boot / launch).
  autoRun = true,
  -- Auto-discovery on boot (default on)
  autoDiscover = true,
}

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
  -- Hysteresis latch: prefer RUN when missing/invalid (first boot / old cfg)
  if type(cfg.latchedOn) ~= "boolean" then
    cfg.latchedOn = false
  end
  -- Auto-start watch on boot (default on for older cfgs missing the key)
  if type(cfg.autoRun) ~= "boolean" then
    cfg.autoRun = true
  end
  -- Auto-discovery on boot (default on)
  if type(cfg.autoDiscover) ~= "boolean" then
    cfg.autoDiscover = true
  end
  -- Migrate legacy single integrator to array format
  if type(cfg.integrators) ~= "table" then
    cfg.integrators = {}
  end
  if cfg.integrator and cfg.integrator ~= "" then
    local exists = false
    for _, entry in ipairs(cfg.integrators) do
      if entry.name == cfg.integrator then
        exists = true
        break
      end
    end
    if not exists then
      table.insert(cfg.integrators, {
        name = cfg.integrator,
        side = cfg.integratorSide or "front"
      })
    end
    cfg.integrator = nil
  end
  
  -- Validate saved storage is still present (important for side-attached inventories)
  -- If not present or not an inventory, clear it so autoDiscover can re-scan
  if cfg.storage and cfg.storage ~= "" then
    if not peripheral.isPresent(cfg.storage) then
      cfg.storage = nil
    else
      -- Check if it's still an inventory
      local isInv = false
      if peripheral.hasType and peripheral.hasType(cfg.storage, "inventory") then
        isInv = true
      else
        local w = peripheral.wrap(cfg.storage)
        isInv = w and type(w.list) == "function"
      end
      if not isInv then
        cfg.storage = nil
      end
    end
  end
end

local function isFullyBound()
  return cfg.storage and (cfg.rsSide or (#cfg.integrators > 0))
end

local function hasAnyIntegrators()
  return cfg.rsSide or (#cfg.integrators > 0)
end

local function saveCfg()
  local f = fs.open(LOCAL_CFG, "w")
  if f then f.write(textutils.serialize(cfg)); f.close() end
end

--- Update persisted latch when it flips (true=STOP feed, false=RUN).
local function setLatch(on)
  on = not not on
  if cfg.latchedOn ~= on then
    cfg.latchedOn = on
    saveCfg()
  end
  return cfg.latchedOn
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
  
  -- Explicitly check all six sides first (important for directly attached peripherals)
  for side in pairs(SIDES) do
    if peripheral.isPresent(side) then
      add(side)
    end
  end
  
  -- Then check other local peripherals
  for _, name in ipairs(peripheral.getNames()) do
    add(name)
  end
  
  -- Finally scan wired modem networks
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

local function findMonitor()
  -- Prefer directly attached monitor (sides), then scan wired network
  -- Check local peripherals first
  for _, name in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(name)
    if ptype == "monitor" then
      return peripheral.wrap(name)
    end
  end
  
  -- Scan wired modems for remote monitors
  for _, sideName in ipairs(peripheral.getNames()) do
    if peripheral.getType(sideName) == "modem" then
      local m = peripheral.wrap(sideName)
      if m and type(m.getNamesRemote) == "function" then
        for _, remoteName in ipairs(m.getNamesRemote() or {}) do
          if peripheral.getType(remoteName) == "monitor" then
            return peripheral.wrap(remoteName)
          end
        end
      end
    end
  end
  
  return nil
end

--------------------------------------------------------------------------------
-- Auto-discovery: Find and link all integrators, monitor, and storage
--------------------------------------------------------------------------------
local function autoDiscover()
  local changed = false
  local report = {}

  -- 1. Auto-link ALL Redstone Integrators on the network
  local allIntegrators = collectNames(isIntegrator)
  local newIntegrators = {}
  for _, name in ipairs(allIntegrators) do
    local exists = false
    for _, entry in ipairs(cfg.integrators) do
      if entry.name == name then
        exists = true
        break
      end
    end
    if not exists then
      table.insert(newIntegrators, name)
      table.insert(cfg.integrators, {
        name = name,
        side = "front"  -- default side; user can adjust later
      })
      changed = true
    end
  end
  if #newIntegrators > 0 then
    table.insert(report, string.format("Linked %d integrator(s): %s",
      #newIntegrators, table.concat(newIntegrators, ", ")))
  end

  -- 2. Auto-bind storage if unbound and exactly one inventory candidate exists
  if not cfg.storage then
    local invs = collectNames(isInventory)
    if #invs == 1 then
      cfg.storage = invs[1]
      table.insert(report, "Auto-bound storage: " .. cfg.storage)
      changed = true
    elseif #invs > 1 then
      table.insert(report, string.format(
        "Multiple inventories found (%d) — use 'bind storage <name>' to pick one", #invs))
    end
  end

  -- 3. Monitor is always auto-discovered via findMonitor() at runtime, no binding needed
  local mon = findMonitor()
  if mon then
    table.insert(report, "Monitor detected (auto-displayed)")
  end

  if changed then
    saveCfg()
  end

  return report, changed
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
  local nextLatch = cfg.latchedOn

  if resumeP == stopP then
    -- single trip: stop (rs ON) at/above, run (rs OFF) below
    nextLatch = (pct >= stopP)
  elseif resumeP < stopP then
    -- Normal band: stop at/above off%, resume at/below on% (hold in between)
    if pct >= stopP then
      nextLatch = true
    elseif pct <= resumeP then
      nextLatch = false
    end
  else
    -- Swapped thresholds (on > off): stop at/above on%, resume at/below off%
    if pct >= resumeP then
      nextLatch = true
    elseif pct <= stopP then
      nextLatch = false
    end
  end
  return setLatch(nextLatch)
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
-- Polish patterns match games launcher / router hub boards: solid header,
-- status chips, filled section bars, framed gauge panels, gray footer.
-- Palette stays brass / copper / iron for clutch only.
--------------------------------------------------------------------------------
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
      brass = colors.orange,       -- header / primary brass
      rivet = colors.yellow,       -- polished brass accents
      iron = colors.lightGray,     -- section rails / labels
      soot = colors.gray,          -- card rows / tube empty
      copper = colors.brown,       -- secondary section bars
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
    brass = colors.white,
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

local function guiFill(out, x, y, ww, hh, bg, fg)
  if not out or ww < 1 or hh < 1 then return end
  local W, H = out.getSize()
  bg = bg or colors.black
  fg = fg or colors.white
  for row = y, math.min(H, y + hh - 1) do
    if row >= 1 then
      local cx = math.max(1, x)
      local cw = math.min(ww - (cx - x), W - cx + 1)
      if cw > 0 then
        if out.setBackgroundColor then out.setBackgroundColor(bg) end
        if out.setTextColor then out.setTextColor(fg) end
        out.setCursorPos(cx, row)
        out.write(string.rep(" ", cw))
      end
    end
  end
end

local function guiText(out, x, y, txt, fg, bg)
  if not out or y < 1 then return end
  local W, H = out.getSize()
  if y > H or x > W then return end
  txt = tostring(txt or "")
  if out.setBackgroundColor then out.setBackgroundColor(bg or colors.black) end
  if out.setTextColor then out.setTextColor(fg or colors.white) end
  out.setCursorPos(math.max(1, x), y)
  out.write(txt:sub(1, math.max(0, W - math.max(1, x) + 1)))
end

local function guiChip(out, x, y, label, fg, bg, colorOk)
  label = " " .. tostring(label) .. " "
  if colorOk then
    guiText(out, x, y, label, fg or colors.white, bg or colors.gray)
  else
    local bare = tostring(label):match("^%s*(.-)%s*$") or ""
    guiText(out, x, y, "[" .. bare .. "]", fg or colors.white, colors.black)
    return x + #bare + 3
  end
  return x + #label + 1
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
  guiText(out, x, y, " ", lampFg, lampBg)
end

--- Riveted panel frame around a body region (color: filled iron rails + yellow rivets).
local function drawPanelFrame(out, x, y, ww, hh, pal, color)
  if ww < 3 or hh < 3 then return end
  local W, H = out.getSize()
  ww = math.min(ww, W - x + 1)
  hh = math.min(hh, H - y + 1)
  if color then
    guiFill(out, x, y, ww, 1, pal.soot, pal.rivet)
    guiFill(out, x, y + hh - 1, ww, 1, pal.soot, pal.rivet)
    for row = y + 1, y + hh - 2 do
      guiText(out, x, row, " ", pal.rivet, pal.soot)
      guiText(out, x + ww - 1, row, " ", pal.rivet, pal.soot)
    end
    -- Rivets at corners + mid-sides
    for _, px in ipairs({ x, x + ww - 1 }) do
      for _, py in ipairs({ y, y + hh - 1 }) do
        guiText(out, px, py, "+", pal.rivet, pal.copper)
      end
    end
    if hh >= 6 then
      local mid = y + math.floor((hh - 1) / 2)
      guiText(out, x, mid, "+", pal.rivet, pal.copper)
      guiText(out, x + ww - 1, mid, "+", pal.rivet, pal.copper)
    end
  else
    guiText(out, x, y, "+" .. string.rep("-", ww - 2) .. "+", pal.steam, pal.bg)
    guiText(out, x, y + hh - 1, "+" .. string.rep("-", ww - 2) .. "+", pal.steam, pal.bg)
    for row = y + 1, y + hh - 2 do
      guiText(out, x, row, "|", pal.steam, pal.bg)
      guiText(out, x + ww - 1, row, "|", pal.steam, pal.bg)
    end
  end
end

--- Pressure gauge: solid fill bar + band tick row (run/stop markers).
local function drawPressureGauge(out, x, y, ww, pct, fillBg, pal, color, onPct, offPct)
  local W = select(1, out.getSize())
  ww = math.min(ww, W - x + 1)
  if ww < 6 then return 0 end
  pct = math.max(0, math.min(100, tonumber(pct) or 0))
  local inner = ww - 2
  local filled = math.floor((pct / 100) * inner + 0.5)

  -- Tube ends (brass)
  if color then
    guiText(out, x, y, "[", pal.rivet, pal.copper)
    guiFill(out, x + 1, y, inner, 1, pal.soot, pal.steam)
    if filled > 0 then
      guiFill(out, x + 1, y, filled, 1, fillBg, colors.black)
    end
    guiText(out, x + ww - 1, y, "]", pal.rivet, pal.copper)
  else
    local bar = string.rep("=", filled) .. string.rep("-", math.max(0, inner - filled))
    guiText(out, x, y, "[" .. bar .. "]", pal.steam, pal.bg)
  end

  -- Band ticks on next row when caller leaves space
  return inner
end

local function drawBandTicks(out, x, y, inner, pal, color, onPct, offPct)
  if inner < 4 then return end
  onPct = math.max(0, math.min(100, tonumber(onPct) or 20))
  offPct = math.max(0, math.min(100, tonumber(offPct) or 60))
  local chars = {}
  for i = 1, inner do
    local p = ((i - 0.5) / inner) * 100
    local nearOn = math.abs(p - onPct) < (100 / inner)
    local nearOff = math.abs(p - offPct) < (100 / inner)
    if nearOff then
      chars[i] = "S" -- stop
    elseif nearOn then
      chars[i] = "R" -- run
    elseif i == 1 or i == inner or math.abs(p - 50) < (100 / inner) then
      chars[i] = "|"
    else
      chars[i] = "-"
    end
  end
  local line = table.concat(chars)
  if color then
    guiText(out, x, y, " ", pal.dim, pal.bg)
    guiText(out, x + 1, y, line, pal.copper, pal.bg)
    guiText(out, x + inner + 1, y, " ", pal.dim, pal.bg)
  else
    guiText(out, x, y, " " .. line .. " ", pal.steam, pal.bg)
  end
end

local function applyMonitorScale(out)
  if not out then return 1, 0, 0 end
  if not out.setTextScale then
    local w, h = out.getSize()
    return 1, w, h
  end
  -- Prefer readable boards like games/router: try 1 then 0.5.
  local chosen = 0.5
  for _, scale in ipairs({ 1, 0.5 }) do
    pcall(function() out.setTextScale(scale) end)
    local ww, hh = out.getSize()
    if ww >= 26 and hh >= 12 then
      chosen = scale
      break
    end
    chosen = scale
  end
  pcall(function() out.setTextScale(chosen) end)
  local w, h = out.getSize()
  return chosen, w, h
end

local function layoutTier(w, h)
  if w < 18 or h < 6 then return "tiny"
  elseif w < 28 or h < 10 then return "small"
  elseif w < 40 or h < 14 then return "medium"
  else return "large"
  end
end

--- Steampunk brass instrument board. fill/rsOn optional.
--- Returns: success, touchAreas
--- touchAreas = {rs = {x,y,w,h}, stop = {x,y,w,h}, start = {x,y,w,h}}
local function drawMonitor(fill, rsOn)
  local out, kind = resolveDisplay()
  if not out then return false, "no monitor / color term" end

  if not fill and cfg.storage then
    fill = storageFill(cfg.storage)
    if fill then recordFill(fill) end
  end
  if rsOn == nil then
    rsOn = (cfg.latchedOn ~= not not cfg.invert)
  end

  local rate = fillRate()
  local color = outIsColor(out)
  local pal = steamPalette(color)
  
  -- Touch areas for tap detection (declared once, set in header/status sections)
  local rsTouchArea = nil
  local stopTouchArea = nil
  local startTouchArea = nil

  local w, h
  if kind == "monitor" then
    _, w, h = applyMonitorScale(out)
  else
    w, h = out.getSize()
  end

  if out.setBackgroundColor then out.setBackgroundColor(pal.bg) end
  out.clear()

  local pct = fill and fill.pct or 0
  local gfg = gaugeColor(pct, pal, color)
  local pctText = fill and string.format("%d%%", pct) or "--%"
  local rateText = formatRate(rate)
  local rfg = rateColor(rate)
  if not color then rfg = pal.steam end
  local onP, offP = cfg.onPct or 20, cfg.offPct or 60
  local slotsText = fill and ("%d/%d"):format(fill.used, fill.size) or "--/--"
  local feedLabel = (rsOn == true) and "STOP" or ((rsOn == false) and "RUN" or "?")
  local tier = layoutTier(w, h)
  local pad = (tier == "large" and color) and 1 or 0
  local x0 = 1 + pad
  local innerW = w - 2 * pad
  local footerH = 1
  local headerH = (tier == "tiny") and 1 or ((tier == "small") and 2 or 3)

  --------------------------------------------------------------------------
  -- Header (solid brass bar — games/router style)
  --------------------------------------------------------------------------
  local title = " STORAGE CLUTCH "
  local ver = ("v%s"):format(VERSION)
  if color then
    guiFill(out, 1, 1, w, headerH, pal.brass, colors.black)
    guiText(out, 2, 1, title:sub(1, w - 2), colors.black, pal.brass)
    if #title + #ver + 3 < w then
      guiText(out, math.max(2, w - #ver), 1, ver, pal.copper, pal.brass)
    end
    if headerH >= 2 then
      local sub = (cfg.label and cfg.label ~= "" and tostring(cfg.label))
        or (cfg.storage and tostring(cfg.storage):sub(1, w - 4))
        or "unbound"
      guiText(out, 2, 2, sub:sub(1, w - 2), pal.rivet, pal.brass)
    end
    if headerH >= 3 then
      local stopText = ("stop>=%d%%"):format(offP)
      local startText = ("run<=%d%%"):format(onP)
      local invText = cfg.invert and "  inv" or ""
      local meta = stopText .. "  " .. startText .. invText
      guiText(out, 2, 3, meta:sub(1, w - 2), colors.black, pal.brass)
      -- Touch areas for threshold buttons (header row 3)
      stopTouchArea = {x = 2, y = 3, w = #stopText, h = 1}
      startTouchArea = {x = 2 + #stopText + 2, y = 3, w = #startText, h = 1}
    end
  else
    guiText(out, 1, 1, (title .. ver):sub(1, w), pal.steam, pal.bg)
    if headerH >= 2 then
      guiText(out, 1, 2, ("stop%d run%d"):format(offP, onP):sub(1, w), pal.steam, pal.bg)
    end
  end

  local y = headerH + 1

  --------------------------------------------------------------------------
  -- Tiny: fill + RS lamp only
  --------------------------------------------------------------------------
  if tier == "tiny" or w < 14 or h < 5 then
    if y <= h - footerH then
      guiText(out, x0, y, pctText, gfg, pal.bg)
      if w >= 8 then
        guiText(out, math.max(x0, w - 5), y, "RS", pal.dim, pal.bg)
        drawRsLamp(out, w - 2, y, rsOn, pal, color)
      end
    end
    if color then
      guiFill(out, 1, h, w, 1, pal.soot, pal.steam)
      guiText(out, 1, h, (" %dx%d"):format(w, h), pal.iron, pal.soot)
    end
    return true
  end

  --------------------------------------------------------------------------
  -- Status chip row (fill / rate / clutch)
  --------------------------------------------------------------------------
  if y <= h - footerH then
    if color then
      guiFill(out, 1, y, w, 1, pal.bg, pal.steam)
      local x = x0
      local fillFg = (gfg == pal.danger) and colors.white or colors.black
      x = guiChip(out, x, y, "FILL " .. pctText, fillFg, gfg, true)
      x = guiChip(out, x, y, rateText, colors.white, pal.soot, true)
      -- RS single-pixel lamp + short label
      local rsX = x
      guiText(out, x, y, "RS", pal.iron, pal.bg)
      drawRsLamp(out, x + 2, y, rsOn, pal, color)
      if x + 5 < w then
        local feedBg = (rsOn == true) and pal.lampOff
          or ((rsOn == false) and pal.lampOn or pal.soot)
        local feedFg = (rsOn == true) and colors.white or colors.black
        local chipEnd = guiChip(out, x + 4, y, feedLabel, feedFg, feedBg, true)
        -- Touch area: from RS text through FEED chip (generous hit target)
        rsTouchArea = {x = rsX, y = y, w = math.max(8, chipEnd - rsX), h = 1, row = y}
      else
        -- No feed chip, smaller touch area
        rsTouchArea = {x = rsX, y = y, w = 3, h = 1, row = y}
      end
    else
      guiText(out, x0, y,
        ("FILL %s  %s  RS=%s"):format(pctText, rateText, feedLabel):sub(1, innerW),
        pal.steam, pal.bg)
    end
    y = y + 1
  end

  --------------------------------------------------------------------------
  -- Pressure section (riveted panel + solid gauge)
  --------------------------------------------------------------------------
  local bodyBot = h - footerH
  local gaugeH = 3
  if tier == "large" then gaugeH = 5
  elseif tier == "medium" then gaugeH = 4
  elseif h - y - footerH < 6 then gaugeH = 2
  end
  gaugeH = math.min(gaugeH, math.max(2, bodyBot - y - 2))

  if y + gaugeH - 1 <= bodyBot and innerW >= 8 then
    local px, py, pw, ph = x0, y, innerW, gaugeH
    drawPanelFrame(out, px, py, pw, ph, pal, color)
    local ix, iy = px + 1, py + 1
    local iw = pw - 2

    if color then
      guiFill(out, ix, iy, iw, 1, pal.copper, pal.rivet)
      guiText(out, ix + 1, iy, "PRESSURE", pal.rivet, pal.copper)
      local pctRight = pctText
      guiText(out, ix + iw - #pctRight, iy, pctRight, colors.black, pal.copper)
    else
      guiText(out, ix, iy, ("PRESSURE %s"):format(pctText):sub(1, iw), pal.steam, pal.bg)
    end

    if ph >= 3 then
      drawPressureGauge(out, ix, iy + 1, iw, pct, gfg, pal, color, onP, offP)
    end
    if ph >= 4 then
      drawBandTicks(out, ix, iy + 2, math.max(1, iw - 2), pal, color, onP, offP)
    end
    if ph >= 5 and color then
      guiText(out, ix + 1, iy + 3,
        ("R=run@%d  S=stop@%d"):format(onP, offP):sub(1, iw - 2),
        pal.iron, pal.bg)
    end
    y = py + ph + 1
  end

  --------------------------------------------------------------------------
  -- Detail cards / rows (slots, rate, band, clutch)
  --------------------------------------------------------------------------
  local cards = {
    { "SLOTS", slotsText, pal.steam },
    { "RATE", rateText, rfg },
    { "BAND", ("stop>=%d  run<=%d"):format(offP, onP), pal.iron },
    { "FEED", feedLabel .. (cfg.invert and " inv" or ""),
      (rsOn == true) and pal.danger or ((rsOn == false) and pal.ok or pal.dim) },
  }

  if color and tier ~= "tiny" and w >= 28 and y <= bodyBot then
    -- Two-column key/value cards (router stats style)
    local colW = math.floor((w - 2) / 2)
    local i = 1
    while i <= #cards and y <= bodyBot do
      local a, b = cards[i], cards[i + 1]
      guiFill(out, 1, y, w, 1, pal.soot, pal.steam)
      local left = (" %s %s"):format(a[1], a[2])
      guiText(out, 1, y, left:sub(1, colW), a[3], pal.soot)
      if b then
        local right = (" %s %s"):format(b[1], b[2])
        guiText(out, colW + 2, y, right:sub(1, colW), b[3], pal.soot)
        -- Put RS lamp next to FEED on the right card when present
        if b[1] == "FEED" then
          local lx = colW + 2 + math.min(colW - 2, #right + 1)
          if lx < w then drawRsLamp(out, lx, y, rsOn, pal, color) end
        end
        i = i + 2
      else
        if a[1] == "FEED" then
          local lx = 1 + math.min(colW - 2, #left + 1)
          if lx < w then drawRsLamp(out, lx, y, rsOn, pal, color) end
        end
        i = i + 1
      end
      y = y + 1
    end
  else
    for _, c in ipairs(cards) do
      if y > bodyBot then break end
      local line = ("%s  %s"):format(c[1], c[2])
      if color then
        guiFill(out, 1, y, w, 1, pal.soot, pal.steam)
        guiText(out, x0, y, line:sub(1, innerW), c[3], pal.soot)
        if c[1] == "FEED" then
          drawRsLamp(out, math.min(w - 1, x0 + #line + 1), y, rsOn, pal, color)
        end
      else
        guiText(out, x0, y, line:sub(1, innerW), pal.steam, pal.bg)
      end
      y = y + 1
    end
  end

  -- Extra tall boards: secondary iron rail with storage name / polarity
  if tier == "large" and y <= bodyBot and color then
    guiFill(out, 1, y, w, 1, pal.iron, colors.black)
    local note = "Create default: RS ON = stop feed"
    if cfg.invert then note = "Inverted: RS ON = run feed" end
    guiText(out, 2, y, note:sub(1, w - 2), colors.black, pal.iron)
  end

  --------------------------------------------------------------------------
  -- Footer
  --------------------------------------------------------------------------
  local right = (color and " BRASS" or " MONO") .. (" %dx%d"):format(w, h)
  local left = " clutch"
  if color then
    guiFill(out, 1, h, w, 1, pal.soot, pal.steam)
    guiText(out, 1, h, left, pal.steam, pal.soot)
    guiText(out, math.max(1, w - #right + 1), h, right, pal.iron, pal.soot)
  else
    guiText(out, 1, h, (left .. right):sub(1, w), pal.dim, pal.bg)
  end

  return true, {rs = rsTouchArea, stop = stopTouchArea, start = startTouchArea}
end

--------------------------------------------------------------------------------
-- Redstone output (supports multiple integrators)
--------------------------------------------------------------------------------
local function setRedstone(on)
  on = not not on
  if cfg.invert then on = not on end

  local success = false
  local errors = {}

  -- Set all integrators
  for _, entry in ipairs(cfg.integrators) do
    if entry.name and peripheral.isPresent(entry.name) then
      local w = peripheral.wrap(entry.name)
      local side = tostring(entry.side or "front"):lower()
      if type(w.setOutput) == "function" then
        local ok, err = pcall(w.setOutput, side, on)
        if ok then
          success = true
        else
          table.insert(errors, entry.name .. ": " .. tostring(err))
        end
      elseif type(w.setAnalogOutput) == "function" then
        local ok, err = pcall(w.setAnalogOutput, side, on and 15 or 0)
        if ok then
          success = true
        else
          table.insert(errors, entry.name .. ": " .. tostring(err))
        end
      else
        table.insert(errors, entry.name .. ": no setOutput method")
      end
    end
  end

  -- Set local redstone side if configured
  if cfg.rsSide and isSideName(cfg.rsSide) then
    redstone.setOutput(cfg.rsSide:lower(), on)
    success = true
  end

  if success then
    local count = #cfg.integrators + (cfg.rsSide and 1 or 0)
    local kind = (#cfg.integrators > 0) and "integrator(s)" or "local"
    if #errors > 0 then
      return true, on, kind .. " (some errors: " .. table.concat(errors, "; ") .. ")"
    end
    return true, on, count > 1 and string.format("%d outputs", count) or kind
  end

  return false, #errors > 0 and table.concat(errors, "; ") or "no redstone output bound"
end

local function getRedstoneState()
  -- Check first integrator
  if #cfg.integrators > 0 then
    local entry = cfg.integrators[1]
    if entry.name and peripheral.isPresent(entry.name) then
      local w = peripheral.wrap(entry.name)
      local side = tostring(entry.side or "front"):lower()
      if type(w.getOutput) == "function" then
        local ok, v = pcall(w.getOutput, side)
        if ok then return not not v, "integrator" end
      end
      if type(w.getAnalogOutput) == "function" then
        local ok, v = pcall(w.getAnalogOutput, side)
        if ok then return (tonumber(v) or 0) > 0, "integrator" end
      end
    end
  end
  -- Fall back to local side
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
    local bound = false
    local boundSide = nil
    for _, entry in ipairs(cfg.integrators) do
      if entry.name == n then
        bound = true
        boundSide = entry.side
        break
      end
    end
    local mark = bound and string.format(" * (side: %s)", boundSide or "?") or ""
    print("  " .. n .. mark)
  end
  if #cfg.integrators > 0 then
    print(string.format("\n%d integrator(s) currently bound", #cfg.integrators))
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
  saveCfg()
  print("Local redstone output: " .. side)
  local total = #cfg.integrators + 1
  print(string.format("Total outputs: %d (%d integrator(s) + local)", total, #cfg.integrators))
end

local function cmdBindIntegrator(ref, side)
  if not ref or ref == "" then
    print("Usage: bind integrator <name|substring> [outputSide]")
    print("  Adds a Redstone Integrator to the output list.")
    print("  outputSide = face of the Integrator block toward the clutch (default: front)")
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
  
  -- Check if already bound
  for _, entry in ipairs(cfg.integrators) do
    if entry.name == n then
      print(("Integrator %s already bound (side: %s)"):format(n, entry.side or "front"))
      if side and isSideName(side) then
        entry.side = side:lower()
        saveCfg()
        print("Updated side to: " .. entry.side)
      end
      return
    end
  end
  
  -- Add new integrator
  local outSide = (side and isSideName(side)) and side:lower() or "front"
  table.insert(cfg.integrators, {
    name = n,
    side = outSide
  })
  saveCfg()
  print(("Integrator bound: %s (output %s)"):format(n, outSide))
  local total = #cfg.integrators + (cfg.rsSide and 1 or 0)
  print(string.format("Total outputs: %d", total))
end

local function cmdUnbindIntegrator(ref)
  if not ref or ref == "" then
    print("Usage: unbind integrator <name|substring>")
    print("  Removes an integrator from the output list.")
    return
  end
  
  local removed = false
  for i = #cfg.integrators, 1, -1 do
    local entry = cfg.integrators[i]
    if entry.name and entry.name:lower():find(ref:lower(), 1, true) then
      print("Removed: " .. entry.name)
      table.remove(cfg.integrators, i)
      removed = true
    end
  end
  
  if removed then
    saveCfg()
    print(string.format("Remaining integrators: %d", #cfg.integrators))
  else
    print("No matching integrator found: " .. ref)
  end
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

local function cmdAutoRun(arg)
  arg = tostring(arg or ""):lower()
  if arg == "on" or arg == "true" or arg == "1" then
    cfg.autoRun = true
  elseif arg == "off" or arg == "false" or arg == "0" then
    cfg.autoRun = false
  else
    print("Usage: autorun on|off")
    print("  current: " .. ((cfg.autoRun ~= false) and "on" or "off"))
    print("  When on, fully bound clutch starts `run` on boot/launch.")
    return
  end
  saveCfg()
  print("autorun: " .. (cfg.autoRun and "on" or "off"))
end

local function cmdDiscover()
  print("Discovering peripherals...")
  local report, changed = autoDiscover()
  if #report > 0 then
    for _, line in ipairs(report) do
      print("  " .. line)
    end
  else
    print("  No changes — already configured or no peripherals found.")
  end
  if changed then
    print("\nConfiguration updated and saved.")
  end
  print("\nCurrent status:")
  cmdStatus()
end

local function cmdStatus()
  print(("Storage Clutch v%s"):format(VERSION))
  print(("  storage:    %s"):format(cfg.storage or "(unbound)"))
  
  -- Show all redstone outputs
  local outputCount = #cfg.integrators + (cfg.rsSide and 1 or 0)
  if outputCount == 0 then
    print("  outputs:    (unbound)")
  else
    print(("  outputs:    %d total"):format(outputCount))
    if cfg.rsSide then
      print(("    - local %s"):format(cfg.rsSide))
    end
    for _, entry in ipairs(cfg.integrators) do
      print(("    - integrator %s (side: %s)"):format(entry.name, entry.side or "front"))
    end
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
  print(("  autorun:    %s"):format((cfg.autoRun ~= false) and "on" or "off"))

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
    print("  display:    steampunk board (monitor)")
  elseif kind == "term" then
    print("  display:    steampunk board (advanced term via run/monitor)")
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
    setLatch(on)  -- keep hysteresis + cfg in sync with forced state
    print("Redstone forced " .. (on and "ON" or "OFF"))
  else
    print("Failed: " .. tostring(err))
  end
end

local function cmdHelp()
  print([[
Storage Clutch — Sophisticated Storage → Create clutch(es)

  discover                     auto-discover and link all peripherals
  invs                         list inventories (+ fill %)
  integrators                  list Redstone Integrators (shows bound *)
  bind storage <side|name>     bind storage inventory
  bind redstone <side>         local PC face → dust → clutch
  bind integrator <name> [side]
                               add Redstone Integrator (supports multiple)
  unbind integrator <name>     remove an integrator
  on <percent>                 resume feed at/below this fill % (default 20)
  off <percent>                stop feed at/above this fill %  (default 60)
  invert [on|off]              flip redstone polarity
  interval <seconds>           poll interval (default 1s)
  autorun on|off               auto-start run on boot (default on)
  status                       show config + current state
  monitor                      redraw steampunk brass board
  test on|off                  force output (ignores invert)
  run                          watch loop (Ctrl+T to stop)
  help

  AUTO-DISCOVERY: On boot, all integrators, monitor, and storage (if only one)
  are automatically discovered and linked. Use 'discover' to re-scan manually.

  MULTIPLE OUTPUTS: All bound integrators receive the same signal (parallel).

  Default (Create: power=stop): stop >=60% (rs ON), resume <=20% (rs OFF),
  hold in between. invert if powered=run instead.
  When storage + output are bound, run starts on boot (autorun off to disable).
]])
  print("Wired modems share peripherals only — not redstone.")
  print("Use local face OR Advanced Peripherals Redstone Integrator(s).")
  print("Display: color monitor or advanced PC — brass board + RS lamp cell.")
  print("Fill % is slot occupancy (used/size), not item-count fullness.")
end

local function cmdMonitor()
  local ok, err = drawMonitor()
  if ok then
    print("Steampunk board updated.")
  else
    print("Display: " .. tostring(err or "failed"))
  end
end

local function applyOnce(manualOverride)
  if not cfg.storage then return false, "bind storage first" end
  if not hasAnyIntegrators() then
    return false, "bind redstone <side> or bind integrator <name>"
  end
  local fill, err = storageFill(cfg.storage)
  if not fill then return false, err end
  recordFill(fill)
  
  -- Determine desired state: manual override or auto hysteresis
  local want
  if manualOverride ~= nil then
    -- Manual toggle: use override, update latch
    want = manualOverride
    setLatch(want)
  else
    -- Auto hysteresis
    want = desiredOn(fill)
  end
  
  local ok, outOrErr, src = setRedstone(want)
  if not ok then return false, outOrErr end
  local pok, okDraw, areas = pcall(drawMonitor, fill, outOrErr)
  return true, fill, outOrErr, src, areas
end

local function cmdRun()
  if not cfg.storage then print("bind storage first"); return end
  if not hasAnyIntegrators() then
    print("bind redstone <side> or bind integrator <name> first")
    return
  end
  rateSamples = {} -- fresh rate window when starting watch
  
  -- Check display: monitor (wired or direct) vs term fallback
  local mon = findMonitor()
  local hasMonitor = (mon ~= nil)
  local _, kind = resolveDisplay()
  
  if kind == "monitor" then
    print("Steampunk board → monitor (tap RS/stop/start to control)")
    print("Console: prompt only (Ctrl+T to stop)")
  elseif kind == "term" then
    print("Steampunk board → this screen (Ctrl+T to stop)")
  else
    print("No color display — console only")
  end
  print(("Watching %s"):format(cfg.storage))
  
  local touchAreas = {}
  local lastUpdate = os.clock()
  local interval = tonumber(cfg.interval) or 1
  
  while true do
    -- Check if it's time to update
    local now = os.clock()
    local shouldUpdate = (now - lastUpdate) >= interval
    
    if shouldUpdate then
      -- Apply clutch logic
      local ok, fill, rsOn, src, areas = applyOnce()
      
      if areas then
        touchAreas = areas
      end
      
      -- Monitor exists: silent console, all UI on monitor
      -- No monitor: term shows board (existing fallback)
      if not ok and not hasMonitor then
        pcall(drawMonitor, nil, nil)
      end
      
      lastUpdate = now
      
      -- Re-check for monitor attachment
      mon = findMonitor()
      hasMonitor = (mon ~= nil)
    end
    
    -- Listen for events (touch or terminate)
    local timeout = math.max(0.1, interval - (os.clock() - lastUpdate))
    local timerId = os.startTimer(timeout)
    local event, p1, p2, p3 = os.pullEvent()
    
    if event == "monitor_touch" and hasMonitor then
      -- p1 = side/name, p2 = x, p3 = y
      local x, y = p2, p3
      local needsUpdate = false
      
      -- Check RS toggle
      if touchAreas.rs and x >= touchAreas.rs.x and x < touchAreas.rs.x + touchAreas.rs.w 
         and y == touchAreas.rs.y then
        -- Toggle: flip the current latch and apply immediately
        local newState = not cfg.latchedOn
        applyOnce(newState)
        lastUpdate = os.clock()
        needsUpdate = false  -- Already updated
      
      -- Check stop threshold button
      elseif touchAreas.stop and x >= touchAreas.stop.x and x < touchAreas.stop.x + touchAreas.stop.w
         and y == touchAreas.stop.y then
        -- Increment stop threshold by 10%, wrap 100 -> 10
        cfg.offPct = cfg.offPct + 10
        if cfg.offPct > 100 then cfg.offPct = 10 end
        saveCfg()
        needsUpdate = true
      
      -- Check start threshold button  
      elseif touchAreas.start and x >= touchAreas.start.x and x < touchAreas.start.x + touchAreas.start.w
         and y == touchAreas.start.y then
        -- Increment start threshold by 10%, wrap 100 -> 10
        cfg.onPct = cfg.onPct + 10
        if cfg.onPct > 100 then cfg.onPct = 10 end
        saveCfg()
        needsUpdate = true
      end
      
      -- Redraw immediately after threshold change
      if needsUpdate then
        local ok, fill, rsOn, src, areas = applyOnce()
        if areas then
          touchAreas = areas
        end
        lastUpdate = os.clock()
      end
    elseif event == "timer" and p1 == timerId then
      -- Timer expired, loop will check shouldUpdate
    elseif event == "terminate" then
      print("\nStopped")
      return  -- Clean exit to prompt
    end
  end
end

--------------------------------------------------------------------------------
local function dispatch(line)
  local args = {}
  for w in string.gmatch(line or "", "%S+") do args[#args + 1] = w end
  local cmd = (args[1] or ""):lower()
  if cmd == "" then return end
  if cmd == "discover" or cmd == "scan" then cmdDiscover()
  elseif cmd == "invs" or cmd == "inventories" then cmdInvs()
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
  elseif cmd == "unbind" then
    local what = (args[2] or ""):lower()
    if what == "integrator" or what == "ri" then
      cmdUnbindIntegrator(args[3])
    else
      print("unbind integrator <name>")
    end
  elseif cmd == "on" then cmdOn(args[2])
  elseif cmd == "off" then cmdOff(args[2])
  elseif cmd == "invert" then cmdInvert(args[2])
  elseif cmd == "interval" then cmdInterval(args[2])
  elseif cmd == "autorun" or cmd == "auto" then cmdAutoRun(args[2])
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
-- Boot and main loop with error handling
--------------------------------------------------------------------------------
local function boot()
  loadCfg()
  if cfg.label and cfg.label ~= "" then
    pcall(os.setComputerLabel, cfg.label)
  end

  -- Auto-discovery on boot (default on)
  if cfg.autoDiscover ~= false then
    local report, changed = autoDiscover()
    if changed and #report > 0 then
      print(("Storage Clutch v%s — Auto-discovery"):format(VERSION))
      for _, line in ipairs(report) do
        print("  " .. line)
      end
      print()
    end
  end

  -- Restore physical clutch from saved latch before the interactive loop
  -- (hold band would otherwise wait for the next threshold cross).
  if isFullyBound() then
    pcall(setRedstone, cfg.latchedOn)
  end

  print(("Storage Clutch v%s — type help"):format(VERSION))
  if cfg.storage or cfg.rsSide or #cfg.integrators > 0 then
    cmdStatus()
  end

  -- Auto-start watch loop when fully bound (typical: launched from startup).
  -- Ctrl+T stops the program (same as manual `run`). Unbound → stay at prompt.
  if cfg.autoRun ~= false and isFullyBound() then
    print("Auto-run — Ctrl+T to stop  (autorun off to disable)")
    cmdRun()
  end

  while true do
    write("> ")
    local line = read()
    if not line then break end
    local r = dispatch(line)
    if r == "exit" then break end
  end
end

-- Error handler for xpcall
local function errorHandler(err)
  local trace = debug.traceback(err, 2)
  return trace
end

-- Run with error catching
local ok, err = xpcall(boot, errorHandler)
if not ok then
  if printError then
    printError(err)
  else
    print("\n=== Storage Clutch Error ===")
    print(err)
  end
  print("\nPress Enter to exit")
  read()
end
