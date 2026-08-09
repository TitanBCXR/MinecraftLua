--[[
  versions.lua  -  Titan package versions

  Bump `system` on every release, and bump each package you change.
  The console `packages` command shows these names + versions.
  Installers / OTA updates ship this file so devices know what they have.

  Titan-Version: 1.6.82
]]

return {
  system = "1.6.82",
  packages = {
    ["lib/titan.lua"]      = "1.2.26",
    ["lib/casino.lua"]     = "1.0.1",
    ["lib/games_economy.lua"] = "1.0.0",
    ["console.lua"]        = "1.1.9",
    ["router.lua"]         = "1.4.4",
    ["router_main.lua"]    = "1.4.2",
    ["router_modem.lua"]   = "1.4.2",
    ["lib/router_hub_net.lua"] = "1.4.6",
    ["lib/router_hub_ui.lua"]  = "1.4.3",
    ["lib/router_hub_cmd.lua"] = "1.4.3",
    ["install.lua"]        = "1.2.13",
    ["github_install.lua"] = "1.2.16",
    ["pastebin_install.lua"]= "1.2.13",
    ["datacenter.lua"]     = "1.2.14",
    ["admin.lua"]          = "1.5.9",
    ["quarry/workers/offline_miner.lua"] = "1.6.0",
    ["quarry/workers/strip_miner.lua"]   = "1.0.3",
    ["quarry/managers/offline_site.lua"] = "1.4.0",
    ["offline_miner.lua"]  = "1.0.0",
    ["offline_site.lua"]   = "1.0.0",
    ["storage/managers/storage_manager.lua"] = "1.0.0",
    ["storage/workers/storage_builder.lua"] = "1.0.0",
    ["storage/managers/storage_atm.lua"] = "1.3.0",
    ["storage_manager.lua"] = "1.0.0",
    ["storage_builder.lua"] = "1.0.0",
    ["storage_atm.lua"] = "1.3.0",
    ["games/managers/currency_manager.lua"] = "1.0.5",
    ["currency_manager.lua"] = "1.0.5",
    ["games/managers/casino_atm.lua"] = "1.0.0",
    ["casino_atm.lua"] = "1.0.0",
    ["perimeter_sensor.lua"] = "1.2.8",
    ["perimeter_manager.lua"]= "1.3.8",
    ["tetris.lua"]         = "1.2.8",
    ["minesweeper.lua"]    = "1.2.3",
    ["sandstorm.lua"]      = "1.0.1",
    ["luigi_poker.lua"]    = "1.2.6",
    ["higher_lower.lua"]   = "1.1.2",
    ["slots.lua"]          = "1.0.5",
    ["games.lua"]          = "1.0.7",
    ["games_catalog.lua"]  = "1.0.6",
    ["games_install.lua"]  = "1.0.3",
    ["host.lua"]           = "1.2.15",
    ["exclude.txt"]        = "1.0.1",
    ["versions.lua"]       = "1.6.82",
  },
}
