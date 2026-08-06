--[[
  versions.lua  -  Titan package versions

  Bump `system` on every release, and bump each package you change.
  The console `packages` command shows these names + versions.
  Installers / OTA updates ship this file so devices know what they have.

  Titan-Version: 1.2.33
]]

return {
  system = "1.2.33",
  packages = {
    ["lib/titan.lua"]      = "1.2.13",
    ["console.lua"]        = "1.1.8",
    ["router.lua"]         = "1.2.15",
    ["host.lua"]           = "1.1.11",
    ["install.lua"]        = "1.1.13",
    ["github_install.lua"] = "1.1.13",
    ["pastebin_install.lua"]= "1.1.13",
    ["hub.lua"]            = "1.1.2",
    ["bot.lua"]            = "1.1.0",
    ["poi.lua"]            = "1.1.0",
    ["worker.lua"]         = "1.2.4",
    ["botserver.lua"]      = "1.2.5",
    ["datacenter.lua"]     = "1.2.11",
    ["admin.lua"]          = "1.2.1",
    ["miner.lua"]          = "1.2.10",
    ["loader.lua"]         = "1.0.1",
    ["marker.lua"]         = "1.0.2",
    ["storage_manager.lua"]= "1.0.4",
    ["gpshost.lua"]        = "1.1.7",
    ["locator.lua"]        = "1.2.0",
    ["exclude.txt"]        = "1.0.1",
    ["versions.lua"]       = "1.2.33",
  },
}
