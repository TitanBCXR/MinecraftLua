--[[
  train_node.lua  -  Create train mesh node for Titan (CC: Tweaked)
  Titan-Version: 1.0.0

  Put this on a computer glued to a Create train (with a wireless/ender modem).

  Create turns the train into a contraption when assembled — CC shuts the
  computer down. When the train stops / blocks come back, the computer reboots.
  This program writes startup.lua so it auto-restarts and rejoins the Titan mesh.

  It is a lightweight mesh hop + GPS announcer (kind "train"), NOT a MAIN router.
  Keep your MAIN router on a stationary computer.

  Setup:
    1. Glue computer + modem onto the train
    2. Install / run:  train_node
    3. Assemble the train — it will go offline while moving (normal)
    4. When the train is loaded again / stops, it should boot and come online

  Commands: status | hostname [name] | startup | help | exit
]]

local titan = dofile("lib/titan.lua")
local MSG  = titan.MSG
local ROUTER = titan.ROUTER_PROTOCOL or "titan_router"

local CFG = "train_node.cfg"
local cfg = { name = nil }

local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  if type(d) == "table" then for k, v in pairs(d) do cfg[k] = v end end
end

local function saveCfg()
  local f = fs.open(CFG, "w"); f.write(textutils.serialize(cfg)); f.close()
end

local function ensureStartup()
  local want = 'shell.run("train_node.lua")\n'
  if fs.exists("startup.lua") then
    local f = fs.open("startup.lua", "r"); local cur = f.readAll() or ""; f.close()
    if cur:find("train_node", 1, true) then return false end
  end
  local f = fs.open("startup.lua", "w"); f.write(want); f.close()
  return true
end

-- After Create reassembles blocks, peripherals can lag a moment.
local function findModemSide()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then return name end
  end
  return nil
end

local function waitForModem(timeout)
  timeout = timeout or 15
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local side = findModemSide()
    if side then
      local ok = pcall(titan.openModem)
      return ok, side
    end
    sleep(0.5)
  end
  local side = findModemSide()
  if side then
    local ok = pcall(titan.openModem)
    return ok, side
  end
  return false, nil
end

local function locate()
  if titan.gpsFix then
    local x, y, z = titan.gpsFix({ timeout = 2, samples = 3 })
    if x then return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5) end
  end
  local x, y, z = gps.locate(2)
  if x then return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5) end
  return nil
end

local lastPos = nil

local function announce()
  local name = os.getComputerLabel() or cfg.name or ("Train-" .. os.getComputerID())
  local x, y, z = locate()
  if x then lastPos = { x = x, y = y, z = z } end
  local p = lastPos
  rednet.broadcast({
    type = "hello",
    kind = "train",
    name = name,
    hostname = name,
    x = p and p.x, y = p and p.y, z = p and p.z,
    train = true,
  }, ROUTER)
  if MSG and MSG.STATUS then
    pcall(titan.broadcast, MSG.STATUS, {
      name = name, botType = "train",
      x = p and p.x, y = p and p.y, z = p and p.z,
      state = "online", task = "train",
    })
  end
end

local function announceLoop()
  while true do
    pcall(announce)
    sleep(8)
  end
end

local function consoleLoop()
  print("Type 'help'. This node rejoins the mesh after each Create reboot.")
  while true do
    write("train> ")
    local a = {}
    for w in tostring(read()):gmatch("%S+") do a[#a + 1] = w end
    local cmd = (a[1] or ""):lower()
    if cmd == "" then
    elseif cmd == "help" then
      print("status     modem + GPS + mesh")
      print("hostname [name]")
      print("startup    (re)write startup.lua -> train_node")
      print("announce   ping the router directory now")
      print("exit")
    elseif cmd == "status" then
      local ok, side = false, nil
      for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then ok, side = true, name; break end
      end
      print(("modem: %s"):format(ok and tostring(side) or "(none — glue a modem)"))
      print(("label: %s"):format(os.getComputerLabel() or "?"))
      local x, y, z = locate()
      if x then
        print(("gps: %d, %d, %d"):format(x, y, z))
      else
        print("gps: (no fix — train may be moving / no constellation)")
      end
      local main = titan.getMainRouterId and titan.getMainRouterId()
      print(("main router: %s"):format(main and ("#" .. main) or "(not found yet)"))
      print("Note: offline while Create has the train assembled as an entity is normal.")
    elseif cmd == "hostname" or cmd == "host" then
      if not a[2] then
        print("hostname: " .. (os.getComputerLabel() or "?"))
      else
        local name, err = titan.setHostname(table.concat(a, " ", 2), "train")
        if name then
          cfg.name = name; saveCfg()
          print("hostname set: " .. name)
          announce()
        else print(tostring(err)) end
      end
    elseif cmd == "startup" then
      if ensureStartup() then print("Wrote startup.lua -> train_node.lua")
      else print("startup.lua already points at train_node.") end
    elseif cmd == "announce" or cmd == "ping" then
      announce()
      print("Announced.")
    elseif cmd == "exit" or cmd == "quit" then
      return
    else
      print("Unknown: " .. cmd)
    end
  end
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------
loadCfg()
local label = cfg.name or os.getComputerLabel() or ("Train-" .. os.getComputerID())
os.setComputerLabel(label)
cfg.name = label
saveCfg()

if ensureStartup() then
  print("Wrote startup.lua (auto-run after Create train reboot).")
end

print(("Titan train node #%d '%s'"):format(os.getComputerID(), label))
print("Waiting for modem after assemble...")
local okModem, modemSide = waitForModem(20)
if okModem then
  print("Modem ready: " .. tostring(modemSide))
else
  print("No modem yet — glue a wireless/ender modem to this computer.")
end

pcall(titan.reauth, "train")
announce()

print("Online when this chunk is loaded. Moving/assembled = offline (Create).")
print("Ctrl+T to stop.")

parallel.waitForAny(
  consoleLoop,
  announceLoop,
  function() titan.networkLoop("train") end
)
print("Train node stopped.")
