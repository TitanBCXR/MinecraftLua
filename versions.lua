--[[
  versions.lua  -  Titan package versions

  Bump `system` on every release, and bump each package you change.
  The console `packages` command shows these names + versions.
  Installers / OTA updates ship this file so devices know what they have.

  Titan-Version: 1.1.5
]]

return {
  system = "1.1.5",
  packages = {
    ["lib/titan.lua"]      = "1.1.4",
    ["console.lua"]        = "1.1.1",
    ["router.lua"]         = "1.1.5",
    ["host.lua"]           = "1.1.0",
    ["install.lua"]        = "1.1.1",
    ["github_install.lua"] = "1.1.1",
    ["pastebin_install.lua"]= "1.1.1",
    ["hub.lua"]            = "1.1.0",
    ["bot.lua"]            = "1.1.0",
    ["poi.lua"]            = "1.1.0",
    ["worker.lua"]         = "1.1.0",
    ["botserver.lua"]      = "1.1.0",
    ["datacenter.lua"]     = "1.1.2",
    ["admin.lua"]          = "1.1.0",
    ["miner.lua"]          = "1.1.0",
    ["gpshost.lua"]        = "1.1.0",
    ["locator.lua"]        = "1.1.4",
    ["exclude.txt"]        = "1.0.0",
    ["versions.lua"]       = "1.1.5",
  },
}
