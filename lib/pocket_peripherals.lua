--[[
  pocket_peripherals.lua  -  Pocket modem / speaker helpers (Titan games)
  Titan-Version: 1.0.5

  Pocket PCs keep modem/speaker in the **player inventory** (Minecraft hotbar),
  including items inside Sophisticated Backpacks when CC:T / Advanced Peripherals
  expose them. Use pocket.equipBack() / pocket.unequipBack() — not turtle slots.

  Press M in the Games launcher or Tetris menu to swap the back upgrade between
  modem and speaker. equipBack searches player inventory from the selected
  hotbar slot; putting the item on the hotbar helps.

  Scan order: player slots (inventory_manager) → nested backpack/curios storage
  → attached inventory peripherals (placed backpack blocks) → turtle slots.

  Cached locations persist in games_launcher.cfg as modemSource / speakerSource.

  Turtle / desktop fallback (optional): reserve inventory slots 15/16 for modem
  and speaker when turtle.getItemDetail is available (not on pocket PCs).

  Config (optional) in games_launcher.cfg:
    modemSlot = 15, speakerSlot = 16   (turtle fallback only)
    modemSource / speakerSource        (last scan: player, backpack, peripheral)
]]

local pp = {}

local STATE_FILE = "games_launcher.cfg"
local DEFAULT_MODEM_SLOT = 15
local DEFAULT_SPEAKER_SLOT = 16

local MODEM_SLOT = DEFAULT_MODEM_SLOT
local SPEAKER_SLOT = DEFAULT_SPEAKER_SLOT
local MODEM_SOURCE = nil
local SPEAKER_SOURCE = nil

local POCKET_MODEM_ERR =
  "Put a wireless/ender modem in player inventory or backpack (hotbar helps)"
local POCKET_SPEAKER_ERR =
  "Put a speaker upgrade in player inventory or backpack (hotbar helps)"

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
    or n == "computercraft:wireless_modem_normal"
    or n == "computercraft:wireless_modem_advanced"
    or n == "computercraft:ender_modem"
end

function pp.isSpeakerItem(detail)
  if type(detail) ~= "table" or not detail.name then return false end
  local n = tostring(detail.name):lower()
  return n:find("speaker", 1, true) ~= nil
    or n == "computercraft:speaker"
    or n:find("noisy_pocket", 1, true) ~= nil
end

function pp.hasModem()
  for _, name in ipairs(peripheral.getNames()) do
    if pp.isModemType(peripheral.getType(name)) then
      return true
    end
  end
  return false
end

--- Wired/side modem while speaker (or other upgrade) is on back.
function pp.hasSideModem()
  for _, name in ipairs(peripheral.getNames()) do
    if name ~= "back" and pp.isModemType(peripheral.getType(name)) then
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

function pp.getSources()
  return MODEM_SOURCE, SPEAKER_SOURCE
end

function pp.setupHelp()
  if isPocketPC() then
    return "Player/backpack inv — M swaps modem/speaker"
  end
  return ("Modem slot %d, speaker slot %d — M swaps music/modem"):format(
    MODEM_SLOT, SPEAKER_SLOT)
end

local function normalizeSource(src)
  if type(src) ~= "table" or type(src.kind) ~= "string" then return nil end
  local out = {
    kind = src.kind,
    slot = tonumber(src.slot),
    playerSlot = tonumber(src.playerSlot),
    side = src.side,
    curios = src.curios,
    name = src.name,
  }
  if out.kind == "player" and not out.slot then return nil end
  if out.kind == "backpack" and (not out.playerSlot or not out.slot) then return nil end
  if out.kind == "curios_backpack" and (not out.curios or not out.slot) then return nil end
  if out.kind == "peripheral" and (not out.side or not out.slot) then return nil end
  if out.kind == "turtle" and not out.slot then return nil end
  return out
end

function pp.loadConfig()
  MODEM_SLOT = DEFAULT_MODEM_SLOT
  SPEAKER_SLOT = DEFAULT_SPEAKER_SLOT
  MODEM_SOURCE = nil
  SPEAKER_SOURCE = nil
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
  MODEM_SOURCE = normalizeSource(d.modemSource)
  SPEAKER_SOURCE = normalizeSource(d.speakerSource)
end

local function writeConfigExtra(d)
  d.modemSlot = MODEM_SLOT
  d.speakerSlot = SPEAKER_SLOT
  d.modemSource = MODEM_SOURCE
  d.speakerSource = SPEAKER_SOURCE
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
  writeConfigExtra(d)
  local f = fs.open(STATE_FILE, "w")
  if f then
    f.write(textutils.serialize(d))
    f.close()
  end
end

local function rememberSource(which, source)
  source = normalizeSource(source)
  if not source then return end
  if which == "modem" then MODEM_SOURCE = source
  elseif which == "speaker" then SPEAKER_SOURCE = source end
  pp.saveSlots()
end

local function inventorySize()
  return 16
end

local function isStorageContainerItem(detail)
  if type(detail) ~= "table" or not detail.name then return false end
  local n = tostring(detail.name):lower()
  return n:find("backpack", 1, true) ~= nil
    or n:find("sophisticated", 1, true) ~= nil
    or n:find("shulker", 1, true) ~= nil
    or n:find("pouch", 1, true) ~= nil
    or n:find("bag", 1, true) ~= nil
end

local function isBackpackSide(name, ptype)
  local n = tostring(name or ""):lower()
  local t = tostring(ptype or ""):lower()
  return n:find("backpack", 1, true) ~= nil
    or n:find("sophisticated", 1, true) ~= nil
    or t:find("backpack", 1, true) ~= nil
    or t:find("sophisticated", 1, true) ~= nil
end

local function scanListTable(list, pred, kind, meta, results)
  if type(list) ~= "table" then return end
  for slot, item in pairs(list) do
    if type(item) == "table" and pred(item) then
      local entry = {
        kind = kind,
        slot = tonumber(slot) or slot,
        detail = item,
        name = item.name,
      }
      if meta then
        for k, v in pairs(meta) do entry[k] = v end
      end
      results[#results + 1] = entry
    end
  end
end

local function scanInventoryPeripheral(side, pred, results)
  if not peripheral.isPresent(side) then return end
  local inv = peripheral.wrap(side)
  if not inv or type(inv.list) ~= "function" then return end
  local ok, list = pcall(inv.list)
  if not ok then return end
  scanListTable(list, pred, "peripheral", { side = side }, results)
end

local function scanStorageWrap(storage, pred, kind, meta, results)
  if not storage or type(storage.list) ~= "function" then return end
  if type(storage.isItemStorage) == "function" then
    local ok, isStore = pcall(storage.isItemStorage)
    if ok and not isStore then return end
  end
  local ok, list = pcall(storage.list)
  if not ok then return end
  scanListTable(list, pred, kind, meta, results)
end

local function findInventoryManager()
  local direct = peripheral.find("inventory_manager")
  if direct then return direct end
  for _, name in ipairs(peripheral.getNames()) do
    local t = tostring(peripheral.getType(name) or ""):lower()
    if t:find("inventory_manager", 1, true) or name:lower():find("inventory_manager", 1, true) then
      local wrap = peripheral.wrap(name)
      if wrap and (type(wrap.list) == "function" or type(wrap.getItems) == "function") then
        return wrap
      end
    end
  end
  return nil
end

local function managerPlayerList(mgr)
  if type(mgr.list) == "function" then
    local ok, list = pcall(mgr.list)
    if ok and type(list) == "table" then return list end
  end
  if type(mgr.getItems) == "function" then
    local ok, list = pcall(mgr.getItems)
    if ok and type(list) == "table" then return list end
  end
  return nil
end

local function scanInventoryManager(mgr, pred, results)
  local list = managerPlayerList(mgr)
  if list then
    for slot, item in pairs(list) do
      if type(item) == "table" and pred(item) then
        results[#results + 1] = {
          kind = "player", slot = tonumber(slot) or slot,
          detail = item, name = item.name,
        }
      end
      if type(item) == "table" and isStorageContainerItem(item)
          and type(mgr.wrapStorageItem) == "function" then
        local ps = tonumber(slot) or slot
        local ok, storage = pcall(mgr.wrapStorageItem, ps)
        if ok then
          scanStorageWrap(storage, pred, "backpack", {
            playerSlot = ps, storage = storage,
          }, results)
        end
      end
    end
  end

  if type(mgr.listCurios) == "function" and type(mgr.wrapCuriosStorageItem) == "function" then
    local ok, curios = pcall(mgr.listCurios)
    if ok and type(curios) == "table" then
      for slotName, slots in pairs(curios) do
        if type(slots) == "table" then
          for cslot, item in pairs(slots) do
            if type(item) == "table" and pred(item) then
              results[#results + 1] = {
                kind = "curios", slot = tonumber(cslot) or cslot,
                curios = slotName, detail = item, name = item.name,
              }
            end
            if type(item) == "table" and isStorageContainerItem(item) then
              local cs = tonumber(cslot) or cslot
              local ok2, storage = pcall(mgr.wrapCuriosStorageItem, slotName, cs)
              if ok2 then
                scanStorageWrap(storage, pred, "curios_backpack", {
                  curios = slotName, playerSlot = cs, storage = storage,
                }, results)
              end
            end
          end
        end
      end
    end
  end
end

function pp.scanUpgradeSources(pred)
  local results = {}
  if type(pred) ~= "function" then return results end

  local mgr = findInventoryManager()
  if mgr then scanInventoryManager(mgr, pred, results) end

  for _, side in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(side)
    local t = tostring(ptype or ""):lower()
    if t:find("inventory", 1, true) or isBackpackSide(side, ptype) then
      if not (mgr and side:lower():find("inventory_manager", 1, true)) then
        scanInventoryPeripheral(side, pred, results)
      end
    end
  end

  if hasTurtleInventory() then
    for s = 1, inventorySize() do
      local d = itemDetail(s)
      if pred(d) then
        results[#results + 1] = { kind = "turtle", slot = s, detail = d, name = d.name }
      end
    end
  end

  return results
end

local function findPreferredSource(which, pred)
  local cached = (which == "modem") and MODEM_SOURCE or SPEAKER_SOURCE
  if cached then
    for _, src in ipairs(pp.scanUpgradeSources(pred)) do
      if src.kind == cached.kind
          and (not cached.slot or src.slot == cached.slot)
          and (not cached.playerSlot or src.playerSlot == cached.playerSlot)
          and (not cached.side or src.side == cached.side)
          and (not cached.curios or src.curios == cached.curios) then
        return src
      end
    end
  end
  local all = pp.scanUpgradeSources(pred)
  return all[1]
end

local function sourceError(src, wantModem)
  local base = wantModem and POCKET_MODEM_ERR or POCKET_SPEAKER_ERR
  if not src then return base end
  if src.kind == "backpack" then
    return ("Upgrade in Sophisticated Backpack (player slot %d) — move to hotbar or open backpack; CC cannot read closed bags"):format(
      src.playerSlot or 0)
  end
  if src.kind == "curios_backpack" then
    return ("Upgrade in backpack (%s slot %d) — move to hotbar"):format(
      tostring(src.curios or "curios"), src.playerSlot or 0)
  end
  if src.kind == "peripheral" then
    return ("Upgrade in placed container %s slot %d — move to player inventory"):format(
      tostring(src.side or "?"), src.slot or 0)
  end
  if src.kind == "player" then
    return ("Upgrade in player slot %d — select that hotbar slot, then press M"):format(src.slot or 0)
  end
  return base
end

local function tryPullFromBackpackToPlayer(mgr, src)
  if not mgr or not src or src.kind ~= "backpack" then return false end
  local free = (type(mgr.getFreeSlot) == "function" and mgr.getFreeSlot())
    or (type(mgr.getHandSlot) == "function" and mgr.getHandSlot())
  if not free or free == 0 then return false end
  local ok, storage = pcall(mgr.wrapStorageItem, src.playerSlot)
  if not ok or not storage or type(storage.exportItem) ~= "function" then return false end
  local filter = { fromSlot = src.slot, count = 1, toSlot = free }
  if src.name then filter.name = src.name end
  -- Advanced Peripherals: best-effort export to player inv (pack-dependent).
  for _, target in ipairs({ "@player", "player", "@self" }) do
    local ok2, moved = pcall(storage.exportItem, target, filter)
    if ok2 and tonumber(moved) and moved > 0 then return true end
  end
  return false
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
  local which = wantModem and "modem" or "speaker"
  local pred = wantModem and pp.isModemItem or pp.isSpeakerItem
  local src = findPreferredSource(which, pred)
  local errMsg = sourceError(src, wantModem)

  local function verify()
    if wantModem then return pp.hasModem() end
    return pocketHasSpeakerEquipped()
  end

  local function finish(ok)
    if ok then
      local found = findPreferredSource(which, pred) or src
      if found then rememberSource(which, found) end
      if wantModem then openModemIfPresent(titan) end
    end
    return ok
  end

  -- CC:T equipBack walks player inventory from the selected hotbar slot and may
  -- include modded nested storage when the pack integrates backpacks with CC:T.
  if src and (src.kind == "backpack" or src.kind == "curios_backpack") then
    local mgr = findInventoryManager()
    if mgr then tryPullFromBackpackToPlayer(mgr, src) end
  end

  if backType() then
    local ok = pocket.equipBack()
    if ok and verify() then return finish(true) end
  end

  if backType() and type(pocket.unequipBack) == "function" then
    local uok, uerr = pocket.unequipBack()
    if not uok then
      return false, uerr or errMsg
    end
  end

  local ok, err = pocket.equipBack()
  if ok and verify() then return finish(true) end

  src = findPreferredSource(which, pred) or src
  if src then rememberSource(which, src) end
  return false, err or sourceError(src, wantModem)
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
    local ok, err = pocketEquipCounterpart(true, titan)
    return ok, err
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

function pp.ensureSpeakerEquipped(titan)
  pp.loadConfig()
  if pocketHasSpeakerEquipped() then
    return true
  end

  if isPocketPC() then
    return pocketEquipCounterpart(false, titan)
  end

  if hasTurtleInventory() then
    pp.parkSpeakerHome()
    if itemCount(SPEAKER_SLOT) == 0 then return false end
    selectSlot(SPEAKER_SLOT)
    local ok = pocket and pocket.equipBack and pocket.equipBack()
    return ok and pocketHasSpeakerEquipped()
  end

  return pocketHasSpeakerEquipped()
end

function pp.statusText()
  if pp.hasModem() then return "Modem on (mesh)" end
  if pp.findSpeaker() or pocketHasSpeakerEquipped() then return "Speaker on (music)" end
  return "No back upgrade"
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

function pp.refreshSourceCache()
  pp.loadConfig()
  local modems = pp.scanUpgradeSources(pp.isModemItem)
  local speakers = pp.scanUpgradeSources(pp.isSpeakerItem)
  if modems[1] then MODEM_SOURCE = normalizeSource(modems[1]) end
  if speakers[1] then SPEAKER_SOURCE = normalizeSource(speakers[1]) end
  pp.saveSlots()
end

function pp.soundModeLabel()
  if pp.hasModem() then return "modem" end
  if pp.findSpeaker() then return "spk" end
  return "off"
end

pp.loadConfig()

return pp
