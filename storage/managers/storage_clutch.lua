--[[
  storage/managers/storage_clutch.lua  -  Storage fill → Create clutch
  Titan-Version: 1.1.0

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

  Hysteresis (default): redstone ON at <= 20% fill, OFF at >= 60%.
  Between those points the last state is held (no chatter).

  Optional: attach a color monitor to the PC — fill % and fill rate are drawn.

  Setup:
    invs | integrators
    bind storage <side|name>
    bind redstone <side>                 -- local PC face
    bind integrator <name> [side]        -- remote Redstone Integrator
    on <percent>                         -- turn ON at/below (or at/above)
    off <percent>                        -- turn OFF at/above (or at/below)
    invert on|off
    interval <seconds>
    run | status | monitor | test on|off | help
]]

local LOCAL_CFG = "storage_clutch.cfg"
local VERSION = "1.3.1"

local cfg = {
  storage = nil,           -- inventory peripheral name
  -- Redstone output (pick one):
  rsSide = nil,            -- local computer face
  integrator = nil,        -- redstoneIntegrator peripheral
  integratorSide = "front",
  -- Hysteresis: ON at onPct, OFF at offPct (hold between)
  onPct = 20,
  offPct = 60,
  invert = false,
  interval = 1,            -- seconds between polls
  label = nil,
}

-- Last desired state (before invert) for the hysteresis band
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
  -- Migrate legacy single-threshold configs
  if (cfg.onPct == nil or cfg.offPct == nil) and cfg.threshold ~= nil then
    local th = tonumber(cfg.threshold) or 90
    local when = tostring(cfg.when or "full"):lower()
    if when == "empty" or when == "below" then
      cfg.onPct = cfg.onPct or math.min(th, 20)
      cfg.offPct = cfg.offPct or math.max(th, 60)
    else
      -- old "full/above": ON when high → swap band
      cfg.onPct = cfg.onPct or th
      cfg.offPct = cfg.offPct or math.max(0, th - 30)
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

local function desiredOn(fill)
  local pct = fill.pct
  local onP = tonumber(cfg.onPct) or 20
  local offP = tonumber(cfg.offPct) or 60

  if onP == offP then
    -- single trip point
    if onP <= 50 then
      latchedOn = (pct <= onP)
    else
      latchedOn = (pct >= onP)
    end
    return latchedOn
  end

  if onP < offP then
    -- Low → ON, high → OFF (default: on 20 / off 60)
    if pct <= onP then
      latchedOn = true
    elseif pct >= offP then
      latchedOn = false
    end
  else
    -- High → ON, low → OFF (e.g. on 80 / off 40)
    if pct >= onP then
      latchedOn = true
    elseif pct <= offP then
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
-- Monitor
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

local function fillColor(pct)
  pct = tonumber(pct) or 0
  if pct >= 80 then return colors.red
  elseif pct >= 60 then return colors.orange
  elseif pct >= 40 then return colors.yellow
  elseif pct >= 20 then return colors.lime
  else return colors.green
  end
end

local function monWrite(mon, x, y, text, fg, bg)
  if not mon then return end
  local w, h = mon.getSize()
  if y < 1 or y > h then return end
  if mon.setBackgroundColor and bg then mon.setBackgroundColor(bg) end
  if mon.setTextColor and fg then mon.setTextColor(fg) end
  mon.setCursorPos(math.max(1, x), y)
  mon.write(tostring(text):sub(1, w - math.max(1, x) + 1))
end

local function monCenter(mon, y, text, fg, bg)
  local w = mon.getSize()
  text = tostring(text or "")
  local x = math.max(1, math.floor((w - #text) / 2) + 1)
  monWrite(mon, x, y, text, fg, bg)
end

local function drawBar(mon, y, pct, fg)
  local w = select(1, mon.getSize())
  pct = math.max(0, math.min(100, tonumber(pct) or 0))
  local filled = math.floor((pct / 100) * w + 0.5)
  if mon.setBackgroundColor then mon.setBackgroundColor(colors.gray) end
  if mon.setTextColor then mon.setTextColor(fg or colors.white) end
  mon.setCursorPos(1, y)
  local bar = string.rep(" ", w)
  mon.write(bar)
  if filled > 0 then
    if mon.setBackgroundColor then mon.setBackgroundColor(fg or colors.lime) end
    mon.setCursorPos(1, y)
    mon.write(string.rep(" ", filled))
  end
end

--- Draw fill % + rate on attached monitor. fill/rsOn optional.
local function drawMonitor(fill, rsOn)
  local mon = findMonitor()
  if not mon then return false, "no monitor" end

  if not fill and cfg.storage then
    fill = storageFill(cfg.storage)
    if fill then recordFill(fill) end
  end
  if rsOn == nil then
    rsOn = (latchedOn ~= not not cfg.invert)
  end

  local rate = fillRate()

  pcall(function()
    if mon.setTextScale then
      -- Prefer largest scale that fits % + rate + footer
      local chosen = 0.5
      for _, scale in ipairs({ 5, 4, 3, 2, 1, 0.5 }) do
        mon.setTextScale(scale)
        local ww, hh = mon.getSize()
        if ww >= 5 and hh >= 4 then
          chosen = scale
          break
        end
      end
      mon.setTextScale(chosen)
    end
  end)

  local w, h = mon.getSize()
  if mon.setBackgroundColor then mon.setBackgroundColor(colors.black) end
  mon.clear()

  local pct = fill and fill.pct or 0
  local fg = fillColor(pct)
  local pctText = fill and string.format("%d%%", pct) or "--%"
  local rateText = formatRate(rate)
  local rfg = rateColor(rate)

  monCenter(mon, 1, "STORAGE", colors.lightGray, colors.black)

  if h >= 6 then
    local mid = math.floor(h / 2)
    monCenter(mon, mid - 1, pctText, fg, colors.black)
    monCenter(mon, mid, rateText:sub(1, w), rfg, colors.black)
    if fill then
      monCenter(mon, mid + 1, ("%d/%d slots"):format(fill.used, fill.size),
        colors.white, colors.black)
    end
    local barY = mid + 2
    if barY < h then drawBar(mon, barY, pct, fg) end
  elseif h >= 4 then
    monCenter(mon, 2, pctText, fg, colors.black)
    monCenter(mon, 3, rateText:sub(1, w), rfg, colors.black)
    if h >= 5 then drawBar(mon, 4, pct, fg) end
  else
    monCenter(mon, math.max(2, math.floor(h / 2)), pctText, fg, colors.black)
  end

  if h >= 3 then
    local rs = (rsOn == nil) and "?" or (rsOn and "ON" or "OFF")
    local foot = ("RS %s  on%d/off%d"):format(rs, cfg.onPct or 20, cfg.offPct or 60)
    monCenter(mon, h, foot:sub(1, w), colors.gray, colors.black)
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
    print("Usage: on <percent>   — turn redstone ON at this fill %")
    print(("  current on=%d%%  off=%d%%"):format(cfg.onPct or 20, cfg.offPct or 60))
    return
  end
  cfg.onPct = n
  saveCfg()
  print(("on %d%%  (off %d%%)"):format(cfg.onPct, cfg.offPct or 60))
end

local function cmdOff(pct)
  local n = clampPct(pct)
  if not n then
    print("Usage: off <percent>  — turn redstone OFF at this fill %")
    print(("  current on=%d%%  off=%d%%"):format(cfg.onPct or 20, cfg.offPct or 60))
    return
  end
  cfg.offPct = n
  saveCfg()
  print(("off %d%%  (on %d%%)"):format(cfg.offPct, cfg.onPct or 20))
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
  if onP < offP then
    print(("  band:       ON <= %d%% , OFF >= %d%%%s"):format(
      onP, offP, cfg.invert and " (inverted)" or ""))
  elseif onP > offP then
    print(("  band:       ON >= %d%% , OFF <= %d%%%s"):format(
      onP, offP, cfg.invert and " (inverted)" or ""))
  else
    print(("  band:       trip @ %d%%%s"):format(
      onP, cfg.invert and " (inverted)" or ""))
  end
  print(("  interval:   %.1fs"):format(cfg.interval or 1))

  if cfg.storage then
    local fill, err = storageFill(cfg.storage)
    if fill then
      print(("  fill:       %d/%d slots (%d%%), %d items"):format(
        fill.used, fill.size, fill.pct, fill.items))
      local want = desiredOn(fill)
      local applied = (want ~= cfg.invert)
      print(("  latched:    %s → redstone %s"):format(
        want and "ON" or "OFF", applied and "ON" or "OFF"))
      recordFill(fill)
      local rate = fillRate()
      if rate then
        print("  rate:       " .. formatRate(rate))
      else
        print("  rate:       (need a few seconds of samples)")
      end
      pcall(drawMonitor, fill, applied)
    else
      print("  fill:       " .. tostring(err))
    end
  end
  local cur, src = getRedstoneState()
  if cur ~= nil then
    print(("  redstone:   %s (%s)"):format(cur and "ON" or "OFF", src))
  end
  if findMonitor() then
    print("  monitor:    attached (fill % shown)")
  else
    print("  monitor:    (none)")
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
  on <percent>                 turn ON at this fill %  (default 20)
  off <percent>                turn OFF at this fill % (default 60)
  invert [on|off]              flip ON/OFF meaning
  interval <seconds>
  status
  monitor                      redraw fill % on attached screen
  test on|off                  force output (ignores invert)
  run                          watch loop (Ctrl+T to stop)
  help

  Default band: ON at <=20%, OFF at >=60%, hold in between.
]])
  print("Wired modems share peripherals only — not redstone.")
  print("Use a local face OR an Advanced Peripherals Redstone Integrator.")
  print("Attach a monitor to the PC to show fill % and rate.")
end

local function cmdMonitor()
  local ok, err = drawMonitor()
  if ok then
    print("Monitor updated.")
  else
    print("Monitor: " .. tostring(err or "failed"))
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
  if findMonitor() then
    print("Monitor: fill % + rate")
  else
    print("No monitor attached — console only")
  end
  print(("Watching %s — Ctrl+T to stop"):format(cfg.storage))
  local last = nil
  while true do
    local ok, a, b, c = applyOnce()
    if ok then
      local fill, on, src = a, b, c
      local rate = fillRate()
      local rateStr = rate and formatRate(rate) or "rate …"
      local line = ("%s  %3d%%  %s  %d/%d  rs=%s"):format(
        os.date("%H:%M:%S"), fill.pct, rateStr, fill.used, fill.size, on and "ON" or "OFF")
      if line ~= last then
        print(line)
        last = line
      end
    else
      print(os.date("%H:%M:%S") .. "  ERR " .. tostring(a))
      last = nil
      pcall(drawMonitor, nil, nil)
    end
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
