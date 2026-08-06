--[[
  versions.lua  -  Titan package versions

  Bump `system` on every release, and bump each package you change.
  The console `packages` command shows these names + versions.
  Installers / OTA updates ship this file so devices know what they have.

  Titan-Version: 1.2.23
]]

return {
  system = "1.2.23",
  packages = {
    ["lib/titan.lua"]      = "1.2.8",
    ["console.lua"]        = "1.1.8",
    ["router.lua"]         = "1.2.13",
    ["host.lua"]           = "1.1.8",
    ["install.lua"]        = "1.1.9",
    ["github_install.lua"] = "1.1.9",
    ["pastebin_install.lua"]= "1.1.9",
    ["hub.lua"]            = "1.1.1",
    ["bot.lua"]            = "1.1.0",
    ["poi.lua"]            = "1.1.0",
    ["worker.lua"]         = "1.2.3",
    ["botserver.lua"]      = "1.2.3",
    ["datacenter.lua"]     = "1.2.4",
    ["admin.lua"]          = "1.1.9",
    ["miner.lua"]          = "1.2.7",
    ["storage_manager.lua"]= "1.0.3",
    ["train_node.lua"]     = "1.0.0",
    ["gpshost.lua"]        = "1.1.7",
    ["locator.lua"]        = "1.2.0",
    ["exclude.txt"]        = "1.0.0",
    ["versions.lua"]       = "1.2.23",
  },
}
