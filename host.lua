--[[
  host.lua  -  Titan install / update host + games leaderboards (CC: Tweaked)
  Titan-Version: 1.2.17

  Run this on ONE computer that already has the Titan files (your "update
  server"). It serves those files over rednet so pockets and other devices can
  install / OTA without storing any GitHub / wget URL on the clients.

  File serving uses both:
    * titan_install  — direct / local RF
    * titan_router   — mesh hops through your MAIN / extender / modem cells

  Leaderboards live on a floppy (`games_leaderboard.cfg`, multi-game). Legacy
  `tetris_leaderboard.cfg` is migrated once. Tetris still uses tetris_lb_* msgs.
  Admin edits use games_lb_admin_* (password in cfg; set from admin tablet).

  Usage:
    1. Keep this machine updated (you may wget/GitHub here — clients never see it).
    2. Wireless (or ender) modem + disk drive with floppy + run:  host
    3. Join the Titan router mesh (same as other devices).
    4. Give out tablets via install.lua role `t` (or disk copy).

  Only serves files on the published list. Ctrl+T to stop.
]]

local PROTOCOL = "titan_install"
local ROUTER_PROTOCOL = "titan_router"
local LB_NAME = "games_leaderboard.cfg"
local LB_LEGACY_TETRIS = "tetris_leaderboard.cfg"
local LB_LOCAL_LEGACY = "tetris_leaderboard.cfg" -- migrate once from computer FS
local LB_MAX = 25 -- keep extras; tablets only display top 3
local LB_DISK_LABEL = "Games LB"

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
  "quarry/workers/cell_scanner.lua",
  "quarry/managers/offline_site.lua",
  "storage/managers/storage_manager.lua",
  "storage/workers/storage_builder.lua",
  "storage/managers/storage_atm.lua",
  "storage_manager.lua",
  "storage_builder.lua",
  "storage_atm.lua",
  "offline_miner.lua",
  "offline_site.lua",
  "perimeter_sensor.lua",
  "perimeter_manager.lua",
  "tetris.lua",
  "minesweeper.lua",
  "sandstorm.lua",
  "luigi_poker.lua",
  "higher_lower.lua",
  "slots.lua",
  "lib/casino.lua",
  "lib/games_economy.lua",
  "games/managers/currency_manager.lua",
  "currency_manager.lua",
  "games/managers/casino_atm.lua",
  "casino_atm.lua",
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
-- Multi-game leaderboards (persisted on floppy disk)
--------------------------------------------------------------------------------
local boards = { tetris = {} } -- [gameId] = sorted { id, name, score, at }
local leaderboard = boards.tetris -- alias for Tetris compat
local lbPassword = "" -- admin password (empty = unset; deny admin ops until set)
local lbDriveName, lbMount, lbPath = nil, nil, nil

local function ensureGame(gameId)
  gameId = tostring(gameId or "tetris"):lower()
  if gameId == "" then gameId = "tetris" end
  if type(boards[gameId]) ~= "table" then boards[gameId] = {} end
  if gameId == "tetris" then leaderboard = boards.tetris end
  return gameId, boards[gameId]
end

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
          local legacy = fs.combine(mount, LB_LEGACY_TETRIS)
          if fs.exists(legacy) and not fs.isDir(legacy) and not anyMount then
            anyName, anyMount = name, mount
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

local function readEntriesList(d)
  if type(d) ~= "table" then return {} end
  if type(d.entries) == "table" then return d.entries end
  -- bare array?
  if d[1] and type(d[1]) == "table" and d[1].score ~= nil then return d end
  return {}
end

local function readLbStore(path)
  if not path or not fs.exists(path) or fs.isDir(path) then return "", {} end
  local f = fs.open(path, "r")
  if not f then return "", {} end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return "", {} end
  local pw = type(d.password) == "string" and d.password or ""
  if type(d.games) == "table" then
    local out = {}
    for gid, block in pairs(d.games) do
      out[tostring(gid)] = readEntriesList(type(block) == "table" and block or {})
    end
    return pw, out
  end
  -- Legacy single-board tetris file
  local entries = readEntriesList(d)
  if #entries > 0 or d.entries then
    return pw, { tetris = entries }
  end
  return pw, {}
end

local function readAllBoards(path)
  local _, games = readLbStore(path)
  return games
end

local function writeBoardFile(path)
  if not path then return false, "no disk" end
  local f = fs.open(path, "w")
  if not f then return false, "open failed" end
  f.write(textutils.serialize({ password = lbPassword, games = boards }))
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

local function sortBoard(gameId)
  local _, list = ensureGame(gameId or "tetris")
  table.sort(list, function(a, b)
    if (a.score or 0) ~= (b.score or 0) then
      return (a.score or 0) > (b.score or 0)
    end
    return (a.at or 0) < (b.at or 0)
  end)
  while #list > LB_MAX do table.remove(list) end
end

local function sortAllBoards()
  for gid in pairs(boards) do sortBoard(gid) end
  leaderboard = boards.tetris or {}
end

local function boardCount()
  local n = 0
  for _, list in pairs(boards) do n = n + #list end
  return n
end

local function loadLeaderboard()
  boards = { tetris = {} }
  leaderboard = boards.tetris
  lbPassword = ""
  refreshLbDisk()
  if lbPath and fs.exists(lbPath) then
    lbPassword, boards = readLbStore(lbPath)
    ensureGame("tetris")
    sortAllBoards()
    return "disk"
  end
  -- Migrate legacy tetris file on floppy or computer FS.
  local legacyPath = nil
  if lbMount then
    local p = fs.combine(lbMount, LB_LEGACY_TETRIS)
    if fs.exists(p) and not fs.isDir(p) then legacyPath = p end
  end
  if not legacyPath and fs.exists(LB_LOCAL_LEGACY) and not fs.isDir(LB_LOCAL_LEGACY) then
    legacyPath = LB_LOCAL_LEGACY
  end
  if legacyPath then
    local old = readAllBoards(legacyPath)
    if old.tetris then boards.tetris = old.tetris else boards.tetris = {} end
    ensureGame("tetris")
    sortAllBoards()
    if lbPath then
      local ok = writeBoardFile(lbPath)
      if ok then
        if legacyPath == LB_LOCAL_LEGACY then pcall(fs.delete, LB_LOCAL_LEGACY) end
        return "migrated"
      end
    end
    return "legacy"
  end
  return lbPath and "empty" or "no_disk"
end

local function saveLeaderboard()
  if not refreshLbDisk() then
    print("[games_lb] no floppy — score kept in RAM until a disk is inserted")
    return false
  end
  local ok, err = writeBoardFile(lbPath)
  if not ok then
    print("[games_lb] save failed: " .. tostring(err))
  end
  return ok
end

-- Watch disk insert/eject so the board follows the floppy.
local function diskWatchLoop()
  while true do
    local ev = os.pullEvent()
    if ev == "disk" or ev == "disk_eject" or ev == "peripheral" or ev == "peripheral_detach" then
      local had = boardCount()
      refreshLbDisk()
      if lbPath then
        if fs.exists(lbPath) then
          lbPassword, boards = readLbStore(lbPath)
          ensureGame("tetris")
          sortAllBoards()
          print(("[games_lb] disk ready (%s) — %d entr%s"):format(
            tostring(lbMount), boardCount(), boardCount() == 1 and "y" or "ies"))
        elseif had > 0 then
          writeBoardFile(lbPath)
          print(("[games_lb] wrote RAM board to %s (%d)"):format(tostring(lbMount), had))
        else
          boards = { tetris = {} }
          leaderboard = boards.tetris
          print(("[games_lb] disk ready (%s) — empty board"):format(tostring(lbMount)))
        end
      else
        print("[games_lb] floppy removed — serving last scores from RAM (not saving)")
      end
    end
  end
end

local function boardSnapshot(gameId)
  local _, list = ensureGame(gameId or "tetris")
  local out = {}
  for i = 1, #list do
    local e = list[i]
    out[i] = {
      id = e.id, name = e.name, score = e.score, at = e.at, rank = i,
    }
  end
  return out
end

-- Upsert by player name (case-insensitive). Lower score is better when lowerIsBetter.
local function submitScore(id, name, score, gameId, lowerIsBetter)
  local gid, list = ensureGame(gameId or "tetris")
  id = tonumber(id)
  score = math.floor(tonumber(score) or 0)
  if score < 0 then return false, "bad score" end
  name = tostring(name or ""):gsub("[%c%z]", ""):match("^%s*(.-)%s*$") or ""
  if name == "" then name = id and ("P" .. tostring(id)) or "Player" end
  name = name:sub(1, 16)
  local key = name:lower()
  local found = nil
  for i = 1, #list do
    if tostring(list[i].name or ""):lower() == key then
      found = i
      break
    end
  end
  local function better(new, old)
    if lowerIsBetter then return new < old end
    return new > old
  end
  if found then
    if better(score, list[found].score or (lowerIsBetter and 1e12 or -1)) then
      list[found].score = score
      list[found].name = name
      list[found].at = os.epoch("utc")
      if id then list[found].id = id end
    else
      list[found].name = name
      if id then list[found].id = id end
    end
  else
    list[#list + 1] = {
      id = id, name = name, score = score, at = os.epoch("utc"),
    }
  end
  sortBoard(gid)
  if gid == "tetris" then leaderboard = boards.tetris end
  saveLeaderboard()
  return true
end

local function lbPassSet()
  return type(lbPassword) == "string" and lbPassword ~= ""
end

local function checkLbAdminPass(msg)
  if not lbPassSet() then return false, "no password set" end
  local pw = tostring(msg.password or "")
  if pw == "" then return false, "password required" end
  if pw ~= lbPassword then return false, "denied" end
  return true
end

local function adminBoardSnapshot()
  local out = {}
  for gid in pairs(boards) do
    out[gid] = boardSnapshot(gid)
  end
  return out
end

local function deleteLbEntry(gameId, which)
  local gid, list = ensureGame(gameId or "tetris")
  local rank = tonumber(which)
  if rank then
    if rank < 1 or rank > #list then return false, "bad rank" end
    table.remove(list, rank)
    sortBoard(gid)
    if gid == "tetris" then leaderboard = boards.tetris end
    saveLeaderboard()
    return true
  end
  local key = tostring(which or ""):lower()
  if key == "" then return false, "need rank or name" end
  for i = 1, #list do
    if tostring(list[i].name or ""):lower() == key then
      table.remove(list, i)
      sortBoard(gid)
      if gid == "tetris" then leaderboard = boards.tetris end
      saveLeaderboard()
      return true
    end
  end
  return false, "not found"
end

local function editLbEntry(gameId, which, newScore, newName)
  local gid, list = ensureGame(gameId or "tetris")
  local rank = tonumber(which)
  local entry
  if rank then
    if rank < 1 or rank > #list then return false, "bad rank" end
    entry = list[rank]
  else
    local key = tostring(which or ""):lower()
    if key == "" then return false, "need rank or name" end
    for i = 1, #list do
      if tostring(list[i].name or ""):lower() == key then
        entry = list[i]
        break
      end
    end
    if not entry then return false, "not found" end
  end
  if newScore ~= nil then
    newScore = math.floor(tonumber(newScore) or -1)
    if newScore < 0 then return false, "bad score" end
    entry.score = newScore
    entry.at = os.epoch("utc")
  end
  if newName ~= nil then
    newName = tostring(newName or ""):gsub("[%c%z]", ""):match("^%s*(.-)%s*$") or ""
    if newName == "" then return false, "bad name" end
    entry.name = newName:sub(1, 16)
  end
  sortBoard(gid)
  if gid == "tetris" then leaderboard = boards.tetris end
  saveLeaderboard()
  return true
end

local function clearLbBoard(gameId)
  if gameId == "all" or gameId == "*" or gameId == "" then
    boards = { tetris = {} }
    leaderboard = boards.tetris
  else
    local gid = ensureGame(gameId)
    boards[gid] = {}
    if gid == "tetris" then leaderboard = boards.tetris end
  end
  sortAllBoards()
  saveLeaderboard()
  return true
end

local function replyLbAdmin(dest, viaId, payload)
  dest = tonumber(dest)
  if not dest or type(payload) ~= "table" then return end
  payload.type = "games_lb_admin"
  payload.replyTo = dest
  payload.from = os.getComputerID()
  rednet.send(dest, payload, PROTOCOL)
  rednet.send(dest, payload, ROUTER_PROTOCOL)
  if viaId and viaId ~= dest then
    rednet.send(viaId, {
      type = "install_fwd",
      dest = dest,
      payload = payload,
      replyTo = dest,
      from = os.getComputerID(),
    }, ROUTER_PROTOCOL)
  end
end

local function deliverGamesLb(dest, viaId, payload)
  dest = tonumber(dest)
  if not dest or type(payload) ~= "table" then return end
  payload.replyTo = dest
  payload.from = os.getComputerID()
  rednet.send(dest, payload, PROTOCOL)
  rednet.send(dest, payload, ROUTER_PROTOCOL)
  if viaId and viaId ~= dest then
    rednet.send(viaId, {
      type = "install_fwd",
      dest = dest,
      payload = payload,
      replyTo = dest,
      from = os.getComputerID(),
    }, ROUTER_PROTOCOL)
  end
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
sortAllBoards()

term.clear(); term.setCursorPos(1, 1)
print("== Titan Install Host ==")
print(("Serving %d files as '%s' (#%d)."):format(#manifest(), os.getComputerLabel(), os.getComputerID()))
if lbPath then
  print(("Games LB disk: %s (%s)"):format(tostring(lbMount), tostring(lbDriveName)))
  print(("Leaderboard entries: %d [%s]"):format(boardCount(), tostring(lbSrc)))
else
  print("Games LB: NO FLOPPY — insert a disk in the drive to persist scores.")
  print(("Leaderboard (RAM): %d entr%s"):format(
    boardCount(), boardCount() == 1 and "y" or "ies"))
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
    entries = boardSnapshot("tetris"),
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
    print(("[tetris_lb] get -> #%d (%d)"):format(dest, #(boards.tetris or {})))

  elseif t == "tetris_lb_submit" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    local score = tonumber(msg.score) or 0
    local name = msg.name or msg.hostname or ("#" .. tostring(id))
    local ok = submitScore(msg.playerId or id, name, score, "tetris", false)
    local payload = {
      type = "tetris_lb",
      ok = ok,
      entries = boardSnapshot("tetris"),
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

  elseif t == "games_lb_get" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    local game = tostring(msg.game or "tetris"):lower()
    local payload = {
      type = "games_lb",
      ok = true,
      game = game,
      entries = boardSnapshot(game),
      replyTo = dest,
      from = os.getComputerID(),
    }
    deliverGamesLb(dest, id, payload)
    print(("[games_lb] get %s -> #%d (%d)"):format(game, dest, #boardSnapshot(game)))

  elseif t == "games_lb_submit" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    local game = tostring(msg.game or "tetris"):lower()
    local score = tonumber(msg.score) or 0
    local name = msg.name or msg.hostname or ("#" .. tostring(id))
    local lower = msg.lowerIsBetter == true or game == "minesweeper"
    local ok = submitScore(msg.playerId or id, name, score, game, lower)
    local payload = {
      type = "games_lb",
      ok = ok,
      game = game,
      entries = boardSnapshot(game),
      accepted = ok,
      replyTo = dest,
      from = os.getComputerID(),
    }
    deliverGamesLb(dest, id, payload)
    print(("[games_lb] %s #%d %s = %d"):format(game, id, tostring(name):sub(1, 12), score))

  elseif t == "games_lb_admin_get" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    if lbPassSet() then
      local ok, err = checkLbAdminPass(msg)
      if not ok then
        replyLbAdmin(dest, id, { ok = false, err = err })
        print(("[games_lb_admin] get denied -> #%d (%s)"):format(dest, tostring(err)))
        return
      end
    else
      replyLbAdmin(dest, id, { ok = false, err = "no password set" })
      print(("[games_lb_admin] get denied -> #%d (no password)"):format(dest))
      return
    end
    replyLbAdmin(dest, id, {
      ok = true,
      passwordSet = true,
      disk = lbPath ~= nil,
      games = adminBoardSnapshot(),
    })
    print(("[games_lb_admin] get -> #%d"):format(dest))

  elseif t == "games_lb_admin_setpass" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    local newPw = tostring(msg.newPassword or "")
    if lbPassSet() then
      local old = tostring(msg.oldPassword or msg.password or "")
      if old ~= lbPassword then
        replyLbAdmin(dest, id, { ok = false, err = "denied" })
        print(("[games_lb_admin] setpass denied -> #%d"):format(dest))
        return
      end
    end
    lbPassword = newPw
    saveLeaderboard()
    replyLbAdmin(dest, id, { ok = true, passwordSet = lbPassword ~= "" })
    print(("[games_lb_admin] setpass -> #%d (%s)"):format(
      dest, lbPassword ~= "" and "set" or "cleared"))

  elseif t == "games_lb_admin_delete" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    local okAuth, err = checkLbAdminPass(msg)
    if not okAuth then
      replyLbAdmin(dest, id, { ok = false, err = err })
      return
    end
    local game = tostring(msg.game or "tetris"):lower()
    local which = msg.rank or msg.which or msg.player
    local okDel, errDel = deleteLbEntry(game, which)
    replyLbAdmin(dest, id, {
      ok = okDel,
      err = errDel,
      game = game,
      games = adminBoardSnapshot(),
    })
    print(("[games_lb_admin] delete %s %s -> #%d (%s)"):format(
      game, tostring(which), dest, okDel and "ok" or tostring(errDel)))

  elseif t == "games_lb_admin_edit" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    local okAuth, err = checkLbAdminPass(msg)
    if not okAuth then
      replyLbAdmin(dest, id, { ok = false, err = err })
      return
    end
    local game = tostring(msg.game or "tetris"):lower()
    local which = msg.rank or msg.which or msg.player
    local okEdit, errEdit = editLbEntry(game, which, msg.score, msg.newName)
    replyLbAdmin(dest, id, {
      ok = okEdit,
      err = errEdit,
      game = game,
      games = adminBoardSnapshot(),
    })
    print(("[games_lb_admin] edit %s %s -> #%d (%s)"):format(
      game, tostring(which), dest, okEdit and "ok" or tostring(errEdit)))

  elseif t == "games_lb_admin_clear" then
    local dest = tonumber(msg.replyTo) or tonumber(msg.originId) or id
    local okAuth, err = checkLbAdminPass(msg)
    if not okAuth then
      replyLbAdmin(dest, id, { ok = false, err = err })
      return
    end
    local game = msg.game
    if game ~= nil then game = tostring(game):lower() end
    if game == "" then game = "all" end
    clearLbBoard(game or "all")
    replyLbAdmin(dest, id, {
      ok = true,
      game = game or "all",
      games = adminBoardSnapshot(),
    })
    print(("[games_lb_admin] clear %s -> #%d"):format(tostring(game or "all"), dest))
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
