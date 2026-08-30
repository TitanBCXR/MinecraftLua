--[[
  Compat shim — Storage Manager lives under storage/managers/.
  Titan-Version: 1.3.1
]]
local path = "storage/managers/storage_manager.lua"
if not fs.exists(path) then
  error("Missing " .. path .. " — reinstall Storage → Managers → Storage Manager", 0)
end
shell.run(path)
