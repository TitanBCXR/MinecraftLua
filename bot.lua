--[[
  bot.lua  -  Turtle "bot" for the Titan network (CC: Tweaked)
  Titan-Version: 1.1.0

  Runs on a TURTLE that has:
    * a wireless modem (equipped on left/right, or a modem block placed on it)
    * fuel (or set turtle.getFuelLevel() == unlimited in config)
    * a GPS constellation in range (see README) for navigation

  What it does:
    * Registers with the hub over rednet
    * Broadcasts its status (position, fuel, state, current task) periodically
    * Listens for COMMAND messages and executes them
    * Reports back with ACK messages

  Supported commands (sent by hub.lua / poi.lua):
    { cmd = "goto",   x, y, z [, poi] [, job] }  - travel to coordinates
    { cmd = "return" }                            - travel to home position
    { cmd = "refuel" }                            - refuel from inventory
    { cmd = "stop" }                              - cancel current task
    { cmd = "sethome" }                           - remember current position as home

  Extend it by adding entries to the `jobs` table (dig, farm, build, ...).
]]

local titan = dofile("lib/titan.lua")
local nav   = titan.nav

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Bot-" .. os.getComputerID()))

-- Shared state between the worker and the network coroutines.
local state = {
  status = "booting",   -- booting | idle | moving | working | refueling | error
  task   = "-",         -- human-readable current task
  queue  = {},          -- pending commands
  stop   = false,       -- request to abort current task
}

local function setStatus(s, t)
  state.status = s
  if t then state.task = t end
end

--------------------------------------------------------------------------------
-- Job handlers. Return true on success, or false + reason.
-- Add your own custom jobs here; the hub/POI can trigger them via `job`.
--------------------------------------------------------------------------------
local jobs = {}

function jobs.mine(_)
  -- Example: dig a 3-deep hole straight down where the bot is standing.
  for _ = 1, 3 do
    if state.stop then return false, "stopped" end
    turtle.digDown()
    if not turtle.down() then break end
  end
  -- climb back up
  for _ = 1, 3 do turtle.up() end
  return true
end

function jobs.deposit(_)
  -- Example: drop everything downward (e.g. into a chest under the bot).
  for slot = 1, 16 do
    turtle.select(slot)
    turtle.dropDown()
  end
  turtle.select(1)
  return true
end

--------------------------------------------------------------------------------
-- Command execution (runs in the worker coroutine)
--------------------------------------------------------------------------------
local function runCommand(cmd, fromId)
  state.stop = false

  if cmd.cmd == "goto" then
    local where = cmd.poi and ("POI " .. cmd.poi) or
      ("%d,%d,%d"):format(cmd.x, cmd.y, cmd.z)
    setStatus("moving", "-> " .. where)
    nav.ensureFuel(64)
    local ok, err = nav.moveTo(cmd.x, cmd.y, cmd.z)
    if not ok then
      setStatus("error", "nav: " .. tostring(err))
      titan.send(fromId, titan.MSG.ACK, { ok = false, task = state.task, err = err })
      return
    end
    -- Arrived. Run an attached job if requested.
    if cmd.job and jobs[cmd.job] then
      setStatus("working", "job: " .. cmd.job)
      local jok, jerr = jobs[cmd.job](cmd)
      if not jok then
        setStatus("error", "job: " .. tostring(jerr))
        titan.send(fromId, titan.MSG.ACK, { ok = false, task = state.task, err = jerr })
        return
      end
    end
    setStatus("idle", "-")
    titan.send(fromId, titan.MSG.ACK, { ok = true, task = "arrived" })

  elseif cmd.cmd == "return" then
    setStatus("moving", "-> home")
    nav.ensureFuel(64)
    local ok, err = nav.goHome()
    setStatus(ok and "idle" or "error", ok and "-" or ("home: " .. tostring(err)))
    titan.send(fromId, titan.MSG.ACK, { ok = ok, task = "home", err = err })

  elseif cmd.cmd == "refuel" then
    setStatus("refueling", "refuel")
    local lvl = nav.ensureFuel(1000)
    setStatus("idle", "-")
    titan.send(fromId, titan.MSG.ACK, { ok = true, task = "fuel:" .. tostring(lvl) })

  elseif cmd.cmd == "sethome" then
    local ok = nav.setHome()
    titan.send(fromId, titan.MSG.ACK, { ok = ok, task = "home set" })
    setStatus("idle", "-")

  elseif cmd.cmd == "stop" then
    state.stop = true
    setStatus("idle", "-")
    titan.send(fromId, titan.MSG.ACK, { ok = true, task = "stopped" })

  else
    titan.send(fromId, titan.MSG.ACK, { ok = false, err = "unknown cmd " .. tostring(cmd.cmd) })
  end
end

--------------------------------------------------------------------------------
-- Coroutines
--------------------------------------------------------------------------------

-- Push current status onto the network so the hub monitor stays fresh.
local function reportStatus()
  local x, y, z = nav.locate(1)
  titan.broadcast(titan.MSG.STATUS, {
    x = x, y = y, z = z,
    fuel  = turtle.getFuelLevel(),
    state = state.status,
    task  = state.task,
  })
end

local function statusLoop()
  -- Announce ourselves, then heartbeat.
  reportStatus()
  titan.broadcast(titan.MSG.REGISTER, { state = state.status })
  while true do
    os.sleep(5)
    reportStatus()
  end
end

local function receiveLoop()
  while true do
    local id, msg = titan.recv()
    if msg then
      if msg.type == titan.MSG.COMMAND then
        table.insert(state.queue, { cmd = msg, from = id })
      elseif msg.type == titan.MSG.PING then
        titan.send(id, titan.MSG.PONG, { state = state.status })
        titan.broadcast(titan.MSG.REGISTER, { state = state.status })
      end
    end
  end
end

local function workerLoop()
  -- Initial calibration + home.
  setStatus("booting", "calibrating")
  local ok, err = nav.calibrate()
  if ok then
    nav.setHome()
    setStatus("idle", "-")
  else
    setStatus("error", "GPS: " .. tostring(err))
    print("[!] calibration failed: " .. tostring(err))
    print("    Check GPS + fuel + clear space, then send a command.")
    setStatus("idle", "-")
  end

  while true do
    local job = table.remove(state.queue, 1)
    if job then
      runCommand(job.cmd, job.from)
    else
      os.sleep(0.3)
    end
  end
end

print("Titan bot online: " .. (os.getComputerLabel() or ("#" .. os.getComputerID())))
parallel.waitForAny(receiveLoop, statusLoop, workerLoop,
  function() titan.networkLoop("bot") end)
