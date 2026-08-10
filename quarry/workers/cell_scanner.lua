--[[
  quarry/workers/cell_scanner.lua  -  Per-cell Geo Scanner turtle
  Titan-Version: 1.0.5

  Places an Advanced Peripherals Geo Scanner at the center of each free
  unscanned quarry cell, runs scan(radius), reports solids to the site board,
  briefly swaps to pickaxe only to dig the scanner up, then modem back on
  before moving to the next cell.

  Setup (same depot as miners):
    * Stand at quarry origin 0,0,0 facing into the mine (+Z)
    * Fuel chest LEFT → slots 16 + 15 (two stacks coal/charcoal)
    * Slot 14 = pickaxe (retrieve only)
    * Slot 13 = Geo Scanner item
    * Wireless modem stays on RIGHT most of the time (parks in cargo 1-12
      only while the pickaxe is briefly equipped)
    * Site board online; `origin` set on the board

  Tooling:
    * RIGHT = modem for travel, place, scan, report, move to next cell
    * RIGHT = pickaxe ONLY while digging up the placed Geo Scanner
    * LEFT upgrade is never touched

  Commands:
    join | scan | stop | home | refuel | setup | status | help | exit

  Site:
    requirescan on   — miners only claim cells this bot has mapped
    clearscans       — wipe maps

  Run:  quarry/workers/cell_scanner
]]

local CFG = "cell_scanner.cfg"
local FUEL_SLOT = 16       -- primary fuel stack
local FUEL_SLOT2 = 15      -- second fuel stack
local PICK_SLOT = 14
local SCANNER_SLOT = 13
local CARGO_MAX = 12       -- slots 1-12: modem park / misc (never fuel/tools)
local PICK_SIDE = "right"
local FUEL_KEEP = 64       -- per fuel slot
local MIN_FUEL = 200
local HOME_MARGIN = 24
local VERSION = "1.0.5"
local PROTO = "titan_quarry"
local NET = "titan_net"

local STOP = false
local siteId = nil
local pos = { x = 0, y = 0, z = 0 }
local facing = 0 -- 0=+Z, 1=+X, 2=-Z, 3=-X
local cfg = { setupDone = false }
local activeScan = nil

local function saveCfg()
  local f = fs.open(CFG, "w")
  if f then f.write(textutils.serialize(cfg)); f.close() end
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
end

local function openModem()
  for _, side in ipairs(redstone.getSides()) do
    local t = peripheral.getType(side)
    if t == "modem" or t == "wireless_modem" then
      if not rednet.isOpen(side) then pcall(rednet.open, side) end
      return true
    end
  end
  return false
end

local function isModemItem(detail)
  if type(detail) ~= "table" then return false end
  local n = tostring(detail.name or ""):lower()
  if n == "" then return false end
  if n:find("wired", 1, true) then return false end
  return n:find("modem", 1, true) ~= nil or n:find("wireless", 1, true) ~= nil
end

local function findModemSlot()
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 and isModemItem(turtle.getItemDetail(s)) then
      return s
    end
  end
  return nil
end

local function isPickaxeItem(detail)
  if type(detail) ~= "table" then return false end
  local n = tostring(detail.name or ""):lower()
  return n:find("pickaxe", 1, true) ~= nil
end

local function isFuelSlot(s)
  return s == FUEL_SLOT or s == FUEL_SLOT2
end

local function findEmptyCargo()
  for s = 1, CARGO_MAX do
    if turtle.getItemCount(s) == 0 then return s end
  end
  return nil
end

local function findPickSlot()
  if turtle.getItemCount(PICK_SLOT) > 0 and isPickaxeItem(turtle.getItemDetail(PICK_SLOT)) then
    return PICK_SLOT
  end
  for s = 1, CARGO_MAX do
    if turtle.getItemCount(s) > 0 and isPickaxeItem(turtle.getItemDetail(s)) then
      return s
    end
  end
  return nil
end

local function parkPickInSlot14()
  local slot = findPickSlot()
  if not slot then return true end
  if slot == PICK_SLOT then return true end
  if turtle.getItemCount(PICK_SLOT) == 0 then
    turtle.select(slot)
    return turtle.transferTo(PICK_SLOT) or false
  end
  if isPickaxeItem(turtle.getItemDetail(PICK_SLOT)) then return true end
  local empty = findEmptyCargo()
  if not empty then return false end
  turtle.select(PICK_SLOT)
  turtle.transferTo(empty)
  turtle.select(slot)
  return turtle.transferTo(PICK_SLOT) or false
end

-- Modem has no reserved slot — park in cargo 1-12 while pickaxe is on RIGHT.
local function parkModemInCargo()
  local slot = findModemSlot()
  if not slot then return false end
  if slot <= CARGO_MAX then return true end
  local empty = findEmptyCargo()
  if not empty then return false end
  turtle.select(slot)
  return turtle.transferTo(empty) or false
end

-- RIGHT = pickaxe for digging / retrieving the Geo Scanner.
-- Note: a pickaxe is NOT a peripheral — getType("right") is nil when pick is on.
local function ensurePick()
  local ptype = peripheral.getType(PICK_SIDE)
  local slot = findPickSlot()
  if ptype ~= "modem" and ptype ~= "wireless_modem" then
    -- Right is empty or already a tool. No pick in inventory ⇒ assume pick equipped.
    if not slot then return true end
  end
  if not slot then
    print("No pickaxe in slot " .. PICK_SLOT .. " — cannot dig up Geo Scanner.")
    return false
  end
  turtle.select(slot)
  if not turtle.equipRight() then
    print("Could not equip pickaxe on RIGHT.")
    return false
  end
  -- Unequipped modem lands in the selected slot — park in cargo 1-12.
  if turtle.getItemCount(slot) > 0 and isModemItem(turtle.getItemDetail(slot)) then
    if slot > CARGO_MAX then parkModemInCargo() end
  else
    local m = findModemSlot()
    if m and m > CARGO_MAX then parkModemInCargo() end
  end
  return true
end

-- RIGHT = wireless modem (default / most of the time).
local function ensureModem()
  local ptype = peripheral.getType(PICK_SIDE)
  if (ptype == "modem" or ptype == "wireless_modem") and openModem() then
    parkPickInSlot14()
    return true
  end
  local slot = findModemSlot()
  if not slot then
    return openModem()
  end
  turtle.select(slot)
  if not turtle.equipRight() then
    return openModem()
  end
  -- Pickaxe came off into selected slot — home it in 14.
  if turtle.getItemCount(slot) > 0 and isPickaxeItem(turtle.getItemDetail(slot)) then
    if slot ~= PICK_SLOT then
      if turtle.getItemCount(PICK_SLOT) == 0 then
        turtle.transferTo(PICK_SLOT)
      else
        parkPickInSlot14()
      end
    end
  else
    parkPickInSlot14()
  end
  return openModem()
end

-- Brief pickaxe window, then always restore modem before returning.
local function withPickaxe(fn)
  if not ensurePick() then return false end
  local ok, a, b, c = pcall(fn)
  if not ensureModem() then
    print("WARNING: could not restore modem after pickaxe use.")
  end
  if not ok then
    print("Pickaxe action error: " .. tostring(a))
    return false
  end
  return a, b, c
end

local function labelSelf()
  local maj, min = VERSION:match("^(%d+)%.(%d+)")
  pcall(os.setComputerLabel, ("V%s.%s-Scan%d"):format(
    maj or "1", min or "0", os.getComputerID()))
end

--------------------------------------------------------------------------------
-- Fuel (coal slots 16 + 15 — two stacks)
--------------------------------------------------------------------------------
local function isCoalName(name)
  name = tostring(name or ""):lower()
  if name == "" or name:find("ore", 1, true) then return false end
  return name:find("coal", 1, true) ~= nil or name:find("charcoal", 1, true) ~= nil
end

local function slotIsCoal(slot)
  local d = turtle.getItemDetail(slot)
  return d ~= nil and isCoalName(d.name)
end

local function fuelCount()
  local n = 0
  if slotIsCoal(FUEL_SLOT) then n = n + turtle.getItemCount(FUEL_SLOT) end
  if slotIsCoal(FUEL_SLOT2) then n = n + turtle.getItemCount(FUEL_SLOT2) end
  return n
end

local function selectCargo()
  local empty = findEmptyCargo()
  if empty then turtle.select(empty); return end
  turtle.select(1)
end

local function protectFuel()
  for _, fs in ipairs({ FUEL_SLOT, FUEL_SLOT2 }) do
    if turtle.getItemCount(fs) > 0 and not slotIsCoal(fs) then
      turtle.select(fs)
      local empty = findEmptyCargo()
      if empty then turtle.transferTo(empty) end
    end
  end
  for _, fs in ipairs({ FUEL_SLOT, FUEL_SLOT2 }) do
    for s = 1, CARGO_MAX do
      if turtle.getItemCount(fs) >= FUEL_KEEP then break end
      if turtle.getItemCount(s) > 0 and slotIsCoal(s) then
        turtle.select(s)
        turtle.transferTo(fs)
      end
    end
  end
  selectCargo()
end

local function burnFuelFromSlots()
  for _, fs in ipairs({ FUEL_SLOT, FUEL_SLOT2 }) do
    if slotIsCoal(fs) then
      turtle.select(fs)
      local n = turtle.getItemCount(fs)
      local leave = ((tonumber(turtle.getFuelLevel()) or 0) < 1) and 0 or 1
      local burn = math.min(math.max(0, n - leave), 8)
      if burn >= 1 then
        turtle.refuel(burn)
        return true
      end
    end
  end
  return false
end

local function ensureFuel()
  local level = turtle.getFuelLevel()
  if level == "unlimited" then return true end
  protectFuel()
  if (tonumber(level) or 0) >= MIN_FUEL then return true end
  burnFuelFromSlots()
  selectCargo()
  level = turtle.getFuelLevel()
  return level == "unlimited" or (tonumber(level) or 0) > 0
end

--------------------------------------------------------------------------------
-- Movement (quarry coords: +Y down)
--------------------------------------------------------------------------------
-- Forward decl: digDir must refuse to path-dig a placed Geo Scanner.
local inspectIsGeoDown

local function turnRight()
  turtle.turnRight()
  facing = (facing + 1) % 4
end

local function turnLeft()
  turtle.turnLeft()
  facing = (facing + 3) % 4
end

local function turnTo(dir)
  dir = dir % 4
  local d = (dir - facing) % 4
  if d == 1 then turnRight()
  elseif d == 2 then turnRight(); turnRight()
  elseif d == 3 then turnLeft() end
end

local function suckFuelLeft()
  local saved = facing
  turnTo(3)
  protectFuel()
  for _, fs in ipairs({ FUEL_SLOT, FUEL_SLOT2 }) do
    turtle.select(fs)
    if turtle.getItemCount(fs) == 0 or slotIsCoal(fs) then
      local space = turtle.getItemCount(fs) == 0 and FUEL_KEEP
        or math.min(turtle.getItemSpace(fs) or 0, FUEL_KEEP - turtle.getItemCount(fs))
      if space and space > 0 then turtle.suck(space) end
    end
  end
  protectFuel()
  ensureFuel()
  turnTo(saved)
end

local function digDir(dir)
  for _ = 1, 8 do
    if dir == "forward" then
      if not turtle.detect() then return true end
      if not turtle.dig() then return false end
    elseif dir == "up" then
      if not turtle.detectUp() then return true end
      if not turtle.digUp() then return false end
    elseif dir == "down" then
      -- Never path-dig a Geo Scanner (place/pickup handle that intentionally).
      if inspectIsGeoDown() then return false end
      if not turtle.detectDown() then return true end
      if not turtle.digDown() then return false end
    end
    sleep(0.05)
  end
  return false
end

local function forward()
  if not ensureFuel() then return false end
  digDir("forward")
  if not turtle.forward() then return false end
  if facing == 0 then pos.z = pos.z + 1
  elseif facing == 1 then pos.x = pos.x + 1
  elseif facing == 2 then pos.z = pos.z - 1
  else pos.x = pos.x - 1 end
  return true
end

local function up()
  if not ensureFuel() then return false end
  digDir("up")
  if not turtle.up() then return false end
  pos.y = pos.y - 1
  return true
end

local function down()
  if not ensureFuel() then return false end
  digDir("down")
  if not turtle.down() then return false end
  pos.y = pos.y + 1
  return true
end

local function goTo(x, y, z)
  x = math.floor(tonumber(x) or 0)
  y = math.floor(tonumber(y) or 0)
  z = math.floor(tonumber(z) or 0)
  -- Prefer surface hop: climb to y<=0, cross XZ, settle.
  while pos.y > 0 do if not up() then return false end end
  while pos.y < 0 do if not down() then return false end end
  if pos.x ~= x then
    turnTo(pos.x < x and 1 or 3)
    while pos.x ~= x do if not forward() then return false end end
  end
  if pos.z ~= z then
    turnTo(pos.z < z and 0 or 2)
    while pos.z ~= z do if not forward() then return false end end
  end
  while pos.y < y do if not down() then return false end end
  while pos.y > y do if not up() then return false end end
  return true
end

local function goHome()
  ensureModem()
  local ok = goTo(0, 0, 0)
  turnTo(0)
  suckFuelLeft()
  ensureModem()
  return ok
end

--------------------------------------------------------------------------------
-- Geo scanner item
--------------------------------------------------------------------------------
local function isGeoScannerItem(detail)
  if type(detail) ~= "table" then return false end
  local n = tostring(detail.name or ""):lower()
  return n:find("geo_scanner", 1, true) ~= nil
    or n:find("geoscanner", 1, true) ~= nil
    or (n:find("geo", 1, true) and n:find("scanner", 1, true))
end

local function findScannerSlot()
  if turtle.getItemCount(SCANNER_SLOT) > 0
    and isGeoScannerItem(turtle.getItemDetail(SCANNER_SLOT)) then
    return SCANNER_SLOT
  end
  for s = 1, CARGO_MAX do
    if turtle.getItemCount(s) > 0 and isGeoScannerItem(turtle.getItemDetail(s)) then
      return s
    end
  end
  -- Last resort: anywhere except fuel slots (misplaced item).
  for s = 1, 16 do
    if not isFuelSlot(s) and turtle.getItemCount(s) > 0
      and isGeoScannerItem(turtle.getItemDetail(s)) then
      return s
    end
  end
  return nil
end

local function parkScannerInSlot13()
  local slot = findScannerSlot()
  if not slot then return false end
  if slot == SCANNER_SLOT then return true end
  if turtle.getItemCount(SCANNER_SLOT) == 0 then
    turtle.select(slot)
    return turtle.transferTo(SCANNER_SLOT) or false
  end
  if isGeoScannerItem(turtle.getItemDetail(SCANNER_SLOT)) then return true end
  local empty = findEmptyCargo()
  if not empty then return false end
  turtle.select(SCANNER_SLOT)
  turtle.transferTo(empty)
  turtle.select(slot)
  return turtle.transferTo(SCANNER_SLOT) or false
end

local function wrapGeoDown()
  local p = peripheral.wrap("bottom")
  if not p then return nil end
  local t = peripheral.getType("bottom")
  if t == "geo_scanner" or t == "geoScanner" then return p end
  if type(p.scan) == "function" or type(p.scanBlocks) == "function" then return p end
  return nil
end

-- True if the block below is a Geo Scanner (even before peripheral wrap is ready).
inspectIsGeoDown = function()
  if not turtle.inspectDown then
    return wrapGeoDown() ~= nil
  end
  local ok, info = turtle.inspectDown()
  if not ok or type(info) ~= "table" then return false end
  local n = tostring(info.name or ""):lower()
  return (n:find("geo_scanner", 1, true) ~= nil)
    or (n:find("geoscanner", 1, true) ~= nil)
    or (n:find("geo", 1, true) ~= nil and n:find("scanner", 1, true) ~= nil)
end

local function waitPeripheralGeo(timeout)
  timeout = timeout or 3
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local geo = wrapGeoDown()
    if geo then return geo end
    if not inspectIsGeoDown() and not turtle.detectDown() then return nil end
    sleep(0.1)
  end
  return wrapGeoDown()
end

local function waitScanCooldown(geo)
  if not geo or type(geo.getScanCooldown) ~= "function" then return end
  for _ = 1, 80 do
    local ok, cd = pcall(geo.getScanCooldown)
    if not ok or type(cd) ~= "number" or cd <= 0 then return end
    sleep(math.min(0.5, cd + 0.05))
  end
end

-- After geo.scan() returns, briefly confirm the scan was consumed (cooldown > 0).
-- Do NOT wait for the full cooldown to expire — that delays pickup unnecessarily.
local function waitScanFinished(geo)
  if not geo then return end
  if type(geo.getScanCooldown) ~= "function" then
    sleep(0.35)
    return
  end
  for _ = 1, 40 do
    local ok, cd = pcall(geo.getScanCooldown)
    if ok and type(cd) == "number" and cd > 0 then
      sleep(0.15)
      return
    end
    sleep(0.1)
  end
  sleep(0.25)
end

local function isAirName(name)
  return name == "minecraft:air" or name == "minecraft:cave_air"
    or name == "minecraft:void_air"
end

-- Relative scan block → quarry coords from turtle pose (scanner under turtle).
local function relToQuarry(bx, by, bz)
  -- Scanner is one block below turtle: world/quarry offset y+1 from turtle.
  local sx, sy, sz = pos.x, pos.y + 1, pos.z
  local fx, fz, rx, rz
  if facing == 0 then fx, fz, rx, rz = 0, 1, 1, 0
  elseif facing == 1 then fx, fz, rx, rz = 1, 0, 0, -1
  elseif facing == 2 then fx, fz, rx, rz = 0, -1, -1, 0
  else fx, fz, rx, rz = -1, 0, 0, 1 end
  -- AP returns x/y/z relative to the peripheral.
  local qx = sx + bx * rx + bz * fx
  local qy = sy - by
  local qz = sz + bx * rz + bz * fz
  return math.floor(qx + 0.5), math.floor(qy + 0.5), math.floor(qz + 0.5)
end

local function placeScannerDown()
  parkScannerInSlot13()
  local slot = findScannerSlot()
  if not slot then
    print("No Geo Scanner in slot " .. SCANNER_SLOT .. ".")
    return false
  end
  -- Already a scanner below — never dig it up while "clearing".
  if inspectIsGeoDown() or wrapGeoDown() then
    local geo = waitPeripheralGeo(2)
    return geo ~= nil
  end
  -- Keep modem on. Only borrow pickaxe if non-scanner block blocks the spot.
  if turtle.detectDown() then
    local cleared = withPickaxe(function()
      if inspectIsGeoDown() then return true end
      digDir("down")
      return not turtle.detectDown()
    end)
    if not cleared and turtle.detectDown() and not inspectIsGeoDown() then
      print("Could not clear space under turtle for Geo Scanner.")
      return false
    end
  end
  slot = findScannerSlot()
  if not slot then
    if inspectIsGeoDown() then return waitPeripheralGeo(2) ~= nil end
    print("Geo Scanner missing after clearing space.")
    return false
  end
  ensureModem()
  turtle.select(slot)
  if not turtle.placeDown() then
    if inspectIsGeoDown() or wrapGeoDown() then
      return waitPeripheralGeo(2) ~= nil
    end
    print("Could not place Geo Scanner down.")
    return false
  end
  local geo = waitPeripheralGeo(3)
  if not geo then
    print("Geo Scanner placed but peripheral not ready.")
    return false
  end
  return true
end

-- ONLY call after site has acked the report. Brief pickaxe dig → modem before move.
local function pickupScannerDown()
  if not inspectIsGeoDown() and not wrapGeoDown() and not turtle.detectDown() then
    if findScannerSlot() then return true end
  end
  print("Retrieving Geo Scanner (brief pickaxe swap)...")
  local ok = withPickaxe(function()
    selectCargo()
    for _ = 1, 10 do
      if findScannerSlot() and not inspectIsGeoDown() then return true end
      if turtle.detectDown() or inspectIsGeoDown() then
        turtle.digDown()
      else
        break
      end
      turtle.suckDown()
      sleep(0.05)
    end
    if not findScannerSlot() then
      for _ = 1, 4 do
        turtle.suck()
        turtle.suckDown()
        turtle.suckUp()
        if findScannerSlot() then return true end
        turnRight()
      end
    end
    return findScannerSlot() ~= nil
  end)
  if ok then
    parkScannerInSlot13()
    print("Geo Scanner recovered — modem back on.")
  else
    print("WARNING: Geo Scanner not in inventory after dig — check ground.")
  end
  ensureModem()
  return ok == true
end

local function solidsFromScanData(data, x0, x1, z0, z1, y1)
  local solids, seen = {}, {}
  for _, b in ipairs(data or {}) do
    if type(b) == "table" and type(b.name) == "string" and not isAirName(b.name) then
      local qx, qy, qz = relToQuarry(
        tonumber(b.x) or 0, tonumber(b.y) or 0, tonumber(b.z) or 0)
      if qx >= x0 and qx <= x1 and qz >= z0 and qz <= z1 and qy >= 0 and qy <= y1 then
        local key = qx .. ":" .. qy .. ":" .. qz
        if not seen[key] then
          seen[key] = true
          solids[#solids + 1] = { x = qx, y = qy, z = qz }
        end
      end
    end
  end
  return solids
end

-- Travel (modem) → place → FULL scan. Never picks up — caller reports first.
-- Returns solids, err, radius, scannerStillPlaced
local function runCellScan(claim)
  local radius = math.max(1, math.min(16, math.floor(tonumber(claim.radius) or 8)))
  local cx = math.floor(tonumber(claim.cx) or 0)
  local cy = math.floor(tonumber(claim.cy) or 0)
  local cz = math.floor(tonumber(claim.cz) or 0)
  local x0 = math.floor(tonumber(claim.x0) or cx)
  local x1 = math.floor(tonumber(claim.x1) or cx)
  local z0 = math.floor(tonumber(claim.z0) or cz)
  local z1 = math.floor(tonumber(claim.z1) or cz)
  local y1 = math.floor(tonumber(claim.y1) or 0)
  if x1 < x0 then x0, x1 = x1, x0 end
  if z1 < z0 then z0, z1 = z1, z0 end

  print(("Scan cell #%s @ %d,%d,%d r=%d"):format(
    tostring(claim.cellId), cx, cy, cz, radius))

  if not ensureModem() then
    return nil, "no-modem", radius, false
  end
  if not goTo(cx, cy, cz) then
    return nil, "path", radius, false
  end
  turnTo(0)

  if not placeScannerDown() then
    return nil, "place", radius, inspectIsGeoDown()
  end
  local geo = waitPeripheralGeo(3)
  if not geo then
    return nil, "no peripheral", radius, inspectIsGeoDown()
  end

  waitScanCooldown(geo)
  if type(geo.cost) == "function" then
    local okc, cost = pcall(geo.cost, radius)
    if okc and type(cost) == "number" then
      print(("  scan cost ~%s FE"):format(tostring(cost)))
    end
  end

  print("  Scanning… (waiting for results)")
  local ok, data, err = pcall(function()
    if geo.scan then return geo.scan(radius) end
    return geo.scanBlocks(radius)
  end)
  waitScanFinished(geo)

  -- Peripheral must still be present — never treat a mid-scan dig as success.
  if not wrapGeoDown() and not inspectIsGeoDown() then
    return nil, "scanner broken during scan", radius, false
  end

  if not ok then
    return nil, tostring(data), radius, true
  end
  if data == nil then
    -- Retry once after cooldown — first call sometimes returns early.
    print("  Scan returned empty — retrying once…")
    geo = waitPeripheralGeo(2) or geo
    waitScanCooldown(geo)
    ok, data, err = pcall(function()
      if geo.scan then return geo.scan(radius) end
      return geo.scanBlocks(radius)
    end)
    waitScanFinished(geo)
    if not ok or data == nil then
      return nil, tostring(err or data or "scan failed"), radius, true
    end
  end

  local solids = solidsFromScanData(data, x0, x1, z0, z1, y1)
  print(("  Scan complete — %d solid(s). Reporting before pickup."):format(#solids))
  return solids, nil, radius, true
end

--------------------------------------------------------------------------------
-- Network
--------------------------------------------------------------------------------
local function send(msg)
  msg.from = os.getComputerID()
  msg.name = os.getComputerLabel() or ("Scan-" .. os.getComputerID())
  msg.role = "scanner"
  msg.posX, msg.posY, msg.posZ = pos.x, pos.y, pos.z
  msg.fuel = turtle.getFuelLevel()
  if siteId then
    rednet.send(siteId, msg, PROTO)
  else
    rednet.broadcast(msg, PROTO)
  end
end

local function waitReply(types, timeout)
  timeout = timeout or 5
  local want = {}
  if type(types) == "string" then want[types] = true
  else for _, t in ipairs(types) do want[t] = true end end
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO, math.max(0.05, deadline - os.clock()))
    if id and type(msg) == "table" and want[tostring(msg.type)] then
      if not siteId then siteId = id end
      return id, msg
    end
  end
  return nil, nil
end

local function joinSite()
  if not ensureModem() then
    print("Need a WIRELESS MODEM on RIGHT (or in cargo slots 1-12).")
    print("  Equip it / put it in the turtle, then `join` again.")
    print("  (Slots 13-16 are geo / pick / fuel — not for the modem.)")
    return false
  end
  send({ type = "quarry_join", bpc = 1 })
  local id, msg = waitReply({ "quarry_welcome" }, 6)
  if not msg then
    print("No site board reply — is the site board on and in range?")
    return false
  end
  siteId = id or msg.siteId or siteId
  print(("Joined site #%s"):format(tostring(siteId)))
  return true
end

local function claimScanCell()
  send({ type = "quarry_scan_req" })
  local _, msg = waitReply({ "quarry_scan_cell" }, 8)
  return msg
end

-- Returns nextClaim, sawAck. Retries send until site acks (or attempts exhausted).
local function reportScan(claim, solids, radius, failed)
  local nextClaim, sawAck = nil, false
  for attempt = 1, 3 do
    send({
      type = "quarry_scan_report",
      cellId = claim.cellId,
      solids = solids or {},
      radius = radius,
      x0 = claim.x0, x1 = claim.x1, z0 = claim.z0, z1 = claim.z1,
      failed = failed == true,
      next = true,
    })
    local deadline = os.clock() + 10
    while os.clock() < deadline do
      local id, msg = rednet.receive(PROTO, math.max(0.05, deadline - os.clock()))
      if id and type(msg) == "table" then
        if not siteId then siteId = id end
        if msg.type == "quarry_scan_ack" then
          sawAck = true
          if msg.autoComplete then print("Site auto-completed empty cell.") end
          if msg.ok == false and failed then
            return nextClaim, true
          end
        elseif msg.type == "quarry_scan_cell" then
          nextClaim = msg
          -- Next cell after ack is enough proof the report landed.
          return nextClaim, true
        end
        if sawAck and nextClaim then return nextClaim, true end
        if sawAck and failed then return nextClaim, true end
        -- Success path: ack alone is enough; next cell may arrive shortly.
        if sawAck and not failed then
          local d2 = os.clock() + 2
          while os.clock() < d2 do
            local id2, msg2 = rednet.receive(PROTO, math.max(0.05, d2 - os.clock()))
            if id2 and type(msg2) == "table" and msg2.type == "quarry_scan_cell" then
              return msg2, true
            end
          end
          return nextClaim, true
        end
      end
    end
    print(("  Site ack timeout (try %d/3)…"):format(attempt))
  end
  return nextClaim, sawAck
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
local function scanLoop()
  if not siteId and not joinSite() then return end
  STOP = false
  local pending = nil
  while not STOP do
    if not ensureFuel() then
      print("Out of fuel — depot.")
      goHome()
      if not ensureFuel() then
        print("Still no fuel. Stock left chest / slots 16+15.")
        return
      end
    end
    if not findScannerSlot() then
      print("Missing Geo Scanner — put one in slot 13.")
      return
    end

    local claim = pending
    pending = nil
    if not claim then claim = claimScanCell() end
    if not claim or claim.ok == false then
      print("No unscanned cells: " .. tostring(claim and claim.err or "nil"))
      goHome()
      return
    end
    activeScan = claim

    -- Fuel gate for round trip.
    local need = (math.abs(claim.cx or 0) + math.abs(claim.cz or 0)) * 2 + HOME_MARGIN + 40
    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" and (tonumber(fuel) or 0) < need then
      print("Low fuel for cell — topping at depot.")
      goHome()
    end

    if not ensureModem() then
      print("Modem required before leaving depot.")
      return
    end
    send({ type = "quarry_leave_origin", status = "travel", cellId = claim.cellId })

    -- Travel / place / scan with modem. Geo Scanner stays placed until report acks.
    local solids, err, radius, placed = runCellScan(claim)
    if not ensureModem() then
      print("Could not equip modem to report — trying anyway.")
    end
    if not solids then
      print("Scan failed: " .. tostring(err))
      print("Reporting failure to site (scanner still placed)…")
      pending = select(1, reportScan(claim, {}, radius, true))
      if placed or inspectIsGeoDown() then pickupScannerDown() end
      goHome()
    else
      print("Uploading scan to site board (scanner still placed)…")
      local nextClaim, acked = reportScan(claim, solids, radius, false)
      pending = nextClaim
      if not acked then
        print("WARNING: site did not ack — not moving yet; retrying report…")
        nextClaim, acked = reportScan(claim, solids, radius, false)
        pending = nextClaim or pending
      end
      if acked then
        print("Site acked — retrieving Geo Scanner…")
      else
        print("WARNING: no ack after retries — retrieving scanner anyway.")
      end
      if placed or inspectIsGeoDown() then
        pickupScannerDown()
      end
    end
    ensureModem() -- modem on before walking to next cell
    activeScan = nil
  end
  ensureModem()
  goHome()
end

local function setup()
  print("Scanner setup — reserved slots:")
  print("  16+15 = coal (2 stacks)  |  14 = pickaxe  |  13 = Geo Scanner")
  print("  RIGHT = wireless modem (parks in 1-12 only while picking up scanner)")
  print("Origin = current pose. Facing into mine (+Z). Fuel chest LEFT.")
  turnTo(0)
  pos.x, pos.y, pos.z = 0, 0, 0
  protectFuel()
  suckFuelLeft()
  parkScannerInSlot13()
  parkPickInSlot14()
  local pickOk = findPickSlot() ~= nil or (
    peripheral.getType(PICK_SIDE) and peripheral.getType(PICK_SIDE) ~= "modem"
      and peripheral.getType(PICK_SIDE) ~= "wireless_modem")
  local modemOk = ensureModem()
  cfg.setupDone = true
  saveCfg()
  print(("Ready. fuel=%s  coal=%d  modem=%s  pick14=%s  geo13=%s"):format(
    tostring(turtle.getFuelLevel()),
    fuelCount(),
    modemOk and "yes" or "MISSING",
    pickOk and "yes" or "MISSING",
    findScannerSlot() and "yes" or "MISSING"))
  if not modemOk then
    print("Equip a wireless modem on RIGHT (or put one in cargo 1-12), then `join`.")
  end
  if not pickOk then
    print("Put a pickaxe in slot " .. PICK_SLOT .. ".")
  end
  if not findScannerSlot() then
    print("Put an AP Geo Scanner in slot " .. SCANNER_SLOT .. ".")
  end
end

local function status()
  print(("Scanner v%s  site=%s  pose=%d,%d,%d face=%d fuel=%s"):format(
    VERSION, tostring(siteId or "-"), pos.x, pos.y, pos.z, facing,
    tostring(turtle.getFuelLevel())))
  print(("  coal15/16=%d  geo13=%s  pick14=%s  modemOpen=%s  cell=%s"):format(
    fuelCount(),
    findScannerSlot() and "yes" or "no",
    findPickSlot() and "yes" or "no",
    tostring(openModem()),
    tostring(activeScan and activeScan.cellId or "-")))
end

local function help()
  print("Cell scanner — slots: 16+15 fuel, 14 pick, 13 geo; modem on RIGHT.")
  print("  Pickaxe only to dig up the Geo Scanner, then modem before moving.")
  print("  join | scan | stop | home | refuel | setup | status | help | exit")
  print("Site: requirescan on  (miners wait for maps)")
end

--------------------------------------------------------------------------------
loadCfg()
labelSelf()
openModem()
term.clear(); term.setCursorPos(1, 1)
print("== Cell Scanner v" .. VERSION .. " ==")
if not cfg.setupDone then
  print("Tip: stand at quarry origin, then `setup`.")
end
if findScannerSlot() then print("Geo Scanner in slot 13 (or cargo).")
else print("Put an AP Geo Scanner in slot 13.") end
print("Type help.")

while true do
  write("scan> ")
  local line = read()
  if not line then break end
  local cmd = line:match("^(%S+)") or ""
  cmd = cmd:lower()
  if cmd == "" then
  elseif cmd == "exit" or cmd == "quit" then break
  elseif cmd == "help" or cmd == "?" then help()
  elseif cmd == "status" then status()
  elseif cmd == "setup" then setup()
  elseif cmd == "join" then joinSite()
  elseif cmd == "home" then goHome(); print("home")
  elseif cmd == "refuel" then suckFuelLeft(); print("fuel=" .. tostring(turtle.getFuelLevel()))
  elseif cmd == "stop" then STOP = true; print("stop requested")
  elseif cmd == "scan" or cmd == "go" or cmd == "start" then
    scanLoop()
  else
    print("Unknown. Type help.")
  end
end
