--[[
  Compat shim — Storage builder lives under storage/workers/.
  Titan-Version: 1.0.0
]]
local path = "storage/workers/storage_builder.lua"
if not fs.exists(path) then
  error("Missing " .. path .. " — reinstall Storage → Workers → Storage builder", 0)
end
shell.run(path)
