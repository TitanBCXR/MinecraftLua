--[[
  offline_miner.lua  -  Local quarry turtle (no GPS / no network)
  Titan-Version: 1.0.2

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

  Commands (sizes as WxH or WxHxD — zeros are just placeholders in the docs):
    box <W>x<H>x<D> [column|layer]
    tunnel <L>x<H> [W]       1-wide (or W-wide) tunnel, length forward, height tall
    stair <W>x<steps> <up|down>
                             stepped ramp; width across, steps along facing
    pattern [column|layer]   show / set default box dig pattern
    home                     return to 0,0,0 facing start
    dump | refuel | setup | stop | status | help

  Optional: exclude.txt (same format as the network miner) — never break those.

  No modem / lib / Parent Center required. Run:  offline_miner
]]

local CFG = "offline_miner.cfg"
local EXCLUDE = "exclude.txt"
local FUEL_SLOT = 16
local MIN_FUEL = 200
local STOP = false

-- Relative pose from boot origin. +Y is DOWN.
local pos = { x = 0, y = 0, z = 0 }
local facing = 0   -- 0=+Z forward, 1=+X right, 2=-Z back, 3=-X left
local dug = 0
local skipped = 0
local job = "-"

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

local function goHome()
  job = "home"
  local ok, err = goTo(0, 0, 0)
  faceForward()
  return ok, err
end

local function manageInventory(resume)
  if not inventoryFull() and ensureFuel() then return true end
  print("Inventory/fuel break — returning to origin...")
  local rx, ry, rz = pos.x, pos.y, pos.z
  if not goHome() then return false, "home" end
  dumpToStorage()
  suckFuelFromLeft()
  if resume then
    print(("Resuming @ %d,%d,%d"):format(rx, ry, rz))
    if not goTo(rx, ry, rz) then return false, "resume" end
  end
  return true
end

-- Dig H blocks downward from the current cell, then climb back to the top.
local function digDownColumn(H)
  for i = 1, H do
    if STOP then return false end
    if not manageInventory(true) then return false end
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
    if STOP then return false end
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
-- Jobs
--------------------------------------------------------------------------------
-- Column pattern: at each (x,z), dig the full vertical shaft, then next cell.
local function digBoxColumn(W, H, D)
  for z = 0, D - 1 do
    if STOP then break end
    local xStart, xEnd, xStep = 0, W - 1, 1
    if z % 2 == 1 then xStart, xEnd, xStep = W - 1, 0, -1 end
    for x = xStart, xEnd, xStep do
      if STOP then break end
      if not manageInventory(true) then return false, "inventory/fuel" end
      if not goTo(x, 0, z) then return false, "path blocked" end
      local ok, err = digDownColumn(H)
      if not ok then return false, err or "column" end
    end
  end
  return true
end

-- Layer pattern: clear each horizontal slice from the top down, then drop one.
local function digBoxLayer(W, H, D)
  for y = 0, H - 1 do
    if STOP then break end
    print(("  layer %d / %d"):format(y + 1, H))
    for z = 0, D - 1 do
      if STOP then break end
      -- Alternate snake per layer and per row for shorter walks.
      local xStart, xEnd, xStep = 0, W - 1, 1
      if (z + y) % 2 == 1 then xStart, xEnd, xStep = W - 1, 0, -1 end
      for x = xStart, xEnd, xStep do
        if STOP then break end
        if not manageInventory(true) then return false, "inventory/fuel" end
        if not goTo(x, y, z) then return false, "path blocked" end
        digDir("down")
      end
    end
    if y < H - 1 and not STOP then
      -- Drop onto the next layer (prefer returning toward x=0,z=0 first).
      if not goTo(0, y, 0) then return false, "layer drop path" end
      if not moveDown() then return false, "layer drop" end
    end
  end
  return true
end

-- Box WxHxD: width (+X), height (+Y down), depth (+Z forward)
-- opts.pattern overrides cfg.pattern for this run.
local function digBox(W, H, D, opts)
  opts = opts or {}
  W, H, D = math.floor(W), math.floor(H), math.floor(D)
  if W < 1 or H < 1 or D < 1 then
    print("Usage: box <W>x<H>x<D> [column|layer]")
    return
  end
  local pattern = normalizePattern(opts.pattern) or normalizePattern(cfg.pattern) or "column"
  STOP = false
  dug, skipped = 0, 0
  job = ("box %dx%dx%d %s"):format(W, H, D, pattern)
  print(("BOX %dx%dx%d  pattern=%s  (right / down / forward)"):format(W, H, D, pattern))
  if not goHome() then print("Could not reach origin."); return end

  local ok, err
  if pattern == "layer" then
    ok, err = digBoxLayer(W, H, D)
  else
    ok, err = digBoxColumn(W, H, D)
  end
  if not ok then
    print("Abort: " .. tostring(err or "?"))
    goHome()
    dumpToStorage()
    suckFuelFromLeft()
    job = "idle"
    return
  end

  goHome()
  dumpToStorage()
  suckFuelFromLeft()
  job = "idle"
  print(("Done. dug=%d skipped=%d fuel=%s"):format(dug, skipped, tostring(turtle.getFuelLevel())))
end

-- Tunnel LxH [W]: length forward, height tall, optional width (default 1)
local function digTunnel(L, H, W)
  L, H = math.floor(L), math.floor(H)
  W = math.floor(tonumber(W) or 1)
  if L < 1 or H < 1 or W < 1 then
    print("Usage: tunnel <L>x<H> [W]  (length forward, height, optional width)")
    return
  end
  STOP = false
  dug, skipped = 0, 0
  job = ("tunnel %dx%dx%d"):format(L, H, W)
  print(("TUNNEL length=%d height=%d width=%d"):format(L, H, W))
  if not goHome() then print("Could not reach origin."); return end

  for z = 0, L - 1 do
    if STOP then break end
    local xStart, xEnd, xStep = 0, W - 1, 1
    if z % 2 == 1 and W > 1 then xStart, xEnd, xStep = W - 1, 0, -1 end
    for x = xStart, xEnd, xStep do
      if STOP then break end
      if not manageInventory(true) then print("Abort: inventory/fuel."); return end
      if not goTo(x, 0, z) then print("Abort: path."); return end
      if not clearHeadroom(H) then print("Abort: headroom."); goHome(); return end
    end
  end

  goHome()
  dumpToStorage()
  suckFuelFromLeft()
  job = "idle"
  print(("Done. dug=%d skipped=%d fuel=%s"):format(dug, skipped, tostring(turtle.getFuelLevel())))
end

-- Stair WxSteps up|down — each step: clear W-wide x 2-high tread, then forward + up/down
local function digStair(W, steps, dir)
  W, steps = math.floor(W), math.floor(steps)
  dir = tostring(dir or "down"):lower()
  if (dir ~= "up" and dir ~= "down") or W < 1 or steps < 1 then
    print("Usage: stair <W>x<steps> <up|down>")
    return
  end
  STOP = false
  dug, skipped = 0, 0
  job = ("stair %dx%d %s"):format(W, steps, dir)
  print(("STAIR width=%d steps=%d dir=%s"):format(W, steps, dir))
  if not goHome() then print("Could not reach origin."); return end

  for s = 0, steps - 1 do
    if STOP then break end
    if not manageInventory(true) then print("Abort: inventory/fuel."); return end
    local y = (dir == "down") and s or -s
    local z = s
    for x = 0, W - 1 do
      if STOP then break end
      if not goTo(x, y, z) then print("Abort: path."); goHome(); return end
      digDir("up")
      digDir("down")
    end
    if s < steps - 1 then
      if not goTo(0, y, z) then print("Abort."); return end
      faceForward()
      if not moveForward() then print("Abort: forward."); return end
      if dir == "down" then
        if not moveDown() then print("Abort: down."); return end
      else
        if not moveUp() then print("Abort: up."); return end
      end
    end
  end

  goHome()
  dumpToStorage()
  suckFuelFromLeft()
  job = "idle"
  print(("Done. dug=%d skipped=%d fuel=%s"):format(dug, skipped, tostring(turtle.getFuelLevel())))
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
  print("    column = full shafts, then next cell")
  print("    layer  = each slice top→bottom, then drop")
  print("  tunnel <L>x<H> [W]               corridor (default W=1)")
  print("  stair <W>x<steps> <up|down>      staircase")
  print("  home | dump | refuel | setup | stop | status")
  print("")
  print("First boot auto-runs setup: fuel LEFT → slot 16, storage BEHIND.")
end

local function printStatus()
  print(("pos=%d,%d,%d face=%d job=%s"):format(pos.x, pos.y, pos.z, facing, job))
  print(("dug=%d skipped=%d fuel=%s"):format(dug, skipped, tostring(turtle.getFuelLevel())))
  print(("setup=%s  pattern=%s"):format(tostring(cfg.setupDone), tostring(cfg.pattern or "column")))
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
    print("Stop requested.")
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
      local W = d[3] or tonumber(a[#a])
      if W and #d == 2 and tonumber(a[3]) and not tostring(a[2]):find("x") then
        -- tunnel 20 3 2 style already in d
      end
      if #d >= 3 then
        digTunnel(d[1], d[2], d[3])
      else
        -- optional trailing W as separate token: tunnel 20x3 2
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
  -- Still top up fuel on boot
  suckFuelFromLeft()
  print("Fuel: " .. tostring(turtle.getFuelLevel()))
end

print("")
print("Type help. Examples:")
print("  box 9x5x9")
print("  tunnel 32x3")
print("  stair 3x20 down")
print("")

while true do
  write("mine> ")
  local line = read()
  local r = handleCommand(line)
  if r == "exit" then break end
end

print("Offline miner stopped.")
