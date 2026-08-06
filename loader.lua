--[[
  loader.lua  -  Chunk-escort turtle for the Titan miner fleet (CC: Tweaked)
  Titan-Version: 1.0.1

  Follows an assigned miner and keeps its work chunks loaded.
  Equip Advanced Peripherals "Chunky Turtle" (loads the chunk the turtle is in).

  While escorting: stay ~2 blocks away so the miner is never blocked.
  When idle / parked: return to stage and do not wander (no chunk load while idle).

  Deploy:  deploy <id> loader
  Parent Center / marker jobs auto-assign loaders with miners.
]]

local titan = dofile("lib/titan.lua")
local nav   = titan.nav
local MSG   = titan.MSG
local P     = titan.PROTOCOL

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("await-" .. os.getComputerID()))

local CFG = "loader.cfg"
local FOLLOW_GAP = 2

local cfg = {
  name = nil,
  botType = "loader",
  stage = nil,
  cruiseY = 150,
  home = nil,
}

local state = {
  status = "idle",
  task = "-",
  jobId = nil,
  stop = false,
  minerId = nil,
}
local pendingEscort = nil
local minerTrack = nil  -- { x, y, z, state, seen, done }

local function saveCfg()
  local f = fs.open(CFG, "w"); f.write(textutils.serialize(cfg)); f.close()
end

local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r")
  local d = textutils.unserialize(f.readAll()); f.close()
  if type(d) == "table" then
    for k, v in pairs(d) do cfg[k] = v end
  end
end

local function setStatus(s, t)
  state.status = s
  if t then state.task = t end
end

local function fmt(p)
  return p and ("%d,%d,%d"):format(p.x, p.y, p.z) or "?"
end

local function assignmentText()
  return state.jobId or state.task or "-"
end

local function goCruiseTo(tx, ty, tz)
  local cruise = tonumber(cfg.cruiseY) or 150
  return nav.travelTo(tx, ty, tz, { dig = true, cruiseY = cruise })
end

local function returnToStage()
  local dest = cfg.stage or cfg.home
  if not dest then return false, "no stage" end
  setStatus("returning", "-> stage")
  local ok, err = goCruiseTo(dest.x, dest.y, dest.z)
  setStatus(ok and "parked" or "error", ok and "-" or tostring(err))
  state.jobId = nil
  state.minerId = nil
  minerTrack = nil
  return ok, err
end

-- Stand FOLLOW_GAP blocks from the miner on X (prefer +X, flip if needed).
local function offsetFromMiner(mx, my, mz)
  local gap = FOLLOW_GAP
  local lx, ly, lz = gps.locate(1)
  local tx = mx + gap
  if lx and math.abs((lx) - (mx + gap)) > math.abs((lx) - (mx - gap)) then
    -- Prefer the side we're already closer to, so we don't cross through the miner.
    if math.abs(lx - (mx - gap)) < math.abs(lx - (mx + gap)) then
      tx = mx - gap
    end
  end
  return tx, my, mz
end

local function chebyshev(ax, az, bx, bz)
  return math.max(math.abs(ax - bx), math.abs(az - bz))
end

local function minerLooksDone(st)
  st = tostring(st or ""):lower()
  return st == "idle" or st == "parked" or st == "error" or st == ""
end

-- Follow minerId at ~2 block gap until they finish / timeout / stop.
local function escortLoop(job)
  state.stop = false
  state.jobId = job.jobId or job.id
  state.minerId = tonumber(job.minerId)
  local gap = tonumber(job.followGap) or FOLLOW_GAP
  FOLLOW_GAP = math.max(2, math.floor(gap))
  if tonumber(job.cruiseY) then cfg.cruiseY = math.floor(tonumber(job.cruiseY)) end

  setStatus("escorting", tostring(state.jobId or "escort"))
  print(("Escort job %s -> miner #%s (gap %d)"):format(
    tostring(state.jobId), tostring(state.minerId or "?"), FOLLOW_GAP))

  -- Fly toward the strip first (cruise), then stick to the miner at work Y.
  local midX = tonumber(job.x) or (tonumber(job.x1) and tonumber(job.x2)
    and math.floor((job.x1 + job.x2) / 2))
  local midZ = tonumber(job.z) or (tonumber(job.z1) and tonumber(job.z2)
    and math.floor((job.z1 + job.z2) / 2))
  local approachY = tonumber(job.y) or tonumber(cfg.cruiseY) or 150
  if midX and midZ then
    goCruiseTo(midX, approachY, midZ)
  end

  minerTrack = {
    x = midX, y = approachY, z = midZ,
    state = "unknown", seen = os.epoch("utc"), done = false,
  }
  local deadline = os.epoch("utc") + 45 * 60 * 1000
  local idleTicks = 0

  while not state.stop and os.epoch("utc") < deadline do
    -- Ask miner for a ping; also STATUS broadcasts update minerTrack in receiveLoop.
    if state.minerId then
      titan.send(state.minerId, MSG.PING, { want = "pos" })
    end

    local t = minerTrack
    if t and t.x and t.y and t.z then
      local tx, ty, tz = offsetFromMiner(t.x, t.y, t.z)
      local lx, ly, lz = gps.locate(1)
      local needMove = true
      if lx then
        needMove = chebyshev(lx, lz, t.x, t.z) > FOLLOW_GAP
          or math.abs((ly or ty) - ty) > 1
      end
      if needMove then
        setStatus("escorting", ("follow #%s @ %d,%d,%d"):format(
          tostring(state.minerId or "?"), t.x, t.y, t.z))
        -- No cruise altitude here — stay in the miner's chunk layer.
        nav.travelTo(tx, ty, tz, { dig = true })
      else
        setStatus("escorting", ("hold gap=%d"):format(FOLLOW_GAP))
      end

      if minerLooksDone(t.state) and (os.epoch("utc") - (t.seen or 0)) < 15000 then
        idleTicks = idleTicks + 1
      else
        idleTicks = 0
      end
      -- Miner idle for ~20s after we have tracked them => job finished.
      if idleTicks >= 10 and t.seen and (os.epoch("utc") - t.seen) < 20000 then
        print("Miner looks idle — escort complete.")
        break
      end
    else
      setStatus("escorting", "waiting for miner GPS")
    end
    sleep(2)
  end

  if job.returnStage ~= false then
    returnToStage()
  else
    setStatus("idle", "-")
    state.jobId = nil
    state.minerId = nil
  end
  return true
end

local function applyDeployment(d)
  local t = tostring(d.botType or ""):lower()
  if t ~= "loader" and t ~= "chunk" and t ~= "chunky" then
    return false, "this turtle runs loader.lua (deploy as loader)"
  end
  cfg.name = titan.uniqueBotName("loader", os.getComputerID())
  cfg.botType = "loader"
  if type(d.stage) == "table" and d.stage.x then
    cfg.stage = {
      x = math.floor(tonumber(d.stage.x)),
      y = math.floor(tonumber(d.stage.y) or 64),
      z = math.floor(tonumber(d.stage.z)),
    }
  elseif type(d.deposit) == "table" and d.deposit.x then
    cfg.stage = {
      x = math.floor(tonumber(d.deposit.x)),
      y = math.floor(tonumber(d.deposit.y) or 64),
      z = math.floor(tonumber(d.deposit.z)),
    }
  end
  if tonumber(d.cruiseY) then cfg.cruiseY = math.floor(tonumber(d.cruiseY)) end
  saveCfg()
  os.setComputerLabel(cfg.name)
  return true
end

local function awaitDeployment()
  setStatus("awaiting", "deploy")
  local awaitName = "await-" .. os.getComputerID()
  os.setComputerLabel(awaitName)
  print("Loader awaiting Parent Center deploy...")
  print(("  deploy %d loader"):format(os.getComputerID()))
  while true do
    local x, y, z = gps.locate(2)
    rednet.broadcast({
      type = MSG.WORKER_AWAIT,
      name = awaitName, kind = "loader", x = x, y = y, z = z,
    }, P)
    local id, msg = rednet.receive(P, 8)
    if type(msg) == "table" and msg.type == MSG.WORKER_DEPLOY then
      local ok, why = applyDeployment(msg)
      titan.send(id, MSG.WORKER_DEPLOYED, {
        ok = ok, err = why, name = cfg.name, botType = "loader",
      })
      if ok then return true end
      print("Deploy rejected: " .. tostring(why))
    end
  end
end

local function handleCommand(a)
  local cmd = (a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" then
    print("stage here | stage <x y z> | cruise [y] | park | stop | status | exit")
    print("Follows miners at 2-block gap. Needs Chunky Turtle upgrade.")
  elseif cmd == "status" then
    print(("status=%s task=%s job=%s miner=#%s"):format(
      state.status, state.task, tostring(state.jobId), tostring(state.minerId)))
    print("stage=" .. fmt(cfg.stage) .. "  cruiseY=" .. tostring(cfg.cruiseY))
    if minerTrack then
      print(("track: %s state=%s"):format(fmt(minerTrack), tostring(minerTrack.state)))
    end
  elseif cmd == "stage" then
    if not a[2] or a[2]:lower() == "here" then
      local x, y, z = nav.locatePrecise(3)
      if not x then print("No GPS") else
        cfg.stage = { x = x, y = y, z = z }; saveCfg()
        print("stage = " .. fmt(cfg.stage))
      end
    elseif a[2] and a[3] and a[4] then
      cfg.stage = {
        x = math.floor(tonumber(a[2])),
        y = math.floor(tonumber(a[3])),
        z = math.floor(tonumber(a[4])),
      }
      saveCfg(); print("stage = " .. fmt(cfg.stage))
    else print("stage: " .. fmt(cfg.stage)) end
  elseif cmd == "cruise" then
    if a[2] then cfg.cruiseY = math.floor(tonumber(a[2]) or 150); saveCfg() end
    print("cruiseY = " .. tostring(cfg.cruiseY))
  elseif cmd == "park" or cmd == "tostage" or cmd == "return" then
    state.stop = true
    returnToStage()
  elseif cmd == "stop" then
    state.stop = true
    print("Stop requested — returning to stage after current leg.")
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    print("Unknown. Type help.")
  end
  return true
end

local function consoleLoop()
  if titan.setSshHandler then
    titan.setSshHandler(function(line)
      local a = {}
      for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
      return handleCommand(a) ~= false
    end)
  end
  while true do
    write("loader> ")
    local line = read()
    local a = {}
    for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
    if handleCommand(a) == "exit" then return end
  end
end

local function statusLoop()
  while true do
    local x, y, z = gps.locate(1)
    rednet.broadcast({
      type = MSG.STATUS,
      botName = cfg.name or os.getComputerLabel(),
      label = cfg.name or os.getComputerLabel(),
      botType = "loader",
      state = state.status,
      status = state.status,
      task = state.task,
      assignment = assignmentText(),
      x = x, y = y, z = z,
      fuel = turtle.getFuelLevel(),
      minerId = state.minerId,
    }, P)
    sleep(5)
  end
end

local function receiveLoop()
  while true do
    local id, msg = rednet.receive(P)
    if type(msg) == "table" then
      local t = msg.type
      if t == MSG.LOADER_ASSIGN or t == "loader_assign" then
        if state.status == "escorting" or state.status == "moving" then
          titan.send(id, MSG.ACK, { ok = false, err = "busy" })
        else
          pendingEscort = msg
          setStatus("idle", "escort queued")
          titan.send(id, MSG.ACK, { ok = true, task = "escort queued", jobId = msg.jobId })
        end
      elseif t == MSG.STATUS or t == MSG.PONG then
        if state.minerId and id == state.minerId then
          minerTrack = minerTrack or {}
          minerTrack.x = msg.x or minerTrack.x
          minerTrack.y = msg.y or minerTrack.y
          minerTrack.z = msg.z or minerTrack.z
          minerTrack.state = msg.state or msg.status or minerTrack.state
          minerTrack.seen = os.epoch("utc")
        end
      elseif t == MSG.COMMAND then
        local cmd = tostring(msg.cmd or ""):lower()
        if cmd == "park" or cmd == "tostage" or cmd == "return" then
          state.stop = true
          local ok, err = returnToStage()
          titan.send(id, MSG.ACK, { ok = ok, err = err })
        elseif cmd == "stop" then
          state.stop = true
          titan.send(id, MSG.ACK, { ok = true, task = "stop" })
        elseif cmd == "stage" and msg.x then
          cfg.stage = {
            x = math.floor(tonumber(msg.x)),
            y = math.floor(tonumber(msg.y) or 64),
            z = math.floor(tonumber(msg.z)),
          }
          saveCfg()
          titan.send(id, MSG.ACK, { ok = true, task = "stage set" })
        elseif cmd == "rename" and msg.name then
          cfg.name = tostring(msg.name); saveCfg(); os.setComputerLabel(cfg.name)
        end
      elseif t == MSG.PERMIT_SYNC and type(msg.permits) == "table" then
        titan.setPermits(msg.permits)
      elseif t == MSG.WORKER_DEPLOY then
        local ok, why = applyDeployment(msg)
        titan.send(id, MSG.WORKER_DEPLOYED, {
          ok = ok, err = why, name = cfg.name, botType = "loader",
        })
      elseif t == MSG.PING then
        local px, py, pz = gps.locate(1)
        titan.send(id, MSG.PONG, {
          state = state.status, status = state.status, botType = "loader",
          name = cfg.name, botName = cfg.name, assignment = assignmentText(),
          x = px, y = py, z = pz,
        })
      end
    end
  end
end

local function jobLoop()
  while true do
    if pendingEscort and state.status ~= "escorting" and state.status ~= "moving"
        and state.status ~= "returning" then
      local job = pendingEscort
      pendingEscort = nil
      escortLoop(job)
    end
    sleep(0.5)
  end
end

--------------------------------------------------------------------------------
loadCfg()
if not cfg.name then
  parallel.waitForAny(awaitDeployment, function() titan.networkLoop("loader") end)
end
if not titan.isUniqueBotName(cfg.name, "loader") then
  cfg.name = titan.uniqueBotName("loader", os.getComputerID())
  saveCfg()
end
os.setComputerLabel(cfg.name)
if cfg.stage then cfg.home = cfg.home or cfg.stage; nav.home = cfg.stage end
pcall(nav.calibrate, true)
setStatus(cfg.stage and "parked" or "idle", "-")
print(("Loader '%s' online. stage=%s cruiseY=%d"):format(
  cfg.name, fmt(cfg.stage), tonumber(cfg.cruiseY) or 150))
print("Follows miners at 2-block gap. Chunky Turtle upgrade required for chunk loading.")

parallel.waitForAny(
  consoleLoop, statusLoop, receiveLoop, jobLoop,
  function() titan.networkLoop("loader") end
)
print("Loader stopped.")
