--[[
  router_main.lua  -  Titan MAIN / ROUTER hub runtime (CC: Tweaked)
  Titan-Version: 1.4.2

  Hub roles (loaded by router.lua when role is main or router):

    MAIN   - directory, OTA, re-auth, GPS, ender backbone hub, monitor boards.
    ROUTER - ender backbone satellite; hosts local RF modem cells.

  Implementation is split across lib/router_hub_*.lua parts loaded into one
  shared environment so Cobalt's 200-local-per-function limit is not hit.

  MODEM cells use router_modem.lua. Prefer: run `router`.
]]

local PROTO_ROUTER = "titan_router"
local REPEAT       = rednet.CHANNEL_REPEAT
local BROADCAST    = rednet.CHANNEL_BROADCAST
local WIRED_CH     = 65012
local WIRED_FRESH  = 45

local function isWiredSide(side)
  if not side or not peripheral.isPresent(side) then return false end
  if peripheral.getType(side) ~= "modem" then return false end
  local ok, wireless = pcall(peripheral.call, side, "isWireless")
  return ok and wireless == false
end

local modems, wiredModems, wirelessModems = {}, {}, {}
local wiredDirect = {}

for _, side in ipairs(peripheral.getNames()) do
  if peripheral.getType(side) == "modem" then
    modems[#modems + 1] = side
    if not rednet.isOpen(side) then rednet.open(side) end
    peripheral.call(side, "open", REPEAT)
    if isWiredSide(side) then
      wiredModems[#wiredModems + 1] = side
      peripheral.call(side, "open", WIRED_CH)
    else
      wirelessModems[#wirelessModems + 1] = side
    end
  end
end
if #modems == 0 then
  error("No modem attached. Put a wireless or wired modem on this computer.", 0)
end

os.setComputerLabel(os.getComputerLabel() or ("Router-" .. os.getComputerID()))

--------------------------------------------------------------------------------
-- Shared hub environment (parts assign functions / mutate state here)
--------------------------------------------------------------------------------
local R = {
  PROTO_ROUTER = PROTO_ROUTER,
  REPEAT = REPEAT,
  BROADCAST = BROADCAST,
  WIRED_CH = WIRED_CH,
  WIRED_FRESH = WIRED_FRESH,
  titanLib = nil,
  modems = modems,
  wiredModems = wiredModems,
  wirelessModems = wirelessModems,
  wiredDirect = wiredDirect,
  isWiredSide = isWiredSide,
  BOOT_EPOCH = os.epoch("utc"),
  seen = {},
  relayed = {},
  relayStats = { relayed = 0 },
  rosterDirty = false,
  ONLINE_SECS = 45,
  SCREEN_ROLES = { "roster", "global", "stats", "gps", "map" },
  screens = { roster = nil, global = nil, stats = nil, gps = nil, map = nil },
  screenNames = { roster = nil, global = nil, stats = nil, gps = nil, map = nil },
  screenOn = { roster = false, global = false, stats = false, gps = false, map = false },
  screenPerm = { roster = false, global = false, stats = false, gps = false, map = false },
  screenFocus = "roster",
  displayMon = nil,
  displayMonName = nil,
  SAVER_TEXT = "TitanSystems",
  saverIdleSecs = 120,
  monRate = 1,
  boardWakeAt = nil,
  saverActive = false,
  saverState = {},
  RCFG = "router.cfg",
  ROSTER = "router_roster.cfg",
  gpsCoords = nil,
  routerRole = "main",
  netPeers = {},
  netCells = {},
  homeRouterId = nil,
  mapScale = 8,
}

setmetatable(R, { __index = _G })

function R.clampMonRate(secs)
  local titanLib = R.titanLib
  local monRate = R.monRate
  if titanLib and titanLib.normalizeMonRate then
    return titanLib.normalizeMonRate(secs, monRate)
  end
  local n = tonumber(secs)
  if not n or n ~= n then return monRate end
  if n < 0.25 then n = 0.25 end
  if n > 120 then n = 120 end
  return n
end

local function loadPart(path)
  if not fs.exists(path) then
    error("Missing " .. path .. " — run `router` bootstrap to auto-install hub parts.", 0)
  end
  local fn, err = loadfile(path)
  if not fn then error(path .. ": " .. tostring(err), 0) end
  setfenv(fn, R)
  local ok, perr = pcall(fn)
  if not ok then error(path .. ": " .. tostring(perr), 0) end
end

loadPart("lib/router_hub_net.lua")
loadPart("lib/router_hub_ui.lua")
loadPart("lib/router_hub_cmd.lua")

if type(R.runHub) ~= "function" then
  error("hub parts loaded but runHub() missing", 0)
end
R.runHub()
