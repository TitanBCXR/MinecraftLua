--[[
  quarry/workers/strip_miner.lua  -  Branch / strip mining turtle
  Titan-Version: 1.0.3

  Classic strip mine: dig a main 1×2 tunnel, then left/right branches every
  few blocks. Solo worker (no site board). Same chest layout as cell miner:

    * Fuel chest LEFT  → coal in slot 16; mined coal excess returns here
    * Storage BEHIND   → dump non-fuel slots 1-14 only
    * Slot 15 = wireless modem (optional)
    * Pickaxe on RIGHT upgrade

  Mined coal/charcoal: keep one stack (64) in slot 16; excess → fuel chest,
  never the deposit chest.

  Fuel safety: estimates tank + fuel items vs Manhattan home cost, returns to
  depot while it can still arrive (+ margin), and pauses with a clear SOS if
  stranded short of home.

  Place turtle at the tunnel mouth, facing into the mine (origin 0,0,0).
  +X right, +Y down, +Z forward.

  One-shot workflow:
    set 64 3 16 1     save your strip defaults once
    mine              start digging with those defaults

  Commands:
    mine | go | start           begin with saved defaults (or resume pause)
    set <L> [spacing] [branch] [levels]   save defaults
    defaults                    show saved defaults
    strip <length> [spacing] [branch] [levels]   one-off (also saves defaults)
    continue | resume
    home | dump | refuel | setup | stop | status | help
    exit

  Run:  quarry/workers/strip_miner
]]

local CFG = "strip_miner.cfg"
local JOB_FILE = "strip_miner_job.cfg"
local EXCLUDE = "exclude.txt"
local FUEL_SLOT = 16
local MODEM_SLOT = 15
local FUEL_KEEP = 64         -- keep one stack of coal on the turtle
local MIN_FUEL = 200
local HOME_MARGIN = 24       -- spare fuel on arrival at depot
local WORK_RESERVE = 48      -- keep digging only with this much above home cost
local VERSION = "1.0.3"

local STOP = false
local dug, skipped, moves = 0, 0, 0
local pos = { x = 0, y = 0, z = 0 }
local facing = 0 -- 0=+Z, 1=+X, 2=-Z, 3=-X
local cfg = {
  setupDone = false,
  length = 64,
  spacing = 3,
  branch = 16,
  levels = 1,
}
local activeJob = nil

local restricted = {
  ["minecraft:bedrock"] = true,
  ["minecraft:command_block"] = true,
  ["minecraft:barrier"] = true,
  ["minecraft:end_portal"] = true,
  ["minecraft:end_portal_frame"] = true,
  ["minecraft:nether_portal"] = true,
}

local function loadExclude()
  if not fs.exists(EXCLUDE) then return end
  local f = fs.open(EXCLUDE, "r")
  if not f then return end
  for line in f.readAll():gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$") or ""
    if line ~= "" and not line:find("^#") then
      restricted[line] = true
    end
  end
  f.close()
end

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

local function defaultsOf()
  return {
    length = math.max(1, math.floor(tonumber(cfg.length) or 64)),
    spacing = math.max(2, math.floor(tonumber(cfg.spacing) or 3)),
    branch = math.max(0, math.floor(tonumber(cfg.branch) or 16)),
    levels = math.max(1, math.floor(tonumber(cfg.levels) or 1)),
  }
end

local function saveDefaults(length, spacing, branch, levels)
  local d = defaultsOf()
  if length ~= nil then d.length = math.max(1, math.floor(tonumber(length) or d.length)) end
  if spacing ~= nil then d.spacing = math.max(2, math.floor(tonumber(spacing) or d.spacing)) end
  if branch ~= nil then d.branch = math.max(0, math.floor(tonumber(branch) or d.branch)) end
  if levels ~= nil then d.levels = math.max(1, math.floor(tonumber(levels) or d.levels)) end
  cfg.length, cfg.spacing, cfg.branch, cfg.levels = d.length, d.spacing, d.branch, d.levels
  saveCfg()
  return d
end

local function saveJob(j)
  activeJob = j
  local f = fs.open(JOB_FILE, "w")
  if f then f.write(textutils.serialize(j or {})); f.close() end
end

local function loadJob()
  if not fs.exists(JOB_FILE) then return nil end
  local f = fs.open(JOB_FILE, "r")
  if not f then return nil end
  local ok, data = pcall(textutils.unserialize, f.readAll())
  f.close()
  if ok and type(data) == "table" then activeJob = data; return data end
  return nil
end

local function clearJob()
  activeJob = nil
  if fs.exists(JOB_FILE) then fs.delete(JOB_FILE) end
end

--------------------------------------------------------------------------------
-- Motion / dig
--------------------------------------------------------------------------------
local function turnLeft()
  turtle.turnLeft(); facing = (facing + 3) % 4
end
local function turnRight()
  turtle.turnRight(); facing = (facing + 1) % 4
end
local function faceDir(dir)
  dir = dir % 4
  while facing ~= dir do
    local r = (dir - facing) % 4
    if r == 3 then turnLeft() else turnRight() end
  end
end

local function isRestricted(name)
  return name and restricted[name] == true
end

local function digDir(dir)
  for _ = 1, 8 do
    local ok, info
    if dir == "forward" then
      if not turtle.detect() then return true end
      ok, info = turtle.inspect()
      if ok and isRestricted(info.name) then skipped = skipped + 1; return false end
      if turtle.dig() then dug = dug + 1 else return false end
    elseif dir == "up" then
      if not turtle.detectUp() then return true end
      ok, info = turtle.inspectUp()
      if ok and isRestricted(info.name) then skipped = skipped + 1; return false end
      if turtle.digUp() then dug = dug + 1 else return false end
    elseif dir == "down" then
      if not turtle.detectDown() then return true end
      ok, info = turtle.inspectDown()
      if ok and isRestricted(info.name) then skipped = skipped + 1; return false end
      if turtle.digDown() then dug = dug + 1 else return false end
    end
    sleep(0.05)
  end
  return false
end

--------------------------------------------------------------------------------
-- Fuel planning (anti-strand)
--------------------------------------------------------------------------------
local function itemDetail(slot)
  if turtle.getItemDetail then return turtle.getItemDetail(slot) end
  return nil
end

local function selectedIsFuel()
  local ok = false
  pcall(function() ok = turtle.refuel(0) end)
  return ok
end

local function consolidateFuelToSlot16()
  for s = 1, 15 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if selectedIsFuel() and turtle.getItemSpace(FUEL_SLOT) > 0 then
        turtle.transferTo(FUEL_SLOT)
      end
    end
  end
  turtle.select(FUEL_SLOT)
end

local function burnSomeFuel()
  turtle.select(FUEL_SLOT)
  if turtle.getItemCount(FUEL_SLOT) > 0 and selectedIsFuel() then
    turtle.refuel(math.min(8, turtle.getItemCount(FUEL_SLOT)))
  end
  for s = 1, 15 do
    local level = turtle.getFuelLevel()
    if level == "unlimited" or (type(level) == "number" and level >= MIN_FUEL) then break end
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if selectedIsFuel() then turtle.refuel(math.min(4, turtle.getItemCount(s))) end
    end
  end
  turtle.select(FUEL_SLOT)
end

local function ensureFuel()
  if turtle.getFuelLevel() == "unlimited" then return true end
  if turtle.getFuelLevel() < MIN_FUEL then
    consolidateFuelToSlot16()
    burnSomeFuel()
  end
  if turtle.getFuelLevel() > 0 then return true end
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if selectedIsFuel() then turtle.refuel() end
    end
    if turtle.getFuelLevel() > 0 then return true end
  end
  return false
end

-- Manhattan home cost (matches goTo) + arrival margin.
local function homeFuelCost(px, py, pz)
  px = math.floor(tonumber(px) or pos.x)
  py = math.floor(tonumber(py) or pos.y)
  pz = math.floor(tonumber(pz) or pos.z)
  return math.abs(px) + math.abs(py) + math.abs(pz) + HOME_MARGIN
end

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

-- "ok" | "depot" | "stranded"
local function fuelPlanNow(px, py, pz)
  local fuel = estimateFuelUnits()
  local home = homeFuelCost(px, py, pz)
  if fuel == math.huge then return "ok", fuel, home end
  local atHome = (math.floor(tonumber(px) or pos.x) == 0
    and math.floor(tonumber(py) or pos.y) == 0
    and math.floor(tonumber(pz) or pos.z) == 0)
  if atHome then
    if fuel >= MIN_FUEL then return "ok", fuel, home end
    return "depot", fuel, home
  end
  if fuel < home then return "stranded", fuel, home end
  if fuel < home + WORK_RESERVE then return "depot", fuel, home end
  return "ok", fuel, home
end

local function openModemIfAny()
  for _, side in ipairs(redstone.getSides()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then pcall(rednet.open, side) end
      return true
    end
  end
  if turtle.getItemCount(MODEM_SLOT) > 0 then
    turtle.select(MODEM_SLOT)
    if pcall(turtle.equipRight) then
      for _, side in ipairs(redstone.getSides()) do
        if peripheral.getType(side) == "modem" then
          pcall(rednet.open, side)
          return "equipped"
        end
      end
    end
  end
  return false
end

local function broadcastFuelSos(reason, fuel, home)
  openModemIfAny()
  local msg = {
    type = "quarry_sos",
    reason = reason or "out_of_fuel",
    name = os.getComputerLabel() or ("StripMiner-" .. os.getComputerID()),
    from = os.getComputerID(),
    worker = "strip_miner",
    posX = pos.x, posY = pos.y, posZ = pos.z,
    fuel = turtle.getFuelLevel(),
    fuelEst = fuel,
    homeCost = home,
  }
  pcall(rednet.broadcast, msg, "titan_quarry")
  pcall(rednet.broadcast, msg, "titan_net")
  pcall(rednet.broadcast, msg, "titan_router")
  print(("[SOS] %s @ %d,%d,%d fuel~%s need~%s"):format(
    tostring(reason), pos.x, pos.y, pos.z, tostring(fuel), tostring(home)))
end

local function forward(digBlocks)
  if STOP then return false end
  if not ensureFuel() then return false end
  if digBlocks then digDir("forward") end
  if turtle.forward() then
    if facing == 0 then pos.z = pos.z + 1
    elseif facing == 1 then pos.x = pos.x + 1
    elseif facing == 2 then pos.z = pos.z - 1
    else pos.x = pos.x - 1 end
    moves = moves + 1
    return true
  end
  return false
end

local function up(digBlocks)
  if STOP then return false end
  if not ensureFuel() then return false end
  if digBlocks then digDir("up") end
  if turtle.up() then pos.y = pos.y - 1; moves = moves + 1; return true end
  return false
end

local function down(digBlocks)
  if STOP then return false end
  if not ensureFuel() then return false end
  if digBlocks then digDir("down") end
  if turtle.down() then pos.y = pos.y + 1; moves = moves + 1; return true end
  return false
end

local function goTo(x, y, z)
  x, y, z = math.floor(x), math.floor(y), math.floor(z)
  while pos.y > y do if not up(true) then return false end end
  while pos.y < y do if not down(true) then return false end end
  if pos.x ~= x then
    faceDir(pos.x < x and 1 or 3)
    while pos.x ~= x do if not forward(true) then return false end end
  end
  if pos.z ~= z then
    faceDir(pos.z < z and 0 or 2)
    while pos.z ~= z do if not forward(true) then return false end end
  end
  return true
end

local function inventoryFull()
  for s = 1, 14 do
    if turtle.getItemCount(s) == 0 then return false end
  end
  return true
end

local function isCoalName(name)
  name = tostring(name or ""):lower()
  if name == "" then return false end
  -- Coal / charcoal (and blocks) — keep as turtle fuel stock.
  return name:find("coal", 1, true) ~= nil or name:find("charcoal", 1, true) ~= nil
end

local function slotIsCoal(slot)
  local d = itemDetail(slot)
  return d and isCoalName(d.name)
end

-- Pull mined coal into slot 16 (up to FUEL_KEEP). Other fuels also consolidate.
local function gatherCoalToFuelSlot()
  consolidateFuelToSlot16()
  for s = 1, 14 do
    if turtle.getItemCount(FUEL_SLOT) >= FUEL_KEEP then break end
    if turtle.getItemCount(s) > 0 and slotIsCoal(s) then
      turtle.select(s)
      turtle.transferTo(FUEL_SLOT)
    end
  end
  turtle.select(FUEL_SLOT)
end

-- Drop excess fuel/coal into the LEFT fuel chest. Never into the deposit.
local function depositExcessFuel()
  gatherCoalToFuelSlot()
  faceDir(3) -- left = fuel chest
  local n = turtle.getItemCount(FUEL_SLOT)
  if n > FUEL_KEEP then
    turtle.select(FUEL_SLOT)
    turtle.drop(n - FUEL_KEEP)
  end
  for s = 1, 14 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if selectedIsFuel() or slotIsCoal(s) then
        turtle.drop()
      end
    end
  end
  -- Trim again if more coal landed in 16 somehow.
  n = turtle.getItemCount(FUEL_SLOT)
  if n > FUEL_KEEP then
    turtle.select(FUEL_SLOT)
    turtle.drop(n - FUEL_KEEP)
  end
  faceDir(0)
  turtle.select(FUEL_SLOT)
end

-- Deposit chest BEHIND: non-fuel only. Coal/fuel excess already went LEFT.
local function dumpToStorage()
  gatherCoalToFuelSlot()
  depositExcessFuel()
  faceDir(2) -- behind = storage
  for s = 1, 14 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if selectedIsFuel() or slotIsCoal(s) then
        -- Prefer fuel chest, never deposit.
        faceDir(3)
        turtle.drop()
        faceDir(2)
      else
        turtle.drop()
      end
    end
  end
  -- Ensure slot 16 is still capped at one stack.
  faceDir(3)
  local n = turtle.getItemCount(FUEL_SLOT)
  if n > FUEL_KEEP then
    turtle.select(FUEL_SLOT)
    turtle.drop(n - FUEL_KEEP)
  end
  faceDir(0)
  turtle.select(FUEL_SLOT)
end

-- Top up slot 16 to FUEL_KEEP from LEFT; burn only enough for the tank.
local function suckFuel()
  faceDir(3) -- left
  turtle.select(FUEL_SLOT)
  while turtle.getItemCount(FUEL_SLOT) < FUEL_KEEP do
    local need = FUEL_KEEP - turtle.getItemCount(FUEL_SLOT)
    if not turtle.suck(need) then break end
  end
  local level = turtle.getFuelLevel()
  if level ~= "unlimited" and (tonumber(level) or 0) < MIN_FUEL then
    local have = turtle.getItemCount(FUEL_SLOT)
    -- Burn a little, but try to leave coal in the slot.
    local burn = math.min(8, math.max(0, have - 16))
    if burn < 1 and have > 0 then burn = 1 end
    if burn > 0 then turtle.refuel(burn) end
  end
  faceDir(0)
  turtle.select(FUEL_SLOT)
end

local function goHome()
  local ok = goTo(0, 0, 0)
  faceDir(0)
  dumpToStorage() -- excess coal → fuel chest; ores → deposit
  suckFuel()      -- refill slot 16 to 64 from fuel chest
  return ok
end

-- Returns true to keep digging, false to pause the job.
-- On depot trip: dumps/refuels and returns to the dig pose when possible.
local function maybeHome(opts)
  opts = opts or {}
  local plan, fuel, home = fuelPlanNow()
  local full = inventoryFull()
  if plan == "ok" and not full then return true end

  if plan == "stranded" then
    print(("Fuel low for home (have~%s need~%d). Attempting depot..."):format(
      tostring(fuel), home))
    broadcastFuelSos("need_refuel_station", fuel, home)
    if activeJob then
      activeJob.status = "paused"
      activeJob.pauseReason = "stranded"
      activeJob.resumeX, activeJob.resumeY, activeJob.resumeZ = pos.x, pos.y, pos.z
      activeJob.resumeFacing = facing
      activeJob.dug, activeJob.skipped = dug, skipped
      saveJob(activeJob)
    end
    -- Best-effort walk home; may still fail if tank is empty.
    goHome()
    local plan2, fuel2, home2 = fuelPlanNow(0, 0, 0)
    if plan2 == "ok" or (type(fuel2) == "number" and fuel2 >= MIN_FUEL) then
      print("Reached depot / refueled. Resume with `continue`.")
    else
      print(("Still short on fuel at/near depot (have~%s). Add coal LEFT, then `continue`."):format(
        tostring(fuel2)))
      broadcastFuelSos("stranded", fuel2, home2)
    end
    return false
  end

  -- depot or inventory full — return while we still can.
  local rx, ry, rz, rf = pos.x, pos.y, pos.z, facing
  if activeJob then
    activeJob.resumeX, activeJob.resumeY, activeJob.resumeZ = rx, ry, rz
    activeJob.resumeFacing = rf
    activeJob.dug, activeJob.skipped = dug, skipped
    saveJob(activeJob)
  end
  print(("Returning to depot (fuel~%s home~%d%s)..."):format(
    tostring(fuel), home, full and ", inv full" or ""))
  if not goHome() then
    print("Could not reach depot.")
    broadcastFuelSos("home_failed", estimateFuelUnits(), homeFuelCost())
    if activeJob then
      activeJob.status = "paused"
      activeJob.pauseReason = "home_failed"
      saveJob(activeJob)
    end
    return false
  end

  local planAfter, fuelAfter = fuelPlanNow(0, 0, 0)
  if opts.stayHome or planAfter ~= "ok" or (type(fuelAfter) == "number" and fuelAfter < MIN_FUEL) then
    print(("At depot. fuel~%s — top up LEFT chest if needed, then `continue`."):format(
      tostring(fuelAfter)))
    if activeJob then
      activeJob.status = "paused"
      activeJob.pauseReason = "refuel"
      saveJob(activeJob)
    end
    return false
  end

  if not goTo(rx, ry, rz) then
    print("Could not return to dig pose after refuel.")
    if activeJob then
      activeJob.status = "paused"
      activeJob.pauseReason = "resume_travel"
      saveJob(activeJob)
    end
    return false
  end
  faceDir(rf)
  return true
end

-- Before a branch: ensure fuel for out + back + home from the far tip.
local function canAffordBranch(branchLen)
  branchLen = math.max(0, math.floor(tonumber(branchLen) or 0))
  if branchLen < 1 then return true end
  -- Worst-case tip is branchLen off the spine on either side.
  local tipCost = math.max(
    homeFuelCost(pos.x + branchLen, pos.y, pos.z),
    homeFuelCost(pos.x - branchLen, pos.y, pos.z))
  -- Also pay ~2*branchLen to walk the branch out and back.
  local need = tipCost + (2 * branchLen) + WORK_RESERVE
  local fuel = estimateFuelUnits()
  if fuel == math.huge then return true end
  if fuel < need then
    print(("Branch needs~%d fuel (have~%s) — topping at depot first."):format(need, tostring(fuel)))
    return false
  end
  return true
end

--------------------------------------------------------------------------------
-- Strip pattern
--------------------------------------------------------------------------------
local function digShaftStep()
  digDir("up")
  if not forward(true) then
    digDir("forward")
    if not forward(true) then return false end
  end
  digDir("up")
  -- Keep mined coal stacking into slot 16 while digging.
  gatherCoalToFuelSlot()
  return true
end

local function digBranch(dir, length)
  faceDir(dir)
  for i = 1, length do
    if STOP then return false end
    if not digShaftStep() then return false end
    if not maybeHome() then return false end
    if activeJob then
      activeJob.branchIdx = i
      if i % 4 == 0 then saveJob(activeJob) end
    end
  end
  faceDir((dir + 2) % 4)
  for _ = 1, length do
    if not forward(true) then return false end
  end
  faceDir(0)
  return true
end

local function runStrip(job)
  local length = math.max(1, math.floor(tonumber(job.length) or 64))
  local spacing = math.max(2, math.floor(tonumber(job.spacing) or 3))
  local branch = math.max(0, math.floor(tonumber(job.branch) or 16))
  local levels = math.max(1, math.floor(tonumber(job.levels) or 1))
  local startIdx = math.max(1, math.floor(tonumber(job.idx) or 1))
  local startLevel = math.max(0, math.floor(tonumber(job.level) or 0))

  dug, skipped = tonumber(job.dug) or dug, tonumber(job.skipped) or skipped
  print(("Strip L=%d spacing=%d branch=%d levels=%d"):format(length, spacing, branch, levels))

  -- Resume pose if we paused mid-dig for fuel.
  if job.resumeX ~= nil and job.status == "paused" then
    local rx = math.floor(tonumber(job.resumeX) or 0)
    local ry = math.floor(tonumber(job.resumeY) or 0)
    local rz = math.floor(tonumber(job.resumeZ) or 0)
    local rf = math.floor(tonumber(job.resumeFacing) or 0) % 4
    local plan, fuel, home = fuelPlanNow(0, 0, 0)
    if pos.x == 0 and pos.y == 0 and pos.z == 0 then
      suckFuel()
      plan, fuel, home = fuelPlanNow(0, 0, 0)
    end
    local need = homeFuelCost(rx, ry, rz) + WORK_RESERVE
    if fuel ~= math.huge and fuel < need then
      print(("Not enough fuel to resume dig pose (have~%s need~%d)."):format(
        tostring(fuel), need))
      job.status = "paused"
      saveJob(job)
      return "paused"
    end
    print(("Resuming @ %d,%d,%d ..."):format(rx, ry, rz))
    if not goTo(rx, ry, rz) then
      print("Could not reach resume pose.")
      job.status = "paused"
      saveJob(job)
      return "paused"
    end
    faceDir(rf)
    job.status = "active"
    job.pauseReason = nil
  end

  for level = startLevel, levels - 1 do
    if STOP then break end
    local y = level -- +Y down
    if not (pos.x == 0 and pos.z == 0 and pos.y == y) then
      if not goTo(0, y, 0) then
        print("Could not reach level Y=" .. y)
        job.status = "paused"
        saveJob(job)
        return "paused"
      end
    end
    faceDir(0)
    job.level = level
    local i0 = (level == startLevel) and startIdx or 1
    for i = i0, length do
      if STOP then break end
      job.idx = i
      job.dug, job.skipped = dug, skipped
      job.status = "active"
      if i % 2 == 0 then saveJob(job) end

      if not maybeHome() then
        return "paused"
      end

      if not digShaftStep() then
        print("Blocked on main tunnel at z=" .. tostring(pos.z))
        job.status = "paused"
        saveJob(job)
        return "paused"
      end
      if not maybeHome() then
        return "paused"
      end

      if branch > 0 and i % spacing == 0 then
        if not canAffordBranch(branch) then
          if not maybeHome({ stayHome = true }) then return "paused" end
          -- After stay-home pause, continue will resume.
          return "paused"
        end
        local bx, by, bz = pos.x, pos.y, pos.z
        job.phase = "branch_right"
        if not digBranch(1, branch) then
          job.status = "paused"; saveJob(job); return "paused"
        end
        if not goTo(bx, by, bz) then
          job.status = "paused"; saveJob(job); return "paused"
        end
        faceDir(0)
        job.phase = "branch_left"
        if not digBranch(3, branch) then
          job.status = "paused"; saveJob(job); return "paused"
        end
        if not goTo(bx, by, bz) then
          job.status = "paused"; saveJob(job); return "paused"
        end
        faceDir(0)
        job.phase = "main"
      end
    end
    if level < levels - 1 then
      goTo(0, y, 0)
      faceDir(0)
    end
    startIdx = 1
  end

  goHome()
  job.status = "done"
  job.pauseReason = nil
  job.resumeX, job.resumeY, job.resumeZ = nil, nil, nil
  job.dug, job.skipped = dug, skipped
  saveJob(job)
  print(("Strip done. dug=%d skipped=%d moves=%d"):format(dug, skipped, moves))
  return "done"
end

local function startStripJob(length, spacing, branch, levels)
  local d = saveDefaults(length, spacing, branch, levels)
  STOP = false
  local job = {
    type = "strip",
    length = d.length,
    spacing = d.spacing,
    branch = d.branch,
    levels = d.levels,
    idx = 1, level = 0, status = "active",
    dug = 0, skipped = 0,
  }
  dug, skipped, moves = 0, 0, 0
  saveJob(job)
  print(("Mining L=%d spacing=%d branch=%d levels=%d"):format(
    d.length, d.spacing, d.branch, d.levels))
  return runStrip(job)
end

local function beginMine()
  -- One command: resume a paused job, else start with saved defaults.
  local job = loadJob()
  if job and job.type == "strip" and job.status == "paused" then
    print("Resuming paused strip job...")
    STOP = false
    if pos.x ~= 0 or pos.y ~= 0 or pos.z ~= 0 then
      goHome()
    else
      suckFuel()
    end
    return runStrip(job)
  end
  if not cfg.setupDone then
    print("First run: setup (fuel LEFT, storage BEHIND)...")
    dumpToStorage()
    suckFuel()
    cfg.setupDone = true
    saveCfg()
  else
    suckFuel()
  end
  return startStripJob()
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function printHelp()
  local d = defaultsOf()
  print("Strip miner v" .. VERSION)
  print("  mine | go | start     BEGIN strip (saved defaults / resume pause)")
  print("  set <L> [sp] [br] [lv]  save defaults once")
  print(("  defaults               now L=%d sp=%d br=%d lv=%d"):format(
    d.length, d.spacing, d.branch, d.levels))
  print("  strip <L> [sp] [br] [lv]  one-off dig (also saves defaults)")
  print("  continue | resume     resume saved job after fuel pause")
  print("  home | dump | refuel | setup | stop | status | clearjob")
  print("  help | exit")
  print("Fuel: returns home before stranding; SOS if short of depot.")
end

local function handle(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = tostring(a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" or cmd == "?" then printHelp()
  elseif cmd == "status" then
    local plan, fuel, home = fuelPlanNow()
    local d = defaultsOf()
    print(("pos=%d,%d,%d face=%d dug=%d tank=%s"):format(
      pos.x, pos.y, pos.z, facing, dug, tostring(turtle.getFuelLevel())))
    print(("fuelPlan=%s est~%s homeCost~%d (margin %d + reserve %d)"):format(
      plan, tostring(fuel), home, HOME_MARGIN, WORK_RESERVE))
    print(("defaults L=%d spacing=%d branch=%d levels=%d"):format(
      d.length, d.spacing, d.branch, d.levels))
    if activeJob then
      print(("job L=%s idx=%s/%s level=%s status=%s %s"):format(
        tostring(activeJob.length), tostring(activeJob.idx),
        tostring(activeJob.length), tostring(activeJob.level),
        tostring(activeJob.status),
        activeJob.pauseReason and ("(" .. activeJob.pauseReason .. ")") or ""))
    end
  elseif cmd == "defaults" or cmd == "default" then
    local d = defaultsOf()
    print(("defaults: length=%d spacing=%d branch=%d levels=%d"):format(
      d.length, d.spacing, d.branch, d.levels))
    print("Change with: set <length> [spacing] [branch] [levels]")
    print("Then: mine")
  elseif cmd == "set" then
    if not a[2] then
      print("Usage: set <length> [spacing] [branch] [levels]")
      print("Example: set 64 3 16 1")
    else
      local d = saveDefaults(a[2], a[3], a[4], a[5])
      print(("Saved defaults L=%d spacing=%d branch=%d levels=%d"):format(
        d.length, d.spacing, d.branch, d.levels))
      print("Type  mine  to begin.")
    end
  elseif cmd == "mine" or cmd == "go" or cmd == "start" then
    beginMine()
  elseif cmd == "setup" then
    print("Fuel LEFT → slot 16; storage BEHIND; facing into mine.")
    dumpToStorage()
    suckFuel()
    cfg.setupDone = true
    saveCfg()
    print("Setup done. fuel=" .. tostring(turtle.getFuelLevel()))
  elseif cmd == "dump" then dumpToStorage()
  elseif cmd == "refuel" then suckFuel(); print("fuel=" .. tostring(turtle.getFuelLevel()))
  elseif cmd == "home" then goHome()
  elseif cmd == "stop" then STOP = true; print("Stop requested.")
  elseif cmd == "clearjob" then clearJob(); print("Job cleared.")
  elseif cmd == "strip" then
    if not a[2] then
      print("Usage: strip <length> [spacing] [branch] [levels]")
      print("Or set defaults once, then: mine")
    else
      startStripJob(a[2], a[3], a[4], a[5])
    end
  elseif cmd == "continue" or cmd == "resume" then
    STOP = false
    local job = loadJob()
    if not job or job.type ~= "strip" then
      print("No strip job saved. Use: mine")
    elseif job.status == "done" then
      print("Job already done. Use: mine")
    else
      if pos.x ~= 0 or pos.y ~= 0 or pos.z ~= 0 then
        print("Heading home to refuel before resume...")
        goHome()
      else
        suckFuel()
      end
      runStrip(job)
    end
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    print("Unknown. Type help. Quick start: set … then mine")
  end
  return true
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------
if not turtle then error("strip_miner must run on a turtle.", 0) end
loadExclude()
loadCfg()
loadJob()
os.setComputerLabel(os.getComputerLabel() or ("StripMiner-" .. os.getComputerID()))

term.clear(); term.setCursorPos(1, 1)
print("== Strip Miner v" .. VERSION .. " ==")
do
  local d = defaultsOf()
  print(("Defaults L=%d sp=%d br=%d lv=%d  →  type  mine  to dig"):format(
    d.length, d.spacing, d.branch, d.levels))
end
print("Fuel guard on.  set …  to change defaults.  help for more.")
if not cfg.setupDone then print("Tip: fuel LEFT, storage BEHIND — `mine` will setup once.") end

while true do
  write("strip> ")
  local line = read()
  local r = handle(line)
  if r == "exit" then break end
end
print("Strip miner closed.")
