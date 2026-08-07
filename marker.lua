--[[
  marker.lua  -  Work-site marker computer for Titan fleet mining (CC: Tweaked)
  Titan-Version: 1.1.0

  Place this computer at (or near) a job site. Define the dig box, how many
  miner bots to request, and `start` — Parent Center assigns idle miners.

  Y stagger (default mode `yband`):
    Each bot owns a vertical band of the box so they are NOT all digging the
    same layer at once (much faster than 5 turtles stacked on one Y).

  Alternate mode `strip`:
    Each bot owns an X-strip of the footprint and digs full height.

  Site chests (sent with the job):
    storage / chest <x y z|here>   where miners dump
    fuelchest <x y z|here>         optional fuel pickup
    selfchunk on|off               miners dig with chunk loader (modem in slot 15)

  Gizmos (Quark-quarry style as far as CC allows):
    * Attached MONITOR — live top-down wireframe + Y bands / bot count
    * COMMAND COMPUTER (optional) — dust particle outline of the box edges
      (vanilla CC cannot draw world holograms without commands / extra mods)
    * Corner coordinates always shown on the terminal

  Setup:
    set1 / set2     opposite XZ corners (or `here` / `size WxD`)
    sety <top> <bot>   or ystart / yend   (yend = bottom)
    bots <n>        how many miners to request
    mode yband|strip
    start           request Parent Center dispatch
    gizmo on|off    particle outline (needs command computer)
    monrate [secs]  monitor refresh rate (default 1s)

  Requires: wireless modem, GPS (for `here` / `size`), lib/titan.lua.
  Parent Center must be online for `start`.
]]

local titan = dofile("lib/titan.lua")
local MSG = titan.MSG
local P = titan.PROTOCOL

titan.openModem()

local CFG = "marker.cfg"
local cfg = {
  name = nil,
  siteId = nil,
  x1 = nil, z1 = nil, x2 = nil, z2 = nil,
  yStart = nil, yEnd = nil,
  nBots = 4,
  mode = "yband",   -- yband | strip
  cruiseY = 150,
  gizmo = true,
  returnStage = true,
  monRate = 1,
  storage = nil,    -- {x,y,z}
  fuelChest = nil,  -- {x,y,z}
  selfChunk = false,
}

local state = {
  status = "idle",
  lastJob = nil,
  lastAck = nil,
  err = nil,
}

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

local function areaReady()
  return cfg.x1 and cfg.z1 and cfg.x2 and cfg.z2
    and cfg.yStart ~= nil and cfg.yEnd ~= nil
end

local function bounds()
  if not areaReady() then return nil end
  local minX, maxX = math.min(cfg.x1, cfg.x2), math.max(cfg.x1, cfg.x2)
  local minZ, maxZ = math.min(cfg.z1, cfg.z2), math.max(cfg.z1, cfg.z2)
  local yTop, yBot = cfg.yStart, cfg.yEnd
  if yBot > yTop then yTop, yBot = yBot, yTop end
  return {
    minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ,
    yTop = yTop, yBot = yBot,
    w = maxX - minX + 1, d = maxZ - minZ + 1,
    h = yTop - yBot + 1,
  }
end

local function fmtB(b)
  if not b then return "(area incomplete)" end
  return ("X[%d..%d] Z[%d..%d] Y[%d->%d]  %dx%dx%d"):format(
    b.minX, b.maxX, b.minZ, b.maxZ, b.yTop, b.yBot, b.w, b.d, b.h)
end

--------------------------------------------------------------------------------
-- World gizmos (particle outline) — command computer only
--------------------------------------------------------------------------------
local function particleAt(x, y, z, r, g, b)
  if not commands then return end
  -- dust <r> <g> <b> <size>  — colour wireframe like a quarry preview
  local cmd = ("particle dust %.2f %.2f %.2f 1 %d %d %d 0 0 0 0 1 force"):format(
    r or 1, g or 0.25, b or 0.15, x, y, z)
  pcall(commands.execAsync, cmd)
end

local function drawEdge(x1, y1, z1, x2, y2, z2, r, g, b)
  local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
  local len = math.max(math.abs(dx), math.abs(dy), math.abs(dz))
  if len < 1 then
    particleAt(x1, y1, z1, r, g, b)
    return
  end
  local step = math.max(1, math.floor(len / 24))
  for i = 0, len, step do
    local t = i / len
    particleAt(
      math.floor(x1 + dx * t + 0.5),
      math.floor(y1 + dy * t + 0.5),
      math.floor(z1 + dz * t + 0.5),
      r, g, b)
  end
end

local function drawWorldGizmo()
  if not cfg.gizmo or not commands then return false end
  local b = bounds()
  if not b then return false end
  local x1, x2, y1, y2, z1, z2 = b.minX, b.maxX, b.yBot, b.yTop, b.minZ, b.maxZ
  -- Bottom rectangle
  drawEdge(x1, y1, z1, x2, y1, z1, 1, 0.3, 0.1)
  drawEdge(x2, y1, z1, x2, y1, z2, 1, 0.3, 0.1)
  drawEdge(x2, y1, z2, x1, y1, z2, 1, 0.3, 0.1)
  drawEdge(x1, y1, z2, x1, y1, z1, 1, 0.3, 0.1)
  -- Top rectangle
  drawEdge(x1, y2, z1, x2, y2, z1, 0.2, 0.9, 1)
  drawEdge(x2, y2, z1, x2, y2, z2, 0.2, 0.9, 1)
  drawEdge(x2, y2, z2, x1, y2, z2, 0.2, 0.9, 1)
  drawEdge(x1, y2, z2, x1, y2, z1, 0.2, 0.9, 1)
  -- Vertical corners
  drawEdge(x1, y1, z1, x1, y2, z1, 1, 1, 0.2)
  drawEdge(x2, y1, z1, x2, y2, z1, 1, 1, 0.2)
  drawEdge(x2, y1, z2, x2, y2, z2, 1, 1, 0.2)
  drawEdge(x1, y1, z2, x1, y2, z2, 1, 1, 0.2)
  return true
end

--------------------------------------------------------------------------------
-- Monitor gizmo (top-down box + Y band legend)
--------------------------------------------------------------------------------
local function drawMonitor(mon)
  mon.setTextScale(0.5)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local function put(x, y, text, fg, bg)
    if y < 1 or y > h or x > w then return end
    mon.setCursorPos(x, y)
    mon.setTextColor(fg or colors.white)
    if bg then mon.setBackgroundColor(bg) end
    mon.write(tostring(text):sub(1, w - x + 1))
    mon.setBackgroundColor(colors.black)
  end

  put(1, 1, "== SITE MARKER : " .. tostring(cfg.name or "?") .. " ==", colors.yellow)
  local b = bounds()
  if not b then
    put(1, 3, "Set area: set1 / set2 / sety", colors.orange)
    put(1, 4, "Then: bots <n> | mode yband|strip | start", colors.lightGray)
    return
  end

  put(1, 2, fmtB(b), colors.white)
  put(1, 3, ("bots=%d  mode=%s  status=%s"):format(
    tonumber(cfg.nBots) or 0, tostring(cfg.mode), tostring(state.status)), colors.lime)
  if state.lastJob then
    put(1, 4, "job " .. tostring(state.lastJob), colors.cyan)
  elseif state.err then
    put(1, 4, tostring(state.err):sub(1, w), colors.red)
  end

  -- Top-down footprint wireframe in the remaining space
  local mapX0, mapY0 = 2, 6
  local mapW, mapH = math.max(8, w - 4), math.max(6, h - 10)
  local function toMap(wx, wz)
    local mx = mapX0 + math.floor((wx - b.minX) / math.max(1, b.w - 1) * (mapW - 1) + 0.5)
    local my = mapY0 + math.floor((wz - b.minZ) / math.max(1, b.d - 1) * (mapH - 1) + 0.5)
    return mx, my
  end
  local function plot(mx, my, ch, fg)
    if mx >= mapX0 and mx < mapX0 + mapW and my >= mapY0 and my < mapY0 + mapH then
      put(mx, my, ch or "#", fg or colors.orange)
    end
  end

  -- Border
  for i = 0, mapW - 1 do
    plot(mapX0 + i, mapY0, "-", colors.orange)
    plot(mapX0 + i, mapY0 + mapH - 1, "-", colors.orange)
  end
  for j = 0, mapH - 1 do
    plot(mapX0, mapY0 + j, "|", colors.orange)
    plot(mapX0 + mapW - 1, mapY0 + j, "|", colors.orange)
  end
  plot(mapX0, mapY0, "+", colors.yellow)
  plot(mapX0 + mapW - 1, mapY0, "+", colors.yellow)
  plot(mapX0, mapY0 + mapH - 1, "+", colors.yellow)
  plot(mapX0 + mapW - 1, mapY0 + mapH - 1, "+", colors.yellow)

  -- Preview band / strip divisions
  local n = math.max(1, tonumber(cfg.nBots) or 1)
  if tostring(cfg.mode) == "strip" then
    for i = 1, n - 1 do
      local wx = b.minX + math.floor(i * b.w / n)
      local mx = select(1, toMap(wx, b.minZ))
      for j = 0, mapH - 1 do plot(mx, mapY0 + j, ":", colors.cyan) end
    end
    put(1, h - 1, "strips = X divisions (full Y each)", colors.lightGray)
  else
    put(1, h - 2, "Y bands (each bot a different height range):", colors.lightGray)
    local nb = math.min(n, b.h)
    local base, rem = math.floor(b.h / nb), b.h % nb
    local cursor = b.yTop
    local parts = {}
    for i = 1, nb do
      local bh = base + (i <= rem and 1 or 0)
      local ye = cursor - bh + 1
      parts[#parts + 1] = ("B%d:%d..%d"):format(i, cursor, ye)
      cursor = ye - 1
    end
    put(1, h - 1, table.concat(parts, "  "), colors.cyan)
  end

  if commands then
    put(1, h, "world gizmo: particles ON (command computer)", colors.lime)
  else
    put(1, h, "world gizmo: monitor only (need command PC for particles)", colors.gray)
  end
end

--------------------------------------------------------------------------------
-- Job request
--------------------------------------------------------------------------------
local function requestJob()
  local b = bounds()
  if not b then
    state.err = "area incomplete"
    print("Define set1/set2 and sety first.")
    return false
  end
  state.status = "requesting"
  state.err = nil
  local payload = {
    type = MSG.SITE_JOB,
    name = cfg.name,
    siteId = cfg.siteId or cfg.name,
    x1 = b.minX, z1 = b.minZ, x2 = b.maxX, z2 = b.maxZ,
    yStart = b.yTop, yEnd = b.yBot,
    nBots = tonumber(cfg.nBots) or 4,
    mode = cfg.mode or "yband",
    cruiseY = tonumber(cfg.cruiseY) or 150,
    returnStage = cfg.returnStage ~= false,
    storage = cfg.storage,
    chest = cfg.storage,
    fuelChest = cfg.fuelChest,
    selfChunk = cfg.selfChunk and true or false,
  }
  print(("Requesting %s job: %s  bots=%d"):format(
    payload.mode, fmtB(b), payload.nBots))
  print("Sending site_job to Parent Center over the mesh...")
  -- One broadcast on titan_net (MAIN/modems relay hops). DC botLoop handles it.
  rednet.broadcast(payload, P)
  -- Wait for ack from Parent Center
  local deadline = os.clock() + 12
  while os.clock() < deadline do
    local id, msg = rednet.receive(P, deadline - os.clock())
    if type(msg) == "table" and (msg.type == MSG.SITE_JOB_ACK or msg.type == "site_job_ack") then
      if msg.ok then
        state.status = "dispatched"
        state.lastJob = msg.jobId
        state.lastAck = msg
        print(("Parent Center job %s — %d miners (%s) Y %s->%s"):format(
          tostring(msg.jobId), tonumber(msg.bots) or 0, tostring(msg.mode),
          tostring(msg.yStart), tostring(msg.yEnd)))
        print("Miners + loaders are being dispatched. Check Parent Center `bots` / `jobs`.")
        return true
      else
        state.status = "error"
        state.err = tostring(msg.err or "rejected")
        print("Rejected: " .. state.err)
        print("Tip: deploy miners (`deploy <id> miner`), keep them idle, check `bots` on Parent Center.")
        return false
      end
    end
  end
  state.status = "error"
  state.err = "no Parent Center ack (is datacenter online on the mesh?)"
  print(state.err)
  print("Check: Parent Center running, MAIN router up, marker in modem range.")
  return false
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function fmtP(p)
  return p and ("%d,%d,%d"):format(p.x, p.y, p.z) or "(unset)"
end

local function printStatus()
  print("Site: " .. tostring(cfg.name) .. "  id=" .. tostring(cfg.siteId or cfg.name or "?"))
  print(fmtB(bounds()))
  print(("bots=%s  mode=%s  cruiseY=%s  selfChunk=%s"):format(
    tostring(cfg.nBots), tostring(cfg.mode), tostring(cfg.cruiseY),
    tostring(cfg.selfChunk)))
  print(("storage=%s  fuelChest=%s"):format(fmtP(cfg.storage), fmtP(cfg.fuelChest)))
  print(("gizmo=%s  monrate=%.2fs"):format(
    cfg.gizmo and "on" or "off", tonumber(cfg.monRate) or 1))
  print(("status=%s  lastJob=%s"):format(tostring(state.status), tostring(state.lastJob)))
  if commands then
    print("Command computer: world particle gizmos available.")
  else
    print("Tip: use a COMMAND computer for Quark-like particle outlines.")
  end
end

local function setPosField(field, a)
  local sub = (a[2] or ""):lower()
  if sub == "here" or sub == "gps" then
    local x, y, z = gps.locate(2)
    if not x then print("No GPS."); return end
    cfg[field] = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
  elseif sub == "clear" or sub == "none" then
    cfg[field] = nil
  elseif a[2] and a[3] and a[4] then
    cfg[field] = {
      x = math.floor(tonumber(a[2])), y = math.floor(tonumber(a[3])),
      z = math.floor(tonumber(a[4])),
    }
  else
    print(field .. " = " .. fmtP(cfg[field]))
    print("Usage: " .. field .. " <x> <y> <z> | " .. field .. " here | " .. field .. " clear")
    return
  end
  saveCfg()
  print(field .. " = " .. fmtP(cfg[field]))
end

local function handleCommand(a)
  local cmd = (a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" then
    print("AREA : set1/set2 [here|x z] | size <W>x<D> | sety <top> <bot>")
    print("      ystart <y> | yend <y> | here (GPS as set1)")
    print("SITE : storage|chest [x y z|here] | fuelchest [x y z|here]")
    print("      selfchunk on|off | siteid <id>")
    print("JOB  : bots <n> | mode yband|strip | cruise <y>")
    print("      start | stop-status | status")
    print("VIZ  : gizmo on|off | show   (particles need command computer)")
    print("      monrate [secs]   monitor refresh rate")
    print("      name <label> | hostname [name]")
  elseif cmd == "monrate" or cmd == "mrate" or cmd == "monitorrate" or cmd == "refreshrate" then
    if a[2] then
      cfg.monRate = titan.normalizeMonRate(a[2], cfg.monRate or 1)
      saveCfg()
    end
    print(("Monitor refresh: %.2fs  (range %.2f–%ds)"):format(
      tonumber(cfg.monRate) or 1, titan.MONRATE_MIN, titan.MONRATE_MAX))
  elseif cmd == "status" then
    printStatus()
  elseif cmd == "name" then
    if a[2] then cfg.name = table.concat(a, " ", 2); saveCfg(); os.setComputerLabel(cfg.name) end
    print("name = " .. tostring(cfg.name))
  elseif cmd == "hostname" or cmd == "host" then
    if a[2] then
      cfg.name = table.concat(a, " ", 2); saveCfg(); os.setComputerLabel(cfg.name)
    end
    print("hostname: " .. (os.getComputerLabel() or "?"))
  elseif cmd == "set1" or cmd == "set2" then
    local field = (cmd == "set1") and "x1" or "x2"
    local zfield = (cmd == "set1") and "z1" or "z2"
    if a[2] and a[2]:lower() == "here" then
      local x, y, z = gps.locate(3)
      if not x then print("No GPS") else
        cfg[field] = math.floor(x); cfg[zfield] = math.floor(z)
        if cfg.yStart == nil then cfg.yStart = math.floor(y) end
        saveCfg(); print(("%s = %d, %d"):format(cmd, cfg[field], cfg[zfield]))
      end
    elseif a[2] and a[3] then
      cfg[field] = math.floor(tonumber(a[2]))
      cfg[zfield] = math.floor(tonumber(a[3]))
      saveCfg(); print(("%s = %d, %d"):format(cmd, cfg[field], cfg[zfield]))
    else
      print(("Usage: %s here | %s <x> <z>"):format(cmd, cmd))
    end
  elseif cmd == "here" then
    local x, y, z = gps.locate(3)
    if not x then print("No GPS") else
      cfg.x1 = math.floor(x); cfg.z1 = math.floor(z)
      if cfg.yStart == nil then cfg.yStart = math.floor(y) end
      saveCfg()
      print(("set1 = %d, %d  (ystart=%s)"):format(cfg.x1, cfg.z1, tostring(cfg.yStart)))
    end
  elseif cmd == "size" then
    local w, d = tostring(a[2] or ""):match("^(%d+)[xX](%d+)$")
    w, d = tonumber(w), tonumber(d)
    if not (w and d) then print("Usage: size <W>x<D>  (from set1/here, +X +Z)"); return true end
    if not (cfg.x1 and cfg.z1) then
      local x, y, z = gps.locate(3)
      if not x then print("No GPS / set1 first"); return true end
      cfg.x1, cfg.z1 = math.floor(x), math.floor(z)
      if cfg.yStart == nil then cfg.yStart = math.floor(y) end
    end
    cfg.x2 = cfg.x1 + w - 1
    cfg.z2 = cfg.z1 + d - 1
    saveCfg()
    print(("Box XZ %dx%d  set2=%d,%d"):format(w, d, cfg.x2, cfg.z2))
  elseif cmd == "sety" then
    local t, e = tonumber(a[2]), tonumber(a[3])
    if not (t and e) then print("Usage: sety <topY> <bottomY>"); return true end
    cfg.yStart, cfg.yEnd = math.floor(t), math.floor(e)
    saveCfg(); print(("Y %d -> %d"):format(cfg.yStart, cfg.yEnd))
  elseif cmd == "ystart" then
    cfg.yStart = math.floor(tonumber(a[2]) or cfg.yStart or 0); saveCfg()
    print("ystart = " .. tostring(cfg.yStart))
  elseif cmd == "yend" then
    cfg.yEnd = math.floor(tonumber(a[2]) or cfg.yEnd or 0); saveCfg()
    print("yend = " .. tostring(cfg.yEnd))
  elseif cmd == "bots" then
    if a[2] then cfg.nBots = math.max(1, math.floor(tonumber(a[2]) or 1)); saveCfg() end
    print("bots = " .. tostring(cfg.nBots))
  elseif cmd == "storage" or cmd == "chest" then
    setPosField("storage", a)
  elseif cmd == "fuelchest" or cmd == "fuel" then
    setPosField("fuelChest", a)
  elseif cmd == "selfchunk" or cmd == "chunkmode" then
    local v = (a[2] or ""):lower()
    if v == "on" or v == "true" or v == "1" then
      cfg.selfChunk = true; saveCfg()
    elseif v == "off" or v == "false" or v == "0" then
      cfg.selfChunk = false; saveCfg()
    end
    print("selfChunk = " .. tostring(cfg.selfChunk))
    print("When on, miners dig with chunk loader; modem stays in slot 15 until dump.")
  elseif cmd == "siteid" or cmd == "site" then
    if a[2] then
      cfg.siteId = table.concat(a, " ", 2)
      saveCfg()
    end
    print("siteId = " .. tostring(cfg.siteId or cfg.name or "?"))
  elseif cmd == "mode" then
    local m = tostring(a[2] or ""):lower()
    if m == "y" or m == "layer" or m == "layers" then m = "yband" end
    if m == "xz" or m == "x" then m = "strip" end
    if m == "yband" or m == "strip" then cfg.mode = m; saveCfg()
    elseif a[2] then print("mode: yband | strip"); return true end
    print("mode = " .. tostring(cfg.mode)
      .. (cfg.mode == "yband" and "  (each bot a Y band)" or "  (each bot an X strip)"))
  elseif cmd == "cruise" then
    if a[2] then cfg.cruiseY = math.floor(tonumber(a[2]) or 150); saveCfg() end
    print("cruiseY = " .. tostring(cfg.cruiseY))
  elseif cmd == "gizmo" then
    local v = tostring(a[2] or ""):lower()
    if v == "on" or v == "1" or v == "true" then cfg.gizmo = true; saveCfg()
    elseif v == "off" or v == "0" or v == "false" then cfg.gizmo = false; saveCfg()
    elseif a[2] then print("gizmo on|off"); return true end
    print("gizmo = " .. (cfg.gizmo and "on" or "off"))
    if cfg.gizmo then drawWorldGizmo() end
  elseif cmd == "show" then
    printStatus()
    if drawWorldGizmo() then print("Particle outline pulsed.")
    elseif not commands then print("No commands API — monitor gizmo still updates.") end
  elseif cmd == "start" or cmd == "request" or cmd == "go" then
    requestJob()
  elseif cmd == "stop" then
    state.status = "idle"
    print("Marker idle (miners already dispatched keep working — stop them from Parent Center).")
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    print("Unknown. Type help.")
  end
  return true
end

--------------------------------------------------------------------------------
-- Loops
--------------------------------------------------------------------------------
local function consoleLoop()
  if titan.setSshHandler then
    titan.setSshHandler(function(line)
      local a = {}
      for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
      return handleCommand(a) ~= false
    end)
  end
  print(("Titan site marker '%s'. Type help."):format(cfg.name or "?"))
  printStatus()
  while true do
    write("marker> ")
    local line = read()
    local a = {}
    for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
    if handleCommand(a) == "exit" then return end
  end
end

local function displayLoop()
  while true do
    local mon = peripheral.find("monitor")
    if mon then pcall(drawMonitor, mon) end
    sleep(titan.normalizeMonRate(cfg.monRate, 1))
  end
end

local function gizmoLoop()
  while true do
    if cfg.gizmo and areaReady() then drawWorldGizmo() end
    sleep(2)
  end
end

local function netLoop()
  while true do
    local id, msg = rednet.receive(P)
    if type(msg) == "table" then
      if msg.type == MSG.SITE_JOB_ACK or msg.type == "site_job_ack" then
        if msg.ok then
          state.status = "dispatched"
          state.lastJob = msg.jobId
          state.lastAck = msg
        else
          state.status = "error"
          state.err = tostring(msg.err)
        end
      elseif msg.type == MSG.PING then
        titan.send(id, MSG.PONG, {
          kind = "marker", name = cfg.name, status = state.status,
        })
      end
    end
  end
end

--------------------------------------------------------------------------------
loadCfg()
if not cfg.name then
  term.clear(); term.setCursorPos(1, 1)
  print("== New Site Marker ==")
  write("Site name: ")
  local n = read()
  cfg.name = (n ~= "" and n) or ("Site-" .. os.getComputerID())
  local x, y, z = gps.locate(3)
  if x then
    cfg.x1, cfg.z1 = math.floor(x), math.floor(z)
    cfg.yStart = math.floor(y)
    print(("GPS set1=%d,%d  ystart=%d"):format(cfg.x1, cfg.z1, cfg.yStart))
    print("Next: size <W>x<D>  or set2 <x> <z>  then sety <top> <bot>")
  else
    print("No GPS — use set1 <x> <z> / set2 / sety manually.")
  end
  saveCfg()
end
os.setComputerLabel(cfg.name)

parallel.waitForAny(
  consoleLoop,
  displayLoop,
  gizmoLoop,
  netLoop,
  function() titan.networkLoop("marker") end
)
print("Marker stopped.")
