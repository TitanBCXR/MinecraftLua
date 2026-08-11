--[[
  games_music.lua  -  Shared speaker soundtracks for Titan minigames
  Titan-Version: 1.0.0

  Presets per game (menu + in-game where applicable). Settings live in
  games_launcher.cfg: musicSpeed, musicTrackGlobal, musicTracks{game=presetId}.

  Games call gm.newPlayer("tetris") then player:start("menu"|"game") and
  player:step(musicOn) each timer tick.
]]

local gm = {}

local STATE_FILE = "games_launcher.cfg"
local MUSIC_SPEED = 1.0
local MUSIC_TRACK_GLOBAL = nil -- preset id or nil = per-game default
local MUSIC_TRACKS = {}        -- game id -> preset id

local SPEAKER = nil

-- Track tables: { beat, legato, style, bass = {...}, melody = {{pitch, beats}|{false, beats}} }
local PRESETS = {
  tetris = {
    {
      id = "classic", name = "Classic",
      menu = {
        beat = 0.20, legato = 0.80, style = "menu",
        bass = { 4, 4, 4, 4, 2, 2, 2, 2, 0, 0, 0, 0, 4, 4, 7, 7 },
        melody = {
          {9, 2}, {12, 2}, {16, 3}, {12, 2}, {9, 2}, {7, 3}, {false, 1},
          {7, 2}, {11, 2}, {14, 3}, {11, 2}, {7, 2}, {4, 3}, {false, 1},
          {4, 2}, {7, 2}, {12, 3}, {9, 2}, {7, 2}, {9, 4}, {false, 2},
          {12, 2}, {16, 2}, {19, 3}, {16, 2}, {12, 2}, {9, 4}, {false, 3},
        },
      },
      game = {
        beat = 0.13, legato = 0.72, style = "game",
        bass = { 4, 4, 2, 2, 0, 0, 4, 4, 7, 7, 4, 4, 0, 0, 4, 4 },
        melody = {
          {16, 2}, {11, 1}, {12, 1}, {14, 2}, {12, 1}, {11, 1},
          {9, 2}, {9, 1}, {12, 1}, {16, 2}, {14, 1}, {12, 1},
          {11, 2}, {11, 1}, {12, 1}, {14, 2}, {16, 2},
          {12, 2}, {9, 2}, {9, 4}, {false, 2},
          {14, 2}, {17, 1}, {21, 2}, {19, 1}, {17, 1},
          {16, 3}, {12, 1}, {16, 2}, {14, 1}, {12, 1},
          {11, 2}, {11, 1}, {12, 1}, {14, 2}, {16, 2},
          {12, 2}, {9, 2}, {9, 4}, {false, 4},
        },
      },
    },
    {
      id = "arcade", name = "Arcade Rush",
      menu = {
        beat = 0.14, legato = 0.70, style = "menu",
        bass = { 0, 0, 3, 3, 5, 5, 7, 7, 0, 0, 3, 3, 5, 5, 7, 7 },
        melody = {
          {12, 1}, {14, 1}, {16, 2}, {14, 1}, {12, 1}, {9, 2},
          {7, 1}, {9, 1}, {12, 2}, {14, 2}, {16, 3}, {false, 1},
          {19, 2}, {16, 1}, {14, 1}, {12, 2}, {9, 2}, {7, 3},
        },
      },
      game = {
        beat = 0.11, legato = 0.65, style = "game",
        bass = { 0, 3, 5, 7, 0, 3, 5, 7, 2, 5, 7, 9, 2, 5, 7, 9 },
        melody = {
          {16, 1}, {16, 1}, {19, 1}, {16, 1}, {14, 2}, {12, 1}, {14, 2},
          {16, 1}, {19, 1}, {21, 2}, {19, 1}, {16, 2}, {14, 3},
          {12, 1}, {14, 1}, {16, 1}, {19, 2}, {21, 2}, {19, 3}, {false, 1},
        },
      },
    },
    {
      id = "zen", name = "Zen Garden",
      menu = {
        beat = 0.28, legato = 0.88, style = "menu",
        bass = { 2, 2, 4, 4, 2, 2, 0, 0, 2, 2, 4, 4, 7, 7, 4, 4 },
        melody = {
          {7, 3}, {9, 2}, {11, 4}, {9, 2}, {7, 3}, {false, 2},
          {4, 3}, {7, 2}, {9, 4}, {7, 2}, {4, 4}, {false, 3},
        },
      },
      game = {
        beat = 0.24, legato = 0.85, style = "menu",
        bass = { 0, 0, 2, 2, 4, 4, 2, 2, 0, 0, 2, 2, 4, 4, 7, 7 },
        melody = {
          {9, 2}, {11, 2}, {12, 3}, {11, 2}, {9, 4}, {false, 1},
          {7, 2}, {9, 2}, {11, 3}, {9, 2}, {7, 4}, {false, 2},
          {4, 2}, {7, 2}, {9, 4}, {7, 2}, {4, 4}, {false, 3},
        },
      },
    },
  },
  minesweeper = {
    {
      id = "default", name = "Probe Pulse",
      menu = {
        beat = 0.22, legato = 0.82, style = "menu",
        bass = { 2, 2, 2, 2, 5, 5, 5, 5, 0, 0, 7, 7, 2, 2, 5, 5 },
        melody = {
          {7, 2}, {9, 2}, {12, 3}, {9, 2}, {7, 2}, {5, 3}, {false, 1},
          {5, 2}, {7, 2}, {11, 3}, {7, 2}, {5, 2}, {2, 4}, {false, 2},
          {9, 2}, {12, 2}, {14, 3}, {12, 2}, {9, 2}, {7, 4}, {false, 2},
        },
      },
      game = {
        beat = 0.15, legato = 0.74, style = "tense",
        bass = { 0, 0, 3, 3, 5, 5, 3, 3, 0, 0, 7, 7, 5, 5, 3, 3 },
        melody = {
          {12, 1}, {false, 1}, {12, 1}, {11, 1}, {9, 2}, {7, 2},
          {9, 1}, {11, 1}, {12, 2}, {14, 2}, {12, 2}, {false, 1},
          {14, 1}, {12, 1}, {11, 2}, {9, 2}, {7, 2}, {9, 3}, {false, 2},
          {7, 1}, {9, 1}, {11, 1}, {12, 2}, {11, 1}, {9, 2}, {7, 3}, {false, 2},
        },
      },
    },
    {
      id = "stealth", name = "Stealth Sweep",
      menu = {
        beat = 0.26, legato = 0.86, style = "menu",
        bass = { 0, 0, 0, 0, 3, 3, 3, 3, 5, 5, 5, 5, 0, 0, 3, 3 },
        melody = {
          {5, 2}, {7, 2}, {9, 3}, {7, 2}, {5, 4}, {false, 2},
          {4, 2}, {5, 2}, {7, 3}, {5, 2}, {4, 4}, {false, 3},
        },
      },
      game = {
        beat = 0.18, legato = 0.78, style = "tense",
        bass = { 0, 0, 0, 0, 2, 2, 2, 2, 5, 5, 5, 5, 0, 0, 2, 2 },
        melody = {
          {9, 1}, {false, 2}, {9, 1}, {7, 1}, {5, 2}, {false, 1},
          {7, 1}, {9, 1}, {11, 2}, {9, 1}, {7, 3}, {false, 2},
        },
      },
    },
    {
      id = "radar", name = "Radar Ping",
      menu = {
        beat = 0.20, legato = 0.80, style = "menu",
        bass = { 3, 3, 3, 3, 7, 7, 7, 7, 3, 3, 3, 3, 7, 7, 7, 7 },
        melody = {
          {12, 1}, {false, 1}, {12, 2}, {14, 2}, {12, 3}, {false, 1},
          {9, 2}, {12, 2}, {14, 3}, {12, 2}, {9, 4}, {false, 2},
        },
      },
      game = {
        beat = 0.12, legato = 0.68, style = "tense",
        bass = { 0, 0, 5, 5, 0, 0, 5, 5, 3, 3, 7, 7, 3, 3, 7, 7 },
        melody = {
          {14, 1}, {false, 1}, {14, 1}, {12, 1}, {14, 1}, {false, 1},
          {16, 2}, {14, 1}, {12, 2}, {11, 2}, {9, 3}, {false, 1},
          {12, 1}, {14, 1}, {16, 2}, {14, 1}, {12, 3}, {false, 2},
        },
      },
    },
  },
  luigi_poker = {
    {
      id = "mario", name = "Mario Bed",
      menu = {
        beat = 0.16, legato = 0.78, style = "casino",
        bass = { 2, 2, 2, 2, 0, 0, 0, 0, 2, 2, 2, 2, 0, 0, 0, 0 },
        melody = {
          {7, 2}, {10, 2}, {12, 2}, {10, 2}, {7, 2}, {5, 2}, {7, 3}, {false, 1},
          {10, 2}, {12, 2}, {14, 2}, {12, 2}, {10, 2}, {7, 3}, {false, 2},
        },
      },
    },
    {
      id = "casino", name = "Vegas Lounge",
      menu = {
        beat = 0.18, legato = 0.80, style = "casino",
        bass = { 0, 0, 4, 4, 7, 7, 4, 4, 0, 0, 4, 4, 7, 7, 4, 4 },
        melody = {
          {9, 2}, {12, 2}, {14, 3}, {12, 2}, {9, 2}, {7, 3}, {false, 1},
          {11, 2}, {14, 2}, {16, 3}, {14, 2}, {11, 4}, {false, 2},
        },
      },
    },
    {
      id = "spooky", name = "Luigi Mansion",
      menu = {
        beat = 0.24, legato = 0.85, style = "menu",
        bass = { 0, 0, 2, 2, 3, 3, 2, 2, 0, 0, 2, 2, 5, 5, 3, 3 },
        melody = {
          {7, 2}, {8, 1}, {7, 1}, {5, 3}, {false, 1},
          {4, 2}, {5, 2}, {7, 3}, {5, 2}, {4, 4}, {false, 2},
          {7, 1}, {8, 1}, {10, 2}, {8, 1}, {7, 4}, {false, 3},
        },
      },
    },
  },
  slots = {
    {
      id = "vegas", name = "Vegas Bells",
      menu = {
        beat = 0.17, legato = 0.76, style = "casino",
        bass = { 0, 0, 4, 4, 0, 0, 7, 7, 0, 0, 4, 4, 0, 0, 7, 7 },
        melody = {
          {12, 1}, {12, 1}, {14, 2}, {12, 1}, {9, 2}, {7, 3}, {false, 1},
          {9, 1}, {12, 1}, {14, 2}, {16, 2}, {14, 3}, {false, 2},
        },
      },
    },
    {
      id = "jackpot", name = "Jackpot Fever",
      menu = {
        beat = 0.13, legato = 0.70, style = "casino",
        bass = { 0, 3, 5, 7, 0, 3, 5, 7, 0, 3, 5, 7, 0, 3, 5, 7 },
        melody = {
          {16, 1}, {19, 1}, {16, 1}, {14, 1}, {12, 2}, {14, 2}, {16, 3},
          {19, 1}, {21, 1}, {19, 1}, {16, 2}, {14, 3}, {false, 1},
        },
      },
    },
    {
      id = "chime", name = "Coin Chime",
      menu = {
        beat = 0.20, legato = 0.82, style = "menu",
        bass = { 4, 4, 2, 2, 4, 4, 2, 2, 0, 0, 4, 4, 2, 2, 0, 0 },
        melody = {
          {14, 2}, {12, 2}, {9, 2}, {7, 3}, {false, 1},
          {9, 2}, {12, 2}, {14, 3}, {12, 2}, {9, 4}, {false, 2},
        },
      },
    },
  },
  higher_lower = {
    {
      id = "streak", name = "Streak Pulse",
      menu = {
        beat = 0.16, legato = 0.78, style = "casino",
        bass = { 0, 0, 2, 2, 4, 4, 2, 2, 0, 0, 2, 2, 5, 5, 4, 4 },
        melody = {
          {9, 2}, {11, 2}, {12, 2}, {14, 2}, {12, 2}, {11, 2}, {9, 3}, {false, 1},
          {7, 2}, {9, 2}, {11, 2}, {12, 3}, {false, 2},
        },
      },
    },
    {
      id = "highroller", name = "High Roller",
      menu = {
        beat = 0.14, legato = 0.72, style = "casino",
        bass = { 0, 3, 5, 7, 0, 3, 5, 7, 2, 5, 7, 9, 2, 5, 7, 9 },
        melody = {
          {12, 1}, {14, 1}, {16, 2}, {14, 1}, {12, 1}, {11, 2},
          {12, 1}, {14, 1}, {16, 2}, {19, 2}, {16, 3}, {false, 1},
        },
      },
    },
    {
      id = "suspense", name = "Card Suspense",
      menu = {
        beat = 0.22, legato = 0.84, style = "menu",
        bass = { 0, 0, 0, 0, 2, 2, 2, 2, 0, 0, 0, 0, 5, 5, 5, 5 },
        melody = {
          {7, 3}, {false, 1}, {9, 2}, {7, 2}, {5, 4}, {false, 2},
          {4, 2}, {5, 2}, {7, 3}, {9, 2}, {7, 4}, {false, 3},
        },
      },
    },
  },
}

-- Fix slots chime preset (legacy typo guard)
do
  local ch = PRESETS.slots and PRESETS.slots[3] and PRESETS.slots[3].menu
  if ch and ch.melody and ch.melody[1] then ch.melody[1][2] = 2 end
end

function gm.listGames()
  local out = {}
  for id in pairs(PRESETS) do out[#out + 1] = id end
  table.sort(out)
  return out
end

function gm.listPresets(gameId)
  local list = PRESETS[gameId] or {}
  local out = {}
  for i = 1, #list do
    out[i] = { id = list[i].id, name = list[i].name }
  end
  return out
end

function gm.defaultPresetId(gameId)
  local list = PRESETS[gameId]
  if list and list[1] then return list[1].id end
  return "default"
end

function gm.presetLabel(gameId, presetId)
  for _, p in ipairs(PRESETS[gameId] or {}) do
    if p.id == presetId then return p.name end
  end
  return presetId or "?"
end

function gm.loadSettings(data)
  if type(data) == "table" then
    MUSIC_SPEED = tonumber(data.musicSpeed) or 1.0
    MUSIC_TRACK_GLOBAL = type(data.musicTrackGlobal) == "string" and data.musicTrackGlobal or nil
    MUSIC_TRACKS = {}
    if type(data.musicTracks) == "table" then
      for k, v in pairs(data.musicTracks) do
        if type(k) == "string" and type(v) == "string" then MUSIC_TRACKS[k] = v end
      end
    end
    return
  end
  if not fs.exists(STATE_FILE) then return end
  local f = fs.open(STATE_FILE, "r")
  if not f then return end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return end
  gm.loadSettings(d)
end

function gm.exportSettings()
  return {
    musicSpeed = MUSIC_SPEED,
    musicTrackGlobal = MUSIC_TRACK_GLOBAL,
    musicTracks = MUSIC_TRACKS,
  }
end

function gm.getSpeed()
  return MUSIC_SPEED
end

function gm.setSpeed(v)
  v = tonumber(v) or 1.0
  if v < 0.5 then v = 0.5 elseif v > 2.0 then v = 2.0 end
  MUSIC_SPEED = v
end

function gm.getGlobalTrack()
  return MUSIC_TRACK_GLOBAL
end

function gm.setGlobalTrack(id)
  MUSIC_TRACK_GLOBAL = (id and id ~= "") and id or nil
end

function gm.getTrack(gameId)
  if MUSIC_TRACKS[gameId] then return MUSIC_TRACKS[gameId] end
  if MUSIC_TRACK_GLOBAL then
    for _, p in ipairs(PRESETS[gameId] or {}) do
      if p.id == MUSIC_TRACK_GLOBAL then return p.id end
    end
  end
  return gm.defaultPresetId(gameId)
end

function gm.setTrack(gameId, presetId)
  if presetId == nil or presetId == "" or presetId == gm.defaultPresetId(gameId) then
    MUSIC_TRACKS[gameId] = nil
  else
    MUSIC_TRACKS[gameId] = presetId
  end
end

function gm.cycleTrack(gameId, dir)
  dir = dir or 1
  local list = PRESETS[gameId] or {}
  if #list == 0 then return gm.getTrack(gameId) end
  local cur = gm.getTrack(gameId)
  local idx = 1
  for i = 1, #list do
    if list[i].id == cur then idx = i; break end
  end
  idx = ((idx - 1 + dir) % #list) + 1
  local id = list[idx].id
  gm.setTrack(gameId, id == gm.defaultPresetId(gameId) and nil or id)
  return list[idx].id, list[idx].name
end

local function resolvePreset(gameId, presetId)
  for _, p in ipairs(PRESETS[gameId] or {}) do
    if p.id == presetId then return p end
  end
  local list = PRESETS[gameId]
  return list and list[1] or nil
end

local function refreshSpeaker()
  SPEAKER = peripheral.find("speaker")
  return SPEAKER ~= nil
end

local function playSoft(instrument, volume, pitch)
  if not SPEAKER or pitch == nil or pitch == false then return end
  if pitch < 0 or pitch > 24 then return end
  pcall(function() SPEAKER.playNote(instrument, volume, pitch) end)
end

local function renderStep(tr, idx, bassPulse)
  local melody, bass = tr.melody, tr.bass
  local note = melody[idx] or { false, 1 }
  local pitch, beats = note[1], tonumber(note[2]) or 1
  local bassPitch = bass[((bassPulse - 1) % #bass) + 1]
  local style = tr.style or "menu"

  if style == "menu" then
    playSoft("bass", 0.16, bassPitch)
    if pitch ~= false and pitch ~= nil then
      playSoft("flute", 0.28, pitch)
      playSoft("chime", 0.12, pitch)
      playSoft("guitar", 0.12, math.max(0, pitch - 5))
    else
      playSoft("harp", 0.08, math.min(24, bassPitch + 12))
    end
  elseif style == "game" then
    playSoft("bass", 0.22, bassPitch)
    if pitch ~= false and pitch ~= nil then
      playSoft("harp", 0.42, pitch)
      playSoft("pling", 0.18, pitch)
      local harmony = pitch - 5
      if harmony < 0 then harmony = pitch + 3 end
      playSoft("guitar", 0.16, harmony)
      if beats >= 2 then
        playSoft("flute", 0.14, math.min(24, pitch + 7))
      end
    else
      playSoft("guitar", 0.10, bassPitch + 12 <= 24 and bassPitch + 12 or bassPitch)
    end
  elseif style == "tense" then
    playSoft("bass", tr.beat and tr.beat < 0.17 and 0.20 or 0.14, bassPitch)
    if pitch ~= false and pitch ~= nil then
      playSoft("pling", 0.28, pitch)
      playSoft("guitar", 0.12, math.max(0, pitch - 7))
    end
    if bassPulse % 2 == 0 then playSoft("hat", 0.10, 18) end
  elseif style == "casino" then
    playSoft("bass", 0.12, bassPitch)
    if pitch ~= false and pitch ~= nil then
      playSoft("pling", 0.22, pitch)
      playSoft("guitar", 0.10, math.max(0, pitch - 5))
    end
  end

  local wait = beats * (tr.beat or 0.16) * (tr.legato or 0.75)
  return math.max(0.06, wait / MUSIC_SPEED)
end

function gm.newPlayer(gameId)
  local player = {
    gameId = gameId,
    context = "menu",
    idx = 1,
    bassPulse = 0,
    trackName = nil,
  }

  function player:resolveTrackTable()
    local presetId = gm.getTrack(self.gameId)
    local preset = resolvePreset(self.gameId, presetId)
    if not preset then return nil end
    return preset[self.context] or preset.menu or preset.game
  end

  function player:start(context)
    context = context or "menu"
    if context ~= self.context then
      if SPEAKER then pcall(function() SPEAKER.stop() end) end
    end
    self.context = context
    self.idx = 1
    self.bassPulse = 0
    self.trackName = context
    return refreshSpeaker()
  end

  function player:stop()
    if SPEAKER then pcall(function() SPEAKER.stop() end) end
  end

  function player:step(enabled)
    if not enabled then return 0.5 end
    if not SPEAKER and not refreshSpeaker() then return 1.0 end
    local tr = self:resolveTrackTable()
    if not tr then return 1.0 end
    self.bassPulse = self.bassPulse + 1
    local wait = renderStep(tr, self.idx, self.bassPulse)
    self.idx = self.idx + 1
    if self.idx > #tr.melody then self.idx = 1 end
    return wait
  end

  function player:refreshSpeaker()
    return refreshSpeaker()
  end

  return player
end

function gm.playSfx(kind)
  if not refreshSpeaker() then return end
  if kind == "tick" then playSoft("hat", 0.18, 12)
  elseif kind == "win" then playSoft("chime", 0.45, 20); playSoft("pling", 0.35, 24)
  elseif kind == "lose" then playSoft("bass", 0.28, 1)
  elseif kind == "coin" then playSoft("pling", 0.22, 15)
  end
end

gm.loadSettings()

return gm
