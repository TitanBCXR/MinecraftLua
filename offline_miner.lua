--[[
  Compat shim — cell quarry worker lives under quarry/workers/.
  Titan-Version: 1.0.0
]]
local path = "quarry/workers/offline_miner.lua"
if not fs.exists(path) then
  error("Missing " .. path .. " — reinstall Quarry → Workers → Cell miner", 0)
end
shell.run(path)
