--[[
  storage/managers/storage_atm.lua  -  Standalone Create storage ATM
  Titan-Version: 1.0.0

  Solo item ATM for a Create logistics network. No casino chips, no Currency
  Manager, no Titan mesh required.

  Hardware:
    - vanilla intake chest (frogport hauls deposits into the vault network)
    - Create Stock Ticker (withdraw requests)
    - Create frogport / package address for this ATM's output

  Deposit:
    Put items in the intake chest, run `deposit`, confirm. Items stay for the
    frogport — this PC does not move them (Create does).

  Withdraw:
    Looks up Create stock. Calls Stock Ticker requestFiltered ONLY if the
    network has enough of the requested item(s). Package goes to `address`.

  Setup:
    bind intake <side|name>
    address <packageAddress>
    deposit | withdraw | stock | status | help
]]

local LOCAL_CFG = "storage_atm.cfg"
local VERSION = "1.0.0"

local cfg = {
  intake = nil,
  address = nil,
  label = nil,
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

local function wrapIntake()
  local n = cfg.intake
  if not n or not isInventory(n) then return nil end
  return peripheral.wrap(n), n
end

local function findTicker()
  local t = peripheral.find("Create_StockTicker")
  if t then return t, "Create_StockTicker" end
  for _, name in ipairs(peripheral.getNames()) do
    local typ = tostring(peripheral.getType(name) or ""):lower()
    if typ:find("stockticker", 1, true) or typ:find("stock_ticker", 1, true) then
      return peripheral.wrap(name), name
    end
  end
  return nil
end

local function shortName(id)
  id = tostring(id or "")
  local bare = id:match("([^:]+)$") or id
  return bare
end

--------------------------------------------------------------------------------
-- Create stock helpers
--------------------------------------------------------------------------------
local function createStockList(ticker, detailed)
  local ok, stock
  if detailed then
    ok, stock = pcall(function() return ticker.stock(true) end)
  end
  if not ok or type(stock) ~= "table" then
    ok, stock = pcall(function() return ticker.stock() end)
  end
  if not ok or type(stock) ~= "table" then return {}, "stock() failed" end
  return stock, nil
end

local function createStockMap(ticker)
  local stock, err = createStockList(ticker, true)
  local map = {}
  for _, row in ipairs(stock) do
    if type(row) == "table" and row.name then
      map[row.name] = (map[row.name] or 0) + (tonumber(row.count) or 0)
    end
  end
  return map, err
end

local function matchStock(stockMap, query)
  query = tostring(query or ""):lower()
  if query == "" then return nil end
  if stockMap[query] then return query, stockMap[query] end
  -- exact bare name / substring
  local hits = {}
  for name, count in pairs(stockMap) do
    local low = name:lower()
    local bare = shortName(name):lower()
    if low == query or bare == query then
      return name, count
    end
    if low:find(query, 1, true) or bare:find(query, 1, true) then
      hits[#hits + 1] = { name = name, count = count }
    end
  end
  table.sort(hits, function(a, b) return a.name < b.name end)
  if #hits == 1 then return hits[1].name, hits[1].count end
  if #hits > 1 then return nil, hits end
  return nil, nil
end

local function requestItems(ticker, address, item, count)
  count = math.floor(tonumber(count) or 0)
  if count <= 0 then return false, "bad count" end
  local ok, n = pcall(function()
    return ticker.requestFiltered(address, {
      name = item,
      _requestCount = count,
    })
  end)
  if not ok then return false, tostring(n) end
  return true, tonumber(n) or 0
end

--------------------------------------------------------------------------------
-- Intake listing
--------------------------------------------------------------------------------
local function listIntake(inv)
  local list = inv.list() or {}
  local rows, total = {}, 0
  local slots = {}
  for slot in pairs(list) do slots[#slots + 1] = slot end
  table.sort(slots)
  for _, slot in ipairs(slots) do
    local d = list[slot]
    if type(d) == "table" and d.name then
      local c = tonumber(d.count) or 0
      if c > 0 then
        rows[#rows + 1] = { slot = slot, name = d.name, count = c }
        total = total + c
      end
    end
  end
  return rows, total
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function cmdBind(a)
  local name = a[2]
  if name and name:lower() == "intake" then name = a[3] end
  if not name then
    print("Usage: bind intake <peripheralName|side>")
    return
  end
  if not isInventory(name) then
    print("Not an inventory: " .. tostring(name))
    print("Use a vanilla chest/barrel touching this PC.")
    return
  end
  cfg.intake = name
  saveCfg()
  print("Intake = " .. name)
end

local function cmdAddress(a)
  local addr = a[2] and table.concat(a, " ", 2) or nil
  if not addr or addr == "" then
    print("Current address: " .. tostring(cfg.address or "(unset)"))
    print("Usage: address <createPackageAddress>")
    return
  end
  cfg.address = addr
  saveCfg()
  print("Package address = " .. addr)
end

local function cmdInvs()
  print("Inventories:")
  local any = false
  for _, n in ipairs(peripheral.getNames()) do
    if isInventory(n) then
      any = true
      local mark = (n == cfg.intake) and " [intake]" or ""
      print("  " .. n .. mark)
    end
  end
  if not any then print("  (none)") end
  local ticker, tname = findTicker()
  print("Stock Ticker: " .. (ticker and tostring(tname) or "NONE"))
end

local function cmdStatus()
  print("== Storage ATM v" .. VERSION .. " ==")
  print("Mode:    Create logistics only (no casino / mesh)")
  print("Intake:  " .. tostring(cfg.intake or "(unbound)"))
  print("Address: " .. tostring(cfg.address or "(unset)"))
  print("Ticker:  " .. (findTicker() and "OK" or "NONE"))
end

local function cmdStock(a)
  local ticker = findTicker()
  if not ticker then print("No Create Stock Ticker."); return end
  local filter = a[2] and table.concat(a, " ", 2):lower() or nil
  local stock, err = createStockList(ticker, true)
  if err and #stock == 0 then print(err); return end

  local rows = {}
  for _, row in ipairs(stock) do
    if type(row) == "table" and row.name then
      local name = row.name
      local disp = row.displayName or shortName(name)
      local count = tonumber(row.count) or 0
      if not filter or name:lower():find(filter, 1, true)
          or tostring(disp):lower():find(filter, 1, true) then
        rows[#rows + 1] = { name = name, disp = disp, count = count }
      end
    end
  end
  table.sort(rows, function(x, y)
    if x.count ~= y.count then return x.count > y.count end
    return x.name < y.name
  end)

  print(("Create stock%s:"):format(filter and (" filter=" .. filter) or ""))
  if #rows == 0 then print("  (none)"); return end
  local limit = math.min(#rows, 40)
  for i = 1, limit do
    local r = rows[i]
    print(("  %6d  %s"):format(r.count, r.disp))
    if r.disp ~= shortName(r.name) then
      print("         " .. r.name)
    end
  end
  if #rows > limit then
    print(("  … %d more (narrow with: stock <filter>)"):format(#rows - limit))
  end
end

local function cmdDeposit()
  local inv, iname = wrapIntake()
  if not inv then
    print("Bind intake first: bind intake <side|name>")
    return
  end
  local rows, total = listIntake(inv)
  if total <= 0 then
    print("Intake chest is empty.")
    print("Put items in the chest, then run deposit.")
    return
  end
  print(("Intake (%s) — %d item(s):"):format(iname, total))
  for _, r in ipairs(rows) do
    print(("  %dx %s"):format(r.count, r.name))
  end
  write("Confirm deposit for frogport haul? (y/N): ")
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then
    print("Cancelled — items left in chest.")
    return
  end
  print("Confirmed. Leave items in intake — Create frogport should haul to vault.")
  print("(This ATM does not move items; Create logistics does.)")
end

local function cmdWithdraw(a)
  local ticker = findTicker()
  if not ticker then print("No Create Stock Ticker."); return end
  if not cfg.address or cfg.address == "" then
    print("Set package address: address <name>")
    return
  end

  local itemQ = a[2]
  local count = tonumber(a[3])
  if not itemQ then
    write("Item name (or filter): ")
    itemQ = read()
  end
  if not itemQ or not tostring(itemQ):match("%S") then
    print("Cancelled."); return
  end
  if not count then
    write("Count: ")
    count = tonumber(read())
  end
  count = math.floor(tonumber(count) or 0)
  if count <= 0 then print("Need a positive count."); return end

  local stockMap, err = createStockMap(ticker)
  if err and not next(stockMap) then print(tostring(err)); return end

  local item, availOrHits = matchStock(stockMap, itemQ)
  if type(availOrHits) == "table" then
    print("Multiple matches — be more specific:")
    for i = 1, math.min(#availOrHits, 12) do
      local h = availOrHits[i]
      print(("  %6d  %s"):format(h.count, h.name))
    end
    return
  end
  if not item then
    print("Not in Create stock: " .. tostring(itemQ))
    print("Stock Ticker was NOT called.")
    return
  end
  local avail = tonumber(availOrHits) or 0
  if avail < count then
    print(("Not enough in Create stock (have %d, need %d)."):format(avail, count))
    print("Stock Ticker was NOT called.")
    return
  end

  print(("Request %dx %s → address '%s'"):format(count, item, cfg.address))
  write("Send package? (y/N): ")
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then
    print("Cancelled — ticker not called."); return
  end

  local ok, nOrErr = requestItems(ticker, cfg.address, item, count)
  if not ok then
    print("Ticker request failed: " .. tostring(nOrErr))
    return
  end
  print(("Requested (%s). Package should arrive at: %s"):format(
    tostring(nOrErr), cfg.address))
end

local function cmdHelp()
  print([[
Storage ATM — Create vault only (no casino).

bind intake <side|name>     frogport-watched deposit chest
address <createAddress>     package destination for withdraws
invs | status
stock [filter]              browse Create network stock
deposit                     confirm intake contents for frog haul
withdraw [item] [count]     request if stock has enough (else no ticker call)
help | exit
]])
end

--------------------------------------------------------------------------------
loadCfg()
os.setComputerLabel(cfg.label or os.getComputerLabel() or ("StorageATM-" .. os.getComputerID()))

term.clear(); term.setCursorPos(1, 1)
print("== Storage ATM v" .. VERSION .. " ==")
print("Create logistics only — no mesh / casino.")
if not cfg.intake then print("Bind intake: bind intake <side>") end
if not cfg.address then print("Set address: address <name>") end
if not findTicker() then print("Attach a Create Stock Ticker.") end
print("Type help.")
print("")

while true do
  write("satm> ")
  local line = read()
  if not line then break end
  local a = {}
  for w in line:gmatch("%S+") do a[#a + 1] = w end
  local cmd = tostring(a[1] or ""):lower()
  if cmd == "" then
  elseif cmd == "exit" or cmd == "quit" then break
  elseif cmd == "help" or cmd == "?" then cmdHelp()
  elseif cmd == "bind" then cmdBind(a)
  elseif cmd == "address" or cmd == "addr" then cmdAddress(a)
  elseif cmd == "invs" then cmdInvs()
  elseif cmd == "status" then cmdStatus()
  elseif cmd == "stock" or cmd == "list" then cmdStock(a)
  elseif cmd == "deposit" or cmd == "dep" then cmdDeposit()
  elseif cmd == "withdraw" or cmd == "wd" or cmd == "get" then cmdWithdraw(a)
  else
    print("Unknown. help")
  end
end
