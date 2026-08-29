--[[
  sheep_command_block.lua - Place a command block that summons 1 sheep above it
  
  Requires: Command Computer (has the `commands` API)
  Regular computers and turtles cannot set command-block NBT.
  
  Usage:
    sheep_command_block [x] [y] [z]
  
  Examples:
    sheep_command_block         -- place in front (~1 ~ ~)
    sheep_command_block 0 -1 0  -- place below (~ ~-1 ~)
    sheep_command_block 5 10 3  -- place at specific offset
  
  The command block is an impulse block (runs once per activation).
  To activate: place a button/lever next to it, or power with redstone.
  
  Command Computers are Creative-mode only and require op permissions.
]]

-- Check if commands API is available
if not commands then
  error("This script requires a Command Computer.\n" ..
        "Command Computers are Creative-mode only (place via /give @p computercraft:command_computer).\n" ..
        "Regular computers and turtles cannot set command-block NBT.", 0)
end

-- Parse position arguments (default: in front)
local args = {...}
local x = tonumber(args[1]) or 1
local y = tonumber(args[2]) or 0
local z = tonumber(args[3]) or 0

print(("Placing command block at ~%d ~%d ~%d"):format(x, y, z))

-- Place the command block (impulse type, default)
local success, err = commands.setblock(
  ("~%d ~%d ~%d"):format(x, y, z),
  "minecraft:command_block"
)

if not success then
  error("Failed to place command block: " .. tostring(err), 0)
end

print("Command block placed.")

-- Set the command block's command to summon 1 sheep above it
-- The command block uses its own position as origin, so ~1 means 1 block above the command block
local blockPos = ("~%d ~%d ~%d"):format(x, y, z)
success, err = commands.data("merge", "block", blockPos, "{Command:\"summon minecraft:sheep ~ ~1 ~\"}")

if not success then
  error("Failed to set command: " .. tostring(err), 0)
end

print("Command configured: summon minecraft:sheep ~ ~1 ~")
print("\nTo activate:")
print("  - Place a button/lever next to the command block")
print("  - Or power it with redstone")
print("  - Each activation spawns 1 sheep above the command block")
