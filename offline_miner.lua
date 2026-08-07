--[[
  offline_miner.lua  -  Local quarry turtle (no GPS / no network)
  Titan-Version: 1.0.9

  Place the turtle at the TOP-FRONT-LEFT corner of the dig, facing into the
  mine. That cell is origin 0,0,0:

      +X = right
      +Y = down
      +Z = forward (into the mine)

  First boot (or `setup`):
    * Fuel chest is on the LEFT  → top up slot 16 with coal only (keeps it there)
    * Storage chest is BEHIND    → dumps slots 1-15 (never slot 16)
    * If a pickaxe (incl. enchanted) is in the turtle inventory, equip it as a
      tool upgrade via turtle.equipLeft/Right (crafting often rejects enchantments)

  box / area — ALWAYS 1 Y-layer at a time (walk the plane, then drop one).
               Never digs 2 high; no player headroom on quarry jobs.

  Job memory (offline_miner_job.cfg):
    Progress is saved as you dig. After stop / reboot / dump, put the turtle
    back at origin (0,0,0 facing in) and run `continue`.

  Commands (sizes as WxH or WxHxD — zeros are just placeholders in the docs):
    area <W>x<L> <stopY>     width × length, dig down stopY layers from origin
                             (aliases: quarry, flatten)
    box <W>x<H>x<D>          H = number of 1-high layers down
    tunnel <L> [W]           player-tall (2 high) corridor; optional width
    stair <W>x<steps> <up|down>
                             player-tall stepped ramp
    equip | tool | pick      equip best pickaxe from inventory (left/right)
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

--------------------------------------------------------------------------------
-- Tool equip (inventory → turtle upgrade slot)
-- Crafting an enchanted pick onto a turtle often fails; equipLeft/Right keeps NBT
-- when the pack/datapack allows enchanted turtle tools.
--------------------------------------------------------------------------------
local function toolKind(name)
  name = tostring(name or ""):lower()
  if name:find("pickaxe", 1, true) then return "pickaxe" end
  if name:find("sword", 1, true) then return "sword" end
  if name:find("shovel", 1, true) then return "shovel" end
  if name:find("_hoe", 1, true) or name:sub(-4) == "_hoe" then return "hoe" end
  -- Check axe after pickaxe (pickaxe contains "axe").
  if name:find("_axe", 1, true) or name:sub(-4) == "_axe" then return "axe" end
  return nil
end

local function itemDetail(slot)
  local ok, d = pcall(turtle.getItemDetail, slot, true)
  if ok and type(d) == "table" then return d end
  return turtle.getItemDetail(slot)
end

local function enchantCount(detail)
  local e = detail and detail.enchantments
  if type(e) ~= "table" then return 0 end
  return #e
end

local function scoreTool(detail)
  if type(detail) ~= "table" or not detail.name then return -1 end
  local kind = toolKind(detail.name)
  if not kind then return -1 end
  local s = 0
  if kind == "pickaxe" then s = s + 100
  elseif kind == "shovel" then s = s + 40
  elseif kind == "axe" then s = s + 30
  else s = s + 10 end
  local n = detail.name:lower()
  if n:find("netherite", 1, true) then s = s + 30
  elseif n:find("diamond", 1, true) then s = s + 20
  elseif n:find("iron", 1, true) then s = s + 10 end
  s = s + enchantCount(detail) * 15
  return s
end

local function isToolItem(detail)
  return scoreTool(detail) >= 0
end

local function getEquipped(side)
  local fn = (side == "left") and turtle.getEquippedLeft or turtle.getEquippedRight
  if type(fn) ~= "function" then return nil end
  local ok, d = pcall(fn)
  if ok and type(d) == "table" then return d end
  return nil
end

local function sideLooksLikeModem(side)
  local t = peripheral.getType(side)
  if t == "modem" or t == "wired_modem" or t == "wireless_modem" then return true end
  local d = getEquipped(side)
  if d and tostring(d.name or ""):find("modem", 1, true) then return true end
  return false
end

local function sideLooksLikeDigTool(side)
  local d = getEquipped(side)
  if not d then return false end
  return toolKind(d.name) ~= nil
end

local function describeTool(detail)
  if not detail or not detail.name then return "(none)" end
  local short = tostring(detail.name):gsub("^[^:]+:", "")
  local n = enchantCount(detail)
  if n > 0 then
    return ("%s (+%d enchant)"):format(short, n)
  end
  return short
end

local function findBestToolInInventory()
  local bestSlot, bestScore, bestDetail = nil, -1, nil
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      local d = itemDetail(s)
      local sc = scoreTool(d)
      if sc > bestScore then
        bestScore, bestSlot, bestDetail = sc, s, d
      end
    end
  end
  return bestSlot, bestDetail
end

-- Equip best pick/tool from inventory onto left or right upgrade slot.
-- sideArg: "left" | "right" | nil (auto)
-- quiet: if true, stay silent when nothing to equip (boot path)
local function equipToolFromInventory(sideArg, quiet)
  local bestSlot, bestDetail = findBestToolInInventory()
  if not bestSlot then
    if not quiet then
      print("No pickaxe/tool in inventory to equip.")
      print("Put a diamond/netherite pick (enchanted OK) in any slot, then: equip")
    end
    return false, "none"
  end

  local prefer = tostring(sideArg or ""):lower()
  local order = {}
  if prefer == "left" or prefer == "l" then
    order = { "left", "right" }
  elseif prefer == "right" or prefer == "r" then
    order = { "right", "left" }
  else
    -- Prefer replacing an existing dig tool; else avoid modem side; else left.
    if sideLooksLikeDigTool("left") then
      order = { "left", "right" }
    elseif sideLooksLikeDigTool("right") then
      order = { "right", "left" }
    elseif sideLooksLikeModem("left") and not sideLooksLikeModem("right") then
      order = { "right", "left" }
    elseif sideLooksLikeModem("right") and not sideLooksLikeModem("left") then
      order = { "left", "right" }
    else
      order = { "left", "right" }
    end
  end

  print(("Equipping %s from slot %d..."):format(describeTool(bestDetail), bestSlot))
  turtle.select(bestSlot)
  local lastErr = nil
  for _, side in ipairs(order) do
    local ok, err
    if side == "left" then
      ok, err = turtle.equipLeft()
    else
      ok, err = turtle.equipRight()
    end
    if ok then
      local now = getEquipped(side)
      print(("Equipped on %s: %s"):format(side, describeTool(now or bestDetail)))
      return true, side
    end
    lastErr = err or "failed"
    print(("  %s: %s"):format(side, tostring(lastErr)))
  end

  print("Could not equip tool. " .. tostring(lastErr))
  if enchantCount(bestDetail) > 0 then
    print("Enchanted tools need CC: Tweaked to allow them (datapack /")
    print("allowEnchantments). Unenchanted diamond picks always work.")
  end
  return false, lastErr
end

-- Dump mined goods to the chest behind. Never drops slot 16 (coal stays).
-- Also keeps pickaxes/tools in inventory so dump does not eat an unequipped pick.
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
        local d = itemDetail(s)
        if isToolItem(d) then
          -- Leave tools for `equip` / boot auto-equip.
        else
          turtle.drop()
        end
      end
    end
  end
  turtle.select(FUEL_SLOT)
  faceForward()
end

local function setupChests()
  print("Setup: fuel chest LEFT → slot 16 only; storage BEHIND → dump 1-15.")
  print("Facing into the mine at top-front-left (origin 0,0,0)...")
  equipToolFromInventory(nil, true)
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
  if j.type == "area" then
    return ("area %dx%d stopY=%d %s  step %d/%d  [%s]"):format(
      j.W or 0, j.L or j.D or 0, j.stopY or j.H or 0, tostring(j.pattern or "column"),
      tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
  elseif j.type == "box" then
    return ("box %dx%dx%d %s  step %d/%d  [%s]"):format(
      j.W or 0, j.H or 0, j.D or 0, tostring(j.pattern or "column"),
      tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
  elseif j.type == "tunnel" then
    return ("tunnel L=%d W=%d (2hi)  step %d/%d  [%s]"):format(
      j.L or 0, j.W or 1,
      tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
  elseif j.type == "stair" then
    return ("stair %dx%d %s  step %d/%d  [%s]"):format(
      j.W or 0, j.steps or 0, tostring(j.dir or "?"),
      tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
  end
  return tostring(j.type)
end

-- Normalize area jobs onto W/H/D used by the box digger (H = stopY down, D = length).
local function normalizeAreaJob(j)
  if not j or j.type ~= "area" then return j end
  j.L = tonumber(j.L) or tonumber(j.D) or 0
  j.stopY = tonumber(j.stopY) or tonumber(j.H) or 0
  j.W = tonumber(j.W) or 0
  j.H = j.stopY
  j.D = j.L
  return j
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
-- Used by box/area only — single-block footprint, no player headroom.
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

-- Clear 2-tall player headroom at the current cell (dig the block above feet).
local function clearPlayerHeadroom()
  digDir("up")
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
      -- Job fully complete — forget progress so the next dig starts clean.
      clearJobFile()
      activeJob = nil
      print("Job finished — cleared " .. JOB_FILE)
    else
      activeJob.status = "paused"
      saveJobFile(activeJob)
      print("Job paused: " .. tostring(err or "stop"))
      print("Put turtle at origin 0,0,0 facing in, then: continue")
      print("(Or `clearjob` to forget this dig.)")
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
  if j.type == "area" then normalizeAreaJob(j) end
  local W, H, D = j.W, j.H, j.D
  -- Quarry jobs are ALWAYS true 1-Y-layer passes (never column / never 2-high).
  j.pattern = "layer"
  local units = boxLayerUnits(W, H, D)
  j.total = #units
  j.idx = math.max(1, tonumber(j.idx) or 1)
  j.status = "active"
  activeJob = j
  dug = tonumber(j.dug) or dug
  skipped = tonumber(j.skipped) or skipped
  saveJobFile(j)
  jobLabel = jobSummary(j)
  if j.type == "area" then
    print(("AREA %dx%d  stopY=%d  (1 layer at a time)  resume @ %d/%d"):format(
      W, D, H, j.idx, j.total))
  else
    print(("BOX %dx%dx%d  (1 layer at a time)  resume @ %d/%d"):format(
      W, H, D, j.idx, j.total))
  end

  local lastY = -999
  for i = j.idx, #units do
    if STOP then finishJob(false, "stop"); return end
    local u = units[i]
    j.idx = i
    saveJobFile(j)
    if not manageInventory(true) then finishJob(false, "inventory/fuel"); return end

    -- Drop exactly one Y when the work-list advances to the next layer.
    if lastY ~= -999 and u.y > lastY then
      if not goTo(0, lastY, 0) then finishJob(false, "layer path"); return end
      while pos.y < u.y do
        if not moveDown() then finishJob(false, "layer drop"); return end
      end
      print(("  layer %d / %d"):format(u.y + 1, H))
    elseif lastY == -999 then
      print(("  layer %d / %d"):format(u.y + 1, H))
    end
    lastY = u.y

    -- Excavate ONLY this Y plane (goTo digs 1-high forward). Do NOT digDown —
    -- that was clearing a second layer under the turtle.
    if not goTo(u.x, u.y, u.z) then finishJob(false, "path"); return end

    j.idx = i + 1
    saveJobFile(j)
  end
  finishJob(true)
end

local function runTunnelJob(j)
  -- Player-tall corridor: dig path + clear the block above (2 high).
  local L, W = j.L, j.W or 1
  j.H = 2
  local units = tunnelUnits(L, W)
  j.total = #units
  j.idx = math.max(1, tonumber(j.idx) or 1)
  j.status = "active"
  activeJob = j
  dug = tonumber(j.dug) or dug
  skipped = tonumber(j.skipped) or skipped
  saveJobFile(j)
  jobLabel = jobSummary(j)
  print(("TUNNEL L=%d W=%d (player height 2)  resume @ %d/%d"):format(L, W, j.idx, j.total))

  for i = j.idx, #units do
    if STOP then finishJob(false, "stop"); return end
    local u = units[i]
    j.idx = i
    saveJobFile(j)
    if not manageInventory(true) then finishJob(false, "inventory/fuel"); return end
    if not goTo(u.x, 0, u.z) then finishJob(false, "path"); return end
    clearPlayerHeadroom()
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
    -- Player-tall tread: clear above + the step below.
    clearPlayerHeadroom()
    digDir("down")
    -- After last cell of a step, step forward/up/down toward next step
    local nextU = units[i + 1]
    if nextU and nextU.step ~= u.step then
      if not goTo(0, u.y, u.z) then finishJob(false, "stair edge"); return end
      faceForward()
      if not moveForward() then finishJob(false, "forward"); return end
      clearPlayerHeadroom()
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
    clearJobFile()
    print("Old finished job cleared. Start a new dig (area / box / …).")
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
  if j.type == "box" or j.type == "area" then
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
    print("Usage: box <W>x<H>x<D>   (H = layers down, 1 Y at a time)")
    return
  end
  dug, skipped = 0, 0
  local units = boxLayerUnits(W, H, D)
  local j = {
    type = "box", W = W, H = H, D = D, pattern = "layer",
    idx = 1, total = #units, status = "active", dug = 0, skipped = 0,
  }
  runSavedJob(j, false)
end

-- Area: width × length footprint, dig stopY one-high layers down from origin.
-- Example: area 16x32 40   → 16 right, 32 forward, 40 layers of 1 Y each
local function digArea(W, L, stopY, opts)
  opts = opts or {}
  W = math.floor(tonumber(W) or 0)
  L = math.floor(tonumber(L) or 0)
  stopY = math.floor(tonumber(stopY) or 0)
  if W < 1 or L < 1 or stopY < 1 then
    print("Usage: area <W>x<L> <stopY>")
    print("  W = width (right), L = length (forward), stopY = layers down (1 Y each)")
    print("Example: area 16x32 40")
    return
  end
  dug, skipped = 0, 0
  local units = boxLayerUnits(W, stopY, L)
  local j = {
    type = "area", W = W, L = L, stopY = stopY,
    H = stopY, D = L, pattern = "layer",
    idx = 1, total = #units, status = "active", dug = 0, skipped = 0,
  }
  runSavedJob(j, false)
end

-- Tunnel is always player-tall (2 high). Usage: tunnel <L> [W]
local function digTunnel(L, W)
  L = math.floor(tonumber(L) or 0)
  W = math.floor(tonumber(W) or 1)
  if L < 1 or W < 1 then
    print("Usage: tunnel <L> [W]   (length forward, optional width; player height 2)")
    return
  end
  dug, skipped = 0, 0
  local units = tunnelUnits(L, W)
  local j = {
    type = "tunnel", L = L, H = 2, W = W,
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
    print("No saved job in " .. JOB_FILE .. ". Start with area / box / tunnel / stair.")
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
  print("  area <W>x<L> <stopY>             width × length, stopY layers (1 Y each)")
  print("  box <W>x<H>x<D>                  H layers down, 1 Y at a time")
  print("  tunnel <L> [W]                   player-tall (2 high) corridor")
  print("  stair <W>x<steps> <up|down>      player-tall staircase")
  print("  equip [left|right]               equip pick from inventory (aliases: tool, pick)")
  print("  continue | resume                resume saved job (from origin)")
  print("  job | clearjob                   show / forget saved job")
  print("  home | dump | refuel | setup | stop | status")
  print("")
  print("Jobs save to " .. JOB_FILE .. " while running / paused.")
  print("Finished digs clear that file automatically. After stop: origin + continue.")
  print("Enchanted pick: put it in inventory, then `equip` (not craft onto turtle).")
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
  elseif cmd == "equip" or cmd == "tool" or cmd == "pick" or cmd == "pickaxe" then
    equipToolFromInventory(a[2])
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
  elseif cmd == "clearjob" or cmd == "forgetjob" or cmd == "clear" then
    clearJobFile()
    activeJob = nil
    jobLabel = "idle"
    print("Cleared " .. JOB_FILE)
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
  elseif cmd == "area" or cmd == "quarry" or cmd == "flatten" then
    -- area 16x32 40   or   area 16x32 stop 40   or   area 16 32 40
    local d = parseDims(a, 2)
    local stopY = nil
    if d and d[1] and d[2] and d[3] and not tostring(a[2] or ""):find("x") then
      digArea(d[1], d[2], d[3])
    elseif d and d[1] and d[2] then
      for i = 3, #a do
        local t = tostring(a[i]):lower()
        if t ~= "stop" and t ~= "to" and t ~= "y" and not normalizePattern(t) then
          stopY = tonumber(a[i])
          if stopY then break end
        end
      end
      if not stopY and d[3] then stopY = d[3] end
      if not stopY then
        print("Usage: area <W>x<L> <stopY>")
        print("Example: area 16x32 40   (40 layers of 1 Y each)")
      else
        digArea(d[1], d[2], stopY)
      end
    else
      print("Usage: area <W>x<L> <stopY>")
      print("  W=width  L=length  stopY=how many 1-high layers down")
      print("Example: area 16x32 40")
    end
  elseif cmd == "box" then
    local d = parseDims(a, 2)
    if not d or not d[1] or not d[2] or not d[3] then
      print("Usage: box <W>x<H>x<D>   (H = 1-high layers down)")
    else
      digBox(d[1], d[2], d[3])
    end
  elseif cmd == "tunnel" then
    -- tunnel 32          → L=32 W=1
    -- tunnel 32 3        → L=32 W=3
    -- tunnel 32x3        → L=32 W=3  (old LxH form: second number is width now)
    local d = parseDims(a, 2)
    if not d or not d[1] then
      print("Usage: tunnel <L> [W]   (player height 2)")
    else
      local L = d[1]
      local W = d[2] or tonumber(a[3]) or 1
      digTunnel(L, W)
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
  -- If a pick is sitting in inventory (e.g. enchanted), mount it before digging.
  equipToolFromInventory(nil, true)
  suckFuelFromLeft()
  print("Fuel: " .. tostring(turtle.getFuelLevel()))
end

local saved = loadJobFile()
if saved and saved.status == "done" then
  clearJobFile()
  saved = nil
end
if saved then
  print("")
  print("Saved job: " .. jobSummary(saved))
  print("Place at origin facing in, then: continue")
  print("Or `clearjob` to forget it.")
end

print("")
print("Type help. Examples:  area 16x32 40   |   continue")
print("")

while true do
  write("mine> ")
  local line = read()
  local r = handleCommand(line)
  if r == "exit" then break end
end

print("Offline miner stopped.")
