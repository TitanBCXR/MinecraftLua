--[[
  versions.lua  -  Titan package versions

  Bump `system` on every release, and bump each package you change.
  The console `packages` command shows these names + versions.
  Installers / OTA updates ship this file so devices know what they have.

  Titan-Version: 1.3.1
]]

return {
  system = "1.3.1",
  packages = {
    ["lib/titan.lua"]      = "1.2.15",
    ["console.lua"]        = "1.1.8",
    ["router.lua"]         = "1.2.16",
    ["host.lua"]           = "1.1.12",
    ["install.lua"]        = "1.1.15",
    ["github_install.lua"] = "1.1.15",
    ["pastebin_install.lua"]= "1.1.15",
    ["hub.lua"]            = "1.1.2",
    ["bot.lua"]            = "1.1.0",
    ["poi.lua"]            = "1.1.0",
    ["worker.lua"]         = "1.2.4",
    ["botserver.lua"]      = "1.2.5",
    ["datacenter.lua"]     = "1.2.13",
    ["admin.lua"]          = "1.3.0",
    ["miner.lua"]          = "1.3.0",
    ["offline_miner.lua"]  = "1.0.8",
    ["loader.lua"]         = "1.0.1",
    ["marker.lua"]         = "1.1.0",
    ["storage_manager.lua"]= "1.0.4",
    ["gpshost.lua"]        = "1.1.7",
    ["locator.lua"]        = "1.2.0",
    ["perimeter_sensor.lua"] = "1.0.0",
    ["perimeter_manager.lua"]= "1.0.0",
    ["exclude.txt"]        = "1.0.1",
    ["versions.lua"]       = "1.3.1",
  },
}
