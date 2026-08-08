--[[
  gpshost.lua  -  Easy GPS host for the Titan network (CC: Tweaked)
  Titan-Version: 1.1.7

  Bots locate themselves with gps.locate(), which needs at least FOUR GPS host
  computers in range. Run this on each of those computers. On first run it asks
  for the MODEM's coordinates (or multi-samples GPS if a constellation already
  exists), saves them, offers to auto-start on boot, then hosts forever.

  Hosts must report the modem block — wrong host Y is the usual cause of bots
  reading Y one block high/low.

  Also joins the Titan mesh and hosts an SSH shell (when lib/titan.lua is present)
  so you can jump in remotely and `reboot` if needed.

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

local function openModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
    end
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

openModem()
os.setComputerLabel(os.getComputerLabel() or ("GPS-" .. os.getComputerID()))

local function multiLocate(samples, timeout)
  samples = samples or 9
  local per = (timeout or 4) / samples
  local xs, ys, zs = {}, {}, {}
  for i = 1, samples do
    local x, y, z = gps.locate(math.max(0.3, per))
    if x then
      xs[#xs + 1] = x; ys[#ys + 1] = y; zs[#zs + 1] = z
    end
    if i < samples then sleep(0.05) end
  end
  if #xs == 0 then return nil end
  local function pick(t)
    table.sort(t)
    local lo, hi = t[1], t[#t]
    local mid = (lo + hi) / 2
    return math.floor(mid + 0.5), lo, hi
  end
  local x, xLo, xHi = pick(xs)
  local y, yLo, yHi = pick(ys)
  local z, zLo, zHi = pick(zs)
  return x, y, z, { n = #xs, xLo = xLo, xHi = xHi, yLo = yLo, yHi = yHi, zLo = zLo, zHi = zHi }
end

local cfg = load()
if not cfg then
  print("Trying to auto-detect modem position (multi-sample)...")
  local x, y, z, info = multiLocate(9, 4)
  if x then
    print(("Auto-located: %d, %d, %d  (n=%d  Y %.2f..%.2f)"):format(
      x, y, z, info.n, info.yLo, info.yHi))
  else
    print("No existing GPS. Enter THIS MODEM's block coordinates.")
    print("(F3 → Targeted Block on the modem itself, not the computer.)")
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
print("SSH shell on mesh when lib/titan.lua is installed. Ctrl+T to stop.")

local function gpsHostLoop()
  local modems = {}
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      modems[#modems + 1] = side
      peripheral.call(side, "open", gps.CHANNEL_GPS)
    end
  end
  while true do
    local _, side, ch, reply, message = os.pullEvent("modem_message")
    if ch == gps.CHANNEL_GPS and message == "PING" and reply then
      peripheral.call(side, "transmit", reply, gps.CHANNEL_GPS,
        { cfg.x, cfg.y, cfg.z })
    end
  end
end

if fs.exists("lib/titan.lua") then
  local titan = dofile("lib/titan.lua")
  parallel.waitForAny(gpsHostLoop, function() titan.networkLoop("gpshost") end)
else
  -- Fallback: stock gps host only (no remote shell).
  shell.run("gps", "host", tostring(cfg.x), tostring(cfg.y), tostring(cfg.z))
end
