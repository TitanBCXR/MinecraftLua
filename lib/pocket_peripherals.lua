--[[
  pocket_peripherals.lua  -  Pocket modem / speaker helpers (Titan games)
  Titan-Version: 1.0.2

  Pocket PCs keep modem/speaker in the **player inventory** (Minecraft hotbar).
  Use pocket.equipBack() / pocket.unequipBack() — not turtle slots 15/16.

  Press M in the Games launcher or Tetris menu to swap the back upgrade between
  modem and speaker. equipBack searches player inventory from the selected
  hotbar slot; putting the item on the hotbar helps.

  Turtle / desktop fallback (optional): reserve inventory slots 15/16 for modem
  and speaker when turtle.getItemDetail is available (not on pocket PCs).

  Config (optional) in games_launcher.cfg:
    modemSlot = 15, speakerSlot = 16   (turtle fallback only)
]]

local pp = {}

local STATE_FILE = "games_launcher.cfg"
local DEFAULT_MODEM_SLOT = 15
local DEFAULT_SPEAKER_SLOT = 16

local MODEM_SLOT = DEFAULT_MODEM_SLOT
local SPEAKER_SLOT = DEFAULT_SPEAKER_SLOT

local POCKET_MODEM_ERR =
  "Put a wireless/ender modem in your player inventory (hotbar helps)"
local POCKET_SPEAKER_ERR =
  "Put a speaker upgrade in your player inventory (hotbar helps)"

local function isPocketPC()
  return pocket and type(pocket.equipBack) == "function"
end

local function hasTurtleInventory()
  return turtle and type(turtle.getItemDetail) == "function" and not isPocketPC()
end

local function backType()
  if peripheral.isPresent("back") then
    return peripheral.getType("back")
  end
  return nil
end

local function itemDetail(slot)
  if not hasTurtleInventory() then return nil end
  local ok, d = pcall(turtle.getItemDetail, slot)
  if ok then return d end
  return nil
end

local function itemCount(slot)
  if not hasTurtleInventory() then return 0 end
  return turtle.getItemCount(slot) or 0
end

local function selectSlot(slot)
  if hasTurtleInventory() and type(turtle.select) == "function" then
    turtle.select(slot)
  end
end

function pp.isModemType(ptype)
  if not ptype then return false end
  local t = tostring(ptype):lower()
  return t == "modem"
    or t == "wired_modem"
    or t == "wireless_modem"
    or t == "ender_modem"
end

function pp.isSpeakerType(ptype)
  if not ptype then return false end
  return tostring(ptype):lower():find("speaker", 1, true) ~= nil
end

function pp.isModemItem(detail)
  if type(detail) ~= "table" or not detail.name then return false end
  local n = tostring(detail.name):lower()
  if n:find("speaker", 1, true) then return false end
  return n:find("modem", 1, true) ~= nil
    or n:find("ender_modem", 1, true) ~= nil
    or n:find("wireless_modem", 1, true) ~= nil
end

function pp.isSpeakerItem(detail)
  if type(detail) ~= "table" or not detail.name then return false end
  return tostring(detail.name):lower():find("speaker", 1, true) ~= nil
end

function pp.hasModem()
  for _, name in ipairs(peripheral.getNames()) do
    if pp.isModemType(peripheral.getType(name)) then
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
  if isPocketPC() then
    return "Player inventory — M swaps modem/speaker on back"
  end
  return ("Modem slot %d, speaker slot %d — M swaps music/modem"):format(
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
  if not hasTurtleInventory() then return nil end
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
  if not hasTurtleInventory() then return nil end
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
  if not hasTurtleInventory() then return false end
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
  if not hasTurtleInventory() then return true end
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

local function openModemIfPresent(titan)
  if titan and titan.openModem then pcall(titan.openModem) end
end

local function pocketHasSpeakerEquipped()
  return pp.isSpeakerType(backType()) or pp.findSpeaker() ~= nil
end

local function pocketEquipCounterpart(wantModem, titan)
  local errMsg = wantModem and POCKET_MODEM_ERR or POCKET_SPEAKER_ERR

  local function verify()
    if wantModem then return pp.hasModem() end
    return pocketHasSpeakerEquipped()
  end

  -- equipBack replaces the current back upgrade with another from player inventory.
  if backType() then
    local ok = pocket.equipBack()
    if ok and verify() then
      if wantModem then openModemIfPresent(titan) end
      return true
    end
  end

  -- Unequip current back item into player inventory, then equip from inventory.
  if backType() and type(pocket.unequipBack) == "function" then
    local uok, uerr = pocket.unequipBack()
    if not uok then
      return false, uerr or errMsg
    end
  end

  local ok, err = pocket.equipBack()
  if ok and verify() then
    if wantModem then openModemIfPresent(titan) end
    return true
  end
  return false, err or errMsg
end

local function swapSoundTurtle(titan)
  pp.parkModemHome()
  pp.parkSpeakerHome()

  local targetSlot
  if pp.hasModem() then
    targetSlot = pp.findSpeakerSlot()
    if not targetSlot then
      return false, ("no speaker in inventory (slot %d preferred)"):format(SPEAKER_SLOT)
    end
  else
    targetSlot = pp.findModemSlot()
    if not targetSlot then
      return false, ("no modem in inventory (slot %d preferred)"):format(MODEM_SLOT)
    end
  end

  selectSlot(targetSlot)
  local ok, err = pocket.equipBack()
  if ok then
    if pp.hasModem() then openModemIfPresent(titan) end
    pp.parkModemHome()
    pp.parkSpeakerHome()
  end
  return ok, err
end

function pp.ensureModemEquipped(titan)
  pp.loadConfig()
  if pp.hasModem() then
    openModemIfPresent(titan)
    return true
  end

  if isPocketPC() then
    local ok = pocket.equipBack()
    if not ok and backType() and type(pocket.unequipBack) == "function" then
      if pocket.unequipBack() then
        ok = pocket.equipBack()
      end
    end
    if ok and pp.hasModem() then
      openModemIfPresent(titan)
      return true
    end
    return false
  end

  if hasTurtleInventory() then
    pp.parkModemHome()
    if itemCount(MODEM_SLOT) == 0 then return false end
    selectSlot(MODEM_SLOT)
    local ok = pocket and pocket.equipBack and pocket.equipBack()
    if ok and pp.hasModem() then openModemIfPresent(titan) end
    return ok and pp.hasModem()
  end

  openModemIfPresent(titan)
  return pp.hasModem()
end

-- Toggle back upgrade: modem equipped -> speaker in player inventory; otherwise -> modem.
function pp.swapSound(titan)
  pp.loadConfig()
  if not isPocketPC() then
    if hasTurtleInventory() and pocket and type(pocket.equipBack) == "function" then
      return swapSoundTurtle(titan)
    end
    return false, "not a pocket PC"
  end

  if pp.hasModem() then
    return pocketEquipCounterpart(false, titan)
  end
  return pocketEquipCounterpart(true, titan)
end

function pp.soundModeLabel()
  if pp.hasModem() then return "modem" end
  if pp.findSpeaker() then return "spk" end
  return "off"
end

pp.loadConfig()

return pp
