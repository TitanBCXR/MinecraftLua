--[[
  quarry/workers/strip_miner.lua  -  Branch / strip mining turtle
  Titan-Version: 1.0.0

  Classic strip mine: dig a main 1×2 tunnel, then left/right branches every
  few blocks. Solo worker (no site board). Same chest layout as cell miner:

    * Fuel chest LEFT  → coal in slot 16
    * Storage BEHIND   → dump slots 1-14
    * Slot 15 = wireless modem (optional)
    * Pickaxe on RIGHT upgrade

  Place turtle at the tunnel mouth, facing into the mine (origin 0,0,0).
  +X right, +Y down, +Z forward.

  Commands:
    strip <length> [spacing] [branch] [levels]
        length  = main tunnel blocks forward (default 64)
        spacing = blocks between branch centers (default 3)
        branch  = side-tunnel length each side (default 16)
        levels  = how many Y layers down to repeat (default 1)
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
local MIN_FUEL = 200
local VERSION = "1.0.0"

local STOP = false
local dug, skipped, moves = 0, 0, 0
local pos = { x = 0, y = 0, z = 0 }
local facing = 0 -- 0=+Z, 1=+X, 2=-Z, 3=-X
local cfg = { setupDone = false }
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
  if ok and type(data) == "table" then cfg = data end
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

local function ensureFuel()
  if turtle.getFuelLevel() == "unlimited" then return true end
  if turtle.getFuelLevel() >= MIN_FUEL then return true end
  turtle.select(FUEL_SLOT)
  if turtle.refuel(0) or turtle.getItemCount(FUEL_SLOT) > 0 then
    turtle.refuel()
  end
  for s = 1, 16 do
    if turtle.getFuelLevel() >= MIN_FUEL then return true end
    if s ~= FUEL_SLOT then
      turtle.select(s)
      if turtle.refuel(0) then turtle.refuel() end
    end
  end
  return turtle.getFuelLevel() > 0
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

local function excavateHere()
  digDir("up")
end

local function inventoryFull()
  for s = 1, 14 do
    if turtle.getItemCount(s) == 0 then return false end
  end
  return true
end

local function dumpToStorage()
  faceDir(2) -- back toward origin storage
  -- Face world -Z from origin facing; storage is behind start → face 2 from origin facing 0
  for s = 1, 14 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      turtle.drop()
    end
  end
  faceDir(0)
end

local function suckFuel()
  faceDir(3) -- left
  turtle.select(FUEL_SLOT)
  for _ = 1, 64 do
    if not turtle.suck() then break end
  end
  turtle.refuel()
  faceDir(0)
end

local function goHome()
  goTo(0, 0, 0)
  faceDir(0)
  dumpToStorage()
  suckFuel()
end

local function maybeHome()
  if inventoryFull() or (turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < MIN_FUEL) then
    local rx, ry, rz, rf = pos.x, pos.y, pos.z, facing
    goHome()
    if not goTo(rx, ry, rz) then return false end
    faceDir(rf)
  end
  return true
end

--------------------------------------------------------------------------------
-- Strip pattern
--------------------------------------------------------------------------------
-- Dig one block forward with headroom (1×2), then optional side branches.
local function digShaftStep()
  digDir("up")
  if not forward(true) then
    digDir("forward")
    if not forward(true) then return false end
  end
  digDir("up")
  return true
end

local function digBranch(dir, length)
  -- dir: 1 = right (+X when facing +Z), 3 = left
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
  -- Return to spine
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

  for level = startLevel, levels - 1 do
    if STOP then break end
    local y = level -- +Y down
    if not goTo(0, y, 0) then
      print("Could not reach level Y=" .. y)
      break
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

      if not digShaftStep() then
        print("Blocked on main tunnel at z=" .. tostring(pos.z))
        job.status = "paused"
        saveJob(job)
        return "paused"
      end
      if not maybeHome() then
        job.status = "paused"
        saveJob(job)
        return "paused"
      end

      -- Branch at every `spacing` along the main tunnel (skip z=0 mouth).
      if branch > 0 and i % spacing == 0 then
        local bx, by, bz = pos.x, pos.y, pos.z
        job.phase = "branch_right"
        if not digBranch(1, branch) then
          job.status = "paused"; saveJob(job); return "paused"
        end
        goTo(bx, by, bz); faceDir(0)
        job.phase = "branch_left"
        if not digBranch(3, branch) then
          job.status = "paused"; saveJob(job); return "paused"
        end
        goTo(bx, by, bz); faceDir(0)
        job.phase = "main"
      end
    end
    -- Drop to next level under the mouth for the next strip floor.
    if level < levels - 1 then
      goTo(0, y, 0)
      faceDir(0)
    end
  end

  goHome()
  job.status = "done"
  job.dug, job.skipped = dug, skipped
  saveJob(job)
  print(("Strip done. dug=%d skipped=%d moves=%d"):format(dug, skipped, moves))
  return "done"
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function printHelp()
  print("Strip miner v" .. VERSION)
  print("  strip <length> [spacing] [branch] [levels]")
  print("      e.g. strip 64 3 16     main 64, branch every 3, 16 long")
  print("      e.g. strip 128 3 20 2  two levels deep")
  print("  continue | resume   resume saved job")
  print("  home | dump | refuel | setup | stop | status | clearjob")
  print("  help | exit")
end

local function handle(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = tostring(a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" or cmd == "?" then printHelp()
  elseif cmd == "status" then
    print(("pos=%d,%d,%d face=%d dug=%d fuel=%s"):format(
      pos.x, pos.y, pos.z, facing, dug, tostring(turtle.getFuelLevel())))
    if activeJob then
      print(("job L=%s idx=%s/%s level=%s status=%s"):format(
        tostring(activeJob.length), tostring(activeJob.idx),
        tostring(activeJob.length), tostring(activeJob.level),
        tostring(activeJob.status)))
    end
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
    STOP = false
    local job = {
      type = "strip",
      length = tonumber(a[2]) or 64,
      spacing = tonumber(a[3]) or 3,
      branch = tonumber(a[4]) or 16,
      levels = tonumber(a[5]) or 1,
      idx = 1, level = 0, status = "active",
      dug = 0, skipped = 0,
    }
    dug, skipped, moves = 0, 0, 0
    saveJob(job)
    runStrip(job)
  elseif cmd == "continue" or cmd == "resume" then
    STOP = false
    local job = loadJob()
    if not job or job.type ~= "strip" then
      print("No strip job saved.")
    elseif job.status == "done" then
      print("Job already done.")
    else
      runStrip(job)
    end
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    print("Unknown. Type help.")
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
print("Branch mining worker. Type help.")
if not cfg.setupDone then print("Tip: run `setup` at the tunnel mouth first.") end

while true do
  write("strip> ")
  local line = read()
  local r = handle(line)
  if r == "exit" then break end
end
print("Strip miner closed.")
