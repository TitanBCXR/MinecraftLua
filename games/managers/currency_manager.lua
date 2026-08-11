--[[
  games/managers/currency_manager.lua  -  Casino currency vault
  Titan-Version: 1.1.1

  Ledger / admin for casino chips. Persists accepted items, rates, balances,
  and password on floppy (casino_currency.cfg).

  Vault + dual-barrel stations (wired to this PC, mapped by station computer ID):
    bind storage <vault>                    -- coin vault (AE/RS/chest/vault)
    bind station <id> input <in> output <out>

  Players use casino_atm.lua at each station PC (thin client over mesh).
  Admin tablet uses Parent Center master password for remote withdraw / rates.

  Layout:
    [Vault] <--wired-- [Currency Manager PC] --wired--> [station input/output barrels]
            | disk + wireless mesh
            +-- games (bet/payout)
            +-- station ATMs (deposit / withdraw)
            +-- admin tablet (admin withdraw / rates / scan / bind)

  Rednet:
    casino_ping / casino_hello
    casino_balance_req / casino_balance
    casino_rates_req / casino_rates
    casino_credit / casino_bet / casino_payout + casino_ack
    casino_station_deposit / casino_station_withdraw + ack
    casino_stations_req / casino_stations
    casino_bind_station + ack            (password: floppy or Parent Center)
    casino_admin_withdraw / scan / rate / rates + ack
    casino_ledger_req / casino_ledger          (admin snapshot, password)
]]

local titan = nil
if fs.exists("lib/titan.lua") then
  local ok, t = pcall(dofile, "lib/titan.lua")
  if ok then titan = t end
end

local PROTO = "titan_install"
local ROUTER_PROTOCOL = "titan_router"
local DISK_FILE = "casino_currency.cfg"
local LOCAL_CFG = "currency_manager.cfg"
local SESSION_MS = 5 * 60 * 1000
local PLAYER_RANGE = 8
local VERSION = "1.1.1"
local MON_REFRESH_SEC = 5
local NATIVE_TERM = term.current()

local cfg = {
  storage = nil, deposit = nil, chest = nil, drive = nil, label = nil,
  stations = {}, -- [computerId] = { input = peripheralName, output = peripheralName }
}
local data = {
  accepted = {}, -- list of item names
  rates = {},    -- item -> chips
  balances = {}, -- player -> chips
  password = nil,
}
local sessionUntil = 0
local diskMount = nil

--------------------------------------------------------------------------------
local function now() return os.epoch("utc") end

local function markLedgerDirty()
  pcall(os.queueEvent, "casino_ledger_dirty")
end

local function openModem()
  if titan and titan.openModem then pcall(titan.openModem) end
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

local function loadLocal()
  if not fs.exists(LOCAL_CFG) then return end
  local f = fs.open(LOCAL_CFG, "r")
  if not f then return end
  local ok, d = pcall(textutils.unserialize, f.readAll())
  f.close()
  if ok and type(d) == "table" then
    for k, v in pairs(d) do cfg[k] = v end
  end
  if type(cfg.stations) ~= "table" then cfg.stations = {} end
  -- Legacy: single `chest` becomes storage vault.
  if (not cfg.storage or cfg.storage == "") and cfg.chest and cfg.chest ~= "" then
    cfg.storage = cfg.chest
  end
end

local function saveLocal()
  local f = fs.open(LOCAL_CFG, "w")
  if f then f.write(textutils.serialize(cfg)); f.close() end
end

local function findDiskMount()
  if cfg.drive and peripheral.isPresent(cfg.drive) then
    local d = peripheral.wrap(cfg.drive)
    if d and d.isDiskPresent and d.isDiskPresent() then
      local m = d.getMountPath and d.getMountPath()
      if m and m ~= "" then return m, cfg.drive end
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
      local d = peripheral.wrap(name)
      if d and d.isDiskPresent and d.isDiskPresent() then
        local m = d.getMountPath and d.getMountPath()
        if m and m ~= "" then return m, name end
      end
    end
  end
  return nil, nil
end

local function diskPath()
  diskMount = select(1, findDiskMount())
  if not diskMount then return nil end
  return fs.combine(diskMount, DISK_FILE)
end

local function loadDisk()
  local path = diskPath()
  if not path or not fs.exists(path) then return false, "no floppy cfg" end
  local f = fs.open(path, "r")
  if not f then return false, "open failed" end
  local ok, d = pcall(textutils.unserialize, f.readAll())
  f.close()
  if not ok or type(d) ~= "table" then return false, "bad cfg" end
  data.accepted = type(d.accepted) == "table" and d.accepted or {}
  data.rates = type(d.rates) == "table" and d.rates or {}
  data.balances = type(d.balances) == "table" and d.balances or {}
  data.password = d.password
  return true
end

local function saveDisk()
  local path = diskPath()
  if not path then return false, "insert floppy in disk drive" end
  local f = fs.open(path, "w")
  if not f then return false, "open failed" end
  f.write(textutils.serialize({
    accepted = data.accepted,
    rates = data.rates,
    balances = data.balances,
    password = data.password,
    version = VERSION,
  }))
  f.close()
  local _, driveName = findDiskMount()
  if driveName then
    pcall(function()
      local d = peripheral.wrap(driveName)
      if d and d.setDiskLabel then
        local lab = d.getDiskLabel and d.getDiskLabel()
        if not lab or lab == "" then d.setDiskLabel("Casino") end
      end
    end)
  end
  markLedgerDirty()
  return true
end

local function hasPass()
  return type(data.password) == "string" and data.password ~= ""
end

local function sessionOk()
  return now() < sessionUntil
end

local function askPass(prompt)
  write(prompt or "Password: ")
  local p = read("*")
  return p
end

local function requireAuth(cmd)
  if not hasPass() then
    print("No password set. Run: setpass")
    return false
  end
  if sessionOk() then return true end
  local p = askPass(("Password (%s): "):format(cmd or "?"))
  if p == data.password then
    sessionUntil = now() + SESSION_MS
    print("Unlocked (5 min).")
    return true
  end
  print("Denied.")
  return false
end

local function isInventory(name)
  if not name or not peripheral.isPresent(name) then return false end
  if peripheral.hasType and peripheral.hasType(name, "inventory") then return true end
  local w = peripheral.wrap(name)
  return w and type(w.list) == "function"
end

local function wrapRole(role)
  local n = cfg[role]
  if not n or not isInventory(n) then return nil end
  return peripheral.wrap(n), n
end

local function wrapStorage()
  return wrapRole("storage")
end

local function wrapDeposit()
  return wrapRole("deposit")
end

local function normalizeStationId(id)
  id = tonumber(id)
  if not id or id <= 0 then return nil end
  return id
end

local function getStationBinding(stationId)
  stationId = normalizeStationId(stationId)
  if not stationId then return nil end
  local row = cfg.stations[stationId] or cfg.stations[tostring(stationId)]
  if type(row) ~= "table" then return nil end
  return row, stationId
end

local function wrapStationBarrel(stationId, role)
  local row, sid = getStationBinding(stationId)
  if not row then return nil, nil, sid, "no station binding for #" .. tostring(stationId) end
  local name = row[role]
  if not name or not isInventory(name) then
    return nil, nil, sid, role .. " barrel not bound / missing"
  end
  return peripheral.wrap(name), name, sid
end

--- Accept floppy password or Parent Center master password (when lib/titan present).
local function verifyRemoteAdminPassword(pw)
  if type(pw) ~= "string" or pw == "" then return false end
  loadDisk()
  if hasPass() and pw == data.password then return true end
  if titan and titan.checkPassword then
    return titan.checkPassword(pw) == true
  end
  return false
end

local function sendCasinoAck(replyTo, ok, fields)
  local msg = { type = "casino_ack", ok = ok == true, from = os.getComputerID() }
  if type(fields) == "table" then
    for k, v in pairs(fields) do msg[k] = v end
  end
  rednet.send(replyTo, msg, PROTO)
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
  local pd = peripheral.find("playerDetector")
  if pd then return pd end
  return peripheral.find("player_detector")
end

--- Nearby players via Advanced Peripherals Player Detector (closest first).
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
  if #names > 1 and type(pd.getPlayerPos) == "function" then
    local dist = {}
    for _, n in ipairs(names) do
      local okp, pos = pcall(function() return pd.getPlayerPos(n) end)
      if okp and type(pos) == "table" then
        local x = tonumber(pos.x or pos.X) or 0
        local y = tonumber(pos.y or pos.Y) or 0
        local z = tonumber(pos.z or pos.Z) or 0
        dist[n] = x * x + y * y + z * z
      else
        dist[n] = math.huge
      end
    end
    table.sort(names, function(a, b)
      local da, db = dist[a] or math.huge, dist[b] or math.huge
      if da ~= db then return da < db end
      return a:lower() < b:lower()
    end)
  else
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
  end
  return names, nil
end

--- Pick depositor: optional arg (name or #), else interactive list from detector.
local function pickDepositPlayer(arg)
  local nearby = listNearbyPlayers(PLAYER_RANGE)
  local asNum = tonumber(arg)

  if arg and asNum and asNum >= 1 and asNum == math.floor(asNum) then
    if nearby[asNum] then return nearby[asNum] end
    print("No player #" .. tostring(asNum) .. " in range.")
  elseif arg and tostring(arg):match("%S") then
    local want = normalizePlayer(arg)
    if want then return want end
  end

  if #nearby == 0 then
    if not findDetector() then
      print("No Player Detector — place one next to this PC, or: deposit <player>")
    else
      print("No players in range. Stand closer, or: deposit <player>")
    end
    write("Player name (blank cancel): ")
    local line = read()
    return normalizePlayer(line)
  end

  print("Nearby players:")
  for i, n in ipairs(nearby) do
    print(("  %d) %s"):format(i, n))
  end
  if #nearby == 1 then
    write(("Select # / name [1=%s]: "):format(nearby[1]))
  else
    write("Select # or name: ")
  end
  local line = read()
  if not line or not line:match("%S") then
    if #nearby == 1 then return nearby[1] end
    print("Cancelled.")
    return nil
  end
  local n = tonumber(line)
  if n and nearby[n] then return nearby[n] end
  local named = normalizePlayer(line)
  if named then
    for _, p in ipairs(nearby) do
      if p:lower() == named:lower() then return p end
    end
    -- Allow typing a name not in the list (manual override).
    return named
  end
  print("Cancelled.")
  return nil
end

local function playerKey(name)
  name = tostring(name or ""):gsub("[%c%z]", ""):match("^%s*(.-)%s*$") or ""
  if name == "" then return nil end
  return name:sub(1, 24), name:lower()
end

local function getBal(name)
  local disp, key = playerKey(name)
  if not key then return 0 end
  for k, v in pairs(data.balances) do
    if tostring(k):lower() == key then return tonumber(v) or 0, k end
  end
  return 0, disp
end

local function setBal(name, amount)
  local disp, key = playerKey(name)
  if not key then return false, "bad name" end
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  -- preserve casing of existing key
  local _, existing = getBal(name)
  if existing and tostring(existing):lower() == key then
    data.balances[existing] = amount
  else
    data.balances[disp] = amount
  end
  return true
end

local function acceptedSet()
  local s = {}
  for _, n in ipairs(data.accepted) do s[n] = true end
  return s
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function cmdSetpass()
  loadDisk()
  if hasPass() then
    local old = askPass("Current password: ")
    if old ~= data.password then print("Denied."); return end
  end
  local a = askPass("New password: ")
  if not a or a == "" then print("Empty — cancelled."); return end
  local b = askPass("Confirm: ")
  if a ~= b then print("Mismatch."); return end
  data.password = a
  local ok, err = saveDisk()
  if ok then
    sessionUntil = now() + SESSION_MS
    print("Password saved on floppy.")
  else
    print("Save failed: " .. tostring(err))
  end
end

local function cmdLogin()
  loadDisk()
  if requireAuth("login") then end
end

local function cmdLogout()
  sessionUntil = 0
  print("Locked.")
end

local function cmdBind(a)
  if not requireAuth("bind") then return end
  local role = tostring(a[2] or ""):lower()
  local name = a[3]
  if role == "chest" then role = "storage" end -- legacy alias
  if role == "station" then
    local sid = normalizeStationId(a[3])
    if not sid then
      print("Usage: bind station <computerId> input <barrel> output <barrel>")
      return
    end
    if tostring(a[4] or ""):lower() ~= "input" or tostring(a[6] or ""):lower() ~= "output" then
      print("Usage: bind station <computerId> input <barrel> output <barrel>")
      return
    end
    local inName, outName = a[5], a[7]
    if not inName or not outName then
      print("Usage: bind station <computerId> input <barrel> output <barrel>")
      return
    end
    if not isInventory(inName) then print("Not an inventory: " .. tostring(inName)); return end
    if not isInventory(outName) then print("Not an inventory: " .. tostring(outName)); return end
    if inName == outName then print("Input and output must differ."); return end
    local storName = cfg.storage or cfg.chest
    if storName and (inName == storName or outName == storName) then
      print("Station barrels must differ from the vault."); return
    end
    cfg.stations[sid] = { input = inName, output = outName }
    saveLocal()
    print(("Station #%d  input=%s  output=%s"):format(sid, inName, outName))
    return
  end
  if (role ~= "storage" and role ~= "deposit" and role ~= "drive") or not name then
    print("Usage: bind storage|deposit|drive <peripheralName|side>")
    return
  end
  if role == "drive" then
    if peripheral.getType(name) ~= "drive" then
      print("Not a disk drive: " .. tostring(name)); return
    end
    cfg.drive = name
  else
    if not isInventory(name) then
      print("Not an inventory: " .. tostring(name)); return
    end
    if role == "storage" and cfg.deposit == name then
      print("That peripheral is already the deposit chest."); return
    end
    if role == "deposit" and cfg.storage == name then
      print("That peripheral is already the storage chest."); return
    end
    cfg[role] = name
    if role == "storage" then cfg.chest = name end -- keep legacy field in sync
  end
  saveLocal()
  print("Bound " .. role .. " = " .. name)
end

local function collectInventories()
  local seen, names = {}, {}
  local function add(n, note)
    if not n or seen[n] or not isInventory(n) then return end
    seen[n] = true
    names[#names + 1] = { name = n, note = note }
  end
  for _, n in ipairs(peripheral.getNames()) do
    add(n, nil)
  end
  -- Wired modems: list remotes even if they are not yet in getNames().
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      local m = peripheral.wrap(side)
      if m and type(m.getNamesRemote) == "function" then
        local rem = m.getNamesRemote()
        for _, n in ipairs(rem or {}) do
          add(n, "via " .. side)
        end
      end
    end
  end
  table.sort(names, function(a, b) return a.name < b.name end)
  return names
end

local function cmdInvs()
  print("Inventories:")
  local list = collectInventories()
  if #list == 0 then
    print("  (none)")
    print("Tip: place VANILLA chests/barrels touching this PC, then:")
    print("  bind storage left")
    print("  bind deposit right")
    print("Modded storage usually will not connect a CC wired modem.")
    return
  end
  for _, row in ipairs(list) do
    local marks = ""
    if row.name == cfg.storage then marks = marks .. " [storage]" end
    if row.name == cfg.deposit then marks = marks .. " [deposit]" end
    for sid, bind in pairs(cfg.stations or {}) do
      if type(bind) == "table" then
        if bind.input == row.name then marks = marks .. (" [in #%s]"):format(tostring(sid)) end
        if bind.output == row.name then marks = marks .. (" [out #%s]"):format(tostring(sid)) end
      end
    end
    local note = row.note and ("  (" .. row.note .. ")") or ""
    print("  " .. row.name .. marks .. note)
  end
  if not cfg.storage or not cfg.deposit then
    print("Bind:  bind storage <name>   then   bind deposit <name>")
  end
end

local function cmdDrives()
  print("Disk drives:")
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "drive" then
      local d = peripheral.wrap(n)
      local present = d and d.isDiskPresent and d.isDiskPresent()
      local mark = (n == cfg.drive) and " [bound]" or ""
      print(("  %s%s  disk=%s"):format(n, mark, present and "yes" or "no"))
    end
  end
end

local function cmdScan()
  if not requireAuth("scan") then return end
  local inv, name = wrapStorage()
  if not inv then
    print("Bind storage first: bind storage <name|side>")
    return
  end
  local list = inv.list() or {}
  local seen, order = {}, {}
  for _, slot in pairs(list) do
    if type(slot) == "table" and slot.name then
      if not seen[slot.name] then
        seen[slot.name] = true
        order[#order + 1] = slot.name
      end
    end
  end
  table.sort(order)
  data.accepted = order
  for _, item in ipairs(order) do
    if data.rates[item] == nil then data.rates[item] = 1 end
  end
  -- drop rates for items no longer accepted
  for item in pairs(data.rates) do
    if not seen[item] then data.rates[item] = nil end
  end
  local ok, err = saveDisk()
  print(("Accepted %d item type(s) from storage %s"):format(#order, name))
  for _, item in ipairs(order) do
    print(("  %s  = %d chips"):format(item, data.rates[item] or 0))
  end
  if not ok then print("Floppy save failed: " .. tostring(err)) end
end

local function cmdRates()
  if not requireAuth("rates") then return end
  loadDisk()
  if #data.accepted == 0 then
    print("No accepted items — run scan first."); return
  end
  print("Chips per item (Enter keeps current):")
  for _, item in ipairs(data.accepted) do
    local cur = tonumber(data.rates[item]) or 1
    write(("  %s [%d]: "):format(item, cur))
    local line = read()
    if line and line:match("%S") then
      local n = tonumber(line)
      if n and n >= 0 then data.rates[item] = math.floor(n) end
    end
  end
  local ok, err = saveDisk()
  print(ok and "Rates saved." or ("Save failed: " .. tostring(err)))
end

local function cmdRate(a)
  if not requireAuth("rate") then return end
  local item, chips = a[2], tonumber(a[3])
  if not item or not chips then
    print("Usage: rate <itemName> <chips>"); return
  end
  data.rates[item] = math.max(0, math.floor(chips))
  local found = false
  for _, n in ipairs(data.accepted) do if n == item then found = true; break end end
  if not found then data.accepted[#data.accepted + 1] = item end
  local ok, err = saveDisk()
  print(ok and ("Set " .. item .. " = " .. data.rates[item]) or tostring(err))
end

--- Process accepted items from an input barrel → vault; credit player chips.
local function depositFromBarrel(dep, dname, stor, sname, player)
  loadDisk()
  local accept = acceptedSet()
  if not next(accept) then return false, 0, "no accepted currency — scan vault first" end
  if not dep or not stor then return false, 0, "vault/input not bound" end
  if dname == sname then return false, 0, "input and vault must differ" end
  if type(dep.pushItems) ~= "function" then
    return false, 0, "input barrel cannot pushItems"
  end

  local list = dep.list() or {}
  local gained, movedCount = 0, 0
  local unaccepted = {}
  local storageFull = false
  local slots = {}
  for slot in pairs(list) do slots[#slots + 1] = slot end
  table.sort(slots)

  for _, slot in ipairs(slots) do
    local detail = list[slot]
    if type(detail) == "table" and detail.name then
      local count = tonumber(detail.count) or 0
      if count > 0 then
        if accept[detail.name] then
          local rate = tonumber(data.rates[detail.name]) or 0
          if rate > 0 then
            local left = count
            while left > 0 do
              local okp, n = pcall(dep.pushItems, sname, slot, left)
              n = (okp and tonumber(n)) or 0
              if n <= 0 then
                storageFull = true
                break
              end
              gained = gained + rate * n
              movedCount = movedCount + n
              left = left - n
            end
          else
            unaccepted[detail.name] = true
          end
        else
          unaccepted[detail.name] = true
        end
      end
    end
  end

  local leftList = dep.list() or {}
  local leftoverAccepted = 0
  for _, detail in pairs(leftList) do
    if type(detail) == "table" and detail.name then
      if accept[detail.name] then
        leftoverAccepted = leftoverAccepted + (tonumber(detail.count) or 0)
      else
        unaccepted[detail.name] = true
      end
    end
  end

  if gained <= 0 then
    if next(unaccepted) then return false, 0, "unaccepted items in input barrel" end
    return false, 0, "input barrel empty"
  end

  local bal = getBal(player)
  setBal(player, bal + gained)
  local okSave, saveErr = saveDisk()
  return true, gained, nil, {
    movedCount = movedCount,
    balance = select(1, getBal(player)),
    leftoverAccepted = leftoverAccepted,
    storageFull = storageFull,
    unaccepted = unaccepted,
    saveOk = okSave,
    saveErr = saveErr,
  }
end

local function cmdDeposit(a)
  -- Public: no password. Credit goes to a nearby (or named) player.
  local player = pickDepositPlayer(a[2])
  if not player then return end
  local dep, dname = wrapDeposit()
  local stor, sname = wrapStorage()
  if not dep then
    print("Bind deposit chest: bind deposit <name|side>"); return
  end
  if not stor then
    print("Bind storage chest: bind storage <name|side>"); return
  end
  print("Depositing for: " .. player)

  local ok, gained, err, extra = depositFromBarrel(dep, dname, stor, sname, player)
  extra = extra or {}
  if not ok then
    if extra.unaccepted and next(extra.unaccepted) then
      print("Unaccepted item in deposit chest:")
      local names = {}
      for n in pairs(extra.unaccepted) do names[#names + 1] = n end
      table.sort(names)
      for _, n in ipairs(names) do print("  " .. n) end
    end
    print(tostring(err or "deposit failed"))
    return
  end

  print(("Credited %s +%d chips (%d items → vault %s). Balance=%d"):format(
    player, gained, extra.movedCount or 0, sname, extra.balance or select(1, getBal(player))))
  if (extra.leftoverAccepted or 0) > 0 or extra.storageFull then
    print(("Vault full? %d accepted item(s) still in deposit."):format(extra.leftoverAccepted or 0))
  end
  if extra.saveOk == false then print("Save failed: " .. tostring(extra.saveErr)) end
end

--- Count accepted currency currently in storage (item → count) + total chip value.
local function storageStock(inv)
  local accept = acceptedSet()
  local stock, value = {}, 0
  local list = inv.list() or {}
  for _, detail in pairs(list) do
    if type(detail) == "table" and detail.name and accept[detail.name] then
      local c = tonumber(detail.count) or 0
      local rate = tonumber(data.rates[detail.name]) or 0
      if c > 0 and rate > 0 then
        stock[detail.name] = (stock[detail.name] or 0) + c
        value = value + rate * c
      end
    end
  end
  return stock, value
end

--- Greedy plan: chips → item counts using highest rates first (exact amount).
local function planWithdrawItems(amount, stock)
  local denoms = {}
  for item, rate in pairs(data.rates) do
    rate = tonumber(rate) or 0
    if rate > 0 and (stock[item] or 0) > 0 then
      denoms[#denoms + 1] = { item = item, rate = rate }
    end
  end
  table.sort(denoms, function(a, b)
    if a.rate ~= b.rate then return a.rate > b.rate end
    return a.item < b.item
  end)

  local plan, left = {}, amount
  local avail = {}
  for item, c in pairs(stock) do avail[item] = c end

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

--- Move `need` of `item` from vault → output barrel. Returns moved count.
local function pushItemToOutput(stor, sname, outName, item, need)
  local moved = 0
  local list = stor.list() or {}
  local slots = {}
  for slot, detail in pairs(list) do
    if type(detail) == "table" and detail.name == item then
      slots[#slots + 1] = slot
    end
  end
  table.sort(slots)
  for _, slot in ipairs(slots) do
    if moved >= need then break end
    local detail = stor.list()[slot]
    local have = (type(detail) == "table" and tonumber(detail.count)) or 0
    local want = math.min(need - moved, have)
    if want > 0 then
      local okp, n = pcall(stor.pushItems, outName, slot, want)
      n = (okp and tonumber(n)) or 0
      moved = moved + n
      if n <= 0 then break end
    end
  end
  return moved
end

--- Debit player and pay coins from vault → output barrel.
local function withdrawToBarrel(stor, sname, outInv, outName, player, amount)
  loadDisk()
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then return false, 0, "bad amount" end
  if not stor or not outInv then return false, 0, "vault/output not bound" end
  if outName == sname then return false, 0, "output and vault must differ" end
  if type(stor.pushItems) ~= "function" then
    return false, 0, "vault cannot pushItems"
  end

  local bal = getBal(player)
  if bal < amount then return false, 0, "insufficient player chips" end

  local stock, vaultValue = storageStock(stor)
  if vaultValue < amount then return false, 0, "insufficient vault stock" end

  local plan, leftover = planWithdrawItems(amount, stock)
  if leftover > 0 then return false, 0, "cannot make exact payout from vault" end

  local paidValue, totalItems = 0, 0
  for item, count in pairs(plan) do
    local rate = tonumber(data.rates[item]) or 0
    local moved = pushItemToOutput(stor, sname, outName, item, count)
    if moved < count then
      if moved > 0 then
        paidValue = paidValue + rate * moved
        totalItems = totalItems + moved
      end
      if paidValue <= 0 then return false, 0, "output barrel full" end
      setBal(player, bal - paidValue)
      saveDisk()
      return true, paidValue, "partial", {
        partial = true,
        balance = select(1, getBal(player)),
        totalItems = totalItems,
      }
    end
    paidValue = paidValue + rate * moved
    totalItems = totalItems + moved
  end

  setBal(player, bal - paidValue)
  saveDisk()
  return true, paidValue, nil, {
    balance = select(1, getBal(player)),
    totalItems = totalItems,
    plan = plan,
  }
end

local function cmdWithdraw(a)
  if not requireAuth("withdraw") then return end
  local player, n = a[2], tonumber(a[3])
  if not player or not n then
    print("Usage: withdraw <player> <chips>"); return
  end
  n = math.floor(n)
  if n <= 0 then print("Need positive chips."); return end

  local stor, sname = wrapStorage()
  local dep, dname = wrapDeposit()
  if not stor then print("Bind vault: bind storage <name|side>"); return end
  if not dep then print("Bind deposit/output: bind deposit <name|side>"); return end

  loadDisk()
  local bal = getBal(player)
  local ok, paid, err, extra = withdrawToBarrel(stor, sname, dep, dname, player, n)
  extra = extra or {}
  if not ok then
    if err == "insufficient player chips" then
      print(("Insufficient player chips (%d)."):format(bal))
    elseif err == "insufficient vault stock" then
      local _, vaultValue = storageStock(stor)
      print(("Not enough in vault (have %d chips worth, need %d)."):format(vaultValue or 0, n))
    else
      print(tostring(err or "withdraw failed"))
    end
    return
  end
  if err == "partial" then
    print(("Partial withdraw: %d chips (%d items → %s). Balance=%d"):format(
      paid, extra.totalItems or 0, dname, extra.balance or select(1, getBal(player))))
    return
  end
  print(("Withdrew %d chips for %s (%d items → %s). Balance=%d"):format(
    paid, player, extra.totalItems or 0, dname, extra.balance or select(1, getBal(player))))
end

local function cmdUnbindStation(a)
  if not requireAuth("unbind") then return end
  local sid = normalizeStationId(a[3] or a[2])
  if not sid then
    print("Usage: unbind station <computerId>")
    return
  end
  if cfg.stations[sid] or cfg.stations[tostring(sid)] then
    cfg.stations[sid] = nil
    cfg.stations[tostring(sid)] = nil
    saveLocal()
    print("Removed station #" .. sid)
  else
    print("No binding for station #" .. sid)
  end
end

local function cmdStations()
  print("Station barrel bindings (by station computer ID):")
  local ids = {}
  for k in pairs(cfg.stations or {}) do
    local sid = normalizeStationId(k)
    if sid then ids[#ids + 1] = sid end
  end
  table.sort(ids)
  if #ids == 0 then
    print("  (none)")
    print("Bind: bind station <computerId> input <barrel> output <barrel>")
    return
  end
  for _, sid in ipairs(ids) do
    local row = cfg.stations[sid] or cfg.stations[tostring(sid)]
    print(("  #%d  in=%s  out=%s"):format(
      sid, tostring(row and row.input or "?"), tostring(row and row.output or "?")))
  end
end

local function cmdBalance(a)
  if not requireAuth("balance") then return end
  loadDisk()
  local who = a[2]
  if who then
    print(("%s: %d chips"):format(who, select(1, getBal(who))))
    return
  end
  print("Balances:")
  local keys = {}
  for k in pairs(data.balances) do keys[#keys + 1] = k end
  table.sort(keys, function(x, y) return tostring(x):lower() < tostring(y):lower() end)
  if #keys == 0 then print("  (none)") end
  for _, k in ipairs(keys) do
    print(("  %s  %d"):format(k, tonumber(data.balances[k]) or 0))
  end
end

local function cmdStatus()
  loadDisk()
  print("== Currency Manager v" .. VERSION .. " ==")
  print("Vault:   " .. tostring(cfg.storage or cfg.chest or "(unbound)"))
  print("Deposit: " .. tostring(cfg.deposit or "(legacy emergency I/O)"))
  print("Detect:  " .. (findDetector() and ("OK (range " .. PLAYER_RANGE .. ")") or "NONE"))
  print("Drive:   " .. tostring(cfg.drive or "(auto)"))
  print("Floppy:  " .. tostring(diskPath() or "NONE"))
  print("Pass:    " .. (hasPass() and "set" or "NOT SET"))
  print("Session: " .. (sessionOk() and "unlocked" or "locked"))
  print("Accepted types: " .. tostring(#data.accepted))
  local stations = 0
  for _ in pairs(cfg.stations or {}) do stations = stations + 1 end
  print("Stations: " .. tostring(stations))
  local players = 0
  for _ in pairs(data.balances) do players = players + 1 end
  print("Players: " .. tostring(players))
end

local function cmdHelp()
  print([[
Currency Manager = vault ledger + station barrels. Players use casino_atm.

setpass | login | logout
bind storage|deposit|drive <name|side>        (password)
bind station <computerId> input <in> output <out>   (password)
unbind station <computerId>                  (password)
stations | invs | drives | status
scan / rates / rate …                        (password)
deposit [player|#]   legacy chest credit (prefer station ATM)
withdraw <player> <chips>                    (password) legacy chest payout
balance [player]                             (password)
help | exit

Mesh: casino_station_deposit / casino_station_withdraw
      casino_admin_balance_req / casino_ledger_req + casino_ledger / ack
]])
end

--------------------------------------------------------------------------------
-- Live ledger monitor (optional wired/advanced monitor)
--------------------------------------------------------------------------------
local function findMonitor()
  local m = peripheral.find("monitor")
  if m then return m end
  for _, side in ipairs(redstone.getSides()) do
    if peripheral.getType(side) == "monitor" then
      return peripheral.wrap(side)
    end
  end
  return nil
end

local function monIsColor(out)
  local ok, c = pcall(function() return out.isColor and out.isColor() end)
  return ok and c == true
end

local function monApplyScale(out)
  if not out then return 0.5, 0, 0, false end
  local color = monIsColor(out)
  pcall(function() out.setTextScale(0.5) end)
  local w, h = out.getSize()
  local scale = 0.5
  if w >= 52 and h >= 26 then scale = 1 end
  pcall(function() out.setTextScale(scale) end)
  w, h = out.getSize()
  return scale, w, h, color
end

local function monFill(out, x, y, ww, hh, bg, fg)
  if not out then return end
  bg = bg or colors.black
  fg = fg or colors.white
  for row = y, y + hh - 1 do
    out.setCursorPos(x, row)
    if out.setBackgroundColor then out.setBackgroundColor(bg) end
    if out.setTextColor then out.setTextColor(fg) end
    out.write(string.rep(" ", ww))
  end
end

local function monText(out, x, y, txt, fg, bg)
  if not out or y < 1 then return end
  local mw = select(1, out.getSize())
  if x > mw then return end
  txt = tostring(txt or "")
  if out.setBackgroundColor then out.setBackgroundColor(bg or colors.black) end
  if out.setTextColor then out.setTextColor(fg or colors.white) end
  out.setCursorPos(x, y)
  out.write(txt:sub(1, math.max(0, mw - x + 1)))
end

local function ledgerSnapshot()
  loadDisk()
  local rows, totalChips = {}, 0
  for k, v in pairs(data.balances) do
    local chips = math.max(0, math.floor(tonumber(v) or 0))
    if chips > 0 then
      rows[#rows + 1] = { name = tostring(k), chips = chips }
      totalChips = totalChips + chips
    end
  end
  table.sort(rows, function(a, b)
    if a.chips ~= b.chips then return a.chips > b.chips end
    return a.name:lower() < b.name:lower()
  end)
  local vaultChips = 0
  local inv = select(1, wrapStorage())
  if inv then
    vaultChips = select(2, storageStock(inv)) or 0
  end
  return {
    totalChips = totalChips,
    vaultChips = vaultChips,
    players = rows,
    playerCount = #rows,
  }
end

local function fmtLedgerRow(name, chips, width)
  name = tostring(name or "?"):sub(1, math.max(1, width - 10))
  local num = tostring(math.floor(tonumber(chips) or 0))
  local pad = width - #name - #num
  if pad < 1 then pad = 1 end
  return name .. string.rep(" ", pad) .. num
end

local function drawLedgerMonitor(monitor, snap)
  if not monitor or not snap then return end
  local prev = term.current()
  term.redirect(monitor)
  local ok, err = pcall(function()
    local _, w, h, color = monApplyScale(monitor)
    if w < 1 or h < 1 then return end
    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    local headerH = (h >= 10) and 3 or 2
    local footerH = 1
    local bodyTop = headerH + 1
    local bodyH = math.max(1, h - headerH - footerH)

    local title = "CASINO LEDGER"
    local sub = ("CHIPS %d  VAULT %d"):format(
      tonumber(snap.totalChips) or 0, tonumber(snap.vaultChips) or 0)
    if color then
      monFill(monitor, 1, 1, w, headerH, colors.magenta, colors.black)
      monText(monitor, 2, 1, title, colors.white, colors.magenta)
      monText(monitor, 2, 2, sub:sub(1, w - 2), colors.pink, colors.magenta)
      if headerH >= 3 then
        monText(monitor, 2, 3, ("Mgr #%d"):format(os.getComputerID()), colors.lightGray, colors.magenta)
      end
    else
      monText(monitor, 1, 1, title, colors.white, colors.black)
      monText(monitor, 1, 2, sub:sub(1, w), colors.lightGray, colors.black)
    end

    local maxRows = bodyH
    local players = snap.players or {}
    if #players == 0 then
      monText(monitor, 2, bodyTop, "(no player balances)", colors.gray, colors.black)
    else
      for i = 1, math.min(maxRows, #players) do
        local row = players[i]
        local line = fmtLedgerRow(row.name, row.chips, w)
        local fg = colors.lightGray
        if color and i == 1 then fg = colors.yellow
        elseif color and i == 2 then fg = colors.orange
        elseif color and i == 3 then fg = colors.white end
        local bg = colors.black
        if color and i % 2 == 0 then bg = colors.gray end
        monText(monitor, 1, bodyTop + i - 1, line, fg, bg)
      end
      if #players > maxRows then
        monText(monitor, 2, bodyTop + maxRows - 1,
          ("+%d more"):format(#players - maxRows + 1), colors.gray, colors.black)
      end
    end

    local foot = (" %d players  refresh %ds"):format(
      tonumber(snap.playerCount) or 0, MON_REFRESH_SEC)
    if color then
      monFill(monitor, 1, h, w, 1, colors.gray, colors.white)
      monText(monitor, 1, h, foot:sub(1, w), colors.white, colors.gray)
    else
      monText(monitor, 1, h, foot:sub(1, w), colors.gray, colors.black)
    end
  end)
  term.redirect(prev)
  if not ok and err then pcall(term.redirect, NATIVE_TERM) end
end

local function monitorLoop()
  while true do
    local monitor = findMonitor()
    if monitor then
      drawLedgerMonitor(monitor, ledgerSnapshot())
      local timer = os.startTimer(MON_REFRESH_SEC)
      while true do
        local ev, p1 = os.pullEvent()
        if ev == "timer" and p1 == timer then break end
        if ev == "casino_ledger_dirty" or ev == "monitor_resize"
            or ev == "peripheral" or ev == "peripheral_detach"
            or ev == "disk" or ev == "disk_eject" then
          break
        end
      end
    else
      sleep(MON_REFRESH_SEC)
    end
  end
end

--------------------------------------------------------------------------------
-- Rednet casino API (games spend/payout chips already on the floppy ledger)
--------------------------------------------------------------------------------
local function announce()
  local payload = {
    type = "casino_hello",
    from = os.getComputerID(),
    name = os.getComputerLabel() or ("Casino-" .. os.getComputerID()),
    ok = true,
  }
  pcall(rednet.broadcast, payload, PROTO)
  pcall(rednet.broadcast, payload, ROUTER_PROTOCOL)
end

local function handleNet(from, msg)
  if type(msg) ~= "table" then return end
  local t = msg.type
  local replyTo = tonumber(msg.replyTo) or from
  if t == "casino_ping" or t == "ping" then
    rednet.send(replyTo, {
      type = "casino_hello",
      ok = true,
      from = os.getComputerID(),
      name = os.getComputerLabel(),
    }, PROTO)
  elseif t == "casino_balance_req" then
    loadDisk()
    local player = msg.player or msg.name
    local bal = select(1, getBal(player))
    rednet.send(replyTo, {
      type = "casino_balance",
      ok = true,
      player = player,
      chips = bal,
      from = os.getComputerID(),
    }, PROTO)
  elseif t == "casino_rates_req" then
    loadDisk()
    rednet.send(replyTo, {
      type = "casino_rates",
      ok = true,
      accepted = data.accepted,
      rates = data.rates,
      from = os.getComputerID(),
    }, PROTO)
  elseif t == "casino_credit" then
    -- ATM explicit deposit: trust mesh ATM after it verified chest contents.
    loadDisk()
    local player = msg.player or msg.name
    local amount = math.floor(tonumber(msg.amount or msg.count) or 0)
    local disp = select(2, playerKey(player))
    if not disp then
      rednet.send(replyTo, { type = "casino_ack", ok = false, err = "bad player", op = "credit" }, PROTO)
      return
    end
    if amount <= 0 then
      rednet.send(replyTo, {
        type = "casino_ack", ok = false, err = "bad amount", op = "credit",
        chips = select(1, getBal(player)),
      }, PROTO)
      return
    end
    local bal = getBal(player)
    setBal(player, bal + amount)
    saveDisk()
    rednet.send(replyTo, {
      type = "casino_ack", ok = true, op = "credit",
      player = player, amount = amount, chips = select(1, getBal(player)),
    }, PROTO)
  elseif t == "casino_bet" then
    loadDisk()
    local player = msg.player or msg.name
    local amount = math.floor(tonumber(msg.amount or msg.count) or 0)
    local bal = select(1, getBal(player))
    if amount <= 0 then
      rednet.send(replyTo, { type = "casino_ack", ok = false, err = "bad amount", chips = bal }, PROTO)
      return
    end
    if bal < amount then
      rednet.send(replyTo, { type = "casino_ack", ok = false, err = "insufficient", chips = bal }, PROTO)
      return
    end
    setBal(player, bal - amount)
    saveDisk()
    rednet.send(replyTo, {
      type = "casino_ack", ok = true, op = "bet",
      player = player, amount = amount, chips = select(1, getBal(player)),
    }, PROTO)
  elseif t == "casino_payout" then
    loadDisk()
    local player = msg.player or msg.name
    local amount = math.floor(tonumber(msg.amount or msg.count) or 0)
    if amount < 0 then amount = 0 end
    local bal = select(1, getBal(player))
    setBal(player, bal + amount)
    saveDisk()
    rednet.send(replyTo, {
      type = "casino_ack", ok = true, op = "payout",
      player = player, amount = amount, chips = select(1, getBal(player)),
    }, PROTO)
  elseif t == "casino_stations_req" then
    local rows = {}
    for k, row in pairs(cfg.stations or {}) do
      local sid = normalizeStationId(k)
      if sid and type(row) == "table" then
        rows[#rows + 1] = {
          stationId = sid,
          input = row.input,
          output = row.output,
        }
      end
    end
    table.sort(rows, function(a, b) return (a.stationId or 0) < (b.stationId or 0) end)
    rednet.send(replyTo, {
      type = "casino_stations",
      ok = true,
      stations = rows,
      from = os.getComputerID(),
    }, PROTO)
  elseif t == "casino_station_deposit" then
    loadDisk()
    local stationId = normalizeStationId(msg.stationId) or from
    local player = normalizePlayer(msg.player or msg.name)
    if not player then
      sendCasinoAck(replyTo, false, { op = "station_deposit", err = "bad player" })
      return
    end
    local dep, dname = wrapStationBarrel(stationId, "input")
    local stor, sname = wrapStorage()
    if not dep then
      sendCasinoAck(replyTo, false, {
        op = "station_deposit", err = "station input not bound", stationId = stationId,
      })
      return
    end
    if not stor then
      sendCasinoAck(replyTo, false, { op = "station_deposit", err = "vault not bound" })
      return
    end
    local ok, gained, err, extra = depositFromBarrel(dep, dname, stor, sname, player)
    extra = extra or {}
    if not ok then
      sendCasinoAck(replyTo, false, {
        op = "station_deposit", err = err or "deposit failed",
        stationId = stationId, player = player,
      })
      return
    end
    sendCasinoAck(replyTo, true, {
      op = "station_deposit",
      stationId = stationId,
      player = player,
      amount = gained,
      chips = extra.balance or select(1, getBal(player)),
      movedCount = extra.movedCount,
    })
  elseif t == "casino_station_withdraw" then
    loadDisk()
    local stationId = normalizeStationId(msg.stationId) or from
    local player = normalizePlayer(msg.player or msg.name)
    local amount = math.floor(tonumber(msg.amount or msg.count) or 0)
    if not player then
      sendCasinoAck(replyTo, false, { op = "station_withdraw", err = "bad player" })
      return
    end
    if amount <= 0 then
      sendCasinoAck(replyTo, false, {
        op = "station_withdraw", err = "bad amount", chips = select(1, getBal(player)),
      })
      return
    end
    local outInv, outName = wrapStationBarrel(stationId, "output")
    local stor, sname = wrapStorage()
    if not outInv then
      sendCasinoAck(replyTo, false, {
        op = "station_withdraw", err = "station output not bound", stationId = stationId,
      })
      return
    end
    if not stor then
      sendCasinoAck(replyTo, false, { op = "station_withdraw", err = "vault not bound" })
      return
    end
    local ok, paid, err, extra = withdrawToBarrel(stor, sname, outInv, outName, player, amount)
    extra = extra or {}
    if not ok then
      sendCasinoAck(replyTo, false, {
        op = "station_withdraw", err = err or "withdraw failed",
        stationId = stationId, player = player,
        chips = select(1, getBal(player)),
      })
      return
    end
    sendCasinoAck(replyTo, true, {
      op = "station_withdraw",
      stationId = stationId,
      player = player,
      amount = paid,
      chips = extra.balance or select(1, getBal(player)),
      totalItems = extra.totalItems,
      partial = err == "partial",
    })
  elseif t == "casino_bind_station" then
    if not verifyRemoteAdminPassword(msg.password) then
      sendCasinoAck(replyTo, false, { op = "bind_station", err = "denied" })
      return
    end
    local sid = normalizeStationId(msg.stationId)
    local inName, outName = msg.input or msg.inputBarrel, msg.output or msg.outputBarrel
    if not sid or not inName or not outName then
      sendCasinoAck(replyTo, false, { op = "bind_station", err = "bad args" })
      return
    end
    if not isInventory(inName) or not isInventory(outName) then
      sendCasinoAck(replyTo, false, { op = "bind_station", err = "bad peripheral" })
      return
    end
    cfg.stations[sid] = { input = inName, output = outName }
    saveLocal()
    sendCasinoAck(replyTo, true, {
      op = "bind_station", stationId = sid, input = inName, output = outName,
    })
  elseif t == "casino_admin_withdraw" then
    if not verifyRemoteAdminPassword(msg.password) then
      sendCasinoAck(replyTo, false, { op = "admin_withdraw", err = "denied" })
      return
    end
    loadDisk()
    local player = normalizePlayer(msg.player or msg.name)
    local amount = math.floor(tonumber(msg.amount or msg.count) or 0)
    local stationId = normalizeStationId(msg.stationId)
    if not player or amount <= 0 then
      sendCasinoAck(replyTo, false, { op = "admin_withdraw", err = "bad args" })
      return
    end
    local stor, sname = wrapStorage()
    if not stor then
      sendCasinoAck(replyTo, false, { op = "admin_withdraw", err = "vault not bound" })
      return
    end
    local outInv, outName
    if stationId then
      outInv, outName = wrapStationBarrel(stationId, "output")
    end
    if not outInv then
      outInv, outName = wrapDeposit()
    end
    if not outInv then
      sendCasinoAck(replyTo, false, { op = "admin_withdraw", err = "no output barrel" })
      return
    end
    local ok, paid, err, extra = withdrawToBarrel(stor, sname, outInv, outName, player, amount)
    extra = extra or {}
    if not ok then
      sendCasinoAck(replyTo, false, {
        op = "admin_withdraw", err = err or "withdraw failed",
        player = player, chips = select(1, getBal(player)),
      })
      return
    end
    sendCasinoAck(replyTo, true, {
      op = "admin_withdraw",
      player = player,
      amount = paid,
      chips = extra.balance or select(1, getBal(player)),
      stationId = stationId,
      output = outName,
      partial = err == "partial",
    })
  elseif t == "casino_admin_scan" then
    if not verifyRemoteAdminPassword(msg.password) then
      sendCasinoAck(replyTo, false, { op = "admin_scan", err = "denied" })
      return
    end
    local inv, name = wrapStorage()
    if not inv then
      sendCasinoAck(replyTo, false, { op = "admin_scan", err = "vault not bound" })
      return
    end
    local list = inv.list() or {}
    local seen, order = {}, {}
    for _, slot in pairs(list) do
      if type(slot) == "table" and slot.name and not seen[slot.name] then
        seen[slot.name] = true
        order[#order + 1] = slot.name
      end
    end
    table.sort(order)
    data.accepted = order
    for _, item in ipairs(order) do
      if data.rates[item] == nil then data.rates[item] = 1 end
    end
    for item in pairs(data.rates) do
      if not seen[item] then data.rates[item] = nil end
    end
    local okSave, saveErr = saveDisk()
    sendCasinoAck(replyTo, okSave ~= false, {
      op = "admin_scan",
      accepted = data.accepted,
      rates = data.rates,
      vault = name,
      err = okSave == false and tostring(saveErr) or nil,
    })
  elseif t == "casino_admin_rate_set" then
    if not verifyRemoteAdminPassword(msg.password) then
      sendCasinoAck(replyTo, false, { op = "admin_rate_set", err = "denied" })
      return
    end
    loadDisk()
    local item = msg.item or msg.name
    local chips = math.max(0, math.floor(tonumber(msg.chips or msg.rate or msg.amount) or 0))
    if not item then
      sendCasinoAck(replyTo, false, { op = "admin_rate_set", err = "bad item" })
      return
    end
    data.rates[item] = chips
    local found = false
    for _, n in ipairs(data.accepted) do if n == item then found = true break end end
    if not found then data.accepted[#data.accepted + 1] = item end
    local okSave, saveErr = saveDisk()
    sendCasinoAck(replyTo, okSave ~= false, {
      op = "admin_rate_set",
      item = item,
      chips = chips,
      rates = data.rates,
      err = okSave == false and tostring(saveErr) or nil,
    })
  elseif t == "casino_admin_rates_set" then
    if not verifyRemoteAdminPassword(msg.password) then
      sendCasinoAck(replyTo, false, { op = "admin_rates_set", err = "denied" })
      return
    end
    loadDisk()
    if type(msg.rates) == "table" then
      for item, rate in pairs(msg.rates) do
        data.rates[item] = math.max(0, math.floor(tonumber(rate) or 0))
      end
    end
    local okSave, saveErr = saveDisk()
    sendCasinoAck(replyTo, okSave ~= false, {
      op = "admin_rates_set",
      rates = data.rates,
      accepted = data.accepted,
      err = okSave == false and tostring(saveErr) or nil,
    })
  elseif t == "casino_admin_balance_req" then
    if not verifyRemoteAdminPassword(msg.password) then
      sendCasinoAck(replyTo, false, { op = "admin_balance", err = "denied" })
      return
    end
    loadDisk()
    local player = msg.player or msg.name
    sendCasinoAck(replyTo, true, {
      op = "admin_balance",
      player = player,
      chips = select(1, getBal(player)),
    })
  elseif t == "casino_ledger_req" then
    if not verifyRemoteAdminPassword(msg.password) then
      rednet.send(replyTo, { type = "casino_ledger", ok = false, err = "denied" }, PROTO)
      return
    end
    local snap = ledgerSnapshot()
    rednet.send(replyTo, {
      type = "casino_ledger",
      ok = true,
      from = os.getComputerID(),
      totalChips = snap.totalChips,
      vaultChips = snap.vaultChips,
      players = snap.players,
      playerCount = snap.playerCount,
    }, PROTO)
  end
end

local function netLoop()
  local helloT = os.startTimer(15)
  announce()
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "timer" and p1 == helloT then
      announce()
      helloT = os.startTimer(20)
    elseif ev == "rednet_message" and type(p2) == "table" then
      if p3 == PROTO or p3 == ROUTER_PROTOCOL or p3 == nil then
        handleNet(p1, p2)
      end
    elseif ev == "disk" or ev == "disk_eject" then
      loadDisk()
    end
  end
end

local function consoleLoop()
  while true do
    write("casino> ")
    local line = read()
    if not line then break end
    local a = {}
    for w in line:gmatch("%S+") do a[#a + 1] = w end
    local cmd = tostring(a[1] or ""):lower()
    if cmd == "" then
    elseif cmd == "exit" or cmd == "quit" then return
    elseif cmd == "help" or cmd == "?" then cmdHelp()
    elseif cmd == "setpass" then cmdSetpass()
    elseif cmd == "login" then cmdLogin()
    elseif cmd == "logout" then cmdLogout()
    elseif cmd == "bind" then cmdBind(a)
    elseif cmd == "unbind" then cmdUnbindStation(a)
    elseif cmd == "stations" then cmdStations()
    elseif cmd == "invs" then cmdInvs()
    elseif cmd == "drives" then cmdDrives()
    elseif cmd == "scan" or cmd == "accept" then cmdScan()
    elseif cmd == "rates" then cmdRates()
    elseif cmd == "rate" then cmdRate(a)
    elseif cmd == "deposit" then cmdDeposit(a)
    elseif cmd == "withdraw" then cmdWithdraw(a)
    elseif cmd == "balance" or cmd == "bal" then cmdBalance(a)
    elseif cmd == "status" then cmdStatus()
    elseif cmd == "reload" then
      local ok, err = loadDisk()
      print(ok and "Reloaded floppy." or ("Fail: " .. tostring(err)))
    else
      print("Unknown. help")
    end
  end
end

--------------------------------------------------------------------------------
loadLocal()
loadDisk()
openModem()
os.setComputerLabel(cfg.label or os.getComputerLabel() or ("Casino-" .. os.getComputerID()))

term.clear(); term.setCursorPos(1, 1)
print("== Currency Manager v" .. VERSION .. " ==")
if not hasPass() then
  print("FIRST RUN: insert floppy, then: setpass")
else
  print("Floppy OK. login to manage currency.")
end
print("Bind vault + station barrels (+ optional legacy deposit chest).")
print("Type help. Mesh casino API online.")
print("")

parallel.waitForAny(consoleLoop, netLoop, monitorLoop)
