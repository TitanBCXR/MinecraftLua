--[[
  Compat shim — Factory Clutch lives under storage/workers/.
  Titan-Version: 1.1.0
]]
local path = "storage/workers/factory_clutch.lua"
if not fs.exists(path) then
  error("Missing: " .. path, 0)
end
dofile(path)
