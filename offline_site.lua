--[[
  offline_site.lua  -  Quarry site board for multi-turtle offline miners
  Titan-Version: 1.2.3

  Place this computer to the LEFT of the storage chest (storage sits behind
  the turtles' origin). Attach a modem (wired to the turtles is fine, or
  wireless in range).

  OPTIONAL — turtles can dig and report straight to the admin tablet with no
    site board. When this board IS present it:
    * Auto-sets W×L×H from turtle mine/job data (or `setup` to lock manually)
    * Dig mode `column` (default): hands out non-overlapping 2×2 XZ columns
      (full height). Dig mode `layer`: Y bands across the footprint
    * Site pattern + unique bands are authoritative (turtles must obey)
    * On join: rebands the whole fleet (split remaining work), calls all
      turtles home, turn-taking origin reset (depot), then continueIdx digs
    * Collects BPC so every turtle knows safe travel distance
    * Stores each turtle's offline_miner_job.cfg under quarry_jobs/
    * Hands that job back if a turtle rejoins with no local job file
    * Relays a quarry_site snapshot to the admin tablet
    * where <id> — send turtle world/relative pose to admin distance screen

  Commands:
    setup <W>x<L> <H> [half|third] [column|layer]
    origin <x> <y> <z> [n|s|e|w|0-3]   GPS of quarry 0,0,0 + facing into mine
    where <id>                       ping admin tablet with that turtle's coords
    auto                             unlock auto-learn from turtles
    pattern column|layer             claim style for mine/ (clears + tells fleet)
    fraction half|third              max Y band size hint (layer mode)
    reband                           force fleet reband + origin reset turns
    claims                           list claimed / free regions
    clearclaims [all|done|stale|Y…]  release claims (see help)
    clear | clearminers              wipe site miner data + tell turtles forget jobs
    status | turtles | jobs
    help | exit

  Turtle side: offline_miner online mode; modem → join → reband → mine.

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
  fraction = 0.5,        -- half of height per claim (layer mode; use 1/3 via `fraction third`)
  pattern = "column",    -- "column" = 2×2 XZ shafts; "layer" = Y bands
  manual = false,        -- true after `setup` (still expands if turtles report larger)
  label = nil,
  -- World GPS of quarry origin 0,0,0 and which way +Z (into mine) faces.
  -- facing: 0=+Z/S, 1=+X/E, 2=-Z/N, 3=-X/W (same as turtle facing).
  originX = nil, originY = nil, originZ = nil, originFacing = 0,
}

local turtles = {}  -- [id] = { name, y0, y1, x0, x1, z0, z1, dug, idx, total, continueIdx, bpc, fuel, seen, status, pos*, job }
local completedBands = {}  -- list of { y0, y1 } (layer) or { x0,x1,z0,z1,y0,y1 } (column)

-- Fleet reband / origin reset turn queue.
local rebandState = {
  epoch = 0,
  active = false,
  turnOrder = {},       -- computer ids, ascending
  homeReady = {},       -- [id] = true
  resetDone = {},       -- [id] = true
  currentTurn = nil,
  parkOffset = {},      -- [id] = corridor slot (down then right)
  reason = nil,
}

local function normalizePattern(p)
  p = tostring(p or ""):lower()
  if p == "col" or p == "columns" or p == "shaft" then p = "column" end
  if p == "layers" or p == "slice" or p == "flat" or p == "band" then p = "layer" end
  if p == "column" or p == "layer" then return p end
  return nil
end

local function sitePattern()
  return normalizePattern(cfg.pattern) or "column"
end

--------------------------------------------------------------------------------
local function now() return os.epoch("utc") end
local function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end

local function turtleJobPath(id)
  return JOB_DIR .. "/" .. tostring(id) .. "_offline_miner_job.cfg"
end

local function jobSummaryShort(j)
  if type(j) ~= "table" then return "(none)" end
  if j.x0 ~= nil and j.z0 ~= nil then
    return ("col X%d-%d Z%d-%d step %d/%d [%s]"):format(
      tonumber(j.x0) or 0, tonumber(j.x1) or 0,
      tonumber(j.z0) or 0, tonumber(j.z1) or 0,
      tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
  end
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
  cfg.pattern = normalizePattern(cfg.pattern) or "column"
  cfg.manual = cfg.manual == true
  cfg.W = tonumber(cfg.W) or 0
  cfg.L = tonumber(cfg.L) or 0
  cfg.H = tonumber(cfg.H) or 0
  cfg.originX = tonumber(cfg.originX)
  cfg.originY = tonumber(cfg.originY)
  cfg.originZ = tonumber(cfg.originZ)
  cfg.originFacing = math.floor(tonumber(cfg.originFacing) or 0) % 4
  completedBands = {}
  if type(cfg.completedBands) == "table" then
    for _, b in ipairs(cfg.completedBands) do
      local y0, y1 = tonumber(b.y0), tonumber(b.y1)
      local x0, x1 = tonumber(b.x0), tonumber(b.x1)
      local z0, z1 = tonumber(b.z0), tonumber(b.z1)
      if x0 and z0 then
        completedBands[#completedBands + 1] = {
          x0 = x0, x1 = x1 or x0, z0 = z0, z1 = z1 or z0,
          y0 = y0 or 0, y1 = y1 or math.max(0, (tonumber(cfg.H) or 1) - 1),
          pattern = "column",
        }
      elseif y0 and y1 then
        completedBands[#completedBands + 1] = { y0 = y0, y1 = y1, pattern = "layer" }
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

local function turtleHasClaim(t)
  if not t then return false end
  if t.x0 ~= nil and t.z0 ~= nil then return true end
  return t.y0 ~= nil and t.y1 ~= nil
end

-- Claim shape must match site dig mode (column = XZ, layer = Y-only).
local function claimMatchesPattern(t, pat)
  if not turtleHasClaim(t) then return false end
  pat = normalizePattern(pat) or sitePattern()
  if pat == "column" then
    return t.x0 ~= nil and t.z0 ~= nil
  end
  return t.x0 == nil and t.y0 ~= nil and t.y1 ~= nil
end

local function clearTurtleCoords(t)
  t.y0, t.y1 = nil, nil
  t.x0, t.x1, t.z0, t.z1 = nil, nil, nil, nil
  t.adminLock = false
  t.assignId = nil
end

-- Tell every turtle to drop local job + pendingAssign (site is source of truth).
local function broadcastFleetClear(reason)
  local msg = {
    type = "quarry_fleet_clear",
    siteId = os.getComputerID(),
    reason = tostring(reason or "clear"),
    pattern = sitePattern(),
    W = cfg.W, L = cfg.L, H = cfg.H,
    clearJobs = true,
    clearAssign = true,
  }
  rednet.broadcast(msg, PROTO)
  rednet.broadcast(msg, NET)
  for id in pairs(turtles) do
    rednet.send(id, msg, PROTO)
  end
  print(("[fleet] clear broadcast (%s) — turtles forget local jobs/assigns"):format(
    tostring(reason or "clear")))
end

local function wipeMinerData(reason)
  turtles, completedBands = {}, {}
  rebandState.active = false
  rebandState.currentTurn = nil
  rebandState.homeReady = {}
  rebandState.resetDone = {}
  rebandState.turnOrder = {}
  rebandState.parkOffset = {}
  if fs.exists(JOB_DIR) then
    for _, name in ipairs(fs.list(JOB_DIR)) do
      pcall(fs.delete, JOB_DIR .. "/" .. name)
    end
  end
  saveCfg()
  broadcastFleetClear(reason or "clear")
end

local function claimLabel(t)
  if not t then return "?" end
  if t.x0 ~= nil then
    return ("X%d-%d Z%d-%d"):format(
      tonumber(t.x0) or 0, tonumber(t.x1) or 0,
      tonumber(t.z0) or 0, tonumber(t.z1) or 0)
  end
  if t.y0 ~= nil then
    return ("Y%d-%d"):format(tonumber(t.y0) or 0, tonumber(t.y1) or 0)
  end
  return "-"
end

-- Manual only (`clearclaims stale`) — never called while assigning bands.
local function releaseStaleClaims()
  local n = 0
  for id, t in pairs(turtles) do
    if turtleHasClaim(t) and t.status ~= "done" and ago(t.seen) >= STALE_CLAIM_SECS then
      print(("[stale] #%d released %s (no ping %ss)"):format(
        id, claimLabel(t), tostring(ago(t.seen))))
      clearTurtleCoords(t)
      t.status = "stale"
      turtles[id] = t
      n = n + 1
    end
  end
  return n
end

-- Occupied Y layers (layer mode). No ping timeout.
local function occupiedLayers()
  local occ = {}
  local H = math.max(0, tonumber(cfg.H) or 0)
  for y = 0, H - 1 do occ[y] = false end
  for _, t in pairs(turtles) do
    if t.y0 and t.y1 and t.status ~= "done" and t.x0 == nil then
      for y = t.y0, t.y1 do
        if occ[y] ~= nil then occ[y] = true end
      end
    end
  end
  for _, b in ipairs(completedBands) do
    if b.x0 == nil and b.y0 and b.y1 then
      for y = b.y0, b.y1 do
        if occ[y] ~= nil then occ[y] = true end
      end
    end
  end
  return occ
end

-- Occupied XZ cells for column mode (2×2 claims).
local function occupiedColumns()
  local W = math.max(0, tonumber(cfg.W) or 0)
  local L = math.max(0, tonumber(cfg.L) or 0)
  local occ = {}
  for z = 0, L - 1 do
    occ[z] = {}
    for x = 0, W - 1 do occ[z][x] = false end
  end
  local function mark(x0, x1, z0, z1)
    if not x0 or not z0 then return end
    x1 = x1 or x0
    z1 = z1 or z0
    for z = z0, z1 do
      for x = x0, x1 do
        if occ[z] and occ[z][x] ~= nil then occ[z][x] = true end
      end
    end
  end
  for _, t in pairs(turtles) do
    if t.status ~= "done" then mark(t.x0, t.x1, t.z0, t.z1) end
  end
  for _, b in ipairs(completedBands) do
    mark(b.x0, b.x1, b.z0, b.z1)
  end
  return occ
end

local function xzOverlap(ax0, ax1, az0, az1, bx0, bx1, bz0, bz1)
  if ax0 == nil or bx0 == nil then return false end
  return overlaps(ax0, ax1, bx0, bx1) and overlaps(az0, az1, bz0, bz1)
end

local function listClaimEntries()
  local entries = {}
  local pat = sitePattern()
  for id, t in pairs(turtles) do
    if turtleHasClaim(t) and t.status ~= "done" then
      entries[#entries + 1] = {
        kind = "active",
        id = id,
        name = t.name,
        pattern = (t.x0 ~= nil) and "column" or "layer",
        y0 = t.y0, y1 = t.y1,
        x0 = t.x0, x1 = t.x1, z0 = t.z0, z1 = t.z1,
        stale = ago(t.seen) >= STALE_CLAIM_SECS,
        status = t.status,
      }
    end
  end
  for _, b in ipairs(completedBands) do
    entries[#entries + 1] = {
      kind = "done",
      pattern = b.pattern or ((b.x0 ~= nil) and "column" or "layer"),
      y0 = b.y0, y1 = b.y1,
      x0 = b.x0, x1 = b.x1, z0 = b.z0, z1 = b.z1,
    }
  end
  table.sort(entries, function(a, b)
    if (a.z0 or -1) ~= (b.z0 or -1) then return (a.z0 or -1) < (b.z0 or -1) end
    if (a.x0 or -1) ~= (b.x0 or -1) then return (a.x0 or -1) < (b.x0 or -1) end
    if (a.y0 or 0) ~= (b.y0 or 0) then return (a.y0 or 0) < (b.y0 or 0) end
    return (a.y1 or 0) < (b.y1 or 0)
  end)
  return entries
end

local function listFreeBands()
  if sitePattern() == "column" then
    local W = math.max(0, tonumber(cfg.W) or 0)
    local L = math.max(0, tonumber(cfg.L) or 0)
    local occ = occupiedColumns()
    local frees, n = {}, 0
    for z = 0, L - 1, 2 do
      for x = 0, W - 1, 2 do
        local free = true
        for zz = z, math.min(z + 1, L - 1) do
          for xx = x, math.min(x + 1, W - 1) do
            if occ[zz] and occ[zz][xx] then free = false end
          end
        end
        if free then
          n = n + 1
          if n <= 12 then
            frees[#frees + 1] = {
              x0 = x, x1 = math.min(x + 1, W - 1),
              z0 = z, z1 = math.min(z + 1, L - 1),
              y0 = 0, y1 = math.max(0, (tonumber(cfg.H) or 1) - 1),
            }
          end
        end
      end
    end
    return frees, n
  end
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

-- Next free 2×2 XZ patch (full height). Edge patches may be 1×2 / 2×1 / 1×1.
local function nextFreeColumn()
  local W = math.max(1, tonumber(cfg.W) or 1)
  local L = math.max(1, tonumber(cfg.L) or 1)
  local H = math.max(1, tonumber(cfg.H) or 1)
  local occ = occupiedColumns()
  for z = 0, L - 1, 2 do
    for x = 0, W - 1, 2 do
      local x1 = math.min(x + 1, W - 1)
      local z1 = math.min(z + 1, L - 1)
      local free = true
      for zz = z, z1 do
        for xx = x, x1 do
          if occ[zz] and occ[zz][xx] then free = false end
        end
      end
      if free then
        return x, x1, z, z1, 0, H - 1
      end
    end
  end
  return nil
end

-- Release active and/or completed claims. y0/y1 nil = entire height (layer filter).
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
      local hit = false
      if turtleHasClaim(t) then
        if mode == "all" or mode == "active" or mode == "turtle" then
          hit = true
        elseif t.y0 and t.y1 and overlaps(t.y0, t.y1, y0, y1) then
          hit = true
        end
      end
      if hit then
        print(("[unclaim] #%d %s"):format(id, claimLabel(t)))
        clearTurtleCoords(t)
        if t.status == "assigned" or t.status == "mining" then t.status = "idle" end
        turtles[id] = t
        released = released + 1
      end
    end
  end

  if mode == "all" or mode == "done" or mode == "y" then
    local keep = {}
    for _, b in ipairs(completedBands) do
      local hit = false
      if mode == "all" or mode == "done" then
        hit = true
      elseif b.y0 and b.y1 then
        hit = overlaps(b.y0, b.y1, y0, y1)
      end
      if hit then
        print(("[unclaim] done %s"):format(claimLabel(b)))
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
  if not turtleHasClaim(t) then return 0 end
  print(("[unclaim] #%d %s"):format(id, claimLabel(t)))
  clearTurtleCoords(t)
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

local function jobReplyFor(id)
  local job = loadStoredJob(id)
  local t = turtles[id] or {}
  return {
    type = "quarry_job_reply",
    ok = job ~= nil,
    job = job,
    jobFile = job and turtleJobPath(id) or nil,
    pattern = sitePattern(),
    y0 = t.y0, y1 = t.y1,
    x0 = t.x0, x1 = t.x1, z0 = t.z0, z1 = t.z1,
    W = cfg.W, L = cfg.L, H = cfg.H,
    maxTravel = maxTravel(), minBpc = minBpc(),
  }
end

local function siteProgress()
  local W = tonumber(cfg.W) or 0
  local L = tonumber(cfg.L) or 0
  local H = tonumber(cfg.H) or 0
  local plane = math.max(1, W * L)
  local total = math.max(1, plane * H)
  local done = 0
  if sitePattern() == "column" then
    for _, b in ipairs(completedBands) do
      if b.x0 ~= nil then
        local bw = (tonumber(b.x1) or b.x0) - b.x0 + 1
        local bl = (tonumber(b.z1) or b.z0) - b.z0 + 1
        local bh = (tonumber(b.y1) or (H - 1)) - (tonumber(b.y0) or 0) + 1
        done = done + math.max(0, bw * bl * bh)
      end
    end
    for _, t in pairs(turtles) do
      if t.x0 ~= nil and t.status ~= "done" then
        local bw = (tonumber(t.x1) or t.x0) - t.x0 + 1
        local bl = (tonumber(t.z1) or t.z0) - t.z0 + 1
        local bh = math.max(1, H)
        local bandCells = bw * bl * bh
        local tot = tonumber(t.total) or bandCells
        local idx = math.max(0, (tonumber(t.idx) or 1) - 1)
        if tot < 1 then tot = bandCells end
        done = done + math.min(bandCells, math.floor(bandCells * (idx / tot)))
      end
    end
  else
    for _, b in ipairs(completedBands) do
      if b.y0 and b.y1 and b.x0 == nil then
        done = done + plane * (b.y1 - b.y0 + 1)
      end
    end
    for _, t in pairs(turtles) do
      if t.y0 and t.y1 and t.status ~= "done" and t.x0 == nil then
        local bandCells = plane * (t.y1 - t.y0 + 1)
        local tot = tonumber(t.total) or bandCells
        local idx = math.max(0, (tonumber(t.idx) or 1) - 1)
        if tot < 1 then tot = bandCells end
        done = done + math.min(bandCells, math.floor(bandCells * (idx / tot)))
      end
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
      x0 = t.x0, x1 = t.x1, z0 = t.z0, z1 = t.z1,
      posX = t.posX, posY = t.posY, posZ = t.posZ,
      lastPosAt = t.lastPosAt, sos = t.sos,
      dug = t.dug, idx = t.idx, total = t.total,
      continueIdx = t.continueIdx or t.idx,
      bpc = t.bpc,
      fuel = t.fuel, status = t.status, age = ago(t.seen),
      job = t.job,
      jobSummary = t.job and jobSummaryShort(t.job) or nil,
      jobFile = t.job and turtleJobPath(id) or nil,
      pattern = (t.x0 ~= nil) and "column" or ((t.y0 ~= nil) and "layer" or sitePattern()),
    }
  end
  table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
  local freeList = listFreeBands()
  return {
    type = "quarry_site",
    source = "site_board",
    siteId = os.getComputerID(),
    name = os.getComputerLabel() or ("Quarry-" .. os.getComputerID()),
    W = cfg.W, L = cfg.L, H = cfg.H,
    manual = cfg.manual == true,
    pattern = sitePattern(),
    fraction = fractionLabel(),
    maxClaim = (sitePattern() == "column") and 4 or maxClaimLayers(),
    pct = pct, done = done, total = total,
    minBpc = minBpc(), maxTravel = maxTravel(),
    online = onlineCount(),
    turtles = list,
    claims = listClaimEntries(),
    free = freeList,
    rebandEpoch = rebandState.epoch,
    rebandActive = rebandState.active == true,
    rebandTurn = rebandState.currentTurn,
    originSet = (cfg.originX ~= nil and cfg.originY ~= nil and cfg.originZ ~= nil),
    originX = cfg.originX, originY = cfg.originY, originZ = cfg.originZ,
    originFacing = cfg.originFacing,
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

local function parseFacing(raw)
  if raw == nil or raw == "" then return 0 end
  local s = tostring(raw):lower()
  if s == "0" or s == "s" or s == "south" or s == "+z" or s == "z+" then return 0 end
  if s == "1" or s == "e" or s == "east" or s == "+x" or s == "x+" then return 1 end
  if s == "2" or s == "n" or s == "north" or s == "-z" or s == "z-" then return 2 end
  if s == "3" or s == "w" or s == "west" or s == "-x" or s == "x-" then return 3 end
  local n = tonumber(raw)
  if n then return math.floor(n) % 4 end
  return nil
end

local function facingLabel(f)
  f = math.floor(tonumber(f) or 0) % 4
  return ({ "south/+Z", "east/+X", "north/-Z", "west/-X" })[f + 1]
end

-- Quarry relative (+X right, +Y down, +Z forward) → world GPS.
local function quarryToWorld(qx, qy, qz)
  local ox, oy, oz = tonumber(cfg.originX), tonumber(cfg.originY), tonumber(cfg.originZ)
  if ox == nil or oy == nil or oz == nil then return nil end
  qx = tonumber(qx) or 0
  qy = tonumber(qy) or 0
  qz = tonumber(qz) or 0
  local f = math.floor(tonumber(cfg.originFacing) or 0) % 4
  -- forward (quarry +Z) and right (quarry +X) unit vectors in world XZ
  local fx, fz, rx, rz
  if f == 0 then fx, fz, rx, rz = 0, 1, 1, 0
  elseif f == 1 then fx, fz, rx, rz = 1, 0, 0, -1
  elseif f == 2 then fx, fz, rx, rz = 0, -1, -1, 0
  else fx, fz, rx, rz = -1, 0, 0, 1 end
  return {
    x = ox + qx * rx + qz * fx,
    y = oy - qy,  -- quarry +Y is down
    z = oz + qx * rz + qz * fz,
  }
end

local function hasOriginGps()
  return cfg.originX ~= nil and cfg.originY ~= nil and cfg.originZ ~= nil
end

local function findTurtleRef(ref)
  local id = tonumber(tostring(ref or ""):match("(%d+)"))
  if id and turtles[id] then return id, turtles[id] end
  local want = tostring(ref or ""):lower()
  if want == "" then return nil end
  for tid, t in pairs(turtles) do
    if tostring(t.name or ""):lower():find(want, 1, true) then
      return tid, t
    end
  end
  return nil
end

local function buildWherePayload(turtleId, t, toId)
  t = t or turtles[turtleId]
  if not t then return nil end
  local qx, qy, qz = tonumber(t.posX), tonumber(t.posY), tonumber(t.posZ)
  local world = nil
  if qx ~= nil then
    world = quarryToWorld(qx, qy or 0, qz or 0)
  end
  return {
    type = "quarry_where",
    siteId = os.getComputerID(),
    siteName = os.getComputerLabel() or ("Quarry-" .. os.getComputerID()),
    turtleId = turtleId,
    name = t.name or ("Turtle-" .. turtleId),
    status = t.status,
    -- Relative quarry pose
    posX = qx, posY = qy, posZ = qz,
    -- World GPS (nil if origin not set)
    x = world and world.x or nil,
    y = world and world.y or nil,
    z = world and world.z or nil,
    hasWorld = world ~= nil,
    originSet = hasOriginGps(),
    originFacing = cfg.originFacing,
    age = ago(t.seen),
    to = toId,  -- optional admin id that requested
  }
end

local function sendWhere(turtleId, toId)
  local t = turtles[turtleId]
  if not t then return false, "unknown turtle" end
  -- Ask turtle for a fresh check-in (best-effort).
  rednet.send(turtleId, { type = "quarry_turtle_req", from = os.getComputerID() }, PROTO)
  sleep(0.35)
  t = turtles[turtleId] or t
  local msg = buildWherePayload(turtleId, t, toId)
  if not msg then return false, "no payload" end
  if toId then
    rednet.send(toId, msg, PROTO)
    rednet.send(toId, msg, NET)
  end
  rednet.broadcast(msg, PROTO)
  rednet.broadcast(msg, NET)
  if titan and titan.ROUTER_PROTOCOL then
    rednet.broadcast(msg, titan.ROUTER_PROTOCOL)
  end
  return true, msg
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
  if msg.idx ~= nil then
    t.idx = tonumber(msg.idx) or t.idx
    t.continueIdx = tonumber(msg.idx) or t.continueIdx
  end
  if msg.continueIdx ~= nil then
    t.continueIdx = tonumber(msg.continueIdx) or t.continueIdx
  end
  if msg.total ~= nil then t.total = tonumber(msg.total) or t.total end
  if msg.moves ~= nil then t.moves = tonumber(msg.moves) or t.moves end
  if msg.coal ~= nil then t.coal = tonumber(msg.coal) or t.coal end
  if msg.status then t.status = msg.status end
  if msg.posX ~= nil then
    t.posX = tonumber(msg.posX) or t.posX
    t.posY = tonumber(msg.posY) or t.posY
    t.posZ = tonumber(msg.posZ) or t.posZ
    t.lastPosAt = now()
  end
  if msg.type == "quarry_sos" or msg.sos == true then
    t.sos = true
    t.status = "sos"
  elseif msg.sos == false or msg.type == "quarry_sos_clear" then
    t.sos = false
  end
  -- Site board owns claim coords. Progress msgs / old job files must NOT
  -- overwrite unique bands (that caused two turtles to share one XZ/Y claim).
  -- Only sync continueIdx / dug / job snapshot here.
  if msg.clearJob or msg.job == false then
    t.job = nil
    persistTurtleJob(id, nil)
  elseif type(msg.job) == "table" then
    t.job = msg.job
    if msg.job.idx ~= nil then
      t.idx = tonumber(msg.job.idx) or t.idx
      t.continueIdx = tonumber(msg.job.idx) or t.continueIdx
    end
    if msg.job.total ~= nil then t.total = tonumber(msg.job.total) or t.total end
    if msg.job.dug ~= nil then t.dug = tonumber(msg.job.dug) or t.dug end
    if msg.job.status and not msg.status then t.status = msg.job.status end
    persistTurtleJob(id, msg.job)
  end
  -- Drop claim shapes that disagree with current site dig mode.
  if turtleHasClaim(t) and not claimMatchesPattern(t, sitePattern()) then
    print(("[claim] #%d cleared mismatched %s (site=%s)"):format(
      id, claimLabel(t), sitePattern()))
    clearTurtleCoords(t)
    if t.status == "mining" or t.status == "assigned" then t.status = "idle" end
  end
  learnSiteFromMsg(msg)
  turtles[id] = t
  return t
end

local function claimPayload(extra)
  local p = {
    type = "quarry_claim",
    W = cfg.W, L = cfg.L, H = cfg.H,
    pattern = sitePattern(),
    maxTravel = maxTravel(), minBpc = minBpc(),
    claims = listClaimEntries(),
    free = listFreeBands(),
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do p[k] = v end
  end
  return p
end

local function archiveClaim(t)
  if not turtleHasClaim(t) then return end
  if t.x0 ~= nil then
    completedBands[#completedBands + 1] = {
      pattern = "column",
      x0 = t.x0, x1 = t.x1, z0 = t.z0, z1 = t.z1,
      y0 = t.y0 or 0, y1 = t.y1 or math.max(0, (tonumber(cfg.H) or 1) - 1),
    }
  else
    completedBands[#completedBands + 1] = {
      pattern = "layer", y0 = t.y0, y1 = t.y1,
    }
  end
end

--------------------------------------------------------------------------------
-- Fleet reband: split remaining work among N turtles, origin reset turns
--------------------------------------------------------------------------------
local function fleetIds()
  local ids = {}
  for id, t in pairs(turtles) do
    if t and t.status ~= "done" then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

-- Occupancy from completed work only (active claims are cleared during reband).
local function completedOnlyLayers()
  local H = math.max(0, tonumber(cfg.H) or 0)
  local occ = {}
  for y = 0, H - 1 do occ[y] = false end
  for _, b in ipairs(completedBands) do
    if b.x0 == nil and b.y0 and b.y1 then
      for y = b.y0, b.y1 do
        if occ[y] ~= nil then occ[y] = true end
      end
    end
  end
  return occ
end

local function freeLayerSpans()
  local H = math.max(0, tonumber(cfg.H) or 0)
  local occ = completedOnlyLayers()
  local spans = {}
  local y = 0
  while y < H do
    if not occ[y] then
      local y0 = y
      while y + 1 < H and not occ[y + 1] do y = y + 1 end
      spans[#spans + 1] = { y0 = y0, y1 = y }
    end
    y = y + 1
  end
  return spans
end

local function partitionLayerSpans(spans, n)
  local bands = {}
  if n < 1 then return bands end
  local total = 0
  for _, s in ipairs(spans) do total = total + (s.y1 - s.y0 + 1) end
  if total < 1 then return bands end
  local target = math.max(1, math.ceil(total / n))
  local si, ycur = 1, nil
  if spans[1] then ycur = spans[1].y0 end
  for _ = 1, n do
    local need = target
    local y0, y1 = nil, nil
    while need > 0 and si <= #spans do
      local s = spans[si]
      if not ycur or ycur < s.y0 or ycur > s.y1 then ycur = s.y0 end
      local take = math.min(need, s.y1 - ycur + 1)
      if not y0 then y0 = ycur end
      y1 = ycur + take - 1
      need = need - take
      ycur = y1 + 1
      if ycur > s.y1 then
        si = si + 1
        if spans[si] then ycur = spans[si].y0 end
      end
    end
    if y0 then bands[#bands + 1] = { y0 = y0, y1 = y1, pattern = "layer" } end
  end
  return bands
end

local function freeColumnList()
  local W = math.max(1, tonumber(cfg.W) or 1)
  local L = math.max(1, tonumber(cfg.L) or 1)
  local H = math.max(1, tonumber(cfg.H) or 1)
  local occ = {}
  for z = 0, L - 1 do
    occ[z] = {}
    for x = 0, W - 1 do occ[z][x] = false end
  end
  for _, b in ipairs(completedBands) do
    if b.x0 ~= nil then
      for z = b.z0, (b.z1 or b.z0) do
        for x = b.x0, (b.x1 or b.x0) do
          if occ[z] and occ[z][x] ~= nil then occ[z][x] = true end
        end
      end
    end
  end
  local cols = {}
  for z = 0, L - 1, 2 do
    for x = 0, W - 1, 2 do
      local x1 = math.min(x + 1, W - 1)
      local z1 = math.min(z + 1, L - 1)
      local free = true
      for zz = z, z1 do
        for xx = x, x1 do
          if occ[zz] and occ[zz][xx] then free = false end
        end
      end
      if free then
        cols[#cols + 1] = { x0 = x, x1 = x1, z0 = z, z1 = z1, y0 = 0, y1 = H - 1, pattern = "column" }
      end
    end
  end
  return cols
end

local function partitionColumns(cols, n)
  local bands = {}
  if n < 1 or #cols < 1 then return bands end
  local per = math.max(1, math.ceil(#cols / n))
  for i = 1, n do
    local group = {}
    for j = 1, per do
      local c = cols[(i - 1) * per + j]
      if c then group[#group + 1] = c end
    end
    if #group > 0 then
      local x0, x1 = group[1].x0, group[1].x1
      local z0, z1 = group[1].z0, group[1].z1
      local y0, y1 = group[1].y0, group[1].y1
      for _, c in ipairs(group) do
        x0 = math.min(x0, c.x0); x1 = math.max(x1, c.x1)
        z0 = math.min(z0, c.z0); z1 = math.max(z1, c.z1)
      end
      bands[#bands + 1] = {
        pattern = "column",
        x0 = x0, x1 = x1, z0 = z0, z1 = z1, y0 = y0, y1 = y1,
      }
    end
  end
  return bands
end

local function computeContinueIdx(t, claim)
  if not t or not claim then return 1 end
  local idx = tonumber(t.continueIdx) or tonumber(t.idx) or 1
  if idx < 1 then idx = 1 end
  if claim.x0 ~= nil and t.x0 ~= nil
      and tonumber(t.x0) == tonumber(claim.x0)
      and tonumber(t.x1) == tonumber(claim.x1)
      and tonumber(t.z0) == tonumber(claim.z0)
      and tonumber(t.z1) == tonumber(claim.z1) then
    return idx
  end
  if claim.x0 == nil and t.x0 == nil and claim.y0 ~= nil and t.y0 ~= nil
      and tonumber(t.y0) == tonumber(claim.y0)
      and tonumber(t.y1) == tonumber(claim.y1) then
    return idx
  end
  return 1
end

local function claimExtrasFor(t)
  if not turtleHasClaim(t) then return nil end
  local cidx = tonumber(t.continueIdx) or tonumber(t.idx) or 1
  return {
    ok = true,
    pattern = (t.x0 ~= nil) and "column" or "layer",
    y0 = t.y0, y1 = t.y1,
    x0 = t.x0, x1 = t.x1, z0 = t.z0, z1 = t.z1,
    continueIdx = cidx,
    resume = cidx > 1,
    epoch = rebandState.epoch,
    adminLock = t.adminLock == true,
  }
end

local advanceResetQueue  -- forward decl

local function sendRebandMsg(id, t)
  t = t or turtles[id]
  if not t then return end
  local park = rebandState.parkOffset[id] or 0
  local extra = claimExtrasFor(t) or { ok = false, err = "no claim after reband" }
  rednet.send(id, {
    type = "quarry_reband",
    epoch = rebandState.epoch,
    reason = rebandState.reason,
    turnOrder = rebandState.turnOrder,
    parkOffset = park,
    clearOrigin = { down = 1, right = 1 },
    W = cfg.W, L = cfg.L, H = cfg.H,
    pattern = sitePattern(),
    maxTravel = maxTravel(), minBpc = minBpc(),
    y0 = extra.y0, y1 = extra.y1,
    x0 = extra.x0, x1 = extra.x1, z0 = extra.z0, z1 = extra.z1,
    continueIdx = extra.continueIdx or 1,
    ok = extra.ok,
    err = extra.err,
  }, PROTO)
end

advanceResetQueue = function()
  if not rebandState.active then return end
  -- Find next turtle that is home and not yet reset.
  for _, id in ipairs(rebandState.turnOrder) do
    if rebandState.homeReady[id] and not rebandState.resetDone[id] then
      rebandState.currentTurn = id
      local t = turtles[id]
      local extra = claimExtrasFor(t) or {}
      local park = rebandState.parkOffset[id] or 0
      print(("[reband] reset turn → #%d (epoch %d)"):format(id, rebandState.epoch))
      local go = {
        type = "quarry_reset_go",
        epoch = rebandState.epoch,
        parkOffset = park,
        clearOrigin = { down = 1, right = 1 },
        W = cfg.W, L = cfg.L, H = cfg.H,
        pattern = sitePattern(),
        maxTravel = maxTravel(), minBpc = minBpc(),
        y0 = extra.y0, y1 = extra.y1,
        x0 = extra.x0, x1 = extra.x1, z0 = extra.z0, z1 = extra.z1,
        continueIdx = extra.continueIdx or 1,
        ok = extra.ok ~= false,
      }
      rednet.send(id, go, PROTO)
      rednet.broadcast(go, PROTO)  -- in case unicast missed
      if t then
        t.status = "reset"
        turtles[id] = t
      end
      return
    end
  end
  -- All done?
  local allDone = true
  for _, id in ipairs(rebandState.turnOrder) do
    if not rebandState.resetDone[id] then allDone = false; break end
  end
  if allDone then
    print(("[reband] epoch %d complete — fleet mining"):format(rebandState.epoch))
    rebandState.active = false
    rebandState.currentTurn = nil
    broadcastStatus()
  end
end

local function rebandFleet(reason, triggerId)
  if (tonumber(cfg.H) or 0) < 1 or (tonumber(cfg.W) or 0) < 1 then
    print("[reband] skipped — site size unknown")
    return false
  end
  local ids = fleetIds()
  if #ids < 1 then return false end

  rebandState.epoch = (tonumber(rebandState.epoch) or 0) + 1
  rebandState.active = true
  rebandState.reason = tostring(reason or "join")
  rebandState.turnOrder = ids
  rebandState.homeReady = {}
  rebandState.resetDone = {}
  rebandState.currentTurn = nil
  rebandState.parkOffset = {}
  for i, id in ipairs(ids) do
    rebandState.parkOffset[id] = i - 1  -- 0 = origin turn, others park down/right
  end

  local pat = sitePattern()
  local bands
  if pat == "column" then
    bands = partitionColumns(freeColumnList(), #ids)
  else
    bands = partitionLayerSpans(freeLayerSpans(), #ids)
  end

  print(("[reband] epoch %d  reason=%s  turtles=%d  bands=%d  trigger=#%s"):format(
    rebandState.epoch, rebandState.reason, #ids, #bands, tostring(triggerId or "-")))

  for i, id in ipairs(ids) do
    local t = turtles[id]
    if t then
      local old = {
        x0 = t.x0, x1 = t.x1, z0 = t.z0, z1 = t.z1,
        y0 = t.y0, y1 = t.y1,
        continueIdx = t.continueIdx, idx = t.idx,
      }
      -- Snapshot progress before clearing coords.
      local claim = bands[i]
      clearTurtleCoords(t)
      t.adminLock = false
      if claim then
        if claim.pattern == "column" or claim.x0 ~= nil then
          t.x0, t.x1, t.z0, t.z1 = claim.x0, claim.x1, claim.z0, claim.z1
          t.y0, t.y1 = claim.y0, claim.y1
        else
          t.y0, t.y1 = claim.y0, claim.y1
          t.x0, t.x1, t.z0, t.z1 = nil, nil, nil, nil
        end
        -- Restore identity fields for continue mapping against previous claim.
        local tmp = {
          x0 = old.x0, x1 = old.x1, z0 = old.z0, z1 = old.z1,
          y0 = old.y0, y1 = old.y1,
          continueIdx = old.continueIdx, idx = old.idx,
        }
        t.continueIdx = computeContinueIdx(tmp, claim)
        t.idx = t.continueIdx
        t.status = "homing"
        print(("  #%d → %s  continue@%d"):format(id, claimLabel(t), t.continueIdx))
      else
        t.status = "idle"
        t.continueIdx = 1
        print(("  #%d → (no remaining work)"):format(id))
      end
      turtles[id] = t
      sendRebandMsg(id, t)
    end
  end
  saveCfg()
  broadcastStatus()
  return true
end

local function onTurtleHome(id, msg)
  touchTurtle(id, msg or {})
  local t = turtles[id]
  if t then
    t.status = "homing"
    turtles[id] = t
  end
  if not rebandState.active then return end
  local ep = tonumber(msg and msg.epoch)
  if ep and ep ~= rebandState.epoch then
    return  -- stale epoch
  end
  local already = rebandState.homeReady[id] == true
  rebandState.homeReady[id] = true
  if not already then
    print(("[reband] #%d home (epoch %d)"):format(id, rebandState.epoch))
  end
  -- Start turns, or re-send reset_go if this turtle is current and still waiting.
  if not rebandState.currentTurn then
    advanceResetQueue()
  elseif rebandState.currentTurn == id and not rebandState.resetDone[id] then
    advanceResetQueue()
  end
end

local function onTurtleResetDone(id, msg)
  touchTurtle(id, msg or {})
  if not rebandState.active then return end
  if tonumber(msg and msg.epoch) and tonumber(msg.epoch) ~= rebandState.epoch then
    return
  end
  rebandState.resetDone[id] = true
  if rebandState.currentTurn == id then
    rebandState.currentTurn = nil
  end
  local t = turtles[id]
  if t then
    t.status = turtleHasClaim(t) and "mining" or "idle"
    turtles[id] = t
  end
  print(("[reband] #%d reset done"):format(id))
  advanceResetQueue()
  broadcastStatus()
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

  local pat = sitePattern()

  -- During reband, hand back the assigned claim + continueIdx (no new free grab).
  if rebandState.active and turtleHasClaim(t) and claimMatchesPattern(t, pat) then
    local extra = claimExtrasFor(t)
    extra.resume = true
    return claimPayload(extra)
  end

  -- Turtle finished a claim and wants another: archive old claim, don't resume it.
  if msg.nextBand or msg.forceNew then
    if turtleHasClaim(t) and t.status ~= "done" then
      archiveClaim(t)
      print(("[done] #%d released %s for next claim"):format(id, claimLabel(t)))
      saveCfg()
    end
    clearTurtleCoords(t)
    t.status = "idle"
    t.job = nil
    t.idx, t.total, t.continueIdx = nil, nil, nil
    persistTurtleJob(id, nil)
    turtles[id] = t
    -- Rebalance remaining work across the fleet when someone finishes a band.
    local ids = fleetIds()
    if #ids > 0 then
      rebandFleet("next_band", id)
      t = turtles[id]
      if turtleHasClaim(t) and claimMatchesPattern(t, pat) then
        return claimPayload(claimExtrasFor(t))
      end
    end
  end
  -- Keep the turtle's claim forever until done / clearclaims / reband.
  -- But only if it matches site dig mode (column vs layer).
  if turtleHasClaim(t) and t.status ~= "done" then
    if claimMatchesPattern(t, pat) then
      local extra = claimExtrasFor(t)
      extra.resume = true
      return claimPayload(extra)
    end
    print(("[claim] #%d drop stale %s — site is %s"):format(id, claimLabel(t), pat))
    clearTurtleCoords(t)
    t.status = "idle"
    turtles[id] = t
  end

  -- First claim with an existing fleet → reband everyone (includes this turtle).
  local others = 0
  for oid, ot in pairs(turtles) do
    if oid ~= id and ot.status ~= "done" then others = others + 1 end
  end
  if others > 0 or (turtleHasClaim(t) == false and #fleetIds() > 1) then
    rebandFleet("claim", id)
    t = turtles[id]
    if turtleHasClaim(t) and claimMatchesPattern(t, pat) then
      return claimPayload(claimExtrasFor(t))
    end
    return claimPayload({ ok = false, err = "no remaining work after reband" })
  end

  if pat == "column" then
    local x0, x1, z0, z1, y0, y1 = nextFreeColumn()
    if not x0 then
      return claimPayload({ ok = false, err = "no free 2x2 columns" })
    end
    t.x0, t.x1, t.z0, t.z1 = x0, x1, z0, z1
    t.y0, t.y1 = y0, y1
    t.status = "assigned"
    t.adminLock = false
    t.idx, t.total, t.continueIdx = 1, nil, 1
    t.job = nil
    turtles[id] = t
    print(("[claim] #%d %s → column X%d-%d Z%d-%d (full Y %d..%d)"):format(
      id, tostring(t.name), x0, x1, z0, z1, y0, y1))
    return claimPayload({
      ok = true,
      pattern = "column",
      x0 = x0, x1 = x1, z0 = z0, z1 = z1,
      y0 = y0, y1 = y1,
      continueIdx = 1,
      resume = false,
    })
  end

  local y0, y1 = nextFreeBand()
  if not y0 then
    return claimPayload({ ok = false, err = "no free Y layers" })
  end
  t.y0, t.y1 = y0, y1
  t.x0, t.x1, t.z0, t.z1 = nil, nil, nil, nil
  t.status = "assigned"
  t.adminLock = false
  t.idx, t.total, t.continueIdx = 1, nil, 1
  t.job = nil
  turtles[id] = t
  print(("[claim] #%d %s → Y %d..%d (%d layers)"):format(
    id, tostring(t.name), y0, y1, y1 - y0 + 1))
  return claimPayload({
    ok = true,
    pattern = "layer",
    y0 = y0, y1 = y1,
    continueIdx = 1,
    resume = false,
  })
end

local function markDone(id, msg)
  local t = touchTurtle(id, msg or {})
  if turtleHasClaim(t) then
    archiveClaim(t)
    print(("[done] #%d finished %s"):format(id, claimLabel(t)))
    saveCfg()
  end
  t.status = "done"
  clearTurtleCoords(t)
  t.job = nil
  persistTurtleJob(id, nil)  -- clear so turtle can claim a fresh region
  turtles[id] = t
end

-- Admin tablet sets a turtle's Y band (overrides auto claims for that turtle).
local function applyAdminAssign(turtleId, msg)
  turtleId = tonumber(turtleId) or tonumber(msg.turtleId)
  local y0 = tonumber(msg.y0)
  local y1 = tonumber(msg.y1)
  if not turtleId or y0 == nil or y1 == nil then return false end
  y0, y1 = math.floor(y0), math.floor(y1)
  if y1 < y0 then y0, y1 = y1, y0 end
  -- Free other turtles that overlap this admin band.
  for id, t in pairs(turtles) do
    if id ~= turtleId and t.y0 and t.y1 and overlaps(t.y0, t.y1, y0, y1) then
      print(("[admin] #%d freed Y %d..%d (overlap)"):format(id, t.y0, t.y1))
      t.y0, t.y1 = nil, nil
      t.status = "idle"
      turtles[id] = t
    end
  end
  local keep = {}
  for _, b in ipairs(completedBands) do
    if not overlaps(b.y0, b.y1, y0, y1) then
      keep[#keep + 1] = b
    else
      print(("[admin] cleared done Y %d..%d (reassigned)"):format(b.y0, b.y1))
    end
  end
  completedBands = keep
  if sitePattern() == "column" then
    print("[admin] refuse Y assign — site dig mode is column (use site column claims)")
    return false
  end
  local t = turtles[turtleId] or {
    name = "Turtle-" .. turtleId, seen = now(), status = "assigned",
  }
  t.y0, t.y1 = y0, y1
  t.x0, t.x1, t.z0, t.z1 = nil, nil, nil, nil  -- layer claim = Y band only
  t.status = "assigned"
  t.assignId = msg.assignId
  t.assignedBy = msg.from
  t.adminLock = true
  t.seen = now()
  if msg.W then cfg.W = math.max(tonumber(cfg.W) or 0, tonumber(msg.W) or 0) end
  if msg.L then cfg.L = math.max(tonumber(cfg.L) or 0, tonumber(msg.L) or 0) end
  if msg.H then cfg.H = math.max(tonumber(cfg.H) or 0, tonumber(msg.H) or 0) end
  turtles[turtleId] = t
  saveCfg()
  print(("[admin] #%d assigned Y %d..%d (locked)"):format(turtleId, y0, y1))
  broadcastStatus()
  return true
end

local function handleMsg(id, msg)
  if type(msg) ~= "table" or not msg.type then return end
  local t = tostring(msg.type)
  if t == "quarry_assign_set" then
    applyAdminAssign(msg.turtleId or id, msg)
  elseif t == "quarry_assign_ack" then
    local tid = tonumber(msg.turtleId) or id
    local row = turtles[tid]
    if row and msg.ok ~= false then
      row.y0 = tonumber(msg.y0) or row.y0
      row.y1 = tonumber(msg.y1) or row.y1
      row.status = row.status or "assigned"
      row.seen = now()
      turtles[tid] = row
      print(("[ack] #%d Y %s..%s"):format(
        tid, tostring(row.y0), tostring(row.y1)))
      broadcastStatus()
    end
  elseif t == "quarry_hello" or t == "quarry_join" or t == "quarry_turtle" then
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
    -- New fleet member with a sized site → reband everyone (home + reset turns).
    if first and (t == "quarry_join" or t == "quarry_hello")
        and (tonumber(cfg.W) or 0) >= 1 and (tonumber(cfg.H) or 0) >= 1 then
      local n = #fleetIds()
      if n >= 1 then
        rebandFleet("join", id)
        row = turtles[id]
      end
    end
    if shouldWelcome then
      local stored = loadStoredJob(id)
      rednet.send(id, {
        type = "quarry_welcome",
        siteId = os.getComputerID(),
        name = os.getComputerLabel(),
        W = cfg.W, L = cfg.L, H = cfg.H,
        pattern = sitePattern(),
        fraction = fractionLabel(),
        maxClaim = (sitePattern() == "column") and 4 or maxClaimLayers(),
        maxTravel = maxTravel(), minBpc = minBpc(),
        job = stored,
        y0 = row.y0, y1 = row.y1,
        x0 = row.x0, x1 = row.x1, z0 = row.z0, z1 = row.z1,
        continueIdx = row.continueIdx or row.idx or 1,
        rebandEpoch = rebandState.epoch,
        rebandActive = rebandState.active == true,
        hasJob = stored ~= nil,
      }, PROTO)
      row.welcomedAt = now()
      if stored then
        print(("[job] #%d can resume %s"):format(id, jobSummaryShort(stored)))
      end
      -- During reband: do NOT re-spam quarry_reband (that loops miners).
      -- If this turtle is already home and it's their turn, nudge reset_go again.
      if rebandState.active then
        if rebandState.homeReady[id] and rebandState.currentTurn == id
            and not rebandState.resetDone[id] then
          advanceResetQueue()
        elseif not rebandState.homeReady[id] and first then
          sendRebandMsg(id, row)
        end
      end
    end
    if t ~= "quarry_turtle" then broadcastStatus() end
  elseif t == "quarry_home" then
    onTurtleHome(id, msg)
  elseif t == "quarry_reset_done" then
    onTurtleResetDone(id, msg)
  elseif t == "quarry_claim_req" then
    local reply = assignClaim(id, msg)
    rednet.send(id, reply, PROTO)
    broadcastStatus()
  elseif t == "quarry_job_req" then
    touchTurtle(id, msg)
    local reply = jobReplyFor(id)
    reply.continueIdx = (turtles[id] and (turtles[id].continueIdx or turtles[id].idx)) or 1
    reply.epoch = rebandState.epoch
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
  elseif t == "quarry_sos" or t == "quarry_sos_clear" then
    touchTurtle(id, msg)
    if t == "quarry_sos" then
      print(("[SOS] #%d %s out of fuel @ %s,%s,%s"):format(
        id, tostring(msg.name or "?"),
        tostring(msg.posX or "?"), tostring(msg.posY or "?"), tostring(msg.posZ or "?")))
    end
    broadcastStatus()
  elseif t == "quarry_done" then
    markDone(id, msg)
    broadcastStatus()
  elseif t == "quarry_status_req" or t == "quarry_turtle_req" then
    rednet.send(id, snapshot(), PROTO)
    rednet.broadcast(snapshot(), PROTO)
  elseif t == "quarry_where_req" then
    local tid = tonumber(msg.turtleId) or tonumber(msg.botId) or tonumber(msg.id)
    if not tid or not turtles[tid] then
      rednet.send(id, {
        type = "quarry_where",
        ok = false,
        err = "unknown turtle",
        siteId = os.getComputerID(),
        turtleId = tid,
        to = id,
      }, PROTO)
    else
      local ok, payload = sendWhere(tid, id)
      if ok then
        print(("[where] #%d → admin #%d  rel=%s,%s,%s  world=%s"):format(
          tid, id,
          tostring(payload.posX), tostring(payload.posY), tostring(payload.posZ),
          payload.hasWorld
            and ("%d,%d,%d"):format(payload.x, payload.y, payload.z)
            or "(set origin first)"))
      end
    end
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

  local title = ("QUARRY  %dx%d × %dY  [%s/%s]"):format(
    snap.W, snap.L, snap.H, tostring(snap.pattern or "column"), snap.fraction)
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
  if snap.rebandActive then
    line(5, ("REBAND epoch %d  turn=#%s"):format(
      tonumber(snap.rebandEpoch) or 0, tostring(snap.rebandTurn or "-")), colors.yellow or colors.orange)
  elseif tostring(snap.pattern) == "column" then
    line(5, "claim mode COLUMN (2x2 XZ shafts, full H)", colors.lightGray)
  else
    line(5, ("claim max %d layers (%s of H)"):format(snap.maxClaim, snap.fraction), colors.lightGray)
  end

  local y = 7
  line(6, "ID   CLAIM      BPC   PROG  @POS / STATUS", colors.orange or colors.yellow)
  for _, t in ipairs(snap.turtles) do
    if y >= h then break end
    local band = "-"
    if t.x0 ~= nil then
      band = ("X%d-%dZ%d-%d"):format(t.x0, t.x1 or t.x0, t.z0, t.z1 or t.z0)
    elseif t.y0 and t.y1 then
      band = ("%d-%d"):format(t.y0, t.y1)
    end
    local prog = "-"
    if t.total and t.total > 0 and t.idx then
      prog = ("%d%%"):format(math.floor(100 * math.min(1, (t.idx - 1) / t.total)))
    end
    local st = tostring(t.status or "?")
    if t.sos then st = "SOS"
    elseif (t.age or 99) >= ONLINE_SECS then st = "stale" end
    local pos = (t.posX ~= nil)
      and ("%d,%d,%d"):format(t.posX, t.posY or 0, t.posZ or 0) or "-"
    local col = colors.white
    if st == "SOS" then col = colors.red
    elseif st == "homing" or st == "reset" then col = colors.yellow or colors.orange
    elseif st == "assigned" or st == "mining" then col = colors.lime
    elseif st == "done" then col = colors.lightGray
    elseif st == "stale" then col = colors.red end
    local cidx = t.continueIdx or t.idx
    if cidx and prog == "-" then prog = ("@" .. tostring(cidx)) end
    line(y, ("#%-3d %-10s %-5s %-4s %s %s"):format(
      t.id, band:sub(1, 10), tostring(t.bpc or "?"):sub(1, 5), prog, pos, st), col)
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
  print("  setup <W>x<L> <H> [half|third] [column|layer]")
  print("  auto                             learn size from turtle mine data")
  print("  pattern column|layer             column=2x2 XZ shafts; layer=Y bands")
  print("  fraction half|third              max Y band size hint (layer mode)")
  print("  reband                           split remaining work + origin reset turns")
  print("  origin <x> <y> <z> [n|s|e|w]     GPS of quarry 0,0,0 + facing into mine")
  print("  where <id>                       send turtle coords to admin distance screen")
  print("  claims                           show claimed + free regions")
  print("  clearclaims                      release ALL claims (active+done)")
  print("  clearclaims done                 clear finished claims only")
  print("  clearclaims stale                free claims from quiet turtles (manual)")
  print("  clearclaims Y <y0> [y1]          clear claims overlapping Y range")
  print("  clearclaims turtle <id>          release one turtle's claim")
  print("  clear | clearminers              wipe miner registry + jobs; turtles forget local digs")
  print("  reband                           re-split unique bands; turtles obey site pattern")
  print("  status | turtles | jobs | clear | broadcast")
  print("  help | exit")
  print("")
  print("On join: site rebands the fleet, turtles home, take turns dumping at origin,")
  print("then dig from continueIdx (skips already-mined units in their claim).")
  print("Set `origin` once (stand at turtle 0,0,0 facing into mine, F3 coords) so")
  print("`where` can send real GPS to the admin tablet.")
  print("Job files: " .. JOB_DIR .. "/<id>_offline_miner_job.cfg")
end

local function printClaims()
  local entries = listClaimEntries()
  local frees = listFreeBands()
  print("Dig mode: " .. sitePattern())
  if #entries == 0 then
    print("No claims.")
  else
    print("Claimed:")
    for _, e in ipairs(entries) do
      if e.x0 ~= nil then
        local tag = (e.kind == "done") and "[done]" or ("#" .. tostring(e.id) .. " " .. tostring(e.name or "?"):sub(1, 10))
        print(("  X%d-%d Z%d-%d  %s%s"):format(
          e.x0, e.x1 or e.x0, e.z0, e.z1 or e.z0, tag,
          e.stale and " (stale)" or ""))
      elseif e.kind == "done" then
        print(("  Y %d..%d  [done]"):format(e.y0, e.y1))
      else
        print(("  Y %d..%d  #%d %s%s"):format(
          e.y0, e.y1, e.id, tostring(e.name or "?"):sub(1, 12),
          e.stale and " (stale)" or ""))
      end
    end
  end
  if sitePattern() == "column" then
    if type(frees) ~= "table" or #frees == 0 then
      print("Free columns: (none)")
    else
      local parts = {}
      for _, f in ipairs(frees) do
        parts[#parts + 1] = ("X%d-%dZ%d-%d"):format(f.x0, f.x1, f.z0, f.z1)
      end
      print("Free columns (sample): " .. table.concat(parts, ", "))
    end
  elseif #frees == 0 then
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
    if s.rebandActive then
      print(("reband ACTIVE epoch=%d  turn=#%s"):format(
        tonumber(s.rebandEpoch) or 0, tostring(s.rebandTurn or "-")))
    else
      print(("reband idle (last epoch %d)"):format(tonumber(s.rebandEpoch) or 0))
    end
  elseif cmd == "reband" then
    if rebandFleet("manual", nil) then
      print("Reband broadcast — turtles should home and reset in turn.")
    else
      print("Reband failed (need footprint + at least one turtle).")
    end
  elseif cmd == "origin" then
    if not a[2] then
      if hasOriginGps() then
        print(("Origin GPS %d,%d,%d  facing %s (%d)"):format(
          cfg.originX, cfg.originY, cfg.originZ,
          facingLabel(cfg.originFacing), cfg.originFacing))
      else
        print("Origin not set. Stand at quarry 0,0,0 facing into the mine:")
        print("  origin <x> <y> <z> [north|south|east|west]")
      end
    else
      local x, y, z = tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
      local face = parseFacing(a[5] or a[2])
      -- Allow: origin x y z facing   OR   origin (with GPS later)
      if x and y and z then
        cfg.originX, cfg.originY, cfg.originZ = math.floor(x), math.floor(y), math.floor(z)
        if a[5] then
          local f = parseFacing(a[5])
          if f == nil then
            print("Bad facing (use n/s/e/w or 0-3). Kept previous facing.")
          else
            cfg.originFacing = f
          end
        end
        saveCfg()
        print(("Origin set to %d,%d,%d  facing %s — `where <id>` can send world GPS."):format(
          cfg.originX, cfg.originY, cfg.originZ, facingLabel(cfg.originFacing)))
      else
        print("Usage: origin <x> <y> <z> [north|south|east|west]")
        print("Example: origin 120 72 -45 south")
      end
    end
  elseif cmd == "where" then
    local tid = findTurtleRef(a[2])
    if not tid then
      print("Usage: where <turtleId>   (or partial name)")
      print("Example: where 12")
    else
      local ok, payload = sendWhere(tid, nil)
      if not ok then
        print("where failed: " .. tostring(payload))
      else
        print(("Sent where for #%d %s"):format(tid, tostring(payload.name)))
        print(("  quarry @ %s,%s,%s"):format(
          tostring(payload.posX), tostring(payload.posY), tostring(payload.posZ)))
        if payload.hasWorld then
          print(("  world  @ %d,%d,%d  → admin distance screen"):format(
            payload.x, payload.y, payload.z))
        else
          print("  world  (unset) — run `origin <x> <y> <z> <facing>` for GPS track")
        end
      end
    end
  elseif cmd == "turtles" then
    local s = snapshot()
    if #s.turtles == 0 then print("(none)")
    else
      for _, t in ipairs(s.turtles) do
        local claim = "-"
        if t.x0 ~= nil then
          claim = ("X%d-%d Z%d-%d"):format(t.x0, t.x1 or t.x0, t.z0, t.z1 or t.z0)
        elseif t.y0 then
          claim = ("Y%d-%d"):format(t.y0, t.y1 or t.y0)
        end
        local pos = (t.posX ~= nil)
          and (" @%d,%d,%d"):format(t.posX, t.posY or 0, t.posZ or 0) or ""
        print(("#%d %s  %s  bpc=%s  %s  %ss%s"):format(
          t.id, tostring(t.name):sub(1, 12), claim,
          tostring(t.bpc or "?"), tostring(t.status or "?"), tostring(t.age or "?"),
          pos))
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
      broadcastFleetClear("clearclaims")
      print(("Cleared all claims (%d released). Turtles forget local digs; run mine/reband."):format(n))
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
  elseif cmd == "clear" or cmd == "clearminers" or cmd == "resetfleet" then
    wipeMinerData(cmd)
    print("Cleared turtle registry / claims / quarry_jobs (footprint + pattern kept).")
    print("Broadcast quarry_fleet_clear — each turtle drops local job + pending assign.")
    print("Next: turtles `mine` (or reboot online) → site reband → unique bands.")
    print("Tip: `clearclaims` frees bands without wiping job files / turtle list.")
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
  elseif cmd == "pattern" or cmd == "mode" or cmd == "digmode" then
    local p = normalizePattern(a[2])
    if not p then
      print("Usage: pattern column|layer   (now " .. sitePattern() .. ")")
      print("  column = 2x2 XZ shafts through full height")
      print("  layer  = Y-band slices across the whole footprint")
      return true
    end
    local prev = sitePattern()
    cfg.pattern = p
    wipeMinerData("pattern")
    print(("Dig mode %s → %s (miner data cleared; fleet told to forget local jobs)."):format(
      prev, p))
    print("Run `reband` after turtles re-join, or let them `mine` to claim unique bands.")
    broadcastStatus()
  elseif cmd == "setup" then
    local raw = a[2]
    local W, L, H
    local extras = {}
    if raw and tostring(raw):find("x") then
      local p = {}
      for n in tostring(raw):gmatch("(%-?%d+)") do p[#p + 1] = tonumber(n) end
      W, L = p[1], p[2]
      H = tonumber(a[3])
      for i = 3, #a do extras[#extras + 1] = tostring(a[i] or ""):lower() end
    else
      W, L, H = tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
      for i = 5, #a do extras[#extras + 1] = tostring(a[i] or ""):lower() end
    end
    for _, fr in ipairs(extras) do
      if fr == "half" then cfg.fraction = 0.5
      elseif fr == "third" then cfg.fraction = 1 / 3
      else
        local pat = normalizePattern(fr)
        if pat then cfg.pattern = pat end
      end
    end
    if not W or not L or not H then
      print("Usage: setup <W>x<L> <H> [half|third] [column|layer]")
      print("Example: setup 16x32 60 column")
      print("Or skip setup — turtles' area commands set the site automatically.")
    else
      cfg.W, cfg.L, cfg.H = W, L, H
      cfg.pattern = normalizePattern(cfg.pattern) or "column"
      cfg.manual = true
      wipeMinerData("setup")
      if sitePattern() == "column" then
        print(("Site locked: %dx%d × %dY  pattern=column (2x2 XZ claims)"):format(W, L, H))
      else
        print(("Site locked: %dx%d × %dY  pattern=layer claim=%s (max %d)"):format(
          W, L, H, fractionLabel(), maxClaimLayers()))
      end
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
  print(("Footprint %dx%d × %dY  pattern=%s  claim=%s  %s"):format(
    cfg.W, cfg.L, cfg.H, sitePattern(), fractionLabel(),
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
