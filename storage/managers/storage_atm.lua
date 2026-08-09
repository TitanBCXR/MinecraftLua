--[[
  storage/managers/storage_atm.lua  -  Standalone vault ATM (wired modem)
  Titan-Version: 1.2.1

  Solo item ATM. No casino, no Currency Manager, no Create Stock Ticker.
  Moves items over the wired modem network with pushItems / pullItems.

  Hardware (same cable network):
    [I/O chest]    --touching or wired--> [ATM PC]
    [Create vault] --wired modem (right-click to connect) --/

  One chest is both deposit and withdraw tray (`bind chest`).
  Deposit: chest → vault.
  Withdraw: vault → chest; if the chest fills mid-request, wait for the
  player to collect, then continue the next batch.

  Setup:
    invs
    bind chest <side|name>
    bind vault <name>
    deposit | withdraw | stock | status | help
]]

local LOCAL_CFG = "storage_atm.cfg"
local VERSION = "1.2.1"

local cfg = {
  chest = nil,   -- shared deposit + withdraw tray
  vault = nil,
  label = nil,
  -- legacy fields (migrated on load)
  intake = nil,
  output = nil,
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
  if (not cfg.chest or cfg.chest == "") then
    cfg.chest = cfg.intake or cfg.output
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

local function canTransfer(name)
  if not isInventory(name) then return false end
  local w = peripheral.wrap(name)
  return w and (type(w.pushItems) == "function" or type(w.pullItems) == "function")
end

local SIDES = {
  left = true, right = true, front = true, back = true, top = true, bottom = true,
}

local function resolveInventory(ref)
  if not ref or ref == "" then return nil end
  local s = tostring(ref)
  if isInventory(s) then return s end

  local side = s:lower()
  if SIDES[side] and peripheral.isPresent(side) then
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
  for _, name in ipairs(peripheral.getNames()) do
    if isInventory(name) and name:lower():find(want, 1, true) then
      hits[#hits + 1] = name
    end
  end
  -- Also scan modem remotes (some CC builds list them only here).
  for _, sideName in ipairs(peripheral.getNames()) do
    if peripheral.getType(sideName) == "modem" then
      local m = peripheral.wrap(sideName)
      if m and type(m.getNamesRemote) == "function" then
        for _, n in ipairs(m.getNamesRemote() or {}) do
          if isInventory(n) and n:lower():find(want, 1, true) then
            local dup = false
            for _, h in ipairs(hits) do if h == n then dup = true; break end end
            if not dup then hits[#hits + 1] = n end
          end
        end
      end
    end
  end
  if #hits == 1 then return hits[1] end
  if #hits > 1 then return nil, hits end
  return nil
end

local function wrapRole(role)
  local n = cfg[role]
  if role == "chest" and (not n or n == "") then
    n = cfg.intake or cfg.output
  end
  if not n then return nil end
  -- Re-resolve in case modem remotes renamed after reboot.
  local resolved = resolveInventory(n)
  if resolved then n = resolved end
  if not isInventory(n) then return nil end
  return peripheral.wrap(n), n
end

local function chestFreeSlots(inv)
  local size = 27
  if type(inv.size) == "function" then
    local ok, s = pcall(inv.size)
    if ok and tonumber(s) then size = tonumber(s) end
  end
  local list = inv.list() or {}
  local used = 0
  for _ in pairs(list) do used = used + 1 end
  return math.max(0, size - used), size
end

--- Wait until the I/O chest has at least one empty slot (or user cancels).
local function waitForChestSpace(cname)
  print(("Chest full (%s) — collect items."):format(cname))
  print("Waiting for space (auto every 1s, Enter = check, C = cancel)…")
  while true do
    local timer = os.startTimer(1)
    while true do
      local ev, p1 = os.pullEvent()
      if ev == "timer" and p1 == timer then
        break
      elseif ev == "key" and p1 == keys.enter then
        break
      elseif ev == "char" and tostring(p1 or ""):lower() == "c" then
        print("Cancelled remaining withdraw.")
        return false
      end
    end
    local chest = select(1, wrapRole("chest"))
    if chest and select(1, chestFreeSlots(chest)) > 0 then
      print("Space available — continuing…")
      return true
    end
  end
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

local function isSideName(name)
  name = tostring(name or ""):lower()
  return SIDES[name] == true
end

--- Network name usable as a push/pull target. Side names (left/…) only work
--- as the wrapped source on this computer — remotes cannot pullItems("left").
local function networkTargetName(name)
  if not name or isSideName(name) then return nil end
  return name
end

local function pushSlot(fromWrap, fromName, toName, slot, limit)
  if not toName then return 0, "no destination" end
  -- Prefer peripheral.call so side names resolve on THIS computer.
  if fromName and peripheral.isPresent(fromName)
      and type(peripheral.call) == "function" then
    local ok, r
    if limit then
      ok, r = pcall(peripheral.call, fromName, "pushItems", toName, slot, limit)
    else
      ok, r = pcall(peripheral.call, fromName, "pushItems", toName, slot)
    end
    if ok then return tonumber(r) or 0, nil end
    -- fall through to wrap method
  end
  if fromWrap and type(fromWrap.pushItems) == "function" then
    local ok, r = pcall(function()
      if limit then return fromWrap.pushItems(toName, slot, limit) end
      return fromWrap.pushItems(toName, slot)
    end)
    if ok then return tonumber(r) or 0, nil end
    return 0, tostring(r)
  end
  return 0, "no pushItems"
end

local function pullSlot(toWrap, toName, fromName, slot, limit)
  -- Remote inventories cannot see computer side names like "left".
  if not fromName or isSideName(fromName) then
    return 0, nil
  end
  if toName and peripheral.isPresent(toName) and type(peripheral.call) == "function" then
    local ok, r
    if limit then
      ok, r = pcall(peripheral.call, toName, "pullItems", fromName, slot, limit)
    else
      ok, r = pcall(peripheral.call, toName, "pullItems", fromName, slot)
    end
    if ok then return tonumber(r) or 0, nil end
  end
  if toWrap and type(toWrap.pullItems) == "function" then
    local ok, r = pcall(function()
      if limit then return toWrap.pullItems(fromName, slot, limit) end
      return toWrap.pullItems(fromName, slot)
    end)
    if ok then return tonumber(r) or 0, nil end
    return 0, tostring(r)
  end
  return 0, nil
end

--- Move everything from source → dest over the modem network.
local function transferAll(source, sourceName, dest, destName)
  local moved, lastErr = 0, nil
  local destNet = networkTargetName(destName) or destName
  local guard = 0
  while guard < 256 do
    guard = guard + 1
    local okList, list = pcall(function() return source.list() end)
    if not okList or type(list) ~= "table" then
      return moved, lastErr or "chest list failed"
    end
    local slots = {}
    for slot, detail in pairs(list) do
      if type(detail) == "table" and detail.name and (tonumber(detail.count) or 0) > 0 then
        slots[#slots + 1] = slot
      end
    end
    if #slots == 0 then break end
    table.sort(slots)

    local progressed = false
    for _, slot in ipairs(slots) do
      local n, err = pushSlot(source, sourceName, destNet, slot, nil)
      if err then lastErr = err end
      if n <= 0 then
        local n2, err2 = pullSlot(dest, destName, sourceName, slot, nil)
        if err2 then lastErr = err2 end
        n = n2
      end
      if n > 0 then
        moved = moved + n
        progressed = true
      end
    end
    if not progressed then
      if moved <= 0 and isSideName(sourceName) then
        lastErr = (lastErr and (lastErr .. " | ") or "")
          .. "Chest is bound as side '" .. sourceName
          .. "'. Put a wired modem on the chest (connect it), then: bind chest <name from invs>"
      elseif moved <= 0 and not lastErr then
        lastErr = "Vault accepted 0 items (full, filtered, or not linked on this cable)"
      end
      break
    end
  end
  return moved, lastErr
end

--- Move `need` of `item` from vault → chest. Returns moved count.
local function transferItem(vault, vname, chest, cname, item, need)
  local moved, lastErr = 0, nil
  local chestNet = networkTargetName(cname) or cname
  local guard = 0
  while moved < need and guard < 256 do
    guard = guard + 1
    local okList, list = pcall(function() return vault.list() end)
    if not okList or type(list) ~= "table" then break end
    local slots = {}
    for slot, detail in pairs(list) do
      if type(detail) == "table" and detail.name == item
          and (tonumber(detail.count) or 0) > 0 then
        slots[#slots + 1] = { slot = slot, count = tonumber(detail.count) or 0 }
      end
    end
    if #slots == 0 then break end
    table.sort(slots, function(a, b) return a.slot < b.slot end)

    local progressed = false
    for _, row in ipairs(slots) do
      if moved >= need then break end
      local want = math.min(need - moved, row.count)
      -- Push from vault to chest (chest may be side name — OK as push target on this PC).
      local n, err = pushSlot(vault, vname, chestNet, row.slot, want)
      if (not n or n <= 0) and isSideName(cname) then
        -- Side-named chest: push target must be the side string on this computer.
        n, err = pushSlot(vault, vname, cname, row.slot, want)
      end
      if err then lastErr = err end
      if n <= 0 then
        local n2, err2 = pullSlot(chest, cname, vname, row.slot, want)
        if err2 then lastErr = err2 end
        n = n2
      end
      if n > 0 then
        moved = moved + n
        progressed = true
      end
    end
    if not progressed then break end
  end
  return moved, lastErr
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function cmdBind(a)
  local role = tostring(a[2] or ""):lower()
  local ref = a[3]
  -- `bind left` → chest; `bind chest left` / `bind vault name`
  if role ~= "chest" and role ~= "vault" and role ~= "intake" and role ~= "output"
      and role ~= "io" then
    if a[2] and not a[3] then
      ref = a[2]
      role = "chest"
    else
      print("Usage: bind chest|vault <peripheralName|side>")
      print("       bind <side>     (same as bind chest <side>)")
      return
    end
  end
  if role == "intake" or role == "output" or role == "io" then role = "chest" end
  if not ref then
    print("Usage: bind " .. role .. " <peripheralName|side>")
    return
  end
  local name, hits = resolveInventory(ref)
  if not name then
    if type(hits) == "table" then
      print("Multiple matches for '" .. ref .. "':")
      for _, h in ipairs(hits) do print("  " .. h) end
      return
    end
    print("Not an inventory: " .. tostring(ref))
    print("Run invs — right-click the vault modem until it connects.")
    return
  end
  if not canTransfer(name) then
    print("Inventory has no pushItems/pullItems: " .. name)
    return
  end
  if role == "chest" and name == cfg.vault then
    print("Chest must be different from the vault."); return
  end
  if role == "vault" and name == (cfg.chest or cfg.intake or cfg.output) then
    print("Vault must be different from the I/O chest."); return
  end
  cfg[role] = name
  if role == "chest" then
    cfg.intake = name
    cfg.output = name
  end
  saveCfg()
  print("Bound " .. role .. " = " .. name)
end

local function cmdInvs()
  print("Inventories:")
  local list = collectInventories()
  if #list == 0 then
    print("  (none)")
    print("Put a chest against this PC, or cable a wired modem to the vault.")
    return
  end
  local chestName = cfg.chest or cfg.intake or cfg.output
  for _, row in ipairs(list) do
    local marks = ""
    if row.name == chestName then marks = marks .. " [chest]" end
    if row.name == cfg.vault then marks = marks .. " [vault]" end
    local note = row.note and ("  (" .. row.note .. ")") or ""
    print("  " .. row.name .. marks .. note)
  end
end

local function cmdStatus()
  print("== Storage ATM v" .. VERSION .. " ==")
  print("Mode:   one I/O chest + modem vault")
  local function line(role, label)
    local w, n = wrapRole(role)
    local stored = cfg[role] or (role == "chest" and (cfg.intake or cfg.output)) or nil
    if not stored then return label .. ": (unbound)" end
    if not w then return label .. ": " .. tostring(stored) .. " MISSING" end
    return label .. ": " .. tostring(n) .. " OK"
  end
  print(line("chest", "Chest"))
  print(line("vault", "Vault"))
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
  local chest, cname = wrapRole("chest")
  local vault, vname = wrapRole("vault")
  if not chest then print("Bind chest: bind chest <side|name>"); return end
  if not vault then print("Bind vault: bind vault <name>  (from invs)"); return end
  if cname == vname then
    print("Chest and vault are the same peripheral — rebind."); return
  end
  if type(chest.pushItems) ~= "function" and type(vault.pullItems) ~= "function" then
    print("Neither chest.pushItems nor vault.pullItems available.")
    return
  end

  local rows, total = listContents(chest)
  if total <= 0 then
    print("Chest empty — put items in, then deposit."); return
  end
  print(("Chest (%s) — %d item(s):"):format(cname, total))
  for _, r in ipairs(rows) do
    print(("  %dx %s"):format(r.count, r.name))
  end
  print(("Target vault: %s"):format(vname))
  write("Move into vault over modem? (y/N): ")
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then
    print("Cancelled — items left in chest."); return
  end

  local moved, err = transferAll(chest, cname, vault, vname)
  local left = select(2, listContents(chest))
  print(("Moved %d item(s) → vault %s."):format(moved, vname))
  if moved <= 0 then
    print("Nothing transferred.")
    if err then print("Last error: " .. tostring(err)) end
    print("Check: vault modem connected (right-click), same cable as ATM,")
    print("       and bind vault to the name shown in invs.")
  elseif left > 0 then
    print(("Partial — %d item(s) still in chest (vault full?)."):format(left))
  end
end

local function cmdWithdraw(a)
  local vault, vname = wrapRole("vault")
  local chest, cname = wrapRole("chest")
  if not vault then print("Bind vault: bind vault <name>"); return end
  if not chest then print("Bind chest: bind chest <side|name>"); return end
  if vname == cname then
    print("Vault and chest are the same peripheral — rebind."); return
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

  print(("Withdraw %dx %s → chest %s"):format(count, item, cname))
  print("If the chest fills, collect items — withdraw will continue.")
  write("Confirm? (y/N): ")
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then
    print("Cancelled."); return
  end

  local moved, lastErr = 0, nil
  while moved < count do
    chest, cname = wrapRole("chest")
    vault, vname = wrapRole("vault")
    if not chest or not vault then
      print("Chest/vault missing mid-withdraw."); break
    end

    local need = count - moved
    local n, err = transferItem(vault, vname, chest, cname, item, need)
    lastErr = err or lastErr
    if n > 0 then
      moved = moved + n
      print(("  … %d/%d in chest (+%d)"):format(moved, count, n))
    else
      local free = select(1, chestFreeSlots(chest))
      if free > 0 then
        print("Transfer stalled with free slots — check modem/vault.")
        if lastErr then print("Last error: " .. tostring(lastErr)) end
        break
      end
      if not waitForChestSpace(cname) then break end
    end
  end

  if moved <= 0 then
    print("Nothing moved — chest full or modem path failed.")
    if lastErr then print("Last error: " .. tostring(lastErr)) end
    return
  end
  print(("Done: moved %d/%d → chest."):format(moved, count))
  if moved < count then
    print(("Stopped early — %d still in vault."):format(count - moved))
  end
end

local function cmdHelp()
  print([[
Storage ATM — one I/O chest + modem vault.

bind chest <side|name>      deposit + withdraw tray (same chest)
bind <side>                 same as bind chest <side>
bind vault <name>
invs | status
stock [filter]              list vault contents
deposit                     confirm → chest → vault
withdraw [item] [count]     vault → chest (waits if chest full)
help | exit
]])
end

--------------------------------------------------------------------------------
loadCfg()
os.setComputerLabel(cfg.label or os.getComputerLabel() or ("StorageATM-" .. os.getComputerID()))

term.clear(); term.setCursorPos(1, 1)
print("== Storage ATM v" .. VERSION .. " ==")
print("One I/O chest + vault over wired modem.")
if not (cfg.chest or cfg.intake or cfg.output) then print("bind chest <side>") end
if not cfg.vault then print("bind vault <name from invs>") end
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
