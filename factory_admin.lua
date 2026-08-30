--[[
  Compat shim — Factory Admin lives under storage/managers/.
  Titan-Version: 1.0.0
]]
local path = "storage/managers/factory_admin.lua"
if not fs.exists(path) then
  error("Missing: " .. path, 0)
end
dofile(path)
