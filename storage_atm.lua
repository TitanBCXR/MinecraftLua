--[[
  Compat shim — Storage ATM lives under storage/managers/.
  Titan-Version: 1.4.0
]]
local path = "storage/managers/storage_atm.lua"
if not fs.exists(path) then
  error("Missing " .. path .. " — reinstall Storage ATM", 0)
end
shell.run(path)
