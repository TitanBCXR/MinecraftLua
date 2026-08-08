--[[
  miner.lua  -  Area miner turtle for the Titan network (CC: Tweaked)
  Titan-Version: 1.3.1

  Digs a rectangular "box":
    * set1 <x> <z> / set2 <x> <z> — opposite corners (X/Z footprint)
    * ystart / yend — vertical range (mine from start Y down to end Y)
    * sety <start> <end> — set both Y levels at once
    * mine 5x5 <yEnd> — quick flatten from here (end Y = bottom)
    * home / stage — return / fleet parking sheet
    * mine — start (writes miner_job.cfg with corners + Y + init pos)
    * continue — resume after unload/reboot from GPS / saved progress
    * Parent Center can assign strip jobs (cruise Y ~150)

  Slot map:
    16 = fuel (never dumped)
    15 = equipment hot-swap (modem OR chunk loader — whichever is not equipped)
  With selfChunk: dig offline with chunk loader equipped; on dump/refuel/check-in
  swap modem from slot 15, talk to the mesh, then swap chunker back.

  Fuel budget:
    Tracks fuel burn vs blocks moved. Before it cannot afford a return trip to
    the fuel chest/home, it saves depot coords and waits. Place the turtle at
    those coords with fuel chest LEFT and storage BEHIND — it auto-continues.

  Never breaks blocks listed in exclude.txt (or titan.RESTRICTED).

  Fresh miners wait for Parent Center deploy:
    deploy <id> miner <name> [depX depY depZ]

  Then: set1 <x> <z> / set2 <x> <z> / sety <ystart> <yend> / home / mine

  NETWORK: joins the Titan mesh; status+assignment go to botserver + datacenter.

  Requires: wireless modem, fuel, GPS constellation, lib/titan.lua.
  Optional: Advanced Peripherals Chunky Turtle (or similar) in slot 15 for selfChunk.
]]

local titan = dofile("lib/titan.lua")
local nav   = titan.nav
local MSG   = titan.MSG
local P     = titan.PROTOCOL

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Miner-" .. os.getComputerID()))

local CFG     = "miner.cfg"
local JOB     = "miner_job.cfg"  -- active quarry for `continue` after unload
local EXCLUDE = "exclude.txt"
local EQUIP_SLOT = 15
local FUEL_SLOT  = nav.FUEL_SLOT or 16

local cfg = {
  name = nil,
  botType = "miner",
  loc1 = nil,       -- opposite corner A (X/Z box; Y ignored for depth)
  loc2 = nil,       -- opposite corner B
  yStart = nil,     -- starting (top) Y level, inclusive
  yEnd = nil,       -- ending (bottom) Y level, inclusive
  floorY = nil,     -- legacy alias for yEnd (migrated on load)
  deposit = nil,    -- legacy: stand above chest and dropDown (optional)
  chest = nil,      -- {x,y,z} storage chest (default: one block behind home)
  fuelChest = nil,  -- optional site fuel chest
  home = nil,       -- start / return point (face the mine; chest behind)
  homeFacing = nil, -- titan.NORTH/EAST/SOUTH/WEST when home was set
  stage = nil,      -- fleet parking / sheet slot {x,y,z}
  cruiseY = 150,    -- nav layer for long hops to jobs
  selfChunk = false,-- dig with chunk loader; modem lives in slot 15 while mining
  siteId = nil,
}

local state = {
  status = "idle",
  task   = "-",
  stop   = false,
  dug    = 0,
  skipped = 0,
  jobId  = nil,
  netMode = "online", -- "online" (modem) | "chunk" (chunk loader)
}

-- Dead-reckon pose while modem is unequipped (world blocks).
local track = { x = nil, y = nil, z = nil }
local mineRequested = false
local continueRequested = false
local pendingJob = nil  -- strip job from Parent Center
local activeMineJob = nil -- in-progress quarry table (for fuel/depot hooks)

-- Fuel economy (CC: normally 1 fuel / block moved; we measure actual burn).
local FUEL_RESERVE = 48          -- keep this much after a return trip
local fuelEco = {
  fuelPerBlock = 1.0,
  blocks = 0,
  burned = 0,
  lastFuel = nil,
  lastX = nil, lastY = nil, lastZ = nil,
}

local exclude = {}   -- [blockName] = true

--------------------------------------------------------------------------------
-- Config / exclude
--------------------------------------------------------------------------------
local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  if type(d) == "table" then
    for k, v in pairs(d) do cfg[k] = v end
  end
  -- Migrate older configs: floorY -> yEnd; corner Y -> yStart if missing.
  if cfg.yEnd == nil and cfg.floorY ~= nil then
    cfg.yEnd = cfg.floorY
  end
  if cfg.yStart == nil and cfg.loc1 and cfg.loc2 then
    local y1 = tonumber(cfg.loc1.y)
    local y2 = tonumber(cfg.loc2.y)
    if y1 and y2 then cfg.yStart = math.max(y1, y2) end
  end
end

local function saveCfg()
  -- Keep floorY mirrored for older tools that still read it.
  if cfg.yEnd ~= nil then cfg.floorY = cfg.yEnd end
  local f = fs.open(CFG, "w"); f.write(textutils.serialize(cfg)); f.close()
end

-- Hook exclude list into titan.isRestricted so nav.moveTo / travelTo also skip them.
local _baseRestricted = titan.isRestricted
function titan.isRestricted(name)
  if name and exclude[name] then return true end
  return _baseRestricted(name)
end

local function loadExclude()
  exclude = {}
  if not fs.exists(EXCLUDE) then
    -- seed a minimal file so the player can edit it
    local f = fs.open(EXCLUDE, "w")
    f.write("# One block id per line. Miner will not break these.\n")
    f.write("minecraft:bedrock\n")
    f.write("minecraft:chest\n")
    f.write("minecraft:barrel\n")
    f.write("minecraft:spawner\n")
    f.write("minecraft:obsidian\n")
    f.close()
  end
  local f = fs.open(EXCLUDE, "r")
  while true do
    local line = f.readLine()
    if not line then break end
    line = line:match("^%s*(.-)%s*$") or ""
    if line ~= "" and not line:find("^#") then
      exclude[line] = true
    end
  end
  f.close()
end

local function isExcluded(name)
  return titan.isRestricted(name)
end

local function fmt(p)
  return p and ("%d,%d,%d"):format(p.x, p.y, p.z) or "?"
end

local function setStatus(s, t)
  state.status = s
  if t then state.task = t end
end

local function yRange()
  local ys = tonumber(cfg.yStart)
  local ye = tonumber(cfg.yEnd or cfg.floorY)
  if ys == nil or ye == nil then return nil end
  -- Allow either order; mining always goes high -> low.
  return math.max(ys, ye), math.min(ys, ye)
end

local function assignmentText()
  if state.jobId and (state.status == "mining" or state.status == "moving"
      or state.status == "queued" or state.status == "returning") then
    return tostring(state.jobId)
  end
  if state.status == "mining" or state.status == "moving" then
    return state.task or "mining"
  end
  return "-"
end

--------------------------------------------------------------------------------
-- Box: opposite corners (X/Z) + start/end Y levels
--------------------------------------------------------------------------------
local function bounds()
  if not cfg.loc1 or not cfg.loc2 then return nil end
  local topY, floorY = yRange()
  if not topY then return nil end
  local x1, z1 = cfg.loc1.x, cfg.loc1.z
  local x2, z2 = cfg.loc2.x, cfg.loc2.z
  return {
    minX = math.min(x1, x2), maxX = math.max(x1, x2),
    minZ = math.min(z1, z2), maxZ = math.max(z1, z2),
    topY = topY,      -- start Y (highest)
    floorY = floorY,  -- end Y (lowest)
    yStart = topY,
    yEnd = floorY,
  }
end

local function quarryReady()
  return bounds() ~= nil
end

--------------------------------------------------------------------------------
-- Persisted mine job (survive chunk unload / reboot)
--------------------------------------------------------------------------------
local function loadJob()
  if not fs.exists(JOB) then return nil end
  local f = fs.open(JOB, "r")
  if not f then return nil end
  local d = textutils.unserialize(f.readAll()); f.close()
  return type(d) == "table" and d or nil
end

local function saveJob(job)
  if type(job) ~= "table" then return end
  local f = fs.open(JOB, "w")
  if not f then return end
  f.write(textutils.serialize(job))
  f.close()
end

local function clearJob()
  if fs.exists(JOB) then pcall(fs.delete, JOB) end
end

local function applyJobToCfg(job)
  if type(job) ~= "table" then return false end
  if job.loc1 then cfg.loc1 = job.loc1 end
  if job.loc2 then cfg.loc2 = job.loc2 end
  if job.yStart ~= nil then cfg.yStart = job.yStart end
  if job.yEnd ~= nil then
    cfg.yEnd = job.yEnd
    cfg.floorY = job.yEnd
  end
  if job.home then cfg.home = job.home; nav.home = job.home end
  if job.chest then cfg.chest = job.chest end
  if job.homeFacing ~= nil then cfg.homeFacing = job.homeFacing end
  saveCfg()
  return quarryReady()
end

-- Serpentine X direction for a Z row (minZ starts eastbound).
local function zDirAt(b, z)
  local k = (z or b.minZ) - b.minZ
  if k < 0 then k = 0 end
  return (k % 2 == 0) and 1 or -1
end

local function touchJobProgress(job, y, z, zDir, x)
  if not job then return end
  job.y = y
  job.z = z
  job.zDir = zDir
  job.x = x
  job.dug = state.dug
  job.skipped = state.skipped
  job.updated = os.epoch("utc")
  saveJob(job)
end

-- Pick resume cell from GPS (preferred) or last saved progress.
local function resolveResume(job, b)
  local cx, cy, cz = nav.locatePrecise(4)
  local y = job.y or b.topY
  local z = job.z or b.minZ
  local x = job.x
  local zDir = job.zDir or zDirAt(b, z)
  local from = "saved progress"

  if cx then
    local ix = math.floor(cx + 0.5)
    local iy = math.floor(cy + 0.5)
    local iz = math.floor(cz + 0.5)
    local inBox = ix >= b.minX and ix <= b.maxX
      and iz >= b.minZ and iz <= b.maxZ
      and iy >= (b.floorY - 1) and iy <= (b.topY + 1)
    if inBox then
      y = math.max(b.floorY, math.min(b.topY, iy))
      z = math.max(b.minZ, math.min(b.maxZ, iz))
      x = math.max(b.minX, math.min(b.maxX, ix))
      zDir = zDirAt(b, z)
      from = "GPS"
    else
      print(("At %d,%d,%d (outside box) — using saved progress."):format(ix, iy, iz))
      if job.init then
        print(("Job init was %s"):format(fmt(job.init)))
      end
    end
  else
    print("No GPS — using saved progress from miner_job.cfg.")
  end

  return {
    y = y, z = z, x = x, zDir = zDir, from = from,
    gps = cx and { x = math.floor(cx + 0.5), y = math.floor(cy + 0.5), z = math.floor(cz + 0.5) } or nil,
  }
end

--------------------------------------------------------------------------------
-- Dig helpers — never break excluded / restricted blocks
--------------------------------------------------------------------------------
local function tryDig(dir)
  -- dir: "forward" | "up" | "down"
  local inspect, dig
  if dir == "up" then inspect, dig = turtle.inspectUp, turtle.digUp
  elseif dir == "down" then inspect, dig = turtle.inspectDown, turtle.digDown
  else inspect, dig = turtle.inspect, turtle.dig end

  local present, data = inspect()
  if not present then return true, "air" end
  if isExcluded(data.name) then
    state.skipped = state.skipped + 1
    -- Ask Parent Center to show a Create/train break permit request on the monitor.
    local n = data.name
    if n and (n:find("^create") or n:find("^railways") or n:find("rail")) then
      local now = os.epoch("utc")
      state._permitAsk = state._permitAsk or {}
      if not state._permitAsk[n] or (now - state._permitAsk[n]) > 30000 then
        state._permitAsk[n] = now
        rednet.broadcast({
          type = MSG.PERMIT_REQUEST, key = n, from = cfg.name or os.getComputerLabel(),
        }, P)
      end
    end
    return false, "excluded:" .. data.name
  end
  if dig() then
    state.dug = state.dug + 1
    return true, data.name
  end
  return false, "dig failed"
end

local function invFull()
  -- Slot 15 (equipment) and 16 (fuel) do not count as dig capacity.
  for s = 1, 16 do
    if s ~= EQUIP_SLOT and s ~= FUEL_SLOT and turtle.getItemCount(s) == 0 then
      return false
    end
  end
  return true
end

--------------------------------------------------------------------------------
-- Slot 15 equipment swap: modem <-> chunk loader
--------------------------------------------------------------------------------
local function detailName(d)
  return d and tostring(d.name or "") or ""
end

local function isModemName(n)
  n = tostring(n or ""):lower()
  return n:find("modem", 1, true) ~= nil
end

local function isChunkerName(n)
  n = tostring(n or ""):lower()
  if n:find("chunky", 1, true) then return true end
  if n:find("chunk_controller", 1, true) then return true end
  if n:find("chunkloader", 1, true) or n:find("chunk_loader", 1, true) then return true end
  if n:find("chunk", 1, true) and n:find("turtle", 1, true) then return true end
  return false
end

local function isPickName(n)
  n = tostring(n or ""):lower()
  return n:find("pickaxe", 1, true) ~= nil
end

local function itemDetail(slot)
  local ok, d = pcall(turtle.getItemDetail, slot, true)
  if ok and type(d) == "table" then return d end
  return turtle.getItemDetail(slot)
end

local function getEquipped(side)
  local fn = (side == "left") and turtle.getEquippedLeft or turtle.getEquippedRight
  if type(fn) ~= "function" then return nil end
  local ok, d = pcall(fn)
  if ok and type(d) == "table" then return d end
  return nil
end

local function modemSideEquipped()
  for _, side in ipairs({ "left", "right" }) do
    if peripheral.getType(side) == "modem" then return side end
    local d = getEquipped(side)
    if d and isModemName(d.name) then return side end
  end
  return nil
end

local function chunkerSideEquipped()
  for _, side in ipairs({ "left", "right" }) do
    local d = getEquipped(side)
    if d and isChunkerName(d.name) then return side end
  end
  return nil
end

local function peripheralSwapSide()
  local m = modemSideEquipped()
  if m then return m end
  local c = chunkerSideEquipped()
  if c then return c end
  for _, side in ipairs({ "right", "left" }) do
    local d = getEquipped(side)
    if d and not isPickName(d.name) then return side end
  end
  return "right"
end

local function parkPeripheralInEquipSlot()
  for s = 1, 16 do
    if s ~= EQUIP_SLOT and s ~= FUEL_SLOT then
      local d = itemDetail(s)
      local n = detailName(d)
      if isModemName(n) or isChunkerName(n) then
        turtle.select(s)
        if turtle.getItemCount(EQUIP_SLOT) == 0 then
          turtle.transferTo(EQUIP_SLOT)
        elseif turtle.getItemSpace(EQUIP_SLOT) > 0 then
          turtle.transferTo(EQUIP_SLOT)
        end
      end
    end
  end
  turtle.select(1)
end

local function findItemSlot(pred)
  local d15 = itemDetail(EQUIP_SLOT)
  if d15 and pred(detailName(d15)) then return EQUIP_SLOT end
  for s = 1, 16 do
    if s ~= EQUIP_SLOT and s ~= FUEL_SLOT then
      local d = itemDetail(s)
      if d and pred(detailName(d)) then return s end
    end
  end
  return nil
end

local function equipSlotOntoSide(slot, side)
  turtle.select(slot)
  local ok, err
  if side == "left" then
    ok, err = turtle.equipLeft()
  else
    ok, err = turtle.equipRight()
  end
  parkPeripheralInEquipSlot()
  return ok, err
end

-- Put modem on the turtle; chunker (if any) lands in slot 15.
local function ensureModemEquipped()
  if modemSideEquipped() then
    pcall(titan.openModem)
    state.netMode = "online"
    return true
  end
  local slot = findItemSlot(isModemName)
  if not slot then
    print("No modem in inventory/slot " .. EQUIP_SLOT)
    return false, "no modem"
  end
  local side = peripheralSwapSide()
  local ok, err = equipSlotOntoSide(slot, side)
  if not ok then
    -- try other side
    local other = (side == "left") and "right" or "left"
    ok, err = equipSlotOntoSide(slot, other)
  end
  if ok then
    pcall(titan.openModem)
    state.netMode = "online"
    print("Modem equipped (chunker/hot-swap in slot " .. EQUIP_SLOT .. ")")
    return true
  end
  print("Could not equip modem: " .. tostring(err))
  return false, err
end

-- Put chunk loader on; modem goes to slot 15. Only if selfChunk / chunker present.
local function ensureChunkerEquipped()
  if not cfg.selfChunk then return false, "selfChunk off" end
  if chunkerSideEquipped() then
    state.netMode = "chunk"
    return true
  end
  local slot = findItemSlot(isChunkerName)
  if not slot then return false, "no chunker" end
  local side = peripheralSwapSide()
  local ok, err = equipSlotOntoSide(slot, side)
  if not ok then
    local other = (side == "left") and "right" or "left"
    ok, err = equipSlotOntoSide(slot, other)
  end
  if ok then
    state.netMode = "chunk"
    print("Chunk loader equipped (modem in slot " .. EQUIP_SLOT .. ")")
    return true
  end
  return false, err
end

local function syncTrackFromGps(timeout)
  local x, y, z = nav.locatePrecise(timeout or 3)
  if not x then
    x, y, z = nav.locate(timeout or 2)
  end
  if x then
    track.x, track.y, track.z = x, y, z
    return true
  end
  return false
end

local function hasTrack()
  return track.x ~= nil and track.y ~= nil and track.z ~= nil
end

-- Online check-in: modem on, GPS sync, ready for dump/travel/status.
local function goOnline(reason)
  setStatus("checkin", reason or "modem on")
  local ok, err = ensureModemEquipped()
  if not ok then return false, err end
  syncTrackFromGps(4)
  return true
end

-- Enter offline dig mode when configured.
local function goChunkMine()
  if not cfg.selfChunk then return false end
  if hasTrack() or syncTrackFromGps(2) then
    local ok = ensureChunkerEquipped()
    return ok
  end
  return false
end

-- Axis walk using heading + dig, updating track (for modem-off mining).
local function trackMoveTo(tx, ty, tz)
  tx, ty, tz = math.floor(tx), math.floor(ty), math.floor(tz)
  if not hasTrack() then
    if not goOnline("gps fix") then return false, "no gps" end
    if not syncTrackFromGps(4) then return false, "no gps" end
  end
  -- Prefer real GPS nav when modem is up.
  if modemSideEquipped() then
    local ok, err = nav.moveTo(tx, ty, tz, { dig = true })
    if ok then
      track.x, track.y, track.z = tx, ty, tz
      return true
    end
    -- fall through to tracked steps
  end
  if nav.heading == nil then
    local okc = goOnline("calibrate")
    if okc then nav.calibrate(true) end
    if nav.heading == nil then return false, "no heading" end
  end

  local function digStep(dir)
    if dir == "up" then
      if turtle.detectUp() then turtle.digUp() end
      if turtle.up() then track.y = track.y + 1; return true end
    elseif dir == "down" then
      if turtle.detectDown() then turtle.digDown() end
      if turtle.down() then track.y = track.y - 1; return true end
    else
      if turtle.detect() then turtle.dig() end
      if turtle.forward() then
        local dx, dz = 0, 0
        if nav.heading == titan.NORTH then dz = -1
        elseif nav.heading == titan.SOUTH then dz = 1
        elseif nav.heading == titan.EAST then dx = 1
        elseif nav.heading == titan.WEST then dx = -1 end
        track.x = track.x + dx
        track.z = track.z + dz
        return true
      end
      turtle.attack()
      if turtle.forward() then
        local dx, dz = 0, 0
        if nav.heading == titan.NORTH then dz = -1
        elseif nav.heading == titan.SOUTH then dz = 1
        elseif nav.heading == titan.EAST then dx = 1
        elseif nav.heading == titan.WEST then dx = -1 end
        track.x = track.x + dx
        track.z = track.z + dz
        return true
      end
    end
    return false
  end

  while track.y < ty do if not digStep("up") then return false, "up" end end
  while track.y > ty do if not digStep("down") then return false, "down" end end
  while track.x ~= tx do
    nav.face(track.x < tx and titan.EAST or titan.WEST)
    if not digStep("forward") then return false, "x" end
  end
  while track.z ~= tz do
    nav.face(track.z < tz and titan.SOUTH or titan.NORTH)
    if not digStep("forward") then return false, "z" end
  end
  return true
end

-- Unit vector for a compass heading.
local function headingDelta(h)
  if h == titan.NORTH then return 0, -1 end
  if h == titan.SOUTH then return 0,  1 end
  if h == titan.EAST  then return 1,  0 end
  if h == titan.WEST  then return -1, 0 end
  return nil
end

local function ensureHeading()
  if nav.heading ~= nil then return nav.heading end
  local ok, err = nav.calibrate(true)
  if not ok then print("Calibrate warning: " .. tostring(err)) end
  return nav.heading
end

-- Chest sits one block behind the start/home facing.
local function chestBehindHome(home, facing)
  home = home or cfg.home
  facing = facing or cfg.homeFacing or nav.heading
  if not home or facing == nil then return nil end
  local dx, dz = headingDelta(facing)
  if not dx then return nil end
  -- Behind = opposite of facing.
  return {
    x = home.x - dx,
    y = home.y,
    z = home.z - dz,
  }
end

local function ensureChest()
  if cfg.chest then return cfg.chest end
  local c = chestBehindHome()
  if c then
    cfg.chest = c
    saveCfg()
  end
  return cfg.chest
end

-- Face a neighboring block from the turtle's current position.
local function faceToward(tx, tz)
  local x, _, z = nav.locate(1)
  if not x then return false end
  local dx, dz = tx - x, tz - z
  if math.abs(dx) >= math.abs(dz) then
    if dx > 0 then nav.face(titan.EAST)
    elseif dx < 0 then nav.face(titan.WEST)
    else return false end
  else
    if dz > 0 then nav.face(titan.SOUTH)
    elseif dz < 0 then nav.face(titan.NORTH)
    else return false end
  end
  return true
end

local function dropCargo(dropFn)
  for s = 1, 16 do
    if s ~= FUEL_SLOT and s ~= EQUIP_SLOT then
      turtle.select(s)
      dropFn()
    end
  end
  turtle.select(1)
end

local function suckFuelFromChest()
  if not cfg.fuelChest then return end
  if not goOnline("fuel chest") then return end
  setStatus("refuel", "fuel chest @ " .. fmt(cfg.fuelChest))
  local ok = nav.travelTo(cfg.fuelChest.x, cfg.fuelChest.y, cfg.fuelChest.z)
  if not ok then
    -- Stand next to fuel chest: try adjacent approach via home-level travel
    print("Could not stand on fuel chest coords; trying face-and-suck nearby.")
  end
  faceToward(cfg.fuelChest.x, cfg.fuelChest.z)
  turtle.select(FUEL_SLOT)
  for _ = 1, 8 do
    if turtle.getItemSpace(FUEL_SLOT) <= 0 then break end
    turtle.suck(turtle.getItemSpace(FUEL_SLOT))
  end
  nav.ensureFuel(64)
end

local function dumpInventory()
  -- Always bring modem online before GPS travel / mesh check-in.
  if not goOnline("deposit") then
    print("Need modem in slot " .. EQUIP_SLOT .. " (or equipped) to deposit.")
    return false
  end

  local chest = ensureChest()

  -- Preferred: home start + chest one block behind → face chest and drop().
  if chest and cfg.home then
    setStatus("depositing", "chest @ " .. fmt(chest))
    local ok, err = nav.travelTo(cfg.home.x, cfg.home.y, cfg.home.z)
    if not ok then
      print("Could not reach home/chest: " .. tostring(err))
      return false
    end
    if cfg.homeFacing ~= nil then
      -- Face the mine again, then turn 180 to look at the chest.
      pcall(nav.face, cfg.homeFacing)
      turtle.turnRight(); turtle.turnRight()
      if nav.heading ~= nil then nav.heading = (nav.heading + 2) % 4 end
    else
      faceToward(chest.x, chest.z)
    end
    dropCargo(function() turtle.drop() end)
    -- Face back toward the mine for the next trip out.
    if cfg.homeFacing ~= nil then pcall(nav.face, cfg.homeFacing) end
    if cfg.fuelChest then suckFuelFromChest() end
    syncTrackFromGps(3)
    return true
  end

  -- Legacy: stand above a deposit point and dropDown.
  if cfg.deposit then
    setStatus("depositing", "dumping to " .. fmt(cfg.deposit))
    local ok, err = nav.travelTo(cfg.deposit.x, cfg.deposit.y, cfg.deposit.z)
    if not ok then
      print("Could not reach deposit: " .. tostring(err))
      return false
    end
    dropCargo(function() turtle.dropDown() end)
    if cfg.fuelChest then suckFuelFromChest() end
    syncTrackFromGps(3)
    return true
  end

  print("No chest. Set `home` facing the mine (chest one block behind), or `chest <x> <y> <z>`.")
  return false
end

local function ensureSpace()
  if invFull() then
    if not dumpInventory() then
      setStatus("full", "inventory full, no deposit")
      return false
    end
    -- Resume dig offline if configured.
    goChunkMine()
  end
  return true
end

--------------------------------------------------------------------------------
-- Fuel economy + forward depot relocate
--------------------------------------------------------------------------------
local function manhattan(a, b)
  if not (a and b and a.x and b.x) then return nil end
  return math.abs(a.x - b.x) + math.abs((a.y or 0) - (b.y or 0)) + math.abs(a.z - b.z)
end

local function returnBase()
  return cfg.fuelChest or cfg.home or cfg.chest
end

local function fuelLevelNum()
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return math.huge end
  return tonumber(f) or 0
end

local function noteFuelSample()
  local f = fuelLevelNum()
  if f == math.huge then return end
  local x, y, z = track.x, track.y, track.z
  if not x then
    x, y, z = nav.locate(0.5)
  end
  if fuelEco.lastFuel ~= nil and x and fuelEco.lastX then
    local moved = math.abs(x - fuelEco.lastX)
      + math.abs((y or 0) - (fuelEco.lastY or 0))
      + math.abs((z or 0) - (fuelEco.lastZ or 0))
    local burned = fuelEco.lastFuel - f
    if moved > 0 and burned >= 0 then
      fuelEco.blocks = fuelEco.blocks + moved
      fuelEco.burned = fuelEco.burned + burned
      if fuelEco.blocks >= 8 then
        local rate = fuelEco.burned / fuelEco.blocks
        if rate < 0.25 then rate = 0.25 end
        if rate > 4 then rate = 4 end
        -- EMA toward measured rate
        fuelEco.fuelPerBlock = fuelEco.fuelPerBlock * 0.7 + rate * 0.3
      end
    end
  end
  fuelEco.lastFuel = f
  if x then fuelEco.lastX, fuelEco.lastY, fuelEco.lastZ = x, y, z end
end

local function maxRangeOnTank()
  local f = fuelLevelNum()
  if f == math.huge then return math.huge end
  local rate = fuelEco.fuelPerBlock
  if rate < 0.25 then rate = 0.25 end
  return math.floor(f / rate)
end

local function returnTripCost(fromPos)
  local base = returnBase()
  if not base then return FUEL_RESERVE end
  local pos = fromPos
  if not (pos and pos.x) then
    if hasTrack() then
      pos = { x = track.x, y = track.y, z = track.z }
    else
      local x, y, z = nav.locate(1)
      if x then pos = { x = x, y = y, z = z } end
    end
  end
  local dist = manhattan(pos, base) or 64
  local rate = fuelEco.fuelPerBlock
  if rate < 0.25 then rate = 0.25 end
  return math.ceil(dist * rate) + FUEL_RESERVE
end

local function fuelBudget()
  local f = fuelLevelNum()
  if f == math.huge then
    return {
      unlimited = true, fuel = f, rate = 0, maxRange = math.huge,
      returnCost = 0, digBudget = math.huge, ok = true,
    }
  end
  local rate = fuelEco.fuelPerBlock
  local ret = returnTripCost()
  local digBudget = f - ret
  if digBudget < 0 then digBudget = 0 end
  return {
    unlimited = false,
    fuel = f,
    rate = rate,
    maxRange = maxRangeOnTank(),
    returnCost = ret,
    digBudget = digBudget,
    ok = digBudget >= 8,
  }
end

local function isChestBlock(name)
  name = tostring(name or ""):lower()
  if name:find("chest", 1, true) then return true end
  if name:find("barrel", 1, true) then return true end
  if name:find("shulker", 1, true) then return true end
  return false
end

-- Fuel chest on LEFT, storage BEHIND (relative to current facing into the mine).
local function detectDepotChests()
  local function lookChest()
    local ok, data = turtle.inspect()
    return ok and data and isChestBlock(data.name)
  end
  turtle.turnLeft()
  local leftOk = lookChest()
  turtle.turnRight()
  turtle.turnLeft(); turtle.turnLeft()
  local backOk = lookChest()
  turtle.turnLeft(); turtle.turnLeft()
  return leftOk and backOk, leftOk, backOk
end

local function adoptDepotHere(job)
  goOnline("depot adopt")
  local x, y, z = nav.locatePrecise(4)
  if not x then
    x, y, z = nav.locate(2)
  end
  if not x then
    print("Depot chests seen but no GPS — cannot lock new home.")
    return false
  end
  if nav.heading == nil then
    pcall(nav.calibrate, true)
  end
  cfg.home = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
  cfg.homeFacing = nav.heading
  cfg.chest = chestBehindHome(cfg.home, cfg.homeFacing)
  local dx, dz = headingDelta(cfg.homeFacing)
  if dx then
    -- Left of facing = fuel chest
    -- Facing north (-Z): left is west (-X) → x-1
    -- left vector from heading: north→west, east→north, south→east, west→south
    local lx, lz = 0, 0
    if cfg.homeFacing == titan.NORTH then lx, lz = -1, 0
    elseif cfg.homeFacing == titan.EAST then lx, lz = 0, -1
    elseif cfg.homeFacing == titan.SOUTH then lx, lz = 1, 0
    elseif cfg.homeFacing == titan.WEST then lx, lz = 0, 1
    end
    cfg.fuelChest = {
      x = cfg.home.x + lx, y = cfg.home.y, z = cfg.home.z + lz,
    }
  end
  nav.home = cfg.home
  saveCfg()
  if job then
    job.home, job.chest, job.homeFacing = cfg.home, cfg.chest, cfg.homeFacing
    job.fuelChest = cfg.fuelChest
    job.awaitingDepot = false
    job.depot = nil
    job.active = true
    saveJob(job)
  end
  print("Depot adopted:")
  print("  home      " .. fmt(cfg.home))
  print("  storage  " .. fmt(cfg.chest) .. " (behind)")
  print("  fuel     " .. fmt(cfg.fuelChest) .. " (left)")
  suckFuelFromChest()
  turtle.select(FUEL_SLOT)
  nav.ensureFuel(64)
  noteFuelSample()
  return true
end

local function printDepotInstructions(job)
  local d = job and job.depot
  if not d then
    print("No depot coords saved.")
    return
  end
  print("========== FUEL DEPOT NEEDED ==========")
  print(("Place turtle at: %d, %d, %d"):format(d.x, d.y, d.z))
  if d.facing ~= nil then
    local names = { [0] = "NORTH/-Z", [1] = "EAST/+X", [2] = "SOUTH/+Z", [3] = "WEST/-X" }
    print("Face: " .. (names[d.facing] or tostring(d.facing)) .. " (into the mine)")
  end
  print("Then place:")
  print("  * FUEL chest on the LEFT of the turtle")
  print("  * STORAGE chest BEHIND the turtle")
  print("Miner will auto-detect and continue.")
  print("=======================================")
end

-- Save resume point and wait for player to relocate turtle + chests.
local function requestDepotRelocate(job, y, z, zDir, x)
  goOnline("depot relocate")
  noteFuelSample()
  local gx, gy, gz = nav.locatePrecise(3)
  if not gx and hasTrack() then
    gx, gy, gz = track.x, track.y, track.z
  end
  if not gx then
    setStatus("error", "out of fuel, no GPS for depot")
    return false
  end
  touchJobProgress(job, y, z, zDir, x)
  job.awaitingDepot = true
  job.depot = {
    x = math.floor(gx), y = math.floor(gy), z = math.floor(gz),
    facing = nav.heading, yProg = y, zProg = z, zDir = zDir, xProg = x,
  }
  job.active = true
  saveJob(job)
  setStatus("awaiting_depot", ("place @ %d,%d,%d"):format(job.depot.x, job.depot.y, job.depot.z))
  printDepotInstructions(job)
  -- Dump cargo if we can still reach home; then park for pickup.
  local bud = fuelBudget()
  if bud.fuel >= (bud.returnCost - FUEL_RESERVE) and (cfg.home or cfg.chest or cfg.deposit) then
    pcall(dumpInventory)
  end
  goOnline("awaiting depot")
  return false
end

local function ensureFuel()
  noteFuelSample()
  nav.ensureFuel(64)
  local bud = fuelBudget()
  if bud.unlimited then return true end

  -- Still have dig budget after reserving a return trip.
  if bud.ok then
    if bud.fuel < 16 and cfg.fuelChest then
      -- Top up early if close to empty but somehow return cost is tiny
    end
    return true
  end

  -- Cannot afford more dig + return: try refuel at existing chest first.
  if cfg.fuelChest then
    local before = bud.fuel
    suckFuelFromChest()
    nav.ensureFuel(64)
    noteFuelSample()
    bud = fuelBudget()
    if bud.ok then return true end
    -- Refuel didn't restore enough for another sortie — need forward depot.
    if fuelLevelNum() <= before + 8 then
      -- Chest empty / unreachable
    end
  end

  if activeMineJob then
    local j = activeMineJob
    return requestDepotRelocate(j, j.y, j.z, j.zDir, j.x)
  end

  goOnline("out of fuel")
  setStatus("error", "out of fuel")
  return false
end

local function tryAutoResumeDepot()
  local job = loadJob()
  if not job or job.awaitingDepot ~= true then return false end
  if state.status == "mining" then return false end

  local ok, left, back = detectDepotChests()
  if not ok then return false end

  -- Optional: warn if GPS far from saved depot (still allow — player may fine-tune).
  local d = job.depot
  local x, y, z = nav.locate(1)
  if d and x then
    local dist = math.abs(x - d.x) + math.abs(z - d.z)
    if dist > 6 then
      print(("Depot chests detected but GPS is %d blocks from saved spot %s"):format(
        dist, fmt(d)))
      print("Continuing anyway if you meant to shift the depot.")
    end
  end

  print("Fuel LEFT + storage BEHIND detected — adopting depot and continuing...")
  if not adoptDepotHere(job) then return false end
  if d and d.facing ~= nil then
    pcall(nav.face, d.facing)
  end
  setStatus("mining", "depot resume")
  continueRequested = true
  return true
end

-- Move forward one block, digging if needed (skip if excluded).
local function stepForward()
  if state.stop then return false, "stopped" end
  if not ensureFuel() then return false, "fuel" end
  if not ensureSpace() then return false, "full" end

  local present, data = turtle.inspect()
  if present then
    if isExcluded(data.name) then
      state.skipped = state.skipped + 1
      return false, "excluded:" .. data.name
    end
    turtle.dig()
    state.dug = state.dug + 1
  end
  if turtle.forward() then return true end
  -- mob / leftover
  turtle.attack()
  if turtle.forward() then return true end
  return false, "blocked"
end

local function goDownOne()
  if state.stop then return false, "stopped" end
  if not ensureFuel() then return false, "fuel" end
  local present, data = turtle.inspectDown()
  if present then
    if isExcluded(data.name) then
      state.skipped = state.skipped + 1
      return false, "excluded:" .. data.name
    end
    turtle.digDown()
    state.dug = state.dug + 1
  end
  if turtle.down() then
    if hasTrack() then track.y = track.y - 1 end
    return true
  end
  turtle.attackDown()
  if turtle.down() then
    if hasTrack() then track.y = track.y - 1 end
    return true
  end
  return false, "blocked down"
end

--------------------------------------------------------------------------------
-- Quarry: layer by layer, serpentine X/Z in the corner box, yStart -> yEnd
-- opts.resume = true  -> load miner_job.cfg and continue from GPS / progress
--------------------------------------------------------------------------------
local function mineVolume(opts)
  opts = opts or {}
  local resuming = opts.resume == true
  local job

  if resuming then
    job = loadJob()
    if not job or job.active == false then
      print("No active mine job. Start one with `mine` first.")
      return false
    end
    if not applyJobToCfg(job) then
      print("Saved job is incomplete (need set1/set2/sety).")
      return false
    end
    print("Loaded mine job from miner_job.cfg")
  end

  local b = bounds()
  if not b then
    print("Define the box first:")
    print("  set1 <x> <z>   then   set2 <x> <z>")
    print("  sety <startY> <endY>   or   ystart <y> / yend <y>")
    return false
  end

  loadExclude()
  state.stop = false

  local resumeY, resumeZ, resumeX, resumeZDir
  if resuming then
    state.dug = tonumber(job.dug) or 0
    state.skipped = tonumber(job.skipped) or 0
    local r = resolveResume(job, b)
    resumeY, resumeZ, resumeX, resumeZDir = r.y, r.z, r.x, r.zDir
    print(("Continuing from %s: X=%s Z=%d Y=%d (zDir=%d)"):format(
      r.from, tostring(resumeX or "?"), resumeZ, resumeY, resumeZDir))
    if job.init then
      print(("Job init location: %s"):format(fmt(job.init)))
    end
  else
    state.dug, state.skipped = 0, 0
    local ix, iy, iz = nav.locatePrecise(3)
    local init = (ix and { x = ix, y = iy, z = iz }) or cfg.home
    job = {
      active = true,
      loc1 = cfg.loc1,
      loc2 = cfg.loc2,
      yStart = b.topY,
      yEnd = b.floorY,
      init = init,
      home = cfg.home,
      chest = cfg.chest,
      homeFacing = cfg.homeFacing,
      y = b.topY,
      z = b.minZ,
      zDir = 1,
      x = b.minX,
      dug = 0,
      skipped = 0,
      started = os.epoch("utc"),
      updated = os.epoch("utc"),
    }
    saveJob(job)
    print("Saved mine job -> miner_job.cfg (use `continue` after unload)")
    resumeY, resumeZ, resumeX, resumeZDir = b.topY, b.minZ, nil, 1
  end

  setStatus("mining", ("box %d..%d,%d..%d Y%d->%d"):format(
    b.minX, b.maxX, b.minZ, b.maxZ, b.topY, b.floorY))
  print(("Mining box  X %d..%d  Z %d..%d  Y %d -> %d"):format(
    b.minX, b.maxX, b.minZ, b.maxZ, b.topY, b.floorY))

  -- Remember home + chest-behind if not set
  if not cfg.home then
    local x, y, z = nav.locatePrecise(3)
    if x then
      cfg.home = { x = x, y = y, z = z }
      cfg.homeFacing = nav.heading or cfg.homeFacing
      if not cfg.chest then cfg.chest = chestBehindHome() end
      saveCfg()
      if job then
        job.home, job.chest, job.homeFacing = cfg.home, cfg.chest, cfg.homeFacing
        if not job.init then job.init = { x = x, y = y, z = z } end
        saveJob(job)
      end
    end
  elseif not cfg.chest then
    ensureChest()
  end

  if nav.heading == nil then
    local ok, err = nav.calibrate(true)
    if not ok then
      print("Calibrate failed: " .. tostring(err))
      setStatus("error", "calibrate failed")
      touchJobProgress(job, resumeY, resumeZ, resumeZDir, resumeX)
      return false
    end
  end

  -- Fix GPS pose, then optionally swap to chunk loader for offline dig.
  goOnline("mine start")
  syncTrackFromGps(4)
  noteFuelSample()
  activeMineJob = job
  if job.awaitingDepot then
    print("Job is awaiting a fuel depot — place chests or run `depot` / `continue` after setup.")
    printDepotInstructions(job)
    setStatus("awaiting_depot", job.depot and fmt(job.depot) or "depot")
    activeMineJob = nil
    return false
  end
  do
    local bud = fuelBudget()
    if not bud.unlimited then
      print(("Fuel: %d  ~%.2f/block  maxRange=%s  returnCost=%d  digBudget=%d"):format(
        bud.fuel, bud.rate, tostring(bud.maxRange), bud.returnCost, bud.digBudget))
    end
  end
  if cfg.selfChunk then
    if goChunkMine() then
      print("selfChunk ON — digging offline; modem parked in slot " .. EQUIP_SLOT)
    else
      print("selfChunk ON but no chunk loader found — staying on modem.")
    end
  end

  local function digMoveTo(tx, ty, tz)
    if cfg.selfChunk and state.netMode == "chunk" then
      local ok, err = trackMoveTo(tx, ty, tz)
      noteFuelSample()
      return ok, err
    end
    local ok, err = nav.moveTo(tx, ty, tz, { dig = true })
    if ok and hasTrack() then track.x, track.y, track.z = tx, ty, tz end
    noteFuelSample()
    return ok, err
  end

  for y = resumeY, b.floorY, -1 do
    if state.stop then break end
    setStatus("mining", ("layer Y=%d %s"):format(y, state.netMode or ""))
    print(("--- Layer Y=%d ---"):format(y))

    local z = (y == resumeY) and resumeZ or b.minZ
    local zDir = (y == resumeY) and (resumeZDir or zDirAt(b, z)) or 1
    while z <= b.maxZ do
      if state.stop then break end

      local startX = (zDir == 1) and b.minX or b.maxX
      local endX   = (zDir == 1) and b.maxX or b.minX
      local step   = zDir
      local x = startX
      -- Mid-row resume: start at current X on this layer/row only.
      if y == resumeY and z == resumeZ and resumeX ~= nil then
        x = resumeX
        -- Clear one-shot resume so later rows start at the edge.
        resumeX, resumeZ, resumeY = nil, nil, nil
      end

      local ok, err = digMoveTo(x, y, z)
      if not ok then
        print("moveTo failed: " .. tostring(err) .. " — trying cell-by-cell")
      end
      touchJobProgress(job, y, z, zDir, x)

      nav.face(zDir == 1 and titan.EAST or titan.WEST)

      while true do
        if state.stop then break end
        if not ensureFuel() or not ensureSpace() then
          touchJobProgress(job, y, z, zDir, x)
          if state.status == "awaiting_depot" then
            activeMineJob = nil
            return false
          end
          setStatus("error", state.task)
          activeMineJob = nil
          return false
        end

        -- GPS optional while selfChunk offline — trust serpentine x counter + track.
        if not (cfg.selfChunk and state.netMode == "chunk") then
          local cx = nav.locate(1)
          if not cx then
            touchJobProgress(job, y, z, zDir, x)
            print("Lost GPS"); setStatus("error", "no GPS"); return false
          end
        end

        if (step == 1 and x >= endX) or (step == -1 and x <= endX) then
          break
        end

        local moved, why = stepForward()
        if moved and hasTrack() and nav.heading ~= nil then
          local dx, dz = 0, 0
          if nav.heading == titan.NORTH then dz = -1
          elseif nav.heading == titan.SOUTH then dz = 1
          elseif nav.heading == titan.EAST then dx = 1
          elseif nav.heading == titan.WEST then dx = -1 end
          track.x = track.x + dx
          track.z = track.z + dz
        end
        if not moved then
          if tostring(why):find("^excluded") then
            print("Skip excluded at row: " .. tostring(why))
            tryDig("up")
            if turtle.up() then
              local ok2 = turtle.forward()
              if ok2 then
                tryDig("down")
                turtle.down()
                x = x + step
              else
                turtle.down()
                x = x + step
                digMoveTo(x, y, z)
                nav.face(step == 1 and titan.EAST or titan.WEST)
              end
            else
              x = x + step
              digMoveTo(x, y, z)
              nav.face(step == 1 and titan.EAST or titan.WEST)
            end
          else
            print("Blocked: " .. tostring(why))
            x = x + step
            digMoveTo(x, y, z)
            nav.face(step == 1 and titan.EAST or titan.WEST)
          end
        else
          x = x + step
        end
        touchJobProgress(job, y, z, zDir, x)
      end

      z = z + 1
      zDir = -zDir
      touchJobProgress(job, y, z <= b.maxZ and z or b.maxZ, zDir,
        (zDir == 1) and b.minX or b.maxX)
    end

    if y > b.floorY and not state.stop then
      local okd, whyd = goDownOne()
      if not okd and not tostring(whyd):find("^excluded") then
        print("Could not descend: " .. tostring(whyd))
      end
      touchJobProgress(job, y - 1, b.minZ, 1, b.minX)
    end
  end

  if state.status == "awaiting_depot" then
    activeMineJob = nil
    return false
  end

  -- Dump leftovers and return home
  if cfg.deposit or cfg.chest or cfg.home then dumpInventory() end
  if cfg.home then
    setStatus("returning", "home")
    nav.travelTo(cfg.home.x, cfg.home.y, cfg.home.z)
  end

  if state.stop then
    touchJobProgress(job, job.y, job.z, job.zDir, job.x)
    job.active = true
    saveJob(job)
    setStatus("stopped", ("paused dug=%d — `continue` to resume"):format(state.dug))
    print(("Mine paused. dug=%d skipped=%d  (run `continue`)"):format(state.dug, state.skipped))
  else
    job.active = false
    job.awaitingDepot = false
    job.depot = nil
    job.finished = os.epoch("utc")
    job.dug, job.skipped = state.dug, state.skipped
    saveJob(job)
    setStatus("idle", ("done dug=%d skipped=%d"):format(state.dug, state.skipped))
    print(("Mine finished. dug=%d skipped=%d"):format(state.dug, state.skipped))
  end
  activeMineJob = nil
  return true
end

local function continueMine()
  return mineVolume({ resume = true })
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function printStatus()
  print(("status: %s  task: %s"):format(state.status, state.task))
  print(("corner1 (set1): %s"):format(fmt(cfg.loc1)))
  print(("corner2 (set2): %s"):format(fmt(cfg.loc2)))
  local topY, floorY = yRange()
  if topY then
    print(("Y range: start=%d  end=%d  (mine high -> low)"):format(topY, floorY))
  else
    print(("Y range: start=%s  end=%s"):format(
      tostring(cfg.yStart or "?"), tostring(cfg.yEnd or cfg.floorY or "?")))
  end
  print(("home: %s"):format(fmt(cfg.home)))
  local chest = cfg.chest or chestBehindHome()
  print(("chest: %s%s"):format(fmt(chest), cfg.chest and "" or " (auto behind home)"))
  if cfg.fuelChest then print(("fuelChest: %s"):format(fmt(cfg.fuelChest))) end
  if cfg.deposit then print(("deposit (legacy): %s"):format(fmt(cfg.deposit))) end
  print(("selfChunk=%s  netMode=%s  equipSlot=%d"):format(
    tostring(cfg.selfChunk), tostring(state.netMode), EQUIP_SLOT))
  if hasTrack() then
    print(("track: %d,%d,%d"):format(track.x, track.y, track.z))
  end
  if cfg.siteId then print("siteId: " .. tostring(cfg.siteId)) end
  local b = bounds()
  if b then
    local dx = b.maxX - b.minX + 1
    local dz = b.maxZ - b.minZ + 1
    local dy = b.topY - b.floorY + 1
    print(("box: %dx%dx%d (~%d blocks)  X[%d..%d] Z[%d..%d] Y[%d..%d]"):format(
      dx, dz, dy, dx * dz * dy, b.minX, b.maxX, b.minZ, b.maxZ, b.topY, b.floorY))
  else
    print("box: incomplete — need set1, set2, and ystart+yend (or sety)")
  end
  print(("dug=%d skipped=%d fuel=%s"):format(
    state.dug, state.skipped, tostring(turtle.getFuelLevel())))
  local bud = fuelBudget()
  if bud.unlimited then
    print("fuel eco: unlimited")
  else
    print(("fuel eco: %.2f fuel/block  maxRange=%d  returnCost=%d  digBudget=%d"):format(
      bud.rate, bud.maxRange, bud.returnCost, bud.digBudget))
  end
  local job = loadJob()
  if job and job.active ~= false then
    print(("job: ACTIVE  progress Y=%s Z=%s X=%s  (continue to resume)"):format(
      tostring(job.y), tostring(job.z), tostring(job.x)))
    if job.init then print("job init: " .. fmt(job.init)) end
    if job.awaitingDepot and job.depot then
      print("AWAITING DEPOT:")
      printDepotInstructions(job)
    end
  elseif job then
    print("job: finished (miner_job.cfg kept for reference)")
  end
end

local function printXZBox()
  if not (cfg.loc1 and cfg.loc2) then return end
  print(("X/Z box: %d..%d , %d..%d"):format(
    math.min(cfg.loc1.x, cfg.loc2.x), math.max(cfg.loc1.x, cfg.loc2.x),
    math.min(cfg.loc1.z, cfg.loc2.z), math.max(cfg.loc1.z, cfg.loc2.z)))
  print("Next: sety <startY> <endY>  (or ystart / yend)")
end

-- set1/set2 corners: X/Z required. Y is unused for the footprint (kept for status).
local function setCornerXZ(field, x, z, y)
  x, z = tonumber(x), tonumber(z)
  if not x or not z then
    print(("Usage: %s <x> <z>"):format(field == "loc1" and "set1" or "set2"))
    print("Example: set1 100 200")
    return false
  end
  y = tonumber(y)
  if not y then
    local gx, gy, gz = nav.locate(1)
    y = gy or 0
  end
  cfg[field] = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
  saveCfg()
  print(("%s = %d, %d  (X,Z)"):format(
    field == "loc1" and "set1" or "set2", cfg[field].x, cfg[field].z))
  printXZBox()
  return true
end

local function setHomeHere()
  local x, y, z = nav.locatePrecise(4)
  if not x then print("No GPS signal."); return false end
  local facing = ensureHeading()
  cfg.home = { x = x, y = y, z = z }
  cfg.homeFacing = facing
  nav.home = cfg.home
  local chest = chestBehindHome(cfg.home, facing)
  if chest then
    cfg.chest = chest
  end
  saveCfg()
  local dirs = { [0] = "N", [1] = "E", [2] = "S", [3] = "W" }
  print(("home = %s  facing %s"):format(fmt(cfg.home), dirs[facing] or "?"))
  if cfg.chest then
    print(("chest = %s  (one block behind home)"):format(fmt(cfg.chest)))
  else
    print("Could not compute chest behind home (calibrate heading, then `home` again).")
  end
  return true
end

local function markHere(field)
  if field == "home" then
    return setHomeHere()
  end
  local x, y, z = nav.locatePrecise(4)
  if not x then print("No GPS signal."); return end
  cfg[field] = { x = x, y = y, z = z }
  saveCfg()
  local fix = nav.lastFix
  if fix then
    print(("%s set to %s  (Y %.2f..%.2f n=%d)"):format(
      field, fmt(cfg[field]), fix.yLo, fix.yHi, fix.n))
  else
    print(("%s set to %s"):format(field, fmt(cfg[field])))
  end
  if field == "loc1" or field == "loc2" then printXZBox() end
end

local function setYStart(y)
  y = tonumber(y)
  if not y then return nil, "need a number" end
  cfg.yStart = math.floor(y)
  saveCfg()
  return cfg.yStart
end

local function setYEnd(y)
  y = tonumber(y)
  if not y then return nil, "need a number" end
  cfg.yEnd = math.floor(y)
  cfg.floorY = cfg.yEnd
  saveCfg()
  return cfg.yEnd
end

local function headingVec(h)
  h = h % 4
  if h == titan.NORTH then return 0, -1
  elseif h == titan.EAST then return 1, 0
  elseif h == titan.SOUTH then return 0, 1
  else return -1, 0 end
end

local function rightVec(h)
  return headingVec((h + 1) % 4)
end

-- Quick flatten: mine WxD from current GPS, forward + right, down to yEnd.
local function setupMineSize(w, d, yEnd)
  w, d, yEnd = tonumber(w), tonumber(d), tonumber(yEnd)
  if not (w and d and yEnd) or w < 1 or d < 1 then
    return false, "Usage: mine <W>x<D> <yEnd>   e.g. mine 5x5 -59"
  end
  if nav.heading == nil then
    local ok, err = nav.calibrate(true)
    if not ok then return false, "calibrate: " .. tostring(err) end
  end
  local x, y, z = nav.locatePrecise(4)
  if not x then return false, "no GPS" end
  local fx, fz = headingVec(nav.heading)
  local rx, rz = rightVec(nav.heading)
  local x2 = x + fx * (d - 1) + rx * (w - 1)
  local z2 = z + fz * (d - 1) + rz * (w - 1)
  cfg.loc1 = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
  cfg.loc2 = { x = math.floor(x2), y = math.floor(y), z = math.floor(z2) }
  cfg.yStart = math.floor(y)
  cfg.yEnd = math.floor(yEnd)
  cfg.floorY = cfg.yEnd
  if not cfg.home then
    cfg.home = { x = cfg.loc1.x, y = cfg.loc1.y, z = cfg.loc1.z }
    cfg.homeFacing = nav.heading
  end
  saveCfg()
  return true, bounds()
end

local function applyStripJob(job)
  if type(job) ~= "table" then return false, "bad job" end
  local x1, z1 = tonumber(job.x1), tonumber(job.z1)
  local x2, z2 = tonumber(job.x2), tonumber(job.z2)
  local yEnd = tonumber(job.yEnd or job.y)
  if not (x1 and z1 and x2 and z2 and yEnd) then
    return false, "job needs x1,z1,x2,z2,yEnd"
  end
  cfg.loc1 = { x = math.floor(x1), z = math.floor(z1), y = tonumber(job.yStart) or 0 }
  cfg.loc2 = { x = math.floor(x2), z = math.floor(z2), y = tonumber(job.yStart) or 0 }
  cfg.yEnd = math.floor(yEnd)
  cfg.floorY = cfg.yEnd
  if job.yStart ~= nil then cfg.yStart = math.floor(tonumber(job.yStart)) end
  if tonumber(job.cruiseY) then cfg.cruiseY = math.floor(tonumber(job.cruiseY)) end
  state.jobId = job.jobId or job.id
  saveCfg()
  return true
end

local function goCruiseTo(tx, ty, tz)
  local cruise = tonumber(cfg.cruiseY) or 150
  return nav.travelTo(tx, ty, tz, { dig = true, cruiseY = cruise })
end

local function returnToStage()
  local dest = cfg.stage or cfg.home
  if not dest then return false, "no stage/home" end
  setStatus("returning", "-> stage")
  local ok, err = goCruiseTo(dest.x, dest.y, dest.z)
  setStatus(ok and "idle" or "error", ok and "-" or tostring(err))
  return ok, err
end

-- Run an assigned strip: fly via cruise, set top Y from arrival GPS if needed, dig, return.
local function runAssignedJob(job)
  local ok, err = applyStripJob(job)
  if not ok then print(tostring(err)); return false end
  if job.storage or job.chest then
    local s = job.storage or job.chest
    if s.x then cfg.chest = { x = math.floor(s.x), y = math.floor(s.y), z = math.floor(s.z) } end
  end
  if job.fuelChest or job.fuel then
    local s = job.fuelChest or job.fuel
    if s.x then cfg.fuelChest = { x = math.floor(s.x), y = math.floor(s.y), z = math.floor(s.z) } end
  end
  if job.selfChunk ~= nil then cfg.selfChunk = not not job.selfChunk end
  if job.siteId then cfg.siteId = job.siteId end
  saveCfg()
  local b = bounds()
  if not b and cfg.yStart == nil then
    -- yStart filled after arrival
  end
  local midX = math.floor((cfg.loc1.x + cfg.loc2.x) / 2)
  local midZ = math.floor((cfg.loc1.z + cfg.loc2.z) / 2)
  local approachY = tonumber(job.approachY) or tonumber(cfg.yStart) or (tonumber(cfg.cruiseY) or 150)
  goOnline("job travel")
  setStatus("moving", ("job %s via Y%d"):format(tostring(state.jobId or "?"), tonumber(cfg.cruiseY) or 150))
  print(("Traveling to strip @ %d,%d (cruise %d)..."):format(midX, midZ, tonumber(cfg.cruiseY) or 150))
  local tok, terr = goCruiseTo(midX, approachY, midZ)
  if not tok then
    setStatus("error", tostring(terr))
    print("Travel failed: " .. tostring(terr))
    return false
  end
  local _, y = nav.locatePrecise(3)
  if tonumber(job.yStart) ~= nil then
    -- Fleet / marker jobs pin the Y band — do not override from GPS.
    cfg.yStart = math.floor(tonumber(job.yStart))
    if tonumber(job.yEnd) ~= nil then
      cfg.yEnd = math.floor(tonumber(job.yEnd))
      cfg.floorY = cfg.yEnd
    end
    saveCfg()
  elseif y and cfg.yStart == nil then
    cfg.yStart = math.floor(y)
    saveCfg()
  elseif y then
    cfg.yStart = math.max(cfg.yStart or y, math.floor(y))
    saveCfg()
  end
  if not quarryReady() then
    print("Strip not ready after arrival.")
    setStatus("error", "bad strip")
    return false
  end
  local bb = bounds()
  if bb then
    print(("Assigned dig Y[%d->%d] X[%d..%d] Z[%d..%d]"):format(
      bb.topY, bb.floorY, bb.minX, bb.maxX, bb.minZ, bb.maxZ))
  end
  mineVolume()
  if job.returnStage ~= false then
    returnToStage()
  end
  if job.replyTo then
    titan.send(job.replyTo, MSG.MINE_JOB_ACK, {
      ok = true, jobId = state.jobId, dug = state.dug,
      name = cfg.name, status = state.status,
    })
  end
  return true
end

-- Returns "exit" to quit local console, false for unknown (shell fallthrough over SSH).
local function handleCommand(a)
  local cmd = (a[1] or ""):lower()

  if cmd == "" then
    return true
  elseif cmd == "help" then
    print("BOX (opposite corners + Y range):")
    print("  set1 <x> <z>             corner A (X/Z)")
    print("  set2 <x> <z>             corner B (X/Z)")
    print("  set1 here / set2 here    use current GPS X/Z")
    print("  sety <startY> <endY>     vertical range (e.g. sety 80 -59)")
    print("  ystart <y> / yend <y>    set start or end Y alone")
    print("  yhere start|end          use current GPS Y")
    print("OTHER:")
    print("  home / start   mark start (face the mine; chest = 1 block behind)")
    print("  chest / storage [x y z]   storage chest (or behind home)")
    print("  fuelchest [x y z|here]    site fuel chest")
    print("  deposit        legacy: stand ABOVE a chest (dropDown)")
    print("  selfchunk on|off          dig with chunk loader; modem in slot 15")
    print("  modem | chunk | swap      force equipment swap (slot 15)")
    print("  exclude   reload & show exclude.txt")
    print("  mine                 dig configured box")
    print("  mine <W>x<D> <yEnd>  flatten from here (e.g. mine 5x5 -59)")
    print("  continue  resume after unload/reboot from GPS/job")
    print("  stage [here|x y z]   fleet parking sheet slot")
    print("  cruise [y]           long-hop altitude (default 150)")
    print("  fuel | eco           fuel burn rate / max range / return budget")
    print("  depot                show saved depot coords / try auto-resume")
    print("  stop | status | dump | goto <x> <y> <z>")
    print("  hostname [name] | exit")
  elseif cmd == "hostname" or cmd == "host" then
    if not a[2] then
      print("hostname: " .. (os.getComputerLabel() or "?"))
    else
      local name, err = titan.setHostname(table.concat(a, " ", 2), "miner")
      if name then print("hostname set: " .. name) else print(tostring(err)) end
    end
  elseif cmd == "set1" or cmd == "corner1" then
    local sub = (a[2] or ""):lower()
    if sub == "" then
      print("Usage: set1 <x> <z>   or   set1 here")
    elseif sub == "here" or sub == "gps" or sub == "me" then
      markHere("loc1")
    else
      setCornerXZ("loc1", a[2], a[3], a[4])
    end
  elseif cmd == "set2" or cmd == "corner2" then
    local sub = (a[2] or ""):lower()
    if sub == "" then
      print("Usage: set2 <x> <z>   or   set2 here")
    elseif sub == "here" or sub == "gps" or sub == "me" then
      markHere("loc2")
    else
      setCornerXZ("loc2", a[2], a[3], a[4])
    end
  elseif cmd == "sety" then
    local ys, ye = tonumber(a[2]), tonumber(a[3])
    if ys and ye then
      setYStart(ys); setYEnd(ye)
      local topY, floorY = yRange()
      print(("Y range: start=%d  end=%d  (will mine %d -> %d)"):format(
        ys, ye, topY, floorY))
    elseif ys and not ye then
      setYEnd(ys)
      print(("yend (bottom) = %d   (also: sety <startY> <endY>)"):format(cfg.yEnd))
    else
      print("Usage: sety <startY> <endY>")
      print("  startY = top of the box (begin mining here)")
      print("  endY   = bottom of the box (stop here, inclusive)")
    end
  elseif cmd == "ystart" or cmd == "ytop" or cmd == "starty" then
    local y, err = setYStart(a[2])
    if y then print("ystart (top) = " .. y) else print("Usage: ystart <y>  (" .. tostring(err) .. ")") end
  elseif cmd == "yend" or cmd == "ybottom" or cmd == "endy" or cmd == "floor" then
    local y, err = setYEnd(a[2])
    if y then print("yend (bottom) = " .. y) else print("Usage: yend <y>  (" .. tostring(err) .. ")") end
  elseif cmd == "yhere" then
    local which = (a[2] or ""):lower()
    local x, y, z = nav.locatePrecise(4)
    if not y then print("No GPS signal.")
    elseif which == "start" or which == "top" or which == "ystart" then
      setYStart(y)
      local fix = nav.lastFix
      print(("ystart = %d (GPS Y; range %.2f..%.2f)"):format(
        cfg.yStart, fix and fix.yLo or y, fix and fix.yHi or y))
    elseif which == "end" or which == "bottom" or which == "yend" then
      setYEnd(y)
      local fix = nav.lastFix
      print(("yend = %d (GPS Y; range %.2f..%.2f)"):format(
        cfg.yEnd, fix and fix.yLo or y, fix and fix.yHi or y))
    else
      print("Usage: yhere start | yhere end")
    end
  elseif cmd == "deposit" then
    markHere("deposit")
    print("(Legacy dropDown mode. Prefer `home` with chest behind.)")
  elseif cmd == "home" or cmd == "start" then
    setHomeHere()
  elseif cmd == "chest" or cmd == "storage" then
    if a[2] and a[3] and a[4] then
      local x, y, z = tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
      if not x then
        print("Usage: chest <x> <y> <z>   or   chest   (recompute behind home)")
      else
        cfg.chest = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
        saveCfg()
        print("chest = " .. fmt(cfg.chest))
      end
    else
      if not cfg.home then
        print("Set `home` first (stand at start, face the mine).")
      else
        local c = chestBehindHome()
        if c then
          cfg.chest = c
          saveCfg()
          print("chest = " .. fmt(cfg.chest) .. "  (behind home)")
        else
          print("Need heading — run `home` again facing the mine.")
        end
      end
    end
  elseif cmd == "fuelchest" then
    if (a[2] or ""):lower() == "here" then
      local x, y, z = nav.locatePrecise(4)
      if not x then print("No GPS.") else
        cfg.fuelChest = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
        saveCfg()
        print("fuelChest = " .. fmt(cfg.fuelChest))
      end
    elseif a[2] and a[3] and a[4] then
      cfg.fuelChest = {
        x = math.floor(tonumber(a[2])), y = math.floor(tonumber(a[3])),
        z = math.floor(tonumber(a[4])),
      }
      saveCfg()
      print("fuelChest = " .. fmt(cfg.fuelChest))
    elseif (a[2] or ""):lower() == "clear" then
      cfg.fuelChest = nil; saveCfg(); print("fuelChest cleared")
    else
      print("fuelChest = " .. fmt(cfg.fuelChest))
      print("Usage: fuelchest <x> <y> <z> | fuelchest here | fuelchest clear")
      print("(tank stats: eco)")
    end
  elseif cmd == "selfchunk" or cmd == "chunkmode" then
    local v = (a[2] or ""):lower()
    if v == "on" or v == "true" or v == "1" then
      cfg.selfChunk = true; saveCfg()
      print("selfChunk ON — put chunk loader in slot " .. EQUIP_SLOT .. " (modem swaps there while digging)")
    elseif v == "off" or v == "false" or v == "0" then
      cfg.selfChunk = false; saveCfg()
      goOnline("selfChunk off")
      print("selfChunk OFF — modem stays equipped")
    else
      print("selfChunk = " .. tostring(cfg.selfChunk))
      print("Usage: selfchunk on|off")
    end
  elseif cmd == "modem" or cmd == "online" then
    goOnline("manual")
  elseif cmd == "chunk" or cmd == "chunker" then
    cfg.selfChunk = true; saveCfg()
    if not syncTrackFromGps(2) then syncTrackFromGps(4) end
    local ok, err = ensureChunkerEquipped()
    if not ok then print("Chunk equip failed: " .. tostring(err)) end
  elseif cmd == "swap" then
    if modemSideEquipped() then
      cfg.selfChunk = true; saveCfg()
      ensureChunkerEquipped()
    else
      goOnline("swap")
    end
  elseif cmd == "fuel" or cmd == "eco" then
    noteFuelSample()
    local bud = fuelBudget()
    print(("tank=%s  samples blocks=%d burned=%d"):format(
      tostring(turtle.getFuelLevel()), fuelEco.blocks, fuelEco.burned))
    if bud.unlimited then
      print("unlimited fuel")
    else
      print(("rate=%.3f fuel/block  maxRange=%d blocks on this tank"):format(
        bud.rate, bud.maxRange))
      print(("return to %s costs ~%d  digBudget=%d %s"):format(
        fmt(returnBase()), bud.returnCost, bud.digBudget,
        bud.ok and "(ok)" or "(NEED DEPOT / REFUEL)"))
    end
  elseif cmd == "depot" then
    local job = loadJob()
    if a[2] and (a[2]:lower() == "try" or a[2]:lower() == "resume" or a[2]:lower() == "check") then
      if tryAutoResumeDepot() then
        print("Depot resume queued.")
      else
        print("No depot chests detected (need fuel LEFT + storage BEHIND).")
        if job and job.depot then printDepotInstructions(job) end
      end
    elseif job and job.depot then
      printDepotInstructions(job)
    else
      print("No depot saved. Miner writes one when digBudget runs out.")
    end
  elseif cmd == "exclude" then
    loadExclude()
    print("Excluded blocks:")
    local n = 0
    for name in pairs(exclude) do print("  " .. name); n = n + 1 end
    if n == 0 then print("  (none - edit exclude.txt)") end
    print("(also respects titan.RESTRICTED / computercraft:*)")
  elseif cmd == "status" then
    printStatus()
  elseif cmd == "mine" then
    if state.status == "mining" then print("Already mining.")
    elseif a[2] then
      -- mine 5x5 -59  OR  mine 5 5 -59
      local w, d, yEnd
      local m = tostring(a[2]):match("^(%d+)[xX](%d+)$")
      if m then
        w, d = tostring(a[2]):match("^(%d+)[xX](%d+)$")
        yEnd = a[3]
      else
        w, d, yEnd = a[2], a[3], a[4]
      end
      local ok, bOrErr = setupMineSize(w, d, yEnd)
      if not ok then print(tostring(bOrErr))
      else
        local b = bOrErr
        print(("Box X[%d..%d] Z[%d..%d] Y %d -> %d"):format(
          b.minX, b.maxX, b.minZ, b.maxZ, b.topY, b.floorY))
        mineVolume()
      end
    elseif not quarryReady() then
      print("Box incomplete. Need set1/set2/sety, or: mine <W>x<D> <yEnd>")
      printStatus()
    else
      mineVolume()
    end
  elseif cmd == "stage" then
    if not a[2] or a[2]:lower() == "here" then
      local x, y, z = nav.locatePrecise(3)
      if not x then print("No GPS.") else
        cfg.stage = { x = x, y = y, z = z }
        saveCfg()
        print("stage = " .. fmt(cfg.stage))
      end
    elseif a[2] and a[3] and a[4] then
      cfg.stage = {
        x = math.floor(tonumber(a[2])),
        y = math.floor(tonumber(a[3])),
        z = math.floor(tonumber(a[4])),
      }
      saveCfg()
      print("stage = " .. fmt(cfg.stage))
    else
      print("stage: " .. fmt(cfg.stage))
      print("Usage: stage here | stage <x> <y> <z>")
    end
  elseif cmd == "cruise" then
    if not a[2] then
      print("cruiseY = " .. tostring(cfg.cruiseY or 150))
    else
      cfg.cruiseY = math.floor(tonumber(a[2]) or 150)
      saveCfg()
      print("cruiseY = " .. cfg.cruiseY)
    end
  elseif cmd == "continue" or cmd == "resume" then
    if state.status == "mining" then print("Already mining.")
    else
      local job = loadJob()
      if not job or job.active == false then
        print("No active mine job in miner_job.cfg. Run `mine` first.")
      else
        continueMine()
      end
    end
  elseif cmd == "stop" then
    state.stop = true
    print("Stop requested (job kept — `continue` to resume).")
  elseif cmd == "dump" then
    dumpInventory()
  elseif cmd == "goto" then
    local x, y, z = tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
    if not x then print("Usage: goto <x> <y> <z>"); else
      setStatus("moving", ("goto %d,%d,%d"):format(x, y, z))
      local ok, err = nav.travelTo(x, y, z)
      print(ok and "Arrived." or ("Failed: " .. tostring(err)))
      setStatus("idle", "-")
    end
  elseif cmd == "exit" or cmd == "quit" then
    state.stop = true
    return "exit"
  else
    return false
  end
  return true
end

local function consoleLoop()
  print(("Titan miner '%s'. Type 'help'."):format(cfg.name or ("#" .. os.getComputerID())))
  printStatus()
  while true do
    write("miner> ")
    local a = {}
    for word in tostring(read()):gmatch("%S+") do a[#a + 1] = word end
    local r = handleCommand(a)
    if r == "exit" then return
    elseif r == false then
      print("Unknown: " .. tostring(a[1] or "") .. "  (type 'help')")
    end
  end
end

titan.setSshHandler(function(line)
  local a = {}
  for w in tostring(line):gmatch("%S+") do a[#a + 1] = w end
  local r = handleCommand(a)
  if r == "exit" then
    print("Over SSH: type `exit` to disconnect (miner keeps running).")
    return true
  end
  if r == false then
    print("Unknown: " .. tostring(a[1] or "") .. "  (type 'help')")
  end
  return true
end)

--------------------------------------------------------------------------------
-- Deploy (Parent Center) + status + remote orders
--------------------------------------------------------------------------------
local function applyDeployment(d)
  local t = tostring(d.botType or ""):lower()
  if t == "mine" then t = "miner" end
  if t == "builder" or t == "gatherer" then
    return false, "this turtle runs miner.lua — install/run worker.lua for builder/gatherer"
  end
  if t ~= "miner" then return false, "bad type (want miner)" end
  local name = titan.uniqueBotName("miner", os.getComputerID())
  print(("Deploying as miner '%s' (unique name)..."):format(name))
  local ok, err = nav.calibrate(true)
  if not ok then print("Calibrate warning: " .. tostring(err)) end
  local hx, hy, hz = nav.locate(2)
  local home = hx and { x = hx, y = hy, z = hz } or nil
  cfg.name = name
  cfg.botType = "miner"
  cfg.home = home or cfg.home
  cfg.homeFacing = nav.heading or cfg.homeFacing
  if cfg.home and not cfg.chest then
    cfg.chest = chestBehindHome(cfg.home, cfg.homeFacing)
  end
  if d.deposit then
    -- Parent Center coords are treated as the chest block (behind start).
    cfg.chest = d.deposit
    cfg.deposit = nil
  end
  if type(d.stage) == "table" and d.stage.x then
    cfg.stage = {
      x = math.floor(tonumber(d.stage.x)),
      y = math.floor(tonumber(d.stage.y) or 64),
      z = math.floor(tonumber(d.stage.z)),
    }
  end
  if tonumber(d.cruiseY) then cfg.cruiseY = math.floor(tonumber(d.cruiseY)) end
  saveCfg()
  os.setComputerLabel(name)
  if cfg.home then nav.home = cfg.home end
  if cfg.chest then
    print(("chest @ %s (behind home)"):format(fmt(cfg.chest)))
  end
  return true
end

local function awaitDeployment()
  setStatus("await", "awaiting deployment")
  local awaitName = "await-" .. os.getComputerID()
  os.setComputerLabel(awaitName)
  print("Unconfigured miner. Waiting for Parent Center deploy...")
  print("  deploy <id> miner")
  print("I will become Miner-" .. os.getComputerID() .. " on deploy.")
  local beacon = os.startTimer(0)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "timer" and p1 == beacon then
      local x, y, z = nav.locate(1)
      titan.broadcast(MSG.WORKER_AWAIT, {
        name = awaitName, kind = "miner", x = x, y = y, z = z,
      })
      beacon = os.startTimer(3)
    elseif ev == "rednet_message" and p3 == P and type(p2) == "table"
           and p2.type == MSG.WORKER_DEPLOY then
      local ok, why = applyDeployment(p2)
      if ok then
        titan.send(p1, MSG.WORKER_DEPLOYED, { name = cfg.name, botType = "miner" })
        return
      else
        titan.send(p1, MSG.WORKER_DEPLOYED, { ok = false, err = why })
        print("Deploy rejected: " .. tostring(why))
      end
    end
  end
end

local function statusLoop()
  if cfg.name and not titan.isUniqueBotName(cfg.name, "miner") then
    cfg.name = titan.uniqueBotName("miner", os.getComputerID())
    saveCfg()
    os.setComputerLabel(cfg.name)
  end
  titan.broadcast(MSG.BOT_REGISTER, {
    botName = cfg.name or os.getComputerLabel(),
    label = cfg.name or os.getComputerLabel(),
    botType = "miner", home = cfg.home or nav.home,
    state = state.status, status = state.status,
  })
  while true do
    local x, y, z = nav.locate(1)
    local fix = nav.lastFix
    local asg = assignmentText()
    if (not x) and hasTrack() then
      x, y, z = track.x, track.y, track.z
    end
    -- Offline (chunker equipped) has no modem — skip mesh noise.
    if modemSideEquipped() then
      pcall(titan.broadcast, MSG.STATUS, {
        botName = cfg.name or os.getComputerLabel(),
        label = cfg.name or os.getComputerLabel(),
        status = state.status,
        state  = state.status,   -- Parent Center reads `state`
        task   = state.task,
        assignment = asg,
        x = x, y = y, z = z,
        yLo = fix and fix.yLo, yHi = fix and fix.yHi,
        gpsN = fix and fix.n, gpsSpreadY = fix and fix.spreadY,
        fuel   = turtle.getFuelLevel(),
        dug    = state.dug,
        botType = "miner",
        jobId = state.jobId,
        siteId = cfg.siteId,
        netMode = state.netMode,
        selfChunk = cfg.selfChunk and true or false,
        fuelRate = fuelEco.fuelPerBlock,
        maxRange = maxRangeOnTank(),
        digBudget = fuelBudget().digBudget,
        awaitingDepot = (loadJob() or {}).awaitingDepot and true or false,
        depot = (loadJob() or {}).depot,
      })
    end
    sleep(5)
  end
end

local function receiveLoop()
  while true do
    local id, msg = rednet.receive(P)
    if type(msg) == "table" then
      local t = msg.type
      if t == MSG.COMMAND then
        local cmd = tostring(msg.cmd or ""):lower()
        if cmd == "mine" then
          if state.status == "mining" then
            titan.send(id, MSG.ACK, { ok = false, err = "already mining" })
          else
            mineRequested = true
            continueRequested = false
            setStatus("idle", "mine queued")
            titan.send(id, MSG.ACK, { ok = true, task = "mine queued" })
          end
        elseif cmd == "continue" or cmd == "resume" then
          if state.status == "mining" then
            titan.send(id, MSG.ACK, { ok = false, err = "already mining" })
          else
            local job = loadJob()
            if not job or job.active == false then
              titan.send(id, MSG.ACK, { ok = false, err = "no active mine job" })
            else
              continueRequested = true
              mineRequested = false
              setStatus("idle", "continue queued")
              titan.send(id, MSG.ACK, { ok = true, task = "continue queued" })
            end
          end
        elseif cmd == "stop" then
          state.stop = true
          mineRequested = false
          continueRequested = false
          titan.send(id, MSG.ACK, { ok = true, task = "stop" })
        elseif cmd == "goto" and msg.x then
          setStatus("moving", ("goto %d,%d,%d"):format(msg.x, msg.y, msg.z))
          local ok, err = nav.travelTo(msg.x, msg.y, msg.z)
          setStatus("idle", "-")
          titan.send(id, MSG.ACK, { ok = ok, err = err })
        elseif cmd == "return" or cmd == "home" then
          setStatus("moving", "-> home")
          nav.goHome({ dig = true })
          setStatus("idle", "-")
          titan.send(id, MSG.ACK, { ok = true, task = "home" })
        elseif cmd == "park" or cmd == "tostage" then
          local ok, err = returnToStage()
          titan.send(id, MSG.ACK, { ok = ok, err = err, task = "park" })
        elseif cmd == "dump" then
          dumpInventory()
          titan.send(id, MSG.ACK, { ok = true, task = "dump" })
        elseif cmd == "stage" and msg.x then
          cfg.stage = {
            x = math.floor(tonumber(msg.x)),
            y = math.floor(tonumber(msg.y) or 64),
            z = math.floor(tonumber(msg.z)),
          }
          saveCfg()
          titan.send(id, MSG.ACK, { ok = true, task = "stage set" })
        end
      elseif t == MSG.MINE_JOB then
        if state.status == "mining" or state.status == "moving"
            or state.status == "queued" or state.status == "returning" then
          titan.send(id, MSG.MINE_JOB_ACK, { ok = false, err = "busy", jobId = msg.jobId })
        else
          msg.replyTo = id
          pendingJob = msg
          state.jobId = msg.jobId or msg.id
          setStatus("queued", tostring(state.jobId or "job"))
          titan.send(id, MSG.MINE_JOB_ACK, {
            ok = true, jobId = state.jobId, queued = true,
            botType = "miner", state = "queued",
          })
        end
      elseif t == MSG.PERMIT_SYNC then
        if type(msg.permits) == "table" then
          titan.setPermits(msg.permits)
        end
      elseif t == MSG.WORKER_DEPLOY then
        local ok, why = applyDeployment(msg)
        if ok and msg.stage then
          cfg.stage = msg.stage
          saveCfg()
        end
        if ok and tonumber(msg.cruiseY) then
          cfg.cruiseY = math.floor(tonumber(msg.cruiseY))
          saveCfg()
        end
        titan.send(id, MSG.WORKER_DEPLOYED, {
          ok = ok, err = why, name = cfg.name, botType = "miner",
        })
      elseif t == MSG.PING then
        local px, py, pz = nav.locate(1)
        titan.send(id, MSG.PONG, {
          state = state.status, status = state.status, botType = "miner",
          botName = cfg.name or os.getComputerLabel(),
          name = cfg.name or os.getComputerLabel(),
          assignment = assignmentText(),
          x = px, y = py, z = pz, jobId = state.jobId,
          fuel = turtle.getFuelLevel(),
        })
      end
    end
  end
end

local function jobLoop()
  while true do
    if state.status == "awaiting_depot" or (loadJob() or {}).awaitingDepot then
      pcall(tryAutoResumeDepot)
    end
    if pendingJob and state.status ~= "mining" and state.status ~= "moving"
        and state.status ~= "returning" and state.status ~= "awaiting_depot" then
      local job = pendingJob
      pendingJob = nil
      runAssignedJob(job)
      state.jobId = nil
      if state.status ~= "error" and state.status ~= "awaiting_depot" then setStatus("idle", "-") end
    elseif mineRequested and state.status ~= "mining" and state.status ~= "awaiting_depot" then
      mineRequested = false
      mineVolume()
      state.jobId = nil
      if state.status ~= "error" and state.status ~= "stopped"
          and state.status ~= "awaiting_depot" then setStatus("idle", "-") end
    elseif continueRequested and state.status ~= "mining" then
      continueRequested = false
      continueMine()
      state.jobId = nil
      if state.status ~= "error" and state.status ~= "stopped"
          and state.status ~= "awaiting_depot" then setStatus("idle", "-") end
    end
    sleep(0.4)
  end
end

-- Pull Create break permits from Parent Center on boot.
local function permitLoop()
  while true do
    rednet.broadcast({ type = MSG.PERMIT_SYNC, want = true }, P)
    sleep(60)
  end
end

--------------------------------------------------------------------------------
loadCfg()
loadExclude()

-- Migrate older miner.cfg (no deploy name) so existing quarries keep running.
if not cfg.name then
  if cfg.loc1 or cfg.loc2 or cfg.yStart ~= nil or cfg.yEnd ~= nil or cfg.floorY ~= nil then
    cfg.name = os.getComputerLabel() or ("Miner-" .. os.getComputerID())
    cfg.botType = "miner"
    saveCfg()
  end
end

if not cfg.name then
  parallel.waitForAny(
    awaitDeployment,
    function() titan.networkLoop("miner") end
  )
end

os.setComputerLabel(cfg.name)
if cfg.home then nav.home = cfg.home end
pcall(nav.calibrate, true)

local bootJob = loadJob()
if bootJob and bootJob.active ~= false then
  applyJobToCfg(bootJob)
end

if not quarryReady() then
  print("Miner '" .. cfg.name .. "' online — box not fully set.")
  print("  1) set1 <x> <z>   then   set2 <x> <z>")
  print("  2) sety <startY> <endY>   e.g. sety 80 -59")
  print("  3) home  (face the mine; chest = one block behind)")
  print("  4) mine")
else
  local b = bounds()
  print(("Miner '%s' online. Box ready X[%d..%d] Z[%d..%d] Y[%d->%d]."):format(
    cfg.name, b.minX, b.maxX, b.minZ, b.maxZ, b.topY, b.floorY))
  if cfg.home and not cfg.chest then ensureChest() end
  if cfg.chest then print("chest @ " .. fmt(cfg.chest)) end
end
if bootJob and bootJob.active ~= false then
  print("Active mine job found (miner_job.cfg). Type `continue` to resume.")
  if bootJob.init then print("  init @ " .. fmt(bootJob.init)) end
  print(("  last progress Y=%s Z=%s X=%s dug=%s"):format(
    tostring(bootJob.y), tostring(bootJob.z), tostring(bootJob.x),
    tostring(bootJob.dug or 0)))
  if bootJob.awaitingDepot and bootJob.depot then
    setStatus("awaiting_depot", fmt(bootJob.depot))
    printDepotInstructions(bootJob)
    print("Waiting for fuel LEFT + storage BEHIND at that spot...")
  else
    setStatus("idle", "-")
  end
else
  setStatus("idle", "-")
end

parallel.waitForAny(
  consoleLoop,
  statusLoop,
  receiveLoop,
  jobLoop,
  permitLoop,
  function() titan.networkLoop("miner") end
)
print("Miner stopped.")
