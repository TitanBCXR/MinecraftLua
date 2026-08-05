--[[
  miner.lua  -  Area miner turtle for the Titan network (CC: Tweaked)
  Titan-Version: 1.2.7

  Digs a rectangular "box":
    * set1 <x> <z> / set2 <x> <z> — opposite corners (X/Z footprint)
    * ystart / yend — vertical range (mine from start Y down to end Y)
    * sety <start> <end> — set both Y levels at once
    * home / start — return point; chest is one block BEHIND home (auto)
    * mine — start (writes miner_job.cfg with corners + Y + init pos)
    * continue — resume after unload/reboot from GPS / saved progress

  Never breaks blocks listed in exclude.txt (or titan.RESTRICTED).

  Fresh miners wait for Parent Center deploy:
    deploy <id> miner <name> [depX depY depZ]

  Then: set1 <x> <z> / set2 <x> <z> / sety <ystart> <yend> / home / mine

  NETWORK: joins the Titan mesh; status+assignment go to botserver + datacenter.

  Requires: wireless modem, fuel, GPS constellation, lib/titan.lua.
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

local cfg = {
  name = nil,
  botType = "miner",
  loc1 = nil,       -- opposite corner A (X/Z box; Y ignored for depth)
  loc2 = nil,       -- opposite corner B
  yStart = nil,     -- starting (top) Y level, inclusive
  yEnd = nil,       -- ending (bottom) Y level, inclusive
  floorY = nil,     -- legacy alias for yEnd (migrated on load)
  deposit = nil,    -- legacy: stand above chest and dropDown (optional)
  chest = nil,      -- {x,y,z} chest block (default: one block behind home)
  home = nil,       -- start / return point (face the mine; chest behind)
  homeFacing = nil, -- titan.NORTH/EAST/SOUTH/WEST when home was set
}

local state = {
  status = "idle",
  task   = "-",
  stop   = false,
  dug    = 0,
  skipped = 0,
}
local mineRequested = false
local continueRequested = false

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
  if state.status == "mining" or state.status == "moving" then
    return state.task or "mining"
  end
  local topY, floorY = yRange()
  if cfg.loc1 and cfg.loc2 and topY then
    return ("box Y%d->%d dug=%d"):format(topY, floorY, state.dug or 0)
  end
  return state.task or "unconfigured"
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
    return false, "excluded:" .. data.name
  end
  if dig() then
    state.dug = state.dug + 1
    return true, data.name
  end
  return false, "dig failed"
end

local function invFull()
  for s = 1, 16 do
    if turtle.getItemCount(s) == 0 then return false end
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

local function dumpInventory()
  local chest = ensureChest()
  local fuelSlot = nav.FUEL_SLOT or 16

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
    for s = 1, 16 do
      if s ~= fuelSlot then
        turtle.select(s)
        turtle.drop()
      end
    end
    turtle.select(1)
    -- Face back toward the mine for the next trip out.
    if cfg.homeFacing ~= nil then pcall(nav.face, cfg.homeFacing) end
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
    for s = 1, 16 do
      if s ~= fuelSlot then
        turtle.select(s)
        turtle.dropDown()
      end
    end
    turtle.select(1)
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
  end
  return true
end

local function ensureFuel()
  nav.ensureFuel(64)
  if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 8 then
    setStatus("error", "out of fuel")
    return false
  end
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
  if turtle.down() then return true end
  turtle.attackDown()
  if turtle.down() then return true end
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

  for y = resumeY, b.floorY, -1 do
    if state.stop then break end
    setStatus("mining", ("layer Y=%d"):format(y))
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

      local ok, err = nav.moveTo(x, y, z, { dig = true })
      if not ok then
        print("moveTo failed: " .. tostring(err) .. " — trying cell-by-cell")
      end
      touchJobProgress(job, y, z, zDir, x)

      nav.face(zDir == 1 and titan.EAST or titan.WEST)

      while true do
        if state.stop then break end
        if not ensureFuel() or not ensureSpace() then
          touchJobProgress(job, y, z, zDir, x)
          setStatus("error", state.task)
          return false
        end

        local cx = nav.locate(1)
        if not cx then
          touchJobProgress(job, y, z, zDir, x)
          print("Lost GPS"); setStatus("error", "no GPS"); return false
        end

        if (step == 1 and x >= endX) or (step == -1 and x <= endX) then
          break
        end

        local moved, why = stepForward()
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
                nav.moveTo(x, y, z, { dig = true })
                nav.face(step == 1 and titan.EAST or titan.WEST)
              end
            else
              x = x + step
              nav.moveTo(x, y, z, { dig = true })
              nav.face(step == 1 and titan.EAST or titan.WEST)
            end
          else
            print("Blocked: " .. tostring(why))
            x = x + step
            nav.moveTo(x, y, z, { dig = true })
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
    job.finished = os.epoch("utc")
    job.dug, job.skipped = state.dug, state.skipped
    saveJob(job)
    setStatus("idle", ("done dug=%d skipped=%d"):format(state.dug, state.skipped))
    print(("Mine finished. dug=%d skipped=%d"):format(state.dug, state.skipped))
  end
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
  if cfg.deposit then print(("deposit (legacy): %s"):format(fmt(cfg.deposit))) end
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
  local job = loadJob()
  if job and job.active ~= false then
    print(("job: ACTIVE  progress Y=%s Z=%s X=%s  (continue to resume)"):format(
      tostring(job.y), tostring(job.z), tostring(job.x)))
    if job.init then print("job init: " .. fmt(job.init)) end
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
    print("  chest          show / recompute behind home")
    print("  chest <x y z>  set chest block manually")
    print("  deposit        legacy: stand ABOVE a chest (dropDown)")
    print("  exclude   reload & show exclude.txt")
    print("  mine      dig the box (saves miner_job.cfg)")
    print("  continue  resume after unload/reboot from GPS/job")
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
  elseif cmd == "chest" then
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
    elseif not quarryReady() then
      print("Box incomplete. Need set1, set2, and sety <start> <end>.")
      printStatus()
    else
      mineVolume()
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
  local name = d.name
  if not name or name == "" then name = "Miner-" .. os.getComputerID() end
  print(("Deploying as miner '%s'..."):format(name))
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
  os.setComputerLabel(os.getComputerLabel() or ("miner-" .. os.getComputerID()))
  print("Unconfigured miner. Waiting for Parent Center deploy...")
  print("  deploy <id> miner <name> [depX depY depZ]")
  local beacon = os.startTimer(0)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "timer" and p1 == beacon then
      local x, y, z = nav.locate(1)
      titan.broadcast(MSG.WORKER_AWAIT, {
        name = os.getComputerLabel(), kind = "miner", x = x, y = y, z = z,
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
  titan.broadcast(MSG.BOT_REGISTER, {
    name = cfg.name or os.getComputerLabel(),
    botType = "miner", home = cfg.home or nav.home,
  })
  while true do
    local x, y, z = nav.locate(1)
    local fix = nav.lastFix
    local asg = assignmentText()
    titan.broadcast(MSG.STATUS, {
      name = cfg.name or os.getComputerLabel(),
      status = state.status,
      task   = state.task,
      assignment = asg,
      x = x, y = y, z = z,
      yLo = fix and fix.yLo, yHi = fix and fix.yHi,
      gpsN = fix and fix.n, gpsSpreadY = fix and fix.spreadY,
      fuel   = turtle.getFuelLevel(),
      dug    = state.dug,
      botType = "miner",
    })
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
        elseif cmd == "dump" then
          dumpInventory()
          titan.send(id, MSG.ACK, { ok = true, task = "dump" })
        end
      elseif t == MSG.WORKER_DEPLOY then
        local ok, why = applyDeployment(msg)
        titan.send(id, MSG.WORKER_DEPLOYED, {
          ok = ok, err = why, name = cfg.name, botType = "miner",
        })
      elseif t == MSG.PING then
        titan.send(id, MSG.PONG, {
          state = state.status, botType = "miner",
          name = cfg.name or os.getComputerLabel(),
          assignment = assignmentText(),
        })
      end
    end
  end
end

local function jobLoop()
  while true do
    if mineRequested and state.status ~= "mining" then
      mineRequested = false
      mineVolume()
    elseif continueRequested and state.status ~= "mining" then
      continueRequested = false
      continueMine()
    end
    sleep(0.4)
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
end
setStatus("idle", "-")

parallel.waitForAny(
  consoleLoop,
  statusLoop,
  receiveLoop,
  jobLoop,
  function() titan.networkLoop("miner") end
)
print("Miner stopped.")
