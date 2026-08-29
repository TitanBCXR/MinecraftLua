--[[
  sheep_command_block.lua - Place a command block that summons 1 sheep above it
  
  Usage:
    sheep_command_block [x] [y] [z]
  
  Examples:
    sheep_command_block         -- place in front (~1 ~ ~)
    sheep_command_block 0 -1 0  -- place below (~ ~-1 ~)
    sheep_command_block 5 10 3  -- place at specific offset
]]

-- Parse position arguments (default: in front)
local args = {...}
local x = tonumber(args[1]) or 1
local y = tonumber(args[2]) or 0
local z = tonumber(args[3]) or 0

local blockPos = ("~%d ~%d ~%d"):format(x, y, z)
print(("Placing command block at %s"):format(blockPos))

-- Attempt to place and configure command block
local function tryPlaceCommandBlock()
  if not commands then
    return false, "commands unavailable"
  end

  local success, err = commands.setblock(blockPos, "minecraft:command_block")
  if not success then
    return false, "setblock failed: " .. tostring(err)
  end

  success, err = commands.data("merge", "block", blockPos, "{Command:\"summon minecraft:sheep ~ ~1 ~\"}")
  if not success then
    return false, "data merge failed: " .. tostring(err)
  end

  return true
end

-- Execute and report
local success, err = tryPlaceCommandBlock()

if success then
  print("SUCCESS: Command block placed at " .. blockPos)
  print("  Command: summon minecraft:sheep ~ ~1 ~")
  print("  Activate with button/lever/redstone")
else
  print("FAILED: " .. (err or "unknown error"))
end
