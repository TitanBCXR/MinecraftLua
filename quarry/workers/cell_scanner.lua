--[[
  quarry/workers/cell_scanner.lua  -  Per-cell Geo Scanner turtle
  Titan-Version: 1.0.2

  Places an Advanced Peripherals Geo Scanner at the center of each free
  unscanned quarry cell, runs scan(radius), reports solids to the site board,
  then swaps modem→pickaxe to dig the scanner up, modem back on, next cell.

  Setup (same depot as miners):
    * Stand at quarry origin 0,0,0 facing into the mine (+Z)
    * Fuel chest LEFT → slot 16 (coal/charcoal)
    * Slot 15 = wireless modem (RIGHT upgrade while talking)
    * Inventory: Geo Scanner + diamond/netherite pickaxe
    * Site board online; `origin` set on the board

  Tooling:
    * RIGHT = modem while traveling check-ins / reporting
    * RIGHT = pickaxe while path-digging and retrieving the Geo Scanner
    * LEFT upgrade is never touched

  Commands:
    join | scan | stop | home | refuel | setup | status | help | exit

  Site:
    requirescan on   — miners only claim cells this bot has mapped
    clearscans       — wipe maps

  Run:  quarry/workers/cell_scanner
]]

local CFG = "cell_scanner.cfg"
local FUEL_SLOT = 16
local MODEM_SLOT = 15
local PICK_SIDE = "right"
local FUEL_KEEP = 64
local MIN_FUEL = 200
local HOME_MARGIN = 24
local VERSION = "1.0.2"
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

local function findPickSlot()
  for s = 1, 16 do
    if s ~= FUEL_SLOT and turtle.getItemCount(s) > 0 then
      local d = turtle.getItemDetail(s)
      if isPickaxeItem(d) then return s end
    end
  end
  return nil
end

local function parkModemInSlot15()
  local slot = findModemSlot()
  if not slot then return isModemItem(turtle.getItemDetail(MODEM_SLOT)) end
  if slot == MODEM_SLOT then return true end
  if turtle.getItemCount(MODEM_SLOT) == 0 then
    turtle.select(slot)
    return turtle.transferTo(MODEM_SLOT) or false
  end
  -- Slot 15 occupied — swap into an empty cargo slot first.
  for s = 1, 14 do
    if turtle.getItemCount(s) == 0 then
      turtle.select(MODEM_SLOT)
      turtle.transferTo(s)
      turtle.select(slot)
      return turtle.transferTo(MODEM_SLOT) or false
    end
  end
  return false
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
    print("No pickaxe in inventory — cannot dig up Geo Scanner.")
    return false
  end
  turtle.select(slot)
  if not turtle.equipRight() then
    print("Could not equip pickaxe on RIGHT.")
    return false
  end
  -- Unequipped modem lands in the selected slot — park it in 15.
  if turtle.getItemCount(slot) > 0 and isModemItem(turtle.getItemDetail(slot)) then
    if slot ~= MODEM_SLOT then
      if turtle.getItemCount(MODEM_SLOT) == 0 then
        turtle.transferTo(MODEM_SLOT)
      else
        parkModemInSlot15()
      end
    end
  end
  return true
end

-- RIGHT = wireless modem for site check-ins / scan reports.
local function ensureModem()
  local ptype = peripheral.getType(PICK_SIDE)
  if (ptype == "modem" or ptype == "wireless_modem") and openModem() then
    return true
  end
  parkModemInSlot15()
  local slot = MODEM_SLOT
  if turtle.getItemCount(MODEM_SLOT) == 0 or not isModemItem(turtle.getItemDetail(MODEM_SLOT)) then
    slot = findModemSlot()
  end
  if not slot then
    return openModem()
  end
  turtle.select(slot)
  if not turtle.equipRight() then
    return openModem()
  end
  -- Pickaxe came off into selected slot — leave it in inventory for later digs.
  return openModem()
end

local function labelSelf()
  local maj, min = VERSION:match("^(%d+)%.(%d+)")
  pcall(os.setComputerLabel, ("V%s.%s-Scan%d"):format(
    maj or "1", min or "0", os.getComputerID()))
end

--------------------------------------------------------------------------------
-- Fuel (coal slot 16)
--------------------------------------------------------------------------------
local function selectedIsFuel()
  local ok = false
  pcall(function() ok = turtle.refuel(0) end)
  return ok == true
end

local function isCoalName(name)
  name = tostring(name or ""):lower()
  if name == "" or name:find("ore", 1, true) then return false end
  return name:find("coal", 1, true) ~= nil or name:find("charcoal", 1, true) ~= nil
end

local function slotIsCoal(slot)
  local d = turtle.getItemDetail(slot)
  return d ~= nil and isCoalName(d.name)
end

local function selectCargo()
  for s = 1, 14 do
    if turtle.getItemCount(s) == 0 then turtle.select(s); return end
  end
  turtle.select(1)
end

local function protectFuel()
  if turtle.getItemCount(FUEL_SLOT) > 0 and not slotIsCoal(FUEL_SLOT) then
    turtle.select(FUEL_SLOT)
    for s = 1, 14 do
      if turtle.getItemCount(s) == 0 then turtle.transferTo(s); break end
    end
  end
  for s = 1, 14 do
    if turtle.getItemCount(FUEL_SLOT) >= FUEL_KEEP then break end
    if turtle.getItemCount(s) > 0 and slotIsCoal(s) then
      turtle.select(s)
      turtle.transferTo(FUEL_SLOT)
    end
  end
  selectCargo()
end

local function ensureFuel()
  local level = turtle.getFuelLevel()
  if level == "unlimited" then return true end
  protectFuel()
  if (tonumber(level) or 0) >= MIN_FUEL then return true end
  if slotIsCoal(FUEL_SLOT) then
    turtle.select(FUEL_SLOT)
    local n = turtle.getItemCount(FUEL_SLOT)
    local leave = ((tonumber(turtle.getFuelLevel()) or 0) < 1) and 0 or 1
    local burn = math.min(math.max(0, n - leave), 8)
    if burn >= 1 then turtle.refuel(burn) end
  end
  selectCargo()
  level = turtle.getFuelLevel()
  return level == "unlimited" or (tonumber(level) or 0) > 0
end

--------------------------------------------------------------------------------
-- Movement (quarry coords: +Y down)
--------------------------------------------------------------------------------
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
  turtle.select(FUEL_SLOT)
  if turtle.getItemCount(FUEL_SLOT) == 0 or slotIsCoal(FUEL_SLOT) then
    local space = turtle.getItemCount(FUEL_SLOT) == 0 and FUEL_KEEP
      or math.min(turtle.getItemSpace(FUEL_SLOT) or 0, FUEL_KEEP - turtle.getItemCount(FUEL_SLOT))
    if space and space > 0 then turtle.suck(space) end
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
  ensurePick()
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
  for s = 1, 16 do
    if s ~= FUEL_SLOT and turtle.getItemCount(s) > 0 then
      local d = turtle.getItemDetail(s)
      if isGeoScannerItem(d) then return s end
    end
  end
  return nil
end

local function wrapGeoDown()
  local p = peripheral.wrap("bottom")
  if not p then return nil end
  local t = peripheral.getType("bottom")
  if t == "geo_scanner" or t == "geoScanner" then return p end
  if type(p.scan) == "function" or type(p.scanBlocks) == "function" then return p end
  return nil
end

local function waitScanCooldown(geo)
  if not geo or type(geo.getScanCooldown) ~= "function" then return end
  for _ = 1, 60 do
    local ok, cd = pcall(geo.getScanCooldown)
    if not ok or type(cd) ~= "number" or cd <= 0 then return end
    sleep(math.min(0.5, cd + 0.05))
  end
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
  local slot = findScannerSlot()
  if not slot then
    print("No Geo Scanner item in inventory.")
    return false
  end
  if not ensurePick() then return false end
  digDir("down")
  -- Re-find slot — dig may have moved selection / stacks.
  slot = findScannerSlot()
  if not slot then
    print("Geo Scanner missing after clearing space.")
    return false
  end
  turtle.select(slot)
  if not turtle.placeDown() then
    if wrapGeoDown() then return true end
    print("Could not place Geo Scanner down.")
    return false
  end
  sleep(0.2)
  return wrapGeoDown() ~= nil
end

-- Modem → pickaxe → dig scanner up → modem back on.
local function pickupScannerDown()
  print("Retrieving Geo Scanner (equip pickaxe)...")
  if not ensurePick() then
    print("WARNING: no pickaxe — cannot dig Geo Scanner.")
    return false
  end
  selectCargo()
  for _ = 1, 10 do
    if findScannerSlot() then break end
    if turtle.detectDown() then
      turtle.digDown()
    else
      break
    end
    turtle.suckDown()
    sleep(0.05)
  end
  if not findScannerSlot() then
    -- Item may have popped as an entity beside us.
    for _ = 1, 4 do
      turtle.suck()
      turtle.suckDown()
      turtle.suckUp()
      if findScannerSlot() then break end
      turnRight()
    end
  end
  local ok = findScannerSlot() ~= nil
  if not ok then
    print("WARNING: Geo Scanner not in inventory after dig — check ground.")
  else
    print("Geo Scanner recovered.")
  end
  if not ensureModem() then
    print("WARNING: could not re-equip modem after pickup.")
  end
  return ok
end

-- Place + scan only. Leaves Geo Scanner placed so we can report with modem first.
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

  if not ensurePick() then
    return nil, "no-pickaxe", radius, false
  end
  if not goTo(cx, cy, cz) then
    return nil, "path", radius, false
  end
  turnTo(0)

  if not placeScannerDown() then
    return nil, "place", radius, false
  end
  local geo = wrapGeoDown()
  if not geo then
    pickupScannerDown()
    return nil, "no peripheral", radius, false
  end

  waitScanCooldown(geo)
  if type(geo.cost) == "function" then
    local okc, cost = pcall(geo.cost, radius)
    if okc and type(cost) == "number" then
      print(("  scan cost ~%s FE"):format(tostring(cost)))
    end
  end

  local ok, data, err = pcall(function()
    if geo.scan then return geo.scan(radius) end
    return geo.scanBlocks(radius)
  end)

  if not ok then
    pickupScannerDown()
    return nil, tostring(data), radius, false
  end
  if data == nil then
    pickupScannerDown()
    return nil, tostring(err or "scan failed"), radius, false
  end

  local solids = {}
  local seen = {}
  for _, b in ipairs(data) do
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
  print(("  indexed %d solid(s) in cell"):format(#solids))
  -- Scanner stays placed until after site report (modem on RIGHT).
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
    print("Need a WIRELESS MODEM inside the turtle.")
    print("  Put it in the turtle inventory (slot 15), then `join` again.")
    print("  (Items in your player inventory do not count.)")
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

-- Returns next scan-cell claim if the site chained one after the ack.
local function reportScan(claim, solids, radius, failed)
  send({
    type = "quarry_scan_report",
    cellId = claim.cellId,
    solids = solids or {},
    radius = radius,
    x0 = claim.x0, x1 = claim.x1, z0 = claim.z0, z1 = claim.z1,
    failed = failed == true,
    next = true,
  })
  local nextClaim, sawAck = nil, false
  local deadline = os.clock() + 8
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO, math.max(0.05, deadline - os.clock()))
    if id and type(msg) == "table" then
      if not siteId then siteId = id end
      if msg.type == "quarry_scan_ack" then
        sawAck = true
        if msg.autoComplete then print("Site auto-completed empty cell.") end
        if msg.ok == false and failed then break end
      elseif msg.type == "quarry_scan_cell" then
        nextClaim = msg
        break
      end
    end
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
        print("Still no fuel. Stock left chest / slot 16.")
        return
      end
    end
    if not findScannerSlot() then
      print("Missing Geo Scanner item — put one in inventory.")
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

    -- Travel / place / scan with pickaxe; leave Geo Scanner placed.
    local solids, err, radius, placed = runCellScan(claim)
    -- Report with modem while scanner is still down (or after failed recovery).
    if not ensureModem() then
      print("Could not equip modem to report — trying anyway.")
    end
    if not solids then
      print("Scan failed: " .. tostring(err))
      if placed then pickupScannerDown() end
      goHome()
      pending = select(1, reportScan(claim, {}, radius, true))
    else
      print("Uploading scan to site board...")
      pending = select(1, reportScan(claim, solids, radius, false))
      if placed then
        pickupScannerDown() -- pickaxe dig → modem back on
      end
    end
    if not ensureModem() then
      print("WARNING: modem not equipped for next leg.")
    end
    activeScan = nil
  end
  ensureModem()
  goHome()
end

local function setup()
  print("Scanner setup — these must be IN THE TURTLE (left 16 slots):")
  print("  slot 15 = wireless modem  |  slot 16 = coal")
  print("  cargo   = Geo Scanner + pickaxe (RIGHT swap)")
  print("Origin = current pose. Facing into mine (+Z).")
  turnTo(0)
  pos.x, pos.y, pos.z = 0, 0, 0
  protectFuel()
  suckFuelLeft()
  local pickOk = findPickSlot() ~= nil or (
    peripheral.getType(PICK_SIDE) and peripheral.getType(PICK_SIDE) ~= "modem"
      and peripheral.getType(PICK_SIDE) ~= "wireless_modem")
  local modemOk = ensureModem()
  cfg.setupDone = true
  saveCfg()
  print(("Ready. fuel=%s  modem=%s  pick=%s  scanner=%s  coal16=%d"):format(
    tostring(turtle.getFuelLevel()),
    modemOk and "yes" or "MISSING",
    pickOk and "yes" or "MISSING",
    findScannerSlot() and "yes" or "MISSING",
    turtle.getItemCount(FUEL_SLOT)))
  if not modemOk then
    print("Put a wireless modem into the turtle, then `join`.")
  end
  if not pickOk then
    print("Put a pickaxe in the turtle (needed to dig up the Geo Scanner).")
  end
end

local function status()
  print(("Scanner v%s  site=%s  pose=%d,%d,%d face=%d fuel=%s"):format(
    VERSION, tostring(siteId or "-"), pos.x, pos.y, pos.z, facing,
    tostring(turtle.getFuelLevel())))
  print(("  geo=%s  pick=%s  modemOpen=%s  cell=%s"):format(
    findScannerSlot() and "yes" or "no",
    findPickSlot() and "inv" or "?",
    tostring(openModem()),
    tostring(activeScan and activeScan.cellId or "-")))
end

local function help()
  print("Cell scanner — place Geo Scanner, report, pickaxe dig, next cell.")
  print("  join | scan | stop | home | refuel | setup | status | help | exit")
  print("RIGHT swaps: modem (talk) <-> pickaxe (dig scanner up)")
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
if findScannerSlot() then print("Geo Scanner item found.")
else print("Put an AP Geo Scanner in inventory.") end
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
