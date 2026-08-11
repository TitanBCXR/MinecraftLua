--[[
  pocket_peripherals.lua  -  Pocket modem / speaker slot helpers (Titan games)
  Titan-Version: 1.0.0

  Reserved inventory slots for pocket PCs (16-slot hotbar):
    MODEM_SLOT   = 15  (wireless modem home — equip for mesh / host LB)
    SPEAKER_SLOT = 16  (speaker home — swap onto back for music)

  Press S in the Games launcher or Tetris menu to swap the back upgrade between
  modem and speaker. Items are parked in the home slots first; if misplaced,
  they are found by item name and moved home.

  Config (optional) in games_launcher.cfg:
    modemSlot = 15, speakerSlot = 16
]]

local pp = {}

local STATE_FILE = "games_launcher.cfg"
local DEFAULT_MODEM_SLOT = 15
local DEFAULT_SPEAKER_SLOT = 16

local MODEM_SLOT = DEFAULT_MODEM_SLOT
local SPEAKER_SLOT = DEFAULT_SPEAKER_SLOT

local function itemDetail(slot)
  if not turtle or type(turtle.getItemDetail) ~= "function" then return nil end
  local ok, d = pcall(turtle.getItemDetail, slot)
  if ok then return d end
  return nil
end

local function itemCount(slot)
  if not turtle or type(turtle.getItemCount) ~= "function" then return 0 end
  return turtle.getItemCount(slot) or 0
end

local function selectSlot(slot)
  if turtle and type(turtle.select) == "function" then
    turtle.select(slot)
  end
end

function pp.isModemItem(detail)
  if type(detail) ~= "table" or not detail.name then return false end
  return tostring(detail.name):lower():find("modem", 1, true) ~= nil
end

function pp.isSpeakerItem(detail)
  if type(detail) ~= "table" or not detail.name then return false end
  return tostring(detail.name):lower():find("speaker", 1, true) ~= nil
end

function pp.hasModem()
  for _, name in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(name)
    if t == "modem" or t == "wired_modem" or t == "wireless_modem" then
      return true
    end
  end
  return false
end

function pp.findSpeaker()
  return peripheral.find("speaker")
end

function pp.getSlots()
  return MODEM_SLOT, SPEAKER_SLOT
end

function pp.setupHelp()
  return ("Modem slot %d, speaker slot %d — S swaps sound on/off"):format(
    MODEM_SLOT, SPEAKER_SLOT)
end

function pp.loadConfig()
  MODEM_SLOT = DEFAULT_MODEM_SLOT
  SPEAKER_SLOT = DEFAULT_SPEAKER_SLOT
  if not fs.exists(STATE_FILE) then return end
  local f = fs.open(STATE_FILE, "r")
  if not f then return end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return end
  local ms = tonumber(d.modemSlot)
  local ss = tonumber(d.speakerSlot)
  if ms and ms >= 1 and ms <= 16 then MODEM_SLOT = math.floor(ms) end
  if ss and ss >= 1 and ss <= 16 then SPEAKER_SLOT = math.floor(ss) end
  if MODEM_SLOT == SPEAKER_SLOT then
    SPEAKER_SLOT = DEFAULT_SPEAKER_SLOT
    if MODEM_SLOT == SPEAKER_SLOT then MODEM_SLOT = DEFAULT_MODEM_SLOT end
  end
end

function pp.saveSlots(modemSlot, speakerSlot)
  pp.loadConfig()
  if modemSlot then MODEM_SLOT = modemSlot end
  if speakerSlot then SPEAKER_SLOT = speakerSlot end
  local d = {}
  if fs.exists(STATE_FILE) then
    local f = fs.open(STATE_FILE, "r")
    if f then
      d = textutils.unserialize(f.readAll() or "") or {}
      f.close()
    end
  end
  if type(d) ~= "table" then d = {} end
  d.modemSlot = MODEM_SLOT
  d.speakerSlot = SPEAKER_SLOT
  local f = fs.open(STATE_FILE, "w")
  if f then
    f.write(textutils.serialize(d))
    f.close()
  end
end

local function inventorySize()
  return 16
end

local function findItemSlot(pred, skipSlot)
  if pred(itemDetail(MODEM_SLOT)) and MODEM_SLOT ~= skipSlot then return MODEM_SLOT end
  if pred(itemDetail(SPEAKER_SLOT)) and SPEAKER_SLOT ~= skipSlot then return SPEAKER_SLOT end
  for s = 1, inventorySize() do
    if s ~= skipSlot and pred(itemDetail(s)) then return s end
  end
  return nil
end

function pp.findModemSlot()
  return findItemSlot(pp.isModemItem)
end

function pp.findSpeakerSlot()
  return findItemSlot(pp.isSpeakerItem)
end

local function findEmptySlot(exclude)
  exclude = exclude or {}
  local skip = {}
  skip[exclude] = true
  skip[MODEM_SLOT] = true
  skip[SPEAKER_SLOT] = true
  for s = 1, inventorySize() do
    if not skip[s] and itemCount(s) == 0 then return s end
  end
  return nil
end

local function moveStackToSlot(fromSlot, toSlot)
  if not fromSlot or not toSlot or fromSlot == toSlot then return true end
  if itemCount(fromSlot) == 0 then return false end
  selectSlot(fromSlot)
  if itemCount(toSlot) == 0 then
    return turtle.transferTo(toSlot) == true
  end
  local empty = findEmptySlot(toSlot)
  if not empty then return false end
  selectSlot(toSlot)
  if not turtle.transferTo(empty) then return false end
  selectSlot(fromSlot)
  return turtle.transferTo(toSlot) == true
end

local function parkToHome(homeSlot, findFn, isItemFn)
  local src = findFn()
  if not src then return false end
  if src == homeSlot then return true end
  local homeDetail = itemDetail(homeSlot)
  if itemCount(homeSlot) > 0 and not isItemFn(homeDetail) then
    local empty = findEmptySlot(homeSlot)
    if not empty then return false end
    selectSlot(homeSlot)
    if not turtle.transferTo(empty) then return false end
  end
  return moveStackToSlot(src, homeSlot)
end

function pp.parkModemHome()
  return parkToHome(MODEM_SLOT, pp.findModemSlot, pp.isModemItem)
end

function pp.parkSpeakerHome()
  return parkToHome(SPEAKER_SLOT, pp.findSpeakerSlot, pp.isSpeakerItem)
end

function pp.ensureModemEquipped(titan)
  pp.loadConfig()
  if not pocket or type(pocket.equipBack) ~= "function" then
    if pp.hasModem() and titan and titan.openModem then pcall(titan.openModem) end
    return pp.hasModem()
  end
  if pp.hasModem() then
    if titan and titan.openModem then pcall(titan.openModem) end
    return true
  end
  pp.parkModemHome()
  if itemCount(MODEM_SLOT) == 0 then return false end
  selectSlot(MODEM_SLOT)
  local ok = pocket.equipBack()
  if ok and titan and titan.openModem then pcall(titan.openModem) end
  return ok and pp.hasModem()
end

-- Toggle back upgrade: modem equipped -> speaker; otherwise -> modem.
function pp.swapSound(titan)
  pp.loadConfig()
  if not pocket or type(pocket.equipBack) ~= "function" then
    return false, "not a pocket PC"
  end
  pp.parkModemHome()
  pp.parkSpeakerHome()

  local targetSlot
  if pp.hasModem() then
    targetSlot = SPEAKER_SLOT
    if itemCount(targetSlot) == 0 or not pp.isSpeakerItem(itemDetail(targetSlot)) then
      return false, ("no speaker in slot %d"):format(SPEAKER_SLOT)
    end
  else
    targetSlot = MODEM_SLOT
    if itemCount(targetSlot) == 0 or not pp.isModemItem(itemDetail(targetSlot)) then
      return false, ("no modem in slot %d"):format(MODEM_SLOT)
    end
  end

  selectSlot(targetSlot)
  local ok, err = pocket.equipBack()
  if ok then
    if pp.hasModem() and titan and titan.openModem then
      pcall(titan.openModem)
    end
    -- Re-park whatever landed in the wrong home slot after swap.
    pp.parkModemHome()
    pp.parkSpeakerHome()
  end
  return ok, err
end

function pp.soundModeLabel()
  if pp.hasModem() then return "modem" end
  if pp.findSpeaker() then return "spk" end
  return "off"
end

pp.loadConfig()

return pp
