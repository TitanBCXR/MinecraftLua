--[[
  versions.lua  -  Titan package versions

  Bump `system` on every release, and bump each package you change.
  The console `packages` command shows these names + versions.
  Installers / OTA updates ship this file so devices know what they have.

  Titan-Version: 1.5.28
]]

return {
  system = "1.5.28",
  packages = {
    ["lib/titan.lua"]      = "1.2.19",
    ["console.lua"]        = "1.1.8",
    ["router.lua"]         = "1.4.2",
    ["router_main.lua"]    = "1.4.1",
    ["router_modem.lua"]   = "1.4.0",
    ["lib/router_hub_net.lua"] = "1.4.2",
    ["lib/router_hub_ui.lua"]  = "1.4.2",
    ["lib/router_hub_cmd.lua"] = "1.4.1",
    ["host.lua"]           = "1.1.16",
    ["install.lua"]        = "1.1.20",
    ["github_install.lua"] = "1.1.20",
    ["pastebin_install.lua"]= "1.1.20",
    ["hub.lua"]            = "1.1.2",
    ["bot.lua"]            = "1.1.0",
    ["poi.lua"]            = "1.1.0",
    ["worker.lua"]         = "1.2.4",
    ["botserver.lua"]      = "1.2.5",
    ["datacenter.lua"]     = "1.2.13",
    ["admin.lua"]          = "1.4.7",
    ["miner.lua"]          = "1.3.1",
    ["offline_miner.lua"]  = "1.4.2",
    ["offline_site.lua"]   = "1.2.1",
    ["chest_sucker.lua"]   = "1.0.0",
    ["loader.lua"]         = "1.0.1",
    ["marker.lua"]         = "1.1.0",
    ["storage_manager.lua"]= "1.0.4",
    ["gpshost.lua"]        = "1.1.7",
    ["locator.lua"]        = "1.2.0",
    ["perimeter_sensor.lua"] = "1.2.2",
    ["perimeter_manager.lua"]= "1.3.1",
    ["exclude.txt"]        = "1.0.1",
    ["versions.lua"]       = "1.5.28",
  },
}
