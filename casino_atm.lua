--[[
  Compat shim — Casino ATM lives under games/managers/.
  Titan-Version: 1.0.0
]]
local path = "games/managers/casino_atm.lua"
if not fs.exists(path) then
  error("Missing " .. path .. " — reinstall Games / Casino ATM", 0)
end
shell.run(path)
