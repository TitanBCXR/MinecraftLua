--[[
  offline_site.lua  -  Quarry site board (XZ cell fleet)
  Titan-Version: 1.3.3

  Place LEFT of the storage chest (storage behind turtle origin). Modem required.
  Attach a **monitor** for the live status board — the computer terminal stays
  free for the `site>` console.

  Dig model:
    * Site W×L×H footprint
    * Split XZ into cells (target 20×20, min 4×4, edge remainders allowed)
    * One bot per cell; digs full H one Y-layer at a time inside the cell
    * Bot check-ins: leave_origin, arrive_cell, progress, cell_done
    * Site tracks quarry-relative + world pose (origin GPS); GPS turtle fix later
    * Fleet net: debounced status/cfg flushes; claim dedupe (avoids freeze under load)

  Commands:
    setup <W>x<L> <H> [cellSize]
    origin <x> <y> <z> [n|s|e|w|0-3]
    where <id>
    cells | status | turtles | jobs
    reband          recall fleet home + keep cell assigns
    clear | clearminers
    cellsize <n>
    help | exit

  Run:  offline_site
]]

local PROTO = "titan_quarry"
local NET = "titan_net"
local CFG = "offline_site.cfg"
local JOB_DIR = "quarry_jobs"
local ONLINE_SECS = 45
local POSE_SLACK = 2
local CELL_TARGET = 20
local CELL_MIN = 4
local STATUS_MIN_MS = 1500   -- min gap between full status broadcasts
local CFG_MIN_MS = 2000      -- debounce routine cfg writes
local CLAIM_DEDUPE_MS = 900  -- ignore dual cell_req+claim_req from same bot
local JOB_PERSIST_MS = 5000  -- throttle per-turtle job file writes

local titan = nil
if fs.exists("lib/titan.lua") then
  local ok, t = pcall(dofile, "lib/titan.lua")
  if ok then titan = t end
end

local cfg = {
  W = 0, L = 0, H = 0,
  cellSize = CELL_TARGET,
  manual = false,
  label = nil,
  originX = nil, originY = nil, originZ = nil, originFacing = 0,
  cells = {},
}

local turtles = {}
local recallState = {
  epoch = 0,
  active = false,
  homeReady = {},
  reason = nil,
}
local statusDirty = false
local statusLastFlush = 0
local cfgDirty = false
local cfgLastFlush = 0
local claimHandledAt = {}   -- [turtleId] = utc ms
local jobPersistAt = {}     -- [turtleId] = utc ms
local jobPersistIdx = {}    -- [turtleId] = last idx written

local function now() return os.epoch("utc") end
local function ago(ts) return math.floor((now() - (ts or 0)) / 1000) end

local function openModem()
  local found = nil
  for _, side in ipairs(redstone.getSides()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      if not found then found = side end
    end
  end
  return found
end

--------------------------------------------------------------------------------
-- Config / cells
--------------------------------------------------------------------------------
local function countCellsByStatus()
  local free, assigned, complete = 0, 0, 0
  for _, c in ipairs(cfg.cells or {}) do
    local st = tostring(c.status or "free")
    if st == "complete" or st == "done" then complete = complete + 1
    elseif st == "assigned" then assigned = assigned + 1
    else free = free + 1 end
  end
  return free, assigned, complete, #(cfg.cells or {})
end

local function cellCountForSize(W, L, s)
  W, L, s = math.max(0, W), math.max(0, L), math.max(1, s)
  if W < 1 or L < 1 then return 0 end
  local nx = math.ceil(W / s)
  local nz = math.ceil(L / s)
  return nx * nz
end

local function chooseCellSize(W, L, botCount)
  W = math.max(0, tonumber(W) or 0)
  L = math.max(0, tonumber(L) or 0)
  botCount = math.max(1, math.floor(tonumber(botCount) or 1))
  if W < 1 or L < 1 then return CELL_MIN end
  local maxDim = math.min(W, L)
  local start = math.min(CELL_TARGET, maxDim)
  if start < CELL_MIN then start = math.max(1, maxDim) end
  local best = start
  for s = start, math.max(1, math.min(CELL_MIN, maxDim)), -1 do
    best = s
    if cellCountForSize(W, L, s) >= botCount then break end
  end
  if maxDim < CELL_MIN then best = maxDim end
  return math.max(1, best)
end

local function buildCellGrid(opts)
  opts = opts or {}
  local W = math.max(0, tonumber(cfg.W) or 0)
  local L = math.max(0, tonumber(cfg.L) or 0)
  if W < 1 or L < 1 then
    cfg.cells = {}
    return 0
  end
  local bots = 0
  for _, t in pairs(turtles) do
    if t.status ~= "done" then bots = bots + 1 end
  end
  if bots < 1 then bots = 1 end
  local size = tonumber(opts.cellSize) or tonumber(cfg.cellSize) or CELL_TARGET
  if opts.autoSize ~= false then
    size = chooseCellSize(W, L, bots)
  end
  size = math.max(1, math.floor(size))
  cfg.cellSize = size

  -- Preserve completed cells by XZ signature when rebuilding.
  local doneMap = {}
  if opts.keepDone ~= false then
    for _, c in ipairs(cfg.cells or {}) do
      if c.status == "complete" or c.status == "done" then
        local key = ("%d:%d:%d:%d"):format(c.x0, c.x1, c.z0, c.z1)
        doneMap[key] = c
      end
    end
  end

  local cells = {}
  local id = 1
  local z = 0
  while z < L do
    local z1 = math.min(z + size - 1, L - 1)
    local x = 0
    while x < W do
      local x1 = math.min(x + size - 1, W - 1)
      local key = ("%d:%d:%d:%d"):format(x, x1, z, z1)
      local prev = doneMap[key]
      if prev then
        cells[#cells + 1] = {
          id = id, x0 = x, x1 = x1, z0 = z, z1 = z1,
          status = "complete", turtleId = nil, doneAt = prev.doneAt,
        }
      else
        cells[#cells + 1] = {
          id = id, x0 = x, x1 = x1, z0 = z, z1 = z1,
          status = "free", turtleId = nil, doneAt = nil,
        }
      end
      id = id + 1
      x = x1 + 1
    end
    z = z1 + 1
  end
  cfg.cells = cells
  -- Drop turtle cell pointers that no longer exist.
  for _, t in pairs(turtles) do
    t.cellId = nil
    t.x0, t.x1, t.z0, t.z1 = nil, nil, nil, nil
  end
  return #cells
end

local function findCell(cellId)
  cellId = tonumber(cellId)
  if not cellId then return nil end
  for _, c in ipairs(cfg.cells or {}) do
    if tonumber(c.id) == cellId then return c end
  end
  return nil
end

local function cellForTurtle(id)
  id = tonumber(id)
  for _, c in ipairs(cfg.cells or {}) do
    if tonumber(c.turtleId) == id and c.status == "assigned" then return c end
  end
  return nil
end

local function cellLabel(c)
  if not c then return "?" end
  return ("C%d X%d-%d Z%d-%d"):format(
    tonumber(c.id) or 0,
    tonumber(c.x0) or 0, tonumber(c.x1) or 0,
    tonumber(c.z0) or 0, tonumber(c.z1) or 0)
end

local function saveCfgNow()
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize(cfg))
  f.close()
  cfgDirty = false
  cfgLastFlush = now()
end

local function markCfgDirty()
  cfgDirty = true
end

local function flushCfg(force)
  if force then
    saveCfgNow()
    return
  end
  if not cfgDirty then return end
  if (now() - cfgLastFlush) < CFG_MIN_MS then return end
  saveCfgNow()
end

-- Back-compat name used throughout; routine callers should prefer markCfgDirty.
local function saveCfg()
  saveCfgNow()
end

local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) ~= "table" then return end
  for k, v in pairs(d) do cfg[k] = v end
  cfg.W = tonumber(cfg.W) or 0
  cfg.L = tonumber(cfg.L) or 0
  cfg.H = tonumber(cfg.H) or 0
  cfg.cellSize = tonumber(cfg.cellSize) or CELL_TARGET
  cfg.manual = cfg.manual == true
  cfg.originX = tonumber(cfg.originX)
  cfg.originY = tonumber(cfg.originY)
  cfg.originZ = tonumber(cfg.originZ)
  cfg.originFacing = math.floor(tonumber(cfg.originFacing) or 0) % 4
  if type(cfg.cells) ~= "table" then cfg.cells = {} end
  -- Normalize cells
  local norm = {}
  for i, c in ipairs(cfg.cells) do
    if type(c) == "table" and c.x0 ~= nil then
      norm[#norm + 1] = {
        id = tonumber(c.id) or i,
        x0 = math.floor(tonumber(c.x0) or 0),
        x1 = math.floor(tonumber(c.x1) or c.x0 or 0),
        z0 = math.floor(tonumber(c.z0) or 0),
        z1 = math.floor(tonumber(c.z1) or c.z0 or 0),
        status = tostring(c.status or "free"),
        turtleId = tonumber(c.turtleId),
        doneAt = c.doneAt,
      }
    end
  end
  cfg.cells = norm
  if #cfg.cells < 1 and cfg.W >= 1 and cfg.L >= 1 then
    buildCellGrid({ keepDone = false })
  end
end

--------------------------------------------------------------------------------
-- Jobs / turtles
--------------------------------------------------------------------------------
local function turtleJobPath(id)
  return JOB_DIR .. "/" .. tostring(id) .. "_offline_miner_job.cfg"
end

local function jobSummaryShort(j)
  if type(j) ~= "table" then return "(none)" end
  if j.cellId or (j.x0 ~= nil and j.z0 ~= nil) then
    return ("cell X%d-%d Z%d-%d step %d/%d [%s]"):format(
      tonumber(j.x0) or 0, tonumber(j.x1) or 0,
      tonumber(j.z0) or 0, tonumber(j.z1) or 0,
      tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
  end
  return ("%s step %d/%d [%s]"):format(
    tostring(j.type or "?"), tonumber(j.idx) or 1, tonumber(j.total) or 0, tostring(j.status or "?"))
end

local function persistTurtleJob(id, job, force)
  if not fs.exists(JOB_DIR) then fs.makeDir(JOB_DIR) end
  local path = turtleJobPath(id)
  if type(job) ~= "table" then
    if fs.exists(path) then pcall(fs.delete, path) end
    jobPersistAt[id] = nil
    jobPersistIdx[id] = nil
    return
  end
  local idx = tonumber(job.idx) or 0
  local st = tostring(job.status or "")
  local important = force
    or st == "done" or st == "paused" or st == "sos" or st == "verify"
  local lastAt = jobPersistAt[id] or 0
  local lastIdx = jobPersistIdx[id]
  if not important and lastIdx == idx and (now() - lastAt) < JOB_PERSIST_MS then
    return
  end
  local f = fs.open(path, "w")
  if not f then return end
  f.write(textutils.serialize(job))
  f.close()
  jobPersistAt[id] = now()
  jobPersistIdx[id] = idx
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

local function learnSiteFromMsg(msg)
  if cfg.manual or type(msg) ~= "table" then return false end
  local j = msg.job
  local W = tonumber(msg.W) or (j and tonumber(j.W))
  local L = tonumber(msg.L) or (j and (tonumber(j.L) or tonumber(j.D)))
  local H = tonumber(msg.H) or (j and (tonumber(j.stopY) or tonumber(j.H)))
  if j and j.y1 ~= nil then H = math.max(H or 0, (tonumber(j.y1) or 0) + 1) end
  W = math.floor(tonumber(W) or 0)
  L = math.floor(tonumber(L) or 0)
  H = math.floor(tonumber(H) or 0)
  if W < 1 or L < 1 or H < 1 then return false end
  local nW = math.max(tonumber(cfg.W) or 0, W)
  local nL = math.max(tonumber(cfg.L) or 0, L)
  local nH = math.max(tonumber(cfg.H) or 0, H)
  if nW == cfg.W and nL == cfg.L and nH == cfg.H then return false end
  cfg.W, cfg.L, cfg.H = nW, nL, nH
  buildCellGrid({ keepDone = true })
  saveCfg()
  print(("[auto] footprint %dx%d × %dY  cells=%d size=%d"):format(
    nW, nL, nH, #cfg.cells, cfg.cellSize))
  return true
end

local function quarryToWorld(qx, qy, qz)
  local ox, oy, oz = tonumber(cfg.originX), tonumber(cfg.originY), tonumber(cfg.originZ)
  if ox == nil or oy == nil or oz == nil then return nil end
  qx = tonumber(qx) or 0
  qy = tonumber(qy) or 0
  qz = tonumber(qz) or 0
  local f = math.floor(tonumber(cfg.originFacing) or 0) % 4
  local fx, fz, rx, rz
  if f == 0 then fx, fz, rx, rz = 0, 1, 1, 0
  elseif f == 1 then fx, fz, rx, rz = 1, 0, 0, -1
  elseif f == 2 then fx, fz, rx, rz = 0, -1, -1, 0
  else fx, fz, rx, rz = -1, 0, 0, 1 end
  return {
    x = ox + qx * rx + qz * fx,
    y = oy - qy,
    z = oz + qx * rz + qz * fz,
  }
end

local function hasOriginGps()
  return cfg.originX ~= nil and cfg.originY ~= nil and cfg.originZ ~= nil
end

local function poseExtras(t)
  local qx, qy, qz = tonumber(t.posX), tonumber(t.posY), tonumber(t.posZ)
  local world = (qx ~= nil) and quarryToWorld(qx, qy or 0, qz or 0) or nil
  return {
    posX = qx, posY = qy, posZ = qz,
    wx = world and world.x or nil,
    wy = world and world.y or nil,
    wz = world and world.z or nil,
    hasWorld = world ~= nil,
    -- GPS hooks (filled later when turtles report gps*)
    gpsX = tonumber(t.gpsX), gpsY = tonumber(t.gpsY), gpsZ = tonumber(t.gpsZ),
    gpsOk = t.gpsOk == true,
  }
end

local function inCellXZ(c, x, z, slack)
  if not c or x == nil or z == nil then return false end
  slack = tonumber(slack) or 0
  return x >= (c.x0 - slack) and x <= (c.x1 + slack)
     and z >= (c.z0 - slack) and z <= (c.z1 + slack)
end

local function sendReturnHome(id, reason)
  local msg = {
    type = "quarry_return_home",
    reason = tostring(reason or "pose"),
    siteId = os.getComputerID(),
  }
  rednet.send(id, msg, PROTO)
  rednet.broadcast(msg, PROTO)
  print(("[pose] #%d return home — %s"):format(id, tostring(reason)))
end

local function checkPose(id, t, msg)
  t = t or turtles[id]
  if not t then return end
  local st = tostring(msg and msg.status or t.status or "")
  if st ~= "mining" and st ~= "arrive" and st ~= "arrived" then return end
  local c = cellForTurtle(id)
  if not c then return end
  local x, z = tonumber(t.posX), tonumber(t.posZ)
  if x == nil or z == nil then return end
  if not inCellXZ(c, x, z, POSE_SLACK) then
    sendReturnHome(id, ("outside %s @ %s,%s"):format(cellLabel(c), tostring(x), tostring(z)))
    return
  end
  -- Future GPS verify: if gpsOk and world disagree with expected, return home.
  if t.gpsOk == true and hasOriginGps() then
    local expected = quarryToWorld(x, tonumber(t.posY) or 0, z)
    if expected and t.gpsX and t.gpsZ then
      local dx = math.abs((tonumber(t.gpsX) or 0) - expected.x)
      local dz = math.abs((tonumber(t.gpsZ) or 0) - expected.z)
      if dx > POSE_SLACK or dz > POSE_SLACK then
        sendReturnHome(id, ("gps mismatch dx=%d dz=%d"):format(dx, dz))
      end
    end
  end
end

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
  if msg.posX ~= nil then
    t.posX = tonumber(msg.posX) or t.posX
    t.posY = tonumber(msg.posY) or t.posY
    t.posZ = tonumber(msg.posZ) or t.posZ
    t.lastPosAt = now()
  end
  if msg.gpsX ~= nil then
    t.gpsX = tonumber(msg.gpsX)
    t.gpsY = tonumber(msg.gpsY)
    t.gpsZ = tonumber(msg.gpsZ)
    t.gpsOk = msg.gpsOk == true or (t.gpsX ~= nil)
  end
  if msg.type == "quarry_sos" or msg.sos == true then
    t.sos = true
    t.status = "sos"
  elseif msg.sos == false or msg.type == "quarry_sos_clear" then
    t.sos = false
  end
  if msg.clearJob or msg.job == false then
    t.job = nil
    persistTurtleJob(id, nil)
  elseif type(msg.job) == "table" then
    t.job = msg.job
    if msg.job.idx ~= nil then t.idx = tonumber(msg.job.idx) or t.idx end
    if msg.job.total ~= nil then t.total = tonumber(msg.job.total) or t.total end
    if msg.job.dug ~= nil then t.dug = tonumber(msg.job.dug) or t.dug end
    if msg.job.status and not msg.status then t.status = msg.job.status end
    persistTurtleJob(id, msg.job)
  end
  local cell = cellForTurtle(id)
  if cell then
    t.cellId = cell.id
    t.x0, t.x1, t.z0, t.z1 = cell.x0, cell.x1, cell.z0, cell.z1
    t.y0, t.y1 = 0, math.max(0, (tonumber(cfg.H) or 1) - 1)
  end
  learnSiteFromMsg(msg)
  turtles[id] = t
  checkPose(id, t, msg)
  return t
end

local function minBpc()
  local best
  for _, t in pairs(turtles) do
    local b = tonumber(t.bpc)
    if b and b > 0 and ago(t.seen) < ONLINE_SECS * 2 then
      if not best or b < best then best = b end
    end
  end
  return best or 48
end

local function maxTravel()
  return math.max(16, math.floor(minBpc() * 32 * 0.4))
end

local function siteProgress()
  local free, assigned, complete, total = countCellsByStatus()
  total = math.max(1, total)
  local done = complete
  -- Partial credit for assigned cells by turtle idx/total
  for _, c in ipairs(cfg.cells or {}) do
    if c.status == "assigned" and c.turtleId then
      local t = turtles[c.turtleId]
      if t and tonumber(t.total) and tonumber(t.total) > 0 then
        local frac = math.min(1, math.max(0, ((tonumber(t.idx) or 1) - 1) / tonumber(t.total)))
        done = done + frac
      end
    end
  end
  local pct = math.floor(math.min(100, (done / total) * 100) + 0.5)
  return pct, math.floor(done + 0.5), total, free, assigned, complete
end

local function onlineCount()
  local n = 0
  for _, t in pairs(turtles) do
    if ago(t.seen) < ONLINE_SECS then n = n + 1 end
  end
  return n
end

local function cellPayload(c, extra)
  local H = math.max(1, tonumber(cfg.H) or 1)
  local p = {
    type = "quarry_cell",
    ok = c ~= nil,
    pattern = "cell",
    dig = "layer",
    W = cfg.W, L = cfg.L, H = cfg.H,
    cellSize = cfg.cellSize,
    maxTravel = maxTravel(), minBpc = minBpc(),
    y0 = 0, y1 = H - 1,
  }
  if c then
    p.cellId = c.id
    p.x0, p.x1, p.z0, p.z1 = c.x0, c.x1, c.z0, c.z1
    p.status = c.status
  end
  if type(extra) == "table" then
    for k, v in pairs(extra) do p[k] = v end
  end
  return p
end

local function assignCell(id, opts)
  opts = opts or {}
  local t = turtles[id] or touchTurtle(id, {})
  if (tonumber(cfg.W) or 0) < 1 or (tonumber(cfg.H) or 0) < 1 then
    return cellPayload(nil, { ok = false, err = "site size unknown — setup WxL H" })
  end
  if #(cfg.cells or {}) < 1 then
    buildCellGrid()
    saveCfg()
  end

  -- Already assigned?
  local existing = cellForTurtle(id)
  if existing and not opts.forceNew then
    t.cellId = existing.id
    t.status = t.status or "assigned"
    turtles[id] = t
    return cellPayload(existing, { resume = true })
  end

  -- Release previous if forcing new (after complete handled separately)
  if existing and opts.forceNew then
    existing.turtleId = nil
    if existing.status == "assigned" then existing.status = "free" end
  end

  -- Maybe shrink grid if not enough free cells for online fleet.
  local free, _, _, total = countCellsByStatus()
  local bots = 0
  for _, tt in pairs(turtles) do
    if tt.status ~= "done" then bots = bots + 1 end
  end
  if free < 1 and bots > total then
    buildCellGrid({ keepDone = true })
    saveCfg()
  end

  local pick = nil
  for _, c in ipairs(cfg.cells or {}) do
    if c.status == "free" then pick = c; break end
  end
  if not pick then
    return cellPayload(nil, { ok = false, err = "no free cells" })
  end
  pick.status = "assigned"
  pick.turtleId = id
  t.cellId = pick.id
  t.x0, t.x1, t.z0, t.z1 = pick.x0, pick.x1, pick.z0, pick.z1
  t.y0, t.y1 = 0, math.max(0, (tonumber(cfg.H) or 1) - 1)
  t.status = "assigned"
  turtles[id] = t
  saveCfg()
  print(("[cell] #%d %s → %s"):format(id, tostring(t.name), cellLabel(pick)))
  return cellPayload(pick, { resume = false })
end

local function markCellDone(id, msg)
  local t = touchTurtle(id, msg or {})
  local c = cellForTurtle(id)
  if c then
    c.status = "complete"
    c.turtleId = nil
    c.doneAt = now()
    print(("[done] #%d finished %s"):format(id, cellLabel(c)))
  end
  t.cellId = nil
  t.status = "idle"
  t.job = nil
  persistTurtleJob(id, nil)
  turtles[id] = t
  saveCfg()
end

local function releaseTurtleCell(id)
  local c = cellForTurtle(id)
  if c then
    c.status = "free"
    c.turtleId = nil
    print(("[unclaim] #%d released %s"):format(id, cellLabel(c)))
  end
  local t = turtles[id]
  if t then
    t.cellId = nil
    t.x0, t.x1, t.z0, t.z1 = nil, nil, nil, nil
    t.status = "idle"
    turtles[id] = t
  end
  saveCfg()
end

local function broadcastFleetClear(reason)
  local msg = {
    type = "quarry_fleet_clear",
    siteId = os.getComputerID(),
    reason = tostring(reason or "clear"),
    pattern = "cell",
    W = cfg.W, L = cfg.L, H = cfg.H,
    clearJobs = true,
    clearAssign = true,
  }
  rednet.broadcast(msg, PROTO)
  rednet.broadcast(msg, NET)
  for tid in pairs(turtles) do rednet.send(tid, msg, PROTO) end
  print(("[fleet] clear (%s)"):format(tostring(reason)))
end

local function wipeMinerData(reason)
  turtles = {}
  for _, c in ipairs(cfg.cells or {}) do
    if c.status == "assigned" then
      c.status = "free"
      c.turtleId = nil
    end
  end
  recallState.active = false
  recallState.homeReady = {}
  if fs.exists(JOB_DIR) then
    for _, name in ipairs(fs.list(JOB_DIR)) do
      pcall(fs.delete, JOB_DIR .. "/" .. name)
    end
  end
  saveCfg()
  broadcastFleetClear(reason or "clear")
end

local function snapshot()
  local pct, done, total, free, assigned, complete = siteProgress()
  local list = {}
  for id, t in pairs(turtles) do
    local pose = poseExtras(t)
    local c = cellForTurtle(id)
    list[#list + 1] = {
      id = id, name = t.name,
      cellId = c and c.id or t.cellId,
      x0 = t.x0, x1 = t.x1, z0 = t.z0, z1 = t.z1,
      y0 = t.y0, y1 = t.y1,
      posX = pose.posX, posY = pose.posY, posZ = pose.posZ,
      wx = pose.wx, wy = pose.wy, wz = pose.wz,
      hasWorld = pose.hasWorld,
      gpsX = pose.gpsX, gpsY = pose.gpsY, gpsZ = pose.gpsZ, gpsOk = pose.gpsOk,
      dug = t.dug, idx = t.idx, total = t.total,
      bpc = t.bpc, fuel = t.fuel, status = t.status, age = ago(t.seen),
      sos = t.sos,
      job = t.job,
      jobSummary = t.job and jobSummaryShort(t.job) or nil,
      pattern = "cell",
    }
  end
  table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
  local cells = {}
  for _, c in ipairs(cfg.cells or {}) do
    cells[#cells + 1] = {
      id = c.id, x0 = c.x0, x1 = c.x1, z0 = c.z0, z1 = c.z1,
      status = c.status, turtleId = c.turtleId,
    }
  end
  return {
    type = "quarry_site",
    source = "site_board",
    siteId = os.getComputerID(),
    name = os.getComputerLabel() or ("Quarry-" .. os.getComputerID()),
    W = cfg.W, L = cfg.L, H = cfg.H,
    manual = cfg.manual == true,
    pattern = "cell",
    dig = "layer",
    cellSize = cfg.cellSize,
    pct = pct, done = done, total = total,
    cellsFree = free, cellsAssigned = assigned, cellsComplete = complete,
    cells = cells,
    minBpc = minBpc(), maxTravel = maxTravel(),
    online = onlineCount(),
    turtles = list,
    rebandEpoch = recallState.epoch,
    rebandActive = recallState.active == true,
    originSet = hasOriginGps(),
    originX = cfg.originX, originY = cfg.originY, originZ = cfg.originZ,
    originFacing = cfg.originFacing,
  }
end

local function markStatusDirty()
  statusDirty = true
end

-- force=true: send now (claims/SOS/clear). Else debounce to STATUS_MIN_MS.
local function broadcastStatus(force)
  if force == true then
    statusDirty = false
    statusLastFlush = now()
    local snap = snapshot()
    rednet.broadcast(snap, PROTO)
    rednet.broadcast(snap, NET)
    if titan and titan.ROUTER_PROTOCOL then
      rednet.broadcast(snap, titan.ROUTER_PROTOCOL)
    end
    return
  end
  markStatusDirty()
end

local function flushStatus()
  if not statusDirty then return end
  if (now() - statusLastFlush) < STATUS_MIN_MS then return end
  broadcastStatus(true)
end

local function parseFacing(raw)
  if raw == nil or raw == "" then return 0 end
  local s = tostring(raw):lower()
  if s == "0" or s == "s" or s == "south" or s == "+z" then return 0 end
  if s == "1" or s == "e" or s == "east" or s == "+x" then return 1 end
  if s == "2" or s == "n" or s == "north" or s == "-z" then return 2 end
  if s == "3" or s == "w" or s == "west" or s == "-x" then return 3 end
  local n = tonumber(raw)
  if n then return math.floor(n) % 4 end
  return nil
end

local function facingLabel(f)
  f = math.floor(tonumber(f) or 0) % 4
  return ({ "south/+Z", "east/+X", "north/-Z", "west/-X" })[f + 1]
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
  local pose = poseExtras(t)
  local c = cellForTurtle(turtleId)
  return {
    type = "quarry_where",
    siteId = os.getComputerID(),
    siteName = os.getComputerLabel() or ("Quarry-" .. os.getComputerID()),
    turtleId = turtleId,
    name = t.name or ("Turtle-" .. turtleId),
    status = t.status,
    cellId = c and c.id or t.cellId,
    posX = pose.posX, posY = pose.posY, posZ = pose.posZ,
    x = pose.wx, y = pose.wy, z = pose.wz,
    hasWorld = pose.hasWorld,
    gpsX = pose.gpsX, gpsY = pose.gpsY, gpsZ = pose.gpsZ, gpsOk = pose.gpsOk,
    originSet = hasOriginGps(),
    originFacing = cfg.originFacing,
    age = ago(t.seen),
    to = toId,
    ok = true,
  }
end

local function sendWhere(turtleId, toId)
  local t = turtles[turtleId]
  if not t then return false, "unknown turtle" end
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

local function recallFleet(reason)
  recallState.epoch = (tonumber(recallState.epoch) or 0) + 1
  recallState.active = true
  recallState.reason = tostring(reason or "reband")
  recallState.homeReady = {}
  local msg = {
    type = "quarry_reband",
    epoch = recallState.epoch,
    reason = recallState.reason,
    pattern = "cell",
    dig = "layer",
    W = cfg.W, L = cfg.L, H = cfg.H,
    cellSize = cfg.cellSize,
    maxTravel = maxTravel(), minBpc = minBpc(),
    recallOnly = true,
    ok = true,
  }
  for id, t in pairs(turtles) do
    local c = cellForTurtle(id)
    local go = {}
    for k, v in pairs(msg) do go[k] = v end
    if c then
      go.cellId = c.id
      go.x0, go.x1, go.z0, go.z1 = c.x0, c.x1, c.z0, c.z1
      go.y0, go.y1 = 0, math.max(0, (tonumber(cfg.H) or 1) - 1)
    end
    rednet.send(id, go, PROTO)
    t.status = "homing"
    turtles[id] = t
  end
  rednet.broadcast(msg, PROTO)
  print(("[reband] epoch %d recall (%s)"):format(recallState.epoch, recallState.reason))
  broadcastStatus(true)
  return true
end

--------------------------------------------------------------------------------
-- Network
--------------------------------------------------------------------------------
local function handleMsg(id, msg)
  if type(msg) ~= "table" or not msg.type then return end
  local t = tostring(msg.type)

  if t == "quarry_hello" or t == "quarry_join" or t == "quarry_turtle" then
    local first = turtles[id] == nil
    touchTurtle(id, msg)
    local row = turtles[id]
    if t ~= "quarry_turtle" or first then
      print(("[+] #%d %s  bpc=%s"):format(
        id, tostring(msg.name or "?"), tostring(msg.bpc or "?")))
    end
    if first and (t == "quarry_join" or t == "quarry_hello")
        and (tonumber(cfg.W) or 0) >= 1 then
      -- Rebuild size if fleet grew enough to need smaller cells (no active assigns).
      local _, assigned = countCellsByStatus()
      if assigned < 1 then
        buildCellGrid({ keepDone = true })
        saveCfg()
      end
    end
    local shouldWelcome = (t ~= "quarry_turtle") or first or ago(row.welcomedAt or 0) > 60
    if shouldWelcome then
      local cell = cellForTurtle(id)
      local stored = loadStoredJob(id)
      rednet.send(id, {
        type = "quarry_welcome",
        siteId = os.getComputerID(),
        name = os.getComputerLabel(),
        W = cfg.W, L = cfg.L, H = cfg.H,
        pattern = "cell", dig = "layer",
        cellSize = cfg.cellSize,
        maxTravel = maxTravel(), minBpc = minBpc(),
        job = stored,
        cellId = cell and cell.id,
        x0 = cell and cell.x0, x1 = cell and cell.x1,
        z0 = cell and cell.z0, z1 = cell and cell.z1,
        y0 = 0, y1 = math.max(0, (tonumber(cfg.H) or 1) - 1),
        rebandEpoch = recallState.epoch,
        rebandActive = recallState.active == true,
        hasJob = stored ~= nil,
      }, PROTO)
      row.welcomedAt = now()
    end
    if t ~= "quarry_turtle" then markStatusDirty() end

  elseif t == "quarry_claim_req" or t == "quarry_cell_req" then
    -- Miners used to send both types at once — only handle one per window.
    local last = claimHandledAt[id] or 0
    if (now() - last) < CLAIM_DEDUPE_MS then
      return
    end
    claimHandledAt[id] = now()
    touchTurtle(id, msg)
    local reply = assignCell(id, {
      forceNew = msg.nextBand or msg.forceNew or msg.nextCell,
    })
    flushCfg(true)
    reply.type = "quarry_cell"
    local legacy = {}
    for k, v in pairs(reply) do legacy[k] = v end
    legacy.type = "quarry_claim"
    rednet.send(id, reply, PROTO)
    rednet.send(id, legacy, PROTO)
    broadcastStatus(true)

  elseif t == "quarry_leave_origin" then
    local row = touchTurtle(id, msg)
    row.status = "travel"
    turtles[id] = row
    print(("[travel] #%d left origin → cell %s"):format(
      id, tostring(row.cellId or "?")))
    markStatusDirty()

  elseif t == "quarry_arrive_cell" then
    local row = touchTurtle(id, msg)
    row.status = "mining"
    turtles[id] = row
    print(("[arrive] #%d at cell %s"):format(id, tostring(row.cellId or "?")))
    markStatusDirty()

  elseif t == "quarry_cell_done" then
    markCellDone(id, msg)
    flushCfg(true)
    local nextC = assignCell(id, { forceNew = true })
    flushCfg(true)
    nextC.type = "quarry_cell"
    rednet.send(id, nextC, PROTO)
    local legacy = {}
    for k, v in pairs(nextC) do legacy[k] = v end
    legacy.type = "quarry_claim"
    rednet.send(id, legacy, PROTO)
    broadcastStatus(true)

  elseif t == "quarry_home" then
    touchTurtle(id, msg)
    if recallState.active then
      recallState.homeReady[id] = true
      local all = true
      for tid in pairs(turtles) do
        if not recallState.homeReady[tid] then all = false; break end
      end
      if all then
        recallState.active = false
        print(("[reband] epoch %d complete — fleet home"):format(recallState.epoch))
        broadcastStatus(true)
      else
        markStatusDirty()
      end
    else
      markStatusDirty()
    end

  elseif t == "quarry_reset_done" then
    touchTurtle(id, msg)
    local row = turtles[id]
    if row then
      row.status = cellForTurtle(id) and "mining" or "idle"
      turtles[id] = row
    end
    markStatusDirty()

  elseif t == "quarry_job_req" then
    touchTurtle(id, msg)
    local job = loadStoredJob(id)
    local cell = cellForTurtle(id)
    rednet.send(id, {
      type = "quarry_job_reply",
      ok = job ~= nil,
      job = job,
      pattern = "cell",
      cellId = cell and cell.id,
      x0 = cell and cell.x0, x1 = cell and cell.x1,
      z0 = cell and cell.z0, z1 = cell and cell.z1,
      y0 = 0, y1 = math.max(0, (tonumber(cfg.H) or 1) - 1),
      W = cfg.W, L = cfg.L, H = cfg.H,
      maxTravel = maxTravel(), minBpc = minBpc(),
    }, PROTO)

  elseif t == "quarry_progress" or t == "quarry_job" then
    touchTurtle(id, msg)
    if msg.status == "done" or msg.finished or msg.cellDone then
      markCellDone(id, msg)
      flushCfg(true)
      broadcastStatus(true)
    else
      -- Pose/progress updates: monitor redraws from memory; mesh broadcast debounced.
      markStatusDirty()
    end

  elseif t == "quarry_sos" or t == "quarry_sos_clear" then
    touchTurtle(id, msg)
    if t == "quarry_sos" then
      print(("[SOS] #%d %s %s @ %s,%s,%s fuel~%s"):format(
        id, tostring(msg.name or "?"), tostring(msg.reason or "fuel"),
        tostring(msg.posX or "?"), tostring(msg.posY or "?"), tostring(msg.posZ or "?"),
        tostring(msg.fuelEst or msg.fuel or "?")))
      if msg.suggestX ~= nil then
        print(("  → fuel chest on travel layer ~%s,%s,%s (rel)"):format(
          tostring(msg.suggestX), tostring(msg.suggestY or -1), tostring(msg.suggestZ)))
      end
    end
    broadcastStatus(true)

  elseif t == "quarry_done" then
    markCellDone(id, msg)
    flushCfg(true)
    broadcastStatus(true)

  elseif t == "quarry_status_req" or t == "quarry_turtle_req" then
    rednet.send(id, snapshot(), PROTO)
    -- Don't also flood-broadcast a second full snapshot for every req.

  elseif t == "quarry_where_req" then
    local tid = tonumber(msg.turtleId) or tonumber(msg.botId) or tonumber(msg.id)
    if not tid or not turtles[tid] then
      rednet.send(id, {
        type = "quarry_where", ok = false, err = "unknown turtle",
        siteId = os.getComputerID(), turtleId = tid, to = id,
      }, PROTO)
    else
      sendWhere(tid, id)
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

  local title = ("QUARRY  %dx%d × %dY  cells@%d"):format(
    snap.W, snap.L, snap.H, tonumber(snap.cellSize) or 0)
  if color then
    if out.setBackgroundColor then out.setBackgroundColor(colors.cyan) end
    if out.setTextColor then out.setTextColor(colors.black) end
    out.setCursorPos(1, 1)
    out.write((" %-"..w.."s"):format(title):sub(1, w))
    if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
  else
    line(1, title, colors.yellow)
  end

  line(2, ("Progress %d%%  cells %d/%d  free=%d asg=%d"):format(
    snap.pct, snap.done, snap.total,
    tonumber(snap.cellsFree) or 0, tonumber(snap.cellsAssigned) or 0), colors.lime)
  line(3, ("Online %d  travel≤%d  origin=%s"):format(
    snap.online, snap.maxTravel, snap.originSet and "set" or "unset"), colors.lightGray)

  local y = 5
  line(y, "ID  Name         Cell     Rel XYZ      World", colors.white)
  y = y + 1
  for _, t in ipairs(snap.turtles or {}) do
    if y > h then break end
    local rel = (t.posX ~= nil)
      and ("%d,%d,%d"):format(t.posX, t.posY or 0, t.posZ or 0) or "-"
    local world = t.hasWorld
      and ("%d,%d,%d"):format(t.wx, t.wy, t.wz) or "-"
    local cell = t.cellId and ("C" .. tostring(t.cellId)) or "-"
    local row = ("#%d %-12s %-8s %-12s %s"):format(
      t.id or 0, tostring(t.name or "?"):sub(1, 12),
      cell, rel:sub(1, 12), world)
    local col = colors.white
    if t.sos then col = colors.red
    elseif t.status == "travel" then col = colors.yellow
    elseif t.status == "mining" then col = colors.lime
    elseif t.status == "homing" then col = colors.orange
    end
    line(y, row, col)
    y = y + 1
  end
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
local function printHelp()
  print("Quarry site board — XZ cells, full-H layer digs")
  print("  setup <W>x<L> <H> [cellSize]   lock footprint + rebuild cells")
  print("  cellsize <n>                   set target cell size (rebuild free)")
  print("  origin <x> <y> <z> [facing]    GPS of quarry 0,0,0")
  print("  where <id>                     admin distance track")
  print("  cells | status | turtles | jobs")
  print("  reband                         recall fleet home (keeps cell assigns)")
  print("  clear | clearminers            wipe turtles/jobs; keep footprint/cells done")
  print("  clearcells                     rebuild all cells as free (keeps size)")
  print("  help | exit")
end

local function printCells()
  local free, assigned, complete, total = countCellsByStatus()
  print(("Cells size=%d  total=%d  free=%d assigned=%d complete=%d"):format(
    cfg.cellSize, total, free, assigned, complete))
  for _, c in ipairs(cfg.cells or {}) do
    local who = c.turtleId and ("#" .. c.turtleId) or "-"
    print(("  %s  %s  %s"):format(cellLabel(c), c.status, who))
  end
end

local function handleCommand(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = tostring(a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" or cmd == "?" then printHelp()
  elseif cmd == "status" then
    local s = snapshot()
    print(("Site %dx%d × %dY  cells@%d  %d%%  online=%d"):format(
      s.W, s.L, s.H, s.cellSize or 0, s.pct, s.online))
    print(("cells free=%d assigned=%d complete=%d / %d"):format(
      s.cellsFree or 0, s.cellsAssigned or 0, s.cellsComplete or 0, s.total))
    if s.rebandActive then
      print(("recall ACTIVE epoch=%d"):format(tonumber(s.rebandEpoch) or 0))
    end
  elseif cmd == "cells" or cmd == "claims" then
    printCells()
  elseif cmd == "turtles" then
    local s = snapshot()
    if #s.turtles == 0 then print("(none)")
    else
      for _, t in ipairs(s.turtles) do
        print(("#%d %s  cell=%s  rel=%s,%s,%s  %s"):format(
          t.id, tostring(t.name or "?"):sub(1, 12),
          tostring(t.cellId or "-"),
          tostring(t.posX), tostring(t.posY), tostring(t.posZ),
          tostring(t.status or "?")))
      end
    end
  elseif cmd == "jobs" then
    if not fs.exists(JOB_DIR) then print("(no quarry_jobs/)")
    else
      for _, name in ipairs(fs.list(JOB_DIR)) do
        print(JOB_DIR .. "/" .. name)
      end
    end
  elseif cmd == "reband" then
    recallFleet("manual")
  elseif cmd == "clear" or cmd == "clearminers" then
    wipeMinerData(cmd)
    print("Cleared turtle registry / jobs. Cells kept (assigned→free).")
    broadcastStatus(true)
  elseif cmd == "clearcells" then
    for _, c in ipairs(cfg.cells or {}) do
      c.status = "free"
      c.turtleId = nil
      c.doneAt = nil
    end
    for _, t in pairs(turtles) do
      t.cellId = nil
      t.status = "idle"
    end
    saveCfg()
    broadcastFleetClear("clearcells")
    print("All cells free.")
    broadcastStatus(true)
  elseif cmd == "cellsize" then
    local n = tonumber(a[2])
    if not n or n < 1 then
      print("Usage: cellsize <n>   (now " .. tostring(cfg.cellSize) .. ")")
    else
      cfg.cellSize = math.max(1, math.floor(n))
      buildCellGrid({ cellSize = cfg.cellSize, autoSize = false, keepDone = true })
      saveCfg()
      print(("Cell size %d — %d cells"):format(cfg.cellSize, #cfg.cells))
      broadcastStatus(true)
    end
  elseif cmd == "origin" then
    if not a[2] then
      if hasOriginGps() then
        print(("Origin %d,%d,%d facing %s"):format(
          cfg.originX, cfg.originY, cfg.originZ, facingLabel(cfg.originFacing)))
      else
        print("Origin unset. Usage: origin <x> <y> <z> [n|s|e|w]")
      end
    else
      local x, y, z = tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
      if x and y and z then
        cfg.originX, cfg.originY, cfg.originZ = math.floor(x), math.floor(y), math.floor(z)
        local f = parseFacing(a[5])
        if f then cfg.originFacing = f end
        saveCfg()
        print(("Origin set %d,%d,%d facing %s"):format(
          cfg.originX, cfg.originY, cfg.originZ, facingLabel(cfg.originFacing)))
      else
        print("Usage: origin <x> <y> <z> [north|south|east|west]")
      end
    end
  elseif cmd == "where" then
    local tid = findTurtleRef(a[2])
    if not tid then
      print("Usage: where <turtleId>")
    else
      local ok, payload = sendWhere(tid, nil)
      if not ok then print("where failed: " .. tostring(payload))
      else
        print(("Sent where #%d %s"):format(tid, tostring(payload.name)))
      end
    end
  elseif cmd == "setup" then
    local raw = a[2]
    local W, L, H
    if raw and tostring(raw):find("x") then
      local p = {}
      for n in tostring(raw):gmatch("(%-?%d+)") do p[#p + 1] = tonumber(n) end
      W, L = p[1], p[2]
      H = tonumber(a[3])
      if tonumber(a[4]) then cfg.cellSize = math.floor(tonumber(a[4])) end
    else
      W, L, H = tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
      if tonumber(a[5]) then cfg.cellSize = math.floor(tonumber(a[5])) end
    end
    if not W or not L or not H then
      print("Usage: setup <W>x<L> <H> [cellSize]")
      print("Example: setup 215x100 13 20")
    else
      cfg.W, cfg.L, cfg.H = W, L, H
      cfg.manual = true
      turtles = {}
      buildCellGrid({ keepDone = false })
      saveCfg()
      broadcastFleetClear("setup")
      print(("Site locked %dx%d × %dY  cellSize=%d  cells=%d"):format(
        W, L, H, cfg.cellSize, #cfg.cells))
      broadcastStatus(true)
    end
  elseif cmd == "broadcast" or cmd == "push" then
    broadcastStatus(true)
    print("Status broadcast.")
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
print("== Quarry Site Board (cells) ==")
if (cfg.W or 0) < 1 then
  print("No footprint yet. `setup WxL H` or let a turtle report.")
else
  print(("Footprint %dx%d × %dY  cellSize=%d  cells=%d"):format(
    cfg.W, cfg.L, cfg.H, cfg.cellSize, #(cfg.cells or {})))
end
local mon = wrapMonitor()
if mon then
  print("Status board → attached monitor (this screen is the console).")
else
  print("No monitor attached — status board idle until you add one.")
  print("(Console stays on this computer; board never draws here.)")
end
print("Type help.")

-- Live board ONLY on a peripheral monitor — never on `term` (that steals the console).
local function uiLoop()
  local warned = false
  while true do
    mon = wrapMonitor()
    if mon then
      warned = false
      local ok, err = pcall(drawBoard, mon)
      if not ok then print("[monitor] " .. tostring(err)) end
    elseif not warned then
      -- one-shot; don't spam the console
      warned = true
    end
    sleep(1)
  end
end

local function netLoop()
  while true do
    local id, msg = rednet.receive(PROTO, 0.4)
    if id and type(msg) == "table" then
      local ok, err = pcall(handleMsg, id, msg)
      if not ok then print("[net err] " .. tostring(err)) end
      -- Drain a short burst so join/claim storms don't stall the event queue.
      for _ = 1, 12 do
        local id2, msg2 = rednet.receive(PROTO, 0)
        if not id2 then break end
        if type(msg2) == "table" then
          ok, err = pcall(handleMsg, id2, msg2)
          if not ok then print("[net err] " .. tostring(err)) end
        end
      end
    end
    flushCfg(false)
    flushStatus()
  end
end

local function consoleLoop()
  while true do
    write("site> ")
    local line = read()
    local r = handleCommand(line)
    if r == "exit" then return end
  end
end

parallel.waitForAny(netLoop, uiLoop, consoleLoop)
print("Site board closed.")
