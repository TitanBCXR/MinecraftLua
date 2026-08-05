--[[
  gpshost.lua  -  Easy GPS host for the Titan network (CC: Tweaked)

  Bots locate themselves with gps.locate(), which needs at least FOUR GPS host
  computers in range. Run this on each of those computers. On first run it asks
  for the computer's own coordinates (or auto-detects them if a constellation
  already exists), saves them, offers to auto-start on boot, then hosts forever.

  Requirements: a WIRELESS (ideally ENDER) modem on this computer.

  Placement tips for a good fix:
    * Use 4+ hosts.
    * Spread them out - do NOT put them in a straight line or all at the same
      height. Varying X, Z AND Y gives the cleanest triangulation.
    * Ender modems = unlimited range (easiest). Plain wireless modems are
      range-limited and can't cross dimensions.
]]

local CFG = "gpshost.cfg"

local function hasWirelessModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
      return true
    end
  end
  return false
end

local function load()
  if not fs.exists(CFG) then return nil end
  local f = fs.open(CFG, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  return d
end

local function save(c)
  local f = fs.open(CFG, "w"); f.write(textutils.serialize(c)); f.close()
end

local function askNum(label)
  while true do
    write(label .. ": ")
    local n = tonumber(read())
    if n then return n end
    print("Please enter a number.")
  end
end

--------------------------------------------------------------------------------
term.clear(); term.setCursorPos(1, 1)
print("== Titan GPS Host ==")

if not hasWirelessModem() then
  printError("No wireless modem attached. Put a wireless/ender modem on this")
  printError("computer, then run gpshost again.")
  return
end

os.setComputerLabel(os.getComputerLabel() or ("GPS-" .. os.getComputerID()))

local cfg = load()
if not cfg then
  -- If a constellation already exists, we can self-locate; otherwise ask.
  print("Trying to auto-detect position...")
  local x, y, z = gps.locate(2)
  if x then
    x, y, z = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
    print(("Auto-located: %d, %d, %d"):format(x, y, z))
  else
    print("No existing GPS. Enter THIS computer's block coordinates.")
    print("(In-game press F3; point at this computer to read 'Targeted Block'.)")
    x = askNum("X")
    y = askNum("Y")
    z = askNum("Z")
  end
  cfg = { x = x, y = y, z = z }
  save(cfg)

  write("Auto-start hosting on boot? [Y/n] ")
  local yn = read():lower()
  if yn == "" or yn == "y" then
    local f = fs.open("startup.lua", "w"); f.write('shell.run("gpshost.lua")\n'); f.close()
    print("Wrote startup.lua.")
  end
end

print(("Hosting GPS at %d, %d, %d ..."):format(cfg.x, cfg.y, cfg.z))
print("Set up 4+ of these, spread out. Ctrl+T to stop.")
-- Hand off to the built-in gps host program (hosts until stopped).
shell.run("gps", "host", tostring(cfg.x), tostring(cfg.y), tostring(cfg.z))
