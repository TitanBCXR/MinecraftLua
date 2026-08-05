--[[
  miner.lua  -  Area miner turtle for the Titan network (CC: Tweaked)
  Titan-Version: 1.1.0

  Digs a rectangular volume defined by two corner positions and a floor Y.
  Never breaks blocks listed in exclude.txt (or titan.RESTRICTED).

  Setup (console):
    set1              mark location 1 at current GPS position
    set2              mark location 2 at current GPS position
    sety <y>          floor Y to dig down to (inclusive)
    deposit           mark current position as the dump chest (stand ABOVE it)
    exclude           show exclude.txt contents
    mine              start mining the volume
    stop              abort the current mine job
    status            show config + progress
    home              return to deposit / home

  exclude.txt (next to this program): one block id per line, # for comments.
  Edit it on the turtle or copy a template from the install host.

  NETWORK: joins the Titan routing mesh (announce + hop relay) so quarry status
  and remote commands can hop through nearby builders/gatherers/routers.

  Requires: wireless modem, fuel, GPS constellation, lib/titan.lua.
]]

local titan = dofile("lib/titan.lua")
local nav   = titan.nav

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Miner-" .. os.getComputerID()))

local CFG     = "miner.cfg"
local EXCLUDE = "exclude.txt"

local cfg = {
  loc1 = nil,       -- {x,y,z} corner 1
  loc2 = nil,       -- {x,y,z} corner 2
  floorY = nil,     -- dig down to this Y (inclusive)
  deposit = nil,    -- {x,y,z} stand above chest and dropDown
  home = nil,       -- start / return point
}

local state = {
  status = "idle",
  task   = "-",
  stop   = false,
  dug    = 0,
  skipped = 0,
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
end

local function saveCfg()
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

--------------------------------------------------------------------------------
-- Bounds from loc1 / loc2
--------------------------------------------------------------------------------
local function bounds()
  if not cfg.loc1 or not cfg.loc2 or cfg.floorY == nil then return nil end
  local x1, z1 = cfg.loc1.x, cfg.loc1.z
  local x2, z2 = cfg.loc2.x, cfg.loc2.z
  local topY = math.max(cfg.loc1.y, cfg.loc2.y)
  return {
    minX = math.min(x1, x2), maxX = math.max(x1, x2),
    minZ = math.min(z1, z2), maxZ = math.max(z1, z2),
    topY = topY,
    floorY = cfg.floorY,
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

local function dumpInventory()
  if not cfg.deposit then
    print("No deposit set. Use `deposit` while standing above a chest.")
    return false
  end
  setStatus("depositing", "dumping to " .. fmt(cfg.deposit))
  local ok, err = nav.travelTo(cfg.deposit.x, cfg.deposit.y, cfg.deposit.z)
  if not ok then
    print("Could not reach deposit: " .. tostring(err))
    return false
  end
  for s = 1, 16 do
    turtle.select(s)
    turtle.dropDown()
  end
  turtle.select(1)
  return true
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
-- Quarry: layer by layer, serpentine X/Z within bounds, down to floorY
--------------------------------------------------------------------------------
local function mineVolume()
  local b = bounds()
  if not b then
    print("Set loc1, loc2, and floor Y first (set1 / set2 / sety).")
    return false
  end
  if b.floorY > b.topY then
    print(("floorY (%d) is above the area top (%d)."):format(b.floorY, b.topY))
    return false
  end

  loadExclude()
  state.stop = false
  state.dug, state.skipped = 0, 0
  setStatus("mining", ("quarry %d..%d,%d..%d Y%d->%d"):format(
    b.minX, b.maxX, b.minZ, b.maxZ, b.topY, b.floorY))

  -- Remember home if not set
  if not cfg.home then
    local x, y, z = nav.locate(2)
    if x then cfg.home = { x = x, y = y, z = z }; saveCfg() end
  end

  if nav.heading == nil then
    local ok, err = nav.calibrate(true)
    if not ok then
      print("Calibrate failed: " .. tostring(err))
      setStatus("error", "calibrate failed")
      return false
    end
  end

  for y = b.topY, b.floorY, -1 do
    if state.stop then break end
    setStatus("mining", ("layer Y=%d"):format(y))
    print(("--- Layer Y=%d ---"):format(y))

    local zDir = 1
    local z = b.minZ
    while z <= b.maxZ do
      if state.stop then break end

      -- Start of this Z-row: travel to the entry corner for this row
      local startX = (zDir == 1) and b.minX or b.maxX
      local endX   = (zDir == 1) and b.maxX or b.minX
      local ok, err = nav.moveTo(startX, y, z, { dig = true })
      if not ok then
        -- If destination cell is excluded bedrock-like, skip the row cell by cell
        print("moveTo failed: " .. tostring(err) .. " — trying cell-by-cell")
      end

      -- Face along the row
      nav.face(zDir == 1 and titan.EAST or titan.WEST)

      local x = startX
      local step = zDir  -- +1 east, -1 west for X
      while true do
        if state.stop then break end
        if not ensureFuel() or not ensureSpace() then
          setStatus("error", state.task)
          return false
        end

        -- Dig the column we're standing in (down already handled by being at y)
        -- Also clear above/below slightly if something dropped? just clear forward path.
        local cx, cy, cz = nav.locate(1)
        if not cx then
          print("Lost GPS"); setStatus("error", "no GPS"); return false
        end

        -- We're done with this row when we've covered endX
        if (step == 1 and x >= endX) or (step == -1 and x <= endX) then
          break
        end

        local moved, why = stepForward()
        if not moved then
          if tostring(why):find("^excluded") then
            -- Skip past excluded block: try to go around via dig-up path or jump Z
            print("Skip excluded at row: " .. tostring(why))
            -- Attempt: dig up, forward over, down — only if air/safe
            tryDig("up")
            if turtle.up() then
              local ok2 = turtle.forward()
              if ok2 then
                tryDig("down")
                turtle.down()
                x = x + step
              else
                turtle.down()
                -- give up on this cell; advance logical x and try nav.moveTo next
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
      end

      z = z + 1
      zDir = -zDir
    end

    -- Drop to next layer (unless this was the floor)
    if y > b.floorY and not state.stop then
      local okd, whyd = goDownOne()
      if not okd and not tostring(whyd):find("^excluded") then
        print("Could not descend: " .. tostring(whyd))
      end
    end
  end

  -- Dump leftovers and return home
  if cfg.deposit then dumpInventory() end
  if cfg.home then
    setStatus("returning", "home")
    nav.travelTo(cfg.home.x, cfg.home.y, cfg.home.z)
  end

  setStatus(state.stop and "stopped" or "idle",
    ("done dug=%d skipped=%d"):format(state.dug, state.skipped))
  print(("Mine finished. dug=%d skipped=%d"):format(state.dug, state.skipped))
  return true
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function printStatus()
  print(("status: %s  task: %s"):format(state.status, state.task))
  print(("loc1: %s"):format(fmt(cfg.loc1)))
  print(("loc2: %s"):format(fmt(cfg.loc2)))
  print(("floorY: %s"):format(tostring(cfg.floorY)))
  print(("deposit: %s"):format(fmt(cfg.deposit)))
  print(("home: %s"):format(fmt(cfg.home)))
  local b = bounds()
  if b then
    local cells = (b.maxX - b.minX + 1) * (b.maxZ - b.minZ + 1) * (b.topY - b.floorY + 1)
    print(("volume: %dx%dx%d (~%d cells)"):format(
      b.maxX - b.minX + 1, b.maxZ - b.minZ + 1, b.topY - b.floorY + 1, cells))
  end
  print(("dug=%d skipped=%d fuel=%s"):format(
    state.dug, state.skipped, tostring(turtle.getFuelLevel())))
end

local function markHere(field)
  local x, y, z = nav.locate(2)
  if not x then print("No GPS signal."); return end
  cfg[field] = { x = x, y = y, z = z }
  saveCfg()
  print(("%s set to %s"):format(field, fmt(cfg[field])))
end

local function consoleLoop()
  print(("Titan miner #%d. Type 'help'."):format(os.getComputerID()))
  printStatus()
  while true do
    write("miner> ")
    local a = {}
    for word in tostring(read()):gmatch("%S+") do a[#a + 1] = word end
    local cmd = (a[1] or ""):lower()

    if cmd == "" then
      -- ignore
    elseif cmd == "help" then
      print("set1 / set2     mark corners at current GPS")
      print("sety <y>        floor Y to dig down to")
      print("deposit         stand ABOVE a chest; dump inventory here")
      print("home            mark current pos as return point")
      print("exclude         reload & show exclude.txt")
      print("mine            start quarrying the volume")
      print("stop            abort mining")
      print("status          show config / progress")
      print("goto <x> <y> <z>")
      print("dump            travel to deposit and drop inventory")
      print("hostname [name] get or set network hostname")
      print("exit")
    elseif cmd == "hostname" or cmd == "host" then
      if not a[2] then
        print("hostname: " .. (os.getComputerLabel() or "?"))
      else
        local name, err = titan.setHostname(table.concat(a, " ", 2), "miner")
        if name then print("hostname set: " .. name) else print(tostring(err)) end
      end
    elseif cmd == "set1" then
      markHere("loc1")
    elseif cmd == "set2" then
      markHere("loc2")
    elseif cmd == "sety" then
      local y = tonumber(a[2])
      if not y then print("Usage: sety <y>"); else
        cfg.floorY = math.floor(y); saveCfg()
        print("floorY = " .. cfg.floorY)
      end
    elseif cmd == "deposit" then
      markHere("deposit")
    elseif cmd == "home" then
      markHere("home")
    elseif cmd == "exclude" then
      loadExclude()
      print("Excluded blocks:")
      local n = 0
      for name in pairs(exclude) do print("  " .. name); n = n + 1 end
      if n == 0 then print("  (none — edit exclude.txt)") end
      print("(also respects titan.RESTRICTED / computercraft:*)")
    elseif cmd == "status" then
      printStatus()
    elseif cmd == "mine" then
      if state.status == "mining" then print("Already mining."); else
        -- run mine in this coroutine so stop can interrupt via flag
        mineVolume()
      end
    elseif cmd == "stop" then
      state.stop = true
      print("Stop requested.")
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
      return
    else
      print("Unknown: " .. cmd)
    end
  end
end

--------------------------------------------------------------------------------
-- Status broadcast (so hub/router can see the miner)
--------------------------------------------------------------------------------
local function statusLoop()
  while true do
    local x, y, z = nav.locate(1)
    titan.broadcast(titan.MSG.STATUS, {
      status = state.status,
      task   = state.task,
      x = x, y = y, z = z,
      fuel   = turtle.getFuelLevel(),
      dug    = state.dug,
      botType = "miner",
    })
    sleep(5)
  end
end

--------------------------------------------------------------------------------
loadCfg()
loadExclude()
if cfg.home then nav.home = cfg.home end

-- First-run hint
if not cfg.loc1 or not cfg.loc2 or cfg.floorY == nil then
  print("Miner not fully configured yet.")
  print("  1) Walk to corner 1 → set1")
  print("  2) Walk to corner 2 → set2")
  print("  3) sety <floorY>   (e.g. sety -59)")
  print("  4) Stand above a chest → deposit")
  print("  5) Edit exclude.txt, then → mine")
  print("")
end

-- networkLoop: register with the router + relay hops (excavator is a mesh peer).
parallel.waitForAny(
  consoleLoop,
  statusLoop,
  function() titan.networkLoop("miner") end
)
print("Miner stopped.")
