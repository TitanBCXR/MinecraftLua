--[[
  games/managers/casino_atm.lua  -  Casino station ATM (barrel model)
  Titan-Version: 1.1.0

  Thin client for Currency Manager. Each station PC talks to the manager over
  the mesh; physical input/output barrels are wired to the manager and mapped
  to this computer's ID.

  Hardware (station PC):
    - wireless modem
    - Advanced Peripherals Player Detector (recommended)

  Hardware (manager PC — see currency_manager.lua):
    - vault inventory (storage)
    - per-station input + output barrels:
        bind station <thisComputerId> input <barrel> output <barrel>

  Deposit:
    Player puts coins in this station's INPUT barrel (on manager), then at this
    PC: deposit → pick/name player → manager moves items to vault and credits.

  Withdraw:
    withdraw → amount → manager debits chips and pays coins to this station's
    OUTPUT barrel.

  Legacy Create Stock Ticker mode (optional):
    mode create
    bind intake <chest> ; address <createPackageAddress>
    (same as v1.0 — frogport intake + ticker withdraw)

  Setup:
    status          -- shows this PC id + manager binding
    deposit | withdraw | bal | help
]]

local PROTO = "titan_install"
local ROUTER = "titan_router"
local LOCAL_CFG = "casino_atm.cfg"
local PLAYER_RANGE = 8
local VERSION = "1.1.0"

local cfg = {
  mode = "barrel", -- "barrel" | "create"
  intake = nil,
  address = nil,
  label = nil,
}

local managerId = nil
local stationBinding = nil -- { input, output } from manager

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
  local m = tostring(cfg.mode or "barrel"):lower()
  if m == "create" or m == "ticker" then cfg.mode = "create" else cfg.mode = "barrel" end
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
    stationId = os.getComputerID(),
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

local function fetchStationBinding()
  local msg, err = req("casino_stations_req", nil, "casino_stations", 3)
  if not msg or not msg.ok then return nil, err or "stations failed" end
  local myId = os.getComputerID()
  for _, row in ipairs(msg.stations or {}) do
    if tonumber(row.stationId) == myId then
      stationBinding = { input = row.input, output = row.output }
      return stationBinding
    end
  end
  stationBinding = nil
  return nil, "no binding for this PC (#" .. myId .. ")"
end

local function fetchBalance(player)
  local msg, err = req("casino_balance_req", { player = player }, "casino_balance", 3)
  if not msg then return nil, err end
  return tonumber(msg.chips) or 0
end

--------------------------------------------------------------------------------
-- Barrel mode (default)
--------------------------------------------------------------------------------
local function cmdDepositBarrel(a)
  if not managerId then discover(2) end
  if not managerId then print("Need Currency Manager online."); return end
  local bind, berr = fetchStationBinding()
  if not bind then
    print("Station not bound on manager: " .. tostring(berr))
    print(("On manager: bind station %d input <barrel> output <barrel>"):format(
      os.getComputerID()))
    return
  end

  local player = pickPlayer(a[2])
  if not player then return end

  print(("Player: %s"):format(player))
  print(("Put coins in INPUT barrel (%s) on the manager, then confirm."):format(
    tostring(bind.input)))
  write("Process deposit and credit chips? (y/N): ")
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then
    print("Cancelled — nothing credited.")
    return
  end

  local msg, err = req("casino_station_deposit", { player = player }, "casino_ack", 8)
  if not msg then print("Deposit failed: " .. tostring(err)); return end
  if not msg.ok then
    print("Deposit denied: " .. tostring(msg.err or "?"))
    return
  end
  print(("Credited %s +%d chips. Balance=%d"):format(
    player, tonumber(msg.amount) or 0, tonumber(msg.chips) or 0))
end

local function cmdWithdrawBarrel(a)
  if not managerId then discover(2) end
  if not managerId then print("Need Currency Manager online."); return end
  local bind, berr = fetchStationBinding()
  if not bind then
    print("Station not bound: " .. tostring(berr))
    return
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

  write(("Withdraw %d chips to OUTPUT barrel (%s)? (y/N): "):format(
    amount, tostring(bind.output)))
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then print("Cancelled."); return end

  local msg, werr = req("casino_station_withdraw", {
    player = player, amount = amount,
  }, "casino_ack", 12)
  if not msg then print("Withdraw failed: " .. tostring(werr)); return end
  if not msg.ok then
    print("Withdraw denied: " .. tostring(msg.err or "?"))
    if msg.chips then print(("Balance=%d"):format(tonumber(msg.chips) or 0)) end
    return
  end
  print(("Withdrew %d for %s (%d items → %s). Balance=%d"):format(
    tonumber(msg.amount) or 0, player, tonumber(msg.totalItems) or 0,
    tostring(bind.output), tonumber(msg.chips) or 0))
end

--------------------------------------------------------------------------------
-- Legacy Create mode
--------------------------------------------------------------------------------
local rates = {}
local accepted = {}

local function fetchRates()
  local msg, err = req("casino_rates_req", nil, "casino_rates", 3)
  if not msg or not msg.ok then return false, err or "rates failed" end
  rates = type(msg.rates) == "table" and msg.rates or {}
  accepted = type(msg.accepted) == "table" and msg.accepted or {}
  return true
end

local function creditPlayer(player, amount)
  local msg, err = req("casino_credit", { player = player, amount = amount }, "casino_ack", 4)
  if not msg then return false, err end
  if not msg.ok then return false, msg.err or "denied" end
  return true, tonumber(msg.chips) or 0
end

local function debitPlayer(player, amount)
  local msg, err = req("casino_bet", { player = player, amount = amount }, "casino_ack", 4)
  if not msg then return false, err end
  if not msg.ok then return false, msg.err or "denied" end
  return true, tonumber(msg.chips) or 0
end

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

local function cmdDepositCreate(a)
  if not fetchRates() then print("Need Currency Manager online (rates)."); return end
  local inv, iname = wrapIntake()
  if not inv then print("Bind intake: bind intake <side|name>"); return end
  local player = pickPlayer(a[2])
  if not player then return end
  local byItem, value, totalCount = scanIntakeValue(inv)
  if value <= 0 then
    print("No accepted currency in intake chest.")
    return
  end
  print(("Player: %s"):format(player))
  for item, c in pairs(byItem) do
    print(("  %dx %s  = %d chips"):format(c, item, (tonumber(rates[item]) or 0) * c))
  end
  print(("Total: %d chips (%d items)"):format(value, totalCount))
  write("Deposit and credit chips? (y/N): ")
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then print("Cancelled."); return end
  local ok, chipsOrErr = creditPlayer(player, value)
  if not ok then print("Credit failed: " .. tostring(chipsOrErr)); return end
  print(("Credited %s +%d chips. Balance=%d"):format(player, value, chipsOrErr))
end

local function cmdWithdrawCreate(a)
  if not fetchRates() then print("Need Currency Manager online."); return end
  if not cfg.address or cfg.address == "" then
    print("Set Create package address: address <name>"); return
  end
  local ticker = findTicker()
  if not ticker then print("No Create Stock Ticker on this PC."); return end
  local player = pickPlayer(a[2])
  if not player then return end
  local amount = tonumber(a[3])
  if not amount then write("Chips to withdraw: "); amount = tonumber(read()) end
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then print("Need positive chips."); return end
  local bal, err = fetchBalance(player)
  if bal == nil then print("Balance failed: " .. tostring(err)); return end
  if bal < amount then
    print(("Insufficient chips (have %d, need %d)."):format(bal, amount)); return
  end
  local stockMap, stockErr = createStockMap(ticker)
  if stockErr and not next(stockMap) then
    print("Create stock read failed: " .. tostring(stockErr)); return
  end
  local netValue = 0
  for item, rate in pairs(rates) do
    rate = tonumber(rate) or 0
    if rate > 0 then netValue = netValue + rate * (stockMap[item] or 0) end
  end
  if netValue < amount then
    print(("Not enough Create stock (%d chips worth, need %d)."):format(netValue, amount))
    return
  end
  local plan, leftover = planWithdraw(amount, stockMap)
  if leftover > 0 then
    print(("Cannot make exact %d from network stock (short %d)."):format(amount, leftover))
    return
  end
  write(("Send package to '%s' and debit %d? (y/N): "):format(cfg.address, amount))
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then print("Cancelled."); return end
  local okReq, nOrErr = requestFromTicker(ticker, cfg.address, plan)
  if not okReq then print("Ticker failed: " .. tostring(nOrErr)); return end
  local okDebit, chipsOrErr = debitPlayer(player, amount)
  if not okDebit then
    print("WARNING: package requested but debit failed: " .. tostring(chipsOrErr))
    return
  end
  print(("Withdrew %d for %s. Balance=%d"):format(amount, player, chipsOrErr))
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function cmdBind(a)
  local name = a[2]
  if not name then print("Usage: bind intake <peripheralName|side>"); return end
  if name:lower() == "intake" then name = a[3] end
  if not name then print("Usage: bind intake <name|side>"); return end
  if not isInventory(name) then print("Not an inventory: " .. tostring(name)); return end
  cfg.intake = name
  saveCfg()
  print("Intake = " .. name)
end

local function cmdAddress(a)
  local addr = a[2] and table.concat(a, " ", 2) or nil
  if not addr or addr == "" then
    print("Current address: " .. tostring(cfg.address or "(unset)"))
    return
  end
  cfg.address = addr
  saveCfg()
  print("Package address = " .. addr)
end

local function cmdMode(a)
  local m = tostring(a[2] or ""):lower()
  if m == "create" or m == "ticker" then
    cfg.mode = "create"
    saveCfg()
    print("Mode = create (Stock Ticker legacy)")
  elseif m == "barrel" or m == "station" or m == "" then
    cfg.mode = "barrel"
    saveCfg()
    print("Mode = barrel (manager vault + station I/O)")
  else
    print("Usage: mode barrel|create")
  end
end

local function cmdStatus()
  print("== Casino ATM v" .. VERSION .. " ==")
  print("Mode:    " .. tostring(cfg.mode or "barrel"))
  print("This PC: #" .. os.getComputerID())
  print("Manager: " .. tostring(managerId or "(not found)"))
  print("Detect:  " .. (findDetector() and "OK" or "NONE"))
  if cfg.mode == "create" then
    print("Intake:  " .. tostring(cfg.intake or "(unbound)"))
    print("Address: " .. tostring(cfg.address or "(unset)"))
    print("Ticker:  " .. (findTicker() and "OK" or "NONE"))
  else
    fetchStationBinding()
    if stationBinding then
      print(("Station binding: in=%s  out=%s"):format(
        tostring(stationBinding.input), tostring(stationBinding.output)))
    else
      print("Station binding: NOT FOUND on manager")
      print(("  bind station %d input <barrel> output <barrel>"):format(
        os.getComputerID()))
    end
  end
end

local function cmdBal(a)
  if not managerId then discover(2) end
  if not managerId then print("Need Currency Manager online."); return end
  local player = pickPlayer(a[2])
  if not player then return end
  local bal, err = fetchBalance(player)
  if bal == nil then print("Balance failed: " .. tostring(err)); return end
  print(("%s: %d chips"):format(player, bal))
end

local function cmdDeposit(a)
  if cfg.mode == "create" then cmdDepositCreate(a) else cmdDepositBarrel(a) end
end

local function cmdWithdraw(a)
  if cfg.mode == "create" then cmdWithdrawCreate(a) else cmdWithdrawBarrel(a) end
end

local function cmdHelp()
  print([[
Casino station ATM — default barrel mode (manager vault + station barrels).

mode barrel|create          barrel = manager I/O (default)
status                      shows this PC id + manager binding
deposit [player|#]          put coins in station INPUT barrel first
withdraw [player|#] [n]     pays to station OUTPUT barrel
bal [player|#]

Create legacy (mode create):
  bind intake <side|name>   address <createAddress>
help | exit
]])
end

--------------------------------------------------------------------------------
loadCfg()
openModem()
discover(2)
if cfg.mode == "create" then fetchRates() end
os.setComputerLabel(cfg.label or os.getComputerLabel() or ("ATM-" .. os.getComputerID()))

term.clear(); term.setCursorPos(1, 1)
print("== Casino ATM v" .. VERSION .. " ==")
print("Station #" .. os.getComputerID() .. "  mode=" .. tostring(cfg.mode or "barrel"))
print("Manager: " .. tostring(managerId or "NOT FOUND"))
if cfg.mode ~= "create" then
  print("Bind on manager: bind station " .. os.getComputerID() .. " input … output …")
end
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
  elseif cmd == "mode" then cmdMode(a)
  elseif cmd == "bind" then cmdBind(a)
  elseif cmd == "address" or cmd == "addr" then cmdAddress(a)
  elseif cmd == "status" then cmdStatus()
  elseif cmd == "bal" or cmd == "balance" then cmdBal(a)
  elseif cmd == "deposit" or cmd == "dep" then cmdDeposit(a)
  elseif cmd == "withdraw" or cmd == "wd" then cmdWithdraw(a)
  elseif cmd == "reload" then
    discover(2)
    if cfg.mode == "create" then
      local ok, err = fetchRates()
      print(ok and "Rates loaded." or ("Fail: " .. tostring(err)))
    else
      local ok, err = fetchStationBinding()
      print(ok and "Station binding OK." or ("Fail: " .. tostring(err)))
    end
  else
    print("Unknown. help")
  end
end
