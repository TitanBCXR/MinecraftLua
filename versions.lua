--[[
  versions.lua  -  Titan package versions

  Bump `system` on every release, and bump each package you change.
  The console `packages` command shows these names + versions.
  Installers / OTA updates ship this file so devices know what they have.

  Titan-Version: 1.7.32
]]

return {
  system = "1.7.32",
  packages = {
    ["lib/titan.lua"]      = "1.2.26",
    ["lib/casino.lua"]     = "1.0.1",
    ["lib/games_economy.lua"] = "1.0.0",
    ["lib/games_music.lua"] = "1.0.0",
    ["lib/pocket_peripherals.lua"] = "1.0.5",
    ["lib/png.lua"]        = "1.1.1",
    ["console.lua"]        = "1.1.9",
    ["router.lua"]         = "1.4.4",
    ["router_main.lua"]    = "1.4.2",
    ["router_modem.lua"]   = "1.4.3",
    ["lib/router_hub_net.lua"] = "1.4.7",
    ["lib/router_hub_ui.lua"]  = "1.4.3",
    ["lib/router_hub_cmd.lua"] = "1.4.3",
    ["install.lua"]        = "1.2.16",
    ["github_install.lua"] = "1.2.19",
    ["pastebin_install.lua"]= "1.2.16",
    ["datacenter.lua"]     = "1.2.14",
    ["admin.lua"]          = "1.5.13",
    ["quarry/workers/offline_miner.lua"] = "1.8.2",
    ["quarry/workers/strip_miner.lua"]   = "1.0.7",
    ["quarry/workers/cell_scanner.lua"]  = "1.0.7",
    ["quarry/managers/offline_site.lua"] = "1.8.2",
    ["offline_miner.lua"]  = "1.0.0",
    ["offline_site.lua"]   = "1.0.0",
    ["storage/managers/storage_manager.lua"] = "1.0.0",
    ["storage/workers/storage_builder.lua"] = "1.0.0",
    ["storage/managers/storage_atm.lua"] = "1.4.0",
    ["storage/managers/storage_clutch.lua"] = "1.7.2",
    ["storage_manager.lua"] = "1.0.0",
    ["storage_builder.lua"] = "1.0.0",
    ["storage_atm.lua"] = "1.4.0",
    ["storage_clutch.lua"] = "1.7.2",
    ["games/managers/currency_manager.lua"] = "1.1.6",
    ["currency_manager.lua"] = "1.1.6",
    ["games/managers/casino_atm.lua"] = "1.1.0",
    ["casino_atm.lua"] = "1.1.0",
    ["perimeter_sensor.lua"] = "1.2.8",
    ["perimeter_manager.lua"]= "1.3.8",
    ["tetris.lua"]         = "1.3.3",
    ["minesweeper.lua"]    = "1.2.5",
    ["sandstorm.lua"]      = "1.0.2",
    ["luigi_poker.lua"]    = "1.2.9",
    ["higher_lower.lua"]   = "1.1.5",
    ["slots.lua"]          = "1.0.8",
    ["games.lua"]          = "1.2.11",
    ["games_catalog.lua"]  = "1.0.9",
    ["games_install.lua"]  = "1.0.4",
    ["image_loader.lua"]   = "1.3.2",
    ["host.lua"]           = "1.2.20",
    ["exclude.txt"]        = "1.0.1",
    ["versions.lua"]       = "1.7.32",
  },
}
