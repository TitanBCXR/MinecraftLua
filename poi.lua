--[[
  poi.lua  -  "Point of Interest" computer for the Titan network (CC: Tweaked)

  Runs on a normal (or advanced) computer placed AT a location you care about
  (a mine, a farm, a base, a smelter, etc). It has:
    * a wireless modem

  On first run it asks for a NAME and DESCRIPTION for this location and tries
  to read its coordinates from GPS. If no GPS is available you can type the
  coords in manually. The config is saved to `poi.cfg` so it only asks once.

  It then:
    * registers this location with the hub (name + coords + description)
    * gives you a tiny menu to summon a bot here to do a job

  Reset the location by deleting `poi.cfg`.
]]

local titan = dofile("lib/titan.lua")
titan.openModem()

local CFG_PATH = "poi.cfg"

-- Load or create this POI's config -------------------------------------------
local function loadConfig()
  if fs.exists(CFG_PATH) then
    local f = fs.open(CFG_PATH, "r")
    local data = textutils.unserialize(f.readAll())
    f.close()
    if data then return data end
  end
  return nil
end

local function saveConfig(cfg)
  local f = fs.open(CFG_PATH, "w")
  f.write(textutils.serialize(cfg))
  f.close()
end

local function ask(prompt, default)
  write(prompt .. (default and (" [" .. default .. "]") or "") .. ": ")
  local v = read()
  if v == "" then return default end
  return v
end

local function firstRun()
  print("== New Point of Interest ==")
  local name = ask("Location name", "poi-" .. os.getComputerID())
  local desc = ask("Description", "")

  print("Locating via GPS...")
  local x, y, z = gps.locate(3)
  if x then
    x, y, z = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
    print(("GPS: %d, %d, %d"):format(x, y, z))
  else
    print("No GPS signal - enter coordinates manually.")
    x = tonumber(ask("X")) or 0
    y = tonumber(ask("Y")) or 0
    z = tonumber(ask("Z")) or 0
  end

  local cfg = { name = name, desc = desc, x = x, y = y, z = z }
  saveConfig(cfg)
  return cfg
end

local cfg = loadConfig() or firstRun()
os.setComputerLabel(cfg.name)

-- Tell the hub we exist.
local function announce()
  titan.broadcast(titan.MSG.POI_REGISTER, {
    poi = cfg.name, desc = cfg.desc, x = cfg.x, y = cfg.y, z = cfg.z,
  })
end

-- Keep re-announcing in the background so a hub that starts later still learns us.
local function beaconLoop()
  while true do
    announce()
    os.sleep(10)
  end
end

-- Also answer pings from the hub.
local function replyLoop()
  while true do
    local id, msg = titan.recv()
    if msg and msg.type == titan.MSG.PING then
      announce()
    end
  end
end

-- Simple summon menu.
local function menuLoop()
  local jobList = { "none", "mine", "deposit" }   -- must match jobs in bot.lua
  while true do
    term.clear(); term.setCursorPos(1, 1)
    print("== POI: " .. cfg.name .. " ==")
    print(("Location: %d, %d, %d"):format(cfg.x, cfg.y, cfg.z))
    if cfg.desc ~= "" then print("Desc: " .. cfg.desc) end
    print("")
    print("1) Summon a bot here")
    print("2) Summon a bot + run a job")
    print("3) Re-announce to hub")
    print("Q) Quit")
    write("> ")
    local choice = read():lower()

    if choice == "1" then
      titan.broadcast(titan.MSG.DISPATCH, { poi = cfg.name })
      print("Requested a bot. Waiting..."); os.sleep(1.5)

    elseif choice == "2" then
      print("Jobs:")
      for i, j in ipairs(jobList) do print("  " .. i .. ") " .. j) end
      write("job #> ")
      local j = jobList[tonumber(read() or "") or 1] or "none"
      titan.broadcast(titan.MSG.DISPATCH,
        { poi = cfg.name, job = (j ~= "none" and j or nil) })
      print("Requested a bot for job: " .. j); os.sleep(1.5)

    elseif choice == "3" then
      announce(); print("Announced."); os.sleep(1)

    elseif choice == "q" then
      return
    end
  end
end

print("POI '" .. cfg.name .. "' online.")
parallel.waitForAny(beaconLoop, replyLoop, menuLoop,
  function() titan.registerLoop("poi") end)
print("POI stopped.")
