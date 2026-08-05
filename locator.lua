--[[
  locator.lua  -  Pocket GPS locator for the Titan network (CC: Tweaked)
  Titan-Version: 1.1.4

  A handheld you carry: live GPS, waypoints, and a top-down RADAR GRID of
  routers / modems relative to YOU (pocket PC at center). Modems named by
  compass from the main router (North, East, NE-1, …) light up on the map.

  Requires: a POCKET computer with a WIRELESS MODEM upgrade, `lib/titan.lua`,
  and an existing GPS constellation in range (see README).

  NOTE: a pocket computer cannot HOST GPS (hosts must be stationary) - use
  router.lua / gpshost.lua for that. This tool only LOCATES.

  Run:  locator
  Tip:  `live` opens the radar (default focus). +/- zoom, Tab cycles modems.
]]

local titan = dofile("lib/titan.lua")
local MSG   = titan.MSG
local ROUTER = titan.ROUTER_PROTOCOL or "titan_router"

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Locator-" .. os.getComputerID()))

local CFG       = "locator.cfg"
local waypoints = {}     -- [name] = { x, y, z }
local pois      = {}     -- [name] = { x, y, z, seen }
local bots      = {}     -- [id]   = { name, botType, x, y, z, state, seen }
local nodes     = {}     -- [id]   = { name, kind, x, y, z, seen } routers/modems
local last      = nil    -- last position, for movement-based heading
local headAngle = nil    -- degrees (0=N,90=E,...) from last movement
local mapScale  = 8      -- blocks per cell (zoom)
local focusIdx  = 1      -- which modem/router is highlighted

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r"); local d = textutils.unserialize(f.readAll()); f.close()
  if type(d) == "table" then
    if type(d.waypoints) == "table" then waypoints = d.waypoints
    else waypoints = d end
    if tonumber(d.scale) then mapScale = tonumber(d.scale) end
  end
end
local function saveCfg()
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize({ waypoints = waypoints, scale = mapScale }))
  f.close()
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------
local CARDS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

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

local function upsertNode(id, entry)
  if not id or not entry then return end
  local prev = nodes[id] or {}
  nodes[id] = {
    name = entry.name or entry.hostname or prev.name or ("#" .. id),
    kind = entry.kind or prev.kind or "modem",
    x = tonumber(entry.x) or prev.x,
    y = tonumber(entry.y) or prev.y,
    z = tonumber(entry.z) or prev.z,
    seen = os.epoch("utc"),
  }
end

--------------------------------------------------------------------------------
-- Network: bots/POIs + router fleet map
-- Router traffic is delivered via titan.onRouterMessage (networkLoop owns receive).
--------------------------------------------------------------------------------
local function handleRouterMsg(id, msg)
  if type(msg) ~= "table" or not id then return end
  if msg.type == "fleet_map" and type(msg.nodes) == "table" then
    for _, n in ipairs(msg.nodes) do
      if n.id and n.x then upsertNode(n.id, n) end
    end
    if msg.x then
      upsertNode(id, {
        name = msg.name or msg.hostname, kind = "router",
        x = msg.x, y = msg.y, z = msg.z,
      })
    end
  elseif (msg.type == "hello" or msg.type == "main_claim"
          or msg.type == "main_here" or msg.type == "here")
         and msg.x and (msg.kind == "modem" or msg.kind == "router"
           or msg.main or msg.type == "main_claim" or msg.type == "main_here") then
    upsertNode(id, {
      name = msg.assignHostname or msg.hostname or msg.name or msg.label,
      kind = msg.kind or (msg.main and "router") or "modem",
      x = msg.x, y = msg.y, z = msg.z,
    })
  end
end

titan.onRouterMessage = handleRouterMsg

local function listenerLoop()
  titan.broadcast(MSG.PING, {})
  rednet.broadcast({ type = "map_req", name = os.getComputerLabel() }, ROUTER)
  rednet.broadcast({ type = "where_main" }, ROUTER)
  while true do
    local id, msg = titan.recv(2)
    if type(msg) == "table" and id then
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

local function freshNodes()
  local list = {}
  local now = os.epoch("utc")
  for id, n in pairs(nodes) do
    if n.x and n.z and (now - (n.seen or 0)) < 120000 then
      list[#list + 1] = {
        id = id, name = n.name, kind = n.kind,
        x = n.x, y = n.y, z = n.z,
      }
    end
  end
  table.sort(list, function(a, b)
    local ka = (a.kind == "router" and "0" or "1") .. tostring(a.name)
    local kb = (b.kind == "router" and "0" or "1") .. tostring(b.name)
    return ka < kb
  end)
  return list
end

--------------------------------------------------------------------------------
-- Live radar GRID (pocket at center; highlight focused modem)
--------------------------------------------------------------------------------
local function drawRadar()
  local tw, th = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()

  local function put(x, y, ch, fg, bg)
    if x < 1 or y < 1 or x > tw or y > th then return end
    term.setCursorPos(x, y)
    if term.isColor and term.isColor() then
      term.setBackgroundColor(bg or colors.black)
      term.setTextColor(fg or colors.white)
    end
    term.write(ch)
  end

  local px, py, pz = locate()
  if not px then
    put(1, 1, "No GPS fix — need 4+ GPS hosts", colors.red)
    put(1, 3, "[any key] exit  [R] refresh map", colors.gray)
    return
  end

  local list = freshNodes()
  if #list == 0 then
    rednet.broadcast({ type = "map_req" }, ROUTER)
    rednet.broadcast({ type = "where_main" }, ROUTER)
  end
  if focusIdx > #list then focusIdx = math.max(1, #list) end
  if focusIdx < 1 then focusIdx = 1 end
  local focus = list[focusIdx]

  -- Header
  put(1, 1, ("@ %d,%d,%d  zoom:%dm/cell"):format(px, py, pz, mapScale), colors.yellow)
  local head = headAngle
    and cardinal(math.sin(math.rad(headAngle)), -math.cos(math.rad(headAngle)))
    or "?"
  put(1, 2, ("facing %s   N=up"):format(head), colors.lightGray)

  -- Grid area (leave rows 1-2 header, last 3 footer)
  local top, bottom = 3, th - 3
  local left, right = 1, tw
  local gw, gh = right - left + 1, bottom - top + 1
  if gh < 5 or gw < 8 then
    put(1, 3, "Screen too small", colors.red)
    return
  end
  local cx = left + math.floor(gw / 2)
  local cy = top + math.floor(gh / 2)

  -- Background grid dots every 4 cells
  for gy = top, bottom do
    for gx = left, right do
      local relX = gx - cx
      local relZ = gy - cy
      if relX == 0 or relZ == 0 then
        put(gx, gy, (relX == 0 and relZ == 0) and " " or "·", colors.gray)
      elseif relX % 4 == 0 and relZ % 4 == 0 then
        put(gx, gy, "·", colors.gray)
      else
        put(gx, gy, " ", colors.black)
      end
    end
  end
  -- Axis cross
  for gx = left, right do put(gx, cy, "─", colors.gray) end
  for gy = top, bottom do put(cx, gy, "│", colors.gray) end
  put(cx, cy, "+", colors.lightGray)
  put(cx, top, "N", colors.white)
  put(right, cy, "E", colors.white)
  put(cx, bottom, "S", colors.white)
  put(left, cy, "W", colors.white)

  -- Plot nodes (world: +X east = right, +Z south = down on screen)
  local function cellOf(wx, wz)
    local dx = math.floor((wx - px) / mapScale + 0.5)
    local dz = math.floor((wz - pz) / mapScale + 0.5)
    return cx + dx, cy + dz
  end

  for i, n in ipairs(list) do
    local sx, sy = cellOf(n.x, n.z)
    local isFocus = focus and n.id == focus.id
    local ch = (n.kind == "router") and "R" or "M"
    local fg, bg = colors.lime, colors.black
    if n.kind == "router" then fg = colors.cyan end
    if isFocus then
      fg = colors.black
      bg = colors.orange
      ch = (n.kind == "router") and "R" or "M"
    end
    put(sx, sy, ch, fg, bg)
  end

  -- You are here (draw last so always on top)
  put(cx, cy, "@", colors.yellow, colors.black)

  -- Footer: focused modem highlight details
  local fy = th - 2
  if focus and focus.x then
    local dist, card = bearingTo(px, py, pz, focus.x, focus.y or py, focus.z)
    local label = ("%s %s"):format(
      (focus.kind == "router") and "ROUTER" or "MODEM",
      tostring(focus.name):sub(1, 12))
    put(1, fy, label, colors.orange)
    put(1, fy + 1, ("%s  %d,%d,%d"):format(
      fmtTarget(px, py, pz, focus.x, focus.y or py, focus.z),
      focus.x, focus.y or 0, focus.z), colors.white)
  else
    put(1, fy, "No routers/modems on map yet", colors.gray)
    put(1, fy + 1, "Waiting for fleet_map from main…", colors.gray)
  end
  put(1, th, "[Tab]focus +/-zoom [R]map [Q]quit", colors.gray)

  -- Reset colors
  if term.isColor and term.isColor() then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
  end
end

local function liveView()
  rednet.broadcast({ type = "map_req", name = os.getComputerLabel() }, ROUTER)
  local timer = os.startTimer(0.5)
  while true do
    drawRadar()
    local ev, p1 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      timer = os.startTimer(0.5)
    elseif ev == "key" then
      local key = p1
      if key == keys.q or key == keys.x or key == keys.escape then
        break
      elseif key == keys.tab then
        local n = #freshNodes()
        if n > 0 then focusIdx = (focusIdx % n) + 1 end
      elseif key == keys.equals or key == keys.numPadAdd then
        mapScale = math.max(2, math.floor(mapScale / 2))
        saveCfg()
      elseif key == keys.minus or key == keys.numPadSubtract then
        mapScale = math.min(128, mapScale * 2)
        saveCfg()
      elseif key == keys.r then
        rednet.broadcast({ type = "map_req" }, ROUTER)
        rednet.broadcast({ type = "where_main" }, ROUTER)
      elseif key == keys.right or key == keys.d then
        local n = #freshNodes()
        if n > 0 then focusIdx = (focusIdx % n) + 1 end
      elseif key == keys.left or key == keys.a then
        local n = #freshNodes()
        if n > 0 then focusIdx = ((focusIdx - 2) % n) + 1 end
      end
      timer = os.startTimer(0.1)
    elseif ev == "char" then
      local ch = p1
      if ch == "+" or ch == "=" then
        mapScale = math.max(2, math.floor(mapScale / 2)); saveCfg()
      elseif ch == "-" then
        mapScale = math.min(128, mapScale * 2); saveCfg()
      elseif ch == "q" or ch == "Q" then
        break
      elseif ch == "r" or ch == "R" then
        rednet.broadcast({ type = "map_req" }, ROUTER)
      end
      timer = os.startTimer(0.1)
    elseif ev == "mouse_click" or ev == "terminate" then
      break
    end
  end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  if term.setTextColor then term.setTextColor(colors.white) end
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function consoleLoop()
  loadCfg()
  term.clear(); term.setCursorPos(1, 1)
  print("== Titan Locator ==")
  print("Type 'live' for the radar grid. 'help' for commands.")
  while true do
    write("loc> ")
    local a = {}
    for word in tostring(read()):gmatch("%S+") do a[#a + 1] = word end
    local cmd = (a[1] or ""):lower()

    if cmd == "" then
      -- ignore
    elseif cmd == "help" then
      print("here            show current position")
      print("live            radar grid (@=you, M=modem, R=router)")
      print("               Tab focus modem  +/- zoom  R refresh")
      print("modems|map      list routers/modems with bearing")
      print("mark <name>     save current spot as a waypoint")
      print("wp              list waypoints w/ distance + bearing")
      print("go <name>       bearing to a waypoint")
      print("del <name>      delete a waypoint")
      print("pois | bots     network targets w/ bearing")
      print("exit")

    elseif cmd == "here" or cmd == "pos" then
      local x, y, z = locate()
      if x then print(("%d, %d, %d"):format(x, y, z)) else print("No GPS fix.") end

    elseif cmd == "live" or cmd == "radar" or cmd == "grid" then
      liveView()

    elseif cmd == "modems" or cmd == "map" or cmd == "routers" then
      rednet.broadcast({ type = "map_req" }, ROUTER)
      sleep(0.4)
      local x, y, z = locate()
      local list = freshNodes()
      if #list == 0 then print("(no routers/modems with GPS yet)") end
      for _, n in ipairs(list) do
        local tag = (n.kind == "router") and "R" or "M"
        if x then
          print(("[%s] %-12s %s"):format(tag, tostring(n.name):sub(1, 12),
            fmtTarget(x, y, z, n.x, n.y or y, n.z)))
        else
          print(("[%s] %-12s %d,%d,%d"):format(tag, tostring(n.name):sub(1, 12),
            n.x, n.y or 0, n.z))
        end
      end

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
  function() titan.networkLoop("locator") end)
print("Locator closed.")
