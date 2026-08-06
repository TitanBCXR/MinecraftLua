--[[
  worker.lua  -  Builder / Gatherer bot for the Titan network (CC: Tweaked)
  Titan-Version: 1.2.4

  A TURTLE that is either a BUILDER or a GATHERER. It registers with the
  "Bots Computer" (botserver.lua), learns/keeps its type, and then works.

  DEPLOYMENT IS DRIVEN BY THE PARENT CENTER (datacenter.lua). A fresh worker
  does NOT prompt for anything: it powers on, announces itself as "awaiting
  deployment", and waits. An admin logged into the Parent Center (unlocked by
  the master-password lock on its disk drive) runs `deploy` to push this
  worker's type. Names are ALWAYS unique (Builder-12 / Gatherer-7) — player
  labels on the turtle are ignored.

  Bots Computer sets site logistics:
    storage   — dump chest when inventory is full
    fuelchest — coal chest; workers keep 16–64 coal in the fuel slot (16)

  GATHERER:
    * Never breaks blocks. Moves with digging disabled; if it gets stuck it
      reports its location to the monitor (STUCK) and moves on.
    * Reads the gather board from the server and collects from registered
      chests, keeping only items the chest's filter accepts, then deposits to
      storage.
    * Redistributes coal: pulls coal from the fuel chest / storage and drops
      it at the start points of bots that requested coal.

  BUILDER:
    * On start, places its output chest and registers it (a gather post) so a
      gatherer empties it to storage; also asks for coal when low on fuel.
    * Reports its location/area to the server.
    * Can SCAN a structure into a reusable preset: it serpentines a WxHxL box,
      recording every block's relative position + type (never breaking blocks
      on the restricted list), saves it to builds/<name>.txt, and uploads it.
    * Can BUILD a preset at its current position from blocks in its inventory.

  NETWORK: joins the Titan routing mesh (titan.networkLoop) — announces to the
  router directory and relays rednet hops while in range, so Parent Center
  deploys and bot-server orders can reach this turtle even when the main router
  is out of direct range (as long as some mesh peer can hear both sides).

  Requires: wireless modem, fuel, a GPS constellation. Uses lib/titan.lua.
]]

local titan = dofile("lib/titan.lua")
local nav   = titan.nav
local P     = titan.PROTOCOL
local MSG   = titan.MSG

titan.openModem()

local CFG       = "worker.cfg"
local BUILD_DIR = "builds"
if not fs.exists(BUILD_DIR) then fs.makeDir(BUILD_DIR) end

-- direction unit vectors keyed by heading
local DIR = {
  [titan.NORTH] = { x = 0, z = -1 },
  [titan.EAST]  = { x = 1, z = 0 },
  [titan.SOUTH] = { x = 0, z = 1 },
  [titan.WEST]  = { x = -1, z = 0 },
}

local cfg   = nil
local queue = {}                                  -- list of job closures
local state = { status = "booting", task = "-" }
local unlocked = false                            -- admin unlocked this session?

local function setStatus(s, t) state.status = s; if t then state.task = t end end
local function isCoal(name) return name == "minecraft:coal" or name == "minecraft:charcoal" end
local function fmt(p) return p and ("%d,%d,%d"):format(p.x, p.y, p.z) or "?" end

-- Fuel-slot coal stock (dedicated slot 16): keep between these counts.
local COAL_MIN, COAL_MAX = 16, 64

--==============================================================================
-- Config
--==============================================================================
local function loadCfg()
  if not fs.exists(CFG) then return nil end
  local f = fs.open(CFG, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  return d
end
local function saveCfg() local f = fs.open(CFG, "w"); f.write(textutils.serialize(cfg)); f.close() end

local function applyUniqueName(botType, id)
  local name = titan.uniqueBotName(botType, id or os.getComputerID())
  if cfg then cfg.name = name; saveCfg() end
  os.setComputerLabel(name)
  return name
end

local function storagePos()
  return (cfg and (cfg.storage or cfg.deposit)) or nil
end

local function fuelPos()
  return (cfg and (cfg.fuelChest or cfg.storage or cfg.deposit)) or nil
end

--==============================================================================
-- Networking helpers
--==============================================================================
local function awaitType(t, timeout, fromId)
  local deadline = os.clock() + timeout
  while true do
    local rem = deadline - os.clock()
    if rem <= 0 then return nil end
    local id, msg = rednet.receive(P, rem)
    if id == nil then return nil end
    if type(msg) == "table" and msg.type == t and (not fromId or id == fromId) then
      return id, msg
    end
  end
end

-- Ask the server for a list; returns the table under `field` or nil.
local function requestList(reqType, respType, field)
  titan.broadcast(reqType, {})
  local _, msg = awaitType(respType, 2)
  return msg and msg[field] or nil
end

local function reportStuck(reason)
  local x, y, z = nav.locate(1)
  titan.broadcast(MSG.STUCK, { x = x, y = y, z = z, reason = reason, botType = cfg.botType })
  setStatus("stuck", "stuck: " .. tostring(reason))
  print("[STUCK] " .. tostring(reason) .. " @ " .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
end

--==============================================================================
-- Inventory helpers (chests are accessed from DIRECTLY ABOVE, via *Down)
--==============================================================================
local function selectItem(name)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == name then turtle.select(s); return true end
  end
  return false
end

local function selectAny(pred)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and pred(d) then turtle.select(s); return true, d end
  end
  return false
end

-- Empty inventory downward (into a chest below the bot), keeping the fuel slot.
local function dumpAllDown()
  local fuelSlot = nav.FUEL_SLOT or 16
  for s = 1, 16 do
    if s ~= fuelSlot then turtle.select(s); turtle.dropDown() end
  end
  turtle.select(1)
end

local function inventoryFull()
  local fuelSlot = nav.FUEL_SLOT or 16
  for s = 1, 16 do
    if s ~= fuelSlot and turtle.getItemCount(s) == 0 then return false end
  end
  return true
end

local function fuelSlotCoalCount()
  local slot = nav.FUEL_SLOT or 16
  local d = turtle.getItemDetail(slot)
  if d and isCoal(d.name) then return d.count end
  return 0
end

-- Go to (x, y+1, z) so we sit directly above the chest at (x,y,z).
local function goAboveChest(pos)
  local dig = cfg and cfg.botType == "builder"
  local ok, reason = nav.travelTo(pos.x, pos.y + 1, pos.z, { dig = dig == true })
  return ok, reason
end

-- Consolidate coal into the fuel slot and pull from fuelchest until 16–64.
local function ensureCoalStock()
  local slot = nav.FUEL_SLOT or 16
  local function count()
    local d = turtle.getItemDetail(slot)
    if d and isCoal(d.name) then return d.count end
    if d and not isCoal(d.name) then
      -- Wrong item in fuel slot — park it elsewhere or drop at fuel chest later.
      for s = 1, 16 do
        if s ~= slot and turtle.getItemCount(s) == 0 then
          turtle.select(slot); turtle.transferTo(s); return 0
        end
      end
    end
    return 0
  end

  -- Pull coal from other slots into fuel slot (cap at COAL_MAX).
  local n = count()
  if n < COAL_MAX then
    for s = 1, 16 do
      if s ~= slot then
        local d = turtle.getItemDetail(s)
        if d and isCoal(d.name) then
          turtle.select(s)
          turtle.transferTo(slot, COAL_MAX - n)
          n = count()
          if n >= COAL_MAX then break end
        end
      end
    end
  end

  -- Trim over COAL_MAX into another slot.
  n = count()
  if n > COAL_MAX then
    for s = 1, 16 do
      if s ~= slot and turtle.getItemCount(s) == 0 then
        turtle.select(slot); turtle.transferTo(s, n - COAL_MAX); break
      end
    end
    n = count()
  end

  if n >= COAL_MIN then return true end

  local src = fuelPos()
  if not src then
    print("No fuelchest/storage from Bots Computer — cannot restock coal.")
    return false
  end
  setStatus("moving", "fuel @ " .. fmt(src))
  local ok, r = goAboveChest(src)
  if not ok then reportStuck(r); return false end

  setStatus("working", "restock coal")
  local guard = 0
  while count() < COAL_MAX and guard < 64 do
    guard = guard + 1
    if not turtle.suckDown(math.min(COAL_MAX - count(), 64)) then break end
    -- Move coal into fuel slot; return non-coal to chest.
    for s = 1, 16 do
      if s ~= slot then
        local d = turtle.getItemDetail(s)
        if d and isCoal(d.name) then
          turtle.select(s); turtle.transferTo(slot, COAL_MAX - count())
        elseif d then
          turtle.select(s); turtle.dropDown()
        end
      end
    end
    local d = turtle.getItemDetail(slot)
    if d and not isCoal(d.name) then
      turtle.select(slot); turtle.dropDown()
    end
    if count() >= COAL_MIN and not turtle.detectDown() then break end
  end

  n = count()
  if n < COAL_MIN then
    print(("Fuel chest low: %d coal (need %d)."):format(n, COAL_MIN))
    return false
  end
  print(("Coal stock: %d in fuel slot."):format(n))
  return true
end

-- Burn fuel for movement without draining the fuel-slot stock below COAL_MIN.
local function ensureTravelFuel(minLevel)
  minLevel = minLevel or 300
  if turtle.getFuelLevel() == "unlimited" then return true end
  if turtle.getFuelLevel() >= minLevel then return true end
  ensureCoalStock()
  local slot = nav.FUEL_SLOT or 16
  turtle.select(slot)
  local d = turtle.getItemDetail(slot)
  if d and isCoal(d.name) and d.count > COAL_MIN then
    turtle.refuel(d.count - COAL_MIN)
  end
  -- Last resort: burn from other slots, then restock coal again.
  if turtle.getFuelLevel() < minLevel then
    nav.ensureFuel(minLevel)
  end
  if fuelSlotCoalCount() < COAL_MIN then ensureCoalStock() end
  turtle.select(1)
  return turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() >= 1
end

local function dumpToStorage(returnPos)
  local dep = storagePos()
  if not dep then
    print("No storage set on Bots Computer — cannot dump.")
    return false
  end
  setStatus("moving", "dump @ " .. fmt(dep))
  local ok, r = goAboveChest(dep)
  if not ok then reportStuck(r); return false end
  dumpAllDown()
  if returnPos then
    setStatus("moving", "back to work")
    nav.travelTo(returnPos.x, returnPos.y, returnPos.z, {
      dig = cfg and cfg.botType == "builder",
    })
    nav.heading = nil
  end
  return true
end

--==============================================================================
-- GATHERER behaviour
--==============================================================================

local function doCollect(post)
  ensureCoalStock()
  ensureTravelFuel(300)
  setStatus("moving", "collect @ " .. fmt(post.pos))
  local ok, reason = goAboveChest(post.pos)
  if not ok then reportStuck(reason); return end

  setStatus("working", "collecting")
  while turtle.suckDown() do end                        -- pull everything up

  -- Return items the chest's filter does NOT accept (never touch fuel slot).
  local fuelSlot = nav.FUEL_SLOT or 16
  for s = 1, 16 do
    if s ~= fuelSlot then
      local d = turtle.getItemDetail(s)
      if d and not titan.itemAccepted(d.name, post) then
        turtle.select(s); turtle.dropDown()
      end
    end
  end
  turtle.select(1)

  -- Deposit kept items into site storage (Bots Computer).
  local dep = storagePos() or post.deposit or cfg.deposit or nav.home
  if dep then
    setStatus("moving", "deposit @ " .. fmt(dep))
    local ok2, r2 = goAboveChest(dep)
    if not ok2 then reportStuck(r2); return end
    ensureTravelFuel(200)
    dumpAllDown()
  end

  titan.broadcast(MSG.GATHER_DONE, { post = post.id })
  setStatus("idle", "-")
end

local function doCoal(need)
  local fuelSlot = nav.FUEL_SLOT or 16
  ensureCoalStock()
  ensureTravelFuel(300)
  -- Source delivery coal from fuel chest / storage (leave our fuel-slot stock).
  local src = fuelPos()
  if src then
    setStatus("moving", "coal src @ " .. fmt(src))
    local ok, r = goAboveChest(src)
    if not ok then reportStuck(r); return end
    while turtle.suckDown() do end
    for s = 1, 16 do
      if s ~= fuelSlot then
        local d = turtle.getItemDetail(s)
        if d and not isCoal(d.name) then turtle.select(s); turtle.dropDown() end
      end
    end
    -- Keep our fuel slot at COAL_MIN–COAL_MAX; extras in other slots for delivery.
    local n = fuelSlotCoalCount()
    if n > COAL_MAX then
      for s = 1, 16 do
        if s ~= fuelSlot and turtle.getItemCount(s) == 0 then
          turtle.select(fuelSlot); turtle.transferTo(s, n - COAL_MAX); break
        end
      end
    end
    turtle.select(1)
  end

  setStatus("moving", "coal -> " .. fmt(need.pos))
  local ok2, r2 = goAboveChest(need.pos)
  if not ok2 then reportStuck(r2); return end
  for s = 1, 16 do
    if s ~= fuelSlot then
      local d = turtle.getItemDetail(s)
      if d and isCoal(d.name) then turtle.select(s); turtle.dropDown() end
    end
  end
  turtle.select(1)
  titan.broadcast(MSG.COAL_DONE, { target = need.from })
  setStatus("idle", "-")
end

-- One unit of gatherer work (kept short so the bot stays responsive).
local function serviceGather()
  ensureCoalStock()
  ensureTravelFuel(300)
  local gathers = requestList(MSG.GATHER_LIST_REQ, MSG.GATHER_LIST, "gathers")
  if gathers then
    for _, post in pairs(gathers) do doCollect(post); return end
  end
  local coalNeeds = requestList(MSG.COAL_LIST_REQ, MSG.COAL_LIST, "coal")
  if coalNeeds then
    for _, need in pairs(coalNeeds) do doCoal(need); return end
  end
  setStatus("idle", "-")
end

--==============================================================================
-- BUILDER behaviour
--==============================================================================

-- Place the output chest in front, register it as a gather post + a coal need.
local function deployChest()
  if not selectItem("minecraft:chest") then
    print("No chest item in inventory to deploy.")
    return false
  end
  if not turtle.place() then
    print("Could not place chest (block in front?).")
    return false
  end
  local x, y, z = nav.locatePrecise(4)
  if not x then print("No GPS - cannot register chest position."); return false end
  local d = DIR[nav.heading]
  local chestPos = { x = x + d.x, y = y, z = z + d.z }
  cfg.chest = chestPos
  saveCfg()
  -- Gatherer should take everything EXCEPT coal (leave fuel for this bot).
  titan.broadcast(MSG.GATHER_POST, {
    id = os.getComputerID(), pos = chestPos,
    accepts = { "minecraft:coal", "minecraft:charcoal" }, mode = "exclude",
    deposit = storagePos() or cfg.deposit,
  })
  titan.broadcast(MSG.COAL_NEED, { pos = chestPos })
  print("Chest deployed @ " .. fmt(chestPos) .. " and registered.")
  return true
end

-- Scan one vertical column of height H at build-space (c, r). Records to blocks.
local function scanColumn(c, r, H, blocks)
  local moved = 0
  for depth = 0, H - 1 do
    local present, data = turtle.inspectDown()
    if present then
      local restricted = titan.isRestricted(data.name)
      blocks[#blocks + 1] = { x = c, y = H - 1 - depth, z = r, name = data.name, restricted = restricted or nil }
      if restricted then break end                      -- never break restricted blocks
      turtle.digDown()
    end
    if depth < H - 1 then
      if turtle.down() then moved = moved + 1 else break end
    end
  end
  for _ = 1, moved do turtle.up() end                   -- climb back to the top plane
end

-- Serpentine a WxHxL box, recording every block. Bot must START on top of the
-- front-left corner (one block above the highest corner), facing along length.
local function excavateScan(name, W, H, L)
  ensureCoalStock()
  ensureTravelFuel(500)
  setStatus("working", "scan " .. name)
  local blocks = {}
  local function fwd() if not turtle.forward() then turtle.dig(); turtle.forward() end end
  for line = 0, L - 1 do
    for step = 0, W - 1 do
      local c = (line % 2 == 0) and step or (W - 1 - step)
      scanColumn(c, line, H, blocks)
      if inventoryFull() then
        local x, y, z = nav.locate(2)
        dumpToStorage(x and { x = x, y = y, z = z } or nil)
        ensureCoalStock()
      end
      if step < W - 1 then fwd() end
    end
    if line < L - 1 then
      if line % 2 == 0 then turtle.turnRight() else turtle.turnLeft() end
      fwd()
      if line % 2 == 0 then turtle.turnRight() else turtle.turnLeft() end
    end
  end
  -- The serpentine used raw turtle turns, so our tracked heading is now stale.
  nav.heading = nil                                     -- force re-calibration on next move
  do
    local any, fuelSlot = false, nav.FUEL_SLOT or 16
    for s = 1, 16 do
      if s ~= fuelSlot and turtle.getItemCount(s) > 0 then any = true; break end
    end
    if any then dumpToStorage(nil) end
  end
  local path = fs.combine(BUILD_DIR, name .. ".txt")
  local f = fs.open(path, "w"); f.write(textutils.serialize(blocks)); f.close()
  titan.broadcast(MSG.BUILD_STORE, { name = name, blocks = blocks })
  print(("Scan '%s' done: %d blocks -> %s"):format(name, #blocks, path))
  setStatus("idle", "-")
end

-- Load build data by name: local file first, else ask the server.
local function loadBuild(name)
  local path = fs.combine(BUILD_DIR, name .. ".txt")
  if fs.exists(path) then
    local f = fs.open(path, "r"); local d = textutils.unserialize(f.readAll()); f.close()
    return d
  end
  titan.broadcast(MSG.BUILD_GET_REQ, { name = name })
  local _, msg = awaitType(MSG.BUILD_GET, 3)
  if msg and msg.blocks then
    local f = fs.open(path, "w"); f.write(textutils.serialize(msg.blocks)); f.close()
    return msg.blocks
  end
  return nil
end

-- Build a preset at the current position (origin = where the bot stands).
local function buildPreset(name)
  ensureCoalStock()
  ensureTravelFuel(500)
  local blocks = loadBuild(name)
  if not blocks then print("Build '" .. name .. "' not found."); return end
  local ox, oy, oz = nav.locate(2)
  if not ox then print("No GPS - cannot build."); return end
  -- bottom-up so lower layers support upper ones
  table.sort(blocks, function(a, b) return a.y < b.y end)
  setStatus("working", "build " .. name)
  local missing = 0
  for _, b in ipairs(blocks) do
    if b.name ~= "minecraft:air" and not b.restricted then
      -- hover one block above the target cell, then place downward
      local ok, r = nav.moveTo(ox + b.x, oy + b.y + 1, oz + b.z, { dig = false })
      if not ok then reportStuck(r); return end
      if selectItem(b.name) then
        turtle.placeDown()
      else
        missing = missing + 1
      end
      if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 200 then
        ensureTravelFuel(500)
      end
    end
  end
  turtle.select(1)
  print(("Build '%s' complete (%d blocks missing from inventory)."):format(name, missing))
  setStatus("idle", "-")
end

--==============================================================================
-- Job queue
--==============================================================================
local function enqueue(fn) queue[#queue + 1] = fn end

local function workerLoop()
  while true do
    local job = table.remove(queue, 1)
    if job then
      local ok, err = pcall(job)
      if not ok then setStatus("error", "job err"); print("[job error] " .. tostring(err)) end
    else
      sleep(0.3)
    end
  end
end

-- Autonomous ticking: gatherers service the boards when idle.
local function roleTicker()
  while true do
    if cfg.botType == "gatherer" and #queue == 0 and state.status == "idle" then
      enqueue(serviceGather)
    end
    sleep(6)
  end
end

--==============================================================================
-- Deployment (driven by the Parent Center / datacenter.lua)
--
-- A fresh worker never prompts locally. It advertises itself as "awaiting
-- deployment" and waits for a WORKER_DEPLOY message from the Parent Center,
-- which only an admin (unlocked by the disk-drive password lock) can send.
--==============================================================================

-- Hand off a miner deploy to miner.lua (write cfg + startup, then reboot).
local function handoffToMiner(d)
  if not fs.exists("miner.lua") then
    return false, "miner.lua not installed — copy miner.lua onto this turtle, then redeploy"
  end
  local name = titan.uniqueBotName("miner", os.getComputerID())
  local mcfg = {
    name = name,
    botType = "miner",
    deposit = d.deposit or d.storage,
    storage = d.storage or d.deposit,
    fuelChest = d.fuelChest,
  }
  local f = fs.open("miner.cfg", "w")
  f.write(textutils.serialize(mcfg))
  f.close()
  local sf = fs.open("startup.lua", "w")
  sf.write('shell.run("miner.lua")\n')
  sf.close()
  os.setComputerLabel(name)
  print(("Handing off to miner.lua as '%s' — rebooting..."):format(name))
  return true, "handoff"
end

local function applySiteConfig(msg)
  if type(msg) ~= "table" then return end
  if type(msg.storage) == "table" and msg.storage.x then
    cfg.storage = {
      x = math.floor(msg.storage.x),
      y = math.floor(msg.storage.y),
      z = math.floor(msg.storage.z),
    }
    cfg.deposit = cfg.storage
  elseif type(msg.deposit) == "table" and msg.deposit.x then
    cfg.storage = {
      x = math.floor(msg.deposit.x),
      y = math.floor(msg.deposit.y),
      z = math.floor(msg.deposit.z),
    }
    cfg.deposit = cfg.storage
  end
  if type(msg.fuelChest) == "table" and msg.fuelChest.x then
    cfg.fuelChest = {
      x = math.floor(msg.fuelChest.x),
      y = math.floor(msg.fuelChest.y),
      z = math.floor(msg.fuelChest.z),
    }
  end
  saveCfg()
end

-- Apply a deploy payload { botType, name, deposit } from the Parent Center.
-- Name from the player is ignored — always Type-<computerId>.
local function applyDeployment(d)
  local t = tostring(d.botType or ""):lower()
  if t == "mine" then t = "miner" end
  if t == "miner" then
    return handoffToMiner(d)
  end
  if t ~= "builder" and t ~= "gatherer" then
    return false, "bad type (want builder|gatherer|miner)"
  end
  local name = titan.uniqueBotName(t, os.getComputerID())

  print(("Deploying as %s '%s' (unique name; player label ignored)..."):format(t, name))
  local ok, err = nav.calibrate(t == "builder")           -- gatherers calibrate without digging
  if not ok then print("Calibrate warning: " .. tostring(err)) end
  local hx, hy, hz = nav.locate(2)
  local home = hx and { x = hx, y = hy, z = hz } or nil

  local deposit = d.storage or d.deposit or home
  cfg = {
    name = name, botType = t, home = home,
    deposit = deposit, storage = d.storage or d.deposit or deposit,
    fuelChest = d.fuelChest,
  }
  saveCfg()
  os.setComputerLabel(name)
  nav.home = home
  -- Ask Bots Computer for latest storage / fuel chest.
  titan.broadcast(MSG.SITE_CONFIG_REQ, { name = name, botType = t })
  return true
end

-- Blocking loop for a brand-new (unconfigured) worker: beacon + wait for deploy.
local function awaitDeployment()
  setStatus("await", "awaiting deployment")
  -- Never keep a player-placed label — use a temporary await tag.
  local awaitName = "await-" .. os.getComputerID()
  os.setComputerLabel(awaitName)
  print("Unconfigured worker. Waiting for the Parent Center to deploy me...")
  print("(An admin must log into the Parent Center and run 'deploy'.)")
  print("I will take a unique name like Builder-" .. os.getComputerID() .. " on deploy.")
  local beacon = os.startTimer(0)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "timer" and p1 == beacon then
      local x, y, z = nav.locate(1)
      titan.broadcast(MSG.WORKER_AWAIT, {
        name = awaitName, kind = "worker", x = x, y = y, z = z,
      })
      beacon = os.startTimer(3)
    elseif ev == "rednet_message" and p3 == P and type(p2) == "table"
           and p2.type == MSG.WORKER_DEPLOY then
      local ok, why = applyDeployment(p2)
      if ok then
        local handoff = (why == "handoff")
        titan.send(p1, MSG.WORKER_DEPLOYED, {
          name = handoff and titan.uniqueBotName("miner", os.getComputerID()) or cfg.name,
          botType = handoff and "miner" or cfg.botType,
          handoff = handoff or nil,
        })
        if handoff then
          sleep(0.3)
          os.reboot()
        end
        return
      else
        titan.send(p1, MSG.WORKER_DEPLOYED, { ok = false, err = why })
        print("Deploy rejected: " .. tostring(why))
      end
    end
  end
end

--==============================================================================
-- Status + registration
--==============================================================================
local function statusLoop()
  -- Enforce unique name in case cfg still has a player label from older deploys.
  if not titan.isUniqueBotName(cfg.name, cfg.botType) then
    applyUniqueName(cfg.botType, os.getComputerID())
  end
  titan.broadcast(MSG.BOT_REGISTER, {
    name = cfg.name, botType = cfg.botType, home = nav.home, chest = cfg.chest,
  })
  titan.broadcast(MSG.SITE_CONFIG_REQ, { name = cfg.name, botType = cfg.botType })
  local tick = 0
  while true do
    tick = tick + 1
    local x, y, z = nav.locate(1)
    local fix = nav.lastFix
    titan.broadcast(MSG.STATUS, {
      name = cfg.name,
      x = x, y = y, z = z, fuel = turtle.getFuelLevel(),
      coal = fuelSlotCoalCount(),
      yLo = fix and fix.yLo, yHi = fix and fix.yHi,
      gpsN = fix and fix.n, gpsSpreadY = fix and fix.spreadY,
      state = state.status, task = state.task,
      assignment = state.task, botType = cfg.botType,
    })
    -- Keep coal stock when idle; ask gatherers if we still have a personal chest.
    if state.status == "idle" and tick % 3 == 0 then
      if fuelSlotCoalCount() < COAL_MIN then
        enqueue(function()
          ensureCoalStock()
          ensureTravelFuel(300)
          setStatus("idle", "-")
        end)
      end
    end
    if cfg.botType == "builder" and cfg.chest and type(turtle.getFuelLevel()) == "number"
       and turtle.getFuelLevel() < 500 then
      titan.broadcast(MSG.COAL_NEED, { pos = cfg.chest })
    end
    sleep(5)
  end
end

--==============================================================================
-- Incoming orders
--==============================================================================
local function receiveLoop()
  while true do
    local id, msg = rednet.receive(P)
    if type(msg) == "table" then
      local t = msg.type
      if t == MSG.SCAN_ORDER and cfg.botType == "builder" then
        enqueue(function() excavateScan(msg.name, msg.W, msg.H, msg.L) end)
      elseif t == MSG.BUILD_ORDER and cfg.botType == "builder" then
        enqueue(function()
          if msg.x then
            local ok = nav.travelTo(msg.x, msg.y, msg.z, { dig = true })
            if not ok then reportStuck("to build site"); return end
          end
          buildPreset(msg.name)
        end)
      elseif t == MSG.SITE_CONFIG then
        applySiteConfig(msg)
        print(("Site: storage=%s  fuel=%s"):format(fmt(cfg.storage), fmt(cfg.fuelChest)))
      elseif t == MSG.COMMAND then                        -- basic hub commands still work
        local cmd = tostring(msg.cmd or ""):lower()
        if cmd == "return" then
          enqueue(function() setStatus("moving", "-> home"); nav.goHome({ dig = cfg.botType == "builder" }); setStatus("idle", "-") end)
        elseif cmd == "goto" and msg.x then
          enqueue(function() nav.travelTo(msg.x, msg.y, msg.z, { dig = cfg.botType == "builder" }) end)
        elseif cmd == "refuel" then
          enqueue(function()
            ensureCoalStock(); ensureTravelFuel(1000); setStatus("idle", "-")
          end)
        elseif cmd == "dump" or cmd == "deposit" then
          enqueue(function() dumpToStorage(nil); setStatus("idle", "-") end)
        elseif cmd == "rename" and msg.name then
          cfg.name = tostring(msg.name)
          saveCfg()
          os.setComputerLabel(cfg.name)
          print("Renamed to " .. cfg.name)
        elseif cmd == "stop" then
          queue = {}; setStatus("idle", "-")
        end
      elseif t == MSG.WORKER_DEPLOY then                   -- Parent Center re-deploys us
        enqueue(function()
          local ok, why = applyDeployment(msg)
          if ok then
            local handoff = (why == "handoff")
            titan.send(id, MSG.WORKER_DEPLOYED, {
              name = handoff and titan.uniqueBotName("miner", os.getComputerID()) or cfg.name,
              botType = handoff and "miner" or cfg.botType,
              handoff = handoff or nil,
            })
            if handoff then
              sleep(0.3)
              os.reboot()
              return
            end
            print(("Re-deployed as %s '%s'."):format(cfg.botType, cfg.name))
            setStatus("idle", "-")
          else
            titan.send(id, MSG.WORKER_DEPLOYED, { ok = false, err = why })
          end
        end)
      elseif t == MSG.PING then
        titan.send(id, MSG.PONG, {
          state = state.status, botType = cfg.botType, name = cfg.name,
          coal = fuelSlotCoalCount(),
        })
      end
    end
  end
end

--==============================================================================
-- Console (admin-gated actions)
--==============================================================================
local function requireAuth()
  if unlocked then return true end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    unlocked = true
    return true
  end
  if titan.login("Master password") then unlocked = true; print("Unlocked."); return true end
  print("Denied (master password required).")
  return false
end

-- Ask the Parent Center to (re)deploy this worker: just advertise ourselves as
-- awaiting deployment so an admin can pick us up with 'pending' / 'deploy'.
local function requestRedeploy()
  local x, y, z = nav.locate(1)
  titan.broadcast(MSG.WORKER_AWAIT, { x = x, y = y, z = z })
  print("Announced to the Parent Center. An admin can now 'deploy' this bot.")
  print("Deployment (type/name) is set from the Parent Center, not here.")
end

local function handleCommand(a)
  local cmd = (a[1] or ""):lower()

  if cmd == "" then
    return true
  elseif cmd == "help" then
    print("Commands: status | login | scan <name> <W> <H> <L> | build <name> |")
    print("          chest | dump | refuel | redeploy | home | reboot")
    print("Site (from Bots Computer): storage + fuelchest — see `status`")
    print("Name is unique (Builder-12); player labels are ignored.")
  elseif cmd == "status" then
    print(("%s (%s)  state=%s task=%s fuel=%s coal=%d"):format(
      cfg.name, cfg.botType, state.status, state.task,
      tostring(turtle.getFuelLevel()), fuelSlotCoalCount()))
    print("home=" .. fmt(nav.home) .. "  chest=" .. fmt(cfg.chest))
    print("storage=" .. fmt(storagePos()) .. "  fuelchest=" .. fmt(cfg.fuelChest or fuelPos()))
  elseif cmd == "hostname" or cmd == "host" then
    print("hostname: " .. (cfg.name or os.getComputerLabel() or "?"))
    print("Workers keep unique Type-<id> names (set by deploy / Bots Computer).")
  elseif cmd == "login" then
    requireAuth()
  elseif cmd == "scan" then
    if cfg.botType ~= "builder" then print("Only builders scan.")
    elseif not (a[2] and a[3] and a[4] and a[5]) then print("Usage: scan <name> <W> <H> <L>")
    elseif requireAuth() then
      enqueue(function() excavateScan(a[2], tonumber(a[3]), tonumber(a[4]), tonumber(a[5])) end)
      print("Scan queued.")
    end
  elseif cmd == "build" then
    if cfg.botType ~= "builder" then print("Only builders build.")
    elseif not a[2] then print("Usage: build <name>")
    elseif requireAuth() then
      enqueue(function() buildPreset(a[2]) end); print("Build queued.")
    end
  elseif cmd == "chest" then
    if cfg.botType ~= "builder" then print("Only builders deploy chests.")
    elseif requireAuth() then enqueue(deployChest) end
  elseif cmd == "dump" or cmd == "deposit" then
    if requireAuth() then
      enqueue(function() dumpToStorage(nil); setStatus("idle", "-") end)
      print("Dump to site storage queued.")
    end
  elseif cmd == "refuel" then
    enqueue(function()
      ensureCoalStock(); ensureTravelFuel(1000); setStatus("idle", "-")
    end)
    print("Refuel / coal restock queued.")
  elseif cmd == "type" or cmd == "redeploy" then
    requestRedeploy()
  elseif cmd == "home" then
    enqueue(function() setStatus("moving", "-> home"); nav.goHome({ dig = cfg.botType == "builder" }); setStatus("idle", "-") end)
  elseif cmd == "reboot" then
    os.reboot()
  else
    return false
  end
  return true
end

local function consoleLoop()
  while true do
    write("[" .. cfg.botType .. ":" .. cfg.name .. "]$ ")
    local a = {}
    for w in tostring(read()):gmatch("%S+") do a[#a + 1] = w end
    local r = handleCommand(a)
    if r == false then
      print("Unknown: " .. tostring(a[1] or "") .. " (type 'help')")
    end
  end
end

titan.setSshHandler(function(line)
  local a = {}
  for w in tostring(line):gmatch("%S+") do a[#a + 1] = w end
  local r = handleCommand(a)
  if r == false then
    print("Unknown: " .. tostring(a[1] or "") .. " (type 'help')")
  end
  return true
end)

--==============================================================================
-- Startup
--==============================================================================
cfg = loadCfg()
if not cfg or not cfg.botType then
  -- Stay on the mesh while waiting so Parent Center deploys can hop through peers.
  parallel.waitForAny(
    awaitDeployment,
    function() titan.networkLoop("worker") end
  )
else
  os.setComputerLabel(cfg.name)
  -- Recover heading/home each boot.
  local ok = nav.calibrate(cfg.botType == "builder")
  if ok and cfg.home then nav.home = cfg.home else nav.setHome() end
end

print(("Titan %s '%s' online."):format(cfg.botType, cfg.name))
setStatus("idle", "-")
-- networkLoop: announce to the router directory AND relay rednet hops so this
-- builder/gatherer extends the mesh while it's in wireless range of peers.
parallel.waitForAny(receiveLoop, statusLoop, workerLoop, roleTicker, consoleLoop,
  function() titan.networkLoop("worker") end)
