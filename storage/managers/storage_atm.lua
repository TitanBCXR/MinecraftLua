--[[
  storage/managers/storage_atm.lua  -  Standalone vault ATM (wired modem)
  Titan-Version: 1.4.0

  Solo item ATM. No casino / Currency Manager / Stock Ticker.
  One I/O chest + one or more Create vaults on the same wired modem network,
  treated as a single linked stock pool.

  Hardware:
    [I/O chest]     --touching or wired--> [ATM PC]
    [Vault A/B/…]   --wired modems-------/

  Item names display without mod id (oak_log not minecraft:oak_log).
  Withdraw supports multiple items; Tab autocompletes item names.

  Setup:
    invs
    bind chest <side|name>
    bind vault <name>          -- add one vault (repeat)
    link                       -- auto-add every create:*vault* on the network
    unbind vault <name|#|all>
    deposit | withdraw | stock | vaults | status | help
]]

local LOCAL_CFG = "storage_atm.cfg"
local VERSION = "1.4.0"

local cfg = {
  chest = nil,
  vaults = {},   -- list of peripheral names
  label = nil,
  -- legacy
  vault = nil,
  intake = nil,
  output = nil,
  address = nil,
}

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
  if (not cfg.chest or cfg.chest == "") then
    cfg.chest = cfg.intake or cfg.output
  end
  if type(cfg.vaults) ~= "table" then cfg.vaults = {} end
  -- Migrate single vault → list
  if cfg.vault and cfg.vault ~= "" then
    local found = false
    for _, n in ipairs(cfg.vaults) do
      if n == cfg.vault then found = true; break end
    end
    if not found then cfg.vaults[#cfg.vaults + 1] = cfg.vault end
  end
end

local function saveCfg()
  -- Keep legacy field synced to first vault for old tools/configs.
  cfg.vault = cfg.vaults[1]
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

local function isSideName(name)
  return SIDES[tostring(name or ""):lower()] == true
end

local function shortName(id)
  id = tostring(id or "")
  return id:match("([^:]+)$") or id
end

local function modId(id)
  id = tostring(id or "")
  local m = id:match("^([^:]+):")
  return m
end

--- Pretty label: strip namespace. If two mods share the same item id, append (mod).
local function displayName(full, stockMap)
  local short = shortName(full)
  if type(stockMap) ~= "table" then return short end
  local collisions = 0
  for name in pairs(stockMap) do
    if shortName(name) == short then collisions = collisions + 1 end
  end
  if collisions > 1 then
    return short .. " (" .. (modId(full) or "?") .. ")"
  end
  return short
end

local function itemCompleteFn(stockMap)
  local labels = {}
  for full in pairs(stockMap) do
    labels[#labels + 1] = displayName(full, stockMap)
  end
  table.sort(labels)
  return function(line)
    line = tostring(line or "")
    local partial = line:match("(%S*)$") or line
    local pl = partial:lower()
    local out, seen = {}, {}
    for _, lab in ipairs(labels) do
      if pl == "" or lab:lower():sub(1, #pl) == pl then
        local suffix = lab:sub(#partial + 1)
        if suffix ~= "" and not seen[suffix] then
          seen[suffix] = true
          out[#out + 1] = suffix
        elseif pl ~= "" and lab:lower() == pl and not seen[""] then
          -- exact match already typed; no suffix
        end
      end
    end
    return out
  end
end

local function readItemName(stockMap, prompt)
  write(prompt or "Item: ")
  return read(nil, nil, itemCompleteFn(stockMap))
end

local function looksLikeVault(name)
  local low = tostring(name or ""):lower()
  return low:find("vault", 1, true) ~= nil
end

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
  local function consider(n)
    if isInventory(n) and n:lower():find(want, 1, true) then
      for _, h in ipairs(hits) do if h == n then return end end
      hits[#hits + 1] = n
    end
  end
  for _, name in ipairs(peripheral.getNames()) do consider(name) end
  for _, sideName in ipairs(peripheral.getNames()) do
    if peripheral.getType(sideName) == "modem" then
      local m = peripheral.wrap(sideName)
      if m and type(m.getNamesRemote) == "function" then
        for _, n in ipairs(m.getNamesRemote() or {}) do consider(n) end
      end
    end
  end
  if #hits == 1 then return hits[1] end
  if #hits > 1 then return nil, hits end
  return nil
end

local function wrapInv(name)
  if not name then return nil end
  local resolved = resolveInventory(name)
  if resolved then name = resolved end
  if not isInventory(name) then return nil end
  return peripheral.wrap(name), name
end

local function wrapChest()
  local n = cfg.chest or cfg.intake or cfg.output
  return wrapInv(n)
end

local function vaultSet()
  local s = {}
  for _, n in ipairs(cfg.vaults or {}) do s[n] = true end
  return s
end

local function listVaults()
  local out = {}
  for _, name in ipairs(cfg.vaults or {}) do
    local w, n = wrapInv(name)
    if w and n then
      out[#out + 1] = { wrap = w, name = n, ok = true }
    else
      out[#out + 1] = { wrap = nil, name = name, ok = false }
    end
  end
  return out
end

local function liveVaults()
  local out = {}
  for _, v in ipairs(listVaults()) do
    if v.ok then out[#out + 1] = v end
  end
  return out
end

local function addVault(name)
  for _, n in ipairs(cfg.vaults) do
    if n == name then return false, "already linked" end
  end
  cfg.vaults[#cfg.vaults + 1] = name
  saveCfg()
  return true
end

local function removeVault(ref)
  ref = tostring(ref or "")
  if ref:lower() == "all" then
    local n = #cfg.vaults
    cfg.vaults = {}
    saveCfg()
    return n
  end
  local idx = tonumber(ref)
  if idx and cfg.vaults[idx] then
    table.remove(cfg.vaults, idx)
    saveCfg()
    return 1
  end
  for i, n in ipairs(cfg.vaults) do
    if n == ref or n:lower() == ref:lower() then
      table.remove(cfg.vaults, i)
      saveCfg()
      return 1
    end
  end
  return 0
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

local function waitForChestSpace(cname)
  print(("Chest full (%s) — collect items."):format(cname))
  print("Waiting for space (auto every 1s, Enter = check, C = cancel)…")
  while true do
    local timer = os.startTimer(1)
    while true do
      local ev, p1 = os.pullEvent()
      if ev == "timer" and p1 == timer then break
      elseif ev == "key" and p1 == keys.enter then break
      elseif ev == "char" and tostring(p1 or ""):lower() == "c" then
        print("Cancelled remaining withdraw.")
        return false
      end
    end
    local chest = select(1, wrapChest())
    if chest and select(1, chestFreeSlots(chest)) > 0 then
      print("Space available — continuing…")
      return true
    end
  end
end

local function collectInventories()
  local seen, names = {}, {}
  local function add(n, note)
    if not n or seen[n] or not isInventory(n) then return end
    seen[n] = true
    names[#names + 1] = { name = n, note = note }
  end
  for _, n in ipairs(peripheral.getNames()) do add(n, nil) end
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
-- Stock / transfer
--------------------------------------------------------------------------------
local function inventoryStock(inv)
  local map = {}
  local list = inv.list() or {}
  for _, detail in pairs(list) do
    if type(detail) == "table" and detail.name then
      local c = tonumber(detail.count) or 0
      if c > 0 then map[detail.name] = (map[detail.name] or 0) + c end
    end
  end
  return map
end

local function poolStock()
  local map = {}
  for _, v in ipairs(liveVaults()) do
    for item, count in pairs(inventoryStock(v.wrap)) do
      map[item] = (map[item] or 0) + count
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
  query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if query == "" then return nil end
  local q = query:lower()
  -- Strip accidental namespace if user typed minecraft:foo
  local qBare = shortName(q):lower()
  -- Exact full id
  if stockMap[query] then return query, stockMap[query] end
  for name, count in pairs(stockMap) do
    if name:lower() == q then return name, count end
  end
  -- Exact short name / display label
  local hits = {}
  for name, count in pairs(stockMap) do
    local bare = shortName(name):lower()
    local disp = displayName(name, stockMap):lower()
    if bare == q or bare == qBare or disp == q or disp == qBare then
      hits[#hits + 1] = { name = name, count = count }
    end
  end
  if #hits == 1 then return hits[1].name, hits[1].count end
  if #hits > 1 then return nil, hits end
  -- Prefix / substring on short name
  for name, count in pairs(stockMap) do
    local bare = shortName(name):lower()
    local disp = displayName(name, stockMap):lower()
    if bare:sub(1, #qBare) == qBare or disp:sub(1, #q) == q
        or bare:find(qBare, 1, true) or disp:find(q, 1, true) then
      hits[#hits + 1] = { name = name, count = count }
    end
  end
  table.sort(hits, function(a, b) return a.name < b.name end)
  if #hits == 1 then return hits[1].name, hits[1].count end
  if #hits > 1 then return nil, hits end
  return nil, nil
end

--- Parse "item count item count …" into { {full, count, label}, … }
local function parseWithdrawArgs(args, stockMap)
  -- args is list of words after "withdraw"
  local reqs, i = {}, 1
  while i <= #args do
    local token = args[i]
    local n = tonumber(token)
    if n and reqs[#reqs] and not reqs[#reqs].count then
      reqs[#reqs].count = math.floor(n)
      i = i + 1
    else
      local full, availOrHits = matchStock(stockMap, token)
      if type(availOrHits) == "table" then
        return nil, "ambiguous:" .. token, availOrHits
      end
      if not full then
        return nil, "unknown:" .. token
      end
      local count = tonumber(args[i + 1])
      if count then
        reqs[#reqs + 1] = {
          item = full,
          count = math.floor(count),
          label = displayName(full, stockMap),
          avail = stockMap[full] or 0,
        }
        i = i + 2
      else
        reqs[#reqs + 1] = {
          item = full,
          count = nil, -- fill later = all
          label = displayName(full, stockMap),
          avail = stockMap[full] or 0,
        }
        i = i + 1
      end
    end
  end
  for _, r in ipairs(reqs) do
    if not r.count or r.count <= 0 then r.count = r.avail end
  end
  return reqs
end

local function interactiveWithdrawList(stockMap)
  print("Add items (Tab = autocomplete). Blank item name when done.")
  local reqs = {}
  while true do
    local itemQ = readItemName(stockMap, "Item: ")
    if not itemQ or not itemQ:match("%S") then break end
    local full, availOrHits = matchStock(stockMap, itemQ)
    if type(availOrHits) == "table" then
      print("Multiple matches — be more specific:")
      for i = 1, math.min(#availOrHits, 12) do
        local h = availOrHits[i]
        print(("  %6d  %s"):format(h.count, displayName(h.name, stockMap)))
      end
    elseif not full then
      print("Not in stock: " .. tostring(itemQ))
    else
      local avail = stockMap[full] or 0
      write(("Count [all=%d]: "):format(avail))
      local cLine = read()
      local count = tonumber(cLine)
      if not cLine or not cLine:match("%S") then count = avail end
      count = math.floor(tonumber(count) or 0)
      if count <= 0 then
        print("Skipped (need positive count).")
      elseif count > avail then
        print(("Only %d available — skipped."):format(avail))
      else
        reqs[#reqs + 1] = {
          item = full,
          count = count,
          label = displayName(full, stockMap),
          avail = avail,
        }
        print(("  + %dx %s"):format(count, displayName(full, stockMap)))
      end
    end
  end
  return reqs
end

local function networkTargetName(name)
  if not name or isSideName(name) then return nil end
  return name
end

local function pushSlot(fromWrap, fromName, toName, slot, limit)
  if not toName then return 0, "no destination" end
  if fromName and peripheral.isPresent(fromName) and type(peripheral.call) == "function" then
    local ok, r
    if limit then
      ok, r = pcall(peripheral.call, fromName, "pushItems", toName, slot, limit)
    else
      ok, r = pcall(peripheral.call, fromName, "pushItems", toName, slot)
    end
    if ok then return tonumber(r) or 0, nil end
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
  if not fromName or isSideName(fromName) then return 0, nil end
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

--- Deposit: push chest slots into any linked vault that will take them.
local function transferAllToPool(source, sourceName)
  local moved, lastErr = 0, nil
  local vaults = liveVaults()
  if #vaults == 0 then return 0, "no live vaults" end

  local guard = 0
  while guard < 512 do
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
      local n = 0
      for _, v in ipairs(vaults) do
        local destNet = networkTargetName(v.name) or v.name
        local got, err = pushSlot(source, sourceName, destNet, slot, nil)
        if err then lastErr = err end
        if got <= 0 then
          local got2, err2 = pullSlot(v.wrap, v.name, sourceName, slot, nil)
          if err2 then lastErr = err2 end
          got = got2
        end
        if got > 0 then
          n = n + got
          progressed = true
          -- Slot may still have leftovers; try next vaults / next loop.
          break
        end
      end
      if n > 0 then moved = moved + n end
    end

    if not progressed then
      if moved <= 0 and isSideName(sourceName) then
        lastErr = (lastErr and (lastErr .. " | ") or "")
          .. "Chest is side '" .. sourceName
          .. "'. Modem-link the chest, then: bind chest <name from invs>"
      elseif moved <= 0 and not lastErr then
        lastErr = "All vaults accepted 0 items (full or not linked)"
      end
      break
    end
    vaults = liveVaults()
  end
  return moved, lastErr
end

--- Withdraw one item type from the pool into the chest.
local function transferItemFromPool(chest, cname, item, need)
  local moved, lastErr = 0, nil
  local chestNet = networkTargetName(cname) or cname
  local guard = 0
  while moved < need and guard < 512 do
    guard = guard + 1
    local vaults = liveVaults()
    if #vaults == 0 then break end

    local progressed = false
    for _, v in ipairs(vaults) do
      if moved >= need then break end
      local okList, list = pcall(function() return v.wrap.list() end)
      if okList and type(list) == "table" then
        local slots = {}
        for slot, detail in pairs(list) do
          if type(detail) == "table" and detail.name == item
              and (tonumber(detail.count) or 0) > 0 then
            slots[#slots + 1] = {
              slot = slot, count = tonumber(detail.count) or 0,
            }
          end
        end
        table.sort(slots, function(a, b) return a.slot < b.slot end)
        for _, row in ipairs(slots) do
          if moved >= need then break end
          local want = math.min(need - moved, row.count)
          local n, err = pushSlot(v.wrap, v.name, chestNet, row.slot, want)
          if (not n or n <= 0) and isSideName(cname) then
            n, err = pushSlot(v.wrap, v.name, cname, row.slot, want)
          end
          if err then lastErr = err end
          if n <= 0 then
            local n2, err2 = pullSlot(chest, cname, v.name, row.slot, want)
            if err2 then lastErr = err2 end
            n = n2
          end
          if n > 0 then
            moved = moved + n
            progressed = true
          end
        end
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
  if role ~= "chest" and role ~= "vault" and role ~= "intake" and role ~= "output"
      and role ~= "io" then
    if a[2] and not a[3] then
      ref = a[2]
      role = "chest"
    else
      print("Usage: bind chest|vault <peripheralName|side>")
      print("       bind <side>     (= bind chest)")
      print("       link            auto-add all vaults on the network")
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
    return
  end
  if not canTransfer(name) then
    print("Inventory has no pushItems/pullItems: " .. name)
    return
  end

  local chestName = cfg.chest or cfg.intake or cfg.output
  if role == "chest" then
    if vaultSet()[name] then
      print("That peripheral is already a linked vault."); return
    end
    cfg.chest = name
    cfg.intake = name
    cfg.output = name
    saveCfg()
    print("Bound chest = " .. name)
    return
  end

  -- vault
  if name == chestName then
    print("Vault must be different from the I/O chest."); return
  end
  local ok, err = addVault(name)
  if not ok then
    print("Vault " .. name .. " — " .. tostring(err))
  else
    print("Linked vault = " .. name .. ("  (pool size %d)"):format(#cfg.vaults))
  end
end

local function cmdUnbind(a)
  local role = tostring(a[2] or ""):lower()
  local ref = a[3]
  if role ~= "vault" then
    print("Usage: unbind vault <name|#|all>")
    return
  end
  if not ref then
    print("Usage: unbind vault <name|#|all>")
    return
  end
  local n = removeVault(ref)
  print(n > 0 and ("Removed " .. n .. " vault(s). Pool=" .. #cfg.vaults)
    or "No matching vault.")
end

local function cmdLink()
  local chestName = cfg.chest or cfg.intake or cfg.output
  local added = 0
  for _, row in ipairs(collectInventories()) do
    local n = row.name
    if looksLikeVault(n) and n ~= chestName and canTransfer(n) then
      local ok = addVault(n)
      if ok then
        added = added + 1
        print("  + " .. n)
      end
    end
  end
  if added == 0 then
    print("No new vaults found (names containing 'vault').")
    print("Or: bind vault <name> for each one from invs.")
  else
    print(("Linked %d vault(s). Pool size=%d"):format(added, #cfg.vaults))
  end
end

local function cmdVaults()
  print(("Vault pool (%d):"):format(#cfg.vaults))
  if #cfg.vaults == 0 then
    print("  (none) — bind vault <name>  or  link")
    return
  end
  for i, v in ipairs(listVaults()) do
    local mark = v.ok and "OK" or "MISSING"
    print(("  %d) %s  [%s]"):format(i, v.name, mark))
  end
end

local function cmdInvs()
  print("Inventories:")
  local list = collectInventories()
  if #list == 0 then
    print("  (none)")
    return
  end
  local chestName = cfg.chest or cfg.intake or cfg.output
  local vset = vaultSet()
  for _, row in ipairs(list) do
    local marks = ""
    if row.name == chestName then marks = marks .. " [chest]" end
    if vset[row.name] then marks = marks .. " [vault]" end
    local note = row.note and ("  (" .. row.note .. ")") or ""
    print("  " .. row.name .. marks .. note)
  end
end

local function cmdStatus()
  print("== Storage ATM v" .. VERSION .. " ==")
  print("Mode:   linked vault pool over wired modem")
  local chest, cname = wrapChest()
  if not (cfg.chest or cfg.intake or cfg.output) then
    print("Chest:  (unbound)")
  elseif not chest then
    print("Chest:  " .. tostring(cfg.chest) .. " MISSING")
  else
    print("Chest:  " .. cname .. " OK")
  end
  local live = liveVaults()
  print(("Vaults: %d linked, %d online"):format(#cfg.vaults, #live))
  for i, v in ipairs(listVaults()) do
    print(("  %d) %s %s"):format(i, v.name, v.ok and "OK" or "MISSING"))
  end
end

local function cmdStock(a)
  local vaults = liveVaults()
  if #vaults == 0 then
    print("No vaults online. bind vault <name>  or  link")
    return
  end
  local filter = a[2] and table.concat(a, " ", 2):lower() or nil
  local map = poolStock()
  local rows = {}
  for name, count in pairs(map) do
    local lab = displayName(name, map)
    if not filter or name:lower():find(filter, 1, true)
        or lab:lower():find(filter, 1, true)
        or shortName(name):lower():find(filter, 1, true) then
      rows[#rows + 1] = { name = name, label = lab, count = count }
    end
  end
  table.sort(rows, function(x, y)
    if x.count ~= y.count then return x.count > y.count end
    return x.label < y.label
  end)
  print(("Linked stock (%d vaults)%s:"):format(
    #vaults, filter and (" filter=" .. filter) or ""))
  if #rows == 0 then print("  (none)"); return end
  local limit = math.min(#rows, 40)
  for i = 1, limit do
    local r = rows[i]
    print(("  %6d  %s"):format(r.count, r.label))
  end
  if #rows > limit then
    print(("  … %d more (stock <filter>)"):format(#rows - limit))
  end
end

local function cmdDeposit()
  local chest, cname = wrapChest()
  local vaults = liveVaults()
  if not chest then print("Bind chest: bind chest <side|name>"); return end
  if #vaults == 0 then print("Link vaults: bind vault <name>  or  link"); return end
  for _, v in ipairs(vaults) do
    if v.name == cname then
      print("Chest is also listed as a vault — unbind it from the pool."); return
    end
  end

  local rows, total = listContents(chest)
  if total <= 0 then
    print("Chest empty — put items in, then deposit."); return
  end
  -- Aggregate chest by short name for display
  local byFull = {}
  for _, r in ipairs(rows) do
    byFull[r.name] = (byFull[r.name] or 0) + r.count
  end
  print(("Chest (%s) — %d item(s):"):format(cname, total))
  for name, count in pairs(byFull) do
    print(("  %dx %s"):format(count, displayName(name, byFull)))
  end
  print(("Target: %d linked vault(s)"):format(#vaults))
  write("Move into vault pool? (y/N): ")
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then
    print("Cancelled — items left in chest."); return
  end

  local moved, err = transferAllToPool(chest, cname)
  local left = select(2, listContents(chest))
  print(("Moved %d item(s) → vault pool."):format(moved))
  if moved <= 0 then
    print("Nothing transferred.")
    if err then print("Last error: " .. tostring(err)) end
  elseif left > 0 then
    print(("Partial — %d item(s) still in chest (pool full?)."):format(left))
  end
end

local function fulfillOne(item, count, label)
  local moved, lastErr = 0, nil
  while moved < count do
    local chest, cname = wrapChest()
    if not chest then return moved, "Chest missing mid-withdraw." end
    if #liveVaults() == 0 then return moved, "No vaults online." end

    local need = count - moved
    local n, err = transferItemFromPool(chest, cname, item, need)
    lastErr = err or lastErr
    if n > 0 then
      moved = moved + n
      print(("  … %s %d/%d (+%d)"):format(label, moved, count, n))
    else
      local free = select(1, chestFreeSlots(chest))
      if free > 0 then
        return moved, lastErr or "Transfer stalled"
      end
      if not waitForChestSpace(cname) then
        return moved, "cancelled"
      end
    end
  end
  return moved, lastErr
end

local function cmdWithdraw(a)
  local chest, cname = wrapChest()
  local vaults = liveVaults()
  if not chest then print("Bind chest: bind chest <side|name>"); return end
  if #vaults == 0 then print("Link vaults first."); return end

  local stockMap = poolStock()
  local reqs

  -- Words after "withdraw"
  local args = {}
  for i = 2, #a do args[#args + 1] = a[i] end

  if #args == 0 then
    reqs = interactiveWithdrawList(stockMap)
  else
    local parsed, err, hits = parseWithdrawArgs(args, stockMap)
    if not parsed then
      if err and err:sub(1, 9) == "ambiguous" then
        print("Multiple matches — be more specific:")
        for i = 1, math.min(#(hits or {}), 12) do
          local h = hits[i]
          print(("  %6d  %s"):format(h.count, displayName(h.name, stockMap)))
        end
      else
        print("Unknown item: " .. tostring(err and err:match("^unknown:(.*)") or args[1]))
      end
      return
    end
    reqs = parsed
    for _, r in ipairs(reqs) do
      if r.count > r.avail then
        print(("Not enough %s (have %d, need %d)."):format(r.label, r.avail, r.count))
        return
      end
    end
  end

  if not reqs or #reqs == 0 then
    print("Nothing to withdraw."); return
  end

  print("Withdraw list:")
  for _, r in ipairs(reqs) do
    print(("  %dx %s"):format(r.count, r.label))
  end
  print("If the chest fills, collect items — withdraw will continue.")
  write("Confirm all? (y/N): ")
  local ans = tostring(read() or ""):lower()
  if ans ~= "y" and ans ~= "yes" then
    print("Cancelled."); return
  end

  local totalMoved = 0
  for _, r in ipairs(reqs) do
    print(("— %s"):format(r.label))
    local moved, err = fulfillOne(r.item, r.count, r.label)
    totalMoved = totalMoved + moved
    if moved < r.count then
      print(("  stopped at %d/%d (%s)"):format(moved, r.count, tostring(err or "short")))
      if err == "cancelled" then break end
    else
      print(("  done %d"):format(moved))
    end
  end
  print(("Finished. Moved %d item(s) total → chest."):format(totalMoved))
end

local function cmdHelp()
  print([[
Storage ATM — linked multi-vault pool + one I/O chest.

bind chest <side|name>
bind vault <name>           add vault to the pool (repeat)
link                        auto-add every *vault* on the network
unbind vault <name|#|all>
vaults | invs | status
stock [filter]              combined stock (short names, no minecraft:)
deposit                     chest → any vault with space
withdraw                    multi-item wizard (Tab = autocomplete)
withdraw <item> <n> [...]   e.g. withdraw oak_log 64 cobblestone 128
help | exit
]])
end

--------------------------------------------------------------------------------
loadCfg()
os.setComputerLabel(cfg.label or os.getComputerLabel() or ("StorageATM-" .. os.getComputerID()))

term.clear(); term.setCursorPos(1, 1)
print("== Storage ATM v" .. VERSION .. " ==")
print("Linked vault pool over wired modem.")
if not (cfg.chest or cfg.intake or cfg.output) then print("bind chest <side>") end
if #cfg.vaults == 0 then print("bind vault <name>  or  link") end
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
  elseif cmd == "unbind" then cmdUnbind(a)
  elseif cmd == "link" then cmdLink()
  elseif cmd == "vaults" then cmdVaults()
  elseif cmd == "invs" then cmdInvs()
  elseif cmd == "status" then cmdStatus()
  elseif cmd == "stock" or cmd == "list" then cmdStock(a)
  elseif cmd == "deposit" or cmd == "dep" then cmdDeposit()
  elseif cmd == "withdraw" or cmd == "wd" or cmd == "get" then cmdWithdraw(a)
  elseif cmd == "address" or cmd == "addr" then
    print("Use: bind vault <name>  or  link")
  else
    print("Unknown. help")
  end
end
