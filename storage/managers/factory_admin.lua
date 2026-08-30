--[[
  storage/managers/factory_admin.lua  -  Factory Admin pocket tablet
  Titan-Version: 1.0.0

  Pocket computer + wireless modem admin interface for factory control.
  Manage ALL factory systems from the tablet (not SSH, not generic admin).

  Screens (color pocket GUI, tap-first; mono fallback):
  - Home: factory list, ON/OFF status, mode toggle
  - Detail: per-factory outputs/inputs, force ON/OFF
  - Items: per-item thresholds (maxShare, daysBuffer, demandRate)

  Hardware: Pocket computer + wireless modem
  
  Run: storage/managers/factory_admin
]]

local titan = nil
if fs.exists("lib/titan.lua") then
  local ok, t = pcall(dofile, "lib/titan.lua")
  if ok then titan = t end
end

local ui = nil
if fs.exists("lib/titan_ui.lua") then
  local ok, t = pcall(dofile, "lib/titan_ui.lua")
  if ok then ui = t end
end

local MSG = titan and titan.MSG or {}
local PROTO = (titan and titan.PROTOCOL) or "titan_net"
local VERSION = "1.0.0"

titan.openModem()

local managerId = nil
local snap = nil
local lastSnap = 0
local screen = "home"  -- "home" | "detail" | "items"
local selectedFactory = nil
local scrollOffset = 0

--------------------------------------------------------------------------------
-- Storage Manager discovery
--------------------------------------------------------------------------------
local function discoverManager()
  if managerId then return managerId end
  
  -- Ping for storage manager
  if titan and titan.broadcast then
    titan.broadcast({type = MSG.STORAGE_PING}, PROTO)
  else
    rednet.broadcast({type = MSG.STORAGE_PING}, PROTO)
  end
  
  -- Wait for response
  local timer = os.startTimer(2)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      break
    elseif ev == "rednet_message" and (p3 == PROTO or p3 == nil) and type(p2) == "table" then
      local msg, from = p2, p1
      if msg.type == MSG.STORAGE_STATUS or msg.type == "storage_status" then
        managerId = from
        os.cancelTimer(timer)
        return managerId
      end
    end
  end
  
  return nil
end

--------------------------------------------------------------------------------
-- Request snapshot from manager
--------------------------------------------------------------------------------
local function requestSnap()
  if not managerId then
    managerId = discoverManager()
    if not managerId then return end
  end
  
  if titan and titan.send then
    titan.send(managerId, {type = MSG.FACTORY_ADMIN_REQ}, PROTO)
  else
    rednet.send(managerId, {type = MSG.FACTORY_ADMIN_REQ}, PROTO)
  end
end

--------------------------------------------------------------------------------
-- Send command to manager
--------------------------------------------------------------------------------
local function sendCommand(factoryId, command)
  if not managerId then return end
  
  local msg = {
    type = MSG.FACTORY_ADMIN_COMMAND,
    factoryId = factoryId,
    command = command
  }
  
  if titan and titan.send then
    titan.send(managerId, msg, PROTO)
  else
    rednet.send(managerId, msg, PROTO)
  end
end

local function setItemThreshold(itemId, maxShare, daysBuffer, demandRate)
  if not managerId then return end
  
  local msg = {
    type = MSG.FACTORY_ADMIN_SET,
    itemId = itemId,
    maxShare = maxShare,
    daysBuffer = daysBuffer,
    demandRate = demandRate
  }
  
  if titan and titan.send then
    titan.send(managerId, msg, PROTO)
  else
    rednet.send(managerId, msg, PROTO)
  end
end

local function setFactoryMode(enabled)
  if not managerId then return end
  
  local msg = {
    type = MSG.FACTORY_ADMIN_MODE,
    factoryMode = enabled
  }
  
  if titan and titan.send then
    titan.send(managerId, msg, PROTO)
  else
    rednet.send(managerId, msg, PROTO)
  end
end

--------------------------------------------------------------------------------
-- Short item name (strip minecraft:)
--------------------------------------------------------------------------------
local function shortName(itemId)
  if not itemId then return "?" end
  local s = tostring(itemId)
  return s:match("^[%w_]+:(.+)$") or s
end

--------------------------------------------------------------------------------
-- Draw screens
--------------------------------------------------------------------------------
local function drawHome()
  if not ui then return end
  local out = term
  local w, h = out.getSize()
  
  ui.clearScreen(out)
  
  -- Header
  local fillStr = snap and snap.fillPct and ("%d%%"):format(math.floor(snap.fillPct * 100)) or "?"
  ui.headerBar(out, "FACTORY ADMIN", fillStr)
  
  -- Factory mode toggle
  local y = 3
  local modeOn = snap and snap.factoryMode or false
  local modeText = modeOn and "Factory Mode ON" or "Factory Mode OFF"
  local modeColor = modeOn and ui.THEME.ok or ui.THEME.bad
  ui.chip(out, 2, y, modeText, modeColor)
  y = y + 2
  
  -- Factory list
  if not snap or not snap.factories or #snap.factories == 0 then
    ui.textAt(out, 2, y, "No factories", ui.THEME.muted, ui.THEME.bg)
    return
  end
  
  local maxRows = h - y - 1
  for i = 1 + scrollOffset, math.min(#snap.factories, maxRows + scrollOffset) do
    local f = snap.factories[i]
    if not f then break end
    
    local row = i - scrollOffset
    local rowY = y + row - 1
    
    -- Zebra striping
    ui.tileRow(out, 1, rowY, w, "", i, false)
    
    -- Label
    local label = f.label or ("#%d"):format(f.id)
    ui.textAt(out, 2, rowY, label:sub(1, w - 16), ui.THEME.text, nil)
    
    -- State chip
    local stateText = (f.state == "ON") and "ON" or "OFF"
    local stateColor = (f.state == "ON") and ui.THEME.ok or ui.THEME.bad
    ui.chip(out, w - 10, rowY, stateText, stateColor)
    
    -- Sending badge
    if f.sending then
      ui.textAt(out, w - 5, rowY, "->", ui.THEME.accentWarm, nil)
    end
  end
  
  -- Footer
  ui.footer(out, ("Factories: %d"):format(#snap.factories))
end

local function drawDetail()
  if not ui or not selectedFactory then
    screen = "home"
    return
  end
  
  local out = term
  local w, h = out.getSize()
  
  ui.clearScreen(out)
  
  -- Header with back button
  local label = selectedFactory.label or ("#%d"):format(selectedFactory.id)
  ui.headerBar(out, label, "", true)
  
  local y = 3
  
  -- Outputs
  ui.textAt(out, 2, y, "Outputs:", ui.THEME.colHeader, ui.THEME.bg)
  y = y + 1
  if selectedFactory.outputs and #selectedFactory.outputs > 0 then
    for _, itemId in ipairs(selectedFactory.outputs) do
      ui.textAt(out, 4, y, shortName(itemId), ui.THEME.text, ui.THEME.bg)
      y = y + 1
    end
  else
    ui.textAt(out, 4, y, "(none)", ui.THEME.muted, ui.THEME.bg)
    y = y + 1
  end
  
  y = y + 1
  
  -- Inputs
  ui.textAt(out, 2, y, "Inputs:", ui.THEME.colHeader, ui.THEME.bg)
  y = y + 1
  if selectedFactory.inputs and #selectedFactory.inputs > 0 then
    for _, itemId in ipairs(selectedFactory.inputs) do
      ui.textAt(out, 4, y, shortName(itemId), ui.THEME.text, ui.THEME.bg)
      y = y + 1
    end
  else
    ui.textAt(out, 4, y, "(none)", ui.THEME.muted, ui.THEME.bg)
    y = y + 1
  end
  
  y = y + 1
  
  -- Force buttons
  ui.chip(out, 2, y, " Force ON ", ui.THEME.ok)
  ui.chip(out, 15, y, " Force OFF ", ui.THEME.bad)
  
  -- Footer
  local age = selectedFactory.lastHeartbeat or 999
  ui.footer(out, ("Heartbeat: %ds ago"):format(math.floor(age)))
end

local function drawItems()
  if not ui or not snap or not snap.items then
    screen = "home"
    return
  end
  
  local out = term
  local w, h = out.getSize()
  
  ui.clearScreen(out)
  
  -- Header with back button
  ui.headerBar(out, "ITEM THRESHOLDS", "", true)
  
  local y = 3
  
  if #snap.items == 0 then
    ui.textAt(out, 2, y, "No items configured", ui.THEME.muted, ui.THEME.bg)
    return
  end
  
  local maxRows = h - y - 1
  for i = 1 + scrollOffset, math.min(#snap.items, maxRows + scrollOffset) do
    local item = snap.items[i]
    if not item then break end
    
    local row = i - scrollOffset
    local rowY = y + row - 1
    
    -- Zebra striping
    ui.tileRow(out, 1, rowY, w, "", i, false)
    
    -- Item name
    local name = shortName(item.itemId)
    ui.textAt(out, 2, rowY, name:sub(1, w - 20), ui.THEME.text, nil)
    
    -- Thresholds (compact)
    local shareP = math.floor((item.maxShare or 0.5) * 100)
    local days = item.daysBuffer or 4
    local rate = item.demandRate or 0
    local threshText = ("%d%% %dd %dr"):format(shareP, days, rate)
    ui.textAt(out, w - #threshText, rowY, threshText, ui.THEME.muted, nil)
  end
  
  -- Footer
  ui.footer(out, "Tap item to edit")
end

local function draw()
  if screen == "home" then
    drawHome()
  elseif screen == "detail" then
    drawDetail()
  elseif screen == "items" then
    drawItems()
  end
end

--------------------------------------------------------------------------------
-- Input handling
--------------------------------------------------------------------------------
local function handleHomeClick(x, y)
  local w, h = term.getSize()
  
  -- Mode chip at y=3
  if y == 3 and x >= 2 and x <= 20 then
    local newMode = not (snap and snap.factoryMode)
    setFactoryMode(newMode)
    requestSnap()
    return
  end
  
  -- Factory list starts at y=5
  if y >= 5 then
    local row = y - 5 + 1 + scrollOffset
    if snap and snap.factories and snap.factories[row] then
      selectedFactory = snap.factories[row]
      screen = "detail"
      scrollOffset = 0
      draw()
    end
  end
end

local function handleDetailClick(x, y)
  local w, h = term.getSize()
  
  -- Back button (header bar, right side)
  if y == 1 and x >= w - 6 then
    screen = "home"
    scrollOffset = 0
    draw()
    return
  end
  
  -- Force buttons (around y=dynamic, let's estimate y > h/2)
  if y > h / 2 then
    if x >= 2 and x <= 13 then
      -- Force ON
      sendCommand(selectedFactory.id, "ON")
      requestSnap()
    elseif x >= 15 and x <= 27 then
      -- Force OFF
      sendCommand(selectedFactory.id, "OFF")
      requestSnap()
    end
  end
end

local function handleItemsClick(x, y)
  local w, h = term.getSize()
  
  -- Back button
  if y == 1 and x >= w - 6 then
    screen = "home"
    scrollOffset = 0
    draw()
    return
  end
  
  -- Item list starts at y=3
  if y >= 3 then
    local row = y - 3 + 1 + scrollOffset
    if snap and snap.items and snap.items[row] then
      local item = snap.items[row]
      -- TODO: Edit dialog (for now, just cycle share +10%)
      local newShare = (item.maxShare or 0.5) + 0.1
      if newShare > 1.0 then newShare = 0.1 end
      setItemThreshold(item.itemId, newShare, nil, nil)
      sleep(0.2)
      requestSnap()
    end
  end
end

local function handleClick(x, y)
  if screen == "home" then
    handleHomeClick(x, y)
  elseif screen == "detail" then
    handleDetailClick(x, y)
  elseif screen == "items" then
    handleItemsClick(x, y)
  end
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
local function main()
  if not pocket then
    print("Factory Admin requires a pocket computer")
    return
  end
  
  if not ui then
    print("Missing lib/titan_ui.lua")
    return
  end
  
  print("Factory Admin v" .. VERSION)
  print("Discovering manager...")
  
  managerId = discoverManager()
  if not managerId then
    print("No Storage Manager found")
    print("Ensure manager is running and wireless modem is attached")
    return
  end
  
  print("Manager found: #" .. managerId)
  sleep(1)
  
  requestSnap()
  draw()
  
  local refreshTimer = os.startTimer(2)
  
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    
    if ev == "timer" and p1 == refreshTimer then
      requestSnap()
      refreshTimer = os.startTimer(2)
      
    elseif ev == "mouse_click" then
      handleClick(p2, p3)
      
    elseif ev == "rednet_message" and (p3 == PROTO or p3 == nil) and type(p2) == "table" then
      local msg, from = p2, p1
      if msg.type == MSG.FACTORY_ADMIN_SNAP and from == managerId then
        snap = msg
        lastSnap = os.clock()
        draw()
      end
      
    elseif ev == "key" then
      local key = p1
      -- i key = items screen
      if key == keys.i then
        screen = "items"
        scrollOffset = 0
        draw()
      -- h key = home
      elseif key == keys.h then
        screen = "home"
        scrollOffset = 0
        draw()
      -- q key = quit
      elseif key == keys.q then
        break
      end
      
    elseif ev == "terminate" then
      break
    end
  end
  
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Factory Admin stopped")
end

main()
