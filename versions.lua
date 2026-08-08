--[[
  versions.lua  -  Titan package versions

  Bump `system` on every release, and bump each package you change.
  The console `packages` command shows these names + versions.
  Installers / OTA updates ship this file so devices know what they have.

  Titan-Version: 1.6.23
]]

return {
  system = "1.6.23",
  packages = {
    ["lib/titan.lua"]      = "1.2.23",
    ["console.lua"]        = "1.1.8",
    ["router.lua"]         = "1.4.4",
    ["router_main.lua"]    = "1.4.2",
    ["router_modem.lua"]   = "1.4.2",
    ["lib/router_hub_net.lua"] = "1.4.4",
    ["lib/router_hub_ui.lua"]  = "1.4.3",
    ["lib/router_hub_cmd.lua"] = "1.4.2",
    ["install.lua"]        = "1.2.0",
    ["github_install.lua"] = "1.2.0",
    ["pastebin_install.lua"]= "1.2.0",
    ["datacenter.lua"]     = "1.2.14",
    ["admin.lua"]          = "1.5.4",
    ["offline_miner.lua"]  = "1.5.6",
    ["offline_site.lua"]   = "1.3.3",
    ["perimeter_sensor.lua"] = "1.2.3",
    ["perimeter_manager.lua"]= "1.3.2",
    ["tetris.lua"]         = "1.0.10",
    ["host.lua"]           = "1.2.4",
    ["exclude.txt"]        = "1.0.1",
    ["versions.lua"]       = "1.6.23",
  },
}
