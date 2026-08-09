--[[
  Compat shim — quarry site board lives under quarry/managers/.
  Titan-Version: 1.0.0
]]
local path = "quarry/managers/offline_site.lua"
if not fs.exists(path) then
  error("Missing " .. path .. " — reinstall Quarry → Managers → Site board", 0)
end
shell.run(path)
