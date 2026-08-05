--[[
  locator.lua  -  Pocket GPS locator for the Titan network (CC: Tweaked)
  Titan-Version: 1.2.0

  A handheld you carry: live GPS, waypoints, and a top-down fleet map matching
  the main router's `map` command — grid (- _ | \ /), r=main, m=modem, @=you.

  Requires: a POCKET computer with a WIRELESS MODEM upgrade, `lib/titan.lua`,
  and an existing GPS constellation in range (see README).

  NOTE: a pocket computer cannot HOST GPS (hosts must be stationary) - use
  router.lua / gpshost.lua for that. This tool only LOCATES.

  Run:  locator
  Tip:  `live` opens the map. +/- zoom, F fit, Tab focus, Q quit.
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
local mapScale  = 16     -- blocks per cell (zoomed out, matches router map)
local focusIdx  = 1      -- which modem/router is highlighted
local autoFitOnce = true

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
  local x, y, z, info = titan.gpsFix({ timeout = 2.5, samples = 5 })
  if not x then return nil end
  if last and (x ~= last.x or z ~= last.z) then
    headAngle = angleOf(x - last.x, z - last.z)
  end
  last = { x = x, y = y, z = z, yLo = info and info.yLo, yHi = info and info.yHi, n = info and info.n }
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
  local isMain = entry.main
  if isMain == nil then
    isMain = prev.main
  end
  if entry.kind == "router" and (entry.main == true) then isMain = true end
  nodes[id] = {
    name = entry.name or entry.hostname or prev.name or ("#" .. id),
    kind = entry.kind or prev.kind or "modem",
    main = isMain and true or false,
    x = tonumber(entry.x) or prev.x,
    y = tonumber(entry.y) or prev.y,
    z = tonumber(entry.z) or prev.z,
    seen = os.epoch("utc"),
  }
  -- Only one main: clear main flag on others when we learn a new main.
  if nodes[id].main then
    for oid, n in pairs(nodes) do
      if oid ~= id then n.main = false end
    end
  end
end

--------------------------------------------------------------------------------
-- Network: bots/POIs + router fleet map
-- Router traffic is delivered via titan.onRouterMessage (networkLoop owns receive).
--------------------------------------------------------------------------------
local function handleRouterMsg(id, msg)
  if type(msg) ~= "table" or not id then return end
  if msg.type == "fleet_map" and type(msg.nodes) == "table" then
    for _, n in ipairs(msg.nodes) do
      if n.id and n.x then
        local main = (n.kind == "router" and n.main)
          or (tonumber(n.id) == tonumber(msg.from))
        upsertNode(n.id, {
          name = n.name, kind = n.kind or "modem",
          main = main, x = n.x, y = n.y, z = n.z,
        })
      end
    end
    if msg.x then
      upsertNode(id, {
        name = msg.name or msg.hostname, kind = "router", main = true,
        x = msg.x, y = msg.y, z = msg.z,
      })
    end
  elseif (msg.type == "hello" or msg.type == "main_claim"
          or msg.type == "main_here" or msg.type == "here")
         and msg.x and (msg.kind == "modem" or msg.kind == "router"
           or msg.main or msg.type == "main_claim" or msg.type == "main_here") then
    local isMain = msg.main or msg.type == "main_claim" or msg.type == "main_here"
      or msg.kind == "router"
    upsertNode(id, {
      name = msg.assignHostname or msg.hostname or msg.name or msg.label,
      kind = isMain and "router" or (msg.kind or "modem"),
      main = isMain,
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
        id = id, name = n.name, kind = n.kind, main = n.main,
        x = n.x, y = n.y, z = n.z,
      }
    end
  end
  -- Modems first, main last (draw order); then by name.
  table.sort(list, function(a, b)
    if a.main ~= b.main then return not a.main end
    local ka = (a.kind == "router" and "0" or "1") .. tostring(a.name)
    local kb = (b.kind == "router" and "0" or "1") .. tostring(b.name)
    return ka < kb
  end)
  return list
end

-- Same background art as router.lua `map` (- _ | \ /).
local function mapGridChar(relX, relZ)
  if relX == 0 and relZ == 0 then return "+" end
  if relX == 0 then return "|" end
  if relZ == 0 then return "-" end
  if relX == relZ then return "\\" end
  if relX == -relZ then return "/" end
  if relZ % 4 == 0 then return "_" end
  if relX % 4 == 0 then return "|" end
  if (relX + relZ) % 6 == 0 then return "/" end
  if (relX - relZ) % 6 == 0 then return "\\" end
  if relZ % 2 == 0 then return "-" end
  return " "
end

local function mapAutoScale(list, ox, oz, gw, gh)
  local maxD = 8
  for _, n in ipairs(list) do
    maxD = math.max(maxD, math.abs(n.x - ox), math.abs(n.z - oz))
  end
  local half = math.max(2, math.floor(math.min(gw, gh) / 2) - 1)
  return math.max(2, math.ceil(maxD / half))
end

--------------------------------------------------------------------------------
-- Live map (matches main router `map`: grid -_|\/  r=main m=modem @=you)
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
    put(1, 3, "[Q] quit  [R] refresh map", colors.gray)
    return
  end

  local list = freshNodes()
  if #list == 0 then
    rednet.broadcast({ type = "map_req" }, ROUTER)
    rednet.broadcast({ type = "where_main" }, ROUTER)
  end

  local top, bottom = 3, th - 3
  local left, right = 1, tw
  local gw, gh = right - left + 1, bottom - top + 1
  if gh < 5 or gw < 8 then
    put(1, 3, "Screen too small", colors.red)
    return
  end

  if autoFitOnce then
    mapScale = mapAutoScale(list, px, pz, gw, gh)
    autoFitOnce = false
  end

  if focusIdx > #list then focusIdx = math.max(1, #list) end
  if focusIdx < 1 then focusIdx = 1 end
  local focus = list[focusIdx]

  put(1, 1, ("FLEET MAP  @ %d,%d,%d  %dm/cell"):format(px, py, pz, mapScale), colors.yellow)
  put(1, 2, "r=main  m=modem  @=you  N=up  +/- zoom  F fit  Tab focus  Q quit", colors.lightGray)

  local cx = left + math.floor(gw / 2)
  local cy = top + math.floor(gh / 2)

  for gy = top, bottom do
    for gx = left, right do
      put(gx, gy, mapGridChar(gx - cx, gy - cy), colors.gray)
    end
  end
  put(cx, top, "N", colors.white)
  put(right, cy, "E", colors.white)
  put(cx, bottom, "S", colors.white)
  put(left, cy, "W", colors.white)

  local function cellOf(wx, wz)
    return cx + math.floor((wx - px) / mapScale + 0.5),
           cy + math.floor((wz - pz) / mapScale + 0.5)
  end

  for _, n in ipairs(list) do
    local sx, sy = cellOf(n.x, n.z)
    local isFocus = focus and n.id == focus.id
    local isMain = n.main or n.kind == "router"
    local ch = isMain and "r" or "m"
    local fg = isMain and colors.cyan or colors.lime
    local bg = colors.black
    if isFocus then
      fg, bg = colors.black, colors.orange
    end
    put(sx, sy, ch, fg, bg)
  end

  -- You are here (always on top)
  put(cx, cy, "@", colors.yellow, colors.black)

  local fy = th - 2
  if focus and focus.x then
    local tag = (focus.main or focus.kind == "router") and "r" or "m"
    put(1, fy, ("%s:%s"):format(tag, tostring(focus.name):sub(1, 14)), colors.orange)
    put(1, fy + 1, ("%s  %d,%d,%d"):format(
      fmtTarget(px, py, pz, focus.x, focus.y or py, focus.z),
      focus.x, focus.y or 0, focus.z), colors.white)
  else
    put(1, fy, "No routers/modems on map yet", colors.gray)
    put(1, fy + 1, "Waiting for fleet_map from main…", colors.gray)
  end
  put(1, th, ("nodes:%d  scale:%d  [+/-] [F]fit [Tab]focus [R]refresh [Q]"):format(
    #list, mapScale), colors.gray)

  if term.isColor and term.isColor() then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
  end
end

local function liveView()
  rednet.broadcast({ type = "map_req", name = os.getComputerLabel() }, ROUTER)
  rednet.broadcast({ type = "where_main" }, ROUTER)
  autoFitOnce = true
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
        mapScale = math.max(2, math.floor(mapScale / 2)); saveCfg()
      elseif key == keys.minus or key == keys.numPadSubtract then
        mapScale = math.min(256, mapScale * 2); saveCfg()
      elseif key == keys.f then
        autoFitOnce = true
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
        mapScale = math.min(256, mapScale * 2); saveCfg()
      elseif ch == "f" or ch == "F" then
        autoFitOnce = true
      elseif ch == "q" or ch == "Q" then
        break
      elseif ch == "r" or ch == "R" then
        rednet.broadcast({ type = "map_req" }, ROUTER)
        rednet.broadcast({ type = "where_main" }, ROUTER)
      end
      timer = os.startTimer(0.1)
    elseif ev == "terminate" then
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
      print("live            fleet map (same as router map)")
      print("               r=main m=modem @=you  grid -_|\\/")
      print("               +/- zoom  F fit  Tab focus  R refresh  Q quit")
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
