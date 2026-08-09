--[[
  host.lua  -  Titan install / update host + Tetris leaderboard (CC: Tweaked)
  Titan-Version: 1.2.10

  Run this on ONE computer that already has the Titan files (your "update
  server"). It serves those files over rednet so pockets and other devices can
  install / OTA without storing any GitHub / wget URL on the clients.

  File serving uses both:
    * titan_install  — direct / local RF
    * titan_router   — mesh hops through your MAIN / extender / modem cells

  Tetris leaderboard lives on a floppy disk in an attached disk drive
  (tetris_leaderboard.cfg), keyed by player name. Attach a drive + leave a
  disk inserted. Tablets sync on boot / after games via titan_install + mesh.

  Usage:
    1. Keep this machine updated (you may wget/GitHub here — clients never see it).
    2. Wireless (or ender) modem + disk drive with floppy + run:  host
    3. Join the Titan router mesh (same as other devices).
    4. Give out tablets via install.lua role `t` (or disk copy).

  Only serves files on the published list. Ctrl+T to stop.
]]

local PROTOCOL = "titan_install"
local ROUTER_PROTOCOL = "titan_router"
local LB_NAME = "tetris_leaderboard.cfg"
local LB_LOCAL_LEGACY = "tetris_leaderboard.cfg" -- migrate once from computer FS
local LB_MAX = 25 -- keep extras; tablets only display top 3
local LB_DISK_LABEL = "Tetris LB"

local FILES = {
  "install.lua",
  "lib/titan.lua",
  "versions.lua",
  "datacenter.lua",
  "console.lua",
  "admin.lua",
  "router.lua",
  "router_main.lua",
  "router_modem.lua",
  "lib/router_hub_net.lua",
  "lib/router_hub_ui.lua",
  "lib/router_hub_cmd.lua",
  "quarry/workers/offline_miner.lua",
  "quarry/workers/strip_miner.lua",
  "quarry/managers/offline_site.lua",
  "offline_miner.lua",
  "offline_site.lua",
  "perimeter_sensor.lua",
  "perimeter_manager.lua",
  "tetris.lua",
  "minesweeper.lua",
  "sandstorm.lua",
  "luigi_poker.lua",
  "slots.lua",
  "games.lua",
  "games_catalog.lua",
  "games_install.lua",
  "host.lua",
  "exclude.txt",
  "github_install.lua",
  "pastebin_install.lua",
}

local function openModem()
  local found = nil
  for _, side in ipairs(redstone.getSides()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      pcall(peripheral.call, side, "open", rednet.CHANNEL_REPEAT)
      if not found then found = side end
    end
  end
  if not found then error("No modem attached. Place a (wireless) modem on this device.", 0) end
  return found
end

local function relayLoop()
  local REPEAT, relayed = rednet.CHANNEL_REPEAT, {}
  while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
      local side, channel, replyChannel, message = p1, p2, p3, p4
      if channel == REPEAT and type(message) == "table"
         and message.nMessageID and message.nRecipient and not relayed[message.nMessageID] then
        relayed[message.nMessageID] = os.startTimer(30)
        for _, s in ipairs(redstone.getSides()) do
          if peripheral.getType(s) == "modem" and rednet.isOpen(s) then
            peripheral.call(s, "transmit", REPEAT, replyChannel, message)
            if message.nRecipient ~= REPEAT then
              peripheral.call(s, "transmit", message.nRecipient, replyChannel, message)
            end
          end
        end
      end
    elseif event == "timer" then
      for mid, timer in pairs(relayed) do
        if timer == p1 then relayed[mid] = nil; break end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Tetris leaderboard (persisted on floppy disk)
--------------------------------------------------------------------------------
local leaderboard = {} -- sorted descending: { id, name, score, at }
local lbDriveName, lbMount, lbPath = nil, nil, nil

-- Prefer a floppy that already has the board file; else any present disk.
local function findLbDisk()
  local anyName, anyMount = nil, nil
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
      local d = peripheral.wrap(name)
      if d and d.isDiskPresent and d.isDiskPresent() then
        local mount = d.getMountPath and d.getMountPath()
        if mount and mount ~= "" then
          local path = fs.combine(mount, LB_NAME)
          if fs.exists(path) and not fs.isDir(path) then
            return name, mount, path
          end
          if not anyMount then
            anyName, anyMount = name, mount
          end
        end
      end
    end
  end
  if anyMount then
    return anyName, anyMount, fs.combine(anyMount, LB_NAME)
  end
  return nil, nil, nil
end

local function refreshLbDisk()
  lbDriveName, lbMount, lbPath = findLbDisk()
  return lbPath ~= nil
end

local function readBoardFile(path)
  if not path or not fs.exists(path) or fs.isDir(path) then return {} end
  local f = fs.open(path, "r")
  if not f then return {} end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) == "table" and type(d.entries) == "table" then
    return d.entries
  elseif type(d) == "table" then
    return d
  end
  return {}
end

local function writeBoardFile(path)
  if not path then return false, "no disk" end
  local f = fs.open(path, "w")
  if not f then return false, "open failed" end
  f.write(textutils.serialize({ entries = leaderboard }))
  f.close()
  if lbDriveName then
    pcall(function()
      local d = peripheral.wrap(lbDriveName)
      if d and d.setDiskLabel and (not d.getDiskLabel or d.getDiskLabel() == nil or d.getDiskLabel() == "") then
        d.setDiskLabel(LB_DISK_LABEL)
      end
    end)
  end
  return true
end

local function loadLeaderboard()
  leaderboard = {}
  refreshLbDisk()
  if lbPath and fs.exists(lbPath) then
    leaderboard = readBoardFile(lbPath)
    return "disk"
  end
  -- One-time migrate from computer-local file onto the floppy.
  if fs.exists(LB_LOCAL_LEGACY) and not fs.isDir(LB_LOCAL_LEGACY) then
    leaderboard = readBoardFile(LB_LOCAL_LEGACY)
    if lbPath then
      local ok = writeBoardFile(lbPath)
      if ok then
        pcall(fs.delete, LB_LOCAL_LEGACY)
        return "migrated"
      end
    end
    return "legacy"
  end
  return lbPath and "empty" or "no_disk"
end

local function saveLeaderboard()
  if not refreshLbDisk() then
    print("[tetris_lb] no floppy — score kept in RAM until a disk is inserted")
    return false
  end
  local ok, err = writeBoardFile(lbPath)
  if not ok then
    print("[tetris_lb] save failed: " .. tostring(err))
  end
  return ok
end

local function sortBoard()
  table.sort(leaderboard, function(a, b)
    if (a.score or 0) ~= (b.score or 0) then
      return (a.score or 0) > (b.score or 0)
    end
    return (a.at or 0) < (b.at or 0)
  end)
  while #leaderboard > LB_MAX do table.remove(leaderboard) end
end

-- Watch disk insert/eject so the board follows the floppy.
local function diskWatchLoop()
  while true do
    local ev = os.pullEvent()
    if ev == "disk" or ev == "disk_eject" or ev == "peripheral" or ev == "peripheral_detach" then
      local had = #leaderboard
      refreshLbDisk()
      if lbPath then
        if fs.exists(lbPath) then
          leaderboard = readBoardFile(lbPath)
          sortBoard()
          print(("[tetris_lb] disk ready (%s) — %d entr%s"):format(
            tostring(lbMount), #leaderboard, #leaderboard == 1 and "y" or "ies"))
        elseif had > 0 then
          -- Blank floppy: flush in-memory board onto it.
          writeBoardFile(lbPath)
          print(("[tetris_lb] wrote RAM board to %s (%d)"):format(tostring(lbMount), had))
        else
          leaderboard = {}
          print(("[tetris_lb] disk ready (%s) — empty board"):format(tostring(lbMount)))
        end
      else
        print("[tetris_lb] floppy removed — serving last scores from RAM (not saving)")
      end
    end
  end
end

local function boardSnapshot()
  local out = {}
  for i = 1, #leaderboard do
    local e = leaderboard[i]
    out[i] = {
      id = e.id, name = e.name, score = e.score, at = e.at, rank = i,
    }
  end
  return out
end

-- Upsert by player name (case-insensitive) so shared pockets track people, not HW.
local function submitScore(id, name, score)
  id = tonumber(id)
  score = math.floor(tonumber(score) or 0)
  if score < 0 then return false, "bad score" end
  name = tostring(name or ""):gsub("[%c%z]", ""):match("^%s*(.-)%s*$") or ""
  if name == "" then name = id and ("P" .. tostring(id)) or "Player" end
  name = name:sub(1, 16)
  local key = name:lower()
  local found = nil
  for i = 1, #leaderboard do
    if tostring(leaderboard[i].name or ""):lower() == key then
      found = i
      break
    end
  end
  if found then
    if score > (leaderboard[found].score or 0) then
      leaderboard[found].score = score
      leaderboard[found].name = name
      leaderboard[found].at = os.epoch("utc")
      if id then leaderboard[found].id = id end
    else
      -- keep best score; refresh display casing / last tablet id
      leaderboard[found].name = name
      if id then leaderboard[found].id = id end
    end
  else
    leaderboard[#leaderboard + 1] = {
      id = id, name = name, score = score, at = os.epoch("utc"),
    }
  end
  sortBoard()
  saveLeaderboard()
  return true
end

local function manifest()
  local m = {}
  for _, path in ipairs(FILES) do
    if fs.exists(path) and not fs.isDir(path) then
      m[#m + 1] = { path = path, size = fs.getSize(path) }
    end
  end
  return m
end

local function isServable(path)
  for _, p in ipairs(FILES) do if p == path then return true end end
  return false
end

local function readFile(path)
  if not isServable(path) or not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  local data = f.readAll()
  f.close()
  return data
end

openModem()
os.setComputerLabel(os.getComputerLabel() or ("TitanHost-" .. os.getComputerID()))
local lbSrc = loadLeaderboard()
sortBoard()

term.clear(); term.setCursorPos(1, 1)
print("== Titan Install Host ==")
print(("Serving %d files as '%s' (#%d)."):format(#manifest(), os.getComputerLabel(), os.getComputerID()))
if lbPath then
  print(("Tetris LB disk: %s (%s)"):format(tostring(lbMount), tostring(lbDriveName)))
  print(("Tetris leaderboard: %d entr%s [%s]"):format(
    #leaderboard, #leaderboard == 1 and "y" or "ies", tostring(lbSrc)))
else
  print("Tetris LB: NO FLOPPY — insert a disk in the drive to persist scores.")
  print(("Tetris leaderboard (RAM): %d entr%s"):format(
    #leaderboard, #leaderboard == 1 and "y" or "ies"))
end
print("Clients update over rednet + titan_router mesh (no GitHub URL on tablets).")
print("Mesh relay on. Ctrl+T to stop.")
print("")

local function replyHostHere(dest, viaId)
  dest = tonumber(dest)
  if not dest then return end
  local files = manifest()
  local label = os.getComputerLabel()
  local hostId = os.getComputerID()
  rednet.send(dest, {
    type = "host_here",
    label = label,
    files = files,
    tetrisLb = true,
    hostId = hostId,
  }, PROTOCOL)
  local mesh = {
    type = "install_host_here",
    hostId = hostId,
    label = label,
    files = files,
    tetrisLb = true,
    replyTo = dest,
    originId = dest,
    from = hostId,
  }
  rednet.send(dest, mesh, ROUTER_PROTOCOL)
  if viaId and viaId ~= dest then
    rednet.send(viaId, mesh, ROUTER_PROTOCOL)
    rednet.send(viaId, {
      type = "install_fwd",
      dest = dest,
      payload = mesh,
      replyTo = dest,
      from = hostId,
    }, ROUTER_PROTOCOL)
  end
end

local function replyFile(dest, path, viaId)
  dest = tonumber(dest)
  if not dest then return end
  local data = readFile(path)
  local hostId = os.getComputerID()
  rednet.send(dest, {
    type = "file", path = path, ok = data ~= nil, data = data,
  }, PROTOCOL)
  local mesh = {
    type = "install_file",
    path = path,
    ok = data ~= nil,
    data = data,
    replyTo = dest,
    originId = dest,
    from = hostId,
  }
  rednet.send(dest, mesh, ROUTER_PROTOCOL)
  if viaId and viaId ~= dest then
    rednet.send(viaId, mesh, ROUTER_PROTOCOL)
    rednet.send(viaId, {
      type = "install_fwd",
      dest = dest,
      payload = mesh,
      replyTo = dest,
      from = hostId,
    }, ROUTER_PROTOCOL)
  end
  print(("[get] %s -> #%d (%s)"):format(
    tostring(path), dest, data and (#data .. "b") or "missing"))
end

local function replyLb(dest, viaId)
  dest = tonumber(dest)
  if not dest then return end
  local payload = {
    type = "tetris_lb",
    ok = true,
    entries = boardSnapshot(),
    replyTo = dest,
    from = os.getComputerID(),
  }
  rednet.send(dest, payload, PROTOCOL)
  rednet.send(dest, payload, ROUTER_PROTOCOL)
  if viaId and viaId ~= dest then
    rednet.send(viaId, {
      type = "install_fwd",
      dest = dest,
      payload = payload,
      replyTo = dest,
    }, ROUTER_PROTOCOL)
  end
end

local function handleServeMsg(id, msg, proto)
  if type(msg) ~= "table" or not msg.type then return end
  local t = msg.type

  if t == "discover" or t == "install_discover" then
    local dest = tonumber(msg.originId) or tonumber(msg.replyTo) or id
    replyHostHere(dest, id)
    print(("[discover/%s] #%d -> reply #%d"):format(tostring(proto), id, dest))

  elseif t == "get" or t == "install_get" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    replyFile(dest, msg.path, id)

  elseif t == "tetris_lb_get" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    replyLb(dest, id)
    print(("[tetris_lb] get -> #%d (%d)"):format(dest, #leaderboard))

  elseif t == "tetris_lb_submit" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    local score = tonumber(msg.score) or 0
    local name = msg.name or msg.hostname or ("#" .. tostring(id))
    local ok = submitScore(msg.playerId or id, name, score)
    local payload = {
      type = "tetris_lb",
      ok = ok,
      entries = boardSnapshot(),
      accepted = ok,
      replyTo = dest,
      from = os.getComputerID(),
    }
    rednet.send(dest, payload, PROTOCOL)
    rednet.send(dest, payload, ROUTER_PROTOCOL)
    if id ~= dest then
      rednet.send(id, {
        type = "install_fwd",
        dest = dest,
        payload = payload,
        replyTo = dest,
      }, ROUTER_PROTOCOL)
    end
    print(("[tetris_lb] #%d %s = %d"):format(id, tostring(name):sub(1, 12), score))
  end
end

local function serveLoop()
  while true do
    local id, msg, proto = rednet.receive(nil)
    if proto == PROTOCOL or proto == ROUTER_PROTOCOL then
      handleServeMsg(id, msg, proto)
    end
  end
end

local tasks = { serveLoop, relayLoop, diskWatchLoop }
if fs.exists("lib/titan.lua") then
  local titan = dofile("lib/titan.lua")
  tasks[#tasks + 1] = function() titan.networkLoop("host") end
end
parallel.waitForAny(table.unpack(tasks))
