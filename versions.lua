--[[
  versions.lua  -  Titan package versions

  Bump `system` on every release, and bump each package you change.
  The console `packages` command shows these names + versions.
  Installers / OTA updates ship this file so devices know what they have.

  Titan-Version: 1.6.55
]]

return {
  system = "1.6.55",
  packages = {
    ["lib/titan.lua"]      = "1.2.25",
    ["console.lua"]        = "1.1.8",
    ["router.lua"]         = "1.4.4",
    ["router_main.lua"]    = "1.4.2",
    ["router_modem.lua"]   = "1.4.2",
    ["lib/router_hub_net.lua"] = "1.4.6",
    ["lib/router_hub_ui.lua"]  = "1.4.3",
    ["lib/router_hub_cmd.lua"] = "1.4.2",
    ["install.lua"]        = "1.2.7",
    ["github_install.lua"] = "1.2.9",
    ["pastebin_install.lua"]= "1.2.7",
    ["datacenter.lua"]     = "1.2.14",
    ["admin.lua"]          = "1.5.7",
    ["offline_miner.lua"]  = "1.5.9",
    ["offline_site.lua"]   = "1.3.3",
    ["perimeter_sensor.lua"] = "1.2.8",
    ["perimeter_manager.lua"]= "1.3.8",
    ["tetris.lua"]         = "1.2.8",
    ["minesweeper.lua"]    = "1.2.2",
    ["sandstorm.lua"]      = "1.0.1",
    ["luigi_poker.lua"]    = "1.2.1",
    ["slots.lua"]          = "1.0.1",
    ["games.lua"]          = "1.0.2",
    ["games_catalog.lua"]  = "1.0.1",
    ["games_install.lua"]  = "1.0.0",
    ["host.lua"]           = "1.2.9",
    ["exclude.txt"]        = "1.0.1",
    ["versions.lua"]       = "1.6.55",
  },
}
