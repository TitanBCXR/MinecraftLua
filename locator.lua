--[[
  locator.lua  -  Pocket GPS locator for the Titan network (CC: Tweaked)

  A handheld you carry: it shows your live GPS position, lets you save waypoints,
  and gives distance + compass bearing to each. It can also pull the network's
  POIs and bots and point you at them. The personal counterpart to admin.lua.

  Requires: a POCKET computer with a WIRELESS MODEM upgrade, `lib/titan.lua`,
  and an existing GPS constellation in range (see README).

  NOTE: a pocket computer cannot HOST GPS (hosts must be stationary) - use
  gpshost.lua for that. This tool only LOCATES using GPS that already exists.

  Run:  locator
]]

local titan = dofile("lib/titan.lua")
local MSG   = titan.MSG

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Locator-" .. os.getComputerID()))

local CFG       = "locator.cfg"
local waypoints = {}     -- [name] = { x, y, z }
local pois      = {}     -- [name] = { x, y, z, seen }
local bots      = {}     -- [id]   = { name, botType, x, y, z, state, seen }
local last      = nil    -- last position, for movement-based heading
local headAngle = nil    -- degrees (0=N,90=E,...) from last movement

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  if type(d) == "table" then waypoints = d end
end
local function saveCfg()
  local f = fs.open(CFG, "w"); f.write(textutils.serialize(waypoints)); f.close()
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------
local CARDS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

-- Absolute compass angle (deg) of a vector (dx,dz). MC: N=-Z, E=+X, S=+Z, W=-X.
local function angleOf(dx, dz)
  return (math.deg(math.atan2(dx, -dz)) + 360) % 360
end
local function cardinal(dx, dz)
  if dx == 0 and dz == 0 then return "--" end
  return CARDS[(math.floor(angleOf(dx, dz) / 45 + 0.5) % 8) + 1]
end

local function locate()
  local x, y, z = gps.locate(2)
  if not x then return nil end
  x, y, z = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
  if last and (x ~= last.x or z ~= last.z) then
    headAngle = angleOf(x - last.x, z - last.z)
  end
  last = { x = x, y = y, z = z }
  return x, y, z
end

-- Describe how to get from (x,y,z) to (tx,ty,tz): distance, cardinal, dy, and a
-- relative turn if we know which way you're moving.
local function bearingTo(x, y, z, tx, ty, tz)
  local dx, dz = tx - x, tz - z
  local dist = math.floor(math.sqrt(dx * dx + dz * dz) + 0.5)
  local card = cardinal(dx, dz)
  local dy = ty - y
  local rel = ""
  if headAngle and dist > 0 then
    local diff = ((angleOf(dx, dz) - headAngle + 540) % 360) - 180
    if math.abs(diff) <= 30 then rel = "ahead"
    elseif math.abs(diff) >= 150 then rel = "behind"
    elseif diff > 0 then rel = "right"
    else rel = "left" end
  end
  return dist, card, dy, rel
end

local function fmtTarget(x, y, z, tx, ty, tz)
  local dist, card, dy, rel = bearingTo(x, y, z, tx, ty, tz)
  local vert = dy == 0 and "" or ((dy > 0 and " up" or " down") .. math.abs(dy))
  return ("%dm %s%s%s"):format(dist, card, vert, rel ~= "" and (" (" .. rel .. ")") or "")
end

--------------------------------------------------------------------------------
-- Network listener (POIs + bots), optional but handy
--------------------------------------------------------------------------------
local function listenerLoop()
  titan.broadcast(MSG.PING, {})
  while true do
    local id, msg = titan.recv()
    if msg then
      local t = msg.type
      if t == MSG.POI_REGISTER then
        pois[msg.poi or ("poi#" .. id)] = { x = msg.x, y = msg.y, z = msg.z, seen = os.epoch("utc") }
      elseif t == MSG.STATUS or t == MSG.REGISTER or t == MSG.BOT_REGISTER then
        local b = bots[id] or {}
        b.name = msg.name or b.name; b.botType = msg.botType or b.botType
        b.x, b.y, b.z = msg.x or b.x, msg.y or b.y, msg.z or b.z
        b.state = msg.state or b.state; b.seen = os.epoch("utc")
        bots[id] = b
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Live radar view (any key exits)
--------------------------------------------------------------------------------
local function nearest(x, y, z)
  local rows = {}
  for name, w in pairs(waypoints) do
    local d = bearingTo(x, y, z, w.x, w.y, w.z)
    rows[#rows + 1] = { label = name, d = d, tx = w.x, ty = w.y, tz = w.z, kind = "wp" }
  end
  for name, p in pairs(pois) do
    if (os.epoch("utc") - (p.seen or 0)) < 60000 then
      local d = bearingTo(x, y, z, p.x, p.y, p.z)
      rows[#rows + 1] = { label = "*" .. name, d = d, tx = p.x, ty = p.y, tz = p.z, kind = "poi" }
    end
  end
  table.sort(rows, function(a, b) return a.d < b.d end)
  return rows
end

local function drawLive()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black); term.clear()
  local function line(y, txt, c)
    term.setCursorPos(1, y); if term.setTextColor then term.setTextColor(c or colors.white) end
    term.write(tostring(txt):sub(1, w))
  end
  local x, y, z = locate()
  if not x then line(1, "No GPS fix", colors.red); line(3, "[any key: exit]", colors.gray); return end
  line(1, ("@ %d,%d,%d"):format(x, y, z), colors.yellow)
  line(2, "heading: " .. (headAngle and cardinal(math.sin(math.rad(headAngle)), -math.cos(math.rad(headAngle))) or "move to set"), colors.lightGray)
  local row = 3
  for _, r in ipairs(nearest(x, y, z)) do
    if row >= h then break end
    line(row, ("%-9s %s"):format(r.label:sub(1, 9), fmtTarget(x, y, z, r.tx, r.ty, r.tz)),
      r.kind == "poi" and colors.lime or colors.white)
    row = row + 1
  end
  if row < h then line(h, "[any key: exit]", colors.gray) end
end

local function liveView()
  local timer = os.startTimer(1)
  while true do
    drawLive()
    local ev, p1 = os.pullEvent()
    if ev == "timer" and p1 == timer then timer = os.startTimer(1)
    elseif ev == "key" or ev == "char" or ev == "mouse_click" or ev == "terminate" then
      term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
      if term.setTextColor then term.setTextColor(colors.white) end
      return
    end
  end
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function consoleLoop()
  loadCfg()
  term.clear(); term.setCursorPos(1, 1)
  print("== Titan Locator ==")
  print("Type 'help'. 'live' for the radar.")
  while true do
    write("loc> ")
    local a = {}
    for word in tostring(read()):gmatch("%S+") do a[#a + 1] = word end
    local cmd = (a[1] or ""):lower()

    if cmd == "" then
      -- ignore
    elseif cmd == "help" then
      print("here            show current position")
      print("live            full-screen radar (any key exits)")
      print("mark <name>     save current spot as a waypoint")
      print("wp              list waypoints w/ distance + bearing")
      print("go <name>       bearing to a waypoint")
      print("del <name>      delete a waypoint")
      print("pois | bots     network targets w/ bearing")
      print("exit")

    elseif cmd == "here" or cmd == "pos" then
      local x, y, z = locate()
      if x then print(("%d, %d, %d"):format(x, y, z)) else print("No GPS fix.") end

    elseif cmd == "live" then
      liveView()

    elseif cmd == "mark" then
      local name = a[2]
      if not name then print("Usage: mark <name>")
      else
        local x, y, z = locate()
        if not x then print("No GPS fix - cannot mark.")
        else waypoints[name] = { x = x, y = y, z = z }; saveCfg()
          print(("Saved '%s' @ %d,%d,%d"):format(name, x, y, z)) end
      end

    elseif cmd == "wp" or cmd == "list" then
      local x, y, z = locate()
      local any = false
      for name, wp in pairs(waypoints) do
        any = true
        if x then print(("%-10s %s"):format(name, fmtTarget(x, y, z, wp.x, wp.y, wp.z)))
        else print(("%-10s %d,%d,%d"):format(name, wp.x, wp.y, wp.z)) end
      end
      if not any then print("(no waypoints - use 'mark <name>')") end

    elseif cmd == "go" then
      local wp = waypoints[a[2] or ""]
      local x, y, z = locate()
      if not wp then print("No waypoint: " .. tostring(a[2]))
      elseif not x then print("No GPS fix.")
      else print(("%s -> %s  (%d,%d,%d)"):format(a[2], fmtTarget(x, y, z, wp.x, wp.y, wp.z), wp.x, wp.y, wp.z)) end

    elseif cmd == "del" then
      if waypoints[a[2] or ""] then waypoints[a[2]] = nil; saveCfg(); print("Deleted " .. a[2])
      else print("No waypoint: " .. tostring(a[2])) end

    elseif cmd == "pois" then
      local x, y, z = locate()
      local any = false
      for name, p in pairs(pois) do
        any = true
        if x then print(("%-10s %s"):format(name, fmtTarget(x, y, z, p.x, p.y, p.z)))
        else print(("%-10s %d,%d,%d"):format(name, p.x, p.y, p.z)) end
      end
      if not any then print("(no POIs heard yet)") end

    elseif cmd == "bots" then
      local x, y, z = locate()
      local any = false
      for id, b in pairs(bots) do
        if (os.epoch("utc") - (b.seen or 0)) < 30000 then
          any = true
          if x and b.x then print(("%-10s %s %s"):format((b.name or ("#" .. id)):sub(1, 10), b.state or "?", fmtTarget(x, y, z, b.x, b.y, b.z)))
          else print(("%-10s %s"):format(b.name or ("#" .. id), b.state or "?")) end
        end
      end
      if not any then print("(no bots heard yet)") end

    elseif cmd == "exit" or cmd == "quit" then
      return
    else
      print("Unknown: " .. cmd .. " (type 'help')")
    end
  end
end

print("Titan locator online.")
parallel.waitForAny(listenerLoop, consoleLoop,
  function() titan.registerLoop("locator") end)
print("Locator closed.")
