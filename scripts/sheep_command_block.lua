--[[
  sheep_command_block.lua - Place a command block that summons 1 sheep above it
  
  Runs on any computer but only SUCCEEDS on Command Computers (with the `commands` API).
  Regular computers and turtles will report FAILED (cannot set command-block NBT).
  
  Usage:
    sheep_command_block [x] [y] [z]
  
  Examples:
    sheep_command_block         -- place in front (~1 ~ ~)
    sheep_command_block 0 -1 0  -- place below (~ ~-1 ~)
    sheep_command_block 5 10 3  -- place at specific offset
  
  The command block is an impulse block (runs once per activation).
  To activate: place a button/lever next to it, or power with redstone.
  
  Command Computers are Creative-mode only and require op permissions.
  Obtain via: /give @p computercraft:command_computer
]]

-- Parse position arguments (default: in front)
local args = {...}
local x = tonumber(args[1]) or 1
local y = tonumber(args[2]) or 0
local z = tonumber(args[3]) or 0

print(("Attempting to place command block at ~%d ~%d ~%d"):format(x, y, z))

-- Try-and-report: attempt the injection flow regardless of API availability
local function tryPlaceCommandBlock()
  -- Check if commands API is available
  if not commands then
    return false, "FAILED: Command Computer required.\n" ..
                  "  This computer does not have the 'commands' API.\n" ..
                  "  Regular computers and turtles cannot set command-block NBT.\n" ..
                  "  Use a Command Computer (Creative-mode, /give @p computercraft:command_computer)."
  end

  -- Place the command block (impulse type, default)
  local blockPos = ("~%d ~%d ~%d"):format(x, y, z)
  local success, err = commands.setblock(blockPos, "minecraft:command_block")
  
  if not success then
    return false, "FAILED: Could not place command block.\n  API error: " .. tostring(err)
  end

  -- Set the command block's command to summon 1 sheep above it
  -- The command block uses its own position as origin, so ~1 means 1 block above the command block
  success, err = commands.data("merge", "block", blockPos, "{Command:\"summon minecraft:sheep ~ ~1 ~\"}")
  
  if not success then
    return false, "FAILED: Command block placed but could not set command.\n  API error: " .. tostring(err)
  end

  return true, "SUCCESS: Command block placed and configured.\n" ..
               "  Position: " .. blockPos .. "\n" ..
               "  Command: summon minecraft:sheep ~ ~1 ~\n" ..
               "  To activate: place a button/lever next to it, or power with redstone.\n" ..
               "  Each activation spawns 1 sheep above the command block."
end

-- Execute and report
local success, message = tryPlaceCommandBlock()

print("\n" .. string.rep("=", 60))
if success then
  print(message)
  print(string.rep("=", 60))
else
  print(message)
  print(string.rep("=", 60))
  -- Exit with error status if supported (CC: Tweaked does not have os.exit, but some environments might)
  if os.exit then
    os.exit(1)
  end
end
