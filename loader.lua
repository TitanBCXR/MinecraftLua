--[[
  loader.lua  -  Chunk-escort turtle for the Titan miner fleet (CC: Tweaked)
  Titan-Version: 1.0.0

  Keeps work areas loaded while miners dig. Vanilla CC turtles cannot force-load
  chunks from Lua. Equip Advanced Peripherals "Chunky Turtle" (loads the chunk
  the turtle is in). This script only moves the escort while a job is active;
  when idle / parked it returns to the staging sheet and does NOT wander.

  Flow:
    * Park at stage (sheet stack with miners)
    * Parent Center `flatten` assigns loaders with miners
    * Fly cruise Y (~150) to strip mid, hover / pace the strip
    * On cancel / job done / `park` — return to stage and idle

  Deploy from Parent Center:
    deploy <id> loader <name> [stageX stageY stageZ]

  Local: stage here | cruise <y> | park | status
]]

local titan = dofile("lib/titan.lua")
local nav   = titan.nav
local MSG   = titan.MSG
local P     = titan.PROTOCOL

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Loader-" .. os.getComputerID()))

local CFG = "loader.cfg"
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
}
local pendingEscort = nil

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
  return ok, err
end

-- Pace the strip slowly so Chunky Turtle keeps nearby chunks warm.
local function escortLoop(job)
  state.stop = false
  state.jobId = job.jobId or job.id
  setStatus("escorting", tostring(state.jobId or "escort"))
  local x1 = tonumber(job.x1) or tonumber(job.x)
  local z1 = tonumber(job.z1) or tonumber(job.z)
  local x2 = tonumber(job.x2) or x1
  local z2 = tonumber(job.z2) or z1
  local y = tonumber(job.y) or tonumber(cfg.cruiseY) or 150
  if tonumber(job.cruiseY) then cfg.cruiseY = math.floor(tonumber(job.cruiseY)) end
  if not (x1 and z1) then
    setStatus("error", "bad escort coords")
    return false
  end
  x2, z2 = x2 or x1, z2 or z1
  local midX = math.floor((x1 + x2) / 2)
  local midZ = math.floor((z1 + z2) / 2)
  print(("Escort %s -> %d,%d,%d (cruise %d)"):format(
    tostring(state.jobId), midX, y, midZ, tonumber(cfg.cruiseY) or 150))
  local ok, err = goCruiseTo(midX, y, midZ)
  if not ok then
    setStatus("error", tostring(err))
    return false
  end

  -- Stay in area until stop / ~15 min max / miner goes idle (polled lightly).
  local deadline = os.epoch("utc") + 15 * 60 * 1000
  local points = {
    { x = x1, z = z1 },
    { x = x2, z = z1 },
    { x = x2, z = z2 },
    { x = x1, z = z2 },
    { x = midX, z = midZ },
  }
  local i = 1
  while not state.stop and os.epoch("utc") < deadline do
    local p = points[i]
    i = (i % #points) + 1
    setStatus("escorting", ("patrol %d,%d"):format(p.x, p.z))
    goCruiseTo(p.x, y, p.z)
    -- Hold ~25s so the chunk stays loaded without constant movement
    for _ = 1, 25 do
      if state.stop then break end
      sleep(1)
    end
  end

  if job.returnStage ~= false then
    returnToStage()
  else
    setStatus("idle", "-")
    state.jobId = nil
  end
  return true
end

local function applyDeployment(d)
  local t = tostring(d.botType or ""):lower()
  if t ~= "loader" and t ~= "chunk" and t ~= "chunky" then
    return false, "this turtle runs loader.lua (deploy as loader)"
  end
  cfg.name = tostring(d.name or cfg.name or ("Loader-" .. os.getComputerID()))
  cfg.botType = "loader"
  if type(d.stage) == "table" and d.stage.x then
    cfg.stage = {
      x = math.floor(tonumber(d.stage.x)),
      y = math.floor(tonumber(d.stage.y) or 64),
      z = math.floor(tonumber(d.stage.z)),
    }
  elseif type(d.deposit) == "table" and d.deposit.x then
    -- Parent Center may send stage in the deposit slots for loaders
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
  print("Loader awaiting Parent Center deploy...")
  print(("  Computer ID: %d"):format(os.getComputerID()))
  while true do
    local x, y, z = gps.locate(2)
    rednet.broadcast({
      type = MSG.WORKER_AWAIT,
      name = os.getComputerLabel() or ("Loader-" .. os.getComputerID()),
      kind = "loader", x = x, y = y, z = z,
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
    print("Needs Advanced Peripherals Chunky Turtle to keep chunks loaded.")
  elseif cmd == "status" then
    print(("status=%s task=%s job=%s"):format(state.status, state.task, tostring(state.jobId)))
    print("stage=" .. fmt(cfg.stage) .. "  cruiseY=" .. tostring(cfg.cruiseY))
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
    print("Stop requested — will return to stage after current leg.")
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
      local r = handleCommand(a)
      return r ~= false
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
      name = cfg.name or os.getComputerLabel(),
      botType = "loader",
      state = state.status,
      task = state.task,
      assignment = assignmentText(),
      x = x, y = y, z = z,
      fuel = turtle.getFuelLevel(),
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
        end
      elseif t == MSG.PERMIT_SYNC and type(msg.permits) == "table" then
        titan.setPermits(msg.permits)
      elseif t == MSG.WORKER_DEPLOY then
        local ok, why = applyDeployment(msg)
        titan.send(id, MSG.WORKER_DEPLOYED, {
          ok = ok, err = why, name = cfg.name, botType = "loader",
        })
      elseif t == MSG.PING then
        titan.send(id, MSG.PONG, {
          state = state.status, botType = "loader",
          name = cfg.name, assignment = assignmentText(),
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
os.setComputerLabel(cfg.name)
if cfg.stage then cfg.home = cfg.home or cfg.stage; nav.home = cfg.stage end
pcall(nav.calibrate, true)
setStatus(cfg.stage and "parked" or "idle", "-")
print(("Loader '%s' online. stage=%s cruiseY=%d"):format(
  cfg.name, fmt(cfg.stage), tonumber(cfg.cruiseY) or 150))
print("Tip: Advanced Peripherals Chunky Turtle upgrade required for chunk loading.")

parallel.waitForAny(
  consoleLoop, statusLoop, receiveLoop, jobLoop,
  function() titan.networkLoop("loader") end
)
print("Loader stopped.")
