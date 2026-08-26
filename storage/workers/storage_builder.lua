--[[
  storage/workers/storage_builder.lua  -  Place a bulk storage cell
  Titan-Version: 1.0.0

  Builds a compact Create Vault + Sophisticated input/output chest pad.

  Stand at the front-left of the pad, facing +Z into the build:

      Z=0  computer pad (gold/marker)
      Z=1  input chest (Sophisticated)
      Z=2  Create item vault
      Z=3  output chest (Sophisticated)
      Modems on vault + both chests (wired) when items are in inventory

  Material names are matched loosely (vault / sophisticated / chest / modem).
  Fuel LEFT, supply chest BEHIND (optional).

  Commands:
    bom                 materials list
    build | go | start  dig footprint + place blocks
    stop | home | status | help | exit

  After build: right-click wired modems, run Storage Manager:
    bind vault … | bind input … | bind output …
]]

local CFG = "storage_builder.cfg"
local FUEL_SLOT = 16
local MIN_FUEL = 200
local VERSION = "1.0.0"

local STOP = false
local pos = { x = 0, y = 0, z = 0 }
local facing = 0
local cfg = { setupDone = false }

-- Schematic: list of { x, y, z, kind } kind = pad|input|vault|output|modem
-- Relative to turtle origin; +Y is DOWN.
local SCHEMATIC = {
  { x = 0, y = 0, z = 0, kind = "pad" },
  { x = 0, y = 0, z = 1, kind = "input" },
  { x = 0, y = 0, z = 2, kind = "vault" },
  { x = 0, y = 0, z = 3, kind = "output" },
  -- Modems sit on top of chests/vault (−Y = up in world = y-1 in quarry coords)
  { x = 0, y = -1, z = 1, kind = "modem" },
  { x = 0, y = -1, z = 2, kind = "modem" },
  { x = 0, y = -1, z = 3, kind = "modem" },
}

local function saveCfg()
  local f = fs.open(CFG, "w")
  if f then f.write(textutils.serialize(cfg)); f.close() end
end

local function loadCfg()
  if not fs.exists(CFG) then return end
  local f = fs.open(CFG, "r")
  if not f then return end
  local ok, data = pcall(textutils.unserialize, f.readAll())
  f.close()
  if ok and type(data) == "table" then cfg = data end
end

local function turnLeft()
  turtle.turnLeft(); facing = (facing + 3) % 4
end
local function turnRight()
  turtle.turnRight(); facing = (facing + 1) % 4
end
local function faceDir(dir)
  dir = dir % 4
  while facing ~= dir do
    local r = (dir - facing) % 4
    if r == 3 then turnLeft() else turnRight() end
  end
end

local function ensureFuel()
  if turtle.getFuelLevel() == "unlimited" then return true end
  if turtle.getFuelLevel() >= MIN_FUEL then return true end
  turtle.select(FUEL_SLOT)
  if turtle.refuel(0) then turtle.refuel() end
  for s = 1, 16 do
    if turtle.getFuelLevel() >= 1 then return true end
    turtle.select(s)
    if turtle.refuel(0) then turtle.refuel() end
  end
  return turtle.getFuelLevel() > 0
end

local function forward()
  if STOP or not ensureFuel() then return false end
  if turtle.detect() then turtle.dig() end
  if turtle.forward() then
    if facing == 0 then pos.z = pos.z + 1
    elseif facing == 1 then pos.x = pos.x + 1
    elseif facing == 2 then pos.z = pos.z - 1
    else pos.x = pos.x - 1 end
    return true
  end
  return false
end

local function up()
  if STOP or not ensureFuel() then return false end
  if turtle.detectUp() then turtle.digUp() end
  if turtle.up() then pos.y = pos.y - 1; return true end
  return false
end

local function down()
  if STOP or not ensureFuel() then return false end
  if turtle.detectDown() then turtle.digDown() end
  if turtle.down() then pos.y = pos.y + 1; return true end
  return false
end

local function goTo(x, y, z)
  x, y, z = math.floor(x), math.floor(y), math.floor(z)
  while pos.y > y do if not up() then return false end end
  while pos.y < y do if not down() then return false end end
  if pos.x ~= x then
    faceDir(pos.x < x and 1 or 3)
    while pos.x ~= x do if not forward() then return false end end
  end
  if pos.z ~= z then
    faceDir(pos.z < z and 0 or 2)
    while pos.z ~= z do if not forward() then return false end end
  end
  return true
end

local function itemName(slot)
  local d = turtle.getItemDetail and turtle.getItemDetail(slot)
  return d and tostring(d.name or ""):lower() or ""
end

local function findSlot(kind)
  local patterns = {
    vault = { "item_vault", "vault", "create:item_vault" },
    input = { "sophisticated", "chest", "barrel" },
    output = { "sophisticated", "chest", "barrel" },
    pad = { "gold_block", "concrete", "wool", "planks", "stone" },
    modem = { "wired_modem", "modem", "networking_cable" },
  }
  local pats = patterns[kind] or { kind }
  -- Prefer sophisticated for input/output when available.
  if kind == "input" or kind == "output" then
    for s = 1, 16 do
      if s ~= FUEL_SLOT and turtle.getItemCount(s) > 0 then
        local n = itemName(s)
        if n:find("sophisticated", 1, true) and (n:find("chest", 1, true) or n:find("barrel", 1, true)) then
          return s
        end
      end
    end
  end
  if kind == "vault" then
    for s = 1, 16 do
      if s ~= FUEL_SLOT and turtle.getItemCount(s) > 0 then
        local n = itemName(s)
        if n:find("vault", 1, true) then return s end
      end
    end
  end
  for _, pat in ipairs(pats) do
    for s = 1, 16 do
      if s ~= FUEL_SLOT and turtle.getItemCount(s) > 0 then
        if itemName(s):find(pat, 1, true) then return s end
      end
    end
  end
  return nil
end

local function countKind(kind)
  local n, s = 0, findSlot(kind)
  -- Count all matching loosely
  local total = 0
  for slot = 1, 16 do
    if slot ~= FUEL_SLOT and turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      local name = itemName(slot)
      if kind == "vault" and name:find("vault", 1, true) then total = total + turtle.getItemCount(slot)
      elseif (kind == "input" or kind == "output") and (name:find("sophisticated", 1, true) or name:find("chest", 1, true)) then
        total = total + turtle.getItemCount(slot)
      elseif kind == "modem" and (name:find("modem", 1, true) or name:find("cable", 1, true)) then
        total = total + turtle.getItemCount(slot)
      elseif kind == "pad" and (name:find("gold", 1, true) or name:find("concrete", 1, true) or name:find("wool", 1, true)) then
        total = total + turtle.getItemCount(slot)
      end
    end
  end
  return total, s
end

local function printBom()
  print("BOM for one storage cell:")
  print("  1x Create Item Vault")
  print("  2x Sophisticated Storage chest/barrel (input + output)")
  print("  3x Wired modem (full block)  [optional but recommended]")
  print("  1x Marker block for computer pad (gold/concrete/wool)")
  print("  Networking cable (player finishes links)")
  print("")
  print("In inventory now:")
  print(("  vault~%d  chests~%d  modem~%d  pad~%d"):format(
    select(1, countKind("vault")),
    select(1, countKind("input")),
    select(1, countKind("modem")),
    select(1, countKind("pad"))))
end

local function placeDown(kind)
  local slot = findSlot(kind)
  if not slot then
    print("Missing item for: " .. kind)
    return false
  end
  turtle.select(slot)
  if turtle.detectDown() then turtle.digDown() end
  if not turtle.placeDown() then
    print("Could not place " .. kind)
    return false
  end
  return true
end

local function clearColumn()
  -- Clear feet and one above for modem layer.
  if turtle.detect() then turtle.dig() end
  if turtle.detectUp() then turtle.digUp() end
  if turtle.detectDown() then turtle.digDown() end
end

local function buildCell()
  STOP = false
  print("Building storage cell (vault + I/O)...")
  printBom()

  -- Clear 1x4 strip at y=0 and y=-1
  for z = 0, 3 do
    if STOP then return false end
    if not goTo(0, 0, z) then print("Path failed"); return false end
    faceDir(0)
    clearColumn()
    if not goTo(0, -1, z) then return false end
    if turtle.detectDown() then turtle.digDown() end
    if turtle.detectUp() then turtle.digUp() end
  end

  -- Place floor layer (pad, input, vault, output)
  local floor = {
    { 0, 0, 0, "pad" },
    { 0, 0, 1, "input" },
    { 0, 0, 2, "vault" },
    { 0, 0, 3, "output" },
  }
  for _, b in ipairs(floor) do
    if STOP then return false end
    local x, y, z, kind = b[1], b[2], b[3], b[4]
    -- Stand above the block to placeDown
    if not goTo(x, y - 1, z) then
      print("Cannot reach place pose for " .. kind)
      return false
    end
    faceDir(0)
    if not placeDown(kind) then
      print("Place " .. kind .. " manually, then continue.")
    else
      print("Placed " .. kind .. " @ " .. x .. "," .. y .. "," .. z)
    end
  end

  -- Modems on top of input/vault/output
  for _, z in ipairs({ 1, 2, 3 }) do
    if STOP then break end
    if findSlot("modem") then
      if goTo(0, -2, z) then
        faceDir(0)
        if placeDown("modem") then
          print("Placed modem above z=" .. z)
        end
      end
    else
      print("No modem in inventory — skip modem layer.")
      break
    end
  end

  goTo(0, 0, 0)
  faceDir(0)
  print("")
  print("Build pass done.")
  print("1) Right-click wired modems so they connect.")
  print("2) Run cable to the Storage Manager computer on the pad.")
  print("3) On the manager: right-click its modem — vaults auto-detect.")
  cfg.lastBuild = os.epoch("utc")
  saveCfg()
  return true
end

local function suckFuel()
  faceDir(3)
  turtle.select(FUEL_SLOT)
  for _ = 1, 32 do if not turtle.suck() then break end end
  turtle.refuel()
  faceDir(0)
end

local function goHome()
  goTo(0, 0, 0)
  faceDir(0)
end

local function printHelp()
  print("Storage builder v" .. VERSION)
  print("  bom              materials list")
  print("  build | go       place vault + I/O + modems")
  print("  home | stop | status | help | exit")
end

local function handle(line)
  local a = {}
  for w in tostring(line or ""):gmatch("%S+") do a[#a + 1] = w end
  local cmd = tostring(a[1] or ""):lower()
  if cmd == "" then return true
  elseif cmd == "help" or cmd == "?" then printHelp()
  elseif cmd == "bom" or cmd == "materials" then printBom()
  elseif cmd == "build" or cmd == "go" or cmd == "start" then
    suckFuel()
    buildCell()
  elseif cmd == "stop" then STOP = true; print("Stop requested.")
  elseif cmd == "home" then goHome()
  elseif cmd == "status" then
    print(("pos=%d,%d,%d fuel=%s"):format(pos.x, pos.y, pos.z, tostring(turtle.getFuelLevel())))
    printBom()
  elseif cmd == "exit" or cmd == "quit" then return "exit"
  else print("Unknown. Type help.") end
  return true
end

if not turtle then error("storage_builder must run on a turtle.", 0) end
loadCfg()
os.setComputerLabel(os.getComputerLabel() or ("StorageBuilder-" .. os.getComputerID()))
term.clear(); term.setCursorPos(1, 1)
print("== Storage Builder v" .. VERSION .. " ==")
print("Faces into pad: pad → input → vault → output")
print("Type bom / build / help.")

while true do
  write("builder> ")
  local r = handle(read())
  if r == "exit" then break end
end
print("Storage builder closed.")
