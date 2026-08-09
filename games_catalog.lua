--[[
  games_catalog.lua  -  Titan games suite catalog
  Titan-Version: 1.0.5

  Source of truth for the Games launcher (`games.lua`).
  Add a new game here (+ versions.lua + ship the .lua) and every launcher
  will auto-download it on the next update check.

  Return shape:
    base   - GitHub raw root (trailing slash)
    games  - list of { id, name, run, files, desc? }
]]

return {
  version = "1.0.5",
  base = "https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/",
  -- Launcher self-update files (always kept current).
  launcher = {
    files = {
      "games.lua", "games_catalog.lua", "versions.lua",
      "lib/casino.lua", "lib/games_economy.lua",
    },
  },
  games = {
    {
      id = "tetris",
      name = "Tetris",
      run = "tetris.lua",
      desc = "Pocket / monitor + music (speaker; local LB)",
      files = { "lib/titan.lua", "tetris.lua", "versions.lua" },
    },
    {
      id = "minesweeper",
      name = "Minesweeper",
      run = "minesweeper.lua",
      desc = "Pocket / monitor mines",
      files = { "minesweeper.lua" },
    },
    {
      id = "luigi_poker",
      name = "Luigi Picture Poker",
      run = "luigi_poker.lua",
      desc = "Beat Luigi's hand (pocket-first)",
      files = { "luigi_poker.lua", "lib/casino.lua", "lib/games_economy.lua" },
    },
    {
      id = "higher_lower",
      name = "Higher / Lower Poker",
      run = "higher_lower.lua",
      desc = "Win the hand, then guess Higher or Lower",
      files = { "higher_lower.lua", "lib/casino.lua", "lib/games_economy.lua" },
    },
    {
      id = "slots",
      name = "Slots",
      run = "slots.lua",
      desc = "3-reel slots",
      files = { "slots.lua", "lib/casino.lua", "lib/games_economy.lua" },
    },
  },
}
