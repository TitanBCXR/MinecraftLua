--[[
  lib/casino.lua  -  Thin client for Currency Manager chips
  Titan-Version: 1.0.0

  Usage from a game (modem mode, not --speaker):

    local casino = dofile("lib/casino.lua")
    casino.open()
    local chips = casino.ensurePlayer()  -- prompts name, fetches balance
    if casino.bet(5) then ... end
    casino.payout(10)
    local n = casino.chips()
]]

local PROTO = "titan_install"
local ROUTER = "titan_router"
local M = {
  player = nil,
  managerId = nil,
  balance = nil,
  online = false,
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

function M.setPlayer(name)
  name = tostring(name or ""):gsub("[%c%z]", ""):match("^%s*(.-)%s*$") or ""
  if name == "" then return false end
  M.player = name:sub(1, 24)
  return true
end

function M.ensurePlayer()
  if M.player then
    M.fetchBalance()
    return M.chips()
  end
  if fs.exists("casino_player.cfg") then
    local f = fs.open("casino_player.cfg", "r")
    local d = textutils.unserialize(f.readAll() or "")
    f.close()
    if type(d) == "table" and d.name then M.player = d.name end
  end
  if not M.player then
    print("Casino player name:")
    write("> ")
    local n = read()
    if not M.setPlayer(n) then return nil, "no name" end
    local f = fs.open("casino_player.cfg", "w")
    f.write(textutils.serialize({ name = M.player }))
    f.close()
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
