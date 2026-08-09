--[[
  lib/casino.lua  -  Thin client for Currency Manager chips
  Titan-Version: 1.0.1

  Usage from a game (modem mode, not --speaker):

    local casino = dofile("lib/casino.lua")
    casino.open()
    local chips = casino.ensurePlayer()  -- detector / name, then balance
    if casino.bet(5) then ... end
    casino.payout(10)
    local n = casino.chips()

  Identity (managed cabinets):
    Advanced Peripherals Player Detector next to the game PC → nearby player
    name, then Currency Manager balance over the mesh. Falls back to typed
    name only when no detector is present (or none in range → prompt).
]]

local PROTO = "titan_install"
local ROUTER = "titan_router"
local PLAYER_RANGE = 8
local PLAYER_CFG = "casino_player.cfg"

local M = {
  player = nil,
  managerId = nil,
  balance = nil,
  online = false,
  detected = false, -- true when name came from Player Detector this session
}

local function openModem()
  local found = false
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      pcall(peripheral.call, side, "open", rednet.CHANNEL_REPEAT)
      found = true
    end
  end
  return found
end

function M.open()
  M.online = openModem()
  return M.online
end

function M.discover(timeout)
  timeout = timeout or 2
  if not M.online and not M.open() then return nil end
  rednet.broadcast({ type = "casino_ping", from = os.getComputerID() }, PROTO)
  rednet.broadcast({ type = "casino_ping", from = os.getComputerID() }, ROUTER)
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg = rednet.receive(nil, math.max(0.05, deadline - os.clock()))
    if id and type(msg) == "table" and (msg.type == "casino_hello") then
      M.managerId = id
      return id
    end
  end
  return M.managerId
end

local function req(msgType, fields, expect, timeout)
  timeout = timeout or 3
  if not M.managerId then M.discover(1.5) end
  if not M.managerId then return nil, "no casino manager" end
  local payload = {
    type = msgType,
    from = os.getComputerID(),
    replyTo = os.getComputerID(),
    player = M.player,
  }
  if type(fields) == "table" then
    for k, v in pairs(fields) do payload[k] = v end
  end
  rednet.send(M.managerId, payload, PROTO)
  rednet.send(M.managerId, payload, ROUTER)
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local id, msg = rednet.receive(nil, math.max(0.05, deadline - os.clock()))
    if id == M.managerId and type(msg) == "table" and msg.type == expect then
      return msg
    end
  end
  return nil, "timeout"
end

function M.fetchBalance()
  local msg, err = req("casino_balance_req", nil, "casino_balance", 3)
  if not msg then return nil, err end
  M.balance = tonumber(msg.chips) or 0
  return M.balance
end

function M.chips()
  return tonumber(M.balance) or 0
end

local function normalizePlayer(p)
  if type(p) == "string" then
    p = p:gsub("[%c%z]", ""):match("^%s*(.-)%s*$") or ""
    if p == "" then return nil end
    return p:sub(1, 24)
  end
  if type(p) == "table" then
    return normalizePlayer(p.name or p.displayName or p.username)
  end
  return nil
end

local function findDetector()
  local pd = peripheral.find("playerDetector")
  if pd then return pd end
  return peripheral.find("player_detector")
end

local function playerDistanceSq(pd, name)
  if type(pd.getPlayerPos) ~= "function" then return nil end
  local ok, pos = pcall(function() return pd.getPlayerPos(name) end)
  if not ok or type(pos) ~= "table" then return nil end
  local x = tonumber(pos.x or pos.X)
  local y = tonumber(pos.y or pos.Y)
  local z = tonumber(pos.z or pos.Z)
  if not x or not y or not z then return nil end
  -- Detector is block-centric; distance from detector origin is fine for ranking.
  return x * x + y * y + z * z
end

--- Nearby player via Advanced Peripherals Player Detector (or nil).
function M.detectPlayer(range)
  range = tonumber(range) or PLAYER_RANGE
  local pd = findDetector()
  if not pd then return nil, "no detector" end

  local names = {}
  local ok, players = pcall(function() return pd.getPlayersInRange(range) end)
  if ok and type(players) == "table" then
    for _, p in ipairs(players) do
      local n = normalizePlayer(p)
      if n then names[#names + 1] = n end
    end
  end

  if #names == 0 then
    return nil, "none in range"
  end
  if #names == 1 then
    return names[1]
  end

  local best, bestD = names[1], nil
  for i = 1, #names do
    local d = playerDistanceSq(pd, names[i])
    if d and (not bestD or d < bestD) then
      best, bestD = names[i], d
    end
  end
  return best
end

local function savePlayerCfg(name)
  local f = fs.open(PLAYER_CFG, "w")
  if f then
    f.write(textutils.serialize({ name = name }))
    f.close()
  end
end

local function loadPlayerCfg()
  if not fs.exists(PLAYER_CFG) then return nil end
  local f = fs.open(PLAYER_CFG, "r")
  if not f then return nil end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) == "table" then return normalizePlayer(d.name) end
  return nil
end

function M.setPlayer(name)
  local n = normalizePlayer(name)
  if not n then return false end
  M.player = n
  return true
end

local function promptPlayer(hint)
  if hint then print(hint) end
  print("Casino player name:")
  write("> ")
  local n = read()
  if not M.setPlayer(n) then return false end
  M.detected = false
  savePlayerCfg(M.player)
  return true
end

function M.ensurePlayer()
  M.detected = false
  local pd = findDetector()
  local detected = select(1, M.detectPlayer(PLAYER_RANGE))

  if detected then
    M.setPlayer(detected)
    M.detected = true
    savePlayerCfg(M.player)
  elseif pd then
    -- Detector present but nobody in range: never reuse a sticky cfg name.
    print("Stand closer to the Player Detector.")
    if not promptPlayer(nil) then return nil, "no name" end
  else
    -- No detector: cfg, then typed name.
    if not M.player then
      local cached = loadPlayerCfg()
      if cached then M.player = cached end
    end
    if not M.player then
      if not promptPlayer("No Player Detector — enter name.") then
        return nil, "no name"
      end
    end
  end

  if not M.discover(2) then
    return nil, "no casino manager on mesh"
  end
  local bal, err = M.fetchBalance()
  if bal == nil then return nil, err end
  return bal
end

function M.bet(amount)
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then return false, "bad bet" end
  local msg, err = req("casino_bet", { amount = amount }, "casino_ack", 4)
  if not msg then return false, err end
  if not msg.ok then return false, msg.err or "denied" end
  M.balance = tonumber(msg.chips) or M.balance
  return true, M.balance
end

function M.payout(amount)
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then
    M.fetchBalance()
    return true, M.balance
  end
  local msg, err = req("casino_payout", { amount = amount }, "casino_ack", 4)
  if not msg then return false, err end
  if not msg.ok then return false, msg.err or "denied" end
  M.balance = tonumber(msg.chips) or M.balance
  return true, M.balance
end

return M
