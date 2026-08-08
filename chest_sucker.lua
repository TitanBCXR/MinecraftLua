--[[
  chest_sucker.lua  -  On boot, suck items from any adjacent chest
  Titan-Version: 1.0.0

  Place the turtle next to a chest (any side, above, or below).
  Run once, or put in startup.lua:

    shell.run("chest_sucker.lua")

  Matches any block whose name contains "chest" (chest, trapped_chest,
  ender_chest, modded *chest*, etc.).
]]

if not turtle then
  print("chest_sucker must run on a turtle.")
  return
end

local function isChest(info)
  if type(info) ~= "table" then return false end
  local name = tostring(info.name or info.id or ""):lower()
  return name:find("chest", 1, true) ~= nil
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

-- Down
do
  local ok, info = turtle.inspectDown()
  if ok and isChest(info) then
    print("Chest below — sucking...")
    total = total + suckAll(turtle.suckDown)
  end
end

-- Up
do
  local ok, info = turtle.inspectUp()
  if ok and isChest(info) then
    print("Chest above — sucking...")
    total = total + suckAll(turtle.suckUp)
  end
end

-- Four horizontal sides
for side = 1, 4 do
  local ok, info = turtle.inspect()
  if ok and isChest(info) then
    print(("Chest in front — sucking (facing %d)..."):format(side))
    total = total + suckAll(turtle.suck)
  end
  turtle.turnRight()
end

if total > 0 then
  print(("Done — took %d stack(s)."):format(total))
else
  print("No adjacent chest with items (or inventory full).")
end
