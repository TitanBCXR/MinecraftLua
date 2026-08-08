--[[
  chest_sucker.lua  -  On boot, suck items from adjacent chests / barrels
  Titan-Version: 1.0.1

  Place the turtle next to a chest or barrel (any side, above, or below).
  Run once, or put in startup.lua:

    shell.run("chest_sucker.lua")

  Matches blocks whose name contains "chest" or "barrel"
  (loot chests, trapped_chest, barrel, modded variants, etc.).
]]

if not turtle then
  print("chest_sucker must run on a turtle.")
  return
end

local function isLootContainer(info)
  if type(info) ~= "table" then return false end
  local name = tostring(info.name or info.id or ""):lower()
  return name:find("chest", 1, true) ~= nil
      or name:find("barrel", 1, true) ~= nil
end

local function suckAll(suckFn)
  local moved = 0
  for _ = 1, 128 do
    if not suckFn() then break end
    moved = moved + 1
  end
  return moved
end

local total = 0

local function labelFor(info)
  local name = tostring(info.name or "container"):lower()
  if name:find("barrel", 1, true) then return "Barrel" end
  return "Chest"
end

-- Down
do
  local ok, info = turtle.inspectDown()
  if ok and isLootContainer(info) then
    print(labelFor(info) .. " below — sucking...")
    total = total + suckAll(turtle.suckDown)
  end
end

-- Up
do
  local ok, info = turtle.inspectUp()
  if ok and isLootContainer(info) then
    print(labelFor(info) .. " above — sucking...")
    total = total + suckAll(turtle.suckUp)
  end
end

-- Four horizontal sides
for side = 1, 4 do
  local ok, info = turtle.inspect()
  if ok and isLootContainer(info) then
    print(("%s in front — sucking..."):format(labelFor(info)))
    total = total + suckAll(turtle.suck)
  end
  turtle.turnRight()
end

if total > 0 then
  print(("Done — took %d stack(s)."):format(total))
else
  print("No adjacent chest/barrel with items (or inventory full).")
end
