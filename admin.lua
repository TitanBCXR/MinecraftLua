--[[
  admin.lua  -  Titan admin console for a POCKET computer ("Live" tablet)
  Titan-Version: 1.4.4

  Pocket remote for the whole fleet. Keep it on you; it joins the mesh like
  every other Titan device (MAIN router + modem hops).

  Two modes (saved in admin.cfg):
    simple   — phone-style home screen with app tiles (default)
    advanced — command-line / SSH power-user console
              `help` is paginated (10 commands per page)

  Switch anytime:  mode simple | mode advanced

  Advanced commands:
    connections | hosts | list   — who is reachable for SSH
    connect | ssh <id|label>     — remote shell (full device commands)
    link                         — network topology (routers + modems)
    link <a> <b>                 — peer two routers OR attach modem→router
    link auto                    — GPS auto: peer routers, modems→nearest hub
    bots / miners / loaders / markers
    pending | deploy | park | stop | mine | continue
    dc | center                  — jump to Parent Center
    flatten ...                  — run flatten on Parent Center via SSH
    live [local|global|stats|gps|bots|quarry] — full-screen boards
      Advanced (color) pocket → pretty GUI; normal pocket → mono.
    quarry                       — offline quarry site % / turtles (titan_quarry)

  Boots with a master-password prompt (before background loops). Deploy / SSH /
  fleet control need an unlocked session.

  Requires: POCKET + wireless modem, lib/titan.lua, mesh in range.
  Run:  admin
]]

local titan = dofile("lib/titan.lua")
local MSG   = titan.MSG
local PROTO_ROUTER = titan.ROUTER_PROTOCOL or "titan_router"
local PROTO_QUARRY = "titan_quarry"
local PROTO_NET = titan.PROTOCOL or "titan_net"

titan.openModem()
os.setComputerLabel(os.getComputerLabel() or ("Admin-" .. os.getComputerID()))

local CFG_FILE = "admin.cfg"
local cfg = { mode = "simple" }  -- "simple" | "advanced"

-- Forward decls (filled later; used by live boards fallback).
local scanNetTopology

local function loadAdminCfg()
  if not fs.exists(CFG_FILE) then return end
  local f = fs.open(CFG_FILE, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" then
    for k, v in pairs(d) do cfg[k] = v end
  end
  local m = tostring(cfg.mode or "simple"):lower()
  if m == "adv" or m == "advanced" or m == "expert" or m == "cli" then
    cfg.mode = "advanced"
  else
    cfg.mode = "simple"
  end
end

local function saveAdminCfg()
  local f = fs.open(CFG_FILE, "w")
  f.write(textutils.serialize(cfg))
  f.close()
end

loadAdminCfg()

--------------------------------------------------------------------------------
-- Shared live state
--------------------------------------------------------------------------------
local unlocked = false
local bots     = {}   -- [id] = roster row (miners, loaders, workers, markers…)
local systems  = {}   -- [id] = { name, kind, seen } from SSH pongs / hellos
local pois     = {}
local pending  = {}
local stuck    = {}
local quarrySnap = nil   -- last quarry_site from offline_site (preferred)
local quarrySnapAt = 0
local quarryTurtles = {} -- [id] = turtle mine reports when no site board

local function now() return os.epoch("utc") end
local function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end
local function pos(b) return ("%s,%s,%s"):format(b.x or "?", b.y or "?", b.z or "?") end

local function findBot(ref)
  if bots[tonumber(ref) or -1] then return tonumber(ref) end
  local want = tostring(ref or ""):lower()
  if want == "" then return nil end
  for id, b in pairs(bots) do
    if b.name and b.name:lower() == want then return id end
    if b.name and b.name:lower():find(want, 1, true) then return id end
  end
  for id, s in pairs(systems) do
    if s.name and s.name:lower() == want then return id end
  end
  return nil
end

local function touchSystem(id, name, kind)
  local s = systems[id] or {}
  s.name = name or s.name
  s.kind = kind or s.kind
  s.seen = now()
  systems[id] = s
end

--------------------------------------------------------------------------------
-- Network listener
--------------------------------------------------------------------------------
local function handle(id, msg)
  local t = msg.type
  if t == MSG.REGISTER or t == MSG.STATUS or t == MSG.BOT_REGISTER
      or t == MSG.PONG then
    local b = bots[id] or {}
    b.name = msg.botName or msg.label or msg.name or msg.hostname or b.name
    b.botType = msg.botType or msg.kind or b.botType
    b.kind = msg.kind or b.kind or b.botType
    b.x, b.y, b.z = msg.x or b.x, msg.y or b.y, msg.z or b.z
    if msg.fuel ~= nil then b.fuel = msg.fuel end
    b.state = msg.state or msg.status or b.state
    b.task = msg.task or b.task
    b.assignment = msg.assignment or b.assignment or b.task
    b.seen = now()
    bots[id] = b
    touchSystem(id, b.name, b.botType or b.kind)
    if b.botType then pending[id] = nil end

  elseif t == MSG.POI_REGISTER then
    pois[msg.poi or ("poi#" .. id)] = {
      x = msg.x, y = msg.y, z = msg.z, id = id, desc = msg.desc, seen = now() }

  elseif t == MSG.WORKER_AWAIT then
    pending[id] = {
      name = msg.name, kind = msg.kind or "worker",
      x = msg.x, y = msg.y, z = msg.z, seen = now(),
    }
    touchSystem(id, msg.name, msg.kind or "pending")

  elseif t == MSG.WORKER_DEPLOYED then
    pending[id] = nil
    if msg.name or msg.botType then
      local b = bots[id] or {}
      b.name = msg.name or b.name
      b.botType = msg.botType or b.botType
      b.state = "idle"
      b.seen = now()
      bots[id] = b
    end

  elseif t == MSG.STUCK then
    table.insert(stuck, 1, {
      name = msg.name or ("#" .. id), x = msg.x, y = msg.y, z = msg.z,
      reason = msg.reason,
    })
    while #stuck > 15 do table.remove(stuck) end

  elseif t == "hello" or t == "main_here" then
    touchSystem(id, msg.name or msg.hostname or msg.label, msg.kind or "router")
  elseif t == "quarry_site" then
    quarrySnap = msg
    quarrySnapAt = now()
    touchSystem(id, msg.name or ("Quarry-" .. id), "quarry_site")
  elseif t == "quarry_turtle" or t == "quarry_progress" or t == "quarry_join"
      or t == "quarry_job" or t == "quarry_done" then
    -- Direct turtle mine data (works without a site board).
    local q = quarryTurtles[id] or {}
    q.name = msg.name or msg.hostname or q.name or ("Turtle-" .. id)
    q.seen = now()
    q.bpc = tonumber(msg.bpc) or q.bpc
    q.fuel = msg.fuel
    q.dug = tonumber(msg.dug) or q.dug
    q.idx = tonumber(msg.idx) or q.idx
    q.total = tonumber(msg.total) or q.total
    q.status = msg.status or q.status
    q.y0 = tonumber(msg.y0) or q.y0
    q.y1 = tonumber(msg.y1) or q.y1
    q.W = tonumber(msg.W) or q.W
    q.L = tonumber(msg.L) or q.L
    q.H = tonumber(msg.H) or q.H
    if type(msg.job) == "table" then
      q.job = msg.job
      q.W = q.W or tonumber(msg.job.W)
      q.L = q.L or tonumber(msg.job.L) or tonumber(msg.job.D)
      q.H = q.H or tonumber(msg.job.stopY) or tonumber(msg.job.H)
      if msg.job.y1 ~= nil then
        q.H = math.max(q.H or 0, (tonumber(msg.job.y1) or 0) + 1)
      end
      q.idx = tonumber(msg.job.idx) or q.idx
      q.total = tonumber(msg.job.total) or q.total
      q.y0 = tonumber(msg.job.y0) or q.y0
      q.y1 = tonumber(msg.job.y1) or q.y1
    end
    if msg.finished or msg.status == "done" or t == "quarry_done" then
      q.status = "done"
    end
    quarryTurtles[id] = q
    touchSystem(id, q.name, "offline_miner")
  end
end

local function listenerLoop()
  titan.broadcast(MSG.PING, {})
  while true do
    local id, msg = titan.recv(1)
    if msg then handle(id, msg) end
  end
end

local function synthesizeQuarryFromTurtles()
  local ONLINE = 45
  local W, L, H = 0, 0, 0
  local list = {}
  local minBpc = nil
  local online = 0
  local doneCells, totalCells = 0, 0
  for id, t in pairs(quarryTurtles) do
    local age = ago(t.seen)
    if age < ONLINE * 3 then
      W = math.max(W, tonumber(t.W) or 0)
      L = math.max(L, tonumber(t.L) or 0)
      H = math.max(H, tonumber(t.H) or 0)
      if age < ONLINE then
        online = online + 1
        local b = tonumber(t.bpc)
        if b and b > 0 and (not minBpc or b < minBpc) then minBpc = b end
      end
      local tot = tonumber(t.total) or 0
      local idx = math.max(0, (tonumber(t.idx) or 1) - 1)
      if tot > 0 then
        doneCells = doneCells + math.min(tot, idx)
        totalCells = totalCells + tot
      end
      list[#list + 1] = {
        id = id, name = t.name, y0 = t.y0, y1 = t.y1,
        dug = t.dug, idx = t.idx, total = t.total, bpc = t.bpc,
        fuel = t.fuel, status = t.status, age = age,
        job = t.job,
      }
    end
  end
  table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
  if #list == 0 then return nil end
  if totalCells < 1 then
    local plane = math.max(1, W * L)
    totalCells = math.max(1, plane * math.max(1, H))
  end
  local pct = math.floor(math.min(100, (doneCells / math.max(1, totalCells)) * 100) + 0.5)
  return {
    type = "quarry_site",
    source = "turtles",
    siteId = nil,
    name = "Turtles (no site board)",
    W = W, L = L, H = H,
    fraction = "-",
    maxClaim = 0,
    pct = pct, done = doneCells, total = totalCells,
    minBpc = minBpc or 48,
    maxTravel = math.max(16, math.floor((minBpc or 48) * 32 * 0.4)),
    online = online,
    turtles = list,
  }
end

local function effectiveQuarrySnap()
  if quarrySnap and ago(quarrySnapAt) < 45 then
    return quarrySnap
  end
  return synthesizeQuarryFromTurtles()
end

-- offline_site + direct turtle mine broadcasts
local function quarryListenerLoop()
  while true do
    local id, msg = rednet.receive(PROTO_QUARRY, 2)
    if id and type(msg) == "table" and msg.type then
      handle(id, msg)
    end
  end
end

local function requestQuarryStatus(timeout)
  timeout = tonumber(timeout) or 3
  -- Broadcast; quarryListenerLoop / titan handle() collect replies.
  rednet.broadcast({ type = "quarry_status_req", from = os.getComputerID() }, PROTO_QUARRY)
  rednet.broadcast({ type = "quarry_turtle_req", from = os.getComputerID() }, PROTO_QUARRY)
  sleep(timeout)
  return effectiveQuarrySnap()
end

--------------------------------------------------------------------------------
-- Auth — login GUI is defined after the shared GUI helpers below
--------------------------------------------------------------------------------
local promptUnlockAtStart  -- assigned later (login screen)
local showLoginScreen      -- assigned later

local function tryUnlock(promptLabel)
  if unlocked then return true end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    unlocked = true
    return true
  end
  if showLoginScreen then
    return showLoginScreen({ title = promptLabel or "Unlock", once = true })
  end
  if titan.login(promptLabel or "Master password") then
    unlocked = true
    return true
  end
  return false
end

local function requireAuth()
  if unlocked then return true end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    unlocked = true
    return true
  end
  if tryUnlock("Master password") then return true end
  print("Denied (need the Parent Center master online + correct password).")
  return false
end

local function needBot(ref)
  local id = findBot(ref)
  if not id then print("Unknown: " .. tostring(ref) .. "  (try bots / connections)") end
  return id
end

--------------------------------------------------------------------------------
-- Connection discovery (SSH-capable hosts on the mesh)
--------------------------------------------------------------------------------
local function listConnections(filter)
  print("Scanning mesh for SSH hosts...")
  local peers = titan.sshListPeers(2.0)
  local filter = tostring(filter or ""):lower()
  local n = 0
  local function match(row)
    if filter == "" then return true end
    local blob = (tostring(row.id) .. " " .. tostring(row.name or "") .. " " .. tostring(row.kind or "")):lower()
    return blob:find(filter, 1, true) ~= nil
  end

  for _, p in ipairs(peers) do
    touchSystem(p.id, p.name, p.kind)
  end

  print("ID    NAME              KIND         AGE")
  local shown = {}
  for _, p in ipairs(peers) do
    if match(p) then
      n = n + 1
      shown[p.id] = true
      print(("#%-4d %-16s %-12s live"):format(
        p.id, tostring(p.name or "?"):sub(1, 16), tostring(p.kind or "?"):sub(1, 12)))
    end
  end
  for id, b in pairs(bots) do
    if not shown[id] and ago(b.seen) < 60 then
      local row = { id = id, name = b.name, kind = b.botType or b.kind or "bot" }
      if match(row) then
        n = n + 1
        print(("#%-4d %-16s %-12s %ss"):format(
          id, tostring(row.name or "?"):sub(1, 16), tostring(row.kind):sub(1, 12), ago(b.seen)))
      end
    end
  end
  if n == 0 then
    print("(none — is MAIN router up? Are devices running networkLoop/SSH?)")
  else
    print(("(%d)  connect <id|name>   or   ssh <id|name>"):format(n))
  end
end

local function findByKind(kind)
  kind = tostring(kind or ""):lower()
  for id, b in pairs(bots) do
    local k = tostring(b.botType or b.kind or ""):lower()
    if k == kind and ago(b.seen) < 45 then return id, b end
  end
  local peers = titan.sshListPeers(1.5)
  for _, p in ipairs(peers) do
    if tostring(p.kind or ""):lower() == kind then return p.id, p end
    local name = tostring(p.name or ""):lower()
    if kind == "datacenter" and (name:find("parent") or name:find("center") or name:find("data")) then
      return p.id, p
    end
  end
  return nil
end

local function printBots(filterType)
  local ids = {}
  for id, b in pairs(bots) do
    if not filterType or b.botType == filterType or b.kind == filterType then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  local n = 0
  for _, id in ipairs(ids) do
    local b = bots[id]
    if ago(b.seen) < 120 then
      n = n + 1
      local asg = tostring(b.assignment or b.task or "-"):sub(1, 14)
      print(("#%-4d %-12s %-8s %-8s %s %s f:%s %ss"):format(
        id, tostring(b.name or "?"):sub(1, 12),
        tostring(b.botType or b.kind or "?"):sub(1, 8),
        tostring(b.state or "?"):sub(1, 8),
        pos(b), asg, tostring(b.fuel or "?"), ago(b.seen)))
    end
  end
  if n == 0 then print("(none)") end
end

--------------------------------------------------------------------------------
-- Live boards (same stats as MAIN monitor; pretty on advanced pocket)
--------------------------------------------------------------------------------
local LIVE_BOARDS = { "local", "global", "stats", "gps", "bots", "quarry" }
local liveBoard = "local"
local boardSnap = nil
local boardSnapAt = 0

local function termIsColor()
  local ok, c = pcall(function() return term.isColor and term.isColor() end)
  return ok and c == true
end

local function termLayout()
  local w, h = term.getSize()
  local color = termIsColor()
  local tier
  if w < 22 or h < 10 then tier = "tiny"
  elseif w < 30 or h < 14 then tier = "small"
  elseif w < 45 or h < 18 then tier = "medium"
  else tier = "large" end
  return {
    out = term, w = w, h = h, color = color, tier = tier,
    headerH = (tier == "tiny") and 1 or 2,
    footerH = 1,
    pad = (tier == "large" and color) and 1 or 0,
  }
end

local function guiFill(out, x, y, w, h, bg, fg)
  bg = bg or colors.black
  fg = fg or colors.white
  for row = y, y + h - 1 do
    out.setCursorPos(x, row)
    if out.setBackgroundColor then out.setBackgroundColor(bg) end
    if out.setTextColor then out.setTextColor(fg) end
    out.write(string.rep(" ", w))
  end
end

local function guiText(out, x, y, txt, fg, bg)
  if not out or y < 1 then return end
  local w = select(1, out.getSize())
  if x > w then return end
  txt = tostring(txt or "")
  if out.setBackgroundColor then out.setBackgroundColor(bg or colors.black) end
  if out.setTextColor then out.setTextColor(fg or colors.white) end
  out.setCursorPos(x, y)
  out.write(txt:sub(1, math.max(0, w - x + 1)))
end

--------------------------------------------------------------------------------
-- Login screen GUI
--------------------------------------------------------------------------------
showLoginScreen = function(opts)
  opts = opts or {}
  if unlocked then return true end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    unlocked = true
    return true
  end

  local errMsg = nil
  local once = opts.once == true

  while not unlocked do
    local w, h = term.getSize()
    local color = termIsColor()
    local out = term
    local bg = colors.black
    local accent = color and colors.cyan or colors.white
    local panel = color and colors.gray or colors.black
    local btnBg = color and colors.lime or colors.white
    local btnFg = colors.black

    if out.setBackgroundColor then out.setBackgroundColor(bg) end
    out.clear()

    -- Header band
    local headerH = math.min(4, math.max(2, math.floor(h * 0.22)))
    guiFill(out, 1, 1, w, headerH, accent, btnFg)
    guiText(out, 2, 1, " TITAN", btnFg, accent)
    if headerH >= 2 then
      guiText(out, 2, 2, " Admin Tablet", btnFg, accent)
    end
    if headerH >= 3 then
      guiText(out, 2, 3, " " .. (opts.title or "Sign in"), color and colors.black or btnFg, accent)
    end

    local y = headerH + 2
    local label = os.getComputerLabel() or ("#" .. os.getComputerID())
    guiText(out, 2, y, "Device  " .. label:sub(1, w - 10), colors.lightGray, bg)
    y = y + 2

    guiText(out, 2, y, "Master password", colors.white, bg)
    y = y + 1

    -- Password field
    local fieldX, fieldW = 2, math.max(10, w - 2)
    local fieldY = y
    guiFill(out, fieldX, fieldY, fieldW, 1, panel, colors.white)
    guiText(out, fieldX, fieldY, " ", colors.white, panel)

    y = fieldY + 2
    if errMsg then
      guiText(out, 2, y, errMsg:sub(1, w - 2), colors.red, bg)
      y = y + 1
    end

    -- Unlock button
    local btnLabel = "  Unlock  "
    local btnY = math.min(h - 3, y + 1)
    local btnX = math.max(2, math.floor((w - #btnLabel) / 2) + 1)
    guiFill(out, btnX, btnY, #btnLabel, 1, btnBg, btnFg)
    guiText(out, btnX, btnY, btnLabel, btnFg, btnBg)

    guiText(out, 2, h - 1, "Parent Center + master floppy online", colors.gray, bg)
    guiText(out, 2, h, "Type password, then Enter", colors.gray, bg)

    -- Read password in the field
    if out.setBackgroundColor then out.setBackgroundColor(panel) end
    if out.setTextColor then out.setTextColor(colors.white) end
    out.setCursorPos(fieldX, fieldY)
    local pw = read("*")
    if pw and pw ~= "" then
      if titan.checkPassword(pw) then
        unlocked = true
        if out.setBackgroundColor then out.setBackgroundColor(bg) end
        out.clear()
        guiFill(out, 1, 1, w, h, color and colors.green or bg, colors.white)
        guiText(out, 2, math.floor(h / 2), "Unlocked", colors.white, color and colors.green or bg)
        sleep(0.45)
        if out.setBackgroundColor then out.setBackgroundColor(bg) end
        out.clear()
        out.setCursorPos(1, 1)
        return true
      end
      errMsg = "Wrong password or no master online"
      if once then
        if out.setBackgroundColor then out.setBackgroundColor(bg) end
        out.clear()
        out.setCursorPos(1, 1)
        return false
      end
    elseif once then
      if out.setBackgroundColor then out.setBackgroundColor(bg) end
      out.clear()
      out.setCursorPos(1, 1)
      return false
    end
  end
  return unlocked
end

promptUnlockAtStart = function()
  if unlocked then return end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    unlocked = true
    return
  end
  showLoginScreen({ title = "Sign in", once = false })
end

local function guiBar(L, y, title, subtitle, accent)
  local out, w = L.out, L.w
  accent = accent or colors.cyan
  if L.color then
    guiFill(out, 1, y, w, 1, accent, colors.black)
    guiText(out, 2, y, title, colors.black, accent)
    if subtitle and L.tier ~= "tiny" and #title + #subtitle + 4 < w then
      guiText(out, math.max(1, w - #subtitle), y, subtitle, colors.gray, accent)
    end
  else
    guiText(out, 1, y, title, colors.white, colors.black)
    if subtitle and L.tier ~= "tiny" then
      guiText(out, math.max(1, w - #subtitle + 1), y, subtitle, colors.lightGray, colors.black)
    end
  end
end

local function guiChip(out, x, y, label, fg, bg, colorOk)
  label = " " .. tostring(label) .. " "
  if colorOk then
    guiText(out, x, y, label, fg or colors.white, bg or colors.gray)
  else
    local bare = tostring(label):match("^%s*(.-)%s*$") or tostring(label)
    guiText(out, x, y, "[" .. bare .. "]", fg or colors.white, colors.black)
    return x + #bare + 3
  end
  return x + #label + 1
end

local function statusColorOf(st)
  if st == "ONLINE" or st == "ON" then return colors.lime end
  if st == "WIRED" or st == "WR" then return colors.cyan end
  if st == "OFFLINE" or st == "OFF" then return colors.red end
  return colors.yellow
end

local function formatUptime(sec)
  sec = math.max(0, math.floor(tonumber(sec) or 0))
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then return ("%dh %dm"):format(h, m) end
  if m > 0 then return ("%dm %ds"):format(m, s) end
  return ("%ds"):format(s)
end

local function synthesizeBoardSnap()
  -- Fallback when MAIN is not answering board_req yet.
  local nodes = scanNetTopology(1.2, true)
  local localRows, globalRows = {}, {}
  local lon, loff, lunk, gon, goff, gunk = 0, 0, 0, 0, 0, 0
  local kinds = {}
  local mainId, mainName, mainGps
  for _, n in ipairs(nodes) do
    local role = tostring(n.role or n.kind or ""):lower()
    local st = "ONLINE"
    local row = {
      id = n.id, hostname = n.name or ("#" .. n.id),
      kind = (role == "main" and "router") or role or "device",
      status = st, seen = now(),
      homeRouter = n.homeRouter,
    }
    if role == "main" then
      mainId, mainName = n.id, n.name
      if n.x then mainGps = { hosting = true, x = n.x, y = n.y, z = n.z } end
      globalRows[#globalRows + 1] = row
      gon = gon + 1
    elseif role == "router" then
      globalRows[#globalRows + 1] = row
      gon = gon + 1
    else
      localRows[#localRows + 1] = row
      lon = lon + 1
    end
    local k = row.kind
    kinds[k] = (kinds[k] or 0) + 1
  end
  for id, s in pairs(systems) do
    if ago(s.seen) < 60 then
      local k = tostring(s.kind or "device")
      kinds[k] = (kinds[k] or 0) + 1
    end
  end
  return {
    type = "board_snap",
    role = mainId and "main" or "synth",
    id = mainId or 0,
    name = mainName or "mesh",
    localRows = localRows,
    globalRows = globalRows,
    localCounts = { on = lon, off = loff, unk = lunk },
    globalCounts = { on = gon, off = goff, unk = gunk },
    peers = #globalRows, cells = #localRows,
    stats = {
      role = mainId and "main" or "?",
      hostname = mainName or "?",
      uptimeSec = 0,
      modems = #nodes, rf = 0, wire = 0, relayed = 0,
      online = lon + gon, offline = 0, unknown = 0,
      wired = 0, remembered = lon + gon, kinds = kinds,
      peers = #globalRows, cells = #localRows,
    },
    gps = mainGps or { hosting = false },
    synth = true,
  }
end

local function fetchBoardSnap(timeout)
  timeout = timeout or 2.0
  rednet.broadcast({ type = "board_req", from = os.getComputerID() }, PROTO_ROUTER)
  local deadline = os.clock() + timeout
  local best
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO_ROUTER, math.max(0.05, deadline - os.clock()))
    if id and type(msg) == "table" and msg.type == "board_snap" then
      msg._from = id
      if tostring(msg.role or ""):lower() == "main" then
        return msg
      end
      best = best or msg
    end
  end
  return best
end

local function refreshBoardSnap(force)
  if not force and boardSnap and (os.clock() - boardSnapAt) < 2.5 then
    return boardSnap
  end
  local snap = fetchBoardSnap(1.8)
  if not snap then snap = synthesizeBoardSnap() end
  boardSnap, boardSnapAt = snap, os.clock()
  return snap
end

local function drawStatusChips(L, y, on, off, unk)
  local out, w = L.out, L.w
  if L.tier == "tiny" then
    guiText(out, 1, y, ("ON:%d OFF:%d ?:%d"):format(on or 0, off or 0, unk or 0),
      colors.white, colors.black)
    return
  end
  if L.color then
    guiFill(out, 1, y, w, 1, colors.black, colors.white)
    local x = 1
    x = guiChip(out, x, y, "ON " .. tostring(on or 0), colors.black, colors.lime, true)
    x = guiChip(out, x, y, "OFF " .. tostring(off or 0), colors.white, colors.red, true)
    guiChip(out, x, y, "? " .. tostring(unk or 0), colors.black, colors.yellow, true)
  else
    guiText(out, 1, y,
      ("ONLINE:%d  OFFLINE:%d  UNKNOWN:%d"):format(on or 0, off or 0, unk or 0),
      colors.white, colors.black)
  end
end

local function drawRosterBoard(L, scope, snap)
  local out, w, h = L.out, L.w, L.h
  local rows = (scope == "global") and (snap.globalRows or {}) or (snap.localRows or {})
  local counts = (scope == "global") and (snap.globalCounts or {}) or (snap.localCounts or {})
  local title = (scope == "global") and "GLOBAL MESH" or "LOCAL NETWORK"
  local accent = (scope == "global") and (colors.orange or colors.yellow) or (colors.cyan or colors.lightBlue)
  local y = 1
  local src = snap.synth and "scan" or ("#" .. tostring(snap.id or "?"))
  guiBar(L, y, title, src, accent)
  y = y + 1
  if y < h then
    drawStatusChips(L, y, counts.on, counts.off, counts.unk)
    y = y + 1
  end
  if L.tier ~= "tiny" and y < h then
    local meta = ("peers %d  cells %d"):format(
      tonumber(snap.peers) or 0, tonumber(snap.cells) or 0)
    if L.color then
      guiFill(out, 1, y, w, 1, colors.gray, colors.white)
      guiText(out, 2, y, meta, colors.white, colors.gray)
    else
      guiText(out, 1, y, meta, colors.lightGray, colors.black)
    end
    y = y + 1
  end

  local showKind = w >= 28
  local showAge = w >= 34
  local idW = (w < 22) and 3 or 4
  if y < h then
    local hdr = L.tier == "tiny" and "ID ST HOST"
      or (showKind and ("%-" .. idW .. "s %-8s %-6s HOST"):format("ID", "STATUS", "KIND")
          or ("%-" .. idW .. "s %-8s HOST"):format("ID", "STATUS"))
    local hbg = L.color and colors.lightGray or colors.black
    local hfg = L.color and colors.black or colors.lightGray
    if L.color then guiFill(out, 1, y, w, 1, hbg, hfg) end
    guiText(out, 1 + L.pad, y, hdr, hfg, hbg)
    y = y + 1
  end

  local listStart = y
  local y1 = h - L.footerH
  for _, r in ipairs(rows) do
    if y > y1 then break end
    local status = tostring(r.status or "?")
    local stShort = status
    if L.tier == "tiny" then
      if status == "ONLINE" then stShort = "ON"
      elseif status == "OFFLINE" then stShort = "OFF"
      elseif status == "WIRED" then stShort = "WR"
      else stShort = "?" end
    end
    local host = tostring(r.hostname or "?")
    if scope == "global" and r.hub then
      host = host .. " @" .. tostring(r.hub):sub(1, 8)
    elseif scope == "global" and r.homeRouter then
      host = host .. " →#" .. tostring(r.homeRouter)
    end
    local age = (r.seen and r.seen > 0) and (ago(r.seen) .. "s") or "-"
    local bg = colors.black
    if L.color and ((y - listStart) % 2 == 1) then bg = colors.gray end
    if L.color then guiFill(out, 1, y, w, 1, bg, colors.white) end

    local x = 1 + L.pad
    local sc = statusColorOf(status)
    guiText(out, x, y, ("%-" .. idW .. "d"):format(tonumber(r.id) or 0), colors.white, bg)
    x = x + idW + 1
    if L.color and L.tier ~= "tiny" then
      local chip = ("%-8s"):format(stShort)
      local chipFg = (status == "OFFLINE") and colors.white or colors.black
      guiText(out, x, y, chip, chipFg, sc)
      x = x + 9
    else
      guiText(out, x, y, ("%-8s"):format(stShort), sc, bg)
      x = x + 9
    end
    if showKind then
      local kw = (w >= 40) and 8 or 6
      local kindCol = (status == "WIRED") and colors.cyan
        or ((r.remote or scope == "global") and (colors.orange or colors.yellow) or colors.white)
      guiText(out, x, y, ("%-" .. kw .. "s"):format(tostring(r.kind or "?"):sub(1, kw)), kindCol, bg)
      x = x + kw + 1
    end
    local room = w - x - (showAge and (#age + 1) or 0) - L.pad
    if room < 1 then room = math.max(0, w - x) end
    guiText(out, x, y, host:sub(1, room), colors.white, bg)
    if showAge then
      guiText(out, w - #age + 1 - L.pad, y, age, colors.lightGray, bg)
    end
    y = y + 1
  end
  if y == listStart and y <= y1 then
    local empty = (scope == "global")
      and "(no remote hubs — link peer)"
      or "(no local devices — link modem)"
    guiText(out, 1 + L.pad, y, empty, colors.gray, colors.black)
  end
end

local function drawStatsBoard(L, snap)
  local out, w, h = L.out, L.w, L.h
  local st = snap.stats or {}
  local cyan = colors.cyan or colors.lightBlue
  local y = 1
  guiBar(L, y, "STATS", ("#%s"):format(tostring(snap.id or "?")), cyan)
  y = y + 1
  if y < h then
    drawStatusChips(L, y, st.online, st.offline, st.unknown)
    y = y + 1
  end
  local cards = {
    { "ROLE", tostring(st.role or "?"):upper(), colors.white },
    { "HOST", tostring(st.hostname or "?"):sub(1, 16), colors.lightGray },
    { "UP", formatUptime(st.uptimeSec), colors.white },
    { "MODEMS", ("%s rf:%s wire:%s"):format(
        tostring(st.modems or 0), tostring(st.rf or 0), tostring(st.wire or 0)), colors.white },
    { "RELAY", tostring(st.relayed or 0), cyan },
    { "WIRED", tostring(st.wired or 0), cyan },
    { "MEM", tostring(st.remembered or 0), colors.white },
  }
  local y1 = h - L.footerH
  if L.color and L.tier ~= "tiny" and w >= 28 then
    local colW = math.floor((w - 2) / 2)
    local i = 1
    while i <= #cards and y <= y1 do
      local a, b = cards[i], cards[i + 1]
      guiFill(out, 1, y, w, 1, colors.gray, colors.white)
      guiText(out, 1, y, (" %s %s"):format(a[1], a[2]):sub(1, colW), a[3], colors.gray)
      if b then
        guiText(out, colW + 2, y, (" %s %s"):format(b[1], b[2]):sub(1, colW), b[3], colors.gray)
        i = i + 2
      else
        i = i + 1
      end
      y = y + 1
    end
  else
    for _, c in ipairs(cards) do
      if y > y1 then break end
      guiText(out, 1 + L.pad, y, ("%s: %s"):format(c[1], c[2]), c[3], colors.black)
      y = y + 1
    end
  end
  if y <= y1 then
    if L.color then
      guiFill(out, 1, y, w, 1, colors.lightGray, colors.black)
      guiText(out, 2, y, "BY KIND", colors.black, colors.lightGray)
    else
      guiText(out, 1, y, "By kind:", colors.lightGray, colors.black)
    end
    y = y + 1
  end
  local kinds = st.kinds or {}
  local keys = {}
  for k in pairs(kinds) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if y > y1 then break end
    local n = kinds[k]
    if L.color and w >= 24 then
      local barW = math.max(1, math.min(w - 14, n))
      guiText(out, 1 + L.pad, y, ("%-10s %3d "):format(k:sub(1, 10), n), colors.white, colors.black)
      guiText(out, 16 + L.pad, y, string.rep(" ", barW), colors.black, cyan)
    else
      guiText(out, 1 + L.pad, y, ("%-10s %d"):format(k, n), colors.white, colors.black)
    end
    y = y + 1
  end
  if #keys == 0 and y <= y1 then
    guiText(out, 1 + L.pad, y, "(none)", colors.gray, colors.black)
  end
end

local function drawGpsBoard(L, snap)
  local out, w, h = L.out, L.w, L.h
  local g = snap.gps or {}
  local y = 1
  guiBar(L, y, "GPS", g.hosting and "HOSTING" or "IDLE", colors.yellow)
  y = y + 1
  local y1 = h - L.footerH
  local function put(txt, c, bg)
    if y > y1 then return end
    if L.color and bg then guiFill(out, 1, y, w, 1, bg, c or colors.white) end
    guiText(out, 1 + L.pad, y, txt, c or colors.white, bg or colors.black)
    y = y + 1
  end
  if g.hosting then
    if L.color then
      put(" MAIN HOSTING ", colors.black, colors.lime)
      if L.tier == "tiny" then
        put(("%s,%s,%s"):format(g.x, g.y, g.z), colors.white, colors.gray)
      else
        put(("  X %-6s  Y %-6s  Z %-6s"):format(g.x, g.y, g.z), colors.white, colors.gray)
      end
    else
      put("Hosting: YES", colors.lime)
      put(("X: %s  Y: %s  Z: %s"):format(g.x, g.y, g.z), colors.white)
    end
  else
    put(L.color and " NOT HOSTING " or "Hosting: NO",
      L.color and colors.white or colors.red,
      L.color and colors.red or colors.black)
    put("Set on MAIN: gpshost <x> <y> <z>", colors.lightGray)
  end
  if L.tier ~= "tiny" then put("", colors.white) end
  put("Tablet locate", colors.lightGray, L.color and colors.gray or nil)
  local lx, ly, lz = gps.locate(0.3)
  if lx then
    lx = math.floor(lx + 0.5); ly = math.floor(ly + 0.5); lz = math.floor(lz + 0.5)
    put(("  %d, %d, %d"):format(lx, ly, lz), colors.lime)
  else
    put("  (no fix — need 4 hosts)", colors.orange or colors.yellow)
  end
end

local function drawBotsBoard(L)
  local out, w, h = L.out, L.w, L.h
  local total, gath, build, mine, load, mark = 0, 0, 0, 0, 0, 0
  for _, b in pairs(bots) do
    if ago(b.seen) < 20 then
      total = total + 1
      if b.botType == "gatherer" then gath = gath + 1
      elseif b.botType == "builder" then build = build + 1
      elseif b.botType == "miner" then mine = mine + 1
      elseif b.botType == "loader" then load = load + 1
      elseif b.botType == "marker" or b.kind == "marker" then mark = mark + 1 end
    end
  end
  local y = 1
  guiBar(L, y, "BOTS", unlocked and "UNLOCKED" or "locked", colors.yellow)
  y = y + 1
  local summary = ("bots:%d B:%d G:%d M:%d L:%d site:%d"):format(
    total, build, gath, mine, load, mark)
  if L.color then
    guiFill(out, 1, y, w, 1, colors.gray, colors.white)
    guiText(out, 2, y, summary, colors.lime, colors.gray)
  else
    guiText(out, 1, y, summary, colors.lime, colors.black)
  end
  y = y + 1
  if y < h then
    local hbg = L.color and colors.lightGray or colors.black
    local hfg = L.color and colors.black or colors.orange or colors.yellow
    if L.color then guiFill(out, 1, y, w, 1, hbg, hfg) end
    guiText(out, 1 + L.pad, y, "ID   NAME         TYPE     STATE", hfg, hbg)
    y = y + 1
  end
  local ids = {}
  for id in pairs(bots) do ids[#ids + 1] = id end
  table.sort(ids)
  local y1 = h - L.footerH
  local listStart = y
  for _, id in ipairs(ids) do
    if y > y1 then break end
    local b = bots[id]
    if ago(b.seen) < 30 then
      local bg = colors.black
      if L.color and ((y - listStart) % 2 == 1) then bg = colors.gray end
      if L.color then guiFill(out, 1, y, w, 1, bg, colors.white) end
      local fg = (b.state == "idle" or b.state == "parked") and colors.white or colors.cyan
      local line = ("#%-3d %-12s %-8s %-8s"):format(
        id, tostring(b.name or "?"):sub(1, 12),
        tostring(b.botType or "?"):sub(1, 8),
        tostring(b.state or "?"):sub(1, 8))
      if w >= 36 then line = line .. " " .. pos(b) end
      guiText(out, 1 + L.pad, y, line, fg, bg)
      y = y + 1
    end
  end
  local np = 0
  for _, wrow in pairs(pending) do if ago(wrow.seen) < 20 then np = np + 1 end end
  if np > 0 and y <= y1 then
    guiText(out, 1 + L.pad, y, ("+%d awaiting deploy"):format(np), colors.orange or colors.yellow, colors.black)
  elseif y == listStart and y <= y1 then
    guiText(out, 1 + L.pad, y, "(no live bots)", colors.gray, colors.black)
  end
end

local function drawQuarryBoard(L)
  local out = L.out
  local snap = effectiveQuarrySnap()
  local age = nil
  if snap and snap.source == "site_board" and quarrySnapAt > 0 then
    age = ago(quarrySnapAt)
  elseif snap and snap.turtles and snap.turtles[1] then
    age = snap.turtles[1].age
  end
  guiFill(out, 1, 1, L.w, L.h, colors.black, colors.white)
  local title = (snap and snap.source == "turtles") and "QUARRY (turtles)" or "QUARRY SITE"
  if L.color then
    guiFill(out, 1, 1, L.w, 1, colors.cyan, colors.black)
    guiText(out, 1 + L.pad, 1, " " .. title, colors.black, colors.cyan)
  else
    guiText(out, 1, 1, title, colors.yellow, colors.black)
  end
  if not snap then
    guiText(out, 1 + L.pad, 3, "Waiting for offline miners...", colors.lightGray, colors.black)
    guiText(out, 1 + L.pad, 4, "Turtle modem: area dig broadcasts progress", colors.gray, colors.black)
    guiText(out, 1 + L.pad, 5, "Optional site board stores jobs + Y claims", colors.gray, colors.black)
    guiText(out, 1 + L.pad, 7, "Press r to request status", colors.gray, colors.black)
    return
  end
  local name = tostring(snap.name or ("#" .. tostring(snap.siteId or "?")))
  guiText(out, 1 + L.pad, 2, ("%s  %dx%d × %dY  [%s]"):format(
    name:sub(1, 12),
    tonumber(snap.W) or 0, tonumber(snap.L) or 0, tonumber(snap.H) or 0,
    tostring(snap.fraction or "?")), colors.white, colors.black)
  local pct = tonumber(snap.pct) or 0
  guiText(out, 1 + L.pad, 3, ("Progress  %d%%   %s / %s"):format(
    pct, tostring(snap.done or "?"), tostring(snap.total or "?")), colors.lime, colors.black)
  if L.h > 6 then
    local barW = math.max(4, L.w - 2 - L.pad)
    local fill = math.floor(barW * math.min(1, pct / 100))
    out.setCursorPos(1 + L.pad, 4)
    if L.color then
      out.setBackgroundColor(colors.gray)
      out.write(string.rep(" ", barW))
      out.setCursorPos(1 + L.pad, 4)
      out.setBackgroundColor(colors.lime)
      out.write(string.rep(" ", fill))
      out.setBackgroundColor(colors.black)
    else
      out.write("[" .. string.rep("#", fill) .. string.rep("-", barW - fill) .. "]")
    end
  end
  guiText(out, 1 + L.pad, 5, ("online:%s  minBPC:%s  maxTravel:%s  %ss"):format(
    tostring(snap.online or 0),
    tostring(snap.minBpc or "?"),
    tostring(snap.maxTravel or "?"),
    tostring(age or "?")), colors.lightGray, colors.black)
  local y = 7
  guiText(out, 1 + L.pad, 6, "ID   Y-band   BPC   PROG  STATUS", colors.orange or colors.yellow, colors.black)
  local list = snap.turtles or {}
  for _, t in ipairs(list) do
    if y >= L.h - L.footerH then break end
    local band = (t.y0 and t.y1) and ("%d-%d"):format(t.y0, t.y1) or "-"
    local prog = "-"
    if t.total and t.total > 0 and t.idx then
      prog = ("%d%%"):format(math.floor(100 * math.min(1, ((t.idx or 1) - 1) / t.total)))
    end
    local st = tostring(t.status or "?")
    if (t.age or 0) >= 45 then st = "stale" end
    local col = colors.white
    if st == "mining" or st == "assigned" then col = colors.lime
    elseif st == "done" then col = colors.lightGray
    elseif st == "stale" then col = colors.red end
    guiText(out, 1 + L.pad, y, ("#%-3d %-8s %-5s %-5s %s"):format(
      t.id or 0, band, tostring(t.bpc or "?"):sub(1, 5), prog, st), col, colors.black)
    y = y + 1
  end
  if #list == 0 then
    guiText(out, 1 + L.pad, y, "(no turtles joined yet)", colors.gray, colors.black)
  end
end

local function drawLiveFooter(L, board)
  local out, w, h = L.out, L.w, L.h
  local tabs = "1loc 2glb 3stat 4gps 5bots 6qry"
  if L.tier == "tiny" then tabs = "1-6 board  q quit" end
  local mode = L.color and "ADV" or "MONO"
  local right = (" %s %dx%d"):format(mode, w, h)
  local left = (" %s  %s"):format(board, (L.tier == "tiny") and "q=quit" or "←→ tabs  q quit")
  if L.color then
    guiFill(out, 1, h, w, 1, colors.gray, colors.white)
    guiText(out, 1, h, left, colors.white, colors.gray)
    if L.tier ~= "tiny" then
      guiText(out, math.max(1, w - #tabs - #right), h, tabs .. right, colors.lightGray, colors.gray)
    else
      guiText(out, math.max(1, w - #right + 1), h, right, colors.lightGray, colors.gray)
    end
  else
    guiText(out, 1, h, (left .. " " .. tabs .. right):sub(1, w), colors.gray, colors.black)
  end
end

local function drawLiveBoard(board)
  board = board or liveBoard
  local L = termLayout()
  if L.out.setBackgroundColor then L.out.setBackgroundColor(colors.black) end
  if L.out.setTextColor then L.out.setTextColor(colors.white) end
  L.out.clear()
  if board == "quarry" then
    drawQuarryBoard(L)
  else
    local snap = boardSnap or refreshBoardSnap(false)
    if board == "global" then
      drawRosterBoard(L, "global", snap or {})
    elseif board == "stats" then
      drawStatsBoard(L, snap or {})
    elseif board == "gps" then
      drawGpsBoard(L, snap or {})
    elseif board == "bots" then
      drawBotsBoard(L)
    else
      drawRosterBoard(L, "local", snap or {})
    end
  end
  drawLiveFooter(L, board)
end

local function normalizeLiveBoard(name)
  name = tostring(name or ""):lower()
  if name == "roster" or name == "loc" or name == "l" then return "local" end
  if name == "mesh" or name == "glb" or name == "g" then return "global" end
  if name == "stat" or name == "s" then return "stats" end
  if name == "p" then return "gps" end
  if name == "bot" or name == "b" then return "bots" end
  if name == "q" or name == "site" or name == "offline" then return "quarry" end
  for _, b in ipairs(LIVE_BOARDS) do
    if b == name then return name end
  end
  return nil
end

local function cycleLiveBoard(delta)
  local idx = 1
  for i, b in ipairs(LIVE_BOARDS) do
    if b == liveBoard then idx = i; break end
  end
  idx = ((idx - 1 + delta) % #LIVE_BOARDS) + 1
  liveBoard = LIVE_BOARDS[idx]
end

local function liveView(startBoard)
  if startBoard then
    liveBoard = normalizeLiveBoard(startBoard) or liveBoard
  end
  if liveBoard == "quarry" then
    requestQuarryStatus(2)
  else
    refreshBoardSnap(true)
  end
  drawLiveBoard(liveBoard)
  local timer = os.startTimer(1)
  local snapTimer = os.startTimer(3)
  while true do
    local ev, p1, p2 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      drawLiveBoard(liveBoard)
      timer = os.startTimer(1)
    elseif ev == "timer" and p1 == snapTimer then
      if liveBoard == "quarry" then
        -- keep last broadcast; optional soft refresh
      else
        refreshBoardSnap(true)
      end
      drawLiveBoard(liveBoard)
      snapTimer = os.startTimer(3)
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "q" then break
      elseif ch == "1" then liveBoard = "local"; drawLiveBoard(liveBoard)
      elseif ch == "2" then liveBoard = "global"; drawLiveBoard(liveBoard)
      elseif ch == "3" then liveBoard = "stats"; drawLiveBoard(liveBoard)
      elseif ch == "4" then liveBoard = "gps"; drawLiveBoard(liveBoard)
      elseif ch == "5" then liveBoard = "bots"; drawLiveBoard(liveBoard)
      elseif ch == "6" then liveBoard = "quarry"; requestQuarryStatus(2); drawLiveBoard(liveBoard)
      elseif ch == "r" then
        if liveBoard == "quarry" then requestQuarryStatus(2) else refreshBoardSnap(true) end
        drawLiveBoard(liveBoard)
      elseif ch == "\t" then cycleLiveBoard(1); drawLiveBoard(liveBoard)
      end
    elseif ev == "key" then
      local K = keys
      if p1 == K.q or p1 == K.backspace then break
      elseif p1 == K.right or p1 == K.tab then
        cycleLiveBoard(1); drawLiveBoard(liveBoard)
      elseif p1 == K.left then
        cycleLiveBoard(-1); drawLiveBoard(liveBoard)
      elseif p1 == K.r then
        if liveBoard == "quarry" then requestQuarryStatus(2) else refreshBoardSnap(true) end
        drawLiveBoard(liveBoard)
      end
    elseif ev == "mouse_click" then
      -- button, x, y — tap right half → next board; left → prev
      local w = select(1, term.getSize())
      local x = p2
      if x and x > 0 then
        if x > w / 2 then cycleLiveBoard(1) else cycleLiveBoard(-1) end
        drawLiveBoard(liveBoard)
      end
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
-- SSH / connect helper
--------------------------------------------------------------------------------
local function doConnect(a)
  if not a[2] then
    print("Usage: connect <id|label> [command...]")
    print("       ssh <id|label> [command...]")
    print("List targets first:  connections")
    return true
  end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    print("Nested ssh from an SSH session is not supported.")
    return true
  end
  if not requireAuth() then return true end
  local target = a[2]
  local cmdline
  if a[3] then
    local parts = {}
    for i = 3, #a do parts[#parts + 1] = a[i] end
    cmdline = table.concat(parts, " ")
  end
  print(("Connecting to %s ..."):format(target))
  titan.sshConnect(target, cmdline)
  return true
end

local function sshOneShot(target, line)
  if not requireAuth() then return false end
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    print("Nested ssh not supported — run that command after `connect`.")
    return false
  end
  titan.sshConnect(target, line)
  return true
end

--------------------------------------------------------------------------------
-- Network link (ender routers + local RF modems)
--------------------------------------------------------------------------------
scanNetTopology = function(timeout, quiet)
  timeout = timeout or 2.5
  if not quiet then print("Scanning network topology...") end
  rednet.broadcast({ type = "net_topo_req", from = os.getComputerID() }, PROTO_ROUTER)
  local nodes, seenN = {}, {}
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO_ROUTER, deadline - os.clock())
    if id and type(msg) == "table" and (msg.type == "net_topo" or msg.type == "net_link_hello") then
      if not seenN[id] then
        seenN[id] = true
        nodes[#nodes + 1] = {
          id = id,
          name = msg.name or msg.hostname or ("#" .. id),
          role = msg.role or msg.kind or "?",
          kind = msg.kind or msg.role or "?",
          homeRouter = msg.homeRouter,
          peers = msg.peers or {},
          cells = msg.cells or {},
          x = msg.x, y = msg.y, z = msg.z,
        }
      end
    end
  end
  local peers = titan.sshListPeers(1.2)
  for _, p in ipairs(peers) do
    if not seenN[p.id] then
      local k = tostring(p.kind or "")
      if k == "router" or k == "modem" or k:find("router", 1, true) then
        seenN[p.id] = true
        nodes[#nodes + 1] = {
          id = p.id, name = p.name or ("#" .. p.id),
          role = k, kind = k, peers = {}, cells = {},
        }
      end
    end
  end
  table.sort(nodes, function(a, b)
    local function rank(r)
      r = tostring(r or ""):lower()
      if r == "main" then return 0 end
      if r == "router" then return 1 end
      if r == "modem" then return 2 end
      return 3
    end
    local ra, rb = rank(a.role), rank(b.role)
    if ra ~= rb then return ra < rb end
    return a.id < b.id
  end)
  return nodes
end

local function printNetTopology(nodes)
  nodes = nodes or scanNetTopology()
  print("== Network topology ==")
  print("MAIN/ROUTER = ender long-haul    MODEM = local RF cell")
  if #nodes == 0 then
    print("(none answered — are routers running updated router.lua?)")
    return nodes
  end
  for _, n in ipairs(nodes) do
    local pstr = (n.x and ("%d,%d,%d"):format(n.x, n.y or 0, n.z)) or "no-gps"
    print(("#%d  %-7s  %-16s  %s"):format(
      n.id, tostring(n.role):upper():sub(1, 7), tostring(n.name):sub(1, 16), pstr))
    if n.homeRouter then
      print(("       home -> #%s"):format(tostring(n.homeRouter)))
    end
    if type(n.peers) == "table" and #n.peers > 0 then
      local bits = {}
      for _, p in ipairs(n.peers) do bits[#bits + 1] = "#" .. tostring(p.id) end
      print("       peers: " .. table.concat(bits, " "))
    end
    if type(n.cells) == "table" and #n.cells > 0 then
      local bits = {}
      for _, c in ipairs(n.cells) do bits[#bits + 1] = "#" .. tostring(c.id) end
      print("       cells: " .. table.concat(bits, " "))
    end
  end
  print("Commands: link <a> <b>  |  link auto  |  link peer|modem ...")
  return nodes
end

local function sendNetLink(targetId, action, withId, withName)
  rednet.send(tonumber(targetId), {
    type = "net_link",
    action = action,
    with = tonumber(withId),
    withName = withName,
    name = os.getComputerLabel(),
    from = os.getComputerID(),
  }, PROTO_ROUTER)
  local deadline = os.clock() + 3
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTO_ROUTER, deadline - os.clock())
    if id == tonumber(targetId) and type(msg) == "table" and msg.type == "net_link_ack" then
      return msg.ok, msg.err or msg
    end
  end
  return nil, "no ack (update that node / in range?)"
end

local function classifyNetNode(node)
  local r = tostring(node.role or node.kind or ""):lower()
  if r == "main" or r == "router" then return "backbone" end
  if r == "modem" then return "modem" end
  if r:find("router", 1, true) then return "backbone" end
  return "other"
end

local function dist2(a, b)
  if not (a.x and a.z and b.x and b.z) then return nil end
  local dx, dz = a.x - b.x, a.z - b.z
  local dy = (a.y or 0) - (b.y or 0)
  return dx * dx + dy * dy + dz * dz
end

local function doNetworkLink(a)
  if not requireAuth() then return true end
  local sub = (a[2] or ""):lower()

  if sub == "" or sub == "status" or sub == "show" or sub == "topo" or sub == "map" then
    printNetTopology()
    return true
  elseif sub == "scan" then
    printNetTopology(scanNetTopology(3.5))
    return true
  elseif sub == "help" or sub == "?" then
    print("link                 show routers + modem cells")
    print("link scan            longer topology scan")
    print("link <idA> <idB>     smart: router↔router OR modem→router")
    print("link peer <r1> <r2>  force backbone peer (ender)")
    print("link modem <m> <r>   attach modem cell to MAIN/ROUTER")
    print("link auto            peer all routers; modems → nearest hub")
    return true
  elseif sub == "auto" then
    local nodes = scanNetTopology(3)
    local backbone, modems = {}, {}
    for _, n in ipairs(nodes) do
      if classifyNetNode(n) == "backbone" then backbone[#backbone + 1] = n
      elseif classifyNetNode(n) == "modem" then modems[#modems + 1] = n end
    end
    print(("Auto-link: %d backbone, %d modems"):format(#backbone, #modems))
    local peered = 0
    for i = 1, #backbone do
      for j = i + 1, #backbone do
        local aN, bN = backbone[i], backbone[j]
        print(("  peer #%d ↔ #%d"):format(aN.id, bN.id))
        local ok1 = sendNetLink(aN.id, "peer", bN.id, bN.name)
        local ok2 = sendNetLink(bN.id, "peer", aN.id, aN.name)
        if ok1 or ok2 then peered = peered + 1 end
      end
    end
    local attached = 0
    for _, m in ipairs(modems) do
      local best, bestD = backbone[1], nil
      for _, b in ipairs(backbone) do
        local d = dist2(m, b)
        if d and (not bestD or d < bestD) then best, bestD = b, d end
      end
      if best then
        print(("  modem #%d → hub #%d%s"):format(
          m.id, best.id, bestD and (" (~" .. math.floor(math.sqrt(bestD)) .. "m)") or ""))
        local okM = sendNetLink(m.id, "home", best.id, best.name)
        local okH = sendNetLink(best.id, "cell", m.id, m.name)
        if okM or okH then attached = attached + 1 end
      end
    end
    print(("Done. peered~%d  attached~%d"):format(peered, attached))
    printNetTopology(scanNetTopology(2))
    return true
  elseif sub == "peer" or sub == "router" then
    local r1, r2 = tonumber(a[3]), tonumber(a[4])
    if not (r1 and r2) then print("Usage: link peer <routerId> <routerId>"); return true end
    print(("Peering #%d ↔ #%d ..."):format(r1, r2))
    local ok1, e1 = sendNetLink(r1, "peer", r2)
    local ok2, e2 = sendNetLink(r2, "peer", r1)
    print(ok1 and ("  #%d ok"):format(r1) or ("  #%d: %s"):format(r1, tostring(e1)))
    print(ok2 and ("  #%d ok"):format(r2) or ("  #%d: %s"):format(r2, tostring(e2)))
    return true
  elseif sub == "modem" or sub == "cell" or sub == "home" then
    local m, r = tonumber(a[3]), tonumber(a[4])
    if not (m and r) then print("Usage: link modem <modemId> <routerId>"); return true end
    print(("Attach modem #%d → hub #%d ..."):format(m, r))
    local okM, eM = sendNetLink(m, "home", r)
    local okH, eH = sendNetLink(r, "cell", m)
    print(okM and "  modem home ok" or ("  modem: " .. tostring(eM)))
    print(okH and "  hub cell ok" or ("  hub: " .. tostring(eH)))
    return true
  end

  local idA, idB = tonumber(a[2]), tonumber(a[3])
  if idA and idB then
    local nodes = scanNetTopology(2)
    local byId = {}
    for _, n in ipairs(nodes) do byId[n.id] = n end
    local na = byId[idA] or { id = idA, role = systems[idA] and systems[idA].kind or "?" }
    local nb = byId[idB] or { id = idB, role = systems[idB] and systems[idB].kind or "?" }
    local ca, cb = classifyNetNode(na), classifyNetNode(nb)
    if ca == "backbone" and cb == "backbone" then
      return doNetworkLink({ "link", "peer", tostring(idA), tostring(idB) })
    elseif ca == "modem" and cb == "backbone" then
      return doNetworkLink({ "link", "modem", tostring(idA), tostring(idB) })
    elseif cb == "modem" and ca == "backbone" then
      return doNetworkLink({ "link", "modem", tostring(idB), tostring(idA) })
    end
    print(("Not sure how to link #%d (%s) with #%d (%s)."):format(
      idA, tostring(na.role), idB, tostring(nb.role)))
    print("Use: link peer <r1> <r2>   or   link modem <m> <r>")
    return true
  end

  print("Unknown. Try: link help")
  return true
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local HELP_PER_PAGE = 10
local HELP_ENTRIES = {
  { "live [board]", "MAIN boards (local/global/stats/gps/bots/quarry)" },
  { "quarry", "Offline quarry site progress %" },
  { "bots", "All known turtles" },
  { "miners", "Miner turtles only" },
  { "loaders", "Loader turtles only" },
  { "markers", "Site markers" },
  { "pending", "Turtles waiting to deploy" },
  { "stuck", "Recent stuck reports" },
  { "connections", "SSH-reachable hosts" },
  { "list [filter]", "Filter connections" },
  { "ping", "Ping the mesh" },
  { "who <id|name>", "Lookup a device" },
  { "link", "Show network topology" },
  { "link auto", "Auto peer routers / attach modems" },
  { "link <a> <b>", "Peer or attach by role" },
  { "connect <id>", "SSH shell (alias: ssh)" },
  { "goto <id> x y z", "Send turtle to coords" },
  { "return|park <id>", "Send turtle home / park" },
  { "refuel <id>", "Ask turtle to refuel" },
  { "stop <id>", "Stop turtle job" },
  { "mine|continue <id>", "Start / resume mining" },
  { "deploy <id> <role>", "Deploy miner|loader|builder|gatherer" },
  { "dc | center", "Jump to Parent Center" },
  { "flatten ...", "Run flatten on Parent Center" },
  { "jobs", "Parent Center job list" },
  { "scan | build", "Builder scan / build" },
  { "mode simple", "Phone home UI" },
  { "mode advanced", "Command console" },
  { "hostname [name]", "Show / set label" },
  { "login | lock", "Unlock session / lock tablet" },
  { "help [page]", "This list (10 per page)" },
  { "exit", "Quit admin" },
}

local function printHelpPage(page, pages)
  pages = pages or math.max(1, math.ceil(#HELP_ENTRIES / HELP_PER_PAGE))
  page = math.max(1, math.min(pages, tonumber(page) or 1))
  local i0 = (page - 1) * HELP_PER_PAGE + 1
  local i1 = math.min(#HELP_ENTRIES, i0 + HELP_PER_PAGE - 1)
  print(("Commands  page %d/%d  (%d–%d of %d)"):format(
    page, pages, i0, i1, #HELP_ENTRIES))
  print(string.rep("-", 36))
  for i = i0, i1 do
    local e = HELP_ENTRIES[i]
    local n = i - i0 + 1
    print((" %2d  %-20s %s"):format(n, e[1], e[2]))
  end
  return page, pages
end

local function showHelpPages(startPage)
  local pages = math.max(1, math.ceil(#HELP_ENTRIES / HELP_PER_PAGE))
  local page = math.max(1, math.min(pages, tonumber(startPage) or 1))
  -- SSH / non-interactive: one page then return
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    printHelpPage(page, pages)
    if pages > 1 then
      print(("More: help <1-%d>"):format(pages))
    end
    return
  end
  while true do
    term.clear(); term.setCursorPos(1, 1)
    if term.setTextColor then term.setTextColor(colors.white) end
    printHelpPage(page, pages)
    print("")
    print("Pick page 1-" .. pages .. "  |  n next  |  p prev  |  Enter back")
    write("help> ")
    local line = tostring(read() or ""):lower()
    if line == "" or line == "q" or line == "back" or line == "exit" then
      break
    elseif line == "n" or line == "next" or line == "+" or line == "d" then
      page = (page % pages) + 1
    elseif line == "p" or line == "prev" or line == "-" or line == "a" then
      page = page - 1
      if page < 1 then page = pages end
    else
      local n = tonumber(line)
      if n and n >= 1 and n <= pages then
        page = n
      else
        print("Unknown. Enter a page number, n/p, or Enter.")
        sleep(0.7)
      end
    end
  end
end

local function handleCommand(a)
  local cmd = (a[1] or ""):lower()

  if cmd == "" then
    return true
  elseif cmd == "help" or cmd == "cmds" or cmd == "?" then
    if cfg.mode == "simple" and not (titan.sshIsAuthed and titan.sshIsAuthed()) then
      print("Simple mode: open apps on the home screen.")
      print("  mode advanced   — command console (paginated help)")
      print("  mode simple     — phone home")
    else
      showHelpPages(a[2])
    end

  elseif cmd == "mode" or cmd == "ui" then
    local m = tostring(a[2] or ""):lower()
    if m == "" then
      print("UI mode: " .. tostring(cfg.mode))
      print("Usage: mode simple | mode advanced")
    elseif m == "simple" or m == "easy" or m == "menu" then
      cfg.mode = "simple"
      saveAdminCfg()
      print("Switched to SIMPLE menus. (Restart console loop next boot, or continue in menu.)")
      return "switch_simple"
    elseif m == "advanced" or m == "adv" or m == "expert" or m == "cli" then
      cfg.mode = "advanced"
      saveAdminCfg()
      print("Switched to ADVANCED command console.")
      return "switch_advanced"
    else
      print("Usage: mode simple | mode advanced")
    end

  elseif cmd == "hostname" or cmd == "host" then
    if not a[2] then
      print("hostname: " .. (os.getComputerLabel() or "?"))
    else
      local name, err = titan.setHostname(table.concat(a, " ", 2), "admin")
      if name then print("hostname set: " .. name) else print(tostring(err)) end
    end

  elseif cmd == "live" or cmd == "boards" or cmd == "screen" then
    if titan.sshIsAuthed and titan.sshIsAuthed() then
      print("live view is local-only. Use `bots` / `connections` over SSH.")
    else
      liveView(a[2])
    end

  elseif cmd == "quarry" or cmd == "quarrysite" or cmd == "offlinesite" then
    if titan.sshIsAuthed and titan.sshIsAuthed() then
      local s = requestQuarryStatus(2) or effectiveQuarrySnap()
      if not s then
        print("No offline miners reporting (modem + area dig, or offline_site).")
      else
        print(("Quarry %s  %dx%d × %dY  %d%%  online=%s  [%s]"):format(
          tostring(s.siteId or "turtles"),
          tonumber(s.W) or 0, tonumber(s.L) or 0, tonumber(s.H) or 0,
          tonumber(s.pct) or 0, tostring(s.online or 0),
          tostring(s.source or "?")))
        print(("minBPC=%s  maxTravel=%s  claim=%s"):format(
          tostring(s.minBpc or "?"), tostring(s.maxTravel or "?"),
          tostring(s.fraction or "?")))
        for _, t in ipairs(s.turtles or {}) do
          print(("#%d %s  Y%s  bpc=%s  %s"):format(
            t.id or 0, tostring(t.name or "?"):sub(1, 12),
            (t.y0 and ("%d-%d"):format(t.y0, t.y1)) or "-",
            tostring(t.bpc or "?"), tostring(t.status or "?")))
        end
      end
    else
      liveView("quarry")
    end

  elseif cmd == "connections" or cmd == "hosts" or cmd == "list" then
    listConnections(a[2])

  elseif cmd == "link" or cmd == "netlink" or cmd == "topology" then
    return doNetworkLink(a)

  elseif cmd == "who" or cmd == "find" then
    local ref = a[2]
    if not ref then print("Usage: who <id|name>"); return true end
    local id = findBot(ref) or tonumber(ref)
    if not id then
      print("Scanning...")
      id = titan.sshResolve(ref, 2)
    end
    if not id then print("Not found: " .. tostring(ref)); return true end
    local b, s = bots[id], systems[id]
    print(("#%d  %s"):format(id, (b and b.name) or (s and s.name) or "?"))
    if b then
      print(("  type=%s  state=%s  pos=%s  fuel=%s  asg=%s  %ss"):format(
        tostring(b.botType or b.kind), tostring(b.state), pos(b),
        tostring(b.fuel), tostring(b.assignment or "-"), ago(b.seen)))
    elseif s then
      print(("  kind=%s  %ss"):format(tostring(s.kind), ago(s.seen)))
    end
    print("  connect " .. tostring(id))

  elseif cmd == "bots" then
    printBots(nil)
  elseif cmd == "miners" then
    printBots("miner")
  elseif cmd == "loaders" then
    printBots("loader")
  elseif cmd == "markers" or cmd == "sites" then
    printBots("marker")
  elseif cmd == "builders" then
    printBots("builder")
  elseif cmd == "gatherers" then
    printBots("gatherer")

  elseif cmd == "pois" then
    for name, p in pairs(pois) do
      print(("%s %d,%d,%d %s"):format(name, p.x or 0, p.y or 0, p.z or 0, p.desc or ""))
    end

  elseif cmd == "pending" then
    local n = 0
    for id, w in pairs(pending) do
      if ago(w.seen) < 30 then
        n = n + 1
        print(("#%d %s [%s] @ %s,%s,%s"):format(
          id, w.name or "?", w.kind or "?", w.x or "?", w.y or "?", w.z or "?"))
      end
    end
    if n == 0 then print("(none awaiting deployment)") end

  elseif cmd == "stuck" then
    for i, al in ipairs(stuck) do
      print(("%d) %s @ %d,%d,%d %s"):format(
        i, al.name or "?", al.x or 0, al.y or 0, al.z or 0, al.reason or ""))
    end

  elseif cmd == "ping" then
    titan.broadcast(MSG.PING, {})
    print("Pinged titan_net. Run `connections` for SSH hosts.")

  elseif cmd == "connect" or cmd == "ssh" or cmd == "c" then
    return doConnect(a)

  elseif cmd == "dc" or cmd == "center" or cmd == "datacenter" or cmd == "parent" then
    local id, row = findByKind("datacenter")
    if not id then
      print("Parent Center not found on mesh. Try: connections datacenter")
      print("Or: connect <ParentCenter-name>")
    else
      print(("Parent Center -> #%d %s"):format(id, (row and row.name) or "?"))
      a[2] = tostring(id)
      if a[3] then
        local parts = { "connect", tostring(id) }
        for i = 3, #a do parts[#parts + 1] = a[i] end
        return doConnect(parts)
      end
      return doConnect({ "connect", tostring(id) })
    end

  elseif cmd == "flatten" or cmd == "minejob" then
    local id = findByKind("datacenter")
    if not id then print("No Parent Center found. Use: connections"); return true end
    if not a[2] then
      print("Usage: flatten <x> <z> <W>x<D> <yEnd> [nBots] [yStart] [yband|strip]")
      print("Runs on Parent Center via SSH.")
      return true
    end
    local line = table.concat(a, " ")
    print("Sending to Parent Center #" .. id)
    sshOneShot(tostring(id), line)

  elseif cmd == "jobs" then
    local id = findByKind("datacenter")
    if not id then print("No Parent Center found."); return true end
    sshOneShot(tostring(id), "jobs")

  elseif cmd == "send" then
    local id, p = needBot(a[2]), pois[a[3] or ""]
    if id and p and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "goto", x = p.x, y = p.y, z = p.z, poi = a[3] })
      print(("-> %s to POI %s"):format(a[2], a[3]))
    elseif id and not p then print("Unknown POI: " .. tostring(a[3])) end

  elseif cmd == "goto" then
    local id = needBot(a[2])
    local x, y, z = tonumber(a[3]), tonumber(a[4]), tonumber(a[5])
    if id and x and y and z and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "goto", x = x, y = y, z = z })
      print(("-> %s to %d,%d,%d"):format(a[2], x, y, z))
    elseif id then print("Usage: goto <bot> <x> <y> <z>") end

  elseif cmd == "return" or cmd == "home" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "return" })
      print("Recalled " .. a[2])
    end

  elseif cmd == "park" or cmd == "tostage" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "park" })
      print("Park/stage " .. a[2])
    end

  elseif cmd == "refuel" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "refuel" })
      print("Refuel " .. a[2])
    end

  elseif cmd == "stop" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "stop" })
      print("Stopped " .. a[2])
    end

  elseif cmd == "mine" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "mine" })
      print("Mine queued on " .. a[2])
    end

  elseif cmd == "continue" or cmd == "resume" then
    local id = needBot(a[2])
    if id and requireAuth() then
      titan.send(id, MSG.COMMAND, { cmd = "continue" })
      print("Continue queued on " .. a[2])
    end

  elseif cmd == "deploy" then
    local id = findBot(a[2]) or tonumber(a[2])
    if not id then
      local want = tostring(a[2] or ""):lower()
      for pid, w in pairs(pending) do
        if w.name and w.name:lower() == want then id = pid; break end
      end
    end
    local btype = (a[3] or ""):lower()
    if btype == "mine" then btype = "miner" end
    if btype == "build" then btype = "builder" end
    if btype == "gather" then btype = "gatherer" end
    if btype == "chunk" or btype == "chunky" then btype = "loader" end
    local okType = btype == "builder" or btype == "gatherer"
      or btype == "miner" or btype == "loader"
    local coordAt = 4
    if a[4] and tonumber(a[4]) then coordAt = 4
    elseif a[4] and (a[4]:lower() == "auto" or not tonumber(a[4])) then
      coordAt = 5
    end
    local name = titan.uniqueBotName(btype, id)
    if not id then
      print("Unknown worker: " .. tostring(a[2]) .. " (try 'pending')")
    elseif not okType then
      print("Usage: deploy <id> <miner|loader|builder|gatherer> [auto] [x y z]")
      print("Example: deploy 20 miner")
      print("Example: deploy 21 loader")
    elseif requireAuth() then
      local deposit
      if a[coordAt] and a[coordAt + 1] and a[coordAt + 2] then
        deposit = {
          x = tonumber(a[coordAt]), y = tonumber(a[coordAt + 1]), z = tonumber(a[coordAt + 2]),
        }
      end
      local payload = {
        botType = btype, name = name, deposit = deposit,
        storage = deposit, stage = (btype == "loader" or btype == "miner") and deposit or nil,
        cruiseY = 150,
      }
      titan.send(id, MSG.WORKER_DEPLOY, payload)
      print(("Deploy sent to #%d: %s '%s'"):format(id, btype, name))
    end

  elseif cmd == "scan" then
    local id = needBot(a[2])
    if id and a[3] and a[4] and a[5] and a[6] and requireAuth() then
      titan.send(id, MSG.SCAN_ORDER, {
        name = a[3], W = tonumber(a[4]), H = tonumber(a[5]), L = tonumber(a[6]),
      })
      print("Scan order sent.")
    elseif id then print("Usage: scan <bot> <name> <W> <H> <L>") end

  elseif cmd == "build" then
    local id = needBot(a[2])
    if id and a[3] and requireAuth() then
      titan.send(id, MSG.BUILD_ORDER, {
        name = a[3], x = tonumber(a[4]), y = tonumber(a[5]), z = tonumber(a[6]),
      })
      print("Build order sent.")
    elseif id then print("Usage: build <bot> <name> [x y z]") end

  elseif cmd == "login" or cmd == "password" then
    if unlocked then
      print("Already unlocked.")
    else
      promptUnlockAtStart()
    end
  elseif cmd == "lock" or cmd == "logout" then
    unlocked = false
    print("Locked.")
    promptUnlockAtStart()
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    return false
  end
  return true
end

--------------------------------------------------------------------------------
-- Simple mode helpers (phone home + wizards)
--------------------------------------------------------------------------------
local function pauseSimple(msg)
  if msg then print(msg) end
  write("Press Enter...")
  read()
end

local function askLine(prompt)
  write(prompt or "> ")
  return tostring(read() or "")
end

local function askNumber(prompt)
  local n = tonumber(askLine(prompt))
  return n
end

local function collectOnline(filterType)
  local list = {}
  for id, b in pairs(bots) do
    if ago(b.seen) < 45 then
      local t = tostring(b.botType or b.kind or ""):lower()
      if not filterType or t == filterType
          or (filterType == "miner" and (t == "excavator"))
          or (filterType == "marker" and (t == "site" or t == "marker")) then
        list[#list + 1] = { id = id, b = b }
      end
    end
  end
  table.sort(list, function(a, c) return a.id < c.id end)
  return list
end

local function collectPending()
  local list = {}
  for id, w in pairs(pending) do
    if ago(w.seen) < 45 then
      list[#list + 1] = { id = id, w = w }
    end
  end
  table.sort(list, function(a, c) return a.id < c.id end)
  return list
end

local function pickFromList(title, list, formatter)
  if #list == 0 then
    print("(none found — wait for status, or check mesh/routers)")
    pauseSimple()
    return nil
  end
  print(title)
  for i, row in ipairs(list) do
    print(("  %d) %s"):format(i, formatter(row)))
  end
  print("  0) Cancel")
  local n = askNumber("Pick number: ")
  if not n or n < 1 or n > #list then return nil end
  return list[n]
end

local function simplePickBot(filterType, title)
  return pickFromList(title or "Pick a turtle:", collectOnline(filterType), function(row)
    local b = row.b
    return ("#%d %s  [%s] %s  %s"):format(
      row.id, tostring(b.name or "?"):sub(1, 14),
      tostring(b.botType or "?"):sub(1, 8),
      tostring(b.state or "?"):sub(1, 8), pos(b))
  end)
end

local function simpleBotAction(cmdName, filterType)
  local row = simplePickBot(filterType, ("Pick turtle for %s:"):format(cmdName))
  if not row then return end
  handleCommand({ cmdName, tostring(row.id) })
  pauseSimple()
end

local function simpleDeployWizard()
  local list = collectPending()
  if #list == 0 then
    -- Also allow deploying already-seen unnamed/await bots from bots table
    print("No turtles awaiting deploy right now.")
    print("Power on a fresh miner/worker (no name) so it shows as pending.")
    pauseSimple()
    return
  end
  local row = pickFromList("Turtles waiting for deploy:", list, function(r)
    return ("#%d %s [%s] @ %s,%s,%s"):format(
      r.id, tostring(r.w.name or "?"), tostring(r.w.kind or "?"),
      tostring(r.w.x or "?"), tostring(r.w.y or "?"), tostring(r.w.z or "?"))
  end)
  if not row then return end
  print("Role:")
  print("  1) Miner")
  print("  2) Loader (chunk escort)")
  print("  3) Builder")
  print("  4) Gatherer")
  print("  0) Cancel")
  local choice = askNumber("Pick: ")
  local map = { [1] = "miner", [2] = "loader", [3] = "builder", [4] = "gatherer" }
  local btype = map[choice or -1]
  if not btype then return end
  print("Optional deposit/stage coords (or leave blank):")
  local xs = askLine("X (blank=skip): ")
  if xs ~= "" then
    local x = tonumber(xs)
    local y = askNumber("Y: ")
    local z = askNumber("Z: ")
    if x and y and z then
      handleCommand({ "deploy", tostring(row.id), btype, tostring(x), tostring(y), tostring(z) })
    else
      print("Bad coords — deploying without deposit.")
      handleCommand({ "deploy", tostring(row.id), btype })
    end
  else
    handleCommand({ "deploy", tostring(row.id), btype })
  end
  pauseSimple()
end

local function simpleFlattenWizard()
  local id = findByKind("datacenter")
  if not id then
    print("Parent Center not found on the mesh.")
    print("Check MAIN router + extenders, then try again.")
    pauseSimple()
    return
  end
  print("Flatten wizard (runs on Parent Center)")
  print("Enter the area corner and size.")
  local x = askNumber("Corner X: ")
  local z = askNumber("Corner Z: ")
  local w = askNumber("Width (blocks +X): ")
  local d = askNumber("Depth (blocks +Z): ")
  local yEnd = askNumber("Bottom Y (e.g. -59): ")
  local nBots = askNumber("How many miners? ") or 4
  local yStart = askNumber("Top Y (blank=skip): ")
  print("Split mode: 1) yband (layers)  2) strip (columns)")
  local modeN = askNumber("Pick [1]: ") or 1
  local mode = (modeN == 2) and "strip" or "yband"
  if not (x and z and w and d and yEnd) then
    print("Need X Z width depth and bottom Y.")
    pauseSimple()
    return
  end
  local args = {
    "flatten", tostring(x), tostring(z),
    ("%dx%d"):format(w, d), tostring(yEnd), tostring(nBots),
  }
  if yStart then args[#args + 1] = tostring(yStart) end
  args[#args + 1] = mode
  print(("Sending: %s"):format(table.concat(args, " ")))
  handleCommand(args)
  pauseSimple()
end

local function simpleConnectMenu()
  print("Connect to a device:")
  print("  1) Pick from live turtles")
  print("  2) Scan mesh (SSH hosts)")
  print("  3) Parent Center")
  print("  4) Type id or name")
  print("  0) Back")
  local c = askNumber("Pick: ")
  if c == 1 then
    local row = simplePickBot(nil, "Connect to:")
    if row then handleCommand({ "connect", tostring(row.id) }) end
  elseif c == 2 then
    local peers = titan.sshListPeers(2.0)
    local list = {}
    for _, p in ipairs(peers or {}) do
      list[#list + 1] = { id = p.id, b = { name = p.name or p.label, botType = p.kind, state = "ssh", x = p.x, y = p.y, z = p.z, seen = now() } }
    end
    local row = pickFromList("SSH hosts:", list, function(r)
      return ("#%d %s [%s]"):format(r.id, tostring(r.b.name or "?"), tostring(r.b.botType or "?"))
    end)
    if row then handleCommand({ "connect", tostring(row.id) }) end
  elseif c == 3 then
    handleCommand({ "dc" })
  elseif c == 4 then
    local ref = askLine("Id or name: ")
    if ref ~= "" then handleCommand({ "connect", ref }) end
  end
end

local function simpleStatusBoard()
  if titan.sshIsAuthed and titan.sshIsAuthed() then
    printBots(nil)
    local np = 0
    for _, w in pairs(pending) do if ago(w.seen) < 30 then np = np + 1 end end
    if np > 0 then print(("\n%d turtle(s) awaiting deploy"):format(np)) end
    pauseSimple()
    return
  end
  -- Full-screen MAIN boards (pretty on advanced pocket).
  liveView("stats")
end

local function simpleLiveMenu()
  print("Live boards (MAIN monitor stats)")
  print("  1) Local network")
  print("  2) Global mesh")
  print("  3) Stats")
  print("  4) GPS")
  print("  5) Bots")
  print("  6) Quarry progress")
  print("  0) Back")
  local n = askNumber("Pick: ")
  if n == 1 then liveView("local")
  elseif n == 2 then liveView("global")
  elseif n == 3 then liveView("stats")
  elseif n == 4 then liveView("gps")
  elseif n == 5 then liveView("bots")
  elseif n == 6 then liveView("quarry")
  end
end

local function simpleLinkMenu()
  if not requireAuth() then pauseSimple(); return end
  print("Network link")
  print("  1) Show topology")
  print("  2) Auto-link (peer routers, modems→nearest)")
  print("  3) Peer two routers (enter ids)")
  print("  4) Attach modem to router (enter ids)")
  print("  0) Back")
  local n = askNumber("Pick: ")
  if n == 1 then
    handleCommand({ "link" }); pauseSimple()
  elseif n == 2 then
    handleCommand({ "link", "auto" }); pauseSimple()
  elseif n == 3 then
    local a = askNumber("Router A id: ")
    local b = askNumber("Router B id: ")
    if a and b then handleCommand({ "link", "peer", tostring(a), tostring(b) }) end
    pauseSimple()
  elseif n == 4 then
    local m = askNumber("Modem id: ")
    local r = askNumber("Home router id: ")
    if m and r then handleCommand({ "link", "modem", tostring(m), tostring(r) }) end
    pauseSimple()
  end
end

-- Phone-style app catalog (id → action). Colors used when term.isColor().
local PHONE_APPS = {
  { id = "stats",    name = "Stats",    sub = "network",  bg = colors.blue },
  { id = "miners",   name = "Miners",   sub = "turtles",  bg = colors.brown },
  { id = "loaders",  name = "Loaders",  sub = "escorts",  bg = colors.orange },
  { id = "sites",    name = "Sites",    sub = "markers",  bg = colors.purple },
  { id = "pending",  name = "Pending",  sub = "deploy",   bg = colors.red },
  { id = "deploy",   name = "Deploy",   sub = "wizard",   bg = colors.magenta },
  { id = "flatten",  name = "Flatten",  sub = "wizard",   bg = colors.green },
  { id = "connect",  name = "Connect",  sub = "SSH",      bg = colors.cyan },
  { id = "center",   name = "Center",   sub = "parent",   bg = colors.lightBlue },
  { id = "link",     name = "Link",     sub = "mesh",     bg = colors.white },
  { id = "park",     name = "Park",     sub = "turtle",   bg = colors.gray },
  { id = "stop",     name = "Stop",     sub = "turtle",   bg = colors.red },
  { id = "continue", name = "Resume",   sub = "mining",   bg = colors.lime },
  { id = "boards",   name = "Boards",   sub = "live",     bg = colors.yellow },
  { id = "quarry",   name = "Quarry",   sub = "offline",  bg = colors.green },
  { id = "advanced", name = "Terminal", sub = "commands", bg = colors.lightGray },
  { id = "lock",     name = "Lock",     sub = "screen",   bg = colors.black },
}

local PHONE_PAGE = 10  -- apps per home page

local function runPhoneApp(id)
  if id == "stats" then
    simpleStatusBoard()
  elseif id == "miners" then
    printBots("miner"); pauseSimple()
  elseif id == "loaders" then
    printBots("loader"); pauseSimple()
  elseif id == "sites" then
    printBots("marker"); pauseSimple()
  elseif id == "pending" then
    handleCommand({ "pending" }); pauseSimple()
  elseif id == "deploy" then
    simpleDeployWizard()
  elseif id == "flatten" then
    simpleFlattenWizard()
  elseif id == "connect" then
    simpleConnectMenu()
  elseif id == "center" then
    handleCommand({ "dc" })
  elseif id == "link" then
    simpleLinkMenu()
  elseif id == "park" then
    simpleBotAction("park", nil)
  elseif id == "stop" then
    simpleBotAction("stop", nil)
  elseif id == "continue" then
    simpleBotAction("continue", "miner")
  elseif id == "boards" then
    if titan.sshIsAuthed and titan.sshIsAuthed() then
      print("Live view is local-only.")
      pauseSimple()
    else
      simpleLiveMenu()
    end
  elseif id == "quarry" then
    if titan.sshIsAuthed and titan.sshIsAuthed() then
      handleCommand({ "quarry" }); pauseSimple()
    else
      liveView("quarry")
    end
  elseif id == "advanced" then
    cfg.mode = "advanced"
    saveAdminCfg()
    return "switch_advanced"
  elseif id == "lock" then
    unlocked = false
    promptUnlockAtStart()
  end
  return nil
end

local function drawPhoneHome(page, pages, tiles)
  local w, h = term.getSize()
  local color = termIsColor()
  local out = term
  local bg = colors.black
  if out.setBackgroundColor then out.setBackgroundColor(bg) end
  out.clear()

  -- Status bar
  local barBg = color and colors.gray or colors.black
  local barFg = colors.white
  guiFill(out, 1, 1, w, 1, barBg, barFg)
  local title = "Titan"
  local clock = textutils.formatTime(os.time(), true)
  guiText(out, 2, 1, title, barFg, barBg)
  guiText(out, math.max(2, w - #clock), 1, clock, colors.lightGray, barBg)

  local label = os.getComputerLabel() or ("#" .. os.getComputerID())
  guiText(out, 2, 2, label:sub(1, w - 2), colors.lightGray, bg)

  -- App grid (2 columns)
  local cols = (w >= 30) and 3 or 2
  local gap = 1
  local tileW = math.floor((w - 2 - gap * (cols - 1)) / cols)
  local tileH = 3
  local startY = 4
  local maxRows = math.max(1, math.floor((h - 6) / (tileH + 0)))
  -- Force layout to fit PAGE apps: prefer 5 rows x 2 cols
  if cols == 2 then maxRows = math.min(maxRows, 5) end

  tiles = tiles or {}
  for i, app in ipairs(tiles) do
    local idx = i - 1
    local col = (idx % cols)
    local row = math.floor(idx / cols)
    local x = 2 + col * (tileW + gap)
    local y = startY + row * tileH
    if y + tileH - 1 >= h - 2 then break end
    local abg = color and (app.bg or colors.blue) or colors.gray
    local afg = colors.white
    if abg == colors.yellow or abg == colors.lime or abg == colors.white then
      afg = colors.black
    end
    if abg == colors.black then
      abg = color and colors.gray or colors.black
    end
    guiFill(out, x, y, tileW, tileH - 1, abg, afg)
    local num = tostring(i % 10)
    if i == 10 then num = "0" end
    guiText(out, x + 1, y, num .. " " .. tostring(app.name):sub(1, tileW - 3), afg, abg)
    if tileH >= 3 then
      guiText(out, x + 1, y + 1, tostring(app.sub or ""):sub(1, tileW - 2),
        color and colors.lightGray or afg, abg)
    end
    app._x, app._y, app._w, app._h = x, y, tileW, tileH - 1
  end

  -- Page dots + dock
  local dockY = h
  local pageTxt = ("<%d/%d>"):format(page, pages)
  guiFill(out, 1, dockY, w, 1, barBg, barFg)
  guiText(out, 2, dockY, pageTxt, colors.lightGray, barBg)
  local dock = "< > page  E exit"
  guiText(out, math.max(2, w - #dock), dockY, dock, colors.white, barBg)
end

local function phoneHitApp(tiles, x, y)
  for i, app in ipairs(tiles) do
    if app._x and x >= app._x and x < app._x + app._w
        and y >= app._y and y < app._y + app._h then
      return app, i
    end
  end
  return nil
end

local function simpleMenuLoop()
  local page = 1
  while cfg.mode == "simple" do
    local pages = math.max(1, math.ceil(#PHONE_APPS / PHONE_PAGE))
    if page > pages then page = pages end
    if page < 1 then page = 1 end
    local i0 = (page - 1) * PHONE_PAGE + 1
    local tiles = {}
    for i = i0, math.min(#PHONE_APPS, i0 + PHONE_PAGE - 1) do
      tiles[#tiles + 1] = PHONE_APPS[i]
    end
    drawPhoneHome(page, pages, tiles)

    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "e" or ch == "q" then
        return "exit"
      elseif ch == "n" or ch == "d" then
        page = (page % pages) + 1
      elseif ch == "p" or ch == "a" then
        page = page - 1
        if page < 1 then page = pages end
      elseif ch >= "1" and ch <= "9" then
        local n = tonumber(ch)
        if tiles[n] then
          local r = runPhoneApp(tiles[n].id)
          if r then return r end
        end
      elseif ch == "0" then
        if tiles[10] then
          local r = runPhoneApp(tiles[10].id)
          if r then return r end
        end
      end
    elseif ev == "key" then
      local K = keys
      if p1 == K.right or p1 == K.pagedown then
        page = (page % pages) + 1
      elseif p1 == K.left or p1 == K.pageup then
        page = page - 1
        if page < 1 then page = pages end
      elseif p1 == K.q then
        return "exit"
      end
    elseif ev == "mouse_click" then
      local x, y = p2, p3
      local app = phoneHitApp(tiles, x, y)
      if app then
        local r = runPhoneApp(app.id)
        if r then return r end
      end
    elseif ev == "terminate" then
      return "exit"
    end
  end
  return "switch_advanced"
end

local function advancedConsoleLoop()
  term.clear(); term.setCursorPos(1, 1)
  print("== Titan Admin — ADVANCED ==")
  print(os.getComputerLabel() or ("#" .. os.getComputerID()))
  print("Type help  (10 cmds/page, pick a page).  mode simple  for phone UI.")
  print("Quick:  live  |  quarry  |  connections  |  connect <name>  |  dc")
  while cfg.mode == "advanced" do
    write("admin> ")
    local a = {}
    for w in tostring(read()):gmatch("%S+") do a[#a + 1] = w end
    local r = handleCommand(a)
    if r == "exit" then return "exit"
    elseif r == "switch_simple" then return "switch_simple"
    elseif r == false then
      print("Unknown: " .. tostring(a[1] or "") .. " (type 'help')")
    end
  end
  return "switch_simple"
end

local function consoleLoop()
  while true do
    local r
    if cfg.mode == "simple" then
      r = simpleMenuLoop()
    else
      r = advancedConsoleLoop()
    end
    if r == "exit" then return end
    -- mode switches fall through and re-enter the other UI
  end
end

titan.setSshHandler(function(line)
  local a = {}
  for w in tostring(line):gmatch("%S+") do a[#a + 1] = w end
  -- SSH sessions always use advanced command parsing (no menus over SSH).
  local r = handleCommand(a)
  if r == "exit" then
    print("Over SSH: type `exit` to disconnect (admin keeps running).")
    return true
  end
  if r == "switch_simple" or r == "switch_advanced" then
    print("UI mode saved. On the pocket tablet, restart admin to see that UI.")
    return true
  end
  if r == false then
    print("Unknown: " .. tostring(a[1] or "") .. " (type 'help')")
  end
  return true
end)

-- Password FIRST (blocking), before any parallel loops touch the terminal.
promptUnlockAtStart()

-- Optional first-run mode pick (friendly chooser)
if not fs.exists(CFG_FILE) then
  local w, h = term.getSize()
  local color = termIsColor()
  local out = term
  if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
  out.clear()
  local accent = color and colors.cyan or colors.white
  guiFill(out, 1, 1, w, 2, accent, colors.black)
  guiText(out, 2, 1, " Choose your UI", colors.black, accent)
  guiText(out, 2, 4, "1  Phone home   (apps — recommended)", colors.white, colors.black)
  guiText(out, 2, 5, "   Tap tiles, swipe pages", colors.lightGray, colors.black)
  guiText(out, 2, 7, "2  Terminal     (commands + help pages)", colors.white, colors.black)
  guiText(out, 2, 8, "   Power users / SSH", colors.lightGray, colors.black)
  guiText(out, 2, h, "Pick 1 or 2  [default 1]", colors.gray, colors.black)
  write("")
  term.setCursorPos(2, h - 1)
  local pick = tonumber(read())
  cfg.mode = (pick == 2) and "advanced" or "simple"
  saveAdminCfg()
end

do
  local w, h = term.getSize()
  if term.setBackgroundColor then term.setBackgroundColor(colors.black) end
  term.clear()
  guiText(term, 2, math.max(1, math.floor(h / 2)),
    "Starting " .. cfg.mode .. "…", colors.lightGray, colors.black)
  sleep(0.35)
end

parallel.waitForAny(
  listenerLoop,
  quarryListenerLoop,
  function() titan.networkLoop("admin") end,
  consoleLoop)
print("Admin console closed.")
