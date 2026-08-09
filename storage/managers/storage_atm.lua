--[[
  storage/managers/storage_atm.lua  -  Standalone vault ATM (wired modem)
  Titan-Version: 1.1.0

  Solo item ATM. No casino, no Currency Manager, no Create Stock Ticker.
  Talks to a Create vault (or any inventory) over a wired modem network.

  Hardware:
    [Intake chest]  --touching/wired--> [ATM PC]
    [Output chest]  --touching/wired-->/
    [Vault]         --wired modem----/

  Deposit: put items in intake → `deposit` → confirm → pushItems into vault.
  Withdraw: if vault has enough → pushItems vault → output. No move if short.

  Setup:
    invs
    bind intake <side|name>
    bind output <side|name>
    bind vault <side|name>
    deposit | withdraw | stock | status | help
]]

local LOCAL_CFG = "storage_atm.cfg"
local VERSION = "1.1.0"

local cfg = {
  intake = nil,
  output = nil,
  vault = nil,
  label = nil,
  -- legacy Create ticker fields ignored if present
  address = nil,
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

local function wrapRole(role)
  local n = cfg[role]
  if not n or not isInventory(n) then return nil end
  return peripheral.wrap(n), n
end

local function shortName(id)
  id = tostring(id or "")
  return id:match("([^:]+)$") or id
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
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      local m = peripheral.wrap(side)
      if m and type(m.getNamesRemote) == "function" then
        for _, n in ipairs(m.getNamesRemote() or {}) do
          add(n, "via " .. side)
        end
      end
    end
  end
  table.sort(names, function(a, b) return a.name < b.name end)
  return names
end

--------------------------------------------------------------------------------
-- Vault stock / transfer
--------------------------------------------------------------------------------
local function inventoryStock(inv)
  local map = {}
  local list = inv.list() or {}
  for _, detail in pairs(list) do
    if type(detail) == "table" and detail.name then
      local c = tonumber(detail.count) or 0
      if c > 0 then
        map[detail.name] = (map[detail.name] or 0) + c
      end
    end
  end
  return map
end

local function listContents(inv)
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

local function matchStock(stockMap, query)
  query = tostring(query or ""):lower()
  if query == "" then return nil end
  if stockMap[query] then return query, stockMap[query] end
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

--- Push all slots from `from` into peripheral `toName`. Returns moved count.
local function pushAll(from, toName)
  if type(from.pushItems) ~= "function" then return 0, "no pushItems" end
  local moved = 0
  local rows = listContents(from)
  for _, r in ipairs(rows) do
    local left = r.count
    while left > 0 do
      local ok, n = pcall(from.pushItems, toName, r.slot, left)
      n = (ok and tonumber(n)) or 0
      if n <= 0 then break end
      moved = moved + n
      left = left - n
    end
  end
  return moved, nil
end

--- Move `need` of `item` from vault → output. Returns moved count.
local function pullItem(vault, vname, oname, item, need)
  local moved = 0
  while moved < need do
    local list = vault.list() or {}
    local slots = {}
    for slot, detail in pairs(list) do
      if type(detail) == "table" and detail.name == item then
        slots[#slots + 1] = slot
      end
    end
    table.sort(slots)
    if #slots == 0 then break end
    local progressed = false
    for _, slot in ipairs(slots) do
      if moved >= need then break end
      local detail = (vault.list() or {})[slot]
      local have = (type(detail) == "table" and tonumber(detail.count)) or 0
      local want = math.min(need - moved, have)
      if want > 0 then
        local ok, n = pcall(vault.pushItems, oname, slot, want)
        n = (ok and tonumber(n)) or 0
        if n > 0 then
          moved = moved + n
          progressed = true
        end
      end
    end
    if not progressed then break end
  end
  return moved
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function cmdBind(a)
  local role = tostring(a[2] or ""):lower()
  local name = a[3]
  if role ~= "intake" and role ~= "output" and role ~= "vault" then
    print("Usage: bind intake|output|vault <peripheralName|side>")
    return
  end
  if not name then
    print("Usage: bind " .. role .. " <peripheralName|side>")
    return
  end
  if not isInventory(name) then
    print("Not an inventory: " .. tostring(name))
    print("Tip: invs — use a vanilla chest or a modem-linked Create vault.")
    return
  end
  if role == "intake" and (name == cfg.vault or name == cfg.output) then
    print("Intake must be a different chest than vault/output."); return
  end
  if role == "output" and (name == cfg.vault or name == cfg.intake) then
    print("Output must be a different chest than vault/intake."); return
  end
  if role == "vault" and (name == cfg.intake or name == cfg.output) then
    print("Vault must be different from intake/output."); return
  end
  cfg[role] = name
  saveCfg()
  print("Bound " .. role .. " = " .. name)
end

local function cmdInvs()
  print("Inventories:")
  local list = collectInventories()
  if #list == 0 then
    print("  (none)")
    print("Put chests against this PC, or cable a wired modem to the vault.")
    return
  end
  for _, row in ipairs(list) do
    local marks = ""
    if row.name == cfg.intake then marks = marks .. " [intake]" end
    if row.name == cfg.output then marks = marks .. " [output]" end
    if row.name == cfg.vault then marks = marks .. " [vault]" end
    local note = row.note and ("  (" .. row.note .. ")") or ""
    print("  " .. row.name .. marks .. note)
  end
end

local function cmdStatus()
  print("== Storage ATM v" .. VERSION .. " ==")
  print("Mode:   wired modem ↔ vault (no ticker / casino)")
  print("Intake: " .. tostring(cfg.intake or "(unbound)"))
  print("Output: " .. tostring(cfg.output or "(unbound)"))
  print("Vault:  " .. tostring(cfg.vault or "(unbound)"))
end

local function cmdStock(a)
  local vault = wrapRole("vault")
  if not vault then print("Bind vault: bind vault <name|side>"); return end
  local filter = a[2] and table.concat(a, " ", 2):lower() or nil
  local map = inventoryStock(vault)
  local rows = {}
  for name, count in pairs(map) do
    if not filter or name:lower():find(filter, 1, true)
        or shortName(name):lower():find(filter, 1, true) then
      rows[#rows + 1] = { name = name, count = count }
    end
  end
  table.sort(rows, function(x, y)
    if x.count ~= y.count then return x.count > y.count end
    return x.name < y.name
  end)
  print(("Vault stock%s:"):format(filter and (" filter=" .. filter) or ""))
  if #rows == 0 then print("  (none)"); return end
  local limit = math.min(#rows, 40)
  for i = 1, limit do
    local r = rows[i]
    print(("  %6d  %s"):format(r.count, r.name))
  end
  if #rows > limit then
    print(("  … %d more (stock <filter>)"):format(#rows - limit))
  end
end

local function cmdDeposit()
  local intake, iname = wrapRole("intake")
  local vault, vname = wrapRole("vault")
  if not intake then print("Bind intake: bind intake <side|name>"); return end
  if not vault then print("Bind vault: bind vault <side|name>"); return end
  if type(intake.pushItems) ~= "function" then
    print("Intake cannot pushItems."); return
  end

  local rows, total = listContents(intake)
  if total <= 0 then
    print("Intake empty — put items in, then deposit."); return
  end
  print(("Intake (%s) — %d item(s):"):format(iname, total))
  for _, r in ipairs(rows) do
    print(("  %dx %s"):format(r.count, r.name))
  end
  write("Move into vault? (y/N): ")
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then
    print("Cancelled — items left in intake."); return
  end

  local moved, err = pushAll(intake, vname)
  if err then print(err); return end
  local left = select(2, listContents(intake))
  print(("Moved %d item(s) → vault %s."):format(moved, vname))
  if left > 0 then
    print(("Vault full? %d item(s) still in intake."):format(left))
  end
end

local function cmdWithdraw(a)
  local vault, vname = wrapRole("vault")
  local output, oname = wrapRole("output")
  if not vault then print("Bind vault: bind vault <side|name>"); return end
  if not output then print("Bind output: bind output <side|name>"); return end
  if type(vault.pushItems) ~= "function" then
    print("Vault cannot pushItems."); return
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

  local stockMap = inventoryStock(vault)
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
    print("Not in vault: " .. tostring(itemQ))
    return
  end
  local avail = tonumber(availOrHits) or 0
  if avail < count then
    print(("Not enough in vault (have %d, need %d)."):format(avail, count))
    return
  end

  print(("Withdraw %dx %s → output %s"):format(count, item, oname))
  write("Confirm? (y/N): ")
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then
    print("Cancelled."); return
  end

  local moved = pullItem(vault, vname, oname, item, count)
  if moved <= 0 then
    print("Nothing moved — output may be full."); return
  end
  print(("Moved %d/%d → output."):format(moved, count))
  if moved < count then
    print("Partial — output full or vault changed.")
  end
end

local function cmdHelp()
  print([[
Storage ATM — wired modem to vault (no Create ticker).

bind intake|output|vault <side|name>
invs | status
stock [filter]              list vault contents
deposit                     confirm → move intake → vault
withdraw [item] [count]     if vault has enough → vault → output
help | exit
]])
end

--------------------------------------------------------------------------------
loadCfg()
os.setComputerLabel(cfg.label or os.getComputerLabel() or ("StorageATM-" .. os.getComputerID()))

term.clear(); term.setCursorPos(1, 1)
print("== Storage ATM v" .. VERSION .. " ==")
print("Wired modem ↔ vault — no ticker / casino.")
if not cfg.intake then print("bind intake <side>") end
if not cfg.output then print("bind output <side>") end
if not cfg.vault then print("bind vault <name>  (modem-linked Create vault)") end
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
  elseif cmd == "invs" then cmdInvs()
  elseif cmd == "status" then cmdStatus()
  elseif cmd == "stock" or cmd == "list" then cmdStock(a)
  elseif cmd == "deposit" or cmd == "dep" then cmdDeposit()
  elseif cmd == "withdraw" or cmd == "wd" or cmd == "get" then cmdWithdraw(a)
  elseif cmd == "address" or cmd == "addr" then
    print("Address/ticker mode removed — use: bind vault <name>")
  else
    print("Unknown. help")
  end
end
