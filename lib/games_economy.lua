--[[
  lib/games_economy.lua  -  Managed vs unmanaged casino economy
  Titan-Version: 1.0.0

  Written by the Games launcher on first setup.
    managed   — in-game currency via Currency Manager (mesh)
    unmanaged — local shared chip wallet (granted once)

  Files:
    games_economy.cfg  { setupDone, mode, grant }
    games_wallet.cfg   { coins }   (unmanaged balance shared by gambling games)
]]

local ECON_FILE = "games_economy.cfg"
local WALLET_FILE = "games_wallet.cfg"
local DEFAULT_GRANT = 10000

local M = {
  mode = nil,       -- "managed" | "unmanaged"
  setupDone = false,
  grant = DEFAULT_GRANT,
  DEFAULT_GRANT = DEFAULT_GRANT,
}

function M.load()
  if not fs.exists(ECON_FILE) then return M end
  local f = fs.open(ECON_FILE, "r")
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return M end
  M.setupDone = d.setupDone == true
  if d.mode == "managed" or d.mode == "unmanaged" then M.mode = d.mode end
  M.grant = math.max(1, math.floor(tonumber(d.grant) or DEFAULT_GRANT))
  return M
end

function M.save()
  local f = fs.open(ECON_FILE, "w")
  f.write(textutils.serialize({
    setupDone = M.setupDone == true,
    mode = M.mode,
    grant = M.grant,
  }))
  f.close()
end

function M.isManaged()
  return M.mode == "managed"
end

function M.isUnmanaged()
  return M.mode == "unmanaged"
end

function M.setMode(mode, grant)
  if mode ~= "managed" and mode ~= "unmanaged" then return false end
  M.mode = mode
  M.setupDone = true
  if grant then M.grant = math.max(1, math.floor(tonumber(grant) or DEFAULT_GRANT)) end
  M.save()
  if mode == "unmanaged" then
    M.ensureWallet(M.grant, true) -- grant only if wallet missing
  end
  return true
end

function M.getCoins()
  if not fs.exists(WALLET_FILE) then return nil end
  local f = fs.open(WALLET_FILE, "r")
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return nil end
  return math.max(0, math.floor(tonumber(d.coins) or 0))
end

function M.setCoins(n)
  n = math.max(0, math.floor(tonumber(n) or 0))
  local f = fs.open(WALLET_FILE, "w")
  f.write(textutils.serialize({ coins = n }))
  f.close()
  return n
end

-- If forceGrant, always set to grant amount; else only create when missing.
function M.ensureWallet(grant, onlyIfMissing)
  grant = math.max(1, math.floor(tonumber(grant) or M.grant or DEFAULT_GRANT))
  if onlyIfMissing and fs.exists(WALLET_FILE) then
    return M.getCoins() or grant
  end
  return M.setCoins(grant)
end

return M
