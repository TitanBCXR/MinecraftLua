--[[
  storage/workers/factory_clutch.lua  -  Wireless factory clutch worker
  Titan-Version: 1.1.0

  A wireless worker that produces items and optionally consumes inputs.
  Listens to the Vault Storage Manager for ON/OFF commands and drives
  Create clutch(es) via redstone.

  Unlike storage_clutch (fill-based local control), this is a remote worker
  that obeys the manager's buffer decisions. The manager alone polls the vault.

  Hardware:
    [Clutch + Integrator] --wired modem--+
    [Clutch + Integrator] --wired modem--+-- cable -- [PC + wired modem]
    [PC] -- wireless modem (for manager commands)
    [Frog port / output inventory] -- wired modem (optional, for transfer notify)
    (or PC redstone face → dust → clutch)

  Setup:
    output <minecraft:item_id>           -- add output item this factory produces
    input <minecraft:item_id>            -- add input item this factory consumes
    manager <computerId>                 -- bind to manager computer ID
    bind redstone <side>                 -- local PC face
    bind integrator <name> [side]        -- add Redstone Integrator
    bind frogport <name>                 -- bind frog port (output inventory for transfer notify)
    unbind integrator|frogport <name>    -- remove peripheral
    invert on|off                        -- powered clutch = run (vs stop)
    label <text>                         -- factory name for manager
    register                             -- send FACTORY_REGISTER to manager
    run                                  -- start listening for commands

  Commands (manager → factory):
    ON  — start production (redstone OFF if not inverted)
    OFF — stop production (redstone ON if not inverted)
]]

local LOCAL_CFG = "factory_clutch.cfg"
local VERSION = "1.1.0"

local titan = nil
if fs.exists("lib/titan.lua") then
  local ok, t = pcall(dofile, "lib/titan.lua")
  if ok then titan = t end
end

local MSG = titan and titan.MSG or {}
local PROTO = (titan and titan.PROTOCOL) or "titan_net"

local cfg = {
  outputs = {},            -- array of minecraft:item_id this factory produces
  inputs = {},             -- array of minecraft:item_id this factory consumes
  managerId = nil,         -- computer ID of the manager
  label = nil,             -- factory name
  integrators = {},        -- array of {name=..., side=...}
  rsSide = nil,            -- local face (fallback)
  frogPort = nil,          -- output inventory for transfer notify (optional)
  invert = false,          -- true = powered clutch runs (vs stops)
  latchedOn = false,       -- last commanded state (ON = stop feed if not inverted)
  heartbeatSecs = 30,      -- heartbeat interval
  
  -- Legacy single item (migrated to outputs)
  item = nil,
}

--------------------------------------------------------------------------------
-- Config persistence
--------------------------------------------------------------------------------
local function loadCfg()
  if not fs.exists(LOCAL_CFG) then return end
  local h = fs.open(LOCAL_CFG, "r")
  if not h then return end
  local raw = h.readAll()
  h.close()
  local ok, t = pcall(textutils.unserialize, raw)
  if ok and type(t) == "table" then
    for k, v in pairs(t) do cfg[k] = v end
  end
  
  -- Migrate legacy single integrator
  if cfg.integrator and cfg.integrator ~= "" then
    local found = false
    for _, i in ipairs(cfg.integrators) do
      if i.name == cfg.integrator then found = true; break end
    end
    if not found then
      table.insert(cfg.integrators, {
        name = cfg.integrator,
        side = cfg.integratorSide or "front"
      })
    end
    cfg.integrator = nil
  end
  
  -- Migrate legacy single item to outputs
  if cfg.item and cfg.item ~= "" then
    local found = false
    for _, out in ipairs(cfg.outputs) do
      if out == cfg.item then found = true; break end
    end
    if not found then
      table.insert(cfg.outputs, cfg.item)
    end
    cfg.item = nil
  end
  
  -- Ensure arrays
  if type(cfg.outputs) ~= "table" then cfg.outputs = {} end
  if type(cfg.inputs) ~= "table" then cfg.inputs = {} end
  if type(cfg.integrators) ~= "table" then cfg.integrators = {} end
end

local function saveCfg()
  local h = fs.open(LOCAL_CFG, "w")
  if not h then return false end
  h.write(textutils.serialize(cfg))
  h.close()
  return true
end

loadCfg()

--------------------------------------------------------------------------------
-- Redstone control
--------------------------------------------------------------------------------
local function setRedstone(want)
  local state = want
  if cfg.invert then state = not state end
  
  -- Set local face
  if cfg.rsSide then
    pcall(redstone.setOutput, cfg.rsSide, state)
  end
  
  -- Set all integrators
  for _, i in ipairs(cfg.integrators) do
    if peripheral.isPresent(i.name) then
      local w = peripheral.wrap(i.name)
      if w and type(w.setOutput) == "function" then
        pcall(w.setOutput, i.side, state)
      end
    end
  end
  
  cfg.latchedOn = want
  saveCfg()
  return true
end

--------------------------------------------------------------------------------
-- Wireless network
--------------------------------------------------------------------------------
local function openWireless()
  for _, side in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(side)
    if t == "modem" then
      local m = peripheral.wrap(side)
      if m and not m.isWireless() then
        -- skip wired modems
      elseif m and m.isWireless() then
        if not m.isOpen(rednet.CHANNEL_REPEAT) then
          m.open(rednet.CHANNEL_REPEAT)
        end
        rednet.open(side)
        return side
      end
    end
  end
  return nil
end

-- Check if frog port is actively sending (has items)
local function isSending()
  if not cfg.frogPort or cfg.frogPort == "" then return false end
  if not peripheral.isPresent(cfg.frogPort) then return false end
  
  local wrap = peripheral.wrap(cfg.frogPort)
  if not wrap or type(wrap.list) ~= "function" then return false end
  
  local ok, list = pcall(wrap.list)
  if not ok or type(list) ~= "table" then return false end
  
  -- If frog port has items, we're sending
  for _ in pairs(list) do
    return true
  end
  return false
end

local function sendToManager(msgType, payload)
  if not cfg.managerId then return false end
  payload = payload or {}
  payload.type = msgType
  payload.from = os.getComputerID()
  payload.outputs = cfg.outputs
  payload.inputs = cfg.inputs
  payload.label = cfg.label or os.getComputerLabel() or ("Factory-" .. os.getComputerID())
  payload.version = VERSION
  payload.sending = isSending()
  rednet.send(cfg.managerId, payload, PROTO)
  return true
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function cmdHelp()
  print("Factory Clutch v" .. VERSION)
  print("\nSetup:")
  print("  output <minecraft:id>     -- add output item")
  print("  input <minecraft:id>      -- add input item")
  print("  remove output|input <id>  -- remove item")
  print("  manager <computerId>")
  print("  bind redstone <side>")
  print("  bind integrator <name> [side]")
  print("  bind frogport <name>      -- output inventory")
  print("  unbind integrator|frogport <name>")
  print("  invert on|off")
  print("  label <text>")
  print("  register    -- send FACTORY_REGISTER")
  print("\nRun:")
  print("  run         -- listen for manager")
  print("  status")
  print("  test on|off")
  print("  help | exit")
end

local function cmdStatus()
  print("Factory Clutch v" .. VERSION)
  print(("Outputs: %s"):format(#cfg.outputs > 0 and table.concat(cfg.outputs, ", ") or "(none)"))
  print(("Inputs:  %s"):format(#cfg.inputs > 0 and table.concat(cfg.inputs, ", ") or "(none)"))
  print(("Manager: %s"):format(cfg.managerId or "(not set)"))
  print(("Label:   %s"):format(cfg.label or "(not set)"))
  print(("State:   %s"):format(cfg.latchedOn and "OFF (stopped)" or "ON (running)"))
  print(("Invert:  %s"):format(cfg.invert and "on" or "off"))
  print(("Sending: %s"):format(isSending() and "YES (frog port active)" or "no"))
  
  local rsOut = {}
  if cfg.rsSide then
    table.insert(rsOut, cfg.rsSide)
  end
  for _, i in ipairs(cfg.integrators) do
    table.insert(rsOut, ("%s:%s"):format(i.name, i.side))
  end
  print(("Redstone: %s"):format(#rsOut > 0 and table.concat(rsOut, ", ") or "(none)"))
  
  if cfg.frogPort then
    print(("Frog port: %s"):format(cfg.frogPort))
  end
end

local function cmdOutput(args)
  if #args < 2 then
    print("Usage: output <minecraft:item_id>")
    return
  end
  local itemId = args[2]
  for _, out in ipairs(cfg.outputs) do
    if out == itemId then
      print(("Already in outputs: %s"):format(itemId))
      return
    end
  end
  table.insert(cfg.outputs, itemId)
  saveCfg()
  print(("Added output: %s"):format(itemId))
end

local function cmdInput(args)
  if #args < 2 then
    print("Usage: input <minecraft:item_id>")
    return
  end
  local itemId = args[2]
  for _, inp in ipairs(cfg.inputs) do
    if inp == itemId then
      print(("Already in inputs: %s"):format(itemId))
      return
    end
  end
  table.insert(cfg.inputs, itemId)
  saveCfg()
  print(("Added input: %s"):format(itemId))
end

local function cmdRemove(args)
  if #args < 3 then
    print("Usage: remove output|input <minecraft:item_id>")
    return
  end
  
  local kind = args[2]:lower()
  local itemId = args[3]
  
  if kind == "output" then
    for i, out in ipairs(cfg.outputs) do
      if out == itemId then
        table.remove(cfg.outputs, i)
        saveCfg()
        print(("Removed output: %s"):format(itemId))
        return
      end
    end
    print(("Output not found: %s"):format(itemId))
  elseif kind == "input" then
    for i, inp in ipairs(cfg.inputs) do
      if inp == itemId then
        table.remove(cfg.inputs, i)
        saveCfg()
        print(("Removed input: %s"):format(itemId))
        return
      end
    end
    print(("Input not found: %s"):format(itemId))
  else
    print("Usage: remove output|input <minecraft:item_id>")
  end
end

local function cmdManager(args)
  if #args < 2 then
    print("Usage: manager <computerId>")
    return
  end
  local id = tonumber(args[2])
  if not id then
    print("Invalid computer ID")
    return
  end
  cfg.managerId = id
  saveCfg()
  print(("Manager set to: %d"):format(cfg.managerId))
end

local function cmdBind(args)
  if #args < 3 then
    print("Usage: bind redstone <side> | bind integrator <name> [side] | bind frogport <name>")
    return
  end
  
  if args[2] == "redstone" then
    cfg.rsSide = args[3]
    saveCfg()
    print(("Bound redstone to: %s"):format(cfg.rsSide))
  elseif args[2] == "integrator" then
    local name = args[3]
    local side = args[4] or "front"
    
    -- Check if already exists
    for i, int in ipairs(cfg.integrators) do
      if int.name == name then
        cfg.integrators[i].side = side
        saveCfg()
        print(("Updated integrator %s side to: %s"):format(name, side))
        return
      end
    end
    
    table.insert(cfg.integrators, {name = name, side = side})
    saveCfg()
    print(("Added integrator: %s:%s"):format(name, side))
  elseif args[2] == "frogport" then
    cfg.frogPort = args[3]
    saveCfg()
    print(("Bound frog port to: %s"):format(cfg.frogPort))
  else
    print("Usage: bind redstone <side> | bind integrator <name> [side] | bind frogport <name>")
  end
end

local function cmdUnbind(args)
  if #args < 3 then
    print("Usage: unbind integrator|frogport <name>")
    return
  end
  
  if args[2] == "integrator" then
    local name = args[3]
    for i, int in ipairs(cfg.integrators) do
      if int.name == name then
        table.remove(cfg.integrators, i)
        saveCfg()
        print(("Removed integrator: %s"):format(name))
        return
      end
    end
    print(("Integrator not found: %s"):format(name))
  elseif args[2] == "frogport" then
    cfg.frogPort = nil
    saveCfg()
    print("Removed frog port")
  else
    print("Usage: unbind integrator|frogport <name>")
  end
end

local function cmdInvert(args)
  if #args < 2 then
    print("Usage: invert on|off")
    return
  end
  
  local val = args[2]:lower()
  if val == "on" or val == "true" then
    cfg.invert = true
  elseif val == "off" or val == "false" then
    cfg.invert = false
  else
    print("Usage: invert on|off")
    return
  end
  
  saveCfg()
  print(("Invert: %s"):format(cfg.invert and "on" or "off"))
end

local function cmdLabel(args)
  if #args < 2 then
    print("Usage: label <text>")
    return
  end
  
  cfg.label = table.concat(args, " ", 2)
  saveCfg()
  print(("Label set to: %s"):format(cfg.label))
end

local function cmdTest(args)
  if #args < 2 then
    print("Usage: test on|off")
    return
  end
  
  local val = args[2]:lower()
  local want = false
  if val == "on" or val == "true" then
    want = false  -- ON = running = redstone OFF (if not inverted)
  elseif val == "off" or val == "false" then
    want = true   -- OFF = stopped = redstone ON (if not inverted)
  else
    print("Usage: test on|off")
    return
  end
  
  setRedstone(want)
  print(("Test: factory %s"):format(want and "OFF" or "ON"))
end

local function cmdRegister()
  if #cfg.outputs == 0 then
    print("Set outputs first: output <minecraft:id>")
    return
  end
  if not cfg.managerId then
    print("Set manager first: manager <computerId>")
    return
  end
  
  local wireless = openWireless()
  if not wireless then
    print("No wireless modem found")
    return
  end
  
  sendToManager(MSG.FACTORY_REGISTER, {
    state = cfg.latchedOn and "OFF" or "ON"
  })
  print(("Sent FACTORY_REGISTER to manager %d"):format(cfg.managerId))
end

local function cmdRun()
  if #cfg.outputs == 0 then
    print("Set outputs first: output <minecraft:id>")
    return
  end
  if not cfg.managerId then
    print("Set manager first: manager <computerId>")
    return
  end
  
  local wireless = openWireless()
  if not wireless then
    print("No wireless modem found")
    return
  end
  
  print(("Factory Clutch running"))
  print(("  Outputs: %s"):format(table.concat(cfg.outputs, ", ")))
  if #cfg.inputs > 0 then
    print(("  Inputs:  %s"):format(table.concat(cfg.inputs, ", ")))
  end
  print("Listening for manager commands (Ctrl+T to stop)")
  
  -- Register on start
  sendToManager(MSG.FACTORY_REGISTER, {
    state = cfg.latchedOn and "OFF" or "ON"
  })
  
  local lastHeartbeat = os.clock()
  
  while true do
    local timer = os.startTimer(1)
    local event, p1, p2, p3, p4 = os.pullEvent()
    
    if event == "rednet_message" then
      local senderId, msg, proto = p1, p2, p3
      
      if proto == PROTO and type(msg) == "table" then
        if msg.type == MSG.FACTORY_COMMAND and senderId == cfg.managerId then
          local cmd = msg.command
          if cmd == "ON" then
            setRedstone(false)  -- ON = running = redstone OFF
            sendToManager(MSG.FACTORY_ACK, {command = "ON", state = "ON"})
            print(("← Manager: ON (running)"))
          elseif cmd == "OFF" then
            setRedstone(true)   -- OFF = stopped = redstone ON
            sendToManager(MSG.FACTORY_ACK, {command = "OFF", state = "OFF"})
            print(("← Manager: OFF (stopped)"))
          end
        end
      end
    elseif event == "timer" and p1 == timer then
      -- Heartbeat
      local now = os.clock()
      if now - lastHeartbeat >= cfg.heartbeatSecs then
        sendToManager(MSG.FACTORY_STATUS, {
          state = cfg.latchedOn and "OFF" or "ON",
          uptime = os.clock()
        })
        lastHeartbeat = now
      end
    elseif event == "terminate" then
      print("\nStopped")
      break
    end
  end
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
local function main()
  if #cfg.outputs > 0 and cfg.managerId then
    print(("Factory: %s → Manager %d"):format(table.concat(cfg.outputs, ", "), cfg.managerId))
    print("Type 'run' to start, 'help' for commands")
  else
    print("Factory Clutch v" .. VERSION)
    print("Type 'help' for setup commands")
  end
  
  while true do
    write("> ")
    local input = read()
    if not input or input == "" then
      -- skip
    else
      local args = {}
      for w in input:gmatch("%S+") do
        table.insert(args, w)
      end
      
      local cmd = args[1] and args[1]:lower() or ""
      
      if cmd == "help" then
        cmdHelp()
      elseif cmd == "status" then
        cmdStatus()
      elseif cmd == "output" then
        cmdOutput(args)
      elseif cmd == "input" then
        cmdInput(args)
      elseif cmd == "remove" then
        cmdRemove(args)
      elseif cmd == "manager" then
        cmdManager(args)
      elseif cmd == "bind" then
        cmdBind(args)
      elseif cmd == "unbind" then
        cmdUnbind(args)
      elseif cmd == "invert" then
        cmdInvert(args)
      elseif cmd == "label" then
        cmdLabel(args)
      elseif cmd == "test" then
        cmdTest(args)
      elseif cmd == "register" then
        cmdRegister()
      elseif cmd == "run" then
        cmdRun()
      elseif cmd == "exit" or cmd == "quit" then
        break
      else
        print("Unknown command. Type 'help' for commands.")
      end
    end
  end
end

main()
