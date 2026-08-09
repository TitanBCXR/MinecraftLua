--[[
  games/managers/currency_manager.lua  -  Casino currency vault
  Titan-Version: 1.0.2

  Accepts in-game items as tender for gambling chips. Password-protects every
  currency command. Persists accepted items, rates, balances, and password on
  a floppy disk (casino_currency.cfg).

  Layout (vanilla chests/barrels — modded storage rarely connects CC modems):

    [Deposit chest] --touching/wired--> [Currency Manager PC] --disk--> floppy
    [Storage chest] --touching/wired-->/              |
                                                 wireless mesh

  - storage  sample accepted currency (scan) + vault for deposited tender
  - deposit  players drop items here; deposit <player> moves accepted types
             into storage and credits chips. Unaccepted items stay put.

  Commands (password required except help/status/exit/setpass first-time):
    setpass                 set / change floppy password
    login                   unlock session (5 min)
    logout
    bind storage|deposit|drive <name|side>
    bind chest <name>       alias for bind storage (legacy)
    invs | drives
    scan | accept           read STORAGE → accepted item list → floppy
    rates                   interactive chips-per-item settings
    rate <item> <chips>
    deposit <player>        move accepted from DEPOSIT → STORAGE + credit
    withdraw <player> <n>   remove chips from player balance
    balance [player]
    status | help | exit

  Rednet (protocol titan_install + titan_router):
    casino_ping / casino_hello
    casino_balance_req / casino_balance
    casino_bet / casino_payout + ack
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
local VERSION = "1.0.2"

local cfg = { storage = nil, deposit = nil, chest = nil, drive = nil, label = nil }
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
  local role = tostring(a[2] or ""):lower()
  local name = a[3]
  if role == "chest" then role = "storage" end -- legacy alias
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

local function cmdDeposit(a)
  if not requireAuth("deposit") then return end
  local player = a[2]
  if not player then print("Usage: deposit <player>"); return end
  local dep, dname = wrapDeposit()
  local stor, sname = wrapStorage()
  if not dep then
    print("Bind deposit chest: bind deposit <name|side>"); return
  end
  if not stor then
    print("Bind storage chest: bind storage <name|side>"); return
  end
  if dname == sname then
    print("Deposit and storage must be different chests."); return
  end
  if type(dep.pushItems) ~= "function" then
    print("Deposit chest cannot pushItems (need inventory peripheral)."); return
  end
  loadDisk()
  local accept = acceptedSet()
  if not next(accept) then print("No accepted currency — scan storage first."); return end

  local list = dep.list() or {}
  local gained, movedCount = 0, 0
  local unaccepted = {}
  local storageFull = false

  -- Stable slot order so partial stacks behave predictably.
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

  -- Re-check deposit for leftover unaccepted / unmoved stacks.
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

  if next(unaccepted) then
    print("Unaccepted item in deposit chest:")
    local names = {}
    for n in pairs(unaccepted) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do print("  " .. n) end
  end

  if gained <= 0 then
    if next(unaccepted) then
      print("No accepted items moved — nothing credited.")
    else
      print("Deposit chest empty (or nothing transferable).")
    end
    return
  end

  local bal = getBal(player)
  setBal(player, bal + gained)
  local ok, err = saveDisk()
  print(("Credited %s +%d chips (%d items → storage %s). Balance=%d"):format(
    player, gained, movedCount, sname, select(1, getBal(player))))
  if leftoverAccepted > 0 or storageFull then
    print(("Storage full? %d accepted item(s) still in deposit."):format(leftoverAccepted))
  end
  if not ok then print("Save failed: " .. tostring(err)) end
end

local function cmdWithdraw(a)
  if not requireAuth("withdraw") then return end
  local player, n = a[2], tonumber(a[3])
  if not player or not n then
    print("Usage: withdraw <player> <chips>"); return
  end
  n = math.floor(n)
  if n <= 0 then print("Need positive chips."); return end
  loadDisk()
  local bal = getBal(player)
  if bal < n then print(("Insufficient (%d)."):format(bal)); return end
  setBal(player, bal - n)
  local ok, err = saveDisk()
  print(("Withdrew %d from %s. Balance=%d"):format(n, player, select(1, getBal(player))))
  if not ok then print("Save failed: " .. tostring(err)) end
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
  print("Storage: " .. tostring(cfg.storage or cfg.chest or "(unbound)"))
  print("Deposit: " .. tostring(cfg.deposit or "(unbound)"))
  print("Drive:   " .. tostring(cfg.drive or "(auto)"))
  print("Floppy:  " .. tostring(diskPath() or "NONE"))
  print("Pass:    " .. (hasPass() and "set" or "NOT SET"))
  print("Session: " .. (sessionOk() and "unlocked" or "locked"))
  print("Accepted types: " .. tostring(#data.accepted))
  local players = 0
  for _ in pairs(data.balances) do players = players + 1 end
  print("Players: " .. tostring(players))
end

local function cmdHelp()
  print([[
setpass | login | logout
bind storage|deposit|drive <name|side>
invs | drives | status
  storage = accepted samples + vault
  deposit = player drop-off (vanilla chests)
scan          STORAGE → accepted list (floppy)
rates         set chips per item
rate <item> <chips>
deposit <player>   move accepted DEPOSIT→STORAGE + credit
withdraw <player> <chips>
balance [player]
help | exit
]])
end

--------------------------------------------------------------------------------
-- Rednet casino API (no password — chips already credited by auth'd deposit)
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
print("Bind storage + deposit chests, scan storage, then deposit <player>.")
print("Type help. Mesh casino API online.")
print("")

parallel.waitForAny(consoleLoop, netLoop)
