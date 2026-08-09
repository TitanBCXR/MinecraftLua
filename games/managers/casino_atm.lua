--[[
  games/managers/casino_atm.lua  -  Casino ATM (Create Stock Ticker)
  Titan-Version: 1.0.0

  Player-facing deposit / withdraw. Currency Manager holds the ledger on the mesh.

  Hardware:
    - wireless modem (mesh → Currency Manager)
    - Advanced Peripherals Player Detector
    - vanilla intake chest (frogport pulls after a confirmed deposit)
    - Create Stock Ticker (withdraw requests only)

  Deposit:
    Player puts tender in the intake chest, then chooses Deposit. Only then are
    chips credited. Items stay in the chest for the Create frogport → vault.

  Withdraw:
    Checks player chips + Create network stock. Only if both cover the amount
    does it call Stock Ticker requestFiltered(address, …) and debit chips.
    Packages go to this ATM's Create address (frogport / output).

  Setup:
    bind intake <side|name>
    address <packageAddress>
    Then: deposit | withdraw | bal | status | help
]]

local PROTO = "titan_install"
local ROUTER = "titan_router"
local LOCAL_CFG = "casino_atm.cfg"
local PLAYER_RANGE = 8
local VERSION = "1.0.0"

local cfg = {
  intake = nil,
  address = nil, -- Create package address for this ATM's output
  label = nil,
}

local managerId = nil
local rates = {}     -- item -> chips
local accepted = {}  -- list

--------------------------------------------------------------------------------
local function openModem()
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

local function normalizePlayer(p)
  if type(p) == "string" then
    p = p:gsub("[%c%z]", ""):match("^%s*(.-)%s*$") or ""
    if p == "" then return nil end
    return p:sub(1, 24)
  end
  if type(p) == "table" then
    return normalizePlayer(p.name or p.displayName or p.username)
  end
  return nil
end

local function findDetector()
  return peripheral.find("playerDetector") or peripheral.find("player_detector")
end

local function listNearbyPlayers(range)
  range = tonumber(range) or PLAYER_RANGE
  local pd = findDetector()
  if not pd then return {}, "no detector" end
  local names, seen = {}, {}
  local ok, players = pcall(function() return pd.getPlayersInRange(range) end)
  if ok and type(players) == "table" then
    for _, p in ipairs(players) do
      local n = normalizePlayer(p)
      if n and not seen[n:lower()] then
        seen[n:lower()] = true
        names[#names + 1] = n
      end
    end
  end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  return names, nil
end

local function pickPlayer(arg)
  local nearby = listNearbyPlayers(PLAYER_RANGE)
  local asNum = tonumber(arg)
  if arg and asNum and nearby[asNum] then return nearby[asNum] end
  if arg and tostring(arg):match("%S") then
    local want = normalizePlayer(arg)
    if want then return want end
  end
  if #nearby == 0 then
    print(findDetector() and "No players nearby." or "No Player Detector.")
    write("Player name (blank cancel): ")
    return normalizePlayer(read())
  end
  print("Nearby players:")
  for i, n in ipairs(nearby) do print(("  %d) %s"):format(i, n)) end
  write(#nearby == 1 and ("Select [1]: ") or "Select # or name: ")
  local line = read()
  if (not line or not line:match("%S")) and #nearby == 1 then return nearby[1] end
  local n = tonumber(line)
  if n and nearby[n] then return nearby[n] end
  return normalizePlayer(line)
end

--------------------------------------------------------------------------------
-- Mesh → Currency Manager
--------------------------------------------------------------------------------
local function discover(timeout)
  timeout = timeout or 2
  openModem()
  rednet.broadcast({ type = "casino_ping", from = os.getComputerID() }, PROTO)
  rednet.broadcast({ type = "casino_ping", from = os.getComputerID() }, ROUTER)
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg = rednet.receive(nil, math.max(0.05, deadline - os.clock()))
    if id and type(msg) == "table" and msg.type == "casino_hello" then
      managerId = id
      return id
    end
  end
  return managerId
end

local function req(msgType, fields, expect, timeout)
  timeout = timeout or 4
  if not managerId then discover(1.5) end
  if not managerId then return nil, "no currency manager" end
  local payload = {
    type = msgType,
    from = os.getComputerID(),
    replyTo = os.getComputerID(),
  }
  if type(fields) == "table" then
    for k, v in pairs(fields) do payload[k] = v end
  end
  rednet.send(managerId, payload, PROTO)
  rednet.send(managerId, payload, ROUTER)
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg = rednet.receive(nil, math.max(0.05, deadline - os.clock()))
    if id == managerId and type(msg) == "table" and msg.type == expect then
      return msg
    end
  end
  return nil, "timeout"
end

local function fetchRates()
  local msg, err = req("casino_rates_req", nil, "casino_rates", 3)
  if not msg or not msg.ok then return false, err or "rates failed" end
  rates = type(msg.rates) == "table" and msg.rates or {}
  accepted = type(msg.accepted) == "table" and msg.accepted or {}
  return true
end

local function fetchBalance(player)
  local msg, err = req("casino_balance_req", { player = player }, "casino_balance", 3)
  if not msg then return nil, err end
  return tonumber(msg.chips) or 0
end

local function creditPlayer(player, amount)
  local msg, err = req("casino_credit", {
    player = player, amount = amount,
  }, "casino_ack", 4)
  if not msg then return false, err end
  if not msg.ok then return false, msg.err or "denied" end
  return true, tonumber(msg.chips) or 0
end

local function debitPlayer(player, amount)
  local msg, err = req("casino_bet", {
    player = player, amount = amount,
  }, "casino_ack", 4)
  if not msg then return false, err end
  if not msg.ok then return false, msg.err or "denied" end
  return true, tonumber(msg.chips) or 0
end

--------------------------------------------------------------------------------
-- Intake / Create stock
--------------------------------------------------------------------------------
local function acceptedSet()
  local s = {}
  for _, n in ipairs(accepted) do s[n] = true end
  for item, rate in pairs(rates) do
    if (tonumber(rate) or 0) > 0 then s[item] = true end
  end
  return s
end

local function scanIntakeValue(inv)
  local accept = acceptedSet()
  local byItem, value, totalCount = {}, 0, 0
  local list = inv.list() or {}
  for _, detail in pairs(list) do
    if type(detail) == "table" and detail.name then
      local c = tonumber(detail.count) or 0
      local rate = tonumber(rates[detail.name]) or 0
      if c > 0 and accept[detail.name] and rate > 0 then
        byItem[detail.name] = (byItem[detail.name] or 0) + c
        value = value + rate * c
        totalCount = totalCount + c
      end
    end
  end
  return byItem, value, totalCount
end

local function createStockMap(ticker)
  local map = {}
  local ok, stock = pcall(function() return ticker.stock(true) end)
  if not ok or type(stock) ~= "table" then
    ok, stock = pcall(function() return ticker.stock() end)
  end
  if not ok or type(stock) ~= "table" then return map, "stock() failed" end
  for _, row in ipairs(stock) do
    if type(row) == "table" and row.name then
      map[row.name] = (map[row.name] or 0) + (tonumber(row.count) or 0)
    end
  end
  return map, nil
end

local function planWithdraw(amount, stockMap)
  local denoms = {}
  for item, rate in pairs(rates) do
    rate = tonumber(rate) or 0
    if rate > 0 then
      denoms[#denoms + 1] = { item = item, rate = rate }
    end
  end
  table.sort(denoms, function(a, b)
    if a.rate ~= b.rate then return a.rate > b.rate end
    return a.item < b.item
  end)

  local plan, left = {}, amount
  local avail = {}
  for k, v in pairs(stockMap) do avail[k] = v end

  for _, d in ipairs(denoms) do
    if left <= 0 then break end
    local maxTake = math.min(math.floor(left / d.rate), avail[d.item] or 0)
    if maxTake > 0 then
      plan[d.item] = maxTake
      avail[d.item] = (avail[d.item] or 0) - maxTake
      left = left - maxTake * d.rate
    end
  end
  return plan, left
end

local function requestFromTicker(ticker, address, plan)
  local filters = {}
  for item, count in pairs(plan) do
    filters[#filters + 1] = { name = item, _requestCount = count }
  end
  if #filters == 0 then return false, "empty plan" end
  local ok, n = pcall(function()
    return ticker.requestFiltered(address, table.unpack(filters))
  end)
  if not ok then return false, tostring(n) end
  return true, tonumber(n) or 0
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function cmdBind(a)
  local name = a[2]
  if not name then
    print("Usage: bind intake <peripheralName|side>")
    return
  end
  -- allow "bind intake left" or "bind left"
  if name:lower() == "intake" then name = a[3] end
  if not name then print("Usage: bind intake <name|side>"); return end
  if not isInventory(name) then
    print("Not an inventory: " .. tostring(name)); return
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
  if not any then print("  (none — use a vanilla chest touching this PC)") end
  local ticker, tname = findTicker()
  print("Stock Ticker: " .. (ticker and tostring(tname) or "NONE"))
  print("Detector: " .. (findDetector() and "OK" or "NONE"))
end

local function cmdStatus()
  print("== Casino ATM v" .. VERSION .. " ==")
  print("Intake:  " .. tostring(cfg.intake or "(unbound)"))
  print("Address: " .. tostring(cfg.address or "(unset)"))
  print("Manager: " .. tostring(managerId or "(not found)"))
  print("Ticker:  " .. (findTicker() and "OK" or "NONE"))
  print("Detect:  " .. (findDetector() and "OK" or "NONE"))
  print("Rates:   " .. tostring(#accepted) .. " accepted type(s)")
end

local function cmdBal(a)
  if not fetchRates() then print("Need Currency Manager online."); return end
  local player = pickPlayer(a[2])
  if not player then return end
  local bal, err = fetchBalance(player)
  if bal == nil then print("Balance failed: " .. tostring(err)); return end
  print(("%s: %d chips"):format(player, bal))
end

local function cmdDeposit(a)
  if not fetchRates() then print("Need Currency Manager online (rates)."); return end
  if not next(rates) then print("Manager has no rates — scan/rates on manager first."); return end
  local inv, iname = wrapIntake()
  if not inv then print("Bind intake: bind intake <side|name>"); return end

  local player = pickPlayer(a[2])
  if not player then return end

  local byItem, value, totalCount = scanIntakeValue(inv)
  if value <= 0 then
    print("No accepted currency in intake chest.")
    print("Put coins in the chest, then run deposit again.")
    return
  end

  print(("Player: %s"):format(player))
  print("Intake contents (will credit ONLY if you confirm):")
  for item, c in pairs(byItem) do
    local rate = tonumber(rates[item]) or 0
    print(("  %dx %s  = %d chips"):format(c, item, rate * c))
  end
  print(("Total: %d chips (%d items)"):format(value, totalCount))
  write("Deposit and credit chips? (y/N): ")
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then
    print("Cancelled — no credit. Items left in chest.")
    return
  end

  local ok, chipsOrErr = creditPlayer(player, value)
  if not ok then
    print("Credit failed: " .. tostring(chipsOrErr))
    print("Items left in chest (not taken).")
    return
  end
  print(("Credited %s +%d chips. Balance=%d"):format(player, value, chipsOrErr))
  print("Leave items in intake — Create frogport should haul them to the vault.")
end

local function cmdWithdraw(a)
  if not fetchRates() then print("Need Currency Manager online (rates)."); return end
  if not next(rates) then print("Manager has no rates yet."); return end
  if not cfg.address or cfg.address == "" then
    print("Set Create package address: address <name>"); return
  end
  local ticker = findTicker()
  if not ticker then
    print("No Create Stock Ticker peripheral on this PC."); return
  end

  local player = pickPlayer(a[2])
  if not player then return end

  local amount = tonumber(a[3])
  if not amount then
    write("Chips to withdraw: ")
    amount = tonumber(read())
  end
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then print("Need a positive chip amount."); return end

  local bal, err = fetchBalance(player)
  if bal == nil then print("Balance failed: " .. tostring(err)); return end
  if bal < amount then
    print(("Insufficient chips (have %d, need %d)."):format(bal, amount))
    return
  end

  local stockMap, stockErr = createStockMap(ticker)
  if stockErr and not next(stockMap) then
    print("Create stock read failed: " .. tostring(stockErr)); return
  end

  -- Network vault value for accepted currency
  local netValue = 0
  for item, rate in pairs(rates) do
    rate = tonumber(rate) or 0
    if rate > 0 then netValue = netValue + rate * (stockMap[item] or 0) end
  end
  if netValue < amount then
    print(("Not enough in Create stock (have %d chips worth, need %d)."):format(
      netValue, amount))
    print("Stock Ticker was NOT called.")
    return
  end

  local plan, leftover = planWithdraw(amount, stockMap)
  if leftover > 0 then
    print(("Cannot make exact %d from network stock (short %d)."):format(
      amount, leftover))
    print("Stock Ticker was NOT called.")
    return
  end

  print("Request plan (Create Stock Ticker):")
  for item, c in pairs(plan) do
    print(("  %dx %s"):format(c, item))
  end
  write(("Send package to '%s' and debit %d? (y/N): "):format(cfg.address, amount))
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then
    print("Cancelled — ticker not called."); return
  end

  local okReq, nOrErr = requestFromTicker(ticker, cfg.address, plan)
  if not okReq then
    print("Ticker request failed: " .. tostring(nOrErr))
    print("No chips debited.")
    return
  end
  print(("Ticker accepted request (%s items flagged)."):format(tostring(nOrErr)))

  local okDebit, chipsOrErr = debitPlayer(player, amount)
  if not okDebit then
    print("WARNING: package requested but debit failed: " .. tostring(chipsOrErr))
    print("Check Currency Manager / player balance manually.")
    return
  end
  print(("Withdrew %d for %s. Balance=%d"):format(amount, player, chipsOrErr))
  print("Package should arrive at Create address: " .. cfg.address)
end

local function cmdHelp()
  print([[
Casino ATM — deposit only credits after you confirm.

bind intake <side|name>   frogport-watched chest
address <createAddress>   package destination for withdraws
invs | status | bal
deposit [player|#]        confirm chest → credit chips (items stay for frog)
withdraw [player|#] [n]   if chips+Create stock OK → Stock Ticker request
help | exit
]])
end

--------------------------------------------------------------------------------
loadCfg()
openModem()
discover(2)
fetchRates()
os.setComputerLabel(cfg.label or os.getComputerLabel() or ("ATM-" .. os.getComputerID()))

term.clear(); term.setCursorPos(1, 1)
print("== Casino ATM v" .. VERSION .. " ==")
print("Manager: " .. tostring(managerId or "NOT FOUND"))
if not cfg.intake then print("Bind intake chest: bind intake <side>") end
if not cfg.address then print("Set withdraw address: address <name>") end
print("Type help.")
print("")

while true do
  write("atm> ")
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
  elseif cmd == "bal" or cmd == "balance" then cmdBal(a)
  elseif cmd == "deposit" or cmd == "dep" then cmdDeposit(a)
  elseif cmd == "withdraw" or cmd == "wd" then cmdWithdraw(a)
  elseif cmd == "rates" or cmd == "reload" then
    local ok, err = fetchRates()
    print(ok and ("Rates loaded (" .. #accepted .. " types).") or ("Fail: " .. tostring(err)))
    if not managerId then discover(2) end
  else
    print("Unknown. help")
  end
end
