--[[
  offline_site.lua  -  Quarry site board for multi-turtle offline miners
  Titan-Version: 1.0.6

  Place this computer to the LEFT of the storage chest (storage sits behind
  the turtles' origin). Attach a modem (wired to the turtles is fine, or
  wireless in range).

  OPTIONAL — turtles can dig and report straight to the admin tablet with no
  site board. When this board IS present it:
    * Auto-sets W×L×H from turtle mine/job data (or `setup` to lock manually)
    * Hands out non-overlapping Y bands (max 1/2 or 1/3 of height)
    * Collects BPC so every turtle knows safe travel distance
    * Stores each turtle's offline_miner_job.cfg under quarry_jobs/
    * Hands that job back if a turtle rejoins with no local job file
    * Relays a quarry_site snapshot to the admin tablet

  Commands:
    setup <W>x<L> <H> [half|third]   lock footprint manually
    auto                             unlock auto-learn from turtles
    fraction half|third              max Y band size per turtle
    claims                           list claimed / free Y bands
    clearclaims [all|done|stale|Y…]  release Y claims (see help)
    status | turtles | jobs | clear
    help | exit

  Turtle side: offline_miner with modem (area …); `join`/`mine` for Y bands.

  Run:  offline_site
]]

local PROTO = "titan_quarry"
local NET = "titan_net"
local CFG = "offline_site.cfg"
local JOB_DIR = "quarry_jobs"
local ONLINE_SECS = 45
-- How long without a ping before `clearclaims stale` / UI marks a turtle stale.
-- Claims are NEVER auto-released on this timer — deep digs can go quiet for a long time.
local STALE_CLAIM_SECS = ONLINE_SECS * 4

local titan = nil
if fs.exists("lib/titan.lua") then
  local ok, t = pcall(dofile, "lib/titan.lua")
  if ok then titan = t end
end

local cfg = {
  W = 0, L = 0, H = 0,   -- 0 = waiting to learn from turtles
  fraction = 0.5,        -- half of height per claim (use 1/3 via `fraction third`)
  manual = false,        -- true after `setup` (still expands if turtles report larger)
  label = nil,
}

local turtles = {}  -- [id] = { name, y0, y1, dug, idx, total, bpc, fuel, seen, status, moves, coal, job }
local completedBands = {}  -- list of { y0, y1 } finished with no active owner

--------------------------------------------------------------------------------
local function now() return os.epoch("utc") end
local function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end

local function turtleJobPath(id)
  return JOB_DIR .. "/" .. tostring(id) .. "_offline_miner_job.cfg"
end

local function jobSummaryShort(j)
  if type(j) ~= "table" then return "(none)" end
  if j.y0 ~= nil and j.y1 ~= nil then
    return ("area Y%d-%d step %d/%d [%s]"):format(
      j.y0, j.y1, tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
  end
  return ("%s step %d/%d [%s]"):format(
    tostring(j.type or "?"), tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
end

local function persistTurtleJob(id, job)
  if not fs.exists(JOB_DIR) then fs.makeDir(JOB_DIR) end
  local path = turtleJobPath(id)
  if type(job) ~= "table" then
    if fs.exists(path) then pcall(fs.delete, path) end
    return
  end
  local f = fs.open(path, "w")
  if not f then return end
  f.write(textutils.serialize(job))
  f.close()
end

local function loadStoredJob(id)
  local t = turtles[id]
  if t and type(t.job) == "table" and t.job.type and t.job.status ~= "done" then
    return t.job
  end
  local path = turtleJobPath(id)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" and d.type and d.status ~= "done" then
    if t then t.job = d; turtles[id] = t end
    return d
  end
  return nil
end

local function jobReplyFor(id)
  local job = loadStoredJob(id)
  local t = turtles[id] or {}
  return {
    type = "quarry_job_reply",
    ok = job ~= nil,
    job = job,
    jobFile = job and turtleJobPath(id) or nil,
    y0 = t.y0, y1 = t.y1,
    W = cfg.W, L = cfg.L, H = cfg.H,
    maxTravel = maxTravel(), minBpc = minBpc(),
  }
end

local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" then
    for k, v in pairs(d) do cfg[k] = v end
  end
  cfg.fraction = tonumber(cfg.fraction) or 0.5
  if cfg.fraction ~= (1 / 3) and cfg.fraction ~= (1 / 2) then
    if cfg.fraction < 0.4 then cfg.fraction = 1 / 3 else cfg.fraction = 0.5 end
  end
  cfg.manual = cfg.manual == true
  cfg.W = tonumber(cfg.W) or 0
  cfg.L = tonumber(cfg.L) or 0
  cfg.H = tonumber(cfg.H) or 0
  completedBands = {}
  if type(cfg.completedBands) == "table" then
    for _, b in ipairs(cfg.completedBands) do
      local y0, y1 = tonumber(b.y0), tonumber(b.y1)
      if y0 and y1 then
        completedBands[#completedBands + 1] = { y0 = y0, y1 = y1 }
      end
    end
  end
end

local function saveCfg()
  cfg.completedBands = completedBands
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize(cfg))
  f.close()
end

local function overlaps(a0, a1, b0, b1)
  return not (a1 < b0 or a0 > b1)
end

-- Grow (or initially set) footprint from a turtle's mine/job report.
local function learnSiteFromMsg(msg)
  if type(msg) ~= "table" then return false end
  local j = msg.job
  local W = tonumber(msg.W)
  local L = tonumber(msg.L)
  local H = tonumber(msg.H)
  if j then
    W = W or tonumber(j.W)
    L = L or tonumber(j.L) or tonumber(j.D)
    H = H or tonumber(j.stopY) or tonumber(j.H)
    if j.y1 ~= nil then
      H = math.max(H or 0, (tonumber(j.y1) or 0) + 1)
    end
  end
  W = math.floor(tonumber(W) or 0)
  L = math.floor(tonumber(L) or 0)
  H = math.floor(tonumber(H) or 0)
  if W < 1 or L < 1 or H < 1 then return false end
  local nW = math.max(tonumber(cfg.W) or 0, W)
  local nL = math.max(tonumber(cfg.L) or 0, L)
  local nH = math.max(tonumber(cfg.H) or 0, H)
  if nW == cfg.W and nL == cfg.L and nH == cfg.H then return false end
  cfg.W, cfg.L, cfg.H = nW, nL, nH
  saveCfg()
  local how = cfg.manual and "expand" or "auto"
  print(("[%s] site %dx%d × %dY from turtle mine data"):format(how, nW, nL, nH))
  return true
end

local function openModem()
  if titan and titan.openModem then
    titan.openModem()
    return true
  end
  local any = false
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      any = true
    end
  end
  return any
end

local function maxClaimLayers()
  local H = math.max(1, tonumber(cfg.H) or 1)
  return math.max(1, math.ceil(H * (tonumber(cfg.fraction) or 0.5)))
end

local function fractionLabel()
  local f = tonumber(cfg.fraction) or 0.5
  if math.abs(f - (1 / 3)) < 0.02 then return "third" end
  return "half"
end

-- Manual only (`clearclaims stale`) — never called while assigning bands.
local function releaseStaleClaims()
  local n = 0
  for id, t in pairs(turtles) do
    if t.y0 and t.y1 and t.status ~= "done" and ago(t.seen) >= STALE_CLAIM_SECS then
      print(("[stale] #%d released Y %d..%d (no ping %ss)"):format(
        id, t.y0, t.y1, tostring(ago(t.seen))))
      t.y0, t.y1 = nil, nil
      t.status = "stale"
      turtles[id] = t
      n = n + 1
    end
  end
  return n
end

-- Occupied Y layers (any active turtle claim + completed bands). No ping timeout.
local function occupiedLayers()
  local occ = {}
  local H = math.max(0, tonumber(cfg.H) or 0)
  for y = 0, H - 1 do occ[y] = false end
  for _, t in pairs(turtles) do
    if t.y0 and t.y1 and t.status ~= "done" then
      for y = t.y0, t.y1 do
        if occ[y] ~= nil then occ[y] = true end
      end
    end
  end
  for _, b in ipairs(completedBands) do
    for y = b.y0, b.y1 do
      if occ[y] ~= nil then occ[y] = true end
    end
  end
  return occ
end

local function listClaimEntries()
  local entries = {}
  for id, t in pairs(turtles) do
    if t.y0 and t.y1 and t.status ~= "done" then
      entries[#entries + 1] = {
        kind = "active",
        id = id,
        name = t.name,
        y0 = t.y0, y1 = t.y1,
        stale = ago(t.seen) >= STALE_CLAIM_SECS,
        status = t.status,
      }
    end
  end
  for _, b in ipairs(completedBands) do
    entries[#entries + 1] = { kind = "done", y0 = b.y0, y1 = b.y1 }
  end
  table.sort(entries, function(a, b)
    if a.y0 ~= b.y0 then return a.y0 < b.y0 end
    return (a.y1 or 0) < (b.y1 or 0)
  end)
  return entries
end

local function listFreeBands()
  local H = math.max(0, tonumber(cfg.H) or 0)
  local occ = occupiedLayers()
  local frees = {}
  local y = 0
  while y < H do
    if not occ[y] then
      local y0, y1 = y, y
      while y1 + 1 < H and not occ[y1 + 1] do
        y1 = y1 + 1
      end
      frees[#frees + 1] = { y0 = y0, y1 = y1 }
      y = y1 + 1
    else
      y = y + 1
    end
  end
  return frees
end

local function nextFreeBand()
  local H = math.max(1, tonumber(cfg.H) or 1)
  local maxN = maxClaimLayers()
  local occ = occupiedLayers()
  local y = 0
  while y < H do
    if not occ[y] then
      local y0 = y
      local y1 = y
      while y1 + 1 < H and not occ[y1 + 1] and (y1 - y0 + 1) < maxN do
        y1 = y1 + 1
      end
      return y0, y1
    end
    y = y + 1
  end
  return nil
end

-- Release active and/or completed claims. y0/y1 nil = entire height.
local function clearClaims(mode, y0, y1)
  mode = tostring(mode or "all"):lower()
  local H = math.max(0, tonumber(cfg.H) or 0)
  if y0 ~= nil then
    y0 = math.floor(tonumber(y0) or 0)
    y1 = math.floor(tonumber(y1) or y0)
    if y1 < y0 then y0, y1 = y1, y0 end
  else
    y0, y1 = 0, math.max(0, H - 1)
  end
  local released = 0

  if mode == "all" or mode == "active" or mode == "y" or mode == "turtle" then
    for id, t in pairs(turtles) do
      if t.y0 and t.y1 and overlaps(t.y0, t.y1, y0, y1) then
        print(("[unclaim] #%d Y %d..%d"):format(id, t.y0, t.y1))
        t.y0, t.y1 = nil, nil
        if t.status == "assigned" or t.status == "mining" then t.status = "idle" end
        turtles[id] = t
        released = released + 1
      end
    end
  end

  if mode == "all" or mode == "done" or mode == "y" then
    local keep = {}
    for _, b in ipairs(completedBands) do
      if overlaps(b.y0, b.y1, y0, y1) then
        print(("[unclaim] done Y %d..%d"):format(b.y0, b.y1))
        released = released + 1
      else
        keep[#keep + 1] = b
      end
    end
    completedBands = keep
  end

  if mode == "stale" then
    released = releaseStaleClaims()
  end

  saveCfg()
  return released
end

local function clearTurtleClaim(id)
  id = tonumber(id)
  if not id or not turtles[id] then return 0 end
  local t = turtles[id]
  if not t.y0 then return 0 end
  print(("[unclaim] #%d Y %d..%d"):format(id, t.y0, t.y1))
  t.y0, t.y1 = nil, nil
  t.status = "idle"
  turtles[id] = t
  saveCfg()
  return 1
end

local function minBpc()
  local best = nil
  for _, t in pairs(turtles) do
    local b = tonumber(t.bpc)
    if b and b > 0 and ago(t.seen) < ONLINE_SECS * 2 then
      if not best or b < best then best = b end
    end
  end
  return best or 48  -- conservative default until turtles report
end

local function maxTravel()
  -- Round-trip budget from worst BPC × ~32 coal, keep 40% margin.
  local bpc = minBpc()
  return math.max(16, math.floor(bpc * 32 * 0.4))
end

local function siteProgress()
  local W = tonumber(cfg.W) or 0
  local L = tonumber(cfg.L) or 0
  local H = tonumber(cfg.H) or 0
  local plane = math.max(1, W * L)
  local total = math.max(1, plane * H)
  local done = 0
  for _, b in ipairs(completedBands) do
    done = done + plane * (b.y1 - b.y0 + 1)
  end
  for _, t in pairs(turtles) do
    if t.y0 and t.y1 and t.status ~= "done" then
      local bandCells = plane * (t.y1 - t.y0 + 1)
      local tot = tonumber(t.total) or bandCells
      local idx = math.max(0, (tonumber(t.idx) or 1) - 1)
      if tot < 1 then tot = bandCells end
      done = done + math.min(bandCells, math.floor(bandCells * (idx / tot)))
    end
  end
  local pct = math.floor(math.min(100, (done / total) * 100) + 0.5)
  return pct, done, total
end

local function onlineCount()
  local n = 0
  for _, t in pairs(turtles) do
    if ago(t.seen) < ONLINE_SECS then n = n + 1 end
  end
  return n
end

local function snapshot()
  local pct, done, total = siteProgress()
  local list = {}
  for id, t in pairs(turtles) do
    list[#list + 1] = {
      id = id, name = t.name, y0 = t.y0, y1 = t.y1,
      dug = t.dug, idx = t.idx, total = t.total, bpc = t.bpc,
      fuel = t.fuel, status = t.status, age = ago(t.seen),
      job = t.job,
      jobSummary = t.job and jobSummaryShort(t.job) or nil,
      jobFile = t.job and turtleJobPath(id) or nil,
    }
  end
  table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
  return {
    type = "quarry_site",
    source = "site_board",
    siteId = os.getComputerID(),
    name = os.getComputerLabel() or ("Quarry-" .. os.getComputerID()),
    W = cfg.W, L = cfg.L, H = cfg.H,
    manual = cfg.manual == true,
    fraction = fractionLabel(),
    maxClaim = maxClaimLayers(),
    pct = pct, done = done, total = total,
    minBpc = minBpc(), maxTravel = maxTravel(),
    online = onlineCount(),
    turtles = list,
    claims = listClaimEntries(),
    free = listFreeBands(),
  }
end

local function broadcastStatus()
  local snap = snapshot()
  rednet.broadcast(snap, PROTO)
  rednet.broadcast(snap, NET)
  if titan and titan.ROUTER_PROTOCOL then
    rednet.broadcast(snap, titan.ROUTER_PROTOCOL)
  end
end

--------------------------------------------------------------------------------
-- Claims / turtle messages
--------------------------------------------------------------------------------
local function touchTurtle(id, msg)
  local t = turtles[id] or {}
  t.name = msg.name or msg.hostname or t.name or ("Turtle-" .. id)
  t.seen = now()
  if msg.bpc ~= nil then t.bpc = tonumber(msg.bpc) or t.bpc end
  if msg.fuel ~= nil then t.fuel = msg.fuel end
  if msg.dug ~= nil then t.dug = tonumber(msg.dug) or t.dug end
  if msg.idx ~= nil then t.idx = tonumber(msg.idx) or t.idx end
  if msg.total ~= nil then t.total = tonumber(msg.total) or t.total end
  if msg.moves ~= nil then t.moves = tonumber(msg.moves) or t.moves end
  if msg.coal ~= nil then t.coal = tonumber(msg.coal) or t.coal end
  if msg.status then t.status = msg.status end
  if msg.y0 ~= nil then t.y0 = tonumber(msg.y0) or t.y0 end
  if msg.y1 ~= nil then t.y1 = tonumber(msg.y1) or t.y1 end
  if msg.clearJob or msg.job == false then
    t.job = nil
    persistTurtleJob(id, nil)
  elseif type(msg.job) == "table" then
    t.job = msg.job
    if msg.job.idx ~= nil then t.idx = tonumber(msg.job.idx) or t.idx end
    if msg.job.total ~= nil then t.total = tonumber(msg.job.total) or t.total end
    if msg.job.dug ~= nil then t.dug = tonumber(msg.job.dug) or t.dug end
    if msg.job.y0 ~= nil then t.y0 = tonumber(msg.job.y0) or t.y0 end
    if msg.job.y1 ~= nil then t.y1 = tonumber(msg.job.y1) or t.y1 end
    if msg.job.status and not msg.status then t.status = msg.job.status end
    persistTurtleJob(id, msg.job)
  end
  learnSiteFromMsg(msg)
  turtles[id] = t
  return t
end

local function claimPayload(extra)
  local p = {
    type = "quarry_claim",
    W = cfg.W, L = cfg.L, H = cfg.H,
    maxTravel = maxTravel(), minBpc = minBpc(),
    claims = listClaimEntries(),
    free = listFreeBands(),
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do p[k] = v end
  end
  return p
end

local function assignClaim(id, msg)
  msg = msg or {}
  local t = touchTurtle(id, msg)
  if (tonumber(cfg.H) or 0) < 1 or (tonumber(cfg.W) or 0) < 1 then
    return claimPayload({
      ok = false,
      err = "site size unknown — setup WxL H or let a turtle area-dig first",
    })
  end
  -- Turtle finished a band and wants another: release old claim, don't resume it.
  if msg.nextBand or msg.forceNew then
    if t.y0 and t.y1 and t.status ~= "done" then
      completedBands[#completedBands + 1] = { y0 = t.y0, y1 = t.y1 }
      print(("[done] #%d released Y %d..%d for next claim"):format(id, t.y0, t.y1))
      saveCfg()
    end
    t.y0, t.y1 = nil, nil
    t.status = "idle"
    t.job = nil
    t.idx, t.total = nil, nil
    persistTurtleJob(id, nil)
    turtles[id] = t
  end
  -- Keep the turtle's band forever until done / clearclaims (deep digs go quiet).
  if t.y0 and t.y1 and t.status ~= "done" then
    return claimPayload({
      ok = true,
      y0 = t.y0, y1 = t.y1,
      resume = true,
    })
  end
  local y0, y1 = nextFreeBand()
  if not y0 then
    return claimPayload({ ok = false, err = "no free Y layers" })
  end
  t.y0, t.y1 = y0, y1
  t.status = "assigned"
  t.idx, t.total = 1, nil
  t.job = nil
  turtles[id] = t
  print(("[claim] #%d %s → Y %d..%d (%d layers)"):format(
    id, tostring(t.name), y0, y1, y1 - y0 + 1))
  return claimPayload({
    ok = true,
    y0 = y0, y1 = y1,
    resume = false,
  })
end

local function markDone(id, msg)
  local t = touchTurtle(id, msg or {})
  if t.y0 and t.y1 then
    completedBands[#completedBands + 1] = { y0 = t.y0, y1 = t.y1 }
    print(("[done] #%d finished Y %d..%d"):format(id, t.y0, t.y1))
    saveCfg()
  end
  t.status = "done"
  t.y0, t.y1 = nil, nil
  t.job = nil
  persistTurtleJob(id, nil)  -- clear so turtle can claim a fresh band
  turtles[id] = t
end

local function handleMsg(id, msg)
  if type(msg) ~= "table" or not msg.type then return end
  local t = tostring(msg.type)
  if t == "quarry_hello" or t == "quarry_join" or t == "quarry_turtle" then
    local first = turtles[id] == nil
    touchTurtle(id, msg)
    local row = turtles[id]
    local shouldWelcome = (t ~= "quarry_turtle")
        or first
        or ago(row.welcomedAt or 0) > 60
    if t ~= "quarry_turtle" or first then
      print(("[+] #%d %s  bpc=%s"):format(
        id, tostring(msg.name or "?"), tostring(msg.bpc or "?")))
    end
    if shouldWelcome then
      local stored = loadStoredJob(id)
      rednet.send(id, {
        type = "quarry_welcome",
        siteId = os.getComputerID(),
        name = os.getComputerLabel(),
        W = cfg.W, L = cfg.L, H = cfg.H,
        fraction = fractionLabel(),
        maxClaim = maxClaimLayers(),
        maxTravel = maxTravel(), minBpc = minBpc(),
        job = stored,
        y0 = row.y0, y1 = row.y1,
        hasJob = stored ~= nil,
      }, PROTO)
      row.welcomedAt = now()
      if stored then
        print(("[job] #%d can resume %s"):format(id, jobSummaryShort(stored)))
      end
    end
    if t ~= "quarry_turtle" then broadcastStatus() end
  elseif t == "quarry_claim_req" then
    local reply = assignClaim(id, msg)
    rednet.send(id, reply, PROTO)
    broadcastStatus()
  elseif t == "quarry_job_req" then
    touchTurtle(id, msg)
    local reply = jobReplyFor(id)
    rednet.send(id, reply, PROTO)
    if reply.ok then
      print(("[job] #%d requested → %s"):format(id, jobSummaryShort(reply.job)))
    else
      print(("[job] #%d requested — none stored"):format(id))
    end
  elseif t == "quarry_progress" or t == "quarry_job" then
    touchTurtle(id, msg)
    if t == "quarry_job" and type(msg.job) == "table" then
      print(("[job] #%d saved %s"):format(id, turtleJobPath(id)))
    end
    if msg.status == "done" or msg.finished then
      markDone(id, msg)
      broadcastStatus()
    elseif t == "quarry_job" then
      broadcastStatus()
    end
  elseif t == "quarry_done" then
    markDone(id, msg)
    broadcastStatus()
  elseif t == "quarry_status_req" or t == "quarry_turtle_req" then
    rednet.send(id, snapshot(), PROTO)
    rednet.broadcast(snapshot(), PROTO)
  end
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------
local function wrapMonitor()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local m = peripheral.wrap(name)
      if m then
        pcall(function() m.setTextScale(0.5) end)
        return m
      end
    end
  end
  return nil
end

local function drawBoard(out)
  out = out or term
  local w, h = out.getSize()
  if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
  if out.setTextColor then out.setTextColor(colors.white) end
  out.clear()
  local snap = snapshot()
  local color = out.isColor and out.isColor()

  local function line(y, txt, c)
    if y > h then return end
    out.setCursorPos(1, y)
    if out.setTextColor then out.setTextColor(c or colors.white) end
    if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
    out.write(tostring(txt):sub(1, w))
  end

  local title = ("QUARRY  %dx%d × %dY  [%s]"):format(
    snap.W, snap.L, snap.H, snap.fraction)
  if color then
    if out.setBackgroundColor then out.setBackgroundColor(colors.cyan) end
    if out.setTextColor then out.setTextColor(colors.black) end
    out.setCursorPos(1, 1)
    out.write((" %-"..w.."s"):format(title):sub(1, w))
    if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
  else
    line(1, title, colors.yellow)
  end

  line(2, ("Progress  %d%%   %d / %d cells"):format(snap.pct, snap.done, snap.total), colors.lime)
  -- bar
  if h >= 3 then
    local barW = math.max(4, w - 2)
    local fill = math.floor(barW * (snap.pct / 100))
    out.setCursorPos(1, 3)
    if color then
      out.setBackgroundColor(colors.gray)
      out.write(string.rep(" ", barW))
      out.setCursorPos(1, 3)
      out.setBackgroundColor(colors.lime)
      out.write(string.rep(" ", fill))
      out.setBackgroundColor(colors.black)
    else
      out.write("[" .. string.rep("#", fill) .. string.rep("-", barW - fill) .. "]")
    end
  end

  line(4, ("online:%d  minBPC:%.1f  maxTravel:%d"):format(
    snap.online, snap.minBpc, snap.maxTravel), colors.lightGray)
  line(5, ("claim max %d layers (%s of H)"):format(snap.maxClaim, snap.fraction), colors.lightGray)

  local y = 7
  line(6, "ID   Y-band     BPC   PROG     STATUS", colors.orange or colors.yellow)
  for _, t in ipairs(snap.turtles) do
    if y >= h then break end
    local band = (t.y0 and t.y1) and ("%d-%d"):format(t.y0, t.y1) or "-"
    local prog = "-"
    if t.total and t.total > 0 and t.idx then
      prog = ("%d%%"):format(math.floor(100 * math.min(1, (t.idx - 1) / t.total)))
    end
    local st = tostring(t.status or "?")
    if (t.age or 99) >= ONLINE_SECS then st = "stale" end
    local col = colors.white
    if st == "assigned" or st == "mining" then col = colors.lime
    elseif st == "done" then col = colors.lightGray
    elseif st == "stale" then col = colors.red end
    line(y, ("#%-3d %-10s %-5s %-8s %s"):format(
      t.id, band, tostring(t.bpc or "?"):sub(1, 5), prog, st), col)
    y = y + 1
  end
  if #snap.turtles == 0 and y < h then
    line(y, "(no turtles — run `join` on offline_miner)", colors.gray)
  end
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function printHelp()
  print("Quarry site board — place LEFT of the storage chest (optional).")
  print("  setup <W>x<L> <H> [half|third]   lock shared dig volume")
  print("  auto                             learn size from turtle mine data")
  print("  fraction half|third              max Y band per turtle")
  print("  claims                           show claimed + free Y bands")
  print("  clearclaims                      release ALL Y claims (active+done)")
  print("  clearclaims done                 clear finished bands only")
  print("  clearclaims stale                free bands from quiet turtles (manual)")
  print("  clearclaims Y <y0> [y1]          clear claims overlapping Y range")
  print("  clearclaims turtle <id>          release one turtle's claim")
  print("  status | turtles | jobs | clear | broadcast")
  print("  help | exit")
  print("")
  print("Turtles call mine/join → site assigns the next free Y band.")
  print("Job files: " .. JOB_DIR .. "/<id>_offline_miner_job.cfg")
end

local function printClaims()
  local entries = listClaimEntries()
  local frees = listFreeBands()
  if #entries == 0 then
    print("No Y claims.")
  else
    print("Claimed Y bands:")
    for _, e in ipairs(entries) do
      if e.kind == "done" then
        print(("  Y %d..%d  [done]"):format(e.y0, e.y1))
      else
        print(("  Y %d..%d  #%d %s%s"):format(
          e.y0, e.y1, e.id, tostring(e.name or "?"):sub(1, 12),
          e.stale and " (stale)" or ""))
      end
    end
  end
  if #frees == 0 then
    print("Free Y: (none)")
  else
    local parts = {}
    for _, f in ipairs(frees) do
      parts[#parts + 1] = ("%d..%d"):format(f.y0, f.y1)
    end
    print("Free Y: " .. table.concat(parts, ", "))
  end
end

local function handleCommand(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = (a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" or cmd == "?" then printHelp()
  elseif cmd == "status" then
    local s = snapshot()
    print(("Site #%d  %dx%d × %dY  %s  %d%%"):format(
      s.siteId, s.W, s.L, s.H, s.fraction, s.pct))
    print(("online=%d  minBPC=%.1f  maxTravel=%d  claimMax=%d"):format(
      s.online, s.minBpc, s.maxTravel, s.maxClaim))
  elseif cmd == "turtles" then
    local s = snapshot()
    if #s.turtles == 0 then print("(none)")
    else
      for _, t in ipairs(s.turtles) do
        print(("#%d %s  Y%s  bpc=%s  %s  %ss"):format(
          t.id, tostring(t.name):sub(1, 12),
          (t.y0 and ("%d-%d"):format(t.y0, t.y1)) or "-",
          tostring(t.bpc or "?"), tostring(t.status or "?"), tostring(t.age or "?")))
        if t.jobSummary then
          print("     job: " .. t.jobSummary)
        end
      end
    end
  elseif cmd == "jobs" then
    if not fs.exists(JOB_DIR) then
      print("(no " .. JOB_DIR .. " yet — turtles send offline_miner_job.cfg on join/mine)")
    else
      local files = fs.list(JOB_DIR)
      if #files == 0 then print("(empty)")
      else
        for _, name in ipairs(files) do
          local path = JOB_DIR .. "/" .. name
          local f = fs.open(path, "r")
          local raw = f and f.readAll() or ""
          if f then f.close() end
          local j = textutils.unserialize(raw)
          print(path .. "  " .. jobSummaryShort(j))
        end
      end
    end
    local s = snapshot()
    for _, t in ipairs(s.turtles) do
      if t.job then
        print(("#%d memory: %s"):format(t.id, t.jobSummary or "?"))
      end
    end
  elseif cmd == "claims" or cmd == "claim" then
    printClaims()
  elseif cmd == "clearclaims" or cmd == "unclaim" then
    local sub = tostring(a[2] or "all"):lower()
    local n = 0
    if sub == "" or sub == "all" then
      n = clearClaims("all")
      print(("Cleared all Y claims (%d released). Turtles can re-claim with mine."):format(n))
    elseif sub == "done" or sub == "completed" then
      n = clearClaims("done")
      print(("Cleared completed Y bands (%d)."):format(n))
    elseif sub == "stale" then
      n = clearClaims("stale")
      print(("Released stale turtle claims (%d)."):format(n))
    elseif sub == "active" then
      n = clearClaims("active")
      print(("Released active turtle claims (%d)."):format(n))
    elseif sub == "turtle" or sub == "id" then
      n = clearTurtleClaim(a[3] or a[2])
      if n < 1 then print("No claim for that turtle id.")
      else print("Released turtle claim.") end
    elseif sub == "y" or sub == "Y" or tonumber(sub) then
      local y0 = tonumber(sub == "y" and a[3] or sub)
      local y1 = tonumber(sub == "y" and a[4] or a[3]) or y0
      if not y0 then
        print("Usage: clearclaims Y <y0> [y1]")
      else
        n = clearClaims("y", y0, y1)
        print(("Cleared claims overlapping Y %d..%d (%d)."):format(y0, y1 or y0, n))
      end
    else
      print("Usage: clearclaims [all|done|stale|active|Y <y0> [y1]|turtle <id>]")
      return true
    end
    broadcastStatus()
    printClaims()
  elseif cmd == "clear" then
    turtles, completedBands = {}, {}
    if fs.exists(JOB_DIR) then
      for _, name in ipairs(fs.list(JOB_DIR)) do
        pcall(fs.delete, JOB_DIR .. "/" .. name)
      end
    end
    saveCfg()
    print("Cleared turtle registry / Y claims / quarry_jobs (footprint kept).")
    print("Tip: `clearclaims` frees Y bands without wiping job files.")
    broadcastStatus()
  elseif cmd == "auto" then
    cfg.manual = false
    saveCfg()
    print("Auto-learn ON — footprint grows from turtle mine data.")
  elseif cmd == "broadcast" or cmd == "push" then
    broadcastStatus()
    print("Status broadcast.")
  elseif cmd == "fraction" then
    local f = tostring(a[2] or ""):lower()
    if f == "half" or f == "1/2" or f == "2" then
      cfg.fraction = 0.5
    elseif f == "third" or f == "1/3" or f == "3" then
      cfg.fraction = 1 / 3
    else
      print("Usage: fraction half|third   (now " .. fractionLabel() .. ")")
      return true
    end
    saveCfg()
    print("Claim size: " .. fractionLabel() .. " (" .. maxClaimLayers() .. " layers max)")
  elseif cmd == "setup" then
    local raw = a[2]
    local W, L, H
    if raw and tostring(raw):find("x") then
      local p = {}
      for n in tostring(raw):gmatch("(%-?%d+)") do p[#p + 1] = tonumber(n) end
      W, L = p[1], p[2]
      H = tonumber(a[3])
      local fr = tostring(a[4] or a[3] or ""):lower()
      if fr == "half" or fr == "third" then
        if not tonumber(a[3]) then H = nil end
        cfg.fraction = (fr == "third") and (1 / 3) or 0.5
        if not H then H = tonumber(a[3]) end
      end
      if tostring(a[4] or ""):lower() == "half" then cfg.fraction = 0.5
      elseif tostring(a[4] or ""):lower() == "third" then cfg.fraction = 1 / 3 end
    else
      W, L, H = tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
      local fr = tostring(a[5] or ""):lower()
      if fr == "half" then cfg.fraction = 0.5
      elseif fr == "third" then cfg.fraction = 1 / 3 end
    end
    if not W or not L or not H then
      print("Usage: setup <W>x<L> <H> [half|third]")
      print("Example: setup 16x32 60 half")
      print("Or skip setup — turtles' area commands set the site automatically.")
    else
      cfg.W, cfg.L, cfg.H = W, L, H
      cfg.manual = true
      turtles, completedBands = {}, {}
      saveCfg()
      print(("Site locked: %dx%d × %dY  claim=%s (max %d layers)"):format(
        W, L, H, fractionLabel(), maxClaimLayers()))
      print("(`auto` to unlock learning from turtles again)")
      broadcastStatus()
    end
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    print("Unknown. Type help.")
  end
  return true
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------
if not openModem() then
  error("No modem. Attach a wireless or wired modem.", 0)
end

loadCfg()
os.setComputerLabel(os.getComputerLabel() or cfg.label or ("QuarrySite-" .. os.getComputerID()))
cfg.label = os.getComputerLabel()
saveCfg()

term.clear(); term.setCursorPos(1, 1)
print("== Quarry Site Board ==")
if (cfg.W or 0) < 1 then
  print("Footprint: waiting for turtle mine data (or `setup WxL H`)")
else
  print(("Footprint %dx%d × %dY  claim=%s  %s"):format(
    cfg.W, cfg.L, cfg.H, fractionLabel(),
    cfg.manual and "manual" or "auto"))
end
print("Place LEFT of storage. Relays jobs/progress to admin tablet.")
print("Type help.")
print("")

local function netLoop()
  while true do
    local id, msg, proto = rednet.receive(nil, 1)
    if id and type(msg) == "table" then
      if proto == PROTO or msg.type and tostring(msg.type):find("^quarry_", 1) then
        handleMsg(id, msg)
      end
    end
  end
end

local function announceLoop()
  while true do
    broadcastStatus()
    sleep(5)
  end
end

local function drawLoop()
  while true do
    local mon = wrapMonitor()
    if mon then drawBoard(mon) else drawBoard(term) end
    sleep(1)
  end
end

local function consoleLoop()
  while true do
    write("site> ")
    local line = read()
    if handleCommand(line) == "exit" then return end
  end
end

local tasks = { netLoop, announceLoop, consoleLoop }
if wrapMonitor() then tasks[#tasks + 1] = drawLoop end
if titan and titan.networkLoop then
  tasks[#tasks + 1] = function() titan.networkLoop("quarry_site") end
end

parallel.waitForAny(table.unpack(tasks))
print("Site board stopped.")
