--[[
  miner.lua  -  Area miner turtle for the Titan network (CC: Tweaked)
  Titan-Version: 1.2.3

  Digs a rectangular "box":
    * set1 / set2  — opposite corners (defines the X/Z footprint)
    * ystart / yend — vertical range (mine from start Y down to end Y)
    * sety <start> <end> — set both Y levels at once

  Never breaks blocks listed in exclude.txt (or titan.RESTRICTED).

  Fresh miners wait for Parent Center deploy:
    deploy <id> miner <name> [depX depY depZ]

  Then: set1 / set2 / sety <ystart> <yend> / deposit / mine

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
local EXCLUDE = "exclude.txt"

local cfg = {
  name = nil,
  botType = "miner",
  loc1 = nil,       -- opposite corner A (X/Z box; Y ignored for depth)
  loc2 = nil,       -- opposite corner B
  yStart = nil,     -- starting (top) Y level, inclusive
  yEnd = nil,       -- ending (bottom) Y level, inclusive
  floorY = nil,     -- legacy alias for yEnd (migrated on load)
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
local mineRequested = false

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
  local fuelSlot = nav.FUEL_SLOT or 16
  for s = 1, 16 do
    if s ~= fuelSlot then
      turtle.select(s)
      turtle.dropDown()
    end
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
-- Quarry: layer by layer, serpentine X/Z in the corner box, yStart -> yEnd
--------------------------------------------------------------------------------
local function mineVolume()
  local b = bounds()
  if not b then
    print("Define the box first:")
    print("  set1 / set2     opposite corners (X/Z)")
    print("  sety <startY> <endY>   or   ystart <y> / yend <y>")
    return false
  end

  loadExclude()
  state.stop = false
  state.dug, state.skipped = 0, 0
  setStatus("mining", ("box %d..%d,%d..%d Y%d->%d"):format(
    b.minX, b.maxX, b.minZ, b.maxZ, b.topY, b.floorY))
  print(("Mining box  X %d..%d  Z %d..%d  Y %d -> %d"):format(
    b.minX, b.maxX, b.minZ, b.maxZ, b.topY, b.floorY))

  -- Remember home if not set
  if not cfg.home then
    local x, y, z = nav.locatePrecise(3)
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
  print(("corner1 (set1): %s"):format(fmt(cfg.loc1)))
  print(("corner2 (set2): %s"):format(fmt(cfg.loc2)))
  local topY, floorY = yRange()
  if topY then
    print(("Y range: start=%d  end=%d  (mine high -> low)"):format(topY, floorY))
  else
    print(("Y range: start=%s  end=%s"):format(
      tostring(cfg.yStart or "?"), tostring(cfg.yEnd or cfg.floorY or "?")))
  end
  print(("deposit: %s"):format(fmt(cfg.deposit)))
  print(("home: %s"):format(fmt(cfg.home)))
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
end

local function markHere(field)
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
  if (field == "loc1" or field == "loc2") and cfg.loc1 and cfg.loc2 then
    print(("X/Z box: %d..%d , %d..%d"):format(
      math.min(cfg.loc1.x, cfg.loc2.x), math.max(cfg.loc1.x, cfg.loc2.x),
      math.min(cfg.loc1.z, cfg.loc2.z), math.max(cfg.loc1.z, cfg.loc2.z)))
    print("Next: sety <startY> <endY>  (or ystart / yend)")
  end
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

local function consoleLoop()
  print(("Titan miner '%s'. Type 'help'."):format(cfg.name or ("#" .. os.getComputerID())))
  printStatus()
  while true do
    write("miner> ")
    local a = {}
    for word in tostring(read()):gmatch("%S+") do a[#a + 1] = word end
    local cmd = (a[1] or ""):lower()

    if cmd == "" then
      -- ignore
    elseif cmd == "help" then
      print("BOX (opposite corners + Y range):")
      print("  set1 / set2              mark opposite corners (X/Z footprint)")
      print("  sety <startY> <endY>     vertical range (e.g. sety 80 -59)")
      print("  ystart <y> / yend <y>    set start or end Y alone")
      print("  yhere start|end          use current GPS Y")
      print("OTHER:")
      print("  deposit   stand ABOVE a chest; dump inventory here")
      print("  home      mark return point")
      print("  exclude   reload & show exclude.txt")
      print("  mine      dig the box from startY down to endY")
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
      markHere("loc1")
    elseif cmd == "set2" or cmd == "corner2" then
      markHere("loc2")
    elseif cmd == "sety" then
      local ys, ye = tonumber(a[2]), tonumber(a[3])
      if ys and ye then
        setYStart(ys); setYEnd(ye)
        local topY, floorY = yRange()
        print(("Y range: start=%d  end=%d  (will mine %d -> %d)"):format(
          ys, ye, topY, floorY))
      elseif ys and not ye then
        -- Back-compat: sety <y> alone sets the end (bottom) level.
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
    elseif cmd == "home" then
      markHere("home")
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
      print("Unknown: " .. cmd .. "  (type 'help')")
    end
  end
end

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
  if d.deposit then cfg.deposit = d.deposit end
  saveCfg()
  os.setComputerLabel(name)
  if cfg.home then nav.home = cfg.home end
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
            setStatus("idle", "mine queued")
            titan.send(id, MSG.ACK, { ok = true, task = "mine queued" })
          end
        elseif cmd == "stop" then
          state.stop = true
          mineRequested = false
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

if not quarryReady() then
  print("Miner '" .. cfg.name .. "' online — box not fully set.")
  print("  1) set1 / set2     opposite corners of the area")
  print("  2) sety <startY> <endY>   e.g. sety 80 -59")
  print("  3) deposit (above chest) then mine")
else
  local b = bounds()
  print(("Miner '%s' online. Box ready X[%d..%d] Z[%d..%d] Y[%d->%d]."):format(
    cfg.name, b.minX, b.maxX, b.minZ, b.maxZ, b.topY, b.floorY))
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
