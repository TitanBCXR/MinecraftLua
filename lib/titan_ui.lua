--[[
  lib/titan_ui.lua  -  Shared UI kit for Titan factory/storage systems
  Titan-Version: 1.0.0

  Standard THEME and helpers extracted from admin.lua + github_install.lua
  for consistent look across factory_clutch, storage_clutch, storage_manager, factory_admin.

  Usage:
    local ui = dofile("lib/titan_ui.lua")
    ui.fill(term, 1, 1, w, h, ui.THEME.bg)
    ui.headerBar(term, "Factory Admin", "v1.0")
    ui.chip(term, 5, 3, "ON", ui.THEME.ok)
]]

--------------------------------------------------------------------------------
-- THEME: colors palette for factory/storage family
--------------------------------------------------------------------------------
local THEME = {
  bg = colors.black,
  panel = colors.gray,
  bar = colors.gray,
  accent = colors.cyan,
  accentWarm = colors.orange,
  accentFg = colors.black,
  text = colors.white,
  muted = colors.lightGray,
  dim = colors.gray,
  ok = colors.lime,
  warn = colors.yellow,
  bad = colors.red,
  zebra = colors.gray,
  colHeader = colors.lightGray,
  colHeaderFg = colors.black,
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Fill rectangle
local function fill(out, x, y, w, h, fg, bg)
  if not out then return end
  if out.setTextColor and fg then out.setTextColor(fg) end
  if out.setBackgroundColor and bg then out.setBackgroundColor(bg) end
  for row = y, y + h - 1 do
    out.setCursorPos(x, row)
    out.write((" "):rep(w))
  end
end

-- Text at position
local function textAt(out, x, y, text, fg, bg)
  if not out then return end
  if out.setTextColor and fg then out.setTextColor(fg) end
  if out.setBackgroundColor and bg then out.setBackgroundColor(bg) end
  out.setCursorPos(x, y)
  out.write(text)
end

-- Header bar (cyan bar at top)
local function headerBar(out, title, right, showBack)
  if not out then return end
  local w, h = out.getSize()
  fill(out, 1, 1, w, 1, THEME.accentFg, THEME.accent)
  textAt(out, 2, 1, title, THEME.accentFg, THEME.accent)
  if right then
    textAt(out, math.max(2, w - #right), 1, right, THEME.dim, THEME.accent)
  end
  if showBack then
    textAt(out, w - 5, 1, "< BACK", THEME.accentFg, THEME.accent)
  end
end

-- Chip (colored rounded badge)
local function chip(out, x, y, text, bgColor, fgColor)
  if not out then return end
  fgColor = fgColor or THEME.accentFg
  textAt(out, x, y, " " .. text .. " ", fgColor, bgColor)
end

-- Track bar (fill percentage bar)
local function trackBar(out, x, y, w, fill, label)
  if not out then return end
  local fillW = math.floor(w * math.max(0, math.min(1, fill)))
  local emptyW = w - fillW
  
  textAt(out, x, y, (" "):rep(fillW), THEME.text, THEME.ok)
  if emptyW > 0 then
    textAt(out, x + fillW, y, (" "):rep(emptyW), THEME.text, THEME.panel)
  end
  
  if label then
    local labelX = x + math.floor((w - #label) / 2)
    textAt(out, labelX, y, label, THEME.accentFg, nil)
  end
end

-- Footer (bottom status line)
local function footer(out, text)
  if not out then return end
  local w, h = out.getSize()
  fill(out, 1, h, w, 1, THEME.muted, THEME.bg)
  textAt(out, 2, h, text, THEME.muted, THEME.bg)
end

-- Pull GUI event (mouse_click + monitor_touch)
local function pullGuiEvent(timeout)
  local evt = {os.pullEvent(timeout)}
  local name = evt[1]
  if name == "mouse_click" or name == "monitor_touch" then
    return name, evt[2], evt[3], evt[4] -- name, button/side, x, y
  end
  return name, table.unpack(evt, 2)
end

-- Clear screen with bg color
local function clearScreen(out, bg)
  if not out then return end
  bg = bg or THEME.bg
  if out.setBackgroundColor then out.setBackgroundColor(bg) end
  if out.setTextColor then out.setTextColor(THEME.text) end
  out.clear()
  out.setCursorPos(1, 1)
end

-- Tile list row (zebra striping)
local function tileRow(out, x, y, w, text, index, selected)
  if not out then return end
  local bg = (index % 2 == 0) and THEME.zebra or THEME.bg
  if selected then bg = THEME.panel end
  fill(out, x, y, w, 1, THEME.text, bg)
  textAt(out, x, y, text:sub(1, w), THEME.text, bg)
end

-- Device tier detection
local function getDeviceTier()
  if not term.isColor() then return "mono" end
  if pocket then return "pocket" end
  local w, h = term.getSize()
  if w <= 26 and h <= 20 then return "tiny" end
  if w >= 51 and h >= 19 then return "large" end
  return "normal"
end

-- Monitor detection
local function findMonitor()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "monitor" then
      return peripheral.wrap(side)
    end
  end
  
  -- Check wired modems for remote monitors
  for _, sideName in ipairs(peripheral.getNames()) do
    if peripheral.getType(sideName) == "modem" then
      local m = peripheral.wrap(sideName)
      if m and not m.isWireless() and type(m.getNamesRemote) == "function" then
        if not m.isOpen(65535) then pcall(m.open, 65535) end
        for _, remoteName in ipairs(m.getNamesRemote() or {}) do
          if peripheral.getType(remoteName) == "monitor" then
            return peripheral.wrap(remoteName)
          end
        end
      end
    end
  end
  
  return nil
end

--------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------
return {
  THEME = THEME,
  fill = fill,
  textAt = textAt,
  headerBar = headerBar,
  chip = chip,
  trackBar = trackBar,
  footer = footer,
  pullGuiEvent = pullGuiEvent,
  clearScreen = clearScreen,
  tileRow = tileRow,
  getDeviceTier = getDeviceTier,
  findMonitor = findMonitor,
}
