--[[
  offline_miner.lua  -  Local quarry turtle (no GPS / no network)
  Titan-Version: 1.0.3

  Place the turtle at the TOP-FRONT-LEFT corner of the dig, facing into the
  mine. That cell is origin 0,0,0:

      +X = right
      +Y = down
      +Z = forward (into the mine)

  First boot (or `setup`):
    * Fuel chest is on the LEFT  → top up slot 16 with coal only (keeps it there)
    * Storage chest is BEHIND    → dumps slots 1-15 (never slot 16)

  Dig pattern (box):
    column  — dig each vertical shaft fully, then move to the next (default)
    layer   — clear each horizontal slice top→bottom, then drop to the next

  Job memory (offline_miner_job.cfg):
    Progress is saved as you dig. After stop / reboot / dump, put the turtle
    back at origin (0,0,0 facing in) and run `continue`.

  Commands (sizes as WxH or WxHxD — zeros are just placeholders in the docs):
    box <W>x<H>x<D> [column|layer]
    tunnel <L>x<H> [W]       1-wide (or W-wide) tunnel, length forward, height tall
    stair <W>x<steps> <up|down>
                             stepped ramp; width across, steps along facing
    pattern [column|layer]   show / set default box dig pattern
    continue | resume        resume saved job from origin
    job | clearjob           show / forget saved job
    home                     return to 0,0,0 facing start
    dump | refuel | setup | stop | status | help

  Optional: exclude.txt (same format as the network miner) — never break those.

  No modem / lib / Parent Center required. Run:  offline_miner
]]

local CFG = "offline_miner.cfg"
local JOB_FILE = "offline_miner_job.cfg"
local EXCLUDE = "exclude.txt"
local FUEL_SLOT = 16
local MIN_FUEL = 200
local STOP = false

-- Relative pose from boot origin. +Y is DOWN.
local pos = { x = 0, y = 0, z = 0 }
local facing = 0   -- 0=+Z forward, 1=+X right, 2=-Z back, 3=-X left
local dug = 0
local skipped = 0
local jobLabel = "-"
local activeJob = nil   -- in-memory copy of JOB_FILE while running

local exclude = {}
local cfg = {
  setupDone = false,
  label = nil,
  pattern = "column",  -- "column" | "layer"
}

local function normalizePattern(p)
  p = tostring(p or ""):lower()
  if p == "col" or p == "columns" or p == "shaft" then p = "column" end
  if p == "layers" or p == "slice" or p == "flat" then p = "layer" end
  if p == "column" or p == "layer" then return p end
  return nil
end

--------------------------------------------------------------------------------
-- Config / exclude
--------------------------------------------------------------------------------
local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" then
    for k, v in pairs(d) do cfg[k] = v end
  end
  cfg.pattern = normalizePattern(cfg.pattern) or "column"
end

local function saveCfg()
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize(cfg))
  f.close()
end

local function loadExclude()
  exclude = {
    ["minecraft:bedrock"] = true,
    ["minecraft:chest"] = true,
    ["minecraft:trapped_chest"] = true,
    ["minecraft:barrel"] = true,
    ["minecraft:hopper"] = true,
    ["minecraft:spawner"] = true,
  }
  if not fs.exists(EXCLUDE) then return end
  local f = fs.open(EXCLUDE, "r")
  while true do
    local line = f.readLine()
    if not line then break end
    line = (line:match("^%s*(.-)%s*$") or "")
    if line ~= "" and not line:find("^#") then
      exclude[line] = true
    end
  end
  f.close()
end

local function blockName(info)
  if type(info) ~= "table" then return nil end
  return info.name or info.id
end

local function restricted(dir)
  local ok, info
  if dir == "up" then ok, info = turtle.inspectUp()
  elseif dir == "down" then ok, info = turtle.inspectDown()
  else ok, info = turtle.inspect() end
  if not ok then return false end
  local name = blockName(info)
  return name and exclude[name] == true
end

--------------------------------------------------------------------------------
-- Size parsing: "10x5x20" or separate numbers
--------------------------------------------------------------------------------
local function parseDims(a, startAt)
  startAt = startAt or 2
  local raw = a[startAt]
  if not raw then return nil end
  if tostring(raw):find("x") then
    local parts = {}
    for n in tostring(raw):gmatch("(%-?%d+)") do
      parts[#parts + 1] = tonumber(n)
    end
    return parts
  end
  local parts = {}
  for i = startAt, #a do
    local n = tonumber(a[i])
    if not n then break end
    parts[#parts + 1] = n
  end
  return parts
end

--------------------------------------------------------------------------------
-- Facing / odometry
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
  local delta = (dir - facing) % 4
  if delta == 1 then turnRight()
  elseif delta == 2 then turnRight(); turnRight()
  elseif delta == 3 then turnLeft()
  end
end

local function faceForward() turnTo(0) end
local function faceRight() turnTo(1) end
local function faceBack() turnTo(2) end
local function faceLeft() turnTo(3) end

local function applyForwardStep()
  if facing == 0 then pos.z = pos.z + 1
  elseif facing == 1 then pos.x = pos.x + 1
  elseif facing == 2 then pos.z = pos.z - 1
  else pos.x = pos.x - 1 end
end

--------------------------------------------------------------------------------
-- Dig / move
--------------------------------------------------------------------------------
local function digDir(dir)
  if restricted(dir) then
    skipped = skipped + 1
    return false, "excluded"
  end
  local dig = turtle.dig
  if dir == "up" then dig = turtle.digUp
  elseif dir == "down" then dig = turtle.digDown end
  for _ = 1, 8 do
    local detect = turtle.detect
    if dir == "up" then detect = turtle.detectUp
    elseif dir == "down" then detect = turtle.detectDown end
    if not detect() then return true end
    if restricted(dir) then
      skipped = skipped + 1
      return false, "excluded"
    end
    if dig() then dug = dug + 1 end
    sleep(0.05)
  end
  return not (dir == "up" and turtle.detectUp()
    or dir == "down" and turtle.detectDown()
    or (dir ~= "up" and dir ~= "down" and turtle.detect()))
end

-- True if the selected slot holds a valid fuel item (does not consume).
local function selectedIsFuel()
  return turtle.refuel(0) == true
end

-- Move any fuel items from slots 1-15 into slot 16 (coal stays on the turtle).
local function consolidateFuelToSlot16()
  for s = 1, 15 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if selectedIsFuel() then
        turtle.transferTo(FUEL_SLOT)
      end
    end
  end
  turtle.select(FUEL_SLOT)
end

-- Burn only enough to stay above MIN_FUEL; always try to leave items in slot 16.
local function burnSomeFuel()
  turtle.select(FUEL_SLOT)
  if not selectedIsFuel() then return turtle.getFuelLevel() end
  local level = turtle.getFuelLevel()
  if level == "unlimited" then return level end
  local count = turtle.getItemCount(FUEL_SLOT)
  if count < 1 then return level end
  if level and level >= MIN_FUEL then return level end
  -- Need more tank fuel — burn a few, keep a reserve in the slot when possible.
  local leave = (count > 1) and 1 or 0
  local burn = math.min(count - leave, 8)
  if burn < 1 then burn = 1 end
  turtle.refuel(burn)
  return turtle.getFuelLevel()
end

local function ensureFuel()
  local level = turtle.getFuelLevel()
  if level == "unlimited" then return true end
  if level and level >= MIN_FUEL then return true end
  consolidateFuelToSlot16()
  burnSomeFuel()
  level = turtle.getFuelLevel()
  if level and level ~= "unlimited" and level < 1 then
    print("Out of fuel. Put coal in slot " .. FUEL_SLOT .. " or the left chest.")
    return false
  end
  return true
end

local function inventoryFull()
  for s = 1, 16 do
    if s ~= FUEL_SLOT and turtle.getItemCount(s) == 0 then
      return false
    end
  end
  return true
end

-- Pull ONLY into slot 16 from the left chest (never empties the chest into 1-15).
local function suckFuelFromLeft()
  faceLeft()
  consolidateFuelToSlot16()
  turtle.select(FUEL_SLOT)
  local space = turtle.getItemSpace(FUEL_SLOT)
  if space and space > 0 then
    turtle.suck(space)
  elseif turtle.getItemCount(FUEL_SLOT) == 0 then
    -- Slot empty / different item: clear non-fuel out of 16 first isn't expected;
    -- suck one stack worth into 16 only.
    turtle.suck(64)
    -- If suck overflowed (CC may fill other slots when 16 is full), pull fuel back.
    consolidateFuelToSlot16()
  end
  -- Top up the fuel tank a little but KEEP coal sitting in slot 16.
  burnSomeFuel()
  faceForward()
  local n = turtle.getItemCount(FUEL_SLOT)
  print(("Fuel slot 16: %d item(s), tank=%s"):format(n, tostring(turtle.getFuelLevel())))
  return turtle.getFuelLevel()
end

-- Dump mined goods to the chest behind. Never drops slot 16 (coal stays).
local function dumpToStorage()
  consolidateFuelToSlot16()
  faceBack()
  for s = 1, 15 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      -- If somehow still fuel, try slot 16 again instead of storing it.
      if selectedIsFuel() and turtle.getItemSpace(FUEL_SLOT) > 0 then
        turtle.transferTo(FUEL_SLOT)
      end
      if turtle.getItemCount(s) > 0 then
        turtle.drop()
      end
    end
  end
  turtle.select(FUEL_SLOT)
  faceForward()
end

local function setupChests()
  print("Setup: fuel chest LEFT → slot 16 only; storage BEHIND → dump 1-15.")
  print("Facing into the mine at top-front-left (origin 0,0,0)...")
  dumpToStorage()
  local fuel = suckFuelFromLeft()
  cfg.setupDone = true
  saveCfg()
  print(("Setup done. Tank=%s  coal in slot 16=%d"):format(
    tostring(fuel), turtle.getItemCount(FUEL_SLOT)))
  print("Origin locked at current pose (0,0,0 forward).")
end

--------------------------------------------------------------------------------
-- Pathing in local coords
--------------------------------------------------------------------------------
local function moveForward()
  if STOP then return false, "stop" end
  if not ensureFuel() then return false, "fuel" end
  digDir("forward")
  if turtle.forward() then
    applyForwardStep()
    return true
  end
  -- Attack entities / retry dig
  digDir("forward")
  if turtle.attack() then sleep(0.2) end
  if turtle.forward() then
    applyForwardStep()
    return true
  end
  return false, "blocked"
end

local function moveUp()
  if STOP then return false, "stop" end
  if not ensureFuel() then return false, "fuel" end
  digDir("up")
  if turtle.up() then
    pos.y = pos.y - 1
    return true
  end
  return false, "blocked"
end

local function moveDown()
  if STOP then return false, "stop" end
  if not ensureFuel() then return false, "fuel" end
  digDir("down")
  if turtle.down() then
    pos.y = pos.y + 1
    return true
  end
  return false, "blocked"
end

local function goTo(tx, ty, tz)
  -- Order: Y first (up/down), then X, then Z — keeps us out of uncleared space when possible.
  while pos.y > ty do
    if not moveUp() then return false, "up" end
  end
  while pos.y < ty do
    if not moveDown() then return false, "down" end
  end
  if pos.x < tx then
    faceRight()
    while pos.x < tx do if not moveForward() then return false, "x+" end end
  elseif pos.x > tx then
    faceLeft()
    while pos.x > tx do if not moveForward() then return false, "x-" end end
  end
  if pos.z < tz then
    faceForward()
    while pos.z < tz do if not moveForward() then return false, "z+" end end
  elseif pos.z > tz then
    faceBack()
    while pos.z > tz do if not moveForward() then return false, "z-" end end
  end
  faceForward()
  return true
end

--------------------------------------------------------------------------------
-- Job memory (offline_miner_job.cfg)
--------------------------------------------------------------------------------
local function loadJobFile()
  if not fs.exists(JOB_FILE) then return nil end
  local f = fs.open(JOB_FILE, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" and d.type then return d end
  return nil
end

local function saveJobFile(j)
  if not j then return end
  j.dug = dug
  j.skipped = skipped
  j.updated = os.epoch("utc")
  local f = fs.open(JOB_FILE, "w")
  f.write(textutils.serialize(j))
  f.close()
  activeJob = j
end

local function clearJobFile()
  if fs.exists(JOB_FILE) then pcall(fs.delete, JOB_FILE) end
  activeJob = nil
end

local function jobSummary(j)
  if not j then return "(none)" end
  if j.type == "box" then
    return ("box %dx%dx%d %s  step %d/%d  [%s]"):format(
      j.W or 0, j.H or 0, j.D or 0, tostring(j.pattern or "column"),
      tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
  elseif j.type == "tunnel" then
    return ("tunnel %dx%dx%d  step %d/%d  [%s]"):format(
      j.L or 0, j.H or 0, j.W or 1,
      tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
  elseif j.type == "stair" then
    return ("stair %dx%d %s  step %d/%d  [%s]"):format(
      j.W or 0, j.steps or 0, tostring(j.dir or "?"),
      tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
  end
  return tostring(j.type)
end

local function assumeAtOrigin()
  pos.x, pos.y, pos.z = 0, 0, 0
  facing = 0
  faceForward()
end

local function goHome()
  jobLabel = "home"
  local ok, err = goTo(0, 0, 0)
  faceForward()
  return ok, err
end

local function manageInventory(resume)
  if not inventoryFull() and ensureFuel() then return true end
  print("Inventory/fuel break — returning to origin...")
  if activeJob then
    activeJob.status = "paused"
    saveJobFile(activeJob)
  end
  local rx, ry, rz = pos.x, pos.y, pos.z
  if not goHome() then return false, "home" end
  dumpToStorage()
  suckFuelFromLeft()
  if resume then
    print(("Resuming @ %d,%d,%d"):format(rx, ry, rz))
    if not goTo(rx, ry, rz) then return false, "resume" end
    if activeJob then
      activeJob.status = "active"
      saveJobFile(activeJob)
    end
  end
  return true
end

-- Dig H blocks downward from the current cell, then climb back to the top.
local function digDownColumn(H)
  for i = 1, H do
    if STOP then return false, "stop" end
    if not manageInventory(true) then return false, "inventory" end
    digDir("down")
    if i < H then
      if not moveDown() then return false, "down" end
    end
  end
  for _ = 1, H - 1 do
    if not moveUp() then return false, "up" end
  end
  return true
end

-- Clear H tall space with feet on this floor (dig upward headroom).
local function clearHeadroom(H)
  if H <= 1 then return true end
  for i = 1, H - 1 do
    if STOP then return false, "stop" end
    digDir("up")
    if i < H - 1 then
      if not moveUp() then return false end
    end
  end
  while pos.y < 0 do
    if not moveDown() then return false end
  end
  while pos.y > 0 do
    if not moveUp() then return false end
  end
  return true
end

--------------------------------------------------------------------------------
-- Work-unit lists (for continue / idx progress)
--------------------------------------------------------------------------------
local function boxColumnUnits(W, D)
  local units = {}
  for z = 0, D - 1 do
    if z % 2 == 0 then
      for x = 0, W - 1 do units[#units + 1] = { x = x, z = z } end
    else
      for x = W - 1, 0, -1 do units[#units + 1] = { x = x, z = z } end
    end
  end
  return units
end

local function boxLayerUnits(W, H, D)
  local units = {}
  for y = 0, H - 1 do
    for z = 0, D - 1 do
      if (z + y) % 2 == 0 then
        for x = 0, W - 1 do units[#units + 1] = { x = x, y = y, z = z } end
      else
        for x = W - 1, 0, -1 do units[#units + 1] = { x = x, y = y, z = z } end
      end
    end
  end
  return units
end

local function tunnelUnits(L, W)
  local units = {}
  for z = 0, L - 1 do
    if z % 2 == 0 or W == 1 then
      for x = 0, W - 1 do units[#units + 1] = { x = x, z = z } end
    else
      for x = W - 1, 0, -1 do units[#units + 1] = { x = x, z = z } end
    end
  end
  return units
end

local function stairUnits(W, steps, dir)
  local units = {}
  for s = 0, steps - 1 do
    local y = (dir == "down") and s or -s
    for x = 0, W - 1 do
      units[#units + 1] = { x = x, y = y, z = s, step = s }
    end
  end
  return units
end

--------------------------------------------------------------------------------
-- Jobs
--------------------------------------------------------------------------------
local function finishJob(ok, err)
  if activeJob then
    if ok then
      activeJob.status = "done"
      activeJob.idx = (activeJob.total or 0) + 1
      saveJobFile(activeJob)
      print("Job finished (kept in " .. JOB_FILE .. " — `clearjob` to forget).")
    else
      activeJob.status = "paused"
      saveJobFile(activeJob)
      print("Job paused: " .. tostring(err or "stop"))
      print("Put turtle at origin 0,0,0 facing in, then: continue")
    end
  end
  goHome()
  dumpToStorage()
  suckFuelFromLeft()
  jobLabel = "idle"
  if ok then
    print(("Done. dug=%d skipped=%d fuel=%s"):format(dug, skipped, tostring(turtle.getFuelLevel())))
  end
end

local function runBoxJob(j)
  local W, H, D = j.W, j.H, j.D
  local pattern = j.pattern or "column"
  local units = (pattern == "layer") and boxLayerUnits(W, H, D) or boxColumnUnits(W, D)
  j.total = #units
  j.idx = math.max(1, tonumber(j.idx) or 1)
  j.status = "active"
  activeJob = j
  dug = tonumber(j.dug) or dug
  skipped = tonumber(j.skipped) or skipped
  saveJobFile(j)
  jobLabel = jobSummary(j)
  print(("BOX %dx%dx%d  pattern=%s  resume @ %d/%d"):format(
    W, H, D, pattern, j.idx, j.total))

  local lastY = -999
  for i = j.idx, #units do
    if STOP then finishJob(false, "stop"); return end
    local u = units[i]
    j.idx = i
    saveJobFile(j)
    if not manageInventory(true) then finishJob(false, "inventory/fuel"); return end

    if pattern == "layer" then
      if lastY ~= -999 and u.y > lastY then
        -- Ensure we drop onto the new layer from a known cell.
        if not goTo(0, lastY, 0) then finishJob(false, "layer path"); return end
        while pos.y < u.y do
          if not moveDown() then finishJob(false, "layer drop"); return end
        end
      end
      lastY = u.y
      if not goTo(u.x, u.y, u.z) then finishJob(false, "path"); return end
      digDir("down")
    else
      if not goTo(u.x, 0, u.z) then finishJob(false, "path"); return end
      local ok, err = digDownColumn(H)
      if not ok then finishJob(false, err or "column"); return end
    end
    j.idx = i + 1
    saveJobFile(j)
  end
  finishJob(true)
end

local function runTunnelJob(j)
  local L, H, W = j.L, j.H, j.W or 1
  local units = tunnelUnits(L, W)
  j.total = #units
  j.idx = math.max(1, tonumber(j.idx) or 1)
  j.status = "active"
  activeJob = j
  dug = tonumber(j.dug) or dug
  skipped = tonumber(j.skipped) or skipped
  saveJobFile(j)
  jobLabel = jobSummary(j)
  print(("TUNNEL L=%d H=%d W=%d  resume @ %d/%d"):format(L, H, W, j.idx, j.total))

  for i = j.idx, #units do
    if STOP then finishJob(false, "stop"); return end
    local u = units[i]
    j.idx = i
    saveJobFile(j)
    if not manageInventory(true) then finishJob(false, "inventory/fuel"); return end
    if not goTo(u.x, 0, u.z) then finishJob(false, "path"); return end
    if not clearHeadroom(H) then finishJob(false, "headroom"); return end
    j.idx = i + 1
    saveJobFile(j)
  end
  finishJob(true)
end

local function runStairJob(j)
  local W, steps, dir = j.W, j.steps, j.dir
  local units = stairUnits(W, steps, dir)
  j.total = #units
  j.idx = math.max(1, tonumber(j.idx) or 1)
  j.status = "active"
  activeJob = j
  dug = tonumber(j.dug) or dug
  skipped = tonumber(j.skipped) or skipped
  saveJobFile(j)
  jobLabel = jobSummary(j)
  print(("STAIR W=%d steps=%d dir=%s  resume @ %d/%d"):format(
    W, steps, dir, j.idx, j.total))

  for i = j.idx, #units do
    if STOP then finishJob(false, "stop"); return end
    local u = units[i]
    j.idx = i
    saveJobFile(j)
    if not manageInventory(true) then finishJob(false, "inventory/fuel"); return end
    if not goTo(u.x, u.y, u.z) then finishJob(false, "path"); return end
    digDir("up")
    digDir("down")
    -- After last cell of a step, step forward/up/down toward next step
    local nextU = units[i + 1]
    if nextU and nextU.step ~= u.step then
      if not goTo(0, u.y, u.z) then finishJob(false, "stair edge"); return end
      faceForward()
      if not moveForward() then finishJob(false, "forward"); return end
      if dir == "down" then
        if not moveDown() then finishJob(false, "down"); return end
      else
        if not moveUp() then finishJob(false, "up"); return end
      end
    end
    j.idx = i + 1
    saveJobFile(j)
  end
  finishJob(true)
end

local function runSavedJob(j, fromContinue)
  if not j or not j.type then
    print("No saved job.")
    return
  end
  if j.status == "done" then
    print("Saved job already finished. `clearjob` to forget, or start a new dig.")
    print("  " .. jobSummary(j))
    return
  end
  STOP = false
  if fromContinue then
    print("Continue: assuming turtle is at origin 0,0,0 facing into the mine.")
    assumeAtOrigin()
    suckFuelFromLeft()
  else
    if not goHome() then print("Could not reach origin."); return end
  end
  if j.type == "box" then
    runBoxJob(j)
  elseif j.type == "tunnel" then
    runTunnelJob(j)
  elseif j.type == "stair" then
    runStairJob(j)
  else
    print("Unknown job type: " .. tostring(j.type))
  end
end

local function digBox(W, H, D, opts)
  opts = opts or {}
  W, H, D = math.floor(W), math.floor(H), math.floor(D)
  if W < 1 or H < 1 or D < 1 then
    print("Usage: box <W>x<H>x<D> [column|layer]")
    return
  end
  local pattern = normalizePattern(opts.pattern) or normalizePattern(cfg.pattern) or "column"
  dug, skipped = 0, 0
  local units = (pattern == "layer") and boxLayerUnits(W, H, D) or boxColumnUnits(W, D)
  local j = {
    type = "box", W = W, H = H, D = D, pattern = pattern,
    idx = 1, total = #units, status = "active", dug = 0, skipped = 0,
  }
  runSavedJob(j, false)
end

local function digTunnel(L, H, W)
  L, H = math.floor(L), math.floor(H)
  W = math.floor(tonumber(W) or 1)
  if L < 1 or H < 1 or W < 1 then
    print("Usage: tunnel <L>x<H> [W]  (length forward, height, optional width)")
    return
  end
  dug, skipped = 0, 0
  local units = tunnelUnits(L, W)
  local j = {
    type = "tunnel", L = L, H = H, W = W,
    idx = 1, total = #units, status = "active", dug = 0, skipped = 0,
  }
  runSavedJob(j, false)
end

local function digStair(W, steps, dir)
  W, steps = math.floor(W), math.floor(steps)
  dir = tostring(dir or "down"):lower()
  if (dir ~= "up" and dir ~= "down") or W < 1 or steps < 1 then
    print("Usage: stair <W>x<steps> <up|down>")
    return
  end
  dug, skipped = 0, 0
  local units = stairUnits(W, steps, dir)
  local j = {
    type = "stair", W = W, steps = steps, dir = dir,
    idx = 1, total = #units, status = "active", dug = 0, skipped = 0,
  }
  runSavedJob(j, false)
end

local function continueJob()
  local j = loadJobFile()
  if not j then
    print("No saved job in " .. JOB_FILE .. ". Start with box / tunnel / stair.")
    return
  end
  print("Loaded: " .. jobSummary(j))
  runSavedJob(j, true)
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function printHelp()
  print("Offline miner — origin = top-front-left, facing into mine.")
  print("  +X right   +Y down   +Z forward")
  print("")
  print("  box <W>x<H>x<D> [column|layer]   solid box dig")
  print("  pattern [column|layer]           default dig pattern")
  print("  tunnel <L>x<H> [W]               corridor (default W=1)")
  print("  stair <W>x<steps> <up|down>      staircase")
  print("  continue | resume                resume saved job (from origin)")
  print("  job | clearjob                   show / forget saved job")
  print("  home | dump | refuel | setup | stop | status")
  print("")
  print("Jobs save to " .. JOB_FILE .. ". After stop/reboot: origin + continue.")
end

local function printStatus()
  print(("pos=%d,%d,%d face=%d"):format(pos.x, pos.y, pos.z, facing))
  print(("label=%s  dug=%d skipped=%d fuel=%s"):format(
    jobLabel, dug, skipped, tostring(turtle.getFuelLevel())))
  print(("setup=%s  pattern=%s"):format(tostring(cfg.setupDone), tostring(cfg.pattern or "column")))
  local j = activeJob or loadJobFile()
  if j then
    print("saved: " .. jobSummary(j))
  else
    print("saved: (none)")
  end
end

local function handleCommand(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = (a[1] or ""):lower()

  if cmd == "" then
    return true
  elseif cmd == "help" or cmd == "?" then
    printHelp()
  elseif cmd == "status" then
    printStatus()
  elseif cmd == "stop" then
    STOP = true
    print("Stop requested — job will be saved for `continue`.")
  elseif cmd == "setup" then
    setupChests()
  elseif cmd == "dump" then
    goHome()
    dumpToStorage()
    print("Dumped.")
  elseif cmd == "refuel" then
    goHome()
    local f = suckFuelFromLeft()
    print("Fuel: " .. tostring(f))
  elseif cmd == "home" then
    goHome()
    print("Home.")
  elseif cmd == "job" then
    local j = activeJob or loadJobFile()
    if not j then print("No saved job.")
    else print(jobSummary(j)) end
  elseif cmd == "clearjob" or cmd == "forgetjob" then
    clearJobFile()
    print("Cleared saved job.")
  elseif cmd == "continue" or cmd == "resume" then
    continueJob()
  elseif cmd == "pattern" or cmd == "mode" then
    if not a[2] then
      print("Dig pattern: " .. tostring(cfg.pattern or "column"))
      print("  column — dig each vertical shaft, then move on")
      print("  layer  — mine each horizontal layer top→bottom")
      print("Usage: pattern <column|layer>")
    else
      local p = normalizePattern(a[2])
      if not p then
        print("Unknown pattern. Use: column | layer")
      else
        cfg.pattern = p
        saveCfg()
        print("Dig pattern set to: " .. p)
      end
    end
  elseif cmd == "box" then
    local d = parseDims(a, 2)
    local override
    for i = 2, #a do
      local p = normalizePattern(a[i])
      if p then override = p end
    end
    if not d or not d[1] or not d[2] or not d[3] then
      print("Usage: box <W>x<H>x<D> [column|layer]")
    else
      digBox(d[1], d[2], d[3], { pattern = override })
    end
  elseif cmd == "tunnel" then
    local d = parseDims(a, 2)
    if not d or not d[1] or not d[2] then
      print("Usage: tunnel <L>x<H> [W]")
    else
      if #d >= 3 then
        digTunnel(d[1], d[2], d[3])
      else
        local wExtra = tonumber(a[3])
        digTunnel(d[1], d[2], wExtra or 1)
      end
    end
  elseif cmd == "stair" then
    local d = parseDims(a, 2)
    local dir = nil
    for i = 2, #a do
      local t = tostring(a[i]):lower()
      if t == "up" or t == "down" then dir = t end
    end
    if not d or not d[1] or not d[2] or not dir then
      print("Usage: stair <W>x<steps> <up|down>")
    else
      digStair(d[1], d[2], dir)
    end
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    print("Unknown: " .. cmd .. "  (help)")
  end
  return true
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------
if not turtle then
  print("offline_miner must run on a turtle.")
  return
end

loadCfg()
loadExclude()
os.setComputerLabel(os.getComputerLabel() or cfg.label or ("OfflineMiner-" .. os.getComputerID()))
cfg.label = os.getComputerLabel()
saveCfg()

term.clear()
term.setCursorPos(1, 1)
print("== Offline Miner ==")
print("Origin: top-front-left of dig, facing in = 0,0,0")
print("Axes: +X right | +Y down | +Z forward")
print("")

if not cfg.setupDone then
  setupChests()
else
  print("Setup already done (fuel left, storage behind). Type `setup` to redo.")
  suckFuelFromLeft()
  print("Fuel: " .. tostring(turtle.getFuelLevel()))
end

local saved = loadJobFile()
if saved and saved.status ~= "done" then
  print("")
  print("Saved job: " .. jobSummary(saved))
  print("Place at origin facing in, then: continue")
elseif saved and saved.status == "done" then
  print("")
  print("Last job finished. `clearjob` to forget, or start a new dig.")
end

print("")
print("Type help. Examples:  box 9x5x9   |   continue")
print("")

while true do
  write("mine> ")
  local line = read()
  local r = handleCommand(line)
  if r == "exit" then break end
end

print("Offline miner stopped.")
