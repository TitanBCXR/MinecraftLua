--[[
  Compat shim — Currency Manager lives under games/managers/.
  Titan-Version: 1.1.6
]]
local path = "games/managers/currency_manager.lua"
if not fs.exists(path) then
  error("Missing " .. path .. " — reinstall Games / Currency Manager", 0)
end
shell.run(path)
