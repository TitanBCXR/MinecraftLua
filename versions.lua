--[[
  versions.lua  -  Titan package versions

  Bump `system` on every release, and bump each package you change.
  The console `packages` command shows these names + versions.
  Installers / OTA updates ship this file so devices know what they have.

  Titan-Version: 1.2.17
]]

return {
  system = "1.2.17",
  packages = {
    ["lib/titan.lua"]      = "1.2.6",
    ["console.lua"]        = "1.1.6",
    ["router.lua"]         = "1.2.11",
    ["host.lua"]           = "1.1.7",
    ["install.lua"]        = "1.1.7",
    ["github_install.lua"] = "1.1.7",
    ["pastebin_install.lua"]= "1.1.7",
    ["hub.lua"]            = "1.1.0",
    ["bot.lua"]            = "1.1.0",
    ["poi.lua"]            = "1.1.0",
    ["worker.lua"]         = "1.2.2",
    ["botserver.lua"]      = "1.2.1",
    ["datacenter.lua"]     = "1.2.1",
    ["admin.lua"]          = "1.1.7",
    ["miner.lua"]          = "1.2.5",
    ["storage_manager.lua"]= "1.0.1",
    ["gpshost.lua"]        = "1.1.7",
    ["locator.lua"]        = "1.2.0",
    ["exclude.txt"]        = "1.0.0",
    ["versions.lua"]       = "1.2.17",
  },
}
