--[[
  storage_manager.lua  -  Titan Storage Manager (Create + inventories)
  Titan-Version: 1.0.1

  Watches Create mod storage (Stock Ticker) and/or any attached inventory
  peripherals (Create vaults, chests, barrels, drawers, …).

  Placement tips (Create):
    * Put a Stock Ticker on a face of this computer, then:
        ticker back     (or front / left / right / up / down)
    * Link the ticker to your Create packager / stock network as usual.
    * Optional: attach vaults/chests via wired modems for inventory fallback.

  Console:
    status | stock [filter] | find <item>
    request <item> [count] [address]   (Create Stock Ticker)
    ticker [side]   set/show Stock Ticker direction
    sides | invs | refresh | hostname [name]
    help | exit

  Run:  storage_manager
  Install role: StorageManager
]]

local titan = dofile("lib/titan.lua")

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("StorageManager-" .. os.getComputerID()))

local CFG = "storage_manager.cfg"
local TICKER_TYPES = {
  Create_StockTicker = true,
  create_stockticker = true,
  stock_ticker = true,
}

local cfg = {
  requestAddress = "StorageManager",  -- Create package address for requests
  refreshSecs = 5,
  tickerSide = nil,                   -- front|back|left|right|top|bottom
}

-- User-facing direction -> CraftOS peripheral side name.
local SIDE_ALIASES = {
  front = "front", forward = "front", f = "front",
  back = "back", behind = "back", rear = "back", b = "back",
  left = "left", l = "left",
  right = "right", r = "right",
  up = "top", top = "top", above = "top", u = "top",
  down = "bottom", bottom = "bottom", below = "bottom", d = "bottom",
}
local SIDE_ORDER = { "front", "back", "left", "right", "top", "bottom" }

local cache = {
  mode = "none",          -- "create" | "inventory" | "none"
  tickerName = nil,
  tickerSide = nil,       -- resolved side currently in use
  items = {},             -- sorted { name, count, displayName }
  totals = {},            -- [name] = count
  invCount = 0,
  updated = 0,
}

local monitor = peripheral.find("monitor")
if monitor then pcall(function() monitor.setTextScale(0.5) end) end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  if type(d) == "table" then
    for k, v in pairs(d) do cfg[k] = v end
  end
end

local function saveCfg()
  local f = fs.open(CFG, "w"); f.write(textutils.serialize(cfg)); f.close()
end

loadCfg()
-- Normalize any saved side aliases (e.g. "up" -> "top").
if cfg.tickerSide then
  cfg.tickerSide = SIDE_ALIASES[tostring(cfg.tickerSide):lower()] or cfg.tickerSide
end

--------------------------------------------------------------------------------
-- Peripheral discovery
--------------------------------------------------------------------------------
local function normalizeSide(s)
  if not s then return nil end
  return SIDE_ALIASES[tostring(s):lower()]
end

local function isTickerWrap(wrap)
  return wrap and type(wrap.stock) == "function"
end

local function tickerOnSide(side)
  if not side or not peripheral.isPresent(side) then return nil, nil end
  local t = peripheral.getType(side)
  local wrap = peripheral.wrap(side)
  if isTickerWrap(wrap) then
    return side, wrap, t
  end
  -- Wired modem on that face: look through its remote names for a ticker.
  if t == "modem" and wrap and type(wrap.getNamesRemote) == "function" then
    local ok, remotes = pcall(wrap.getNamesRemote)
    if ok and type(remotes) == "table" then
      for _, rname in ipairs(remotes) do
        local rt = peripheral.getType(rname)
        if rt and TICKER_TYPES[rt] then
          local rw = peripheral.wrap(rname)
          if isTickerWrap(rw) then return rname, rw, rt, side end
        end
      end
    end
  end
  if t and TICKER_TYPES[t] and isTickerWrap(wrap) then
    return side, wrap, t
  end
  return nil, nil
end

local function findTicker()
  cache.tickerSide = nil
  -- 1) Preferred configured side.
  local prefer = normalizeSide(cfg.tickerSide) or cfg.tickerSide
  if prefer then
    local name, wrap = tickerOnSide(prefer)
    if name and wrap then
      cache.tickerSide = prefer
      return name, wrap
    end
  end
  -- 2) Scan local faces (front/back/left/right/up/down).
  for _, side in ipairs(SIDE_ORDER) do
    local name, wrap = tickerOnSide(side)
    if name and wrap then
      cache.tickerSide = side
      return name, wrap
    end
  end
  -- 3) Any network/remote ticker.
  for _, name in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(name)
    if t and TICKER_TYPES[t] then
      local wrap = peripheral.wrap(name)
      if isTickerWrap(wrap) then
        return name, wrap
      end
    end
  end
  local w = peripheral.find("Create_StockTicker")
  if isTickerWrap(w) then
    return peripheral.getName(w), w
  end
  return nil, nil
end

local function describeSides()
  local rows = {}
  for _, side in ipairs(SIDE_ORDER) do
    local present = peripheral.isPresent(side)
    local typ = present and peripheral.getType(side) or nil
    local name, wrap = tickerOnSide(side)
    local mark = ""
    if cfg.tickerSide == side then mark = "  <- configured" end
    if name and wrap then mark = mark .. "  [STOCK TICKER]" end
    rows[#rows + 1] = {
      side = side,
      typ = typ or "(empty)",
      ticker = name ~= nil,
      mark = mark,
    }
  end
  return rows
end

local function setTickerSide(dir)
  local side = normalizeSide(dir)
  if not side then
    return false, "Use: front back left right up down"
  end
  cfg.tickerSide = side
  saveCfg()
  local name, wrap = tickerOnSide(side)
  if name and wrap then
    cache.tickerSide = side
    cache.tickerName = name
    return true, side, name
  end
  return true, side, nil  -- saved, but nothing there yet
end

local function listInventories()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType and peripheral.hasType(name, "inventory") then
      names[#names + 1] = name
    else
      local w = peripheral.wrap(name)
      if w and type(w.list) == "function" and type(w.size) == "function" then
        -- Skip stock tickers (they also have list() for payment slots).
        local t = peripheral.getType(name)
        if not (t and TICKER_TYPES[t]) then
          names[#names + 1] = name
        end
      end
    end
  end
  table.sort(names)
  return names
end

--------------------------------------------------------------------------------
-- Stock scan
--------------------------------------------------------------------------------
local function shortName(name)
  if not name then return "?" end
  local bare = name:match("([^:]+)$") or name
  return bare
end

local function rebuildRows()
  local rows = {}
  for name, count in pairs(cache.totals) do
    rows[#rows + 1] = {
      name = name,
      count = count,
      displayName = cache.display and cache.display[name] or shortName(name),
    }
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  cache.items = rows
end

local function scanCreate(ticker)
  local ok, stock = pcall(ticker.stock, true)
  if not ok or type(stock) ~= "table" then
    ok, stock = pcall(ticker.stock)
  end
  if not ok or type(stock) ~= "table" then
    return false, tostring(stock)
  end
  local totals, display = {}, {}
  for _, item in pairs(stock) do
    if type(item) == "table" and item.name then
      local n = item.name
      totals[n] = (totals[n] or 0) + (tonumber(item.count) or 0)
      if item.displayName then display[n] = item.displayName end
    end
  end
  cache.mode = "create"
  cache.totals = totals
  cache.display = display
  cache.invCount = 1
  cache.updated = os.epoch("utc")
  rebuildRows()
  return true
end

local function scanInventories()
  local names = listInventories()
  local totals, display = {}, {}
  for _, name in ipairs(names) do
    local inv = peripheral.wrap(name)
    if inv then
      local ok, list = pcall(inv.list)
      if ok and type(list) == "table" then
        for slot, item in pairs(list) do
          if type(item) == "table" and item.name then
            totals[item.name] = (totals[item.name] or 0) + (tonumber(item.count) or 0)
            if not display[item.name] and type(inv.getItemDetail) == "function" then
              local okd, det = pcall(inv.getItemDetail, slot)
              if okd and type(det) == "table" and det.displayName then
                display[item.name] = det.displayName
              end
            end
          end
        end
      end
    end
  end
  cache.mode = #names > 0 and "inventory" or "none"
  cache.totals = totals
  cache.display = display
  cache.invCount = #names
  cache.updated = os.epoch("utc")
  rebuildRows()
  return #names > 0
end

local function refresh()
  local name, ticker = findTicker()
  cache.tickerName = name
  if ticker then
    local ok, err = scanCreate(ticker)
    if ok then return true, "create" end
    print("Create ticker scan failed: " .. tostring(err))
  end
  if scanInventories() then return true, "inventory" end
  cache.mode = "none"
  cache.totals, cache.display, cache.items = {}, {}, {}
  cache.invCount = 0
  cache.updated = os.epoch("utc")
  return false, "none"
end

local function matchFilter(row, filter)
  if not filter or filter == "" then return true end
  local f = filter:lower()
  if row.name:lower():find(f, 1, true) then return true end
  if row.displayName and row.displayName:lower():find(f, 1, true) then return true end
  return false
end

local function filteredRows(filter, limit)
  local out = {}
  for _, row in ipairs(cache.items) do
    if matchFilter(row, filter) then
      out[#out + 1] = row
      if limit and #out >= limit then break end
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- Create request
--------------------------------------------------------------------------------
local function requestItems(itemQuery, count, address)
  local _, ticker = findTicker()
  if not ticker or type(ticker.requestFiltered) ~= "function" then
    return false, "no Create Stock Ticker (need Create_StockTicker peripheral)"
  end
  count = math.max(1, math.floor(tonumber(count) or 64))
  address = tostring(address or cfg.requestAddress or "StorageManager")

  -- Resolve query to a full item id when possible.
  local name = itemQuery
  local q = tostring(itemQuery or ""):lower()
  if not q:find(":", 1, true) then
    for _, row in ipairs(cache.items) do
      if row.name:lower() == q
         or shortName(row.name):lower() == q
         or (row.displayName and row.displayName:lower() == q)
         or row.name:lower():find(q, 1, true) then
        name = row.name
        break
      end
    end
  end

  local filter = {
    name = name,
    _requestCount = count,
  }
  -- If bare name didn't match a known id, try glob on display-ish query.
  if not tostring(name):find(":", 1, true) then
    filter = {
      _requestCount = count,
      name = { _op = "glob", value = "*" .. name .. "*" },
    }
  end

  local ok, n = pcall(ticker.requestFiltered, address, filter)
  if not ok then return false, tostring(n) end
  return true, tonumber(n) or 0, name, address
end

--------------------------------------------------------------------------------
-- Monitor
--------------------------------------------------------------------------------
local function drawMonitor()
  local out = monitor
  if not out then return end
  local w, h = out.getSize()
  out.setBackgroundColor(colors.black)
  out.clear()
  local function line(y, text, c)
    if y < 1 or y > h then return end
    out.setCursorPos(1, y)
    out.setTextColor(c or colors.white)
    out.write(tostring(text):sub(1, w))
  end

  local mode = cache.mode == "create" and "CREATE"
    or (cache.mode == "inventory" and "INV" or "NONE")
  local kinds = #cache.items
  local units = 0
  for _, r in ipairs(cache.items) do units = units + r.count end

  line(1, "== STORAGE MANAGER ==", colors.yellow)
  line(2, ("mode:%s  types:%d  items:%d"):format(mode, kinds, units), colors.lime)
  if cache.tickerName then
    local side = cache.tickerSide or cfg.tickerSide or "?"
    line(3, ("ticker %s @ %s"):format(tostring(side), tostring(cache.tickerName)):sub(1, w), colors.lightGray)
  else
    line(3, ("inventories: %d  (ticker side: %s)"):format(
      cache.invCount, tostring(cfg.tickerSide or "auto")), colors.lightGray)
  end
  line(4, "COUNT   ITEM", colors.gray)

  local y = 5
  for i, row in ipairs(cache.items) do
    if y > h - 1 then break end
    local label = (row.displayName or shortName(row.name)):sub(1, math.max(8, w - 8))
    line(y, ("%6d  %s"):format(row.count, label), colors.white)
    y = y + 1
    if i >= h - 5 then break end
  end
  if kinds == 0 then
    line(5, "(empty / no storage linked)", colors.orange)
    line(6, "Attach Create Stock Ticker", colors.gray)
    line(7, "or inventory peripherals.", colors.gray)
  elseif y <= h then
    line(h, "stock | find | request", colors.gray)
  end
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function printStock(filter, limit)
  limit = limit or 30
  local rows = filteredRows(filter, limit)
  local mode = cache.mode
  print(("Stock [%s]  %d type(s)%s"):format(
    mode, #cache.items,
    filter and ("  filter='" .. filter .. "'") or ""))
  if #rows == 0 then print("  (no matches)"); return end
  for _, row in ipairs(rows) do
    print(("  %6d  %-24s %s"):format(
      row.count, (row.displayName or shortName(row.name)):sub(1, 24), row.name))
  end
  if #cache.items > #rows and filter then
    print("  (showing matches only)")
  elseif #cache.items > limit then
    print(("  ... %d more — use find <item>"):format(#cache.items - limit))
  end
end

local function consoleLoop()
  print(("Titan StorageManager #%d. Type 'help'."):format(os.getComputerID()))
  local ok, mode = refresh()
  if ok then
    print(("Linked: %s  (%d item types)"):format(mode, #cache.items))
  else
    print("No Create ticker / inventories yet. Attach storage, then `refresh`.")
  end
  drawMonitor()

  while true do
    write("storage> ")
    local a = {}
    for w in tostring(read()):gmatch("%S+") do a[#a + 1] = w end
    local cmd = (a[1] or ""):lower()

    if cmd == "" then
    elseif cmd == "help" then
      print("status              link mode + counts")
      print("stock [filter]      list Create/inventory stock")
      print("find <item>         search by name / display name")
      print("request <item> [count] [address]")
      print("                    ask Create network to pack items")
      print("ticker [side]       set Stock Ticker direction")
      print("                    sides: front back left right up down")
      print("sides               show what is on each face")
      print("address [name]      default Create package address")
      print("invs                list tickers + inventories")
      print("refresh             rescan peripherals")
      print("hostname [name]     get/set label")
      print("exit")
    elseif cmd == "status" then
      refresh()
      print(("mode: %s"):format(cache.mode))
      print(("ticker side: %s"):format(tostring(cache.tickerSide or cfg.tickerSide or "auto")))
      print(("ticker: %s"):format(tostring(cache.tickerName or "(none)")))
      print(("inventories: %d"):format(cache.invCount))
      print(("item types: %d"):format(#cache.items))
      print(("request address: %s"):format(tostring(cfg.requestAddress)))
      drawMonitor()
    elseif cmd == "ticker" or cmd == "side" or cmd == "stockticker" then
      local dir = a[2]
      if not dir then
        print(("Configured ticker side: %s"):format(tostring(cfg.tickerSide or "(auto)")))
        print(("Active ticker: %s @ %s"):format(
          tostring(cache.tickerName or "(none)"),
          tostring(cache.tickerSide or "?")))
        print("Usage: ticker <front|back|left|right|up|down>")
        print("Example: ticker back")
      elseif dir:lower() == "auto" or dir:lower() == "clear" then
        cfg.tickerSide = nil
        saveCfg()
        refresh()
        print("Ticker side cleared (auto-detect).")
        drawMonitor()
      else
        local ok, sideOrErr, found = setTickerSide(dir)
        if not ok then
          print(tostring(sideOrErr))
        else
          refresh()
          if found then
            print(("Ticker side = %s  (found %s)"):format(sideOrErr, found))
          else
            print(("Ticker side = %s  (nothing there yet — place Stock Ticker on that face)"):format(sideOrErr))
          end
          drawMonitor()
        end
      end
    elseif cmd == "sides" or cmd == "faces" then
      print("Computer faces:")
      for _, row in ipairs(describeSides()) do
        print(("  %-6s  %-22s%s"):format(row.side, row.typ, row.mark))
      end
      print("Set with: ticker <side>   e.g. ticker back")
    elseif cmd == "stock" or cmd == "list" then
      refresh()
      printStock(a[2] and table.concat(a, " ", 2) or nil, 40)
      drawMonitor()
    elseif cmd == "find" or cmd == "search" then
      if not a[2] then print("Usage: find <item>")
      else
        refresh()
        printStock(table.concat(a, " ", 2), 50)
      end
    elseif cmd == "request" or cmd == "req" then
      if not a[2] then
        print("Usage: request <item> [count] [address]")
        print("Example: request minecraft:iron_ingot 128 DockA")
      else
        -- Parse: request <item words...> [count] [address]
        -- If a[3] is number, it's count; optional a[4] address.
        -- If item has no spaces: request iron_ingot 64
        local item, count, address
        if tonumber(a[3]) then
          item = a[2]
          count = tonumber(a[3])
          address = a[4]
        elseif a[#a] and tonumber(a[#a]) and #a >= 3 then
          count = tonumber(a[#a])
          item = table.concat(a, " ", 2, #a - 1)
        else
          item = table.concat(a, " ", 2)
          count = 64
        end
        refresh()
        local ok, nOrErr, resolved, addr = requestItems(item, count, address)
        if ok then
          print(("Requested %s x%s -> address '%s' (matched %s)"):format(
            tostring(resolved), tostring(count), tostring(addr), tostring(nOrErr)))
        else
          print("Request failed: " .. tostring(nOrErr))
        end
      end
    elseif cmd == "address" then
      if not a[2] then
        print("request address: " .. tostring(cfg.requestAddress))
        print("Usage: address <name>")
      else
        cfg.requestAddress = table.concat(a, " ", 2)
        saveCfg()
        print("request address set: " .. cfg.requestAddress)
      end
    elseif cmd == "invs" or cmd == "peripherals" then
      local tName = select(1, findTicker())
      print("Create Stock Ticker: " .. tostring(tName or "(none)"))
      local invs = listInventories()
      print(("Inventories (%d):"):format(#invs))
      for i, n in ipairs(invs) do
        print(("  %d) %s  [%s]"):format(i, n, tostring(peripheral.getType(n))))
      end
    elseif cmd == "refresh" or cmd == "scan" then
      local ok, mode = refresh()
      print(ok and ("Refreshed (%s), %d types."):format(mode, #cache.items)
        or "No storage found.")
      drawMonitor()
    elseif cmd == "hostname" or cmd == "host" then
      if not a[2] then
        print("hostname: " .. (os.getComputerLabel() or "?"))
      else
        local name, err = titan.setHostname(table.concat(a, " ", 2), "storage")
        if name then print("hostname set: " .. name) else print(tostring(err)) end
      end
    elseif cmd == "exit" or cmd == "quit" then
      return
    else
      print("Unknown: " .. cmd .. "  (type 'help')")
    end
  end
end

--------------------------------------------------------------------------------
-- Background loops
--------------------------------------------------------------------------------
local function refreshLoop()
  while true do
    refresh()
    drawMonitor()
    sleep(math.max(2, tonumber(cfg.refreshSecs) or 5))
  end
end

local function peripheralLoop()
  while true do
    local ev = os.pullEvent()
    if ev == "peripheral" or ev == "peripheral_detach" then
      monitor = peripheral.find("monitor")
      if monitor then pcall(function() monitor.setTextScale(0.5) end) end
      refresh()
      drawMonitor()
    end
  end
end

--------------------------------------------------------------------------------
parallel.waitForAny(
  consoleLoop,
  refreshLoop,
  peripheralLoop,
  function() titan.networkLoop("storage") end
)
print("StorageManager stopped.")
