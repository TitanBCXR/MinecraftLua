--[[
  offline_miner.lua  -  Local quarry turtle (optional site board)
  Titan-Version: 1.6.0

  Place the turtle at the TOP-FRONT-LEFT corner of the dig, facing into the
  mine. That cell is origin 0,0,0:

      +X = right
      +Y = down
      +Z = forward (into the mine)

  First boot (or `setup`):
    * Fuel chest is on the LEFT  → top up slot 16 with coal only (keeps it there)
    * Storage chest is BEHIND    → dumps slots 1-14 (never 15 modem / 16 fuel)
    * Slot 15 = wireless modem
    * Pickaxe on turtle upgrade slot 2 (RIGHT) — modem only swaps with that side
      (left upgrade / chunk loader is never touched)
    * Site computer (optional) LEFT of the storage chest — cell fleet claims

  box / area (solo) — ALWAYS 1 Y-layer at a time (walk the plane, then drop one).

  Online fleet (site board — XZ cells):
    * Claim one cell (target 20×20 XZ, full H, layer dig)
    * Modem ON while traveling; check-in leave_origin + arrive_cell
    * Surface hops: up 1 → cross XZ → down into cell (modem can't dig sideways)
    * Traffic: only other miners trigger overtake/yield; other entities → wait
    * Dig full height one Y layer at a time; stay inside cell perimeter
    * Final full-cell verify walk before site cell_done (no false completes)
    * Home → cell_done → next free cell (same up-over-down hop)
    * Fuel: return to depot while still able to reach it; mid-path fuel chests OK
    * If stranded short of depot → SOS admin with coords + suggested refuel spot
    * GPS correction hooks stubbed (relative pose for now)

  Never attack entities (no turtle.attack*). Dig blocks only.
  Fleet turtle ahead → traffic rules; any other entity → wait until clear.

  Out of fuel: computer still runs. Swaps modem on and broadcasts SOS to the
  admin tablet and MAIN router monitors until coal is restored.

  Commands:
    area <W>x<L> <stopY>     width × length, dig down stopY layers
    box <W>x<H>x<D>          H = number of 1-high layers down
    tunnel <L> [W]           player-tall corridor
    stair <W>x<steps> <up|down>
    equip | tool | pick      equip best pickaxe from inventory
    continue | resume        resume saved / site job
    mode online|offline      online = site/admin; offline = solo
    join | mine | site
    job | clearjob | home | dump | refuel | setup | stop | status | help

  mode offline — solo dig, no site/admin.
  mode online  — wait for modem, join site, claim cells, mine with check-ins.
  Run:  offline_miner
]]

local CFG = "offline_miner.cfg"
local JOB_FILE = "offline_miner_job.cfg"
local EXCLUDE = "exclude.txt"
local FUEL_SLOT = 16
local MODEM_SLOT = 15   -- wireless modem; swapped only with RIGHT pickaxe
local PICK_SIDE = "right"  -- turtle upgrade slot 2 — never touch left (loaders)
-- Fuel budget: go home while we still have enough for the up-over-down hop + margin.
local HOME_MARGIN = 24       -- spare fuel on arrival at depot
local WORK_RESERVE = 48      -- keep digging only with this much above home cost
local MIN_FUEL = 200
local TRAFFIC_Y = -1         -- cruise / traffic layer (+Y = down, so -1 is one above origin)
-- Keep in sync with Titan-Version header (label uses major.minor → V1.5-Miner12).
local MINER_VERSION = "1.6.0"
-- "outbound" = to cell (overtake) | "homebound" = to origin (yield) | "dig" = wait/retry
local travelIntent = "dig"
-- Other miners' last known quarry-relative poses (rednet). Used to tell turtle vs mob/player.
local fleetPoses = {}  -- [computerId] = { x, y, z, at }
local FLEET_POSE_MAX_AGE_MS = 15000
local STOP = false
local PROTO_QUARRY = "titan_quarry"
local PROTO_NET = "titan_net"
local PROTO_ROUTER = "titan_router"
local digging = false
local modemSwapSide = nil  -- only "right" while modem is over the pick
local knownPeers = {}      -- [computerId] = true  (site board + admin tablets)
local pendingReturnHome = nil  -- quarry_return_home reason
local activeCell = nil         -- current site cell assign
local titanLib = nil
if fs.exists("lib/titan.lua") then
  local ok, t = pcall(dofile, "lib/titan.lua")
  if ok then titanLib = t end
end

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
-- Tablet Y assign: { y0, y1, assignId, from, W, L, H }
local adminAssign = nil
-- Fleet reband (site → all turtles home, turn-taking origin reset).
local pendingReband = nil     -- quarry_reband msg
local pendingResetGo = nil    -- quarry_reset_go msg
local rebandEpoch = 0
local rebandClaim = nil       -- claim to dig after reset
-- nil | "homing" | "waiting_reset" | "resetting"
local rebandPhase = nil
local handleQuarryNetMsg      -- forward decl (joinSite / reband wait)

local exclude = {}
local cfg = {
  setupDone = false,
  label = nil,
  pattern = "column",  -- dig style: "column" | "layer"
  mode = "online",     -- network: "online" (site/admin) | "offline" (solo)
  siteId = nil,
  pendingAssign = nil,
}

-- Cobalt counts enclosing-chunk locals toward nested functions' 200-local limit.
-- Keep most late helpers on this table (not `local function`) so site dig code can load.
local site = {}

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

local function normalizeNetMode(m)
  m = tostring(m or ""):lower()
  if m == "on" or m == "online" or m == "site" or m == "net" then return "online" end
  if m == "off" or m == "offline" or m == "solo" or m == "local" then return "offline" end
  return nil
end

local function isOnlineMode()
  return (normalizeNetMode(cfg.mode) or "online") == "online"
end

local function isOfflineMode()
  return not isOnlineMode()
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
  cfg.mode = normalizeNetMode(cfg.mode) or "online"
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

-- +Z "into the mine" is only a resting pose at origin XZ. Never spin back to
-- +Z after mining a cell — locomotion uses turnTo() only when a step needs it.
local function atOriginXZ()
  return pos.x == 0 and pos.z == 0
end

local function faceForward()
  if atOriginXZ() then turnTo(0) end
end

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

-- True when tank is empty and no burnable fuel items remain.
-- Computer still runs at 0 fuel (modem / rednet / UI); only move/dig need fuel.
local function hasFuelItems()
  consolidateFuelToSlot16()
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if selectedIsFuel() then return true end
    end
  end
  return false
end

local function tankEmpty()
  local level = turtle.getFuelLevel()
  return level ~= "unlimited" and (not level or level < 1)
end

local function needsFuelSos()
  if not tankEmpty() then return false end
  if hasFuelItems() then
    burnSomeFuel()
    return tankEmpty()
  end
  return true
end

local broadcastSos
local clearSos

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

local function suckFuelIntoSlot16()
  consolidateFuelToSlot16()
  turtle.select(FUEL_SLOT)
  local space = turtle.getItemSpace(FUEL_SLOT)
  if space and space > 0 then
    turtle.suck(space)
  elseif turtle.getItemCount(FUEL_SLOT) == 0 then
    turtle.suck(64)
    consolidateFuelToSlot16()
  end
end

-- Pull ONLY into slot 16 from the left chest (never empties the chest into 1-15).
local function suckFuelFromLeft()
  local saved = facing
  faceLeft()
  suckFuelIntoSlot16()
  -- Top up the fuel tank a little but KEEP coal sitting in slot 16.
  burnSomeFuel()
  turnTo(saved)
  if atOriginXZ() then faceForward() end
  local n = turtle.getItemCount(FUEL_SLOT)
  print(("Fuel slot 16: %d item(s), tank=%s"):format(n, tostring(turtle.getFuelLevel())))
  return turtle.getFuelLevel()
end

-- Mid-path / dig-layer refuel: try every side for a fuel chest (admin stations).
local function suckFuelNearby()
  local saved = facing
  consolidateFuelToSlot16()
  for dir = 0, 3 do
    turnTo(dir)
    suckFuelIntoSlot16()
  end
  turtle.select(FUEL_SLOT)
  local space = turtle.getItemSpace(FUEL_SLOT)
  if space and space > 0 then turtle.suckUp(space) else turtle.suckUp(64) end
  consolidateFuelToSlot16()
  space = turtle.getItemSpace(FUEL_SLOT)
  if space and space > 0 then turtle.suckDown(space) else turtle.suckDown(64) end
  consolidateFuelToSlot16()
  burnSomeFuel()
  turnTo(saved)
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

  -- Offline miners keep the pick on RIGHT (slot 2) so modem swaps never hit left.
  if not sideArg or sideArg == "" then
    order = { PICK_SIDE, (PICK_SIDE == "right") and "left" or "right" }
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
local function setTravelIntent(intent)
  travelIntent = intent or "dig"
end

-- Dig solid blocks only — NEVER attack entities.
local function tryStepForward(digBlocks)
  if STOP then return false, "stop" end
  if not ensureFuel() then
    if needsFuelSos() and broadcastSos then broadcastSos("out_of_fuel") end
    return false, "fuel"
  end
  if digBlocks and turtle.detect() then
    -- Solid block ahead — dig only (never attack; entities aren't blocks).
    digDir("forward")
  end
  if not turtle.detect() then
    if turtle.forward() then
      applyForwardStep()
      return true
    end
    -- No block, but can't move → entity (turtle, player, mob, …).
    return false, "entity"
  end
  return false, "blocked"
end

local function noteFleetPose(id, msg)
  id = tonumber(id)
  if not id or id == os.getComputerID() then return end
  if type(msg) ~= "table" then return end
  local x = tonumber(msg.posX)
  local z = tonumber(msg.posZ)
  if x == nil or z == nil then return end
  fleetPoses[id] = {
    x = math.floor(x),
    y = math.floor(tonumber(msg.posY) or 0),
    z = math.floor(z),
    at = os.epoch("utc"),
  }
end

local function cellAhead()
  local x, y, z = pos.x, pos.y, pos.z
  if facing == 0 then z = z + 1
  elseif facing == 1 then x = x + 1
  elseif facing == 2 then z = z - 1
  else x = x - 1 end
  return x, y, z
end

local function fleetTurtleInCell(x, y, z)
  local now = os.epoch("utc")
  for id, p in pairs(fleetPoses) do
    if p.at and (now - p.at) <= FLEET_POSE_MAX_AGE_MS then
      if p.x == x and p.z == z and math.abs((p.y or 0) - y) <= 1 then
        return id
      end
    end
  end
  return nil
end

-- Filled after rednet helpers exist. Returns "turtle" | "entity".
local classifyEntityAhead

-- Forward decls: traffic helpers call these; moveForward calls the helpers.
local moveUp, moveDown, overtakeOnTraffic, waitForEntityClear

-- Deepest allowed turtle Y for the active job (+Y = down). Nil = no clamp.
local function digFloorY(j)
  j = j or activeJob
  if not j then return nil end
  if j.y1 ~= nil then return math.floor(tonumber(j.y1) or 0) end
  local stop = tonumber(j.stopY) or tonumber(j.H)
  if stop and stop >= 1 then return math.floor(stop) - 1 end
  return nil
end

moveUp = function()
  if STOP then return false, "stop" end
  if not ensureFuel() then return false, "fuel" end
  for _ = 1, 8 do
    digDir("up")
    if not turtle.detectUp() then
      if turtle.up() then
        pos.y = pos.y - 1
        moves = moves + 1
        return true
      end
    end
    -- Entity above (another turtle) — never attack; wait briefly.
    sleep(0.05)
  end
  return false, "blocked"
end

moveDown = function()
  if STOP then return false, "stop" end
  local floor = digFloorY()
  if floor ~= nil and pos.y >= floor then
    return false, "band-floor"
  end
  if not ensureFuel() then return false, "fuel" end
  for _ = 1, 8 do
    digDir("down")
    if not turtle.detectDown() then
      if turtle.down() then
        pos.y = pos.y + 1
        moves = moves + 1
        return true
      end
    end
    sleep(0.05)
  end
  return false, "blocked"
end

-- Outbound (to cell): hop over the other bot, then settle on traffic layer (Y=-1).
overtakeOnTraffic = function()
  print("Turtle ahead — outbound overtake (up, F2, down to traffic)...")
  local yBefore = pos.y
  if not moveUp() then return false, "up" end
  local ok1, err1 = tryStepForward(true)
  if not ok1 then
    while pos.y < yBefore do
      if not moveDown() then break end
    end
    while pos.y > yBefore do
      if not moveUp() then break end
    end
    return false, err1 or "overtake"
  end
  tryStepForward(true)  -- second block past; ok if another bot blocks
  -- Settle onto traffic layer (one above origin dig surface).
  local guard = 0
  while pos.y ~= TRAFFIC_Y and guard < 64 do
    guard = guard + 1
    if pos.y < TRAFFIC_Y then
      if not moveDown() then break end
    else
      if not moveUp() then break end
    end
  end
  return true
end

-- Wait until whatever is ahead moves (mobs/players, or homebound turtle yield).
waitForEntityClear = function(label)
  print(("%s ahead — waiting..."):format(label or "Entity"))
  for _ = 1, 60 do
    if STOP then return false, "stop" end
    sleep(0.5)
    local ok, err = tryStepForward(true)
    if ok then return true end
    if err == "fuel" or err == "stop" then return false, err end
    if err ~= "entity" then return false, err or "blocked" end
  end
  return false, "entity"
end

local function moveForward()
  if STOP then return false, "stop" end
  if not ensureFuel() then return false, "fuel" end
  -- Dig blocks only — never turtle.attack*.
  for _ = 1, 8 do
    local ok, err = tryStepForward(true)
    if ok then return true end
    if err == "entity" then
      local kind = (classifyEntityAhead and classifyEntityAhead()) or "entity"
      if kind == "turtle" and travelIntent == "outbound" then
        if overtakeOnTraffic() then return true end
        sleep(0.35)
      elseif kind == "turtle" and travelIntent == "homebound" then
        local wok, werr = waitForEntityClear("Turtle")
        if wok then return true end
        if werr == "fuel" or werr == "stop" then return false, werr end
      else
        -- Non-turtle entity, or dig mode: wait for it to leave.
        local wok, werr = waitForEntityClear(kind == "turtle" and "Turtle" or "Entity")
        if wok then return true end
        if werr == "fuel" or werr == "stop" then return false, werr end
      end
    elseif err == "fuel" or err == "stop" then
      return false, err
    else
      sleep(0.05)
    end
  end
  local kind = (classifyEntityAhead and classifyEntityAhead()) or "entity"
  if kind == "turtle" and travelIntent == "outbound" and overtakeOnTraffic() then
    return true
  end
  if waitForEntityClear(kind == "turtle" and "Turtle" or "Entity") then
    return true
  end
  return false, "blocked"
end

-- One block only toward target. Never skips a cell.
-- Locomotion uses turnTo() (not faceForward). Prefer the heading we're already on.
local function stepOnceToward(tx, ty, tz)
  local ox, oy, oz = pos.x, pos.y, pos.z
  if oy < ty then
    if not moveDown() then return false, "down" end
  elseif oy > ty then
    if not moveUp() then return false, "up" end
  else
    local dx, dz = tx - ox, tz - oz
    local function stepDir(dir)
      if dir == 0 and dz > 0 then
        turnTo(0)
        if not moveForward() then return false, "z+" end
        return true
      elseif dir == 1 and dx > 0 then
        turnTo(1)
        if not moveForward() then return false, "x+" end
        return true
      elseif dir == 2 and dz < 0 then
        turnTo(2)
        if not moveForward() then return false, "z-" end
        return true
      elseif dir == 3 and dx < 0 then
        turnTo(3)
        if not moveForward() then return false, "x-" end
        return true
      end
      return nil
    end
    local moved, err = stepDir(facing)
    if moved == nil then
      if dx ~= 0 then
        moved, err = stepDir(dx > 0 and 1 or 3)
      elseif dz ~= 0 then
        moved, err = stepDir(dz > 0 and 0 or 2)
      else
        return true
      end
    end
    if moved == false then return false, err or "blocked" end
    if moved == nil then return true end
  end
  local dist = math.abs(pos.x - ox) + math.abs(pos.y - oy) + math.abs(pos.z - oz)
  if dist ~= 1 then
    -- Pose desync / double-step — snap pose to a single intended step.
    print(("WARN: move spanned %d blocks; clamping to 1"):format(dist))
    pos.x, pos.y, pos.z = ox, oy, oz
    if oy < ty then pos.y = oy + 1
    elseif oy > ty then pos.y = oy - 1
    elseif ox < tx then pos.x = ox + 1
    elseif ox > tx then pos.x = ox - 1
    elseif oz < tz then pos.z = oz + 1
    elseif oz > tz then pos.z = oz - 1
    end
  end
  return true
end

local function goTo(tx, ty, tz, opts)
  -- Never re-face +Z at the destination. Dig line keeps its travel heading.
  opts = opts or {}
  local floor = digFloorY()
  tx = math.floor(tonumber(tx) or 0)
  ty = math.floor(tonumber(ty) or 0)
  tz = math.floor(tonumber(tz) or 0)
  if floor ~= nil and ty > floor then
    return false, "past-band"
  end
  local guard = 0
  while pos.x ~= tx or pos.y ~= ty or pos.z ~= tz do
    guard = guard + 1
    if guard > 20000 then return false, "path-limit" end
    local ok, err = stepOnceToward(tx, ty, tz)
    if not ok then return false, err end
  end
  if opts.faceForward then faceForward() end
  return true
end

-- Surface hop for depot ↔ cell travel (modem on = can't dig horizontally).
-- Quarry +Y is down, so "up one" is cruiseY = topY - clear (usually -1).
-- Pure vertical moves skip the hop. opts.beforeSettle() runs before final Y.
local function goToViaAir(tx, ty, tz, opts)
  opts = opts or {}
  local clear = math.max(1, math.floor(tonumber(opts.clear) or 1))
  local prevIntent = travelIntent
  if opts.intent then setTravelIntent(opts.intent) end
  tx = math.floor(tonumber(tx) or 0)
  ty = math.floor(tonumber(ty) or 0)
  tz = math.floor(tonumber(tz) or 0)

  local function finish(ok, err)
    setTravelIntent(prevIntent)
    return ok, err
  end

  if pos.x == tx and pos.y == ty and pos.z == tz then
    if opts.faceForward then faceForward() end
    return finish(true)
  end
  -- Same column — just climb/drop (no sideways tunnel needed).
  if pos.x == tx and pos.z == tz then
    local ok, err = goTo(tx, ty, tz, opts)
    return finish(ok, err)
  end

  local top = math.min(pos.y, ty)
  local cruiseY = top - clear

  if pos.y ~= cruiseY then
    local ok, err = goTo(pos.x, cruiseY, pos.z)
    if not ok then return finish(false, err or "climb") end
  end
  if pos.x ~= tx or pos.z ~= tz then
    local ok, err = goTo(tx, cruiseY, tz)
    if not ok then return finish(false, err or "cross") end
  end
  if type(opts.beforeSettle) == "function" then
    opts.beforeSettle()
  end
  if pos.y ~= ty then
    local ok, err = goTo(tx, ty, tz, opts)
    if not ok then return finish(false, err or "settle") end
  elseif opts.faceForward then
    faceForward()
  end
  return finish(true)
end

-- Clear this voxel: walk-in already dug the floor block; catch gravel/sand + ceiling.
-- Do not dig horizontal neighbors (would eat into adjacent cells).
local function excavateHere()
  digDir("up")
  local floor = digFloorY()
  if floor == nil or pos.y < floor then
    digDir("down")
  end
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
  -- Persist pose so a reboot can keep digging without a player re-seat.
  j.posX, j.posY, j.posZ = pos.x, pos.y, pos.z
  j.facing = facing
  local f = fs.open(JOB_FILE, "w")
  f.write(textutils.serialize(j))
  f.close()
  activeJob = j
end

local function restorePoseFromJob(j)
  if type(j) ~= "table" then return false end
  if j.posX == nil and j.posY == nil and j.posZ == nil then return false end
  -- Turtle body still faces the pre-reboot direction — only restore odometry.
  pos.x = math.floor(tonumber(j.posX) or 0)
  pos.y = math.floor(tonumber(j.posY) or 0)
  pos.z = math.floor(tonumber(j.posZ) or 0)
  facing = math.floor(tonumber(j.facing) or 0) % 4
  print(("Restored pose %d,%d,%d face=%d"):format(pos.x, pos.y, pos.z, facing))
  return true
end

local function distHome()
  return math.abs(pos.x) + math.abs(pos.y) + math.abs(pos.z)
end

-- Fuel cost of an up-over-down hop (matches goToViaAir).
local function airTravelCost(x0, y0, z0, x1, y1, z1)
  x0 = math.floor(tonumber(x0) or 0)
  y0 = math.floor(tonumber(y0) or 0)
  z0 = math.floor(tonumber(z0) or 0)
  x1 = math.floor(tonumber(x1) or 0)
  y1 = math.floor(tonumber(y1) or 0)
  z1 = math.floor(tonumber(z1) or 0)
  if x0 == x1 and y0 == y1 and z0 == z1 then return 0 end
  if x0 == x1 and z0 == z1 then return math.abs(y0 - y1) end
  local clear = 1
  local top = math.min(y0, y1)
  local cruiseY = top - clear
  return math.abs(y0 - cruiseY) + math.abs(x1 - x0) + math.abs(z1 - z0) + math.abs(y1 - cruiseY)
end

-- Blocks of fuel needed to reach depot from a pose (includes arrival margin).
local function homeFuelCost(px, py, pz)
  return airTravelCost(
    px or pos.x, py or pos.y, pz or pos.z,
    0, 0, 0) + HOME_MARGIN
end

-- Tank fuel + estimated value of remaining fuel items (after a light top-up burn).
local function estimateFuelUnits()
  local level = turtle.getFuelLevel()
  if level == "unlimited" then return math.huge end
  consolidateFuelToSlot16()
  burnSomeFuel()
  level = turtle.getFuelLevel()
  if level == "unlimited" then return math.huge end
  local total = tonumber(level) or 0
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if selectedIsFuel() then
        local d = itemDetail(s)
        local name = d and tostring(d.name or ""):lower() or ""
        local per = 80
        if name:find("coal_block", 1, true) then per = 800
        elseif name:find("lava", 1, true) then per = 1000
        elseif name:find("blaze", 1, true) then per = 120
        elseif name:find("dried_kelp_block", 1, true) then per = 4000
        end
        total = total + turtle.getItemCount(s) * per
      end
    end
  end
  turtle.select(FUEL_SLOT)
  return total
end

-- "ok" = keep working; "depot" = go home now (enough to arrive); "stranded" = cannot reach depot.
local function fuelPlanNow()
  local fuel = estimateFuelUnits()
  local home = homeFuelCost()
  if fuel == math.huge then return "ok", fuel, home end
  if home <= HOME_MARGIN and (pos.x == 0 and pos.y == 0 and pos.z == 0) then
    if fuel >= MIN_FUEL then return "ok", fuel, home end
    return "depot", fuel, home
  end
  if fuel < home then return "stranded", fuel, home end
  if fuel < home + WORK_RESERVE then return "depot", fuel, home end
  return "ok", fuel, home
end

-- "continue" = enough to keep mining; "depot" = only enough to reach home; "sos" = stranded.
local function resumeFuelPlan()
  local plan, fuel, home = fuelPlanNow()
  if plan == "ok" then return "continue", fuel, home end
  if plan == "depot" then return "depot", fuel, home end
  return "sos", fuel, home
end

local function clearJobFile(opts)
  opts = opts or {}
  if fs.exists(JOB_FILE) then pcall(fs.delete, JOB_FILE) end
  activeJob = nil
  -- Tell site to drop its copy unless this was a normal finish (site keeps last snapshot).
  if not opts.keepSite and siteSendJob then siteSendJob(nil, true) end
end

-- Drop local dig memory so the next `mine` takes a fresh site claim.
local function clearLocalMineMemory(opts)
  opts = opts or {}
  clearJobFile({ keepSite = opts.keepSite == true })
  adminAssign = nil
  cfg.pendingAssign = nil
  rebandClaim = nil
  pendingReband = nil
  pendingResetGo = nil
  saveCfg()
  if activeJob then activeJob = nil end
  jobLabel = "idle"
end

local function jobSummary(j)
  if not j then return "(none)" end
  if j.type == "area" then
    if j.x0 ~= nil then
      return ("col X%d-%d Z%d-%d H=%d  step %d/%d  [%s]"):format(
        j.x0, j.x1 or j.x0, j.z0, j.z1 or j.z0, j.H or ((j.y1 or 0) - (j.y0 or 0) + 1),
        tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
    end
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
-- Site/band jobs keep y0..y1; H/stopY are forced to the band floor (never full site H).
local function normalizeAreaJob(j)
  if not j or j.type ~= "area" then return j end
  j.L = tonumber(j.L) or tonumber(j.D) or 0
  j.W = tonumber(j.W) or 0
  j.D = j.L
  if j.y0 ~= nil and j.y1 ~= nil then
    local y0 = math.floor(tonumber(j.y0) or 0)
    local y1 = math.floor(tonumber(j.y1) or 0)
    if y1 < y0 then y0, y1 = y1, y0 end
    j.y0, j.y1 = y0, y1
    j.stopY = y1 + 1
    j.H = y1 + 1
  else
    j.stopY = tonumber(j.stopY) or tonumber(j.H) or 0
    j.H = j.stopY
  end
  return j
end

local function assumeAtOrigin()
  pos.x, pos.y, pos.z = 0, 0, 0
  facing = 0
  turnTo(0)
end

local function goHome()
  jobLabel = "home"
  -- Up → over → down; homebound yields if another turtle is in the way.
  local ok, err = goToViaAir(0, 0, 0, { clear = 1, intent = "homebound" })
  setTravelIntent("dig")
  -- Resting pose into the mine — only forced here at origin.
  turnTo(0)
  return ok, err
end

-- Forward decl — filled after publishMine / siteReportProgress exist.
local checkIn

-- Inventory full and/or fuel budget: return while we can still reach depot.
-- If short of home cost, suck mid-path chests; else SOS admin for a refuel station.
local function manageInventory(resume)
  local full = inventoryFull()
  local plan, fuel, home = fuelPlanNow()

  if plan == "ok" and not full then
    return true
  end

  if plan == "stranded" then
    print(("Fuel~%s < home trip %d — trying mid-path fuel chest..."):format(
      tostring(fuel), home))
    suckFuelNearby()
    plan, fuel, home = fuelPlanNow()
  end

  if plan == "stranded" or needsFuelSos() then
    local sx = math.floor((tonumber(pos.x) or 0) / 2)
    local sy = -1
    local sz = math.floor((tonumber(pos.z) or 0) / 2)
    print(("Stranded: need refuel station (have~%s, home=%d). SOS admin."):format(
      tostring(fuel), home))
    if broadcastSos then
      broadcastSos(needsFuelSos() and "out_of_fuel" or "need_refuel_station", {
        homeCost = home,
        fuelEst = fuel,
        suggestX = sx, suggestY = sy, suggestZ = sz,
      })
    end
    suckFuelNearby()
    plan, fuel, home = fuelPlanNow()
    if plan == "stranded" or needsFuelSos() then
      return false, "fuel"
    end
  end

  -- Mid-chest may have topped us up enough to keep digging.
  if plan == "ok" and not full then
    return true
  end

  if full then
    print("Inventory full — returning to dump/refuel...")
  else
    print(("Fuel reserve low (have~%s, home needs %d) — returning to depot..."):format(
      tostring(fuel), home))
  end
  if activeJob then
    activeJob.status = "paused"
    saveJobFile(activeJob)
  end
  local rx, ry, rz = pos.x, pos.y, pos.z
  if not goHome() then
    suckFuelNearby()
    if (fuelPlanNow() == "stranded" or needsFuelSos()) and broadcastSos then
      broadcastSos("stranded_no_fuel", {
        homeCost = homeFuelCost(),
        fuelEst = estimateFuelUnits(),
        suggestX = math.floor((pos.x or 0) / 2),
        suggestY = -1,
        suggestZ = math.floor((pos.z or 0) / 2),
      })
    end
    return false, "home"
  end
  dumpToStorage()
  suckFuelFromLeft()
  suckFuelNearby()
  if needsFuelSos() and broadcastSos then
    broadcastSos("depot_empty_fuel")
    if needsFuelSos() then return false, "fuel" end
  end
  -- Check in at every depot so admin/site see progress + can deliver Y assigns.
  if checkIn then
    checkIn("depot", { status = "depot", resumeAt = { x = rx, y = ry, z = rz } })
  end
  if resume then
    print(("Resuming @ %d,%d,%d"):format(rx, ry, rz))
    -- Pick should already be on (dig path); air-hop back into the work pose.
    if not goToViaAir(rx, ry, rz, { clear = 1, intent = "outbound" }) then
      setTravelIntent("dig")
      return false, "resume"
    end
    setTravelIntent("dig")
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

-- Column claim: dig shafts only inside x0..x1 × z0..z1 (usually a 2×2).
local function columnClaimUnits(x0, x1, z0, z1)
  local units = {}
  x0 = math.floor(tonumber(x0) or 0)
  x1 = math.floor(tonumber(x1) or x0)
  z0 = math.floor(tonumber(z0) or 0)
  z1 = math.floor(tonumber(z1) or z0)
  if x1 < x0 then x0, x1 = x1, x0 end
  if z1 < z0 then z0, z1 = z1, z0 end
  for z = z0, z1 do
    if (z - z0) % 2 == 0 then
      for x = x0, x1 do units[#units + 1] = { x = x, z = z } end
    else
      for x = x1, x0, -1 do units[#units + 1] = { x = x, z = z } end
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

-- Absolute XZ cell rectangle, full Y band, 1 layer at a time.
-- skipY: optional set/list of quarry-Y layers to omit (site geo empty hints).
local function cellLayerUnits(x0, x1, z0, z1, y0, y1, skipY)
  local units = {}
  x0 = math.floor(tonumber(x0) or 0)
  x1 = math.floor(tonumber(x1) or x0)
  z0 = math.floor(tonumber(z0) or 0)
  z1 = math.floor(tonumber(z1) or z0)
  y0 = math.floor(tonumber(y0) or 0)
  y1 = math.floor(tonumber(y1) or y0)
  if x1 < x0 then x0, x1 = x1, x0 end
  if z1 < z0 then z0, z1 = z1, z0 end
  if y1 < y0 then y0, y1 = y1, y0 end
  local skip = {}
  if type(skipY) == "table" then
    for k, v in pairs(skipY) do
      if type(k) == "number" and v == true then skip[k] = true
      elseif type(v) == "number" then skip[math.floor(v)] = true
      end
    end
  end
  for y = y0, y1 do
    if not skip[y] then
      for z = z0, z1 do
        if ((z - z0) + (y - y0)) % 2 == 0 then
          for x = x0, x1 do units[#units + 1] = { x = x, y = y, z = z } end
        else
          for x = x1, x0, -1 do units[#units + 1] = { x = x, y = y, z = z } end
        end
      end
    end
  end
  return units
end

function site.gpsStubFields()
  -- Groundwork for later constellation correction. Disabled for now so digs
  -- don't stall waiting on gps.locate; site still receives gpsOk=false.
  -- When enabling: call titanLib.gpsFix while modem is equipped (travel/check-in).
  return { gpsX = nil, gpsY = nil, gpsZ = nil, gpsOk = false }
end

function site.tunnelUnits(L, W)
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

function site.stairUnits(W, steps, dir)
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
function site.rememberPeer(id)
  id = tonumber(id)
  if id and id ~= os.getComputerID() then
    knownPeers[id] = true
  end
end

-- Open every modem for rednet + CraftOS hop channel so nearby routers can relay.
function site.openModem()
  local any = false
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      -- Same hop channel routers / titan.relayLoop use (mesh repeat).
      pcall(peripheral.call, side, "open", rednet.CHANNEL_REPEAT)
      any = true
    end
  end
  return any
end

function site.rednetIsReady()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" and rednet.isOpen(side) then
      return true
    end
  end
  return false
end

-- Stagger fleet chatter so many bots don't hit the site in the same tick.
function site.netJitter(scale)
  scale = tonumber(scale) or 1
  local id = os.getComputerID() or 0
  local frac = ((id * 37 + (moves or 0) * 13) % 1000) / 1000
  sleep(frac * scale)
end

-- opts.light: unicast site + one PROTO broadcast (routine progress).
-- opts.full: multi-protocol flood (join / SOS / urgent).
function site.rednetPublish(msg, opts)
  if type(msg) ~= "table" then return false end
  if not site.openModem() and not site.rednetIsReady() then return false end
  opts = opts or {}
  local full = opts.full == true
  local light = opts.light == true or not full
  msg.from = msg.from or os.getComputerID()
  msg.turtleId = msg.turtleId or os.getComputerID()
  msg.name = msg.name or os.getComputerLabel()
  msg.t = os.epoch("utc")

  if siteId then
    site.rememberPeer(siteId)
    rednet.send(siteId, msg, PROTO_QUARRY)
  end
  rednet.broadcast(msg, PROTO_QUARRY)

  if full then
    rednet.broadcast(msg, PROTO_NET)
    rednet.broadcast(msg, PROTO_ROUTER)
    for id in pairs(knownPeers) do
      if id ~= siteId then
        rednet.send(id, msg, PROTO_QUARRY)
        rednet.send(id, msg, PROTO_NET)
      end
    end
  elseif light and not siteId then
    -- No site yet — keep a light mesh presence for admin tablets.
    rednet.broadcast(msg, PROTO_NET)
  end
  return true
end

-- CC can't inspect entities — classify via recent fleet poses on the cell ahead.
classifyEntityAhead = function()
  local ax, ay, az = cellAhead()
  if fleetTurtleInCell(ax, ay, az) then
    return "turtle"
  end
  if not site.rednetIsReady() then
    return "entity"
  end
  local ping = {
    type = "quarry_pose",
    turtleId = os.getComputerID(),
    name = os.getComputerLabel(),
    posX = pos.x, posY = pos.y, posZ = pos.z,
    facing = facing,
    status = travelIntent,
  }
  rednet.broadcast(ping, PROTO_QUARRY)
  local deadline = os.clock() + 0.45
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO_QUARRY, math.max(0.05, deadline - os.clock()))
    if id and type(msg) == "table" then
      noteFleetPose(id, msg)
      local tid = tonumber(msg.turtleId)
      if tid then noteFleetPose(tid, msg) end
    end
  end
  if fleetTurtleInCell(ax, ay, az) then
    return "turtle"
  end
  return "entity"
end

function site.rightDetail()
  return getEquipped(PICK_SIDE)
end

function site.rightHasPickaxe()
  local d = site.rightDetail()
  return d ~= nil and toolKind(d.name) == "pickaxe"
end

function site.rightHasModem()
  return sideLooksLikeModem(PICK_SIDE)
end

function site.findPickaxeInventorySlot()
  -- Prefer slot 15 (modem/pick swap parking), then any other slot.
  local order = { MODEM_SLOT }
  for s = 1, 16 do
    if s ~= MODEM_SLOT and s ~= FUEL_SLOT then order[#order + 1] = s end
  end
  local best, bestScore = nil, -1
  for _, s in ipairs(order) do
    if turtle.getItemCount(s) > 0 then
      local d = itemDetail(s)
      if d and toolKind(d.name) == "pickaxe" then
        local sc = scoreTool(d)
        if sc > bestScore then bestScore, best = sc, s end
      end
    end
  end
  return best
end

function site.parkModemInSlot15()
  -- After equipping pick, modem may sit in whatever slot we selected — move to 15.
  if isModemItem(itemDetail(MODEM_SLOT)) then return true end
  for s = 1, 16 do
    if s ~= FUEL_SLOT and isModemItem(itemDetail(s)) then
      if s == MODEM_SLOT then return true end
      if turtle.getItemCount(MODEM_SLOT) > 0 and not isModemItem(itemDetail(MODEM_SLOT)) then
        for e = 1, 14 do
          if turtle.getItemCount(e) == 0 then
            turtle.select(MODEM_SLOT)
            turtle.transferTo(e)
            break
          end
        end
      end
      turtle.select(s)
      if turtle.transferTo(MODEM_SLOT) or isModemItem(itemDetail(MODEM_SLOT)) then
        return true
      end
    end
  end
  return isModemItem(itemDetail(MODEM_SLOT))
end

-- Guarantee dig tool on RIGHT (slot 2) before mining. Detects modem-still-equipped.
function site.ensurePickReady(quiet)
  if site.rightHasPickaxe() then
    modemSwapSide = nil
    site.parkModemInSlot15()
    return true
  end

  -- Modem still on right after a check-in — swap it off for a pickaxe.
  if site.rightHasModem() then
    local pickSlot = site.findPickaxeInventorySlot()
    if pickSlot then
      turtle.select(pickSlot)
      if turtle.equipRight() and site.rightHasPickaxe() then
        site.parkModemInSlot15()
        modemSwapSide = nil
        return true
      end
    end
    -- Slot 15 empty or has pick: try equip from 15 anyway.
    if turtle.getItemCount(MODEM_SLOT) > 0 then
      turtle.select(MODEM_SLOT)
      if turtle.equipRight() and site.rightHasPickaxe() then
        site.parkModemInSlot15()
        modemSwapSide = nil
        return true
      end
    end
  end

  -- Right empty / wrong item: equip best pick from inventory onto right only.
  local pickSlot = site.findPickaxeInventorySlot()
  if pickSlot then
    turtle.select(pickSlot)
    if turtle.equipRight() and site.rightHasPickaxe() then
      site.parkModemInSlot15()
      modemSwapSide = nil
      return true
    end
  end

  if equipToolFromInventory(PICK_SIDE, true) and site.rightHasPickaxe() then
    site.parkModemInSlot15()
    modemSwapSide = nil
    return true
  end

  if not quiet then
    print("Need a pickaxe on RIGHT (slot 2) to dig. Modem may still be equipped.")
  end
  return false
end

-- Put wireless modem on RIGHT upgrade only (slot 2 / pickaxe). Never touch left.
function site.ensureModemForComms(quiet)
  -- Already talking and modem is on right — mark swap so we restore the pick.
  if site.rightHasModem() and site.openModem() then
    modemSwapSide = PICK_SIDE
    return true
  end
  -- Modem on another side (or already open): talk without touching right pick.
  if site.openModem() and not site.rightHasModem() and site.rightHasPickaxe() then
    return true
  end
  if not moveModemToSlot15() and not isModemItem(itemDetail(MODEM_SLOT)) then
    if not quiet then
      print("No wireless modem. Put one in slot " .. MODEM_SLOT .. " for site/admin.")
    end
    return false
  end
  local d = site.rightDetail()
  if d and not isModemItem(d) and toolKind(d.name) ~= "pickaxe" then
    if not quiet then
      print("Right upgrade (slot 2) must be the pickaxe — won't swap a loader/other.")
    end
    return false
  end
  -- Empty right or pickaxe: swap modem on.
  turtle.select(MODEM_SLOT)
  local ok = turtle.equipRight()
  if not ok then
    if not quiet then print("Could not equip modem on right (slot 2)") end
    return false
  end
  modemSwapSide = PICK_SIDE
  if not site.openModem() then
    if not quiet then print("Modem equipped but rednet failed to open.") end
    return false
  end
  return true
end

-- Always try to put the pickaxe back on RIGHT after comms (robust detection).
function site.restorePickAfterComms()
  local ok = site.ensurePickReady(true)
  modemSwapSide = nil
  return ok
end

function site.footprintFromJob(j)
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

function site.sitePayload(extra)
  local gps = site.gpsStubFields()
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
    posX = pos.x, posY = pos.y, posZ = pos.z,
    gpsX = gps.gpsX, gpsY = gps.gpsY, gpsZ = gps.gpsZ, gpsOk = gps.gpsOk,
    pattern = "cell",
  }
  if activeCell then
    msg.cellId = activeCell.cellId
    msg.x0, msg.x1 = activeCell.x0, activeCell.x1
    msg.z0, msg.z1 = activeCell.z0, activeCell.z1
    msg.y0, msg.y1 = activeCell.y0, activeCell.y1
  end
  local j = activeJob or loadJobFile()
  if j then
    msg.job = j
    msg.jobFile = JOB_FILE
    msg.idx = j.idx
    msg.total = j.total
    msg.y0 = j.y0 or msg.y0
    msg.y1 = j.y1 or msg.y1
    msg.x0 = j.x0 or msg.x0
    msg.x1 = j.x1 or msg.x1
    msg.z0 = j.z0 or msg.z0
    msg.z1 = j.z1 or msg.z1
    msg.cellId = j.cellId or msg.cellId
    msg.pattern = j.pattern or msg.pattern
    local W, L, H = site.footprintFromJob(j)
    if W then msg.W, msg.L, msg.H = W, L, H end
  elseif siteInfo then
    msg.y0 = siteInfo.y0 or msg.y0
    msg.y1 = siteInfo.y1 or msg.y1
    msg.x0 = siteInfo.x0 or msg.x0
    msg.x1 = siteInfo.x1 or msg.x1
    msg.z0 = siteInfo.z0 or msg.z0
    msg.z1 = siteInfo.z1 or msg.z1
    msg.cellId = siteInfo.cellId or msg.cellId
    msg.W = siteInfo.W
    msg.L = siteInfo.L
    msg.H = siteInfo.H
    msg.pattern = siteInfo.pattern or msg.pattern
  end
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      if k ~= "type" and k ~= "_siteType" then msg[k] = v end
    end
  end
  return msg
end

local applyingAssign = false

-- Force physical descent/ascent to target relative Y (+Y = down), one Y at a time.
function site.forceGoToY(ty)
  ty = math.floor(tonumber(ty) or 0)
  if ty < 0 then ty = 0 end
  while pos.y > ty do
    if not moveUp() then return false, "up" end
  end
  while pos.y < ty do
    local oy = pos.y
    if not moveDown() then return false, "blocked-down" end
    if pos.y ~= oy + 1 then
      print("WARN: down step was not exactly 1 — correcting")
      pos.y = oy + 1
    end
    if pos.y % 5 == 0 or pos.y == ty then
      print(("  … at Y=%d (target %d)"):format(pos.y, ty))
    end
  end
  return true
end

-- Path to the top of a Y band (0, y0, 0). Pickaxe must be equipped for digs.
function site.moveIntoBand(y0, y1, opts)
  opts = opts or {}
  y0 = math.floor(tonumber(y0) or 0)
  y1 = math.floor(tonumber(y1) or y0)
  if y1 < y0 then y0, y1 = y1, y0 end
  if digging and not opts.force then
    print(("Y band %d..%d saved — finish/stop current dig, then I'll move in."):format(y0, y1))
    return false
  end
  site.restorePickAfterComms()
  equipToolFromInventory(nil, true)
  if not ensureFuel() then
    print("Need fuel to move into Y band.")
    return false
  end

  -- If caller says we're starting from the depot/origin, reset pose so we
  -- actually walk down y0 layers (stale pos.y == y0 would skip the descent).
  if opts.fromOrigin then
    assumeAtOrigin()
  end

  local prev = activeJob
  activeJob = { y0 = y0, y1 = y1, stopY = y1 + 1, H = y1 + 1 }
  print(("Moving into Y band %d..%d (descend to Y=%d)..."):format(y0, y1, y0))

  -- Home column first (X/Z), then forced Y descent.
  local ok, err = true, nil
  if pos.x ~= 0 or pos.z ~= 0 then
    -- Move X/Z at current Y, then drop.
    local saveY = pos.y
    ok, err = goTo(0, saveY, 0)
  end
  if ok then
    ok, err = site.forceGoToY(y0)
  end
  if ok and (pos.x ~= 0 or pos.z ~= 0) then
    ok, err = goTo(0, y0, 0)
  end
  activeJob = prev
  -- At home column (0, y0, 0) — face into the mine before the dig starts.
  if atOriginXZ() then turnTo(0) end
  if not ok then
    print("Could not reach band Y=" .. y0 .. ": " .. tostring(err))
    return false
  end
  if pos.y ~= y0 then
    print(("Pose error: at Y=%d want Y=%d"):format(pos.y, y0))
    return false
  end
  print(("In position at Y=%d (band %d..%d)."):format(pos.y, y0, y1))
  return true
end

-- Apply admin-tablet Y band; ack back to the tablet (and broadcast).
function site.applyQuarryAssign(msg, fromId)
  if applyingAssign then return false end
  if type(msg) ~= "table" then return false end
  local tid = tonumber(msg.turtleId)
  if tid and tid ~= os.getComputerID() then return false end
  local y0 = tonumber(msg.y0)
  local y1 = tonumber(msg.y1)
  if y0 == nil or y1 == nil then return false end
  y0, y1 = math.floor(y0), math.floor(y1)
  if y1 < y0 then y0, y1 = y1, y0 end

  -- Same band and already sitting on it — just ack.
  local alreadyThere = adminAssign
      and tonumber(adminAssign.y0) == y0 and tonumber(adminAssign.y1) == y1
      and pos.y == y0 and pos.x == 0 and pos.z == 0

  adminAssign = {
    y0 = y0, y1 = y1,
    assignId = msg.assignId,
    from = fromId or msg.from,
    fromAdmin = true,
    W = tonumber(msg.W), L = tonumber(msg.L), H = tonumber(msg.H),
  }
  cfg.pendingAssign = adminAssign
  saveCfg()
  siteInfo = siteInfo or {}
  siteInfo.y0, siteInfo.y1 = y0, y1
  siteInfo.x0, siteInfo.x1, siteInfo.z0, siteInfo.z1 = nil, nil, nil, nil
  siteInfo.pattern = "layer"
  if adminAssign.W then siteInfo.W = adminAssign.W end
  if adminAssign.L then siteInfo.L = adminAssign.L end
  if adminAssign.H then siteInfo.H = adminAssign.H end

  local j = activeJob or loadJobFile()
  if j then
    local bandChanged = tonumber(j.y0) ~= y0 or tonumber(j.y1) ~= y1
    j.y0, j.y1 = y0, y1
    j.site = true
    j.H = y1 + 1
    j.stopY = y1 + 1
    if bandChanged and not digging then
      j.idx = 1
      local W = math.floor(tonumber(j.W) or tonumber(siteInfo.W) or 0)
      local L = math.floor(tonumber(j.L) or tonumber(j.D) or tonumber(siteInfo.L) or 0)
      if W > 0 and L > 0 then
        j.total = #boxBandUnits(W, L, y0, y1)
      end
    end
    if not digging then
      saveJobFile(j)
      if activeJob then activeJob = j end
    end
  end

  applyingAssign = true
  local moved = false
  if not digging and not alreadyThere then
    -- Idle check-ins are almost always from the depot. If pose already claims
    -- we're at y0 without having just moved, reset and force a real descent.
    local needOrigin = (pos.y == y0 and y0 > 0) or (pos.y < 1)
    moved = site.moveIntoBand(y0, y1, { fromOrigin = needOrigin })
  end

  local ack = {
    type = "quarry_assign_ack",
    ok = true,
    turtleId = os.getComputerID(),
    name = os.getComputerLabel(),
    y0 = y0, y1 = y1,
    assignId = msg.assignId,
    digging = digging == true,
    atBand = (pos.y == y0),
    posY = pos.y,
    status = digging and "mining" or (moved or alreadyThere) and "at_band" or "assigned",
  }
  site.rememberPeer(fromId)
  site.rememberPeer(msg.from)
  if fromId then rednet.send(fromId, ack, PROTO_QUARRY) end
  local adminId = tonumber(msg.from)
  if adminId and adminId ~= fromId then rednet.send(adminId, ack, PROTO_QUARRY) end
  site.rednetPublish(ack)
  print(("\n[admin] Y assign %d..%d — acked%s"):format(
    y0, y1,
    digging and " (move after current dig)" or (moved and " — moved in") or ""))
  applyingAssign = false
  return true
end

function site.pollAssignReplies(timeout)
  timeout = tonumber(timeout) or 0.75
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO_QUARRY, math.max(0.05, deadline - os.clock()))
    if id and type(msg) == "table" then
      site.rememberPeer(id)
      local t = tostring(msg.type or "")
      if t == "quarry_assign" then
        site.applyQuarryAssign(msg, id)
      elseif t == "quarry_welcome" then
        if not siteId then
          siteId = id
          siteInfo = msg
          maxTravel = tonumber(msg.maxTravel) or maxTravel
          cfg.siteId = id
          saveCfg()
        end
        site.rememberPeer(id)
      end
    end
  end
end

-- Broadcast mine data for admin. Also unicast to site board when joined.
-- Swaps slot-15 modem over RIGHT pickaxe only, then restores the pickaxe.
-- Offline mode: no site/admin traffic (solo dig).
function site.publishMine(extra)
  extra = extra or {}
  if isOfflineMode() then return false end
  local modemOk = site.ensureModemForComms(true)
  if not modemOk then
    modemOk = site.openModem()
  end
  if not modemOk or not site.rednetIsReady() then
    print("[rednet] check-in FAILED — modem not open")
    return false
  end

  local base = site.sitePayload(extra)
  if adminAssign then
    base.y0 = adminAssign.y0
    base.y1 = adminAssign.y1
  end
  base.posX, base.posY, base.posZ = pos.x, pos.y, pos.z
  base.checkIn = extra.checkIn or base.checkIn

  -- One light update: site unicast + single PROTO broadcast (avoids fleet storms).
  local bcast = {}
  for k, v in pairs(base) do bcast[k] = v end
  bcast.type = "quarry_turtle"
  local siteType = extra._siteType or "quarry_progress"
  if siteType ~= "quarry_turtle" then
    bcast.siteType = siteType
  end
  if not site.rednetPublish(bcast, { light = true }) then
    print("[rednet] broadcast FAILED")
    if digging then site.ensurePickReady(true) end
    return false
  end

  -- Typed message for the site board only (progress / job / leave / arrive).
  if siteId and siteType ~= "quarry_turtle" then
    local uni = {}
    for k, v in pairs(base) do uni[k] = v end
    uni.type = siteType
    rednet.send(siteId, uni, PROTO_QUARRY)
  end

  if extra.checkIn then
    print(("[rednet] sent %s → site#%s + quarry"):format(
      tostring(extra.checkIn), tostring(siteId or "-")))
  end

  -- Listen briefly for tablet Y assign + ack it (shorter while digging).
  local listen = tonumber(extra.listen) or (digging and 0.35 or 0.75)
  site.pollAssignReplies(listen)
  -- While mining, ALWAYS re-equip pick on right before the next dig step.
  if digging then
    if not site.restorePickAfterComms() then
      print("WARN: pickaxe not on right after check-in — retrying...")
      sleep(0.05)
      site.ensurePickReady(false)
    end
  end
  return true
end

function site.siteSend(msgType, extra)
  if not siteId then
    -- No board — still publish so admin tablet can see us.
    return site.publishMine(extra)
  end
  extra = extra or {}
  extra._siteType = msgType
  return site.publishMine(extra)
end

function site.siteReportProgress(extra)
  extra = extra or {}
  extra._siteType = "quarry_progress"
  return site.publishMine(extra)
end

-- Named check-in helper (depot / end of dig line / layer) — always over rednet.
checkIn = function(reason, extra)
  extra = extra or {}
  extra.checkIn = reason or "ping"
  extra._siteType = extra._siteType or "quarry_progress"
  extra.status = extra.status or (activeJob and activeJob.status) or "mining"
  if activeJob then extra.job = activeJob; extra.jobFile = JOB_FILE end
  print(("[check-in] %s @ %d,%d,%d (rednet)"):format(
    tostring(reason), pos.x, pos.y, pos.z))
  local ok = site.publishMine(extra)
  if not ok then
    print("[check-in] rednet send failed — will retry next line/depot")
  end
  -- Belt-and-suspenders: verify pick before returning to the dig line.
  if digging and not site.ensurePickReady(true) then
    print("Pickaxe missing after check-in — cannot dig until RIGHT has a pick.")
  end
  return ok
end

local sosActive = false

-- Fuel empty / can't reach depot: modem on, SOS admin until we can move again.
-- extra: homeCost, fuelEst, suggestX/Y/Z (mid-path refuel station hint).
broadcastSos = function(reason, extra)
  reason = reason or "out_of_fuel"
  extra = extra or {}
  sosActive = true
  if activeJob then
    activeJob.status = "sos"
    saveJobFile(activeJob)
  end
  local sx = tonumber(extra.suggestX) or math.floor((pos.x or 0) / 2)
  local sy = tonumber(extra.suggestY) or -1
  local sz = tonumber(extra.suggestZ) or math.floor((pos.z or 0) / 2)
  local homeCost = tonumber(extra.homeCost) or homeFuelCost()
  local fuelEst = tonumber(extra.fuelEst) or estimateFuelUnits()
  print("========== SOS: FUEL ==========")
  print(("Reason: %s"):format(reason))
  print(("Bot @ rel %d,%d,%d  fuel~%s  homeCost=%d"):format(
    pos.x, pos.y, pos.z, tostring(fuelEst), homeCost))
  if reason == "need_refuel_station" or reason == "stranded_no_fuel" then
    print(("Place a FUEL CHEST on the travel layer near bot or ~%d,%d,%d (rel)."):format(
      sx, sy, sz))
    print("Turtle sucks all sides + up/down. Also keep origin left-chest stocked.")
  else
    print("Put coal in slot 16, an adjacent chest, or the origin left chest.")
  end
  print("Computer stays online — broadcasting to admin + MAIN monitors.")
  while sosActive and not STOP do
    suckFuelNearby()
    local plan = fuelPlanNow()
    if plan ~= "stranded" and not needsFuelSos() then
      clearSos()
      print("Fuel restored — SOS cleared.")
      return true
    end
    site.ensureModemForComms(true)
    local msg = site.sitePayload({
      sos = true,
      urgent = true,
      reason = reason,
      status = "sos",
      checkIn = "sos",
      homeCost = homeCost,
      fuelEst = estimateFuelUnits(),
      suggestX = sx, suggestY = sy, suggestZ = sz,
    })
    msg.type = "quarry_sos"
    site.rednetPublish(msg, { full = true })
    print(("[SOS] %s @ %d,%d,%d  suggest refuel ~%d,%d,%d"):format(
      reason, pos.x, pos.y, pos.z, sx, sy, sz))
    local deadline = os.clock() + 2.5
    while os.clock() < deadline and sosActive and not STOP do
      suckFuelNearby()
      plan = fuelPlanNow()
      if plan ~= "stranded" and not needsFuelSos() then
        clearSos()
        print("Fuel restored — SOS cleared.")
        return true
      end
      sleep(0.35)
    end
  end
  return false
end

clearSos = function()
  if not sosActive then return end
  sosActive = false
  site.ensureModemForComms(true)
  local msg = site.sitePayload({ sos = false, status = "idle", checkIn = "sos_clear" })
  msg.type = "quarry_sos_clear"
  site.rednetPublish(msg, { full = true })
  if digging then site.restorePickAfterComms() end
end

-- Push offline_miner_job.cfg to site (if any) and broadcast for admin.
siteSendJob = function(j, clearing)
  if clearing or not j then
    return site.publishMine({
      _siteType = "quarry_job",
      clearJob = true, job = false, status = "idle",
    })
  end
  return site.publishMine({
    _siteType = "quarry_job",
    job = j, jobFile = JOB_FILE, status = j.status or "active",
  })
end

function site.joinSite(timeout, quiet)
  timeout = tonumber(timeout) or 6
  quiet = quiet == true
  if isOfflineMode() then
    if not quiet then
      print("Offline mode — site/admin disabled. Use `mode online` first.")
    end
    return false
  end
  if not site.ensureModemForComms(quiet) then
    if not quiet then
      print("No modem in slot " .. MODEM_SLOT .. " — solo dig only (no site/admin link).")
    end
    return false
  end
  site.netJitter(1.2)
  local joinMsg = site.sitePayload({})
  joinMsg.type = "quarry_join"
  -- Ask site to include our stored job if we have none locally.
  joinMsg.wantJob = loadJobFile() == nil
  site.rednetPublish(joinMsg, { full = true })
  local deadline = os.clock() + timeout
  local found = false
  local welcomed = nil
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO_QUARRY, math.max(0.05, deadline - os.clock()))
    if id and type(msg) == "table" then
      local mt = tostring(msg.type or "")
      if mt == "quarry_welcome" then
        siteId = id
        site.rememberPeer(id)
        siteInfo = msg
        maxTravel = tonumber(msg.maxTravel) or maxTravel
        cfg.siteId = id
        saveCfg()
        if not quiet then
          print(("Joined site #%d  %dx%d × %dY  mode=%s  claim=%s  maxTravel=%s"):format(
            id,
            tonumber(msg.W) or 0, tonumber(msg.L) or 0, tonumber(msg.H) or 0,
            tostring(msg.pattern or "column"),
            tostring(msg.fraction or "?"),
            tostring(msg.maxTravel or "?")))
        end
        found = true
        welcomed = msg
        handleQuarryNetMsg(id, msg)
        break
      elseif mt == "quarry_reband" or mt == "quarry_reset_go" then
        siteId = siteId or id
        site.rememberPeer(id)
        handleQuarryNetMsg(id, msg)
        found = true
      end
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
  local base = site.sitePayload({ _siteType = found and "quarry_join" or "quarry_progress" })
  local bcast = {}
  for k, v in pairs(base) do bcast[k] = v end
  bcast.type = "quarry_turtle"
  rednet.broadcast(bcast, PROTO_QUARRY)
  rednet.broadcast(bcast, "titan_net")
  if digging then site.restorePickAfterComms() end
  return found
end

-- Pull offline_miner_job.cfg from the site board.
-- force=true: always ask the board (for reboot sync), even if a local job exists.
-- When force, returns the site job table without overwriting local (caller merges).
fetchJobFromSite = function(timeout, quiet, force)
  timeout = tonumber(timeout) or 5
  quiet = quiet == true
  force = force == true
  local localJob = loadJobFile()
  if localJob and not force then return localJob end
  if not site.ensureModemForComms(quiet) then return force and nil or localJob end
  if not siteId then site.joinSite(math.min(timeout, 4), true) end
  if not siteId then
    if not quiet then print("No site board to fetch a job from.") end
    if digging then site.restorePickAfterComms() end
    return force and nil or localJob
  end
  -- Welcome may already have delivered a job during joinSite.
  if not force then
    localJob = loadJobFile()
    if localJob then
      if digging then site.restorePickAfterComms() end
      return localJob
    end
  end
  local req = site.sitePayload({})
  req.type = "quarry_job_req"
  req.wantJob = true
  rednet.send(siteId, req, PROTO_QUARRY)
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO_QUARRY, math.max(0.05, deadline - os.clock()))
    if id == siteId and type(msg) == "table" and msg.type == "quarry_job_reply" then
      if digging then site.restorePickAfterComms() end
      if msg.ok and type(msg.job) == "table" then
        if msg.maxTravel then maxTravel = tonumber(msg.maxTravel) or maxTravel end
        if msg.y0 ~= nil then siteInfo = siteInfo or {}; siteInfo.y0 = msg.y0; siteInfo.y1 = msg.y1 end
        if msg.x0 ~= nil then
          siteInfo = siteInfo or {}
          siteInfo.x0, siteInfo.x1 = msg.x0, msg.x1
          siteInfo.z0, siteInfo.z1 = msg.z0, msg.z1
        end
        if force then return msg.job end
        return adoptJob(msg.job, "site board")
      end
      if not quiet and not force then print("Site board has no job stored for this turtle.") end
      return nil
    end
  end
  if digging then site.restorePickAfterComms() end
  if not quiet and not force then print("Timed out waiting for job from site board.") end
  return nil
end

function site.claimCell(nextCell)
  if not siteId then
    if not site.joinSite() then return nil end
  end
  if not site.ensureModemForComms() then return nil end
  site.netJitter(1.5)
  local req = site.sitePayload({})
  req.type = "quarry_cell_req"
  if nextCell then
    req.nextCell = true
    req.forceNew = true
  end

  local claim = nil
  for attempt = 1, 3 do
    rednet.send(siteId, req, PROTO_QUARRY)
    local deadline = os.clock() + (4 + attempt)
    while os.clock() < deadline do
      local id, msg = rednet.receive(PROTO_QUARRY, math.max(0.05, deadline - os.clock()))
      if id == siteId and type(msg) == "table"
          and (msg.type == "quarry_cell" or msg.type == "quarry_claim") then
        if not msg.ok then
          print("Cell claim failed: " .. tostring(msg.err or "unknown"))
          if digging then site.restorePickAfterComms() end
          return nil
        end
        if msg.x0 == nil or msg.z0 == nil then
          print("Bad cell (missing XZ) — update site board.")
          if digging then site.restorePickAfterComms() end
          return nil
        end
        maxTravel = tonumber(msg.maxTravel) or maxTravel
        siteInfo = msg
        print(("Claimed cell #%s  X%d-%d Z%d-%d  Y%d..%d%s"):format(
          tostring(msg.cellId or "?"),
          msg.x0, msg.x1 or msg.x0, msg.z0, msg.z1 or msg.z0,
          msg.y0 or 0, msg.y1 or 0,
          msg.resume and " (resume)" or ""))
        claim = msg
        break
      end
    end
    if claim then break end
    print(("Cell claim timeout (try %d/3) — backing off..."):format(attempt))
    site.netJitter(1)
    sleep(0.4 * attempt)
  end
  if digging then site.restorePickAfterComms() end
  if not claim then print("Cell claim timed out.") end
  return claim
end

-- Back-compat alias
function site.claimBand(nextBand)
  return site.claimCell(nextBand)
end

function site.printSiteInfo()
  if not siteId and cfg.siteId then siteId = cfg.siteId end
  print(("siteId=%s  bpc=%.1f  moves=%d coal=%d  maxTravel=%s"):format(
    tostring(siteId or "(none — admin via broadcast)"),
    currentBpc(), moves, coalBurned, tostring(maxTravel or "-")))
  local j = activeJob or loadJobFile()
  local W, L, H = site.footprintFromJob(j)
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

-- Listen for site/admin even while digging (reband must interrupt).
handleQuarryNetMsg = function(id, msg)
  if type(msg) ~= "table" then return end
  noteFleetPose(id, msg)
  local tid = tonumber(msg.turtleId)
  if tid then noteFleetPose(tid, msg) end
  local t = tostring(msg.type or "")
  if t == "quarry_pose" then
    -- Answer pose pings so a blocked bot can tell turtle vs mob/player.
    if not msg.reply and site.rednetIsReady() then
      rednet.send(id, {
        type = "quarry_pose",
        reply = true,
        turtleId = os.getComputerID(),
        name = os.getComputerLabel(),
        posX = pos.x, posY = pos.y, posZ = pos.z,
        facing = facing,
        status = travelIntent,
      }, PROTO_QUARRY)
    end
    return
  elseif t == "quarry_reband" then
    local ep = tonumber(msg.epoch) or 0
    -- Ignore duplicate same-epoch spam while already homing / waiting for turn.
    if rebandPhase and ep > 0 and ep <= (tonumber(rebandEpoch) or 0) then
      return
    end
    if ep > 0 and ep < (tonumber(rebandEpoch) or 0) then
      return  -- stale
    end
    pendingReband = msg
    rebandEpoch = ep > 0 and ep or rebandEpoch
    STOP = true
    print(("\n[reband] epoch %d — return home"):format(rebandEpoch))
  elseif t == "quarry_reset_go" then
    local ep = tonumber(msg.epoch)
    if not ep or ep == rebandEpoch
        or (pendingReband and ep == tonumber(pendingReband.epoch)) then
      pendingResetGo = msg
      rebandEpoch = ep or rebandEpoch
      print(("\n[reband] reset turn (epoch %d)"):format(rebandEpoch))
    end
  elseif t == "quarry_assign" then
    if not digging then site.applyQuarryAssign(msg, id) end
  elseif t == "quarry_turtle_req" or t == "quarry_status_req" then
    if not digging then site.publishMine() end
  elseif t == "quarry_welcome" then
    siteId = id
    siteInfo = msg
    maxTravel = tonumber(msg.maxTravel) or maxTravel
    cfg.siteId = id
    if msg.pattern then cfg.pattern = normalizePattern(msg.pattern) or cfg.pattern end
    saveCfg()
    -- Only start a reband from welcome if we are idle (not already in one).
    local ep = tonumber(msg.rebandEpoch) or 0
    if msg.rebandActive and not rebandPhase and (msg.y0 ~= nil or msg.x0 ~= nil) then
      if ep > (tonumber(rebandEpoch) or 0) or (ep == 0 and not pendingReband) then
        pendingReband = {
          type = "quarry_reband",
          epoch = ep > 0 and ep or ((tonumber(rebandEpoch) or 0) + 1),
          y0 = msg.y0, y1 = msg.y1,
          x0 = msg.x0, x1 = msg.x1, z0 = msg.z0, z1 = msg.z1,
          continueIdx = msg.continueIdx or 1,
          W = msg.W, L = msg.L, H = msg.H,
          pattern = msg.pattern,
          parkOffset = 0,
          clearOrigin = { down = 1, right = 1 },
          ok = true,
        }
        STOP = true
      end
    end
  elseif t == "quarry_fleet_clear" then
    print("\n[site] fleet clear — forgetting local job + assign ("
      .. tostring(msg.reason or "?") .. ")")
    STOP = true
    digging = false
    activeCell = nil
    clearLocalMineMemory({ keepSite = true })
    cfg.pattern = "cell"
    siteInfo = siteInfo or {}
    siteInfo.pattern = "cell"
    saveCfg()
  elseif t == "quarry_return_home" then
    pendingReturnHome = tostring(msg.reason or "site")
    STOP = true
    print("\n[site] return home — " .. pendingReturnHome)
  elseif t == "quarry_cell" then
    if msg.ok ~= false and msg.x0 ~= nil then
      siteInfo = msg
      activeCell = {
        cellId = msg.cellId,
        x0 = msg.x0, x1 = msg.x1, z0 = msg.z0, z1 = msg.z1,
        y0 = msg.y0 or 0, y1 = msg.y1 or 0,
        W = msg.W, L = msg.L, H = msg.H,
      }
    end
  end
end

function site.mineNetLoop()
  local last = 0
  while true do
    if not digging then site.ensureModemForComms(true) end
    local id, msg = rednet.receive(PROTO_QUARRY, digging and 0.4 or 2)
    if id and type(msg) == "table" then
      site.rememberPeer(id)
      handleQuarryNetMsg(id, msg)
    end
    if not digging and (os.clock() - last) >= 12 then
      if activeJob or loadJobFile() then site.publishMine() end
      last = os.clock()
    end
  end
end

--------------------------------------------------------------------------------
-- Jobs
--------------------------------------------------------------------------------
function site.finishJob(ok, err)
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
      print("Reboot or `continue` resumes (depot-first if fuel is low).")
      print("(Or `clearjob` to forget this dig.)")
    end
  end
  digging = false
  if ok then
    site.publishMine({
      _siteType = "quarry_done",
      status = "done", finished = true, y0 = y0, y1 = y1,
      job = lastJob, jobFile = JOB_FILE,
    })
  else
    site.publishMine({
      _siteType = "quarry_progress",
      status = "paused", job = activeJob or lastJob, jobFile = JOB_FILE,
    })
  end
  site.restorePickAfterComms()
  -- Only walk home when we still have fuel; otherwise SOS stays in place.
  if not needsFuelSos() then
    goHome()
    dumpToStorage()
    suckFuelFromLeft()
    -- Refresh saved pose to depot so reboot doesn't think we're still in the hole.
    if activeJob then
      saveJobFile(activeJob)
    elseif lastJob and not ok then
      lastJob.posX, lastJob.posY, lastJob.posZ = 0, 0, 0
      lastJob.facing = 0
      lastJob.status = "paused"
      local f = fs.open(JOB_FILE, "w")
      if f then f.write(textutils.serialize(lastJob)); f.close() end
    end
  elseif broadcastSos then
    broadcastSos("paused_no_fuel")
  end
  jobLabel = "idle"
  if ok then
    print(("Done. dug=%d skipped=%d bpc=%.1f fuel=%s"):format(
      dug, skipped, currentBpc(), tostring(turtle.getFuelLevel())))
  end
end

function site.runBoxJob(j)
  if j.type == "area" then normalizeAreaJob(j) end
  local W, H, D = j.W, j.H, j.D
  -- Quarry jobs are ALWAYS true 1-Y-layer passes (never column / never 2-high).
  j.pattern = "layer"

  -- Site / claimed bands MUST dig only y0..y1. Never fall back to full H —
  -- a missing band + leftover stopY used to send turtles past their claim.
  local units
  if j.site == true and (j.y0 == nil or j.y1 == nil) then
    print("Site job missing Y claim (y0/y1) — aborting (will not dig full height).")
    digging = false
    return
  end
  if j.y0 ~= nil and j.y1 ~= nil then
    units = boxBandUnits(W, D, j.y0, j.y1)
    H = j.y1 - j.y0 + 1
  else
    units = boxLayerUnits(W, H, D)
  end
  j.total = #units
  j.idx = math.max(1, tonumber(j.idx) or 1)
  if j.idx > #units + 1 then j.idx = 1 end
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
  local lastZ = nil
  local layerCount = (j.y0 ~= nil and j.y1 ~= nil) and (j.y1 - j.y0 + 1) or H
  local floor = digFloorY(j)
  for i = j.idx, #units do
    if STOP then site.finishJob(false, "stop"); return end
    local u = units[i]
    local nextU = units[i + 1]
    if floor ~= nil and u.y > floor then
      print(("Abort: work unit Y=%d past claim floor Y=%d"):format(u.y, floor))
      site.finishJob(false, "past-band")
      return
    end
    j.idx = i
    saveJobFile(j)
    if not manageInventory(true) then site.finishJob(false, "inventory/fuel"); return end

    -- Drop exactly one Y when the work-list advances to the next layer.
    -- Stay in place (no trip back to 0,0) — just dig down into the next layer.
    if lastY ~= -999 and u.y > lastY then
      while pos.y < u.y do
        if floor ~= nil and pos.y >= floor then break end
        if not moveDown() then site.finishJob(false, "layer drop"); return end
      end
      print(("  layer Y=%d  (%d layers in band)"):format(u.y, layerCount))
    elseif lastY == -999 then
      print(("  layer Y=%d  (%d layers in band)"):format(u.y, layerCount))
    end
    lastY = u.y
    lastZ = u.z

    -- Never path/dig with the modem still equipped on slot 2.
    if not site.ensurePickReady(true) then
      site.finishJob(false, "no-pickaxe")
      return
    end

    -- One cell at a time along the dig line — keep facing travel dir (no spin).
    if not goTo(u.x, u.y, u.z) then site.finishJob(false, "path"); return end
    if pos.x ~= u.x or pos.y ~= u.y or pos.z ~= u.z then
      print(("Pose mismatch at unit %d: at %d,%d,%d want %d,%d,%d"):format(
        i, pos.x, pos.y, pos.z, u.x, u.y, u.z))
      site.finishJob(false, "pose")
      return
    end
    excavateHere()

    j.idx = i + 1
    saveJobFile(j)

    -- Check-in only at layer changes (not every row — modem swap kills speed).
    if nextU and nextU.y ~= u.y then
      checkIn("layer", { status = "mining", job = j, jobFile = JOB_FILE })
      if not site.ensurePickReady(true) then
        site.finishJob(false, "no-pickaxe")
        return
      end
    end
  end
  site.finishJob(true)
end

function site.runTunnelJob(j)
  -- Player-tall corridor: dig path + clear the block above (2 high).
  local L, W = j.L, j.W or 1
  j.H = 2
  local units = site.tunnelUnits(L, W)
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
    if STOP then site.finishJob(false, "stop"); return end
    local u = units[i]
    j.idx = i
    saveJobFile(j)
    if not manageInventory(true) then site.finishJob(false, "inventory/fuel"); return end
    if not goTo(u.x, 0, u.z) then site.finishJob(false, "path"); return end
    clearPlayerHeadroom()
    j.idx = i + 1
    saveJobFile(j)
  end
  site.finishJob(true)
end

function site.runStairJob(j)
  local W, steps, dir = j.W, j.steps, j.dir
  local units = site.stairUnits(W, steps, dir)
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
    if STOP then site.finishJob(false, "stop"); return end
    local u = units[i]
    j.idx = i
    saveJobFile(j)
    if not manageInventory(true) then site.finishJob(false, "inventory/fuel"); return end
    if not goTo(u.x, u.y, u.z) then site.finishJob(false, "path"); return end
    -- Player-tall tread: clear above + the step below.
    clearPlayerHeadroom()
    digDir("down")
    -- After last cell of a step, step forward/up/down toward next step
    local nextU = units[i + 1]
    if nextU and nextU.step ~= u.step then
      if not goTo(0, u.y, u.z) then site.finishJob(false, "stair edge"); return end
      turnTo(0)
      if not moveForward() then site.finishJob(false, "forward"); return end
      clearPlayerHeadroom()
      if dir == "down" then
        if not moveDown() then site.finishJob(false, "down"); return end
      else
        if not moveUp() then site.finishJob(false, "up"); return end
      end
    end
    j.idx = i + 1
    saveJobFile(j)
  end
  site.finishJob(true)
end

-- fromOrigin: turtle is at depot/origin. inPlace: pose already restored after reboot.
function site.runSavedJob(j, fromOrigin, inPlace)
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
  site.restorePickAfterComms()
  equipToolFromInventory(nil, true)

  local bandY0 = (j.y0 ~= nil) and math.floor(tonumber(j.y0) or 0) or nil
  local bandY1 = (j.y1 ~= nil) and math.floor(tonumber(j.y1) or 0) or bandY0
  if inPlace then
    activeJob = j
    print(("In-place resume @ %d,%d,%d step %s/%s"):format(
      pos.x, pos.y, pos.z, tostring(j.idx), tostring(j.total)))
  elseif bandY0 ~= nil then
    -- Y-band jobs: always physically enter the band before digging.
    if fromOrigin then
      print("Continue: at origin — descending to band.")
      assumeAtOrigin()
      suckFuelFromLeft()
    elseif pos.y < 1 then
      suckFuelFromLeft()
    end
    activeJob = j
    if pos.x == 0 and pos.z == 0 and pos.y == bandY0 then
      print(("Already at band Y=%d — starting dig."):format(bandY0))
    elseif not site.moveIntoBand(bandY0, bandY1, {
      force = true,
      fromOrigin = fromOrigin or (pos.y < 1),
    }) then
      print("Could not reach band Y=" .. bandY0)
      activeJob = nil
      return
    end
  elseif fromOrigin then
    print("Continue: assuming turtle is at origin 0,0,0 facing into the mine.")
    assumeAtOrigin()
    suckFuelFromLeft()
  else
    if not goHome() then print("Could not reach origin."); return end
  end

  -- Soft-join site if present; publish footprint, then dig with pickaxe equipped.
  if not siteId then site.joinSite(2, true) end
  site.publishMine({ _siteType = "quarry_job", job = j, status = "active" })
  site.restorePickAfterComms()
  equipToolFromInventory(nil, true)
  digging = true
  if j.type == "box" or j.type == "area" then
    site.runBoxJob(j)
  elseif j.type == "tunnel" then
    site.runTunnelJob(j)
  elseif j.type == "stair" then
    site.runStairJob(j)
  else
    print("Unknown job type: " .. tostring(j.type))
  end
  digging = false
end

function site.digBox(W, H, D, opts)
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
  site.runSavedJob(j, false)
end

-- Area: width × length footprint, dig stopY one-high layers down from origin.
-- Example: area 16x32 40   → 16 right, 32 forward, 40 layers of 1 Y each
function site.digArea(W, L, stopY, opts)
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
  site.runSavedJob(j, false)
end

-- Tunnel is always player-tall (2 high). Usage: tunnel <L> [W]
function site.digTunnel(L, W)
  L = math.floor(tonumber(L) or 0)
  W = math.floor(tonumber(W) or 1)
  if L < 1 or W < 1 then
    print("Usage: tunnel <L> [W]   (length forward, optional width; player height 2)")
    return
  end
  dug, skipped = 0, 0
  local units = site.tunnelUnits(L, W)
  local j = {
    type = "tunnel", L = L, H = 2, W = W,
    idx = 1, total = #units, status = "active", dug = 0, skipped = 0,
  }
  site.runSavedJob(j, false)
end

function site.digStair(W, steps, dir)
  W, steps = math.floor(W), math.floor(steps)
  dir = tostring(dir or "down"):lower()
  if (dir ~= "up" and dir ~= "down") or W < 1 or steps < 1 then
    print("Usage: stair <W>x<steps> <up|down>")
    return
  end
  dug, skipped = 0, 0
  local units = site.stairUnits(W, steps, dir)
  local j = {
    type = "stair", W = W, steps = steps, dir = dir,
    idx = 1, total = #units, status = "active", dug = 0, skipped = 0,
  }
  site.runSavedJob(j, false)
end

--------------------------------------------------------------------------------
-- Online fleet reband / origin reset
--------------------------------------------------------------------------------
function site.waitForModemOnline(quiet)
  if isOfflineMode() then return true end
  if site.ensureModemForComms(true) then return true end
  if not quiet then
    print("ONLINE — waiting for a wireless modem in inventory (slot " .. MODEM_SLOT .. ")...")
  end
  while not STOP do
    if moveModemToSlot15() or site.parkModemInSlot15() or findModemInInventory() then
      if site.ensureModemForComms(true) then
        print("Modem ready in slot " .. MODEM_SLOT .. ".")
        return true
      end
    end
    sleep(2)
  end
  return false
end

-- Park clear of origin: down (+Y) then right (+X), repeated by parkOffset.
function site.clearOriginCorridor(parkOffset)
  parkOffset = math.max(0, math.floor(tonumber(parkOffset) or 0))
  if parkOffset < 1 then return true end
  print(("Clearing origin — park down/right ×%d"):format(parkOffset))
  for _ = 1, parkOffset do
    if not moveDown() then
      -- try right anyway if down blocked
    end
    faceRight()
    turnTo(1)
    if not moveForward() then
      sleep(0.3)
      tryStepForward(true)
    end
  end
  return true
end

function site.claimFromRebandMsg(msg)
  if type(msg) ~= "table" then return nil end
  if msg.ok == false and msg.x0 == nil and msg.y0 == nil then return nil end
  local cidx = math.max(1, math.floor(tonumber(msg.continueIdx) or 1))
  if msg.x0 ~= nil then
    return {
      ok = true,
      pattern = "column",
      x0 = msg.x0, x1 = msg.x1, z0 = msg.z0, z1 = msg.z1,
      y0 = msg.y0 or 0, y1 = msg.y1 or 0,
      W = msg.W, L = msg.L, H = msg.H,
      continueIdx = cidx,
      resume = cidx > 1,
      fromReband = true,
    }
  end
  if msg.y0 ~= nil and msg.y1 ~= nil then
    return {
      ok = true,
      pattern = "layer",
      y0 = msg.y0, y1 = msg.y1,
      W = msg.W, L = msg.L, H = msg.H,
      continueIdx = cidx,
      resume = cidx > 1,
      fromReband = true,
    }
  end
  return nil
end

function site.sendRebandHome(epoch, park)
  site.ensureModemForComms(true)
  local homeMsg = site.sitePayload({
    _siteType = "quarry_home",
    status = "homing",
    epoch = epoch,
    parkOffset = park or 0,
    posX = pos.x, posY = pos.y, posZ = pos.z,
  })
  homeMsg.type = "quarry_home"
  if siteId then rednet.send(siteId, homeMsg, PROTO_QUARRY) end
  rednet.broadcast(homeMsg, PROTO_QUARRY)
  rednet.broadcast(homeMsg, PROTO_NET)
end

-- Return home, wait for reset turn, depot keep-list, adopt claim+continueIdx.
-- Returns claim table or nil.
function site.processRebandCycle()
  local rb = pendingReband
  if not rb then return nil end
  pendingReband = nil
  local epoch = tonumber(rb.epoch) or rebandEpoch
  rebandEpoch = epoch
  rebandClaim = site.claimFromRebandMsg(rb)
  rebandPhase = "homing"

  digging = false
  STOP = false
  if activeJob then
    activeJob.status = "paused"
    saveJobFile(activeJob)
  end

  local park = math.max(0, math.floor(tonumber(rb.parkOffset) or 0))

  -- Dig home with pickaxe; skip pathing when already at origin.
  site.restorePickAfterComms()
  equipToolFromInventory(nil, true)
  if pos.x == 0 and pos.y == 0 and pos.z == 0 then
    print(("REBAND epoch %d — already at origin"):format(epoch))
    turnTo(0)
  else
    print(("REBAND epoch %d — heading to origin"):format(epoch))
    if not goHome() then
      print("Could not reach origin for reband — assuming origin pose.")
      assumeAtOrigin()
    end
  end

  if park > 0 then
    site.clearOriginCorridor(park)
  end

  rebandPhase = "waiting_reset"
  site.sendRebandHome(epoch, park)
  print(("REBAND epoch %d — home, waiting for reset turn..."):format(epoch))

  -- Wait for our reset turn; re-ping site periodically (in case home was missed).
  local deadline = os.clock() + 600
  local lastPing = 0
  while os.clock() < deadline do
    if pendingReband and tonumber(pendingReband.epoch) and tonumber(pendingReband.epoch) > epoch then
      rebandPhase = nil
      return site.processRebandCycle()
    end
    -- Drop same-epoch spam so digSiteMine doesn't restart this cycle.
    if pendingReband and tonumber(pendingReband.epoch) == epoch then
      pendingReband = nil
    end

    local go = pendingResetGo
    if go and (not tonumber(go.epoch) or tonumber(go.epoch) == epoch) then
      pendingResetGo = nil
      rebandPhase = "resetting"
      print("Reset turn — dump / adopt claim")

      if park > 0 then
        site.restorePickAfterComms()
        goHome()
      end
      if turtle.detect() then
        site.clearOriginCorridor(1)
        goHome()
      end

      dumpToStorage()
      suckFuelFromLeft()
      equipToolFromInventory(nil, true)
      site.ensurePickReady(true)

      local claim = site.claimFromRebandMsg(go) or rebandClaim
      rebandClaim = claim
      if claim then
        adminAssign = {
          y0 = claim.y0, y1 = claim.y1,
          x0 = claim.x0, x1 = claim.x1, z0 = claim.z0, z1 = claim.z1,
          W = claim.W, L = claim.L, pattern = claim.pattern,
          continueIdx = claim.continueIdx,
        }
        cfg.pendingAssign = adminAssign
        saveCfg()
        siteInfo = siteInfo or {}
        for k, v in pairs(claim) do siteInfo[k] = v end
      end

      site.ensureModemForComms(true)
      local doneMsg = site.sitePayload({
        _siteType = "quarry_reset_done",
        status = "mining",
        epoch = epoch,
        continueIdx = claim and claim.continueIdx or 1,
        y0 = claim and claim.y0, y1 = claim and claim.y1,
        x0 = claim and claim.x0, x1 = claim and claim.x1,
        z0 = claim and claim.z0, z1 = claim and claim.z1,
      })
      doneMsg.type = "quarry_reset_done"
      if siteId then rednet.send(siteId, doneMsg, PROTO_QUARRY) end
      rednet.broadcast(doneMsg, PROTO_QUARRY)
      site.restorePickAfterComms()
      pendingReband = nil
      rebandPhase = nil
      return claim
    end

    if (os.clock() - lastPing) >= 5 then
      site.sendRebandHome(epoch, park)
      lastPing = os.clock()
    end
    sleep(0.25)
  end
  print("Timed out waiting for reset turn.")
  pendingReband = nil
  rebandPhase = nil
  return rebandClaim
end

-- Dig one claimed Y band. Returns "done" | "paused" | "stop" | "bad".
-- fromContinue = turtle was placed back at origin (pose reset); job idx may still resume.
function site.runColumnClaim(claim, fromOrigin, existingJob)
  local x0 = math.floor(tonumber(claim.x0) or 0)
  local x1 = math.floor(tonumber(claim.x1) or x0)
  local z0 = math.floor(tonumber(claim.z0) or 0)
  local z1 = math.floor(tonumber(claim.z1) or z0)
  local y0 = math.floor(tonumber(claim.y0) or 0)
  local y1 = math.floor(tonumber(claim.y1) or 0)
  local W = math.floor(tonumber(claim.W) or (siteInfo and siteInfo.W) or (x1 + 1))
  local L = math.floor(tonumber(claim.L) or (siteInfo and siteInfo.L) or (z1 + 1))
  local H = math.max(1, y1 - y0 + 1)
  if x1 < x0 then x0, x1 = x1, x0 end
  if z1 < z0 then z0, z1 = z1, z0 end
  if y1 < y0 then y0, y1 = y1, y0 end

  local j = existingJob
  local units = columnClaimUnits(x0, x1, z0, z1)
  if not j then
    dug, skipped = 0, 0
    j = {
      type = "area", W = W, L = L, D = L, H = H, stopY = y1 + 1,
      pattern = "column", site = true,
      x0 = x0, x1 = x1, z0 = z0, z1 = z1,
      y0 = y0, y1 = y1,
      idx = 1, total = #units, status = "active", dug = 0, skipped = 0,
    }
  else
    j.site = true
    j.pattern = "column"
    j.x0, j.x1, j.z0, j.z1 = x0, x1, z0, z1
    j.y0, j.y1 = y0, y1
    j.W, j.L, j.D, j.H = W, L, L, H
    j.stopY = y1 + 1
    j.total = #units
    j.idx = math.max(1, math.min(tonumber(j.idx) or 1, #units + 1))
  end
  -- Site continue point: skip already-mined shafts in this claim.
  local cidx = math.floor(tonumber(claim.continueIdx) or 0)
  if cidx >= 1 then
    j.idx = math.max(1, math.min(cidx, #units + 1))
  end

  adminAssign = {
    y0 = y0, y1 = y1, x0 = x0, x1 = x1, z0 = z0, z1 = z1,
    W = W, L = L, pattern = "column",
    continueIdx = j.idx,
  }
  cfg.pendingAssign = adminAssign
  saveCfg()
  siteSendJob(j)

  -- Start at top of first shaft cell (or resume in place from restored pose).
  site.restorePickAfterComms()
  equipToolFromInventory(nil, true)
  if fromOrigin then
    assumeAtOrigin()
    suckFuelFromLeft()
  elseif pos.y < 1 and pos.x == 0 and pos.z == 0 then
    suckFuelFromLeft()
  end
  -- If we're mid-claim with a saved idx, don't force the first cell — dig loop pathing will.
  local startIdx = math.max(1, tonumber(j.idx) or 1)
  if startIdx <= 1 or fromOrigin then
    if not goTo(x0, y0, z0) then
      print("Could not reach column claim start.")
      return "bad"
    end
  end

  site.siteReportProgress({
    status = "mining", pattern = "column",
    x0 = x0, x1 = x1, z0 = z0, z1 = z1, y0 = y0, y1 = y1,
    job = j, jobFile = JOB_FILE,
  })

  STOP = false
  digging = true
  activeJob = j
  j.status = "active"
  saveJobFile(j)
  jobLabel = jobSummary(j)
  print(("COLUMN claim X%d-%d Z%d-%d  H=%d  resume @ %d/%d"):format(
    x0, x1, z0, z1, H, j.idx, j.total))

  for i = j.idx, #units do
    if STOP then site.finishJob(false, "stop"); digging = false; return "stop" end
    local u = units[i]
    j.idx = i
    saveJobFile(j)
    if not manageInventory(true) then
      site.finishJob(false, "inventory/fuel")
      digging = false
      return "paused"
    end
    if not site.ensurePickReady(true) then
      site.finishJob(false, "no-pickaxe")
      digging = false
      return "bad"
    end
    -- Climb to y0 at this XZ, then dig the shaft.
    if not goTo(u.x, y0, u.z) then
      site.finishJob(false, "path")
      digging = false
      return "paused"
    end
    excavateHere()
    if not digDownColumn(H) then
      site.finishJob(false, "column")
      digging = false
      return "paused"
    end
    -- Back at y0 after digDownColumn.
    j.idx = i + 1
    saveJobFile(j)
    checkIn("column", { status = "mining", job = j, jobFile = JOB_FILE })
  end
  site.finishJob(true)
  digging = false
  if STOP then return "stop" end
  if loadJobFile() then return "paused" end
  return "done"
end

function site.runClaimBand(claim, fromOrigin, existingJob)
  -- Column / 2×2 XZ claims from site dig mode.
  if claim.x0 ~= nil or tostring(claim.pattern or "") == "column" then
    if claim.x0 == nil then
      print("Bad column claim from site (missing x0/z0).")
      return "bad"
    end
    return site.runColumnClaim(claim, fromOrigin, existingJob)
  end

  local W = math.floor(tonumber(claim.W) or 0)
  local L = math.floor(tonumber(claim.L) or 0)
  local y0 = math.floor(tonumber(claim.y0) or 0)
  local y1 = math.floor(tonumber(claim.y1) or 0)
  if W < 1 or L < 1 or claim.y0 == nil or claim.y1 == nil then
    print("Bad claim from site.")
    return "bad"
  end
  if y1 < y0 then y0, y1 = y1, y0 end
  local j = existingJob
  local inPlace = (not fromOrigin) and existingJob ~= nil and (
    pos.x ~= 0 or pos.y ~= 0 or pos.z ~= 0
  )
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
    j.pattern = "layer"
    j.x0, j.x1, j.z0, j.z1 = nil, nil, nil, nil
    j.y0 = y0
    j.y1 = y1
    j.W = W
    j.L = L
    j.D = L
    j.H = y1 + 1
    j.stopY = y1 + 1
    -- Rebuild work list for this band (old total may be a different Y range).
    local units = boxBandUnits(W, L, y0, y1)
    j.total = #units
    j.idx = math.max(1, math.min(tonumber(j.idx) or 1, #units + 1))
  end
  local cidx = math.floor(tonumber(claim.continueIdx) or 0)
  if cidx >= 1 then
    local unitsN = tonumber(j.total) or 1
    j.idx = math.max(1, math.min(cidx, unitsN + 1))
  end
  adminAssign = {
    y0 = y0, y1 = y1, W = W, L = L, pattern = "layer",
    continueIdx = j.idx, fromAdmin = false,
  }
  cfg.pendingAssign = adminAssign
  saveCfg()
  siteSendJob(j)
  if inPlace then
    site.siteReportProgress({ status = "mining", y0 = y0, y1 = y1, job = j, jobFile = JOB_FILE })
    site.runSavedJob(j, false, true)
  else
    -- Descend into the band BEFORE modem chatter so we don't sit on Y=0.
    if not site.moveIntoBand(y0, y1, {
      force = true,
      fromOrigin = fromOrigin == true or pos.y < 1,
    }) then
      return "bad"
    end
    site.siteReportProgress({ status = "mining", y0 = y0, y1 = y1, job = j, jobFile = JOB_FILE })
    -- Pose already correct — do not assumeAtOrigin again inside runSavedJob.
    site.runSavedJob(j, false, false)
  end
  if STOP then return "stop" end
  if loadJobFile() then return "paused" end
  return "done"
end

function site.claimFromAdminAssign()
  if not adminAssign and type(cfg.pendingAssign) == "table" then
    adminAssign = cfg.pendingAssign
  end
  if not adminAssign then return nil end
  -- Only honor *tablet* locks here. Stale local pendingAssign must not override
  -- the site board (that caused shared XZ bands / wrong layer digs).
  if not adminAssign.fromAdmin and not adminAssign.assignId then
    return nil
  end
  local sitePat = normalizePattern(siteInfo and siteInfo.pattern)
    or normalizePattern(cfg.pattern)
  -- Site column mode uses 2×2 XZ claims from the board; ignore stale tablet Y assigns.
  if sitePat == "column" and adminAssign.x0 == nil then
    return nil
  end
  if sitePat == "layer" and adminAssign.x0 ~= nil then
    return nil
  end
  if adminAssign.x0 ~= nil then
    return {
      ok = true,
      pattern = "column",
      x0 = adminAssign.x0, x1 = adminAssign.x1,
      z0 = adminAssign.z0, z1 = adminAssign.z1,
      y0 = adminAssign.y0 or 0,
      y1 = adminAssign.y1 or math.max(0, (tonumber(adminAssign.H) or 1) - 1),
      W = adminAssign.W, L = adminAssign.L,
      continueIdx = adminAssign.continueIdx,
      resume = false,
      fromAdmin = true,
    }
  end
  if adminAssign.y0 == nil or adminAssign.y1 == nil then
    return nil
  end
  local W = math.floor(tonumber(adminAssign.W) or (siteInfo and siteInfo.W) or 0)
  local L = math.floor(tonumber(adminAssign.L) or (siteInfo and siteInfo.L) or 0)
  if W < 1 or L < 1 then
    local j = loadJobFile()
    if j then
      W = math.floor(tonumber(j.W) or W)
      L = math.floor(tonumber(j.L) or tonumber(j.D) or L)
    end
  end
  if W < 1 or L < 1 then
    print("Admin Y assign needs footprint (W×L). Site setup or area dig first.")
    return nil
  end
  return {
    ok = true,
    pattern = "layer",
    y0 = adminAssign.y0, y1 = adminAssign.y1,
    W = W, L = L,
    continueIdx = adminAssign.continueIdx,
    resume = false,
    fromAdmin = true,
  }
end

function site.sendTyped(typeName, extra)
  site.ensureModemForComms(true)
  local msg = site.sitePayload(extra or {})
  msg.type = typeName
  if siteId then
    rednet.send(siteId, msg, PROTO_QUARRY)
  else
    rednet.broadcast(msg, PROTO_QUARRY)
  end
end

function site.inActiveCellXZ(slack)
  if not activeCell then return true end
  slack = tonumber(slack) or 0
  local x0 = (activeCell.x0 or 0) - slack
  local x1 = (activeCell.x1 or activeCell.x0 or 0) + slack
  local z0 = (activeCell.z0 or 0) - slack
  local z1 = (activeCell.z1 or activeCell.z0 or 0) + slack
  return pos.x >= x0 and pos.x <= x1 and pos.z >= z0 and pos.z <= z1
end

-- Final full walk of every cell voxel. Must succeed before site cell_done.
-- Returns ok, err, nextVerifyIdx
function site.verifyCellClear(box, startIdx)
  local x0 = box.x0
  local x1 = box.x1
  local z0 = box.z0
  local z1 = box.z1
  local y0 = box.y0
  local y1 = box.y1
  local units = cellLayerUnits(x0, x1, z0, z1, y0, y1)
  startIdx = math.max(1, math.floor(tonumber(startIdx) or 1))
  if startIdx > #units then return true, nil, #units + 1 end
  print(("Verify pass — %d voxels from #%d (must be clear before done)"):format(
    #units, startIdx))
  local lastY = -999
  for i = startIdx, #units do
    if STOP then return false, "stop", i end
    if pendingReturnHome then return false, "return_home", i end
    if pendingReband then return false, "reband", i end
    local u = units[i]
    if not manageInventory(true) then return false, "inventory", i end
    if not site.ensurePickReady(true) then return false, "no-pickaxe", i end
    if not site.inActiveCellXZ(2) and (pos.x ~= u.x or pos.z ~= u.z) then
      return false, "perimeter", i
    end
    if lastY ~= -999 and u.y > lastY then
      while pos.y < u.y do
        if not moveDown() then return false, "layer", i end
      end
      print(("  verify layer Y=%d"):format(u.y))
    elseif lastY == -999 then
      print(("  verify layer Y=%d"):format(u.y))
    end
    lastY = u.y
    if not goTo(u.x, u.y, u.z) then return false, "path", i end
    if not site.inActiveCellXZ(0) then return false, "perimeter", i end
    excavateHere()
    if activeJob then
      activeJob.phase = "verify"
      activeJob.verifyIdx = i + 1
      activeJob.status = "verify"
      if i % 16 == 0 then saveJobFile(activeJob) end
    end
    if i % 16 == 0 and checkIn then
      checkIn("cell", {
        status = "verify", cellId = box.cellId,
        verifyIdx = i, total = #units,
      })
    end
  end
  return true, nil, #units + 1
end

-- Dig one site cell: full H, layer-by-layer, stay in XZ AABB.
-- Returns "done" | "paused" | "stop" | "bad"
function site.runCellClaim(claim, existingJob)
  if not claim or claim.x0 == nil or claim.z0 == nil then
    print("Bad cell claim.")
    return "bad"
  end
  local x0 = math.floor(tonumber(claim.x0) or 0)
  local x1 = math.floor(tonumber(claim.x1) or x0)
  local z0 = math.floor(tonumber(claim.z0) or 0)
  local z1 = math.floor(tonumber(claim.z1) or z0)
  local y0 = math.floor(tonumber(claim.y0) or 0)
  local y1 = math.floor(tonumber(claim.y1) or math.max(0, (tonumber(claim.H) or 1) - 1))
  if y1 < y0 then y0, y1 = y1, y0 end
  local W = math.floor(tonumber(claim.W) or (siteInfo and siteInfo.W) or (x1 + 1))
  local L = math.floor(tonumber(claim.L) or (siteInfo and siteInfo.L) or (z1 + 1))

  activeCell = {
    cellId = claim.cellId,
    x0 = x0, x1 = x1, z0 = z0, z1 = z1, y0 = y0, y1 = y1,
    W = W, L = L, H = y1 - y0 + 1,
  }

  local skipY = claim.emptyY or (claim.geo and claim.geo.emptyY)
  local units = cellLayerUnits(x0, x1, z0, z1, y0, y1, skipY)
  do
    local nSkip = 0
    if type(skipY) == "table" then
      for k, v in pairs(skipY) do
        if type(v) == "number" or v == true then nSkip = nSkip + 1
        elseif type(k) == "number" and v then nSkip = nSkip + 1 end
      end
    end
    if nSkip > 0 then
      print(("Geo hint: skipping %d empty Y layer(s) near site scanner."):format(nSkip))
    end
  end
  local j = existingJob
  if not j or j.status == "done"
      or tonumber(j.x0) ~= x0 or tonumber(j.z0) ~= z0
      or tonumber(j.x1) ~= x1 or tonumber(j.z1) ~= z1 then
    dug, skipped = 0, 0
    j = {
      type = "area", site = true, pattern = "cell", dig = "layer",
      cellId = claim.cellId,
      W = W, L = L, D = L, H = y1 + 1, stopY = y1 + 1,
      x0 = x0, x1 = x1, z0 = z0, z1 = z1, y0 = y0, y1 = y1,
      idx = 1, total = #units, status = "active", dug = 0, skipped = 0,
    }
  else
    j.site = true
    j.pattern = "cell"
    j.cellId = claim.cellId
    j.x0, j.x1, j.z0, j.z1 = x0, x1, z0, z1
    j.y0, j.y1 = y0, y1
    j.total = #units
    j.idx = math.max(1, math.min(tonumber(j.idx) or 1, #units + 1))
    if j.phase ~= "verify" and (tonumber(j.idx) or 1) > #units then
      j.phase = "verify"
      j.verifyIdx = math.max(1, math.floor(tonumber(j.verifyIdx) or 1))
    end
  end

  -- Travel with modem on.
  site.ensureModemForComms(true)
  if pos.x ~= 0 or pos.y ~= 0 or pos.z ~= 0 then
    print("Returning to origin before cell travel...")
    goHome()
  end
  assumeAtOrigin()
  suckFuelFromLeft()
  -- Bail before leaving if we can't reach the cell corner and still get home.
  do
    local toCell = airTravelCost(0, 0, 0, x0, 0, z0)
    local back = homeFuelCost(x0, 0, z0)
    local need = toCell + back
    local fuel = estimateFuelUnits()
    if fuel ~= math.huge and fuel < need then
      local sx = math.floor(x0 / 2)
      local sz = math.floor(z0 / 2)
      print(("Cell too far for fuel (have~%s, need~%d to enter+return)."):format(
        tostring(fuel), need))
      if broadcastSos then
        broadcastSos("need_refuel_station", {
          homeCost = need,
          fuelEst = fuel,
          suggestX = sx, suggestY = -1, suggestZ = sz,
        })
      end
      suckFuelFromLeft()
      fuel = estimateFuelUnits()
      if fuel ~= math.huge and fuel < need then
        print("Still short on fuel for this cell — pausing.")
        site.sendTyped("quarry_progress", { status = "paused", cellId = claim.cellId })
        return "paused"
      end
    end
  end
  site.sendTyped("quarry_leave_origin", { status = "travel", cellId = claim.cellId })
  print(("Travel → cell #%s  X%d-%d Z%d-%d (up-over-down, modem on)"):format(
    tostring(claim.cellId or "?"), x0, x1, z0, z1))

  -- Modem can't dig: climb 1, cross above dig surface, announce, pick, drop in.
  -- Outbound traffic: overtake other bots (up, F2, down to traffic layer).
  local announced = false
  if not goToViaAir(x0, 0, z0, {
    clear = 1,
    intent = "outbound",
    beforeSettle = function()
      site.sendTyped("quarry_arrive_cell", { status = "arrive", cellId = claim.cellId })
      announced = true
      site.restorePickAfterComms()
      equipToolFromInventory(nil, true)
    end,
  }) then
    setTravelIntent("dig")
    print("Could not reach cell corner.")
    site.sendTyped("quarry_progress", { status = "paused", cellId = claim.cellId })
    return "bad"
  end
  setTravelIntent("dig")
  -- Origin cell / already-there: no settle hop, still announce while modem is up.
  if not announced then
    site.sendTyped("quarry_arrive_cell", { status = "arrive", cellId = claim.cellId })
  end

  print(("Arrived cell #%s — layer dig Y%d..%d"):format(
    tostring(claim.cellId or "?"), y0, y1))

  site.restorePickAfterComms()
  equipToolFromInventory(nil, true)
  STOP = false
  digging = true
  activeJob = j
  j.status = "active"
  saveJobFile(j)
  siteSendJob(j)
  jobLabel = jobSummary(j)

  local lastY = -999
  if j.phase ~= "verify" then
    for i = j.idx, #units do
      if pendingReturnHome then
        print("Pose fault — returning home.")
        site.finishJob(false, "return_home")
        digging = false
        site.ensureModemForComms(true)
        goHome()
        site.sendTyped("quarry_progress", {
          status = "homing", reason = pendingReturnHome, cellId = claim.cellId,
        })
        pendingReturnHome = nil
        return "stop"
      end
      if pendingReband then
        site.finishJob(false, "reband")
        digging = false
        return "stop"
      end
      if STOP then
        site.finishJob(false, "stop")
        digging = false
        return "stop"
      end

      local u = units[i]
      j.idx = i
      saveJobFile(j)

      -- Stay inside cell perimeter (XZ).
      if not site.inActiveCellXZ(2) and (pos.x ~= u.x or pos.z ~= u.z) then
        print(("Outside cell perimeter @ %d,%d — abort."):format(pos.x, pos.z))
        site.finishJob(false, "perimeter")
        digging = false
        site.ensureModemForComms(true)
        goHome()
        site.sendTyped("quarry_progress", { status = "homing", reason = "perimeter" })
        return "stop"
      end

      if not manageInventory(true) then
        -- manageInventory already went home; keep modem for return trip.
        site.ensureModemForComms(true)
        digging = false
        -- Resume same cell after dump.
        print("Resuming same cell after dump/refuel...")
        return site.runCellClaim(claim, loadJobFile())
      end
      if not site.ensurePickReady(true) then
        site.finishJob(false, "no-pickaxe")
        digging = false
        return "bad"
      end

      if lastY ~= -999 and u.y > lastY then
        while pos.y < u.y do
          if not moveDown() then
            site.finishJob(false, "layer drop")
            digging = false
            return "paused"
          end
        end
        print(("  layer Y=%d"):format(u.y))
      elseif lastY == -999 then
        print(("  layer Y=%d"):format(u.y))
      end
      lastY = u.y

      if not goTo(u.x, u.y, u.z) then
        site.finishJob(false, "path")
        digging = false
        return "paused"
      end
      if not site.inActiveCellXZ(0) then
        print("Left cell while pathing — abort.")
        site.finishJob(false, "perimeter")
        digging = false
        site.ensureModemForComms(true)
        goHome()
        return "stop"
      end
      excavateHere()
      j.idx = i + 1
      saveJobFile(j)
      if i % 16 == 0 then
        checkIn("cell", { status = "mining", cellId = claim.cellId, job = j })
      end
    end
    -- Dig pass finished — must verify before site marks the cell complete.
    j.phase = "verify"
    j.verifyIdx = 1
    j.idx = #units + 1
    j.status = "verify"
    saveJobFile(j)
    siteSendJob(j)
  end

  print(("Verify cell #%s before marking done..."):format(tostring(claim.cellId or "?")))
  site.sendTyped("quarry_progress", { status = "verify", cellId = claim.cellId })
  local vOk, vErr, vAt = site.verifyCellClear({
    cellId = claim.cellId,
    x0 = x0, x1 = x1, z0 = z0, z1 = z1, y0 = y0, y1 = y1,
  }, j.verifyIdx or 1)
  if not vOk then
    j.phase = "verify"
    j.verifyIdx = vAt or j.verifyIdx or 1
    j.status = "paused"
    saveJobFile(j)
    site.finishJob(false, "verify:" .. tostring(vErr))
    digging = false
    if vErr == "return_home" or vErr == "perimeter" then
      site.ensureModemForComms(true)
      goHome()
      site.sendTyped("quarry_progress", {
        status = "homing", reason = tostring(vErr), cellId = claim.cellId,
      })
      pendingReturnHome = nil
      return "stop"
    end
    if vErr == "reband" or vErr == "stop" then return "stop" end
    if vErr == "inventory" then
      print("Resuming verify after dump/refuel...")
      return site.runCellClaim(claim, loadJobFile())
    end
    return "paused"
  end

  -- Only now tell the site the cell is complete (finishJob → quarry_done).
  site.finishJob(true)
  digging = false
  site.ensureModemForComms(true)
  goHome()
  dumpToStorage()
  suckFuelFromLeft()
  site.sendTyped("quarry_cell_done", {
    status = "idle", cellDone = true, finished = true,
    cellId = claim.cellId, y0 = y0, y1 = y1,
    x0 = x0, x1 = x1, z0 = z0, z1 = z1,
  })
  activeCell = nil
  clearJobFile({ keepSite = true })
  return "done"
end

-- opts.fromOrigin: turtle is at depot (default: true when pose is 0,0,0).
function site.digSiteMine(opts)
  opts = opts or {}
  if isOfflineMode() then
    print("Offline mode — site claims disabled. `mode online` or use `area` / `box`.")
    return
  end
  if not site.waitForModemOnline(false) then return end
  if not siteId then site.joinSite(5, true) end
  if not siteId then
    print("Need a site board (`join`). Solo dig: `area` / `box` or `mode offline`.")
    return
  end

  local prior = loadJobFile()
  if not prior and siteId then prior = fetchJobFromSite(5, true) end

  local cellsDone = 0
  while true do
    if pendingReturnHome then
      site.ensureModemForComms(true)
      goHome()
      site.sendTyped("quarry_progress", { status = "homing", reason = pendingReturnHome })
      pendingReturnHome = nil
      STOP = false
    end

    if pendingReband then
      -- Recall-only reband: home, ping site, keep/reclaim cell.
      local rb = pendingReband
      pendingReband = nil
      site.ensureModemForComms(true)
      goHome()
      site.sendTyped("quarry_home", {
        status = "homing", epoch = rb.epoch, recallOnly = true,
      })
      if rb.x0 ~= nil then
        rebandClaim = rb
      end
      STOP = false
    end

    if STOP then return end
    STOP = false

    local claim = rebandClaim
    rebandClaim = nil
    if not claim and activeCell and prior and prior.status ~= "done"
        and tonumber(prior.x0) == tonumber(activeCell.x0)
        and tonumber(prior.z0) == tonumber(activeCell.z0) then
      claim = {
        ok = true, cellId = activeCell.cellId,
        x0 = activeCell.x0, x1 = activeCell.x1,
        z0 = activeCell.z0, z1 = activeCell.z1,
        y0 = activeCell.y0, y1 = activeCell.y1,
        W = activeCell.W, L = activeCell.L, H = activeCell.H,
        resume = true, pattern = "cell",
      }
    end
    if not claim then
      claim = site.claimCell(cellsDone > 0)
    end
    if not claim then
      if cellsDone == 0 then
        print("No free cells. Site: `setup WxL H` or `cells` / `clearcells`.")
      else
        print("No more free cells — this turtle is done.")
      end
      return
    end

    activeCell = {
      cellId = claim.cellId,
      x0 = claim.x0, x1 = claim.x1, z0 = claim.z0, z1 = claim.z1,
      y0 = claim.y0 or 0,
      y1 = claim.y1 or math.max(0, (tonumber(claim.H) or 1) - 1),
      W = claim.W, L = claim.L, H = claim.H,
    }
    siteInfo = claim
    cfg.pattern = "cell"
    saveCfg()

    local stored = nil
    if prior and prior.status ~= "done"
        and tonumber(prior.x0) == tonumber(claim.x0)
        and tonumber(prior.z0) == tonumber(claim.z0)
        and tonumber(prior.x1) == tonumber(claim.x1)
        and tonumber(prior.z1) == tonumber(claim.z1) then
      stored = prior
      print("Resuming cell job @ " .. tostring(stored.idx))
    else
      if prior then clearJobFile({ keepSite = true }) end
    end
    prior = nil

    print(("Mining cell #%s  X%d-%d Z%d-%d ..."):format(
      tostring(claim.cellId or "?"),
      claim.x0, claim.x1 or claim.x0, claim.z0, claim.z1 or claim.z0))
    local r = site.runCellClaim(claim, stored)
    if r == "stop" and (pendingReband or pendingReturnHome) then
      -- loop
    elseif r ~= "done" then
      return
    else
      cellsDone = cellsDone + 1
      print("Cell complete — requesting next...")
    end
  end
end

function site.jobIsResumable(j)
  if type(j) ~= "table" or not j.type then return false end
  if j.status == "done" then return false end
  local st = tostring(j.status or "")
  if st == "active" or st == "paused" or st == "sos" or st == "depot" then return true end
  local idx, total = tonumber(j.idx), tonumber(j.total)
  return idx ~= nil and total ~= nil and idx >= 1 and idx <= total
end

-- Prefer local job; if missing/stale, take the site board copy (online mode only).
function site.resolveResumeJob(quiet)
  local localJ = loadJobFile()
  if localJ and localJ.status == "done" then
    clearJobFile({ keepSite = true })
    localJ = nil
  end
  if isOfflineMode() then
    if localJ and site.jobIsResumable(localJ) then return localJ, "local" end
    return nil, nil
  end
  if not siteId then site.joinSite(quiet and 4 or 6, quiet == true) end
  local siteJ = nil
  if siteId then
    -- Ask the board even when local exists — reboot recovery / newer progress.
    siteJ = fetchJobFromSite(quiet and 4 or 6, true, true)
  end
  if siteJ and site.jobIsResumable(siteJ) then
    if not localJ then
      adoptJob(siteJ, "site board")
      return loadJobFile() or siteJ, "site"
    end
    local lu = tonumber(localJ.updated) or 0
    local su = tonumber(siteJ.updated) or 0
    local li = tonumber(localJ.idx) or 0
    local si = tonumber(siteJ.idx) or 0
    -- Prefer site when it has pose and local doesn't, or newer progress.
    local siteHasPose = siteJ.posX ~= nil
    local localHasPose = localJ.posX ~= nil
    if (siteHasPose and not localHasPose) or su > lu or si > li then
      adoptJob(siteJ, "site board")
      return loadJobFile() or siteJ, "site"
    end
  end
  if localJ and site.jobIsResumable(localJ) then return localJ, "local" end
  if siteJ and site.jobIsResumable(siteJ) then
    adoptJob(siteJ, "site board")
    return loadJobFile() or siteJ, "site"
  end
  return nil, nil
end

function site.depotRefuelThenReady()
  print("Low fuel — returning to depot to refuel, then continuing...")
  if activeJob then
    activeJob.status = "paused"
    saveJobFile(activeJob)
  end
  if not goHome() then
    if needsFuelSos() and broadcastSos then broadcastSos("stranded_no_fuel") end
    return false
  end
  dumpToStorage()
  suckFuelFromLeft()
  if checkIn then checkIn("depot", { status = "depot" }) end
  if needsFuelSos() then
    if broadcastSos then broadcastSos("depot_empty_fuel") end
    return false
  end
  assumeAtOrigin()
  return true
end

-- Shared resume path for `continue` and reboot auto-resume.
function site.continueJob(opts)
  opts = opts or {}
  local auto = opts.auto == true
  -- Online + site: board owns pattern + unique bands. digSiteMine asks the
  -- site, then resumes a local job only when it matches that claim.
  if isOnlineMode() and (siteId or site.joinSite(4, true)) then
    local j = loadJobFile()
    local sitePat = normalizePattern(siteInfo and siteInfo.pattern)
      or normalizePattern(cfg.pattern)
    if j and sitePat then
      local jPat = normalizePattern(j.pattern)
        or ((j.x0 ~= nil) and "column") or ((j.y0 ~= nil) and "layer") or nil
      if jPat and jPat ~= sitePat then
        print(("Local job is %s but site is %s — clearing and re-claiming."):format(
          jPat, sitePat))
        clearLocalMineMemory({ keepSite = true })
      end
    end
    print("Site mine — claim/pattern from board...")
    site.digSiteMine({ fromOrigin = true })
    return true
  end

  local j, src = site.resolveResumeJob(auto)
  if not j then
    if not auto then
      if isOfflineMode() then
        print("No saved job. Offline mode: start with area / box / tunnel.")
      else
        print("No saved job locally or on site. Start with area / box / mine.")
      end
    end
    return false
  end

  print((auto and "Auto-resume" or "Loaded") .. " (" .. tostring(src) .. "): " .. jobSummary(j))

  local hadPose = restorePoseFromJob(j)
  if not hadPose then
    print("No saved pose — assuming turtle is at origin (depot).")
    assumeAtOrigin()
  end

  local plan, fuel, home = resumeFuelPlan()
  print(("Fuel plan=%s  est=%s  homeDist=%d"):format(
    plan, tostring(fuel), home))

  if plan == "sos" then
    print("Not enough fuel to reach depot — SOS.")
    if broadcastSos then broadcastSos("reboot_no_fuel") end
    return false
  end

  local fromOrigin = false
  local inPlace = false
  if plan == "depot" then
    if not site.depotRefuelThenReady() then return false end
    fromOrigin = true
    j = loadJobFile() or j
  elseif hadPose and (pos.x ~= 0 or pos.y ~= 0 or pos.z ~= 0) then
    inPlace = true
    fromOrigin = false
  else
    fromOrigin = true
    assumeAtOrigin()
  end

  -- Site / claimed jobs keep claiming further regions after this one finishes.
  if isOnlineMode() and (j.site or j.y0 ~= nil or j.x0 ~= nil) then
    if not siteId then site.joinSite(4, true) end
    site.digSiteMine({ fromOrigin = fromOrigin })
    return true
  end

  site.runSavedJob(j, fromOrigin, inPlace)
  return true
end

-- On program start: resume mid-job (site sync only in online mode).
function site.bootAutoResume()
  local j = loadJobFile()
  if j and j.status == "done" then
    clearJobFile({ keepSite = true })
    j = nil
  end
  if isOfflineMode() then
    if not j or not site.jobIsResumable(j) then return false end
    print("")
    print("Offline mode — resuming local job (no site).")
    return site.continueJob({ auto = true })
  end
  -- Need modem/site or a local job file to consider auto-resume.
  if not j and not siteId and not cfg.siteId then return false end
  print("")
  print("Checking site board for in-progress work...")
  return site.continueJob({ auto = true })
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
function site.printHelp()
  print("Offline miner — origin = top-front-left, facing into mine.")
  print("  +X right   +Y down   +Z forward")
  print("")
  print("  mode online|offline              site/admin link vs solo dig")
  print("  area <W>x<L> <stopY>             width × length, stopY layers (1 Y each)")
  print("  box <W>x<H>x<D>                  H layers down, 1 Y at a time")
  print("  tunnel <L> [W]                   player-tall (2 high) corridor")
  print("  stair <W>x<steps> <up|down>      player-tall staircase")
  print("  join                             find site board (online mode)")
  print("  mine                             claim from site (online mode)")
  print("  site                             show site / BPC / mine broadcast")
  print("  pattern column|layer             dig style hint (site uses site pattern)")
  print("  equip [left|right]               equip pick from inventory (aliases: tool, pick)")
  print("  continue | resume                resume saved / site job (auto on reboot)")
  print("  job | clearjob                   show / forget saved job")
  print("  home | dump | refuel | setup | stop | status")
  print("")
  print("mode offline = solo (area/box), no site/admin.  mode online = join/mine.")
  print("Slot 15 = wireless modem (RIGHT pick swap) — used in online mode.")
  print("Reboot: resumes job; online also syncs with site (depot-first if low fuel).")
  print("Traffic: other miners → overtake/yield; other entities → wait. Never attack.")
  print("Fuel: returns to depot while still able to reach it; mid-path chests OK.")
  print("If short of home trip: SOS admin with coords + suggested refuel spot.")
  print("Jobs save pose+progress to " .. JOB_FILE .. ".")
end

function site.printStatus()
  print(("pos=%d,%d,%d face=%d"):format(pos.x, pos.y, pos.z, facing))
  print(("label=%s  dug=%d skipped=%d bpc=%.1f fuel=%s"):format(
    jobLabel, dug, skipped, currentBpc(), tostring(turtle.getFuelLevel())))
  print(("mode=%s  setup=%s  pattern=%s  site=%s"):format(
    tostring(cfg.mode or "online"),
    tostring(cfg.setupDone), tostring(cfg.pattern or "column"), tostring(siteId or "-")))
  local j = activeJob or loadJobFile()
  if j then
    print("saved: " .. jobSummary(j))
  else
    print("saved: (none)")
  end
end

function site.handleCommand(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = (a[1] or ""):lower()

  if cmd == "" then
    return true
  elseif cmd == "help" or cmd == "?" then
    site.printHelp()
  elseif cmd == "status" then
    site.printStatus()
  elseif cmd == "stop" then
    STOP = true
    print("Stop requested — job will be saved for `continue`.")
  elseif cmd == "setup" then
    setupChests()
  elseif cmd == "join" then
    if isOfflineMode() then
      print("Offline mode — use `mode online` to join a site board.")
    else
      site.joinSite(tonumber(a[2]) or 6)
    end
  elseif cmd == "mine" then
    if isOfflineMode() then
      print("Offline mode — use `area` / `box` for solo digs, or `mode online` for site claims.")
    else
      site.digSiteMine()
    end
  elseif cmd == "site" then
    site.printSiteInfo()
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
    clearLocalMineMemory()
    print("Cleared " .. JOB_FILE .. " + pending site/tablet assign.")
  elseif cmd == "continue" or cmd == "resume" then
    site.continueJob()
  elseif cmd == "mode" then
    if not a[2] then
      print("Mode: " .. tostring(cfg.mode or "online"))
      print("  online  — site board + admin check-ins (join / mine)")
      print("  offline — solo dig only (area / box / tunnel / stair)")
      print("Usage: mode online|offline")
    else
      -- Allow `mode column` as a friendly redirect to dig pattern.
      local asPat = normalizePattern(a[2])
      local m = normalizeNetMode(a[2])
      if m then
        cfg.mode = m
        saveCfg()
        if m == "offline" then
          siteId = nil
          print("Mode set to OFFLINE — solo dig, no site/admin.")
          print("Use: area <W>x<L> <stopY>   or   box <W>x<H>x<D>")
        else
          print("Mode set to ONLINE — site/admin enabled.")
          local hasM = site.ensureModemForComms(true) or site.openModem() or findModemInInventory() ~= nil
          if hasM then
            site.joinSite(4, false)
          else
            print("Put a wireless modem in slot " .. MODEM_SLOT .. ", then `join`.")
          end
        end
      elseif asPat then
        cfg.pattern = asPat
        saveCfg()
        print("Dig pattern set to: " .. asPat .. "  (tip: use `pattern <column|layer>`)")
      else
        print("Usage: mode online|offline")
      end
    end
  elseif cmd == "pattern" then
    if not a[2] then
      print("Dig pattern: " .. tostring(cfg.pattern or "column"))
      print("  column — dig each vertical shaft, then move on")
      print("  layer  — mine each horizontal layer top→bottom")
      print("Usage: pattern <column|layer>")
      print("(Network mode is separate: `mode online|offline`)")
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
      site.digArea(d[1], d[2], d[3])
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
        site.digArea(d[1], d[2], stopY)
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
      site.digBox(d[1], d[2], d[3])
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
      site.digTunnel(L, W)
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
      site.digStair(d[1], d[2], dir)
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

-- Label: V{major}.{minor}-Miner{computerId}  e.g. V1.4-Miner0
function site.minerVersionLabel()
  local maj, min = tostring(MINER_VERSION):match("^(%d+)%.(%d+)")
  if not maj then
    maj, min = "0", "0"
  end
  return ("V%s.%s-Miner%d"):format(maj, min, os.getComputerID())
end

function site.applyMinerLabel()
  local label = site.minerVersionLabel()
  os.setComputerLabel(label)
  cfg.label = label
  return label
end

loadCfg()
loadExclude()
if type(cfg.pendingAssign) == "table" and cfg.pendingAssign.y0 ~= nil then
  adminAssign = cfg.pendingAssign
end
site.applyMinerLabel()
cfg.mode = normalizeNetMode(cfg.mode) or "online"
saveCfg()

term.clear()
term.setCursorPos(1, 1)
print("== Offline Miner ==")
print("Label: " .. tostring(os.getComputerLabel() or cfg.label or "?"))
print("Origin: top-front-left of dig, facing in = 0,0,0")
print("Axes: +X right | +Y down | +Z forward")
print("Mode: " .. tostring(cfg.mode) .. "  (`mode online|offline`)")
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

if cfg.siteId and isOnlineMode() then
  siteId = cfg.siteId
end
local hasModem = false
local autoStarted = false
if isOnlineMode() then
  print("ONLINE — waiting for modem, then site join / reband / mine.")
  hasModem = site.waitForModemOnline(false)
  if hasModem then
    print("ONLINE — modem slot " .. MODEM_SLOT .. " (RIGHT pick swap).")
    site.joinSite(6, false)
    if not saved then
      saved = loadJobFile()
    end
    site.ensureModemForComms(true)
    -- Join-time reband / resume / start site mine (same dig engine as offline).
    print("Starting online site loop (reband → reset → mine)...")
    parallel.waitForAny(function()
      if pendingReband then
        site.processRebandCycle()
      elseif saved then
        local ok = site.bootAutoResume()
        if ok then autoStarted = true; return end
      end
      site.digSiteMine({ fromOrigin = true })
      autoStarted = true
    end, site.mineNetLoop)
  else
    print("ONLINE — stopped waiting for modem.")
  end
else
  siteId = nil
  print("OFFLINE — solo dig only (area / box). No site/admin. `mode online` to link.")
  if saved then
    autoStarted = site.bootAutoResume() == true
  end
end

if saved and not autoStarted then
  print("")
  print("Saved job: " .. jobSummary(saved))
end

if not autoStarted then
  if saved and loadJobFile() then
    print("Job waiting — type `continue` (or add coal / clearjob).")
  elseif isOnlineMode() and hasModem then
    print("Site idle — type `mine` to claim, or wait for reband.")
  elseif isOfflineMode() then
    print("Solo ready — example:  area 16x32 40")
  end
  print("")
  print("Type help. Examples:  mode offline   |   area 16x32 40")
  print("")
end

function site.consoleLoop()
  while true do
    write("mine> ")
    local line = read()
    local r = site.handleCommand(line)
    if r == "exit" then return end
  end
end

if autoStarted then
  print("")
  print("Auto site/mine finished. Type help for more commands.")
end

if isOnlineMode() and hasModem then
  parallel.waitForAny(site.consoleLoop, site.mineNetLoop)
else
  site.consoleLoop()
end

print("Offline miner stopped.")
