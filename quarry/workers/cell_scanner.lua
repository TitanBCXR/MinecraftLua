--[[
  quarry/workers/cell_scanner.lua  -  Per-cell Geo Scanner turtle
  Titan-Version: 1.0.0

  Places an Advanced Peripherals Geo Scanner at the center of each free
  unscanned quarry cell, runs scan(radius), reports solids to the site board,
  picks the scanner back up, then claims the next cell.

  Setup (same depot as miners):
    * Stand at quarry origin 0,0,0 facing into the mine (+Z)
    * Fuel chest LEFT → slot 16 (coal/charcoal)
    * Slot 15 = wireless modem
    * Inventory: Advanced Peripherals Geo Scanner item (+ spare fuel)
    * Site board online; `origin` set on the board

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
local FUEL_KEEP = 64
local MIN_FUEL = 200
local HOME_MARGIN = 24
local VERSION = "1.0.0"
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
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then pcall(rednet.open, side) end
      return true
    end
  end
  return false
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
  local ok = goTo(0, 0, 0)
  turnTo(0)
  suckFuelLeft()
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
  digDir("down")
  turtle.select(slot)
  if not turtle.placeDown() then
    -- Already a scanner? try wrapping.
    if wrapGeoDown() then return true end
    print("Could not place Geo Scanner down.")
    return false
  end
  sleep(0.2)
  return wrapGeoDown() ~= nil
end

local function pickupScannerDown()
  selectCargo()
  if turtle.detectDown() then
    turtle.digDown()
  end
  -- Ensure we still have the scanner item.
  if not findScannerSlot() then
    print("WARNING: Geo Scanner not in inventory after dig — check ground.")
    return false
  end
  return true
end

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

  if not goTo(cx, cy, cz) then
    return nil, "path"
  end
  turnTo(0)

  if not placeScannerDown() then
    return nil, "place"
  end
  local geo = wrapGeoDown()
  if not geo then
    pickupScannerDown()
    return nil, "no peripheral"
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
  pickupScannerDown()

  if not ok then return nil, tostring(data) end
  if data == nil then return nil, tostring(err or "scan failed") end

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
  return solids, nil, radius
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
  if not openModem() then
    print("Need a wireless modem (slot " .. MODEM_SLOT .. " / upgrade).")
    return false
  end
  send({ type = "quarry_join", bpc = 1 })
  local id, msg = waitReply({ "quarry_welcome" }, 6)
  if not msg then
    print("No site board reply.")
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

    send({ type = "quarry_leave_origin", status = "travel", cellId = claim.cellId })
    local solids, err, radius = runCellScan(claim)
    if not solids then
      print("Scan failed: " .. tostring(err))
      goHome()
      pending = select(1, reportScan(claim, {}, radius, true))
    else
      pending = select(1, reportScan(claim, solids, radius, false))
    end
    activeScan = nil
  end
  goHome()
end

local function setup()
  print("Scanner setup: modem slot 15, coal slot 16, Geo Scanner in cargo.")
  print("Origin = current pose. Facing into mine (+Z).")
  turnTo(0)
  pos.x, pos.y, pos.z = 0, 0, 0
  suckFuelLeft()
  cfg.setupDone = true
  saveCfg()
  print(("Ready. fuel=%s scanner=%s"):format(
    tostring(turtle.getFuelLevel()),
    findScannerSlot() and "yes" or "MISSING"))
end

local function status()
  print(("Scanner v%s  site=%s  pose=%d,%d,%d face=%d fuel=%s"):format(
    VERSION, tostring(siteId or "-"), pos.x, pos.y, pos.z, facing,
    tostring(turtle.getFuelLevel())))
  print(("  geo item=%s  active cell=%s"):format(
    findScannerSlot() and "yes" or "no",
    tostring(activeScan and activeScan.cellId or "-")))
end

local function help()
  print("Cell scanner — place Geo Scanner per cell, report solids to site.")
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
