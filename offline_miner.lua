--[[
  offline_miner.lua  -  Local quarry turtle (optional site board)
  Titan-Version: 1.1.5

  Place the turtle at the TOP-FRONT-LEFT corner of the dig, facing into the
  mine. That cell is origin 0,0,0:

      +X = right
      +Y = down
      +Z = forward (into the mine)

  First boot (or `setup`):
    * Fuel chest is on the LEFT  → top up slot 16 with coal only (keeps it there)
    * Storage chest is BEHIND    → dumps slots 1-14 (never 15 modem / 16 fuel)
    * Slot 15 = wireless modem (swapped with the diamond pickaxe for site/admin
      comms; never replaces a loader / non-pickaxe upgrade)
    * Site computer (optional) LEFT of the storage chest — multi-turtle Y claims
    * If a pickaxe (incl. enchanted) is in the turtle inventory, equip it as a
      tool upgrade via turtle.equipLeft/Right (crafting often rejects enchantments)

  box / area — ALWAYS 1 Y-layer at a time (walk the plane, then drop one).
               Never digs 2 high; no player headroom on quarry jobs.

  Modem (slot 15):
    For site/admin talk, equips the modem in place of the diamond pickaxe, then
    puts the pickaxe back before digging. Loader upgrades are never touched.
    join                     find site board (optional)
    mine                     claim a Y band when a site is online
    site                     show site / BPC / broadcast status

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
    home | dump | refuel | setup | stop | status | help

  Optional: exclude.txt (same format as the network miner) — never break those.

  Solo: no modem needed. Admin progress: modem. Multi Y-band: modem + offline_site.
  Run:  offline_miner
]]

local CFG = "offline_miner.cfg"
local JOB_FILE = "offline_miner_job.cfg"
local EXCLUDE = "exclude.txt"
local FUEL_SLOT = 16
local MODEM_SLOT = 15   -- wireless modem; swapped with diamond pickaxe for comms
local MIN_FUEL = 200
local STOP = false
local PROTO_QUARRY = "titan_quarry"
local digging = false
local modemSwapSide = nil  -- "left"|"right" while modem is equipped over the pick

-- Relative pose from boot origin. +Y is DOWN.
local pos = { x = 0, y = 0, z = 0 }
local facing = 0   -- 0=+Z forward, 1=+X right, 2=-Z back, 3=-X left
local dug = 0
local skipped = 0
local moves = 0
local coalBurned = 0
local jobLabel = "-"
local activeJob = nil   -- in-memory copy of JOB_FILE while running

-- Optional site board (offline_site.lua)
local siteId = nil
local siteInfo = nil   -- last welcome / claim
local maxTravel = nil  -- from site (blocks, round-trip budget)

local exclude = {}
local cfg = {
  setupDone = false,
  label = nil,
  pattern = "column",  -- "column" | "layer"
  siteId = nil,
}

local function currentBpc()
  local work = dug + moves
  if coalBurned < 1 then
    -- No coal burned yet — estimate from fuel if we have sample data later.
    return work > 0 and work or 48
  end
  return work / coalBurned
end

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
  moves = moves + 1
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
  coalBurned = coalBurned + burn
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
    if s ~= FUEL_SLOT and s ~= MODEM_SLOT and turtle.getItemCount(s) == 0 then
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

local function isModemItem(detail)
  if type(detail) ~= "table" or not detail.name then return false end
  return tostring(detail.name):lower():find("modem", 1, true) ~= nil
end

local function isDiamondPickaxe(detail)
  if type(detail) ~= "table" or not detail.name then return false end
  local n = tostring(detail.name):lower()
  return n:find("pickaxe", 1, true) ~= nil and n:find("diamond", 1, true) ~= nil
end

local function sideLooksLikeModem(side)
  local t = peripheral.getType(side)
  if t == "modem" or t == "wired_modem" or t == "wireless_modem" then return true end
  local d = getEquipped(side)
  if d and isModemItem(d) then return true end
  return false
end

local function sideLooksLikeDigTool(side)
  local d = getEquipped(side)
  if not d then return false end
  return toolKind(d.name) ~= nil
end

-- Prefer diamond pickaxe side; never treat a non-pickaxe upgrade (e.g. loader) as swappable.
local function findPickaxeSide()
  for _, side in ipairs({ "left", "right" }) do
    local d = getEquipped(side)
    if d and isDiamondPickaxe(d) then return side, d end
  end
  for _, side in ipairs({ "left", "right" }) do
    local d = getEquipped(side)
    if d and toolKind(d.name) == "pickaxe" then return side, d end
  end
  return nil
end

local function findModemInInventory()
  if isModemItem(itemDetail(MODEM_SLOT)) then return MODEM_SLOT end
  for s = 1, 16 do
    if s ~= FUEL_SLOT and isModemItem(itemDetail(s)) then return s end
  end
  return nil
end

local function moveModemToSlot15()
  local slot = findModemInInventory()
  if not slot then return false end
  if slot == MODEM_SLOT then return true end
  if turtle.getItemCount(MODEM_SLOT) > 0 and not isModemItem(itemDetail(MODEM_SLOT)) then
    -- Keep pickaxe/tools; don't overwrite a tool parked in 15.
    if isToolItem(itemDetail(MODEM_SLOT)) then return false end
  end
  turtle.select(slot)
  if turtle.getItemCount(MODEM_SLOT) > 0 then
    -- Swap into an empty slot if needed
    for s = 1, 14 do
      if turtle.getItemCount(s) == 0 then
        turtle.select(MODEM_SLOT)
        turtle.transferTo(s)
        break
      end
    end
  end
  turtle.select(slot)
  return turtle.transferTo(MODEM_SLOT) or isModemItem(itemDetail(MODEM_SLOT))
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

-- Dump mined goods to the chest behind. Never drops slot 16 (coal) or 15 (modem).
-- Also keeps pickaxes/tools in inventory so dump does not eat an unequipped pick.
local function dumpToStorage()
  consolidateFuelToSlot16()
  faceBack()
  for s = 1, 14 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      -- If somehow still fuel, try slot 16 again instead of storing it.
      if selectedIsFuel() and turtle.getItemSpace(FUEL_SLOT) > 0 then
        turtle.transferTo(FUEL_SLOT)
      end
      if turtle.getItemCount(s) > 0 then
        local d = itemDetail(s)
        if isToolItem(d) or isModemItem(d) then
          -- Leave tools / modem for equip / comms.
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
  print("Setup: fuel LEFT → slot 16; modem in slot 15; storage BEHIND → dump 1-14.")
  print("Optional: site computer LEFT of the storage chest (offline_site).")
  print("Facing into the mine at top-front-left (origin 0,0,0)...")
  equipToolFromInventory(nil, true)
  dumpToStorage()
  local fuel = suckFuelFromLeft()
  cfg.setupDone = true
  saveCfg()
  print(("Setup done. Tank=%s  coal in slot 16=%d  modem slot 15=%d"):format(
    tostring(fuel), turtle.getItemCount(FUEL_SLOT), turtle.getItemCount(MODEM_SLOT)))
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
    moves = moves + 1
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
    moves = moves + 1
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

-- Forward decl: site sync uses this after save/clear.
local siteSendJob
local fetchJobFromSite

-- Adopt a job table from the site board (or elsewhere) as local JOB_FILE.
local function adoptJob(j, source)
  if type(j) ~= "table" or not j.type then return nil end
  if j.status == "done" then return nil end
  dug = tonumber(j.dug) or dug or 0
  skipped = tonumber(j.skipped) or skipped or 0
  j.updated = os.epoch("utc")
  local f = fs.open(JOB_FILE, "w")
  f.write(textutils.serialize(j))
  f.close()
  activeJob = j
  print(("Adopted job from %s: %s"):format(
    tostring(source or "site"),
    (j.y0 and ("Y%d-%d step %d/%d"):format(j.y0, j.y1 or j.y0, tonumber(j.idx) or 1, tonumber(j.total) or 0))
      or (tostring(j.type) .. " step " .. tostring(j.idx or 1) .. "/" .. tostring(j.total or 0))))
  return j
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

local function clearJobFile(opts)
  opts = opts or {}
  if fs.exists(JOB_FILE) then pcall(fs.delete, JOB_FILE) end
  activeJob = nil
  -- Tell site to drop its copy unless this was a normal finish (site keeps last snapshot).
  if not opts.keepSite and siteSendJob then siteSendJob(nil, true) end
end

local function jobSummary(j)
  if not j then return "(none)" end
  if j.type == "area" then
    if j.y0 ~= nil and j.y1 ~= nil then
      return ("area %dx%d Y%d-%d %s  step %d/%d  [%s]"):format(
        j.W or 0, j.L or j.D or 0, j.y0, j.y1, tostring(j.pattern or "layer"),
        tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
    end
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

local function distHome()
  return math.abs(pos.x) + math.abs(pos.y) + math.abs(pos.z)
end

local function goHome()
  jobLabel = "home"
  local ok, err = goTo(0, 0, 0)
  faceForward()
  return ok, err
end

local function travelBudgetTight()
  if not maxTravel then return false end
  return distHome() * 2 >= math.floor(maxTravel * 0.85)
end

local function manageInventory(resume)
  local force = travelBudgetTight()
  if not force and not inventoryFull() and ensureFuel() then return true end
  if force then
    print(("Travel budget (maxTravel=%s) — dumping before going deeper..."):format(
      tostring(maxTravel)))
  else
    print("Inventory/fuel break — returning to origin...")
  end
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

-- Shared footprint W×D, only layers y0..y1 (inclusive, +Y = down).
local function boxBandUnits(W, D, y0, y1)
  local units = {}
  y0 = math.floor(tonumber(y0) or 0)
  y1 = math.floor(tonumber(y1) or y0)
  if y1 < y0 then y0, y1 = y1, y0 end
  for y = y0, y1 do
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
-- Optional quarry site board (offline_site.lua)
--------------------------------------------------------------------------------
local function openModem()
  local any = false
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      any = true
    end
  end
  return any
end

-- Put wireless modem on the diamond-pickaxe upgrade side (never a loader).
local function ensureModemForComms(quiet)
  if openModem() then
    if sideLooksLikeModem("left") then modemSwapSide = modemSwapSide or "left" end
    if sideLooksLikeModem("right") then modemSwapSide = modemSwapSide or "right" end
    return true
  end
  if not moveModemToSlot15() and not isModemItem(itemDetail(MODEM_SLOT)) then
    if not quiet then
      print("No wireless modem. Put one in slot " .. MODEM_SLOT .. " for site/admin.")
    end
    return false
  end
  local function sideIsLoaderLike(side)
    local d = getEquipped(side)
    if not d or not d.name then return false end
    if isModemItem(d) then return false end
    if toolKind(d.name) == "pickaxe" then return false end
    -- Anything else equipped (chunk loader, etc.) is protected.
    return true
  end
  local side = findPickaxeSide()
  if not side then
    -- Empty upgrade slot only — never equip over a loader / non-pickaxe.
    if not sideLooksLikeModem("left") and not sideIsLoaderLike("left")
        and not sideLooksLikeDigTool("left") then
      side = "left"
    elseif not sideLooksLikeModem("right") and not sideIsLoaderLike("right")
        and not sideLooksLikeDigTool("right") then
      side = "right"
    else
      if not quiet then
        print("No diamond pickaxe side to swap — won't replace a loader upgrade.")
      end
      return false
    end
  end
  turtle.select(MODEM_SLOT)
  local ok
  if side == "left" then ok = turtle.equipLeft() else ok = turtle.equipRight() end
  if not ok then
    if not quiet then print("Could not equip modem on " .. side) end
    return false
  end
  modemSwapSide = side
  if not openModem() then
    if not quiet then print("Modem equipped but rednet failed to open.") end
    return false
  end
  return true
end

-- Swap modem back off; diamond pickaxe returns from slot 15 to the upgrade slot.
local function restorePickAfterComms()
  if not modemSwapSide then return end
  local side = modemSwapSide
  -- After modem equip, slot 15 should hold the pickaxe we swapped out.
  if turtle.getItemCount(MODEM_SLOT) > 0 then
    turtle.select(MODEM_SLOT)
    if side == "left" then turtle.equipLeft() else turtle.equipRight() end
  end
  modemSwapSide = nil
  -- If pickaxe landed elsewhere, try normal equip.
  if not findPickaxeSide() then
    equipToolFromInventory(side, true)
  end
end

local function footprintFromJob(j)
  if type(j) ~= "table" then return nil end
  local W = math.floor(tonumber(j.W) or 0)
  local L = math.floor(tonumber(j.L) or tonumber(j.D) or 0)
  local H = math.floor(tonumber(j.stopY) or tonumber(j.H) or 0)
  if j.y1 ~= nil then
    H = math.max(H, math.floor(tonumber(j.y1) or 0) + 1)
  end
  if W < 1 or L < 1 or H < 1 then return nil end
  return W, L, H
end

local function sitePayload(extra)
  local msg = {
    name = os.getComputerLabel(),
    hostname = os.getComputerLabel(),
    turtleId = os.getComputerID(),
    bpc = currentBpc(),
    fuel = turtle.getFuelLevel(),
    dug = dug,
    moves = moves,
    coal = coalBurned,
    status = (activeJob and activeJob.status) or "idle",
    hasSite = siteId ~= nil,
  }
  local j = activeJob or loadJobFile()
  if j then
    msg.job = j
    msg.jobFile = JOB_FILE
    msg.idx = j.idx
    msg.total = j.total
    msg.y0 = j.y0 or msg.y0
    msg.y1 = j.y1 or msg.y1
    local W, L, H = footprintFromJob(j)
    if W then msg.W, msg.L, msg.H = W, L, H end
  elseif siteInfo then
    msg.y0 = siteInfo.y0
    msg.y1 = siteInfo.y1
    msg.W = siteInfo.W
    msg.L = siteInfo.L
    msg.H = siteInfo.H
  end
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      if k ~= "type" and k ~= "_siteType" then msg[k] = v end
    end
  end
  return msg
end

-- Broadcast mine data for admin (always). Also unicast to site board when joined.
-- Swaps slot-15 modem over the diamond pickaxe, then restores the pickaxe.
local function publishMine(extra)
  if not ensureModemForComms(true) then return false end
  extra = extra or {}
  local base = sitePayload(extra)
  local bcast = {}
  for k, v in pairs(base) do bcast[k] = v end
  bcast.type = "quarry_turtle"
  rednet.broadcast(bcast, PROTO_QUARRY)
  rednet.broadcast(bcast, "titan_net")
  if siteId then
    local uni = {}
    for k, v in pairs(base) do uni[k] = v end
    uni.type = extra._siteType or "quarry_progress"
    rednet.send(siteId, uni, PROTO_QUARRY)
  end
  -- Keep modem up while idle (listening); put pickaxe back while digging.
  if digging then restorePickAfterComms() end
  return true
end

local function siteSend(msgType, extra)
  if not siteId then
    -- No board — still publish so admin tablet can see us.
    return publishMine(extra)
  end
  extra = extra or {}
  extra._siteType = msgType
  return publishMine(extra)
end

local function siteReportProgress(extra)
  extra = extra or {}
  extra._siteType = "quarry_progress"
  return publishMine(extra)
end

-- Push offline_miner_job.cfg to site (if any) and broadcast for admin.
siteSendJob = function(j, clearing)
  if clearing or not j then
    return publishMine({
      _siteType = "quarry_job",
      clearJob = true, job = false, status = "idle",
    })
  end
  return publishMine({
    _siteType = "quarry_job",
    job = j, jobFile = JOB_FILE, status = j.status or "active",
  })
end

local function joinSite(timeout, quiet)
  timeout = tonumber(timeout) or 6
  quiet = quiet == true
  if not ensureModemForComms(quiet) then
    if not quiet then
      print("No modem in slot " .. MODEM_SLOT .. " — solo dig only (no site/admin link).")
    end
    return false
  end
  local joinMsg = sitePayload({})
  joinMsg.type = "quarry_join"
  -- Ask site to include our stored job if we have none locally.
  joinMsg.wantJob = loadJobFile() == nil
  rednet.broadcast(joinMsg, PROTO_QUARRY)
  local deadline = os.clock() + timeout
  local found = false
  local welcomed = nil
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO_QUARRY, math.max(0.05, deadline - os.clock()))
    if id and type(msg) == "table" and msg.type == "quarry_welcome" then
      siteId = id
      siteInfo = msg
      maxTravel = tonumber(msg.maxTravel) or maxTravel
      cfg.siteId = id
      saveCfg()
      if not quiet then
        print(("Joined site #%d  %dx%d × %dY  claim=%s  minBPC=%s  maxTravel=%s"):format(
          id,
          tonumber(msg.W) or 0, tonumber(msg.L) or 0, tonumber(msg.H) or 0,
          tostring(msg.fraction or "?"),
          tostring(msg.minBpc or "?"),
          tostring(msg.maxTravel or "?")))
      end
      found = true
      welcomed = msg
      break
    end
  end
  if not found then
    siteId, cfg.siteId = nil, nil
    saveCfg()
    if not quiet then
      print("No site board — OK. Broadcasting mine data for the admin tablet.")
      print("Use `area WxL H` to dig. Multi Y-band claims need offline_site.")
    end
  elseif welcomed and type(welcomed.job) == "table" and not loadJobFile() then
    adoptJob(welcomed.job, "site welcome")
  end
  -- Report once while modem is still equipped.
  local base = sitePayload({ _siteType = found and "quarry_join" or "quarry_progress" })
  local bcast = {}
  for k, v in pairs(base) do bcast[k] = v end
  bcast.type = "quarry_turtle"
  rednet.broadcast(bcast, PROTO_QUARRY)
  rednet.broadcast(bcast, "titan_net")
  if digging then restorePickAfterComms() end
  return found
end

-- Pull offline_miner_job.cfg from the site board when we have none locally.
fetchJobFromSite = function(timeout, quiet)
  timeout = tonumber(timeout) or 5
  quiet = quiet == true
  local localJob = loadJobFile()
  if localJob then return localJob end
  if not ensureModemForComms(quiet) then return nil end
  if not siteId then joinSite(math.min(timeout, 4), true) end
  if not siteId then
    if not quiet then print("No site board to fetch a job from.") end
    if digging then restorePickAfterComms() end
    return nil
  end
  -- Welcome may already have delivered a job during joinSite.
  localJob = loadJobFile()
  if localJob then
    if digging then restorePickAfterComms() end
    return localJob
  end
  local req = sitePayload({})
  req.type = "quarry_job_req"
  req.wantJob = true
  rednet.send(siteId, req, PROTO_QUARRY)
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO_QUARRY, math.max(0.05, deadline - os.clock()))
    if id == siteId and type(msg) == "table" and msg.type == "quarry_job_reply" then
      if digging then restorePickAfterComms() end
      if msg.ok and type(msg.job) == "table" then
        if msg.maxTravel then maxTravel = tonumber(msg.maxTravel) or maxTravel end
        if msg.y0 ~= nil then siteInfo = siteInfo or {}; siteInfo.y0 = msg.y0; siteInfo.y1 = msg.y1 end
        return adoptJob(msg.job, "site board")
      end
      if not quiet then print("Site board has no job stored for this turtle.") end
      return nil
    end
  end
  if digging then restorePickAfterComms() end
  if not quiet then print("Timed out waiting for job from site board.") end
  return nil
end

local function claimBand(nextBand)
  if not siteId then
    if not joinSite() then return nil end
  end
  if not ensureModemForComms() then return nil end
  local req = sitePayload({})
  req.type = "quarry_claim_req"
  if nextBand then
    req.nextBand = true
    req.forceNew = true
  end
  rednet.send(siteId, req, PROTO_QUARRY)
  local deadline = os.clock() + 8
  local claim = nil
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO_QUARRY, math.max(0.05, deadline - os.clock()))
    if id == siteId and type(msg) == "table" and msg.type == "quarry_claim" then
      if not msg.ok then
        print("Claim failed: " .. tostring(msg.err or "unknown"))
        if digging then restorePickAfterComms() end
        return nil
      end
      maxTravel = tonumber(msg.maxTravel) or maxTravel
      siteInfo = msg
      print(("Claimed Y %d..%d  (%d layers)  maxTravel=%s"):format(
        msg.y0, msg.y1, (msg.y1 - msg.y0 + 1), tostring(maxTravel or "?")))
      claim = msg
      break
    end
  end
  if digging then restorePickAfterComms() end
  if not claim then print("Claim timed out.") end
  return claim
end

local function printSiteInfo()
  if not siteId and cfg.siteId then siteId = cfg.siteId end
  print(("siteId=%s  bpc=%.1f  moves=%d coal=%d  maxTravel=%s"):format(
    tostring(siteId or "(none — admin via broadcast)"),
    currentBpc(), moves, coalBurned, tostring(maxTravel or "-")))
  local j = activeJob or loadJobFile()
  local W, L, H = footprintFromJob(j)
  if W then
    print(("mine data: %dx%d × %dY (from job)"):format(W, L, H))
  end
  if siteInfo then
    print(("site: %dx%d × %dY  Y=%s..%s  fraction=%s"):format(
      tonumber(siteInfo.W) or 0, tonumber(siteInfo.L) or 0, tonumber(siteInfo.H) or 0,
      tostring(siteInfo.y0 or "?"), tostring(siteInfo.y1 or "?"),
      tostring(siteInfo.fraction or "?")))
  end
end

-- Answer admin/site polls while idle (modem stays equipped). Quiet while digging
-- so we never yank the pickaxe out from under a dig step.
local function mineNetLoop()
  local last = 0
  while true do
    if digging then
      sleep(1)
    else
      ensureModemForComms(true)
      local id, msg = rednet.receive(PROTO_QUARRY, 2)
      if id and type(msg) == "table" then
        local t = tostring(msg.type or "")
        if t == "quarry_turtle_req" or t == "quarry_status_req" then
          publishMine()
        elseif t == "quarry_welcome" and not siteId then
          siteId = id
          siteInfo = msg
          maxTravel = tonumber(msg.maxTravel) or maxTravel
          cfg.siteId = id
          saveCfg()
          print(("\n[site] Linked to #%d"):format(id))
          publishMine({ _siteType = "quarry_join" })
        end
      end
      if (os.clock() - last) >= 12 then
        if activeJob or loadJobFile() then publishMine() end
        last = os.clock()
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Jobs
--------------------------------------------------------------------------------
local function finishJob(ok, err)
  local wasSite = activeJob and activeJob.site
  local y0 = activeJob and activeJob.y0
  local y1 = activeJob and activeJob.y1
  local lastJob = activeJob
  if activeJob then
    if ok then
      -- Job fully complete — forget local progress so the next dig starts clean.
      -- Site keeps a final offline_miner_job.cfg snapshot under quarry_jobs/.
      if wasSite and lastJob then
        lastJob.status = "done"
        siteSendJob(lastJob)
      end
      clearJobFile({ keepSite = true })
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
  digging = false
  if ok then
    publishMine({
      _siteType = "quarry_done",
      status = "done", finished = true, y0 = y0, y1 = y1,
      job = lastJob, jobFile = JOB_FILE,
    })
  else
    publishMine({
      _siteType = "quarry_progress",
      status = "paused", job = activeJob or lastJob, jobFile = JOB_FILE,
    })
  end
  restorePickAfterComms()
  goHome()
  dumpToStorage()
  suckFuelFromLeft()
  jobLabel = "idle"
  if ok then
    print(("Done. dug=%d skipped=%d bpc=%.1f fuel=%s"):format(
      dug, skipped, currentBpc(), tostring(turtle.getFuelLevel())))
  end
end

local function runBoxJob(j)
  if j.type == "area" then normalizeAreaJob(j) end
  local W, H, D = j.W, j.H, j.D
  -- Quarry jobs are ALWAYS true 1-Y-layer passes (never column / never 2-high).
  j.pattern = "layer"
  local units
  if j.y0 ~= nil and j.y1 ~= nil then
    units = boxBandUnits(W, D, j.y0, j.y1)
  else
    units = boxLayerUnits(W, H, D)
  end
  j.total = #units
  j.idx = math.max(1, tonumber(j.idx) or 1)
  j.status = "active"
  activeJob = j
  dug = tonumber(j.dug) or dug
  skipped = tonumber(j.skipped) or skipped
  saveJobFile(j)
  jobLabel = jobSummary(j)
  if j.y0 ~= nil and j.y1 ~= nil then
    print(("AREA %dx%d  Y%d..%d  (site band)  resume @ %d/%d"):format(
      W, D, j.y0, j.y1, j.idx, j.total))
  elseif j.type == "area" then
    print(("AREA %dx%d  stopY=%d  (1 layer at a time)  resume @ %d/%d"):format(
      W, D, H, j.idx, j.total))
  else
    print(("BOX %dx%dx%d  (1 layer at a time)  resume @ %d/%d"):format(
      W, H, D, j.idx, j.total))
  end

  local lastY = -999
  local layerCount = (j.y0 ~= nil and j.y1 ~= nil) and (j.y1 - j.y0 + 1) or H
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
      print(("  layer Y=%d  (%d layers in band)"):format(u.y, layerCount))
    elseif lastY == -999 then
      print(("  layer Y=%d  (%d layers in band)"):format(u.y, layerCount))
    end
    lastY = u.y

    -- Excavate ONLY this Y plane (goTo digs 1-high forward). Do NOT digDown —
    -- that was clearing a second layer under the turtle.
    if not goTo(u.x, u.y, u.z) then finishJob(false, "path"); return end

    j.idx = i + 1
    saveJobFile(j)
    if i % 10 == 0 then
      -- Includes full offline_miner_job.cfg for admin / optional site board.
      siteReportProgress({ status = "mining", job = j, jobFile = JOB_FILE })
    end
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
  -- Soft-join site if present; publish footprint, then dig with pickaxe equipped.
  if not siteId then joinSite(2, true) end
  publishMine({ _siteType = "quarry_job", job = j, status = "active" })
  restorePickAfterComms()
  equipToolFromInventory(nil, true)
  digging = true
  if j.type == "box" or j.type == "area" then
    runBoxJob(j)
  elseif j.type == "tunnel" then
    runTunnelJob(j)
  elseif j.type == "stair" then
    runStairJob(j)
  else
    print("Unknown job type: " .. tostring(j.type))
  end
  digging = false
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

-- Dig one claimed Y band. Returns "done" | "paused" | "stop" | "bad".
local function runClaimBand(claim, fromContinue, existingJob)
  local W = math.floor(tonumber(claim.W) or 0)
  local L = math.floor(tonumber(claim.L) or 0)
  local y0 = tonumber(claim.y0)
  local y1 = tonumber(claim.y1)
  if W < 1 or L < 1 or y0 == nil or y1 == nil then
    print("Bad claim from site.")
    return "bad"
  end
  local j = existingJob
  if not j then
    dug, skipped = 0, 0
    local units = boxBandUnits(W, L, y0, y1)
    j = {
      type = "area", W = W, L = L, stopY = y1 + 1,
      H = y1 + 1, D = L, pattern = "layer",
      y0 = y0, y1 = y1, site = true,
      idx = 1, total = #units, status = "active", dug = 0, skipped = 0,
    }
  else
    j.site = true
    j.y0 = y0
    j.y1 = y1
    j.W = W
    j.L = L
    j.D = L
    j.H = y1 + 1
    j.stopY = y1 + 1
  end
  siteSendJob(j)
  siteReportProgress({ status = "mining", y0 = y0, y1 = y1, job = j, jobFile = JOB_FILE })
  runSavedJob(j, fromContinue == true)
  if STOP then return "stop" end
  if loadJobFile() then return "paused" end
  return "done"
end

local function digSiteMine()
  if not siteId and not joinSite(5, false) then
    print("Site board required for Y-band claims. Solo dig: `area <W>x<L> <stopY>`.")
    return
  end

  -- Finish an incomplete claimed band first (local or from site).
  local j = loadJobFile()
  if not j then j = fetchJobFromSite(5, true) end
  if j and j.status ~= "done" and (j.site or j.y0 ~= nil) then
    print(("Resuming claimed Y %s..%s ..."):format(tostring(j.y0), tostring(j.y1)))
    local r = runClaimBand({
      W = j.W, L = j.L or j.D, y0 = j.y0, y1 = j.y1,
    }, true, j)
    if r ~= "done" then return end
    print("Y band complete.")
  end

  local bandsDone = 0
  while not STOP do
    -- After each finished band, ask for a *new* free Y claim.
    local claim = claimBand(bandsDone > 0 or (j ~= nil))
    if not claim then
      if bandsDone == 0 and not j then
        print("No free Y layers. Site needs `setup WxL H`, or all bands are taken/done.")
      else
        print("No more free Y layers — this turtle is done claiming.")
      end
      return
    end
    local stored = nil
    if claim.resume then
      stored = fetchJobFromSite(3, true)
      if stored and (tonumber(stored.y0) ~= tonumber(claim.y0)
          or tonumber(stored.y1) ~= tonumber(claim.y1)) then
        stored = nil
      end
    end
    print(("Mining claimed Y %d..%d (%d layers)..."):format(
      claim.y0, claim.y1, claim.y1 - claim.y0 + 1))
    local r = runClaimBand(claim, stored ~= nil, stored)
    if r ~= "done" then return end
    bandsDone = bandsDone + 1
    j = nil
    print(("Finished Y %d..%d — claiming next free band..."):format(claim.y0, claim.y1))
  end
end

local function continueJob()
  local j = loadJobFile()
  if not j then
    print("No local " .. JOB_FILE .. " — asking site board...")
    j = fetchJobFromSite(6, false)
  end
  if j and (j.site or j.y0 ~= nil) then
    -- Site jobs: resume band then keep claiming more Y levels.
    if not siteId then joinSite(4, true) end
    print("Loaded: " .. jobSummary(j))
    digSiteMine()
    return
  end
  if not j then
    if siteId or joinSite(4, true) then
      print("No saved job — claiming a Y band from the site...")
      digSiteMine()
      return
    end
    print("No saved job locally or on site. Start with area / box / mine.")
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
  print("  join                             find optional site board (modem)")
  print("  mine                             claim Y bands from site until none left")
  print("  site                             show site / BPC / mine broadcast")
  print("  equip [left|right]               equip pick from inventory (aliases: tool, pick)")
  print("  continue | resume                resume saved job (local or from site)")
  print("  job | clearjob                   show / forget saved job")
  print("  home | dump | refuel | setup | stop | status")
  print("")
  print("Slot 15 = wireless modem (swaps over diamond pickaxe for site/admin).")
  print("With a site board: each turtle claims its own Y band; when finished it")
  print("claims another until no free layers remain. Solo: `area <W>x<L> <H>`.")
  print("Jobs save to " .. JOB_FILE .. " while running / paused.")
  print("Finished digs clear that file automatically. After stop: origin + continue.")
  print("Enchanted pick: put it in inventory, then `equip` (not craft onto turtle).")
end

local function printStatus()
  print(("pos=%d,%d,%d face=%d"):format(pos.x, pos.y, pos.z, facing))
  print(("label=%s  dug=%d skipped=%d bpc=%.1f fuel=%s"):format(
    jobLabel, dug, skipped, currentBpc(), tostring(turtle.getFuelLevel())))
  print(("setup=%s  pattern=%s  site=%s"):format(
    tostring(cfg.setupDone), tostring(cfg.pattern or "column"), tostring(siteId or "-")))
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
  elseif cmd == "join" then
    joinSite(tonumber(a[2]) or 6)
  elseif cmd == "mine" then
    digSiteMine()
  elseif cmd == "site" then
    printSiteInfo()
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
  clearJobFile({ keepSite = true })
  saved = nil
end

if cfg.siteId then
  siteId = cfg.siteId
end
local hasModem = ensureModemForComms(true) or openModem() or findModemInInventory() ~= nil
if hasModem then
  print("Modem slot " .. MODEM_SLOT .. ": swaps over diamond pickaxe for site/admin.")
  print("Optional site board: `join` / `mine` for shared Y bands.")
  joinSite(2, true)
  if not saved then
    saved = loadJobFile()  -- may have been adopted from site welcome
  end
  -- Idle with modem listening; pickaxe re-equipped when a dig starts.
  ensureModemForComms(true)
else
  print("No modem in slot " .. MODEM_SLOT .. " — dig works; no site/admin link.")
end

if saved then
  print("")
  print("Saved job: " .. jobSummary(saved))
  print("Place at origin facing in, then: continue")
  print("Or `clearjob` to forget it.")
elseif hasModem then
  print("")
  print("No local job — `continue` or `mine` will ask the site board.")
end

print("")
print("Type help. Examples:  area 16x32 40   |   continue")
print("")

local function consoleLoop()
  while true do
    write("mine> ")
    local line = read()
    local r = handleCommand(line)
    if r == "exit" then return end
  end
end

if hasModem then
  parallel.waitForAny(consoleLoop, mineNetLoop)
else
  consoleLoop()
end

print("Offline miner stopped.")
