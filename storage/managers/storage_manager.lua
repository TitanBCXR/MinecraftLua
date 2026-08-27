--[[
  storage/managers/storage_manager.lua  -  Create vault rate + fill board
  Titan-Version: 1.1.3

  Auto-detects every Create item vault on the wired modem network and
  tracks the *joined* pool (not per-vault):

    Input rate   — items / min entering the vaults
    Output rate  — items / min leaving the vaults
    Fill percent — used / capacity across all vaults

  Monitor:
    1×1               — in or out (right-click to set that monitor)
    larger than 3×3   — fill wall (title header, boxed fill, max footer)

  Hardware:
    [Create vault] --wired modem--+
    [Create vault] --wired modem--+-- cable -- [PC + wired modem]
    [1×1 in]  [1×1 out]  [>3×3 fill]  -- monitors on the PC
    (optional I/O chests on the same cable for ingest / admin request)

  Commands:
    title [text] | title clear | mons
    status | vaults | invs
    poll [secs] | window [secs]
    bind input|output <name|side>   (optional I/O)
    unbind input|output
    ingest | request <item> [count] | stock [filter] | find <item>
    net | hostname [name] | help | exit

  Run:  storage/managers/storage_manager
]]

local titan = nil
if fs.exists("lib/titan.lua") then
  local ok, t = pcall(dofile, "lib/titan.lua")
  if ok then titan = t end
end

local MSG = titan and titan.MSG or {}
local PROTO = (titan and titan.PROTOCOL) or "titan_net"
local CFG = "storage_manager.cfg"
local VERSION = "1.1.3"

local SCREENS = { "input", "output", "fill" }
local DEFAULT_SLOT_LIMIT = 512
local RATE_MAX_SAMPLES = 180
local HIST_LEN = 48

local SIDE_ALIASES = {
  front = "front", forward = "front", f = "front",
  back = "back", behind = "back", rear = "back", b = "back",
  left = "left", l = "left",
  right = "right", r = "right",
  up = "top", top = "top", above = "top", u = "top",
  down = "bottom", bottom = "bottom", below = "bottom", d = "bottom",
}

local cfg = {
  input = nil,
  output = nil,
  vault = nil,       -- legacy single-vault bind; unused (auto-detect)
  screen = 1,        -- 1=input 2=output 3=fill
  pollSecs = 1,
  windowSecs = 60,
  monRate = 5,
  ingestSecs = 3,
  label = nil,
  title = nil,       -- large-board header (falls back to computer label)
  monRoles = {},     -- [monitorName] = 1 (in) | 2 (out)  — 1×1 rate boards
}

local cache = {
  vaults = {},       -- { name, size, items, cap, used }
  vaultKey = "",
  items = 0,
  cap = 0,
  used = 0,
  slots = 0,
  pct = 0,
  inRate = 0,
  outRate = 0,
  rateReady = false,
  totals = {},
  display = {},
  stockRows = {},
  updated = 0,
  lastItems = nil,
  inCum = 0,
  outCum = 0,
  samples = {},      -- { t, items, inCum, outCum }
  hist = {},         -- sparkline { inR, outR, pct }
  capCache = {},     -- [name] = { size, limit, cap }
  hits = {},
  lastRequest = nil,
  netMain = nil,
  netOk = false,
  ingested = 0,
  lastScanErr = nil,
}

--------------------------------------------------------------------------------
-- Config / clock
--------------------------------------------------------------------------------
local function nowMs()
  if type(os.epoch) == "function" then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r")
  if not f then return end
  local ok, data = pcall(textutils.unserialize, f.readAll())
  f.close()
  if ok and type(data) == "table" then
    for k, v in pairs(data) do cfg[k] = v end
  end
  cfg.screen = math.max(1, math.min(#SCREENS, tonumber(cfg.screen) or 1))
  cfg.pollSecs = math.max(0.25, tonumber(cfg.pollSecs) or 1)
  cfg.windowSecs = math.max(10, math.min(300, tonumber(cfg.windowSecs) or 60))
  if type(cfg.monRoles) ~= "table" then cfg.monRoles = {} end
  if type(cfg.title) == "string" and cfg.title == "" then cfg.title = nil end
end

local function saveCfg()
  local f = fs.open(CFG, "w")
  if f then f.write(textutils.serialize(cfg)); f.close() end
end

local function shortName(name)
  if not name then return "?" end
  return name:match("([^:]+)$") or name
end

local function normalizeSide(s)
  if not s then return nil end
  return SIDE_ALIASES[tostring(s):lower()]
end

--------------------------------------------------------------------------------
-- Peripherals
--------------------------------------------------------------------------------
local function openModem()
  if titan and titan.openModem then
    local ok = pcall(titan.openModem)
    if ok then return true end
  end
  local found = false
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      pcall(peripheral.call, side, "open", rednet.CHANNEL_REPEAT)
      found = true
    end
  end
  return found
end

local function isInventory(name)
  if not name or not peripheral.isPresent(name) then return false end
  if peripheral.hasType and peripheral.hasType(name, "inventory") then return true end
  local w = peripheral.wrap(name)
  return w and type(w.list) == "function" and type(w.size) == "function"
end

local function allNames()
  local seen, out = {}, {}
  local function add(n)
    if n and not seen[n] then
      seen[n] = true
      out[#out + 1] = n
    end
  end
  for _, n in ipairs(peripheral.getNames()) do add(n) end
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      local m = peripheral.wrap(side)
      if m and type(m.getNamesRemote) == "function" then
        local ok, rem = pcall(m.getNamesRemote)
        if ok then
          for _, n in ipairs(rem or {}) do add(n) end
        end
      end
    end
  end
  return out
end

local function isVault(name)
  if not name or not isInventory(name) then return false end
  if name == cfg.input or name == cfg.output then return false end
  local low = tostring(name):lower()
  if low:find("vault", 1, true) then return true end
  local types = { peripheral.getType(name) }
  for _, t in ipairs(types) do
    if tostring(t or ""):lower():find("vault", 1, true) then return true end
  end
  if peripheral.hasType then
    local ok, yes = pcall(peripheral.hasType, name, "create:item_vault")
    if ok and yes then return true end
  end
  return false
end

local function discoverVaults()
  local names = {}
  for _, n in ipairs(allNames()) do
    if isVault(n) then names[#names + 1] = n end
  end
  table.sort(names)
  return names
end

local function listInventories()
  local names = {}
  for _, n in ipairs(allNames()) do
    if isInventory(n) then names[#names + 1] = n end
  end
  table.sort(names)
  return names
end

local function listMonitors()
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "monitor" then
      local w = peripheral.wrap(n)
      if w then out[#out + 1] = { name = n, wrap = w } end
    end
  end
  return out
end

local function resolvePeripheral(ref)
  if not ref or ref == "" then return nil end
  local s = tostring(ref)
  if peripheral.isPresent(s) and isInventory(s) then return s end
  local side = normalizeSide(s)
  if side and peripheral.isPresent(side) then
    if isInventory(side) then return side end
    local t = peripheral.getType(side)
    local wrap = peripheral.wrap(side)
    if t == "modem" and wrap and type(wrap.getNamesRemote) == "function" then
      for _, n in ipairs(wrap.getNamesRemote() or {}) do
        if isInventory(n) then return n end
      end
    end
  end
  local want = s:lower()
  local hits = {}
  for _, name in ipairs(listInventories()) do
    if name:lower():find(want, 1, true) then hits[#hits + 1] = name end
  end
  if #hits == 1 then return hits[1] end
  if #hits > 1 then return nil, hits end
  return nil
end

--------------------------------------------------------------------------------
-- Vault scan + rates
--------------------------------------------------------------------------------
local function slotLimit(wrap, size, list)
  if type(wrap.getItemLimit) ~= "function" then return DEFAULT_SLOT_LIMIT end
  local probe = 1
  if type(list) == "table" and size and size > 0 then
    for i = 1, math.min(size, 40) do
      if list[i] == nil then
        probe = i
        break
      end
    end
  end
  local ok, lim = pcall(wrap.getItemLimit, probe)
  if ok and type(lim) == "number" and lim > 0 then return lim end
  return DEFAULT_SLOT_LIMIT
end

local function vaultCapacity(name, wrap, size, list)
  local prev = cache.capCache[name]
  if prev and prev.size == size then return prev.cap, prev.limit end
  local limit = slotLimit(wrap, size, list)
  local cap = limit * math.max(0, size)
  cache.capCache[name] = { size = size, limit = limit, cap = cap }
  return cap, limit
end

local function scanVaults()
  local names = discoverVaults()
  local key = table.concat(names, "\n")
  if key ~= cache.vaultKey then
    cache.lastItems = nil
    cache.vaultKey = key
    for n in pairs(cache.capCache) do
      local keep = false
      for _, vn in ipairs(names) do
        if vn == n then keep = true; break end
      end
      if not keep then cache.capCache[n] = nil end
    end
  end

  local prevByName = {}
  for _, v in ipairs(cache.vaults) do
    prevByName[v.name] = v
  end

  local vaults, totals = {}, {}
  local items, cap, used, slots = 0, 0, 0, 0
  local err = nil

  for _, name in ipairs(names) do
    local w = peripheral.wrap(name)
    if w and type(w.list) == "function" then
      local okL, list = pcall(w.list)
      if not okL or type(list) ~= "table" then
        err = "list failed: " .. name
        local prev = prevByName[name]
        if prev then
          vaults[#vaults + 1] = prev
          items = items + (prev.items or 0)
          cap = cap + (prev.cap or 0)
          used = used + (prev.used or 0)
          slots = slots + (prev.size or 0)
        end
      else
        local size = 0
        if type(w.size) == "function" then
          local okS, sz = pcall(w.size)
          if okS then size = tonumber(sz) or 0 end
        end
        local vItems, vUsed = 0, 0
        for _, stack in pairs(list) do
          if type(stack) == "table" and stack.name then
            local c = tonumber(stack.count) or 0
            if c > 0 then
              vItems = vItems + c
              vUsed = vUsed + 1
              totals[stack.name] = (totals[stack.name] or 0) + c
            end
          end
        end
        local vCap = vaultCapacity(name, w, size, list)
        vaults[#vaults + 1] = {
          name = name, size = size, items = vItems, cap = vCap, used = vUsed,
        }
        items = items + vItems
        cap = cap + vCap
        used = used + vUsed
        slots = slots + size
      end
    end
  end

  cache.vaults = vaults
  cache.totals = totals
  cache.items = items
  cache.cap = cap
  cache.used = used
  cache.slots = slots
  cache.pct = (cap > 0) and math.floor((items / cap) * 1000 + 0.5) / 10 or 0
  cache.updated = nowMs()
  cache.lastScanErr = err
  return vaults
end

local function recordRates(items)
  local t = nowMs()
  if cache.lastItems ~= nil then
    local d = items - cache.lastItems
    if d > 0 then
      cache.inCum = cache.inCum + d
    elseif d < 0 then
      cache.outCum = cache.outCum + (-d)
    end
  end
  cache.lastItems = items
  local samples = cache.samples
  samples[#samples + 1] = {
    t = t, items = items, inCum = cache.inCum, outCum = cache.outCum,
  }
  local cutoff = t - (tonumber(cfg.windowSecs) or 60) * 1000
  while #samples > 1 and samples[1].t < cutoff do
    table.remove(samples, 1)
  end
  while #samples > RATE_MAX_SAMPLES do
    table.remove(samples, 1)
  end

  local inR, outR, ready = 0, 0, false
  if #samples >= 2 then
    local a, b = samples[1], samples[#samples]
    local dt = (b.t - a.t) / 1000
    if dt >= 2 then
      inR = ((b.inCum - a.inCum) / dt) * 60
      outR = ((b.outCum - a.outCum) / dt) * 60
      ready = true
    end
  end
  cache.inRate = inR
  cache.outRate = outR
  cache.rateReady = ready

  local hist = cache.hist
  hist[#hist + 1] = { inR = inR, outR = outR, pct = cache.pct or 0 }
  while #hist > HIST_LEN do table.remove(hist, 1) end
end

local function rebuildStockRows()
  local rows = {}
  for name, count in pairs(cache.totals) do
    rows[#rows + 1] = {
      name = name,
      count = count,
      displayName = cache.display[name] or shortName(name),
    }
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  cache.stockRows = rows
end

local function refresh()
  scanVaults()
  recordRates(cache.items)
  rebuildStockRows()
  return #cache.vaults > 0
end

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------
local function commas(n)
  n = math.floor(math.abs(tonumber(n) or 0) + 0.5)
  local s = tostring(n)
  local k
  while true do
    s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
    if k == 0 then break end
  end
  return s
end

local function fmtCount(n)
  n = tonumber(n) or 0
  local a = math.abs(n)
  local sign = (n < 0) and "-" or ""
  if a >= 1e9 then return sign .. string.format("%.1fB", a / 1e9)
  elseif a >= 1e6 then return sign .. string.format("%.1fM", a / 1e6)
  elseif a >= 10000 then return sign .. string.format("%.1fk", a / 1000)
  else return sign .. commas(a)
  end
end

local function fmtRate(n, ready)
  if not ready then return "…" end
  n = tonumber(n) or 0
  if math.abs(n) < 0.5 then return "0 /min" end
  return fmtCount(n) .. " /min"
end

local function fmtPct(p)
  p = tonumber(p) or 0
  if p == math.floor(p) then return string.format("%d%%", p) end
  return string.format("%.1f%%", p)
end

--------------------------------------------------------------------------------
-- Optional I/O (admin request / ingest)
--------------------------------------------------------------------------------
local function wrapInv(name)
  if not name or not peripheral.isPresent(name) then return nil, name end
  if not isInventory(name) then return nil, name end
  return peripheral.wrap(name), name
end

local function matchFilter(row, filter)
  if not filter or filter == "" then return true end
  local f = tostring(filter):lower()
  if row.name:lower():find(f, 1, true) then return true end
  if row.displayName and row.displayName:lower():find(f, 1, true) then return true end
  return false
end

local function filteredRows(filter, limit)
  local out = {}
  for _, row in ipairs(cache.stockRows) do
    if matchFilter(row, filter) then
      out[#out + 1] = row
      if limit and #out >= limit then break end
    end
  end
  return out
end

local function resolveItemQuery(query)
  local q = tostring(query or "")
  if q == "" then return nil end
  local ql = q:lower()
  if ql:find(":", 1, true) then return q end
  if (nowMs() - (cache.updated or 0)) > 5000 then refresh() end
  for _, row in ipairs(cache.stockRows) do
    if row.name:lower() == ql
       or shortName(row.name):lower() == ql
       or (row.displayName and row.displayName:lower() == ql) then
      return row.name
    end
  end
  for _, row in ipairs(cache.stockRows) do
    if row.name:lower():find(ql, 1, true)
       or (row.displayName and row.displayName:lower():find(ql, 1, true)) then
      return row.name
    end
  end
  return nil
end

local function ingestOnce()
  local input, iname = wrapInv(cfg.input)
  if not input then return 0, "need bound input" end
  if #cache.vaults == 0 then scanVaults() end
  if #cache.vaults == 0 then return 0, "no vaults" end
  local ok, list = pcall(input.list)
  if not ok or type(list) ~= "table" then return 0, "input list failed" end
  local moved = 0
  for slot, item in pairs(list) do
    if type(item) == "table" and item.name and (tonumber(item.count) or 0) > 0 then
      for _, v in ipairs(cache.vaults) do
        local okp, n = pcall(input.pushItems, v.name, slot)
        if okp and type(n) == "number" and n > 0 then
          moved = moved + n
          if (tonumber(item.count) or 0) - n <= 0 then break end
        end
      end
    end
  end
  cache.ingested = (cache.ingested or 0) + moved
  return moved
end

local function fulfillRequest(itemQuery, count)
  count = math.max(1, math.floor(tonumber(count) or 64))
  local output, oname = wrapInv(cfg.output)
  if not output then return false, "output not bound", 0, nil end
  pcall(ingestOnce)
  scanVaults()
  rebuildStockRows()
  local itemName = resolveItemQuery(itemQuery)
  if not itemName then return false, "item not found: " .. tostring(itemQuery), 0, nil end
  local moved, guard = 0, 0
  while moved < count and guard < 512 do
    guard = guard + 1
    local progress = false
    for _, v in ipairs(cache.vaults) do
      local vault = peripheral.wrap(v.name)
      if vault then
        local ok, list = pcall(vault.list)
        if ok and type(list) == "table" then
          for slot, item in pairs(list) do
            if type(item) == "table" and item.name == itemName then
              local avail = tonumber(item.count) or 0
              if avail > 0 then
                local need = math.min(count - moved, avail)
                local okp, n = pcall(vault.pushItems, oname, slot, need)
                if okp and type(n) == "number" and n > 0 then
                  moved = moved + n
                  progress = true
                  if moved >= count then break end
                end
              end
            end
          end
        end
      end
      if moved >= count then break end
    end
    if not progress then break end
  end
  cache.lastRequest = { item = itemName, want = count, moved = moved, at = nowMs() }
  refresh()
  if moved < 1 then
    return false, "none moved (empty or output full?)", 0, itemName
  end
  return true, moved, moved, itemName
end

--------------------------------------------------------------------------------
-- Network
--------------------------------------------------------------------------------
local function statusPayload()
  local kinds = #cache.stockRows
  return {
    name = os.getComputerLabel() or ("Storage-" .. os.getComputerID()),
    kind = "storage",
    mode = "vault",
    vault = cache.vaults[1] and cache.vaults[1].name or cfg.vault,
    vaults = #cache.vaults,
    input = cfg.input,
    output = cfg.output,
    types = kinds,
    units = cache.items,
    items = cache.items,
    capacity = cache.cap,
    fillPct = cache.pct,
    inRate = cache.inRate,
    outRate = cache.outRate,
    lastRequest = cache.lastRequest,
    version = VERSION,
  }
end

local function announceStorage()
  local payload = statusPayload()
  if titan and titan.broadcast then
    pcall(titan.broadcast, MSG.STORAGE_HELLO or "storage_hello", payload)
  end
  rednet.broadcast({
    type = "storage_hello",
    from = os.getComputerID(),
    name = payload.name,
    kind = "storage",
    vault = payload.vault, input = cfg.input, output = cfg.output,
    types = payload.types, units = payload.units,
    vaults = payload.vaults, fillPct = payload.fillPct,
    inRate = payload.inRate, outRate = payload.outRate,
  }, PROTO)
end

--------------------------------------------------------------------------------
-- Monitor UI  (quiet, centered — not the fleet chip/header boards)
--------------------------------------------------------------------------------
local function outIsColor(out)
  local ok, c = pcall(function() return out.isColor and out.isColor() end)
  return ok and c == true
end

local function boardPal(color)
  if color then
    return {
      bg = colors.black,
      fg = colors.white,
      mute = colors.lightGray,
      dim = colors.gray,
      line = colors.gray,
      bar = colors.white,
      track = colors.gray,
    }
  end
  return {
    bg = colors.black,
    fg = colors.white,
    mute = colors.white,
    dim = colors.white,
    line = colors.white,
    bar = colors.white,
    track = colors.black,
  }
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

local function addHit(monName, x, y, ww, screen)
  cache.hits[#cache.hits + 1] = {
    mon = monName, x1 = x, x2 = x + ww - 1, y = y, screen = screen,
  }
end

local function centerX(w, text)
  return math.max(1, math.floor((w - #tostring(text)) / 2) + 1)
end

local function boxTextX(ix, iw, txt)
  txt = tostring(txt or "")
  if #txt >= iw then return ix end
  return ix + math.floor((iw - #txt) / 2)
end

local function fmtHero(n)
  n = tonumber(n) or 0
  local a = math.abs(n)
  if a >= 1e6 then return fmtCount(n) end
  return commas(n)
end

local function boardTitle()
  local t = cfg.title
  if type(t) == "string" and t:match("%S") then return t end
  return os.getComputerLabel() or cfg.label or "storage"
end

local function ratePair(rate, ready)
  if not ready then return "—", "/min" end
  rate = tonumber(rate) or 0
  if math.abs(rate) < 0.5 then return "0", "/min" end
  return fmtHero(rate), "/min"
end

--- Advanced monitor block is 8×6 at scale 1. Measure at scale 1.
local function measureBlocks(out)
  if out.setTextScale then pcall(function() out.setTextScale(1) end) end
  local w, h = out.getSize()
  local bw = math.max(1, math.floor(w / 8 + 0.05))
  local bh = math.max(1, math.floor(h / 6 + 0.05))
  return bw, bh, w, h
end

local function isSingleBlock(bw, bh)
  return bw <= 1 and bh <= 1
end

local function isFillWall(bw, bh)
  return bw > 3 or bh > 3
end

local function collectSingleNames()
  local names = {}
  for _, m in ipairs(listMonitors()) do
    local bw, bh = measureBlocks(m.wrap)
    if isSingleBlock(bw, bh) then names[#names + 1] = m.name end
  end
  table.sort(names)
  return names
end

local function ensureRateRoles()
  if type(cfg.monRoles) ~= "table" then cfg.monRoles = {} end
  local names = collectSingleNames()
  local dirty = false
  local taken = { [1] = false, [2] = false }
  for _, n in ipairs(names) do
    local r = tonumber(cfg.monRoles[n])
    if r == 1 or r == 2 then taken[r] = true end
  end
  for _, n in ipairs(names) do
    local r = tonumber(cfg.monRoles[n])
    if r ~= 1 and r ~= 2 then
      if not taken[1] then r = 1
      elseif not taken[2] then r = 2
      else r = 1 end
      cfg.monRoles[n] = r
      taken[r] = true
      dirty = true
    end
  end
  if dirty then saveCfg() end
end

local function rateRoleFor(monName)
  ensureRateRoles()
  local r = tonumber(cfg.monRoles[monName])
  if r == 2 then return 2 end
  return 1
end

local function toggleRateRole(monName)
  ensureRateRoles()
  local cur = rateRoleFor(monName)
  local new = (cur == 1) and 2 or 1
  for n, r in pairs(cfg.monRoles) do
    if n ~= monName and tonumber(r) == new then
      cfg.monRoles[n] = cur
    end
  end
  cfg.monRoles[monName] = new
  saveCfg()
end

--- Keep scale 1 (1×1 stays 8×6; walls stay large type).
local function applyMonitorScale(out)
  if not out or not out.setTextScale then
    local w, h = out.getSize()
    return 1, w, h
  end
  pcall(function() out.setTextScale(1) end)
  local w, h = out.getSize()
  return 1, w, h
end

local function drawTrack(out, x, y, ww, pct, pal, color)
  local W = select(1, out.getSize())
  ww = math.min(ww, W - x + 1)
  if ww < 4 then return end
  pct = math.max(0, math.min(100, tonumber(pct) or 0))
  local filled = math.floor((pct / 100) * ww + 0.5)
  if color then
    guiFill(out, x, y, ww, 1, pal.track, pal.fg)
    if filled > 0 then
      guiFill(out, x, y, filled, 1, pal.bar, pal.bg)
    end
  else
    local bar = string.rep("#", filled) .. string.rep("-", math.max(0, ww - filled))
    guiText(out, x, y, bar, pal.fg, pal.bg)
  end
end

local function drawFrame(out, x, y, ww, hh, pal, color)
  if ww < 3 or hh < 3 then return end
  if color then
    guiFill(out, x, y, ww, 1, pal.line, pal.bg)
    guiFill(out, x, y + hh - 1, ww, 1, pal.line, pal.bg)
    for row = y + 1, y + hh - 2 do
      guiFill(out, x, row, 1, 1, pal.line, pal.bg)
      guiFill(out, x + ww - 1, row, 1, 1, pal.line, pal.bg)
    end
  else
    guiText(out, x, y, "+" .. string.rep("-", ww - 2) .. "+", pal.fg, pal.bg)
    guiText(out, x, y + hh - 1, "+" .. string.rep("-", ww - 2) .. "+", pal.fg, pal.bg)
    for row = y + 1, y + hh - 2 do
      guiText(out, x, row, "|", pal.fg, pal.bg)
      guiText(out, x + ww - 1, row, "|", pal.fg, pal.bg)
    end
  end
end

local function drawMetricBox(out, x, y, ww, hh, spec, pal, color)
  drawFrame(out, x, y, ww, hh, pal, color)
  local ix, iy = x + 2, y + 1
  local iw, ih = ww - 4, hh - 2
  if iw < 1 or ih < 1 then return end
  guiText(out, ix, iy, tostring(spec.label or ""):sub(1, iw), pal.dim, pal.bg)

  local hasBar = spec.pct ~= nil
  local heroY
  if hasBar then
    heroY = iy + math.max(1, math.floor(ih * 0.28))
  else
    heroY = iy + math.max(1, math.floor((ih - 1) / 2) - (spec.unit and 1 or 0))
  end
  if heroY > iy + ih - 1 then heroY = iy + ih - 1 end
  guiText(out, boxTextX(ix, iw, spec.hero), heroY, tostring(spec.hero or ""), pal.fg, pal.bg)
  if spec.unit and heroY + 1 <= iy + ih - 1 then
    guiText(out, boxTextX(ix, iw, spec.unit), heroY + 1, spec.unit, pal.mute, pal.bg)
  end
  if hasBar then
    local barY = iy + ih - (spec.sub and 2 or 1)
    if barY <= heroY + 1 then barY = heroY + 2 end
    if barY <= iy + ih - 1 and barY > iy then
      drawTrack(out, ix, barY, math.max(4, iw), spec.pct, pal, color)
    end
    if spec.sub and barY + 1 <= iy + ih - 1 then
      guiText(out, ix, barY + 1, tostring(spec.sub):sub(1, iw), pal.mute, pal.bg)
    end
  end
end

local function drawHairline(out, x, y, ww, pal, color)
  if ww < 1 then return end
  if color then
    guiFill(out, x, y, ww, 1, pal.line, pal.bg)
  else
    guiText(out, x, y, string.rep("-", ww), pal.dim, pal.bg)
  end
end

local function drawLargeBoard(out, w, h, pal, color)
  local title = boardTitle()
  guiText(out, 3, 2, title:sub(1, math.max(0, w - 4)), pal.fg, pal.bg)
  drawHairline(out, 3, 3, math.max(1, w - 4), pal, color)

  local capTxt = ((cache.cap or 0) > 0) and fmtHero(cache.cap) or "—"
  drawHairline(out, 3, h - 1, math.max(1, w - 4), pal, color)
  guiText(out, 3, h, "max", pal.dim, pal.bg)
  guiText(out, math.max(8, w - 1 - #capTxt), h, capTxt, pal.fg, pal.bg)

  local pad = 2
  local top, bot = 5, h - 2
  local x0 = 1 + pad
  local innerW = w - 2 * pad
  local innerH = bot - top + 1
  if innerW < 10 or innerH < 6 then return end

  local nVault = #cache.vaults
  local fillHero = (nVault == 0) and "—" or fmtPct(cache.pct or 0)
  local fillSub
  if nVault == 0 then
    fillSub = "no vaults"
  elseif (cache.cap or 0) > 0 then
    fillSub = fmtHero(cache.items) .. "  /  " .. fmtHero(cache.cap)
  end
  drawMetricBox(out, x0, top, innerW, innerH, {
    label = "fill",
    hero = fillHero,
    pct = cache.pct or 0,
    sub = fillSub,
  }, pal, color)
end

local function drawSparseBoard(out, w, h, pal, color, screen)
  screen = screen or 1
  local nVault = #cache.vaults
  local pct = cache.pct or 0
  local labels = { "in", "out", "fill" }
  local hero, unit
  if nVault == 0 then
    hero, unit = "no vaults", nil
  elseif screen == 3 then
    hero = fmtPct(pct)
    unit = nil
  else
    hero, unit = ratePair(screen == 1 and cache.inRate or cache.outRate, cache.rateReady)
  end

  local bodyH = h
  local block = 1
  if nVault > 0 then
    block = (h >= 4) and 3 or 1
    if unit and h >= 5 then block = block + 1 end
    if screen == 3 and h >= 5 then block = block + 2 end
  end
  local y = math.max(1, math.floor((bodyH - block) / 2) + 1)

  local function line(txt, fg)
    if y > bodyH then return end
    guiText(out, centerX(w, txt), y, txt, fg or pal.fg, pal.bg)
    y = y + 1
  end
  local function skip()
    if y < bodyH then y = y + 1 end
  end

  if nVault == 0 then
    line(hero, pal.mute)
    return
  end
  if h >= 4 then line(labels[screen], pal.dim) end
  if h >= 6 then skip() end
  line(hero, pal.fg)
  if unit then
    line(unit, pal.mute)
  end
  if screen == 3 and y <= bodyH and h >= 5 then
    if h >= 8 then skip() end
    local barW = math.max(4, math.min(w - 2, math.floor(w * 0.7)))
    if y <= bodyH then
      drawTrack(out, math.max(1, math.floor((w - barW) / 2) + 1), y, barW, pct, pal, color)
      y = y + 1
    end
    if y <= bodyH and h >= 10 and (cache.cap or 0) > 0 then
      skip()
      line(fmtHero(cache.items) .. "  /  " .. fmtHero(cache.cap), pal.mute)
    end
  end
end

local function drawOneMonitor(mon)
  local out, monName = mon.wrap, mon.name
  if not out then return end
  local color = outIsColor(out)
  local pal = boardPal(color)
  local bw, bh, w, h = measureBlocks(out)
  applyMonitorScale(out)
  w, h = out.getSize()

  if out.setBackgroundColor then out.setBackgroundColor(pal.bg) end
  out.clear()

  if isSingleBlock(bw, bh) then
    drawSparseBoard(out, w, h, pal, color, rateRoleFor(monName))
  elseif isFillWall(bw, bh) then
    drawLargeBoard(out, w, h, pal, color)
  else
    drawSparseBoard(out, w, h, pal, color, 3)
  end
end

local function drawMonitor()
  cache.hits = {}
  local mons = listMonitors()
  if #mons == 0 then return false, "no monitor" end
  for _, m in ipairs(mons) do
    pcall(drawOneMonitor, m)
  end
  return true
end

local function setScreen(n)
  n = math.max(1, math.min(#SCREENS, tonumber(n) or 1))
  if cfg.screen ~= n then
    cfg.screen = n
    saveCfg()
  end
  drawMonitor()
end

local function cycleScreen()
  setScreen((cfg.screen % #SCREENS) + 1)
end

local function touchToScreen(monName, x, y)
  for _, h in ipairs(cache.hits or {}) do
    if (not h.mon or h.mon == monName)
       and y == h.y and x >= h.x1 and x <= h.x2 then
      return h.screen
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function printHelp()
  print("Storage Manager v" .. VERSION)
  print("  Auto-detects Create vaults on the wired network.")
  print("  1x1 monitor: right-click to set IN or OUT")
  print("  >3x3 monitor: fill wall  (title / max footer)")
  print("  title [text] | title clear")
  print("  mons | status | vaults | invs")
  print("  poll [secs] | window [secs]")
  print("  bind input|output <peripheral|side>   (optional I/O)")
  print("  unbind input|output")
  print("  ingest | request <item> [count]")
  print("  stock [filter] | find <item>")
  print("  net | hostname [name] | help | exit")
end

local function printStatus()
  print(("vaults: %d   items: %s / %s  (%s)"):format(
    #cache.vaults, fmtCount(cache.items), fmtCount(cache.cap), fmtPct(cache.pct)))
  print(("in:  %s"):format(fmtRate(cache.inRate, cache.rateReady)))
  print(("out: %s"):format(fmtRate(cache.outRate, cache.rateReady)))
  print(("title: %s"):format(boardTitle()))
  print(("poll: %ss   window: %ss"):format(
    tostring(cfg.pollSecs), tostring(cfg.windowSecs)))
  print(("input:  %s"):format(tostring(cfg.input or "(unbound)")))
  print(("output: %s"):format(tostring(cfg.output or "(unbound)")))
  print(("net: %s"):format(cache.netOk and ("MAIN #" .. tostring(cache.netMain)) or "offline"))
end

local function printStock(filter, limit)
  limit = limit or 40
  if (nowMs() - (cache.updated or 0)) > 2000 then refresh() end
  local rows = filteredRows(filter, limit)
  print(("Stock (all vaults)  %d type(s)%s"):format(
    #cache.stockRows, filter and ("  filter='" .. filter .. "'") or ""))
  if #rows == 0 then print("  (no matches)"); return end
  for _, row in ipairs(rows) do
    print(("  %6s  %-22s %s"):format(
      fmtCount(row.count), (row.displayName or shortName(row.name)):sub(1, 22), row.name))
  end
end

local function parseScreen(s)
  s = tostring(s or ""):lower()
  if s == "1" or s == "in" or s == "input" then return 1 end
  if s == "2" or s == "out" or s == "output" then return 2 end
  if s == "3" or s == "fill" or s == "pct" or s == "full" then return 3 end
  return nil
end

local function handleCommand(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = tostring(a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" or cmd == "?" then printHelp()
  elseif cmd == "status" then
    refresh(); printStatus(); drawMonitor()
  elseif cmd == "vaults" then
    scanVaults()
    print(("Vaults (%d):"):format(#cache.vaults))
    if #cache.vaults == 0 then
      print("  (none) — right-click wired modems on each Create vault")
    else
      for _, v in ipairs(cache.vaults) do
        local p = (v.cap > 0) and (v.items / v.cap * 100) or 0
        print(("  %s  %s/%s  %s"):format(
          v.name, fmtCount(v.items), fmtCount(v.cap), fmtPct(p)))
      end
    end
    print("Board shows joined totals, not per-vault.")
  elseif cmd == "invs" or cmd == "peripherals" then
    local invs = listInventories()
    print(("Inventories (%d):"):format(#invs))
    local vset = {}
    for _, v in ipairs(cache.vaults) do vset[v.name] = true end
    for _, n in ipairs(invs) do
      local tag = ""
      if vset[n] then tag = "  [vault]"
      elseif n == cfg.input then tag = "  [input]"
      elseif n == cfg.output then tag = "  [output]" end
      print("  " .. n .. tag)
    end
  elseif cmd == "mons" or cmd == "monitors" or cmd == "screens" then
    ensureRateRoles()
    local mons = listMonitors()
    print(("Monitors (%d):"):format(#mons))
    if #mons == 0 then print("  (none)"); return true end
    for _, m in ipairs(mons) do
      local bw, bh = measureBlocks(m.wrap)
      local kind
      if isSingleBlock(bw, bh) then
        local r = rateRoleFor(m.name)
        kind = (r == 2) and "OUT (right-click to set IN)" or "IN (right-click to set OUT)"
      elseif isFillWall(bw, bh) then
        kind = "FILL wall"
      else
        kind = "fill"
      end
      print(("  %s  %dx%d  %s"):format(m.name, bw, bh, kind))
    end
  elseif cmd == "title" then
    if not a[2] then
      print("title: " .. boardTitle())
    elseif tostring(a[2]):lower() == "clear" and not a[3] then
      cfg.title = nil
      saveCfg()
      drawMonitor()
      print("title cleared (using hostname)")
    else
      cfg.title = table.concat(a, " ", 2)
      saveCfg()
      drawMonitor()
      print("title: " .. cfg.title)
    end
  elseif cmd == "screen" then
    print("1x1 monitors: right-click to set IN or OUT.")
    print("Fill is the >3x3 wall.  Type mons to list.")
  elseif cmd == "poll" then
    if a[2] then
      cfg.pollSecs = math.max(0.25, tonumber(a[2]) or cfg.pollSecs)
      saveCfg()
    end
    print("poll=" .. tostring(cfg.pollSecs) .. "s")
  elseif cmd == "window" then
    if a[2] then
      cfg.windowSecs = math.max(10, math.min(300, tonumber(a[2]) or cfg.windowSecs))
      saveCfg()
    end
    print("window=" .. tostring(cfg.windowSecs) .. "s")
  elseif cmd == "bind" then
    local role = tostring(a[2] or ""):lower()
    local ref = a[3] and table.concat(a, " ", 3) or nil
    if (role ~= "input" and role ~= "output") or not ref then
      print("Usage: bind input|output <peripheralName|side>")
      print("Vaults are auto-detected — no bind needed.")
    else
      local name, hits = resolvePeripheral(ref)
      if not name then
        if hits then
          print("Ambiguous — matches:")
          for _, h in ipairs(hits) do print("  " .. h) end
        else
          print("No inventory matching: " .. tostring(ref))
        end
      else
        cfg[role] = name
        saveCfg()
        print(("Bound %s = %s"):format(role, name))
        refresh(); drawMonitor(); announceStorage()
      end
    end
  elseif cmd == "unbind" then
    local role = tostring(a[2] or ""):lower()
    if role ~= "input" and role ~= "output" then
      print("Usage: unbind input|output")
    else
      cfg[role] = nil
      saveCfg()
      print("Unbound " .. role)
      refresh(); drawMonitor()
    end
  elseif cmd == "stock" or cmd == "list" then
    printStock(a[2] and table.concat(a, " ", 2) or nil, 40)
    drawMonitor()
  elseif cmd == "find" or cmd == "search" then
    if not a[2] then print("Usage: find <item>")
    else printStock(table.concat(a, " ", 2), 50) end
  elseif cmd == "ingest" then
    local n, err = ingestOnce()
    if err and n == 0 then print("ingest: " .. tostring(err))
    else print(("Ingested %d item(s) into vaults."):format(n or 0)) end
    refresh(); drawMonitor()
  elseif cmd == "request" or cmd == "req" then
    if not a[2] then
      print("Usage: request <item> [count]")
    else
      local item, count
      if tonumber(a[#a]) and #a >= 3 then
        count = tonumber(a[#a])
        item = table.concat(a, " ", 2, #a - 1)
      else
        item = table.concat(a, " ", 2)
        count = 64
      end
      local ok, movedOrErr, moved, resolved = fulfillRequest(item, count)
      if ok then
        print(("Sent %d x %s -> output"):format(moved or movedOrErr, tostring(resolved)))
      else
        print("Request failed: " .. tostring(movedOrErr))
      end
      drawMonitor()
    end
  elseif cmd == "monrate" then
    if a[2] then
      cfg.monRate = math.max(1, tonumber(a[2]) or cfg.monRate)
      saveCfg()
    end
    print("monRate=" .. tostring(cfg.monRate) .. "s  (board follows poll=" .. tostring(cfg.pollSecs) .. "s)")
  elseif cmd == "net" then
    if titan and titan.reauth then pcall(titan.reauth, "storage") end
    cache.netMain = titan and titan.getMainRouterId and titan.getMainRouterId() or nil
    cache.netOk = cache.netMain ~= nil
    announceStorage()
    print(cache.netOk and ("Linked MAIN #" .. cache.netMain) or "No MAIN router yet.")
  elseif cmd == "hostname" or cmd == "host" then
    if a[2] then
      local name = table.concat(a, " ", 2)
      os.setComputerLabel(name)
      cfg.label = name
      saveCfg()
      announceStorage()
    end
    print("hostname: " .. tostring(os.getComputerLabel()))
  elseif cmd == "refresh" or cmd == "monitor" then
    refresh(); drawMonitor(); print("Refreshed.")
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    print("Unknown. Type help.")
  end
  return true
end

--------------------------------------------------------------------------------
-- Loops
--------------------------------------------------------------------------------
local function eventLoop()
  local pollT = os.startTimer(0.2)
  local helloT = os.startTimer(2)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "timer" and p1 == pollT then
      pcall(refresh)
      pcall(drawMonitor)
      pollT = os.startTimer(tonumber(cfg.pollSecs) or 1)
    elseif ev == "timer" and p1 == helloT then
      if titan and titan.getMainRouterId then
        cache.netMain = titan.getMainRouterId()
        cache.netOk = cache.netMain ~= nil
      end
      pcall(announceStorage)
      helloT = os.startTimer(20)
    elseif ev == "monitor_touch" then
      local name = p1
      local wrap = name and peripheral.wrap(name)
      if wrap and peripheral.getType(name) == "monitor" then
        local bw, bh = measureBlocks(wrap)
        if isSingleBlock(bw, bh) then
          toggleRateRole(name)
          pcall(drawMonitor)
        end
      end
    elseif ev == "rednet_message" and (p3 == PROTO or p3 == nil) and type(p2) == "table" then
      local msg, from = p2, p1
      local t = msg.type
      if t == "storage_ping" or t == MSG.STORAGE_PING or t == "ping" or t == MSG.PING then
        rednet.send(from, {
          type = "storage_status",
          ok = true,
          from = os.getComputerID(),
          data = statusPayload(),
        }, PROTO)
        if titan and titan.send and MSG.STORAGE_STATUS then
          pcall(titan.send, from, MSG.STORAGE_STATUS, statusPayload())
        end
      elseif t == "storage_stock_req" or t == MSG.STORAGE_STOCK_REQ then
        if (nowMs() - (cache.updated or 0)) > 5000 then pcall(refresh) end
        local rows = filteredRows(msg.filter, tonumber(msg.limit) or 40)
        local slim = {}
        for i, r in ipairs(rows) do
          slim[i] = { name = r.name, count = r.count, displayName = r.displayName }
        end
        rednet.send(from, {
          type = "storage_stock",
          ok = true,
          from = os.getComputerID(),
          items = slim,
          types = #cache.stockRows,
          mode = "vault",
        }, PROTO)
      elseif t == "storage_request" or t == MSG.STORAGE_REQUEST then
        local ok, movedOrErr, moved, resolved = fulfillRequest(
          msg.item or msg.name, msg.count)
        rednet.send(from, {
          type = "storage_request_ack",
          ok = ok,
          err = not ok and tostring(movedOrErr) or nil,
          moved = ok and (moved or movedOrErr) or 0,
          item = resolved,
          count = msg.count,
          from = os.getComputerID(),
        }, PROTO)
        pcall(drawMonitor)
      end
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      pcall(scanVaults)
      pcall(drawMonitor)
    end
  end
end

local function ingestLoop()
  while true do
    if cfg.input then pcall(ingestOnce) end
    sleep(tonumber(cfg.ingestSecs) or 3)
  end
end

local function consoleLoop()
  while true do
    write("storage> ")
    local line = read()
    local r = handleCommand(line)
    if r == "exit" then return end
  end
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------
if not openModem() then
  printError("No modem — attach a wired modem to the vault cable.")
end
loadCfg()
os.setComputerLabel(os.getComputerLabel() or cfg.label or ("StorageManager-" .. os.getComputerID()))
cfg.label = os.getComputerLabel()
saveCfg()

term.clear(); term.setCursorPos(1, 1)
print("== Storage Manager v" .. VERSION .. " ==")
print("Create vault board — 1x1 IN/OUT, >3x3 FILL")
print("Right-click a 1x1 monitor to set in or out.")
print("Fill wall: title <name>   |   mons to list screens.")
if titan and titan.reauth then pcall(titan.reauth, "storage") end
cache.netMain = titan and titan.getMainRouterId and titan.getMainRouterId() or nil
cache.netOk = cache.netMain ~= nil
refresh()
announceStorage()
drawMonitor()
if #cache.vaults == 0 then
  print("No vaults yet. Right-click wired modems on each Create vault.")
else
  print(("Tracking %d vault(s), %s items (%s)."):format(
    #cache.vaults, fmtCount(cache.items), fmtPct(cache.pct)))
end
print("Type help.")

parallel.waitForAny(consoleLoop, eventLoop, ingestLoop)
print("Storage manager closed.")
