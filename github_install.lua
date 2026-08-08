--[[
  github_install.lua  -  Install the Titan system straight from a GitHub repo
  Titan-Version: 1.2.3

  Point RAW_BASE at your repo's raw content root, then on each Minecraft device:

      wget run https://raw.githubusercontent.com/YOU/REPO/main/github_install.lua

  (or `wget ... github_install.lua` then run it). It asks what the device is,
  pulls that role's files from GitHub (creating lib/ as needed), offers a
  startup.lua, and can launch it.

  Advanced (color) pocket computers get a tap-friendly tile GUI; other devices
  keep the classic text menu.

  GitHub is a public HTTPS host, so it's on CC: Tweaked's allow-list by default -
  no config changes needed. Use the RAW url (raw.githubusercontent.com), NOT the
  github.com "blob" page.
]]

--==============================================================================
-- 1) SET THIS to your repo's raw root (keep the trailing slash).
--    Format: https://raw.githubusercontent.com/<user>/<repo>/<branch>/
--==============================================================================
local RAW_BASE = "https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/"

--==============================================================================
-- 2) Roles -> which files they need + what to auto-run (matches the README)
--==============================================================================
local KEEP_ALL = {
  "lib/titan.lua", "datacenter.lua", "console.lua", "admin.lua",
  "router.lua", "router_main.lua", "router_modem.lua",
  "lib/router_hub_net.lua", "lib/router_hub_ui.lua", "lib/router_hub_cmd.lua",
  "offline_miner.lua", "offline_site.lua", "exclude.txt",
  "perimeter_sensor.lua", "perimeter_manager.lua", "tetris.lua", "minesweeper.lua",
  "host.lua", "versions.lua",
}

local GAMES = {
  { key = "1", name = "Tetris (pocket / monitor + music)", run = "tetris.lua",
    files = { "lib/titan.lua", "tetris.lua", "versions.lua" } },
  { key = "2", name = "Minesweeper (pocket / monitor)", run = "minesweeper.lua",
    files = { "minesweeper.lua" } },
}

local ROLES = {
  { key = "1", name = "Parent Center (data center)",       run = "datacenter.lua",
    files = { "lib/titan.lua", "datacenter.lua" } },
  { key = "2", name = "Terminal console (basic commands)",  run = "console.lua",
    files = { "lib/titan.lua", "console.lua" } },
  { key = "3", name = "Admin tablet (pocket console)",      run = "admin.lua",
    files = { "lib/titan.lua", "admin.lua" } },
  { key = "4", name = "Network router (repeater + GPS)",   run = "router.lua",
    files = { "lib/titan.lua", "router.lua", "router_main.lua", "router_modem.lua",
              "lib/router_hub_net.lua", "lib/router_hub_ui.lua", "lib/router_hub_cmd.lua",
              "versions.lua" } },
  { key = "5", name = "Offline miner (cell quarry turtle)", run = "offline_miner.lua",
    files = { "lib/titan.lua", "offline_miner.lua", "exclude.txt" } },
  { key = "6", name = "Offline quarry site board",        run = "offline_site.lua",
    files = { "offline_site.lua", "lib/titan.lua" } },
  { key = "7", name = "Perimeter sensor (Player Detector gate)", run = "perimeter_sensor.lua",
    files = { "lib/titan.lua", "perimeter_sensor.lua" } },
  { key = "8", name = "Perimeter manager (territory board)", run = "perimeter_manager.lua",
    files = { "lib/titan.lua", "perimeter_manager.lua" } },
  { key = "g", name = "Games...", submenu = "games" },
  { key = "h", name = "Install / update host (serves files over rednet)", run = "host.lua",
    files = { "lib/titan.lua", "host.lua", "install.lua", "versions.lua" } },
  { key = "9", name = "Everything (kept files, no auto-run)", run = nil,
    files = KEEP_ALL },
}

--==============================================================================
-- Download helpers
--==============================================================================
local function fetch(path)
  local url = RAW_BASE .. path .. "?cb=" .. os.epoch("utc")   -- cache-buster
  local h = http.get(url)
  if not h then return nil, "http request failed" end
  local code = h.getResponseCode and h.getResponseCode() or 200
  local data = h.readAll()
  h.close()
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
  if not data or data == "" then return nil, "empty response" end
  return data
end

local function writeFile(path, data)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  f.write(data)
  f.close()
end

--==============================================================================
-- Main
--==============================================================================
if not http then
  printError("HTTP is disabled. Enable the http API in the CC: Tweaked config.")
  return
end
if RAW_BASE:find("YOURNAME/REPO") then
  printError("Edit RAW_BASE at the top of this file to point at your repo first.")
  return
end

-- Advanced pocket = color terminal + pocket API (golden / advanced pocket PC).
local function useModernGui()
  local ok, color = pcall(function() return term.isColor and term.isColor() end)
  return ok and color == true and pocket ~= nil
end

local TILE_BG = {
  ["1"] = colors.blue, ["2"] = colors.gray, ["3"] = colors.purple,
  ["4"] = colors.cyan, ["5"] = colors.brown, ["6"] = colors.orange,
  ["7"] = colors.red, ["8"] = colors.red, ["g"] = colors.magenta,
  ["h"] = colors.green, ["9"] = colors.lightGray,
  ["1g"] = colors.magenta, ["2g"] = colors.orange, -- games submenu
}

local function fill(x, y, w, h, bg, fg)
  if term.setBackgroundColor then term.setBackgroundColor(bg or colors.black) end
  if term.setTextColor then term.setTextColor(fg or colors.white) end
  for row = y, y + h - 1 do
    term.setCursorPos(x, row)
    term.write((" "):rep(math.max(0, w)))
  end
end

local function textAt(x, y, s, fg, bg)
  if term.setBackgroundColor then term.setBackgroundColor(bg or colors.black) end
  if term.setTextColor then term.setTextColor(fg or colors.white) end
  term.setCursorPos(x, y)
  term.write(tostring(s or ""))
end

local function shortName(name)
  name = tostring(name or "")
  -- Drop parenthetical clutter on small tiles.
  name = name:gsub("%s*%b()", "")
  return name
end

-- Modern tile picker for advanced pockets. Returns item, false (back), or nil (cancel).
local function pickFromListGui(list, opts)
  opts = opts or {}
  local title = opts.title or "TITAN INSTALL"
  local subtitle = opts.subtitle or ""
  local allowBack = opts.backKey ~= nil
  local sel, scroll = 1, 0
  local cols = 1

  local function layout()
    local tw, th = term.getSize()
    cols = (tw >= 28) and 2 or 1
    local headerH = 3
    local footerH = 1
    local tileH = 3
    local gap = 1
    local usable = th - headerH - footerH
    local rows = math.max(1, math.floor((usable + gap) / (tileH + gap)))
    local page = rows * cols
    local tileW = math.floor((tw - (cols + 1)) / cols)
    return tw, th, headerH, footerH, tileH, gap, rows, page, tileW
  end

  local function tileRect(i, tw, headerH, tileH, gap, rows, tileW)
    local localIdx = i - scroll
    if localIdx < 1 then return nil end
    local row = math.floor((localIdx - 1) / cols)
    local col = (localIdx - 1) % cols
    if row >= rows then return nil end
    local x = 2 + col * (tileW + 1)
    local y = headerH + 1 + row * (tileH + gap)
    return x, y, tileW, tileH
  end

  while true do
    local tw, th, headerH, footerH, tileH, gap, rows, page, tileW = layout()
    if sel < 1 then sel = 1 end
    if sel > #list then sel = #list end
    if sel <= scroll then scroll = math.max(0, sel - 1) end
    if sel > scroll + page then scroll = sel - page end
    if scroll < 0 then scroll = 0 end
    local maxScroll = math.max(0, #list - page)
    if scroll > maxScroll then scroll = maxScroll end

    fill(1, 1, tw, th, colors.black, colors.white)
    fill(1, 1, tw, 1, colors.blue, colors.white)
    textAt(2, 1, title:sub(1, tw - 2), colors.white, colors.blue)
    if allowBack then
      textAt(math.max(2, tw - 5), 1, "BACK", colors.yellow, colors.blue)
    else
      textAt(math.max(2, tw - 2), 1, "X", colors.red, colors.blue)
    end
    textAt(2, 2, (subtitle ~= "" and subtitle or "Tap a role to install"):sub(1, tw - 2),
      colors.lightGray, colors.black)

    for i = 1, #list do
      local x, y, w, h = tileRect(i, tw, headerH, tileH, gap, rows, tileW)
      if x then
        local item = list[i]
        local bg = TILE_BG[tostring(item.key)] or colors.gray
        if opts.games then
          bg = (i == 1) and colors.magenta or colors.orange
        end
        local fg = colors.white
        if i == sel then
          -- Selection ring
          fill(x - 1, y, w + 2, h, colors.white, colors.black)
          fill(x, y, w, h, bg, fg)
        else
          fill(x, y, w, h, bg, fg)
        end
        local label = shortName(item.name)
        textAt(x + 1, y + 1, label:sub(1, math.max(1, w - 2)), fg, bg)
        textAt(x + 1, y, tostring(item.key):upper():sub(1, 1), colors.yellow, bg)
      end
    end

    local foot = allowBack and "Tap  Enter  B back  Q quit" or "Tap  Enter  Q quit"
    if scroll > 0 or scroll + page < #list then
      foot = "↑↓  " .. foot
    end
    fill(1, th, tw, 1, colors.gray, colors.white)
    textAt(2, th, foot:sub(1, tw - 2), colors.white, colors.gray)

    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "term_resize" then
      -- redraw
    elseif ev == "key" then
      local K = keys
      if p1 == K.up or p1 == K.left then
        sel = sel > 1 and sel - 1 or #list
      elseif p1 == K.down or p1 == K.right or p1 == K.tab then
        sel = sel < #list and sel + 1 or 1
      elseif p1 == K.enter or p1 == K.space then
        return list[sel]
      elseif p1 == K.q then
        return nil
      elseif allowBack and (p1 == K.b or p1 == K.backspace) then
        return false
      elseif p1 == K.pageUp then
        sel = math.max(1, sel - page)
      elseif p1 == K.pageDown then
        sel = math.min(#list, sel + page)
      end
    elseif ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "q" then return nil end
      if allowBack and ch == "b" then return false end
      for i, item in ipairs(list) do
        if tostring(item.key):lower() == ch then return item end
      end
    elseif ev == "mouse_click" then
      local btn, mx, my = p1, p2, p3
      if my == 1 then
        if allowBack and mx >= tw - 5 then return false end
        if not allowBack and mx >= tw - 2 then return nil end
      end
      for i = 1, #list do
        local x, y, w, h = tileRect(i, tw, headerH, tileH, gap, rows, tileW)
        if x and mx >= x and mx < x + w and my >= y and my < y + h then
          if btn == 1 then return list[i] end
        end
      end
    elseif ev == "mouse_scroll" then
      if p1 < 0 then sel = math.max(1, sel - 1)
      elseif p1 > 0 then sel = math.min(#list, sel + 1) end
    elseif ev == "terminate" then
      return nil
    end
  end
end

-- Classic text picker. cancelKey returns nil; backKey returns false.
local function pickFromListText(list, opts)
  opts = opts or {}
  local title = opts.title or "== Install =="
  local sourceLine = opts.sourceLine
  local promptHint = opts.promptHint or "What is this device?"
  local cancelKey = (opts.cancelKey or "q"):lower()
  local backKey = opts.backKey and tostring(opts.backKey):lower() or nil
  while true do
    local idx = 1
    while idx <= #list do
      local _, h = term.getSize()
      term.clear(); term.setCursorPos(1, 1)
      print(title)
      if sourceLine then print(sourceLine) end
      print(promptHint)
      print("")
      local budget = math.max(4, (h or 13) - 7)
      local shown = 0
      while idx <= #list and shown < budget do
        local r = list[idx]
        print("  " .. r.key .. ") " .. r.name)
        idx = idx + 1
        shown = shown + 1
      end
      print("")
      local qHint = backKey and ("B back, " .. cancelKey:upper() .. " cancel")
        or (cancelKey:upper() .. " cancel")
      if idx <= #list then
        write("Enter #, or Enter=more (" .. qHint .. "): ")
      else
        write("Choose (" .. qHint .. "): ")
      end
      local choice = tostring(read() or ""):lower()
      if choice == cancelKey then return nil end
      if backKey and choice == backKey then return false end
      if choice ~= "" then
        for _, r in ipairs(list) do
          if tostring(r.key):lower() == choice then return r end
        end
        print("Invalid choice."); sleep(1.2)
        idx = 1
      elseif idx > #list then
        idx = 1
      end
    end
  end
end

local function pickFromList(list, opts)
  if useModernGui() then
    return pickFromListGui(list, opts)
  end
  return pickFromListText(list, opts)
end

local function askYesNo(question, defaultYes)
  if not useModernGui() then
    write(question .. (defaultYes and " [Y/n] " or " [y/N] "))
    local yn = read():lower()
    if yn == "" then return defaultYes ~= false end
    return yn == "y" or yn == "yes"
  end
  local tw, th = term.getSize()
  while true do
    fill(1, 1, tw, th, colors.black, colors.white)
    fill(1, 1, tw, 1, colors.blue, colors.white)
    textAt(2, 1, "CONFIRM", colors.white, colors.blue)
    textAt(2, 3, question:sub(1, tw - 2), colors.white, colors.black)
    local yW, nW = 8, 8
    local yX = math.floor(tw / 2) - yW - 1
    local nX = math.floor(tw / 2) + 2
    local yY = math.min(th - 3, 6)
    fill(yX, yY, yW, 3, colors.lime, colors.black)
    textAt(yX + 2, yY + 1, "YES", colors.black, colors.lime)
    fill(nX, yY, nW, 3, colors.red, colors.white)
    textAt(nX + 2, yY + 1, "NO", colors.white, colors.red)
    textAt(2, th, "Y / N   tap a button", colors.lightGray, colors.black)
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "char" then
      local ch = tostring(p1 or ""):lower()
      if ch == "y" then return true end
      if ch == "n" then return false end
    elseif ev == "key" then
      if p1 == keys.enter then return defaultYes ~= false end
      if p1 == keys.y then return true end
      if p1 == keys.n then return false end
    elseif ev == "mouse_click" then
      local mx, my = p2, p3
      if my >= yY and my < yY + 3 then
        if mx >= yX and mx < yX + yW then return true end
        if mx >= nX and mx < nX + nW then return false end
      end
    elseif ev == "terminate" then
      return false
    end
  end
end

local function pickRole(title, sourceLine)
  while true do
    local role = pickFromList(ROLES, {
      title = useModernGui() and "TITAN INSTALL" or title,
      sourceLine = sourceLine,
      subtitle = sourceLine,
      promptHint = "What is this device?  (g = Games)",
    })
    if role == nil then return nil end
    if role.submenu == "games" then
      local game = pickFromList(GAMES, {
        title = useModernGui() and "GAMES" or "== Games ==",
        promptHint = "Pick a game:",
        backKey = "b",
        games = true,
      })
      if game then return game end
      -- nil = cancel all; false = back to main menu
      if game == nil then return nil end
    else
      return role
    end
  end
end

local role = pickRole("== Titan GitHub Installer ==", "Source: " .. RAW_BASE)
if not role then
  if useModernGui() then
    fill(1, 1, select(1, term.getSize()), select(2, term.getSize()), colors.black, colors.white)
    term.setCursorPos(1, 1)
  end
  print("Cancelled.")
  return
end

-- Leave GUI chrome before download logs.
if useModernGui() then
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

local files, hasVersions = {}, false
for _, path in ipairs(role.files) do
  files[#files + 1] = path
  if path == "versions.lua" then hasVersions = true end
end
if not hasVersions then files[#files + 1] = "versions.lua" end

print("")
print("Installing: " .. role.name)
local failed = {}
for _, path in ipairs(files) do
  write("  " .. path .. " ... ")
  local data, err = fetch(path)
  if data then
    writeFile(path, data)
    print("ok (" .. #data .. "b)")
  else
    print("FAILED (" .. tostring(err) .. ")")
    failed[#failed + 1] = path
  end
end

if #failed > 0 then
  print("")
  print("Failed: " .. table.concat(failed, ", "))
  print("Check RAW_BASE, the branch name, and that the repo is public.")
  return
end

print("")
print("Install complete.")

local sysVer = "1.1.0"
if fs.exists("versions.lua") then
  local ok, cat = pcall(dofile, "versions.lua")
  if ok and type(cat) == "table" and cat.system then sysVer = cat.system end
end

-- Desired packages list (`packages` file) — edit anytime, then run `update`.
if fs.exists("lib/titan.lua") then
  local ok, titan = pcall(dofile, "lib/titan.lua")
  if ok and titan and titan.writePackageList then files = titan.writePackageList(files) end
else
  local pf = fs.open("packages", "w")
  pf.write("# Titan packages — desired packages for this computer\n")
  pf.write("# One path per line. Edit this list, then run: update\n#\n")
  for _, path in ipairs(files) do pf.write(path .. "\n") end
  pf.close()
end

-- Record how this device was installed so it can self-update later when the
-- network router pushes an OTA update (see lib/titan.lua : titan.updateSelf).
writeFile(".titan-install", textutils.serialize({
  source = "github", role = role.name, run = role.run, files = files, base = RAW_BASE, version = sysVer,
}))

-- Give this device a role-based label if it doesn't have one yet.
local LABELS = {
  ["datacenter.lua"] = "ParentCenter",
  ["console.lua"] = "Console",
  ["admin.lua"] = "Admin",
  ["router.lua"] = "Router",
  ["offline_miner.lua"] = "OfflineMiner",
  ["offline_site.lua"]  = "QuarrySite",
  ["perimeter_sensor.lua"] = "PerimSensor",
  ["perimeter_manager.lua"] = "PerimMgr",
  ["tetris.lua"] = "Tetris",
  ["minesweeper.lua"] = "Minesweeper",
  ["host.lua"] = "TitanHost",
}
local lbl = role.run and LABELS[role.run]
if lbl and not os.getComputerLabel() then
  os.setComputerLabel(lbl .. "-" .. os.getComputerID())
  print("Label set: " .. os.getComputerLabel())
end

if role.run then
  if askYesNo("Auto-run " .. role.run .. " on boot?", true) then
    writeFile("startup.lua", ('shell.run("%s")\n'):format(role.run))
    print("Wrote startup.lua.")
  end
  if askYesNo("Run " .. role.run .. " now?", true) then
    return shell.run(role.run)
  end
end
print("Done.")
