--[[
  Compat shim — Storage Clutch lives under storage/managers/.
  Titan-Version: 1.8.10
]]
local path = "storage/managers/storage_clutch.lua"
if not fs.exists(path) then
  error("Missing " .. path .. " — reinstall Storage Clutch", 0)
end
shell.run(path)
