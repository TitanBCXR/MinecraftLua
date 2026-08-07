--[[
  lib/router_hub_ui.lua  -  Titan hub monitors / boards / map (part)
  Titan-Version: 1.4.1

  Loaded by router_main.lua into a shared env (setfenv). Do not run directly.
]]

function monIsColor(out)
  local ok, c = pcall(function() return out.isColor and out.isColor() end)
  return ok and c == true
end

-- Pick text scale from monitor size so huge walls stay readable and
-- small monitors stay dense. Returns scale, w, h, color after applying.
function monApplyScale(out)
  if not out then return 0.5, 0, 0, false end
  local color = monIsColor(out)
  -- Probe at 0.5 (max character density), then bump scale on huge walls.
  pcall(function() out.setTextScale(0.5) end)
  local w, h = out.getSize()
  local scale = 0.5
  if w >= 90 and h >= 36 then
    scale = 1 -- ~6x4+ advanced wall: prefer readable cells
  end
  pcall(function() out.setTextScale(scale) end)
  w, h = out.getSize()
  return scale, w, h, color
end

function monLayout(out)
  local scale, w, h, color = monApplyScale(out)
  local tier
  if w < 20 or h < 8 then tier = "tiny"
  elseif w < 30 or h < 12 then tier = "small"
  elseif w < 50 or h < 18 then tier = "medium"
  else tier = "large" end
  return {
    out = out, w = w, h = h, scale = scale, color = color, tier = tier,
    -- Layout slots (leave last row for footer).
    headerH = (tier == "tiny") and 1 or ((tier == "small") and 2 or 3),
    footerH = 1,
    pad = (tier == "large" and color) and 1 or 0,
  }
end

function guiFill(out, x, y, w, h, bg, fg)
  if not out then return end
  bg = bg or colors.black
  fg = fg or colors.white
  for row = y, y + h - 1 do
    out.setCursorPos(x, row)
    if out.setBackgroundColor then out.setBackgroundColor(bg) end
    if out.setTextColor then out.setTextColor(fg) end
    out.write(string.rep(" ", w))
  end
end

function guiText(out, x, y, txt, fg, bg)
  if not out or y < 1 then return end
  local w = select(1, out.getSize())
  if x > w then return end
  txt = tostring(txt or "")
  if out.setBackgroundColor then out.setBackgroundColor(bg or colors.black) end
  if out.setTextColor then out.setTextColor(fg or colors.white) end
  out.setCursorPos(x, y)
  out.write(txt:sub(1, math.max(0, w - x + 1)))
end

function guiBar(L, y, title, subtitle, accent)
  local out, w = L.out, L.w
  accent = accent or colors.cyan
  if L.color then
    guiFill(out, 1, y, w, 1, accent, colors.black)
    guiText(out, 2, y, title, colors.black, accent)
    if subtitle and L.tier ~= "tiny" and #title + #subtitle + 4 < w then
      guiText(out, math.max(1, w - #subtitle), y, subtitle, colors.gray, accent)
    end
  else
    guiText(out, 1, y, title, colors.white, colors.black)
    if subtitle and L.tier ~= "tiny" then
      guiText(out, math.max(1, w - #subtitle + 1), y, subtitle, colors.lightGray, colors.black)
    end
  end
end

function guiChip(out, x, y, label, fg, bg, colorOk)
  label = " " .. tostring(label) .. " "
  if colorOk then
    guiText(out, x, y, label, fg or colors.white, bg or colors.gray)
  else
    guiText(out, x, y, "[" .. tostring(label):match("^%s*(.-)%s*$") .. "]", fg or colors.white, colors.black)
  end
  return x + #label + (colorOk and 1 or 0)
end

function guiFooter(L, role)
  local out, w, h = L.out, L.w, L.h
  local left = ""
  if boardWakeAt and not screenPerm[role] then
    left = (" %ds"):format(math.max(0, math.floor(boardWakeAt + saverIdleSecs - os.clock())))
  elseif screenPerm[role] then
    left = " PERM"
  end
  local tag = (role == "roster") and "local" or tostring(role)
  local right = L.color and " ADV" or " MONO"
  right = right .. (" %dx%d"):format(w, h)
  local line = (" %s%s"):format(tag, left)
  if L.color then
    guiFill(out, 1, h, w, 1, colors.gray, colors.white)
    guiText(out, 1, h, line, colors.white, colors.gray)
    guiText(out, math.max(1, w - #right + 1), h, right, colors.lightGray, colors.gray)
  else
    guiText(out, 1, h, (line .. right):sub(1, w), colors.gray, colors.black)
  end
end

function loadScreenAssignments()
  local c = loadRouterCfg() or {}
  local s = type(c.screens) == "table" and c.screens or {}
  for _, role in ipairs(SCREEN_ROLES) do
    if type(s[role]) == "string" and s[role] ~= "" and s[role] ~= "auto" then
      screenNames[role] = s[role]
    end
  end
  -- Only permanent boards survive reboot. Temp toggles always start as saver.
  if type(c.screenPerm) == "table" then
    for _, role in ipairs(SCREEN_ROLES) do
      screenPerm[role] = c.screenPerm[role] and true or false
      screenOn[role] = screenPerm[role] and true or false
    end
  else
    -- Migrate older cfgs that kept every board ON — default to screensaver.
    for _, role in ipairs(SCREEN_ROLES) do
      screenPerm[role] = false
      screenOn[role] = false
    end
  end
  if type(c.screenFocus) == "string" and isScreenRole(c.screenFocus) then
    screenFocus = c.screenFocus
  end
  if tonumber(c.saverIdleSecs) and tonumber(c.saverIdleSecs) >= 5 then
    saverIdleSecs = math.floor(tonumber(c.saverIdleSecs))
  end
  if c.monRate ~= nil then
    monRate = clampMonRate(c.monRate)
  end
  boardWakeAt = nil
end

function saveScreenAssignments()
  local s, on, perm = {}, {}, {}
  for _, role in ipairs(SCREEN_ROLES) do
    if screenNames[role] then s[role] = screenNames[role] end
    on[role] = screenOn[role] and true or false
    perm[role] = screenPerm[role] and true or false
  end
  patchRouterCfg({
    screens = s, screenOn = on, screenPerm = perm,
    screenFocus = screenFocus, saverIdleSecs = saverIdleSecs,
    monRate = monRate,
  })
end

function enabledRoles()
  local list = {}
  for _, role in ipairs(SCREEN_ROLES) do
    if screenOn[role] then list[#list + 1] = role end
  end
  return list
end

function anyLiveBoard()
  return #enabledRoles() > 0
end

function ensureFocus()
  local active = enabledRoles()
  if #active == 0 then return active end
  if screenOn[screenFocus] then return active end
  screenFocus = active[1]
  return active
end

function expireTemporaryBoards()
  if not boardWakeAt then return false end
  if os.clock() < boardWakeAt + saverIdleSecs then return false end
  local changed = false
  for _, role in ipairs(SCREEN_ROLES) do
    if screenOn[role] and not screenPerm[role] then
      screenOn[role] = false
      changed = true
    end
  end
  boardWakeAt = nil
  if changed then
    ensureFocus()
    saveScreenAssignments()
  end
  return changed
end

function wakeBoard(role, permanent)
  role = normalizeScreenRole(role)
  if not isScreenRole(role) then return false end
  -- Single-screen: exclusive — only this board is live.
  for _, r in ipairs(SCREEN_ROLES) do
    if r ~= role then
      screenOn[r] = false
      screenPerm[r] = false
    end
  end
  screenOn[role] = true
  screenPerm[role] = permanent and true or false
  screenFocus = role
  if permanent then
    boardWakeAt = nil
  else
    boardWakeAt = os.clock()
  end
  saverActive = false
  saverState = {}
  saveScreenAssignments()
  return true
end

-- Prefer an explicitly assigned monitor name; otherwise the first attached.
function primaryMonitorName()
  local names = listMonitorNames()
  if #names == 0 then return nil end
  local want = screenNames[screenFocus]
  if want and peripheral.isPresent(want) and peripheral.getType(want) == "monitor" then
    return want
  end
  return names[1]
end

function refreshScreens()
  local names = listMonitorNames()
  for _, role in ipairs(SCREEN_ROLES) do
    screens[role] = nil
  end
  displayMon, displayMonName = nil, nil

  local monName = primaryMonitorName()
  if not monName then return 0 end
  displayMonName = monName
  displayMon = wrapScreen(monName)

  local active = ensureFocus()
  if #active == 0 then return #names end

  local focus = screenFocus
  if not screenOn[focus] then focus = active[1]; screenFocus = focus end
  screens[focus] = displayMon
  screenNames[focus] = monName
  return #names
end

function monLine(out, w, y, txt, c)
  out.setCursorPos(1, y)
  if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
  out.setTextColor(c or colors.white)
  out.write(tostring(txt):sub(1, w))
end

function clearMon(out)
  if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
  if out.setTextColor then out.setTextColor(colors.white) end
  out.clear()
end

function kindCounts()
  local c = {}
  for _, d in pairs(seen) do
    local k = d.kind or "device"
    c[k] = (c[k] or 0) + 1
  end
  return c
end

function uptimeStr()
  local sec = math.floor((os.epoch("utc") - BOOT_EPOCH) / 1000)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then return ("%dh %dm"):format(h, m) end
  if m > 0 then return ("%dm %ds"):format(m, s) end
  return ("%ds"):format(s)
end

function drawStatusChips(L, y, on, off, unk)
  local out, w = L.out, L.w
  if L.tier == "tiny" then
    guiText(out, 1, y, ("ON:%d OFF:%d ?:%d"):format(on, off, unk), colors.white, colors.black)
    return
  end
  local x = 1
  if L.color then
    guiFill(out, 1, y, w, 1, colors.black, colors.white)
    x = guiChip(out, x, y, "ON " .. on, colors.black, colors.lime, true)
    x = guiChip(out, x, y, "OFF " .. off, colors.white, colors.red, true)
    guiChip(out, x, y, "? " .. unk, colors.black, colors.yellow, true)
  else
    guiText(out, 1, y,
      ("ONLINE:%d  OFFLINE:%d  UNKNOWN:%d"):format(on, off, unk),
      colors.white, colors.black)
  end
end

function drawRosterScoped(out, scope, y0, y1)
  local L = monLayout(out)
  local w, h = L.w, L.h
  y0 = y0 or 1
  y1 = y1 or (h - L.footerH)
  local on, off, unk = countScoped(scope)
  local title = (scope == "global") and "GLOBAL MESH" or "LOCAL NETWORK"
  local accent = (scope == "global") and (colors.orange or colors.yellow) or (colors.cyan or colors.lightBlue)

  local y = y0
  guiBar(L, y, title, L.color and (L.tier ~= "tiny" and "ADV" or nil) or "MONO", accent)
  y = y + 1

  if y <= y1 then
    drawStatusChips(L, y, on, off, unk)
    y = y + 1
  end

  if L.headerH >= 3 and y <= y1 then
    local nPeers, nCells = 0, 0
    for _ in pairs(netPeers) do nPeers = nPeers + 1 end
    for _ in pairs(netCells) do nCells = nCells + 1 end
    local meta
    if scope == "global" then
      meta = ("backbone %d  cells %d"):format(nPeers, nCells)
    else
      meta = ("cells %d  peers %d"):format(nCells, nPeers)
    end
    if L.color then
      guiFill(out, 1, y, w, 1, colors.gray, colors.white)
      guiText(out, 2, y, meta, colors.white, colors.gray)
    else
      guiText(out, 1, y, meta, colors.lightGray, colors.black)
    end
    y = y + 1
  end

  -- Column plan by width.
  local showKind = w >= 28
  local showAge = w >= 36
  local idW = (w < 22) and 3 or 4
  local stW = (L.tier == "tiny") and 3 or 8
  if y <= y1 then
    local hdr
    if L.tier == "tiny" then
      hdr = "ID ST HOST"
    elseif not showKind then
      hdr = ("%-" .. idW .. "s %-8s HOST"):format("ID", "STATUS")
    elseif not showAge then
      hdr = ("%-" .. idW .. "s %-8s %-6s HOST"):format("ID", "STATUS", "KIND")
    else
      hdr = ("%-" .. idW .. "s %-8s %-8s HOST"):format("ID", "STATUS", "KIND")
    end
    local hbg = L.color and colors.lightGray or colors.black
    local hfg = L.color and colors.black or colors.lightGray
    if L.color then guiFill(out, 1, y, w, 1, hbg, hfg) end
    guiText(out, 1 + L.pad, y, hdr, hfg, hbg)
    y = y + 1
  end

  local listStart = y
  local ids = sortedIdsScoped(scope)
  for _, id in ipairs(ids) do
    if y > y1 then break end
    local d = seen[id]
    local host = d.hostname or d.name or "?"
    if scope == "global" and d.hub then
      host = host .. " @" .. tostring(d.hub):sub(1, 8)
    elseif scope == "global" and d.homeRouter and d.homeRouter ~= os.getComputerID() then
      host = host .. " →#" .. tostring(d.homeRouter)
    end
    local status, statusColor = statusOf(d, id)
    local stShort = status
    if L.tier == "tiny" then
      if status == "ONLINE" then stShort = "ON"
      elseif status == "OFFLINE" then stShort = "OFF"
      elseif status == "WIRED" then stShort = "WR"
      else stShort = "?" end
    end
    local age = d.seen and d.seen > 0 and (ago(d.seen) .. "s") or "-"
    local kind = (d.kind or "?"):sub(1, showKind and (w >= 40 and 8 or 6) or 0)
    local bg = colors.black
    if L.color and ((y - listStart) % 2 == 1) then bg = colors.gray end

    if L.color then guiFill(out, 1, y, w, 1, bg, colors.white) end

    local x = 1 + L.pad
    guiText(out, x, y, ("%-" .. idW .. "d"):format(id), colors.white, bg)
    x = x + idW + 1

    if L.color and L.tier ~= "tiny" then
      local chip = ("%-" .. math.min(stW, 8) .. "s"):format(stShort)
      local chipBg = statusColor
      local chipFg = colors.black
      if status == "OFFLINE" then chipFg = colors.white end
      if status == "UNKNOWN" then chipFg = colors.black end
      guiText(out, x, y, chip, chipFg, chipBg)
      x = x + #chip + 1
    else
      guiText(out, x, y, ("%-" .. stW .. "s"):format(stShort), statusColor, bg)
      x = x + stW + 1
    end

    local kindCol = colors.white
    if status == "WIRED" then kindCol = colors.cyan
    elseif d.remote or scope == "global" then kindCol = colors.orange or colors.yellow
    end
    if showKind and #kind > 0 then
      local kw = (w >= 40) and 8 or 6
      guiText(out, x, y, ("%-" .. kw .. "s"):format(kind), kindCol, bg)
      x = x + kw + 1
    end

    local ageStr = showAge and tostring(age) or ""
    local room = w - x - (showAge and (#ageStr + 1) or 0) - L.pad
    if room < 1 then room = math.max(0, w - x) end
    guiText(out, x, y, host:sub(1, room), colors.white, bg)
    if showAge and #ageStr > 0 then
      guiText(out, w - #ageStr + 1 - L.pad, y, ageStr, colors.lightGray, bg)
    end
    y = y + 1
  end

  if y == listStart and y <= y1 then
    local empty = (scope == "global")
      and "(no remote hubs — link peer <id>)"
      or "(no local devices — link modem <id>)"
    guiText(out, 1 + L.pad, y, empty, colors.gray, colors.black)
  end
end

function drawRoster(out, y0, y1)
  drawRosterScoped(out, "local", y0, y1)
end

function drawGlobal(out, y0, y1)
  drawRosterScoped(out, "global", y0, y1)
end

function drawStats(out, y0, y1)
  local L = monLayout(out)
  local w, h = L.w, L.h
  y0 = y0 or 1
  y1 = y1 or (h - L.footerH)
  local on, off, unk = countOnlineOffline()
  local remembered = 0
  for _ in pairs(seen) do remembered = remembered + 1 end
  local cyan = colors.cyan or colors.lightBlue
  local nRf = wirelessModems and #wirelessModems or 0
  local nWire = wiredModems and #wiredModems or 0
  local nModems = modems and #modems or (nRf + nWire)
  local nRelayed = (relayStats and tonumber(relayStats.relayed)) or 0

  local y = y0
  guiBar(L, y, "STATS", ("#%d"):format(os.getComputerID()), cyan)
  y = y + 1

  if y <= y1 then
    drawStatusChips(L, y, on, off, unk)
    y = y + 1
  end

  local cards = {
    { "ROLE", tostring(routerRole or "?"):upper(), colors.white },
    { "HOST", tostring(os.getComputerLabel() or "?"):sub(1, 16), colors.lightGray },
    { "UP", uptimeStr(), colors.white },
    { "MODEMS", ("%d rf:%d wire:%d"):format(nModems, nRf, nWire), colors.white },
    { "RELAY", tostring(nRelayed), cyan },
    { "WIRED", tostring(countWiredOnline()), cyan },
    { "MEM", tostring(remembered), colors.white },
  }

  if L.color and L.tier ~= "tiny" and w >= 30 then
    -- Two-column key/value cards on advanced monitors.
    local colW = math.floor((w - 2) / 2)
    local i = 1
    while i <= #cards and y <= y1 do
      local a, b = cards[i], cards[i + 1]
      guiFill(out, 1, y, w, 1, colors.gray, colors.white)
      local left = (" %s %s"):format(a[1], a[2])
      guiText(out, 1, y, left:sub(1, colW), a[3], colors.gray)
      if b then
        local right = (" %s %s"):format(b[1], b[2])
        guiText(out, colW + 2, y, right:sub(1, colW), b[3], colors.gray)
        i = i + 2
      else
        i = i + 1
      end
      y = y + 1
    end
  else
    for _, c in ipairs(cards) do
      if y > y1 then break end
      local line = ("%s: %s"):format(c[1], c[2])
      if L.tier == "tiny" then line = ("%s %s"):format(c[1], c[2]) end
      guiText(out, 1 + L.pad, y, line, c[3], colors.black)
      y = y + 1
    end
  end

  if y <= y1 then
    if L.color then
      guiFill(out, 1, y, w, 1, colors.lightGray, colors.black)
      guiText(out, 2, y, "BY KIND", colors.black, colors.lightGray)
    else
      guiText(out, 1, y, "By kind:", colors.lightGray, colors.black)
    end
    y = y + 1
  end

  local kinds = kindCounts()
  local keys = {}
  for k in pairs(kinds) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if y > y1 then break end
    local n = kinds[k]
    if L.color and w >= 24 then
      local barW = math.max(1, math.min(w - 14, n))
      guiText(out, 1 + L.pad, y, ("%-10s %3d "):format(k:sub(1, 10), n), colors.white, colors.black)
      guiText(out, 16 + L.pad, y, string.rep(" ", barW), colors.black, cyan)
    else
      guiText(out, 1 + L.pad, y, ("%-10s %d"):format(k, n), colors.white, colors.black)
    end
    y = y + 1
  end
  if #keys == 0 and y <= y1 then
    guiText(out, 1 + L.pad, y, "(none)", colors.gray, colors.black)
  end
end

function drawGps(out, y0, y1)
  local L = monLayout(out)
  local w, h = L.w, L.h
  y0 = y0 or 1
  y1 = y1 or (h - L.footerH)
  local y = y0
  guiBar(L, y, "GPS", gpsCoords and "HOSTING" or "IDLE", colors.yellow)
  y = y + 1

  local function put(txt, c, bg)
    if y > y1 then return end
    if L.color and bg then guiFill(out, 1, y, w, 1, bg, c or colors.white) end
    guiText(out, 1 + L.pad, y, txt, c or colors.white, bg or colors.black)
    y = y + 1
  end

  if gpsCoords then
    if L.color then
      put(" HOSTING ", colors.black, colors.lime)
      local box = ("  X %-6d  Y %-6d  Z %-6d"):format(gpsCoords.x, gpsCoords.y, gpsCoords.z)
      if L.tier == "tiny" then
        put(("%d,%d,%d"):format(gpsCoords.x, gpsCoords.y, gpsCoords.z), colors.white, colors.gray)
      else
        put(box, colors.white, colors.gray)
        put(("  %d, %d, %d"):format(gpsCoords.x, gpsCoords.y, gpsCoords.z), colors.cyan, colors.black)
      end
    else
      put("Hosting: YES", colors.lime)
      put(("X: %d"):format(gpsCoords.x), colors.white)
      put(("Y: %d"):format(gpsCoords.y), colors.white)
      put(("Z: %d"):format(gpsCoords.z), colors.white)
    end
  else
    put(L.color and " NOT HOSTING " or "Hosting: NO",
      L.color and colors.white or colors.red,
      L.color and colors.red or colors.black)
    put("Use: gpshost <x> <y> <z>", colors.lightGray)
  end

  if y <= y1 and L.tier ~= "tiny" then put("", colors.white) end
  put("Live locate", colors.lightGray, L.color and colors.gray or nil)
  local lx, ly, lz = gps.locate(0.3)
  if lx then
    lx = math.floor(lx + 0.5); ly = math.floor(ly + 0.5); lz = math.floor(lz + 0.5)
    put(("  %d, %d, %d"):format(lx, ly, lz), colors.lime)
  else
    put("  (no fix — need 4 hosts)", colors.orange or colors.yellow)
  end
  if L.tier ~= "tiny" then
    put("", colors.white)
    put("Constellation: place 4+ routers", colors.gray)
    put("with gpshost set.", colors.gray)
  end
end

function setScreenOn(role, on)
  role = normalizeScreenRole(role)
  if not isScreenRole(role) then return false end
  if on then
    return wakeBoard(role, false)
  end
  screenOn[role] = false
  screenPerm[role] = false
  boardWakeAt = nil
  ensureFocus()
  saverActive = false
  saverState = {}
  saveScreenAssignments()
  return true
end

function setScreenFocus(role)
  role = normalizeScreenRole(role)
  if not isScreenRole(role) then return false end
  return wakeBoard(role, false)
end

-- Forward-declared; body set after drawFleetMapOn.
drawMapBoard = nil
drawBoards = nil

-- Bounce "TitanSystems" on the primary monitor (erase old glyph only).
function screensaverFrame(entering)
  refreshScreens()
  local mon = displayMon
  if not mon then return end
  local tw = #SAVER_TEXT
  local cyan = colors.cyan or colors.lightBlue
  local w, h = mon.getSize()
  local st = saverState
  if w < tw + 1 or h < 2 then
    if entering then clearMon(mon) end
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(cyan)
    mon.setCursorPos(math.max(1, math.floor((w - tw) / 2) + 1), math.max(1, math.floor(h / 2)))
    mon.write(SAVER_TEXT:sub(1, w))
    return
  end
  if entering or not st.w or st.w ~= w or st.h ~= h then
    clearMon(mon)
    local maxX = w - tw + 1
    st = {
      x = math.random(1, math.max(1, maxX)),
      y = math.random(1, h),
      dx = (math.random(0, 1) == 0) and -1 or 1,
      dy = (math.random(0, 1) == 0) and -1 or 1,
      w = w, h = h, tw = tw,
      prevX = nil, prevY = nil,
    }
    saverState = st
  else
    if st.prevX and st.prevY then
      mon.setBackgroundColor(colors.black)
      mon.setTextColor(colors.black)
      mon.setCursorPos(st.prevX, st.prevY)
      mon.write(string.rep(" ", st.tw))
    end
    st.x = st.x + st.dx
    st.y = st.y + st.dy
    local maxX = w - tw + 1
    if st.x <= 1 then st.x = 1; st.dx = 1
    elseif st.x >= maxX then st.x = maxX; st.dx = -1 end
    if st.y <= 1 then st.y = 1; st.dy = 1
    elseif st.y >= h then st.y = h; st.dy = -1 end
  end
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(cyan)
  mon.setCursorPos(st.x, st.y)
  mon.write(SAVER_TEXT)
  st.prevX, st.prevY = st.x, st.y
end

function drawUpdateAcks(out)
  clearMon(out)
  local L = monLayout(out)
  local w, h = L.w, L.h
  local camp = updateCampaign
  if not camp then
    guiBar(L, 1, "OTA UPDATE", nil, colors.yellow)
    guiText(out, 1 + L.pad, 2, "(no active campaign)", colors.gray, colors.black)
    guiFooter(L, "update")
    return
  end
  local exp, ack, fail = campaignCounts()
  guiBar(L, 1, ("OTA v%s"):format(tostring(camp.version or "?")), nil, colors.yellow)
  local y = 2
  if L.color then
    local x = 1
    x = guiChip(out, x, y, "ACK " .. tostring(ack or 0), colors.black, colors.lime, true)
    x = guiChip(out, x, y, "FAIL " .. tostring(fail or 0), colors.white, colors.red, true)
    guiChip(out, x, y, "EXP " .. tostring(exp or 0), colors.black, colors.lightGray, true)
  else
    guiText(out, 1, y, ("ACKs %d  FAIL %d  / %d expected"):format(ack or 0, fail or 0, exp or 0), colors.lime, colors.black)
  end
  y = 3

  local ids = {}
  for id in pairs(camp.expected) do ids[#ids + 1] = id end
  table.sort(ids)
  if camp.acked[os.getComputerID()] then
    local selfId = os.getComputerID()
    local has = false
    for _, id in ipairs(ids) do if id == selfId then has = true; break end end
    if not has then table.insert(ids, 1, selfId) end
  end

  local function put(txt, c, bg)
    if y > h - 1 then return false end
    if L.color and bg then guiFill(out, 1, y, w, 1, bg, c or colors.white) end
    guiText(out, 1 + L.pad, y, txt, c or colors.white, bg or colors.black)
    y = y + 1
    return true
  end

  for _, id in ipairs(ids) do
    if y > h - 1 then
      put("...", colors.gray)
      break
    end
    local name = camp.expected[id]
      or (camp.acked[id] and camp.acked[id].name)
      or (seen[id] and (seen[id].hostname or seen[id].name))
      or ("#" .. id)
    local ainfo = camp.acked[id]
    local finfo = camp.failed[id]
    if ainfo then
      if not put(tostring(name), L.color and colors.black or colors.lime, L.color and colors.lime or nil) then break end
      local pkgs = ainfo.packages or {}
      if #pkgs == 0 then
        put(("  system - version: ? - %s"):format(tostring(ainfo.version or "?")), colors.white)
      else
        for _, p in ipairs(pkgs) do
          local line = ("%s - version: %s - %s"):format(
            tostring(p.name or p.path or "?"),
            tostring(p.from or "?"),
            tostring(p.to or "?"))
          if not put("  " .. line, colors.white) then break end
        end
      end
    elseif finfo then
      if not put(tostring(finfo.name or name), L.color and colors.white or colors.red, L.color and colors.red or nil) then break end
      put(("  FAIL: %s"):format(tostring(finfo.err or "?"):sub(1, w - 8)), colors.orange or colors.yellow)
    else
      if not put(tostring(name), colors.lightGray, L.color and colors.gray or nil) then break end
      put("  (waiting for ACK...)", colors.gray)
    end
    if y < h - 1 and L.tier ~= "tiny" then put("", colors.white) end
  end

  if #ids == 0 then
    put("(no online devices expected — main self-updated)", colors.gray)
  end

  local footer = camp.finishedAt and "done" or "collecting"
  guiFooter({ out = out, w = w, h = h, color = L.color, tier = L.tier }, "update")
  if L.color then
    guiText(out, math.max(1, w - #footer - 12), h, footer, colors.white, colors.gray)
  end
end

paintUpdateAcks = function()
  refreshScreens()
  local mon = displayMon
  if not mon then
    -- Still try the first attached monitor even if board focus is off.
    local names = listMonitorNames()
    if #names == 0 then return false, "no monitor" end
    mon = wrapScreen(names[1])
    displayMon, displayMonName = mon, names[1]
  end
  if not mon then return false, "no monitor" end
  drawUpdateAcks(mon)
  return true
end

drawBoards = function()
  if otaOverlay or (updateCampaign and updateCampaign.showAcks) then
    paintUpdateAcks()
    return
  end

  local n = refreshScreens()
  if n == 0 or not displayMon then return end

  if not anyLiveBoard() then return end

  local role = screenFocus
  if not screenOn[role] then
    local active = ensureFocus()
    if #active == 0 then return end
    role = screenFocus
  end

  local mon = displayMon
  clearMon(mon)
  local L = monLayout(mon)
  local contentBottom = math.max(1, L.h - L.footerH)

  if role == "stats" then
    drawStats(mon, 1, contentBottom)
  elseif role == "gps" then
    drawGps(mon, 1, contentBottom)
  elseif role == "map" then
    if drawMapBoard then drawMapBoard(mon) else
      guiBar(L, 1, "MAP", nil, colors.yellow)
      guiText(mon, 1, 2, "(map unavailable)", colors.gray, colors.black)
    end
  elseif role == "global" then
    drawGlobal(mon, 1, contentBottom)
  else
    -- roster / local
    drawRoster(mon, 1, contentBottom)
  end

  -- Map board has its own chrome; other boards share the adaptive footer.
  if L.h >= 2 and role ~= "map" then
    guiFooter(L, role)
  end
end

function drawLoop()
  loadScreenAssignments()
  while true do
    refreshWiredFlags()
    if not otaOverlay then
      expireTemporaryBoards()
    end
    maybeFinishUpdateCampaign()
    if otaOverlay or (updateCampaign and updateCampaign.showAcks) then
      if saverActive then
        saverActive = false
        saverState = {}
      end
      local ok, err = pcall(paintUpdateAcks)
      if not ok then
        -- Keep trying; print once in a while via console if needed.
        if type(err) == "string" then
          -- swallow spam; beginUpdateMonitor already reports first failure
        end
      end
      if rosterDirty then saveRoster() end
      sleep(clampMonRate(monRate))
    elseif not anyLiveBoard() then
      local entering = not saverActive
      saverActive = true
      screensaverFrame(entering)
      if rosterDirty then saveRoster() end
      sleep(0.08)   -- ~12 fps bounce
    else
      if saverActive then
        saverActive = false
        saverState = {}
      end
      drawBoards()
      if rosterDirty then saveRoster() end
      sleep(clampMonRate(monRate))
    end
  end
end

-- Persist roster even without a monitor.
function rosterSaveLoop()
  while true do
    if rosterDirty then saveRoster() end
    sleep(5)
  end
end

-- Periodically nudge the network so devices that booted before us also register.
function pingLoop()
  while true do
    rednet.broadcast({ type = "ping" }, "titan_net")
    rednet.broadcast({ type = "ping" }, "titan_dc")
    if isMain() then
      claimMain()
      broadcastFleetMap()
    end
    sleep(15)
  end
end

-- Poll GitHub versions.lua; alert when remote system version is newer.
function githubWatchLoop()
  sleep(5)
  while true do
    if isMain() then
      local cat, err = fetchGithubVersions()
      if cat and cat.system then
        local localVer = localSystemVersion()
        if versionCmp(localVer, cat.system) < 0
           and ghState.lastAlert ~= cat.system then
          ghState.lastAlert = cat.system
          print("")
          print(("[GitHub] New Titan v%s available (local %s)."):format(
            tostring(cat.system), tostring(localVer or "?")))
          print("[GitHub] Run `update` (modems) or `update all` (whole fleet).")
        end
      elseif err then
        -- Quiet unless first failure after boot.
        if not ghState.remote then
          print("[GitHub] Version check failed: " .. tostring(err))
        end
      end
    end
    sleep(300)  -- every 5 minutes
  end
end

-- MODEM routers: mesh hop to MAIN (no local roster), accept unique name, reboot.
-- rednet CHANNEL_REPEAT already relays; we also app-hop hello/where_main when
-- a peer cannot hear main directly.
function modemLoop()
  local manualName = false
  local assignedName = nil
  local mainId = nil
  local mainInfo = nil   -- last main_here fields
  local mainSeenAt = 0
  local MAIN_STALE = 90  -- seconds without hearing main => rediscover via hops

  do
    local c = loadRouterCfg() or {}
    if c.manualHostname then manualName = true end
    if type(c.assignedName) == "string" and c.assignedName ~= "" then
      assignedName = c.assignedName
      if os.getComputerLabel() ~= assignedName then
        os.setComputerLabel(assignedName)
      end
    end
    if tonumber(c.mainRouterId) then mainId = tonumber(c.mainRouterId) end
  end

  local function ownPos()
    if gpsCoords then return gpsCoords.x, gpsCoords.y, gpsCoords.z end
    local x, y, z = gps.locate(1)
    if x then
      return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
    end
    return nil
  end

  local function rememberMain(id, msg)
    if not id or not msg then return end
    if msg.main or msg.type == "main_claim" or msg.type == "main_here"
       or msg.mainRouterId then
      mainId = tonumber(msg.mainRouterId) or id
      mainInfo = msg
      mainSeenAt = os.clock()
      patchRouterCfg({ mainRouterId = mainId })
    end
  end

  local function applyAssignedName(name, shouldReboot)
    if not name or name == "" or manualName then return false end
    local cur = os.getComputerLabel()
    if cur == name and assignedName == name then
      return false
    end
    os.setComputerLabel(name)
    assignedName = name
    patchRouterCfg({ assignedName = name, manualHostname = false })
    print("[name] Main router assigned: " .. name)
    if shouldReboot ~= false then
      print("[name] Rebooting with new hostname...")
      sleep(1)
      os.reboot()
    end
    return true
  end

  local function handleAssign(msg)
    if not msg or not msg.assignHostname then return end
    local needReboot = msg.reboot == true
      or (os.getComputerLabel() ~= msg.assignHostname)
      or (assignedName ~= msg.assignHostname)
    applyAssignedName(msg.assignHostname, needReboot)
  end

  local function hubId()
    return homeRouterId or mainId
  end

  local function announce()
    local x, y, z = ownPos()
    local name = assignedName or os.getComputerLabel()
      or ((routerRole == "router") and ("Router-" .. os.getComputerID())
          or ("Modem-pending-" .. os.getComputerID()))
    local kind = roleKind()
    local msg = {
      type = "hello", kind = kind, name = name, hostname = name,
      role = routerRole,
      autoName = (routerRole == "modem") and (not manualName) or false,
      needName = (routerRole == "modem") and (not manualName) and (assignedName == nil),
      homeRouter = homeRouterId,
    }
    if x then msg.x, msg.y, msg.z = x, y, z end
    -- Prefer home router (local hub), then MAIN, then broadcast.
    local hub = hubId()
    if hub then rednet.send(hub, msg, PROTO_ROUTER) end
    if mainId and mainId ~= hub then rednet.send(mainId, msg, PROTO_ROUTER) end
    for peerId in pairs(netPeers) do
      rednet.send(peerId, msg, PROTO_ROUTER)
    end
    rednet.broadcast(msg, PROTO_ROUTER)
    broadcastNetHello()
    if not mainId or (os.clock() - mainSeenAt) > MAIN_STALE then
      rednet.broadcast({
        type = "hop_find_main", from = os.getComputerID(),
        name = name, hostname = name,
      }, PROTO_ROUTER)
      if hub then
        rednet.send(hub, {
          type = "hop_find_main", from = os.getComputerID(),
          name = name, hostname = name,
        }, PROTO_ROUTER)
      end
    end
  end

  local function findMain()
    rednet.broadcast({ type = "where_main", name = os.getComputerLabel() }, PROTO_ROUTER)
    rednet.broadcast({
      type = "hop_find_main", from = os.getComputerID(),
      name = os.getComputerLabel(),
    }, PROTO_ROUTER)
    local hub = hubId()
    if hub then
      rednet.send(hub, { type = "where_main", name = os.getComputerLabel() }, PROTO_ROUTER)
    end
  end

  if routerRole == "modem" and not manualName and not assignedName then
    print("[name] Waiting for main router to assign a unique name...")
  end
  if routerRole == "router" then
    print("[backbone] ROUTER mode — ender peer to MAIN/other routers; host local modems.")
  else
    print("[hop] MODEM cell — links to home router, then backbone.")
  end
  if homeRouterId then
    print("[link] Home router #" .. tostring(homeRouterId))
  end
  findMain()
  announce()
  local nextAnn = os.clock() + 20
  while true do
    if os.clock() >= nextAnn then announce(); nextAnn = os.clock() + 20 end
    local id, msg = rednet.receive(PROTO_ROUTER, math.max(0.2, nextAnn - os.clock()))
    if type(msg) ~= "table" or not id then
      -- ignore
    elseif handleNetControl(id, msg) then
      -- topology / link / hop
    elseif msg.type == "main_claim" or msg.type == "main_here" then
      rememberMain(id, msg)
      handleAssign(msg)
      announce()

    elseif msg.type == "here" then
      rememberMain(id, msg)
      handleAssign(msg)

    elseif msg.type == "hop_reply" then
      -- Reply from main via another modem (or for us to forward).
      if tonumber(msg.dest) == os.getComputerID() then
        rememberMain(msg.mainRouterId or id, msg)
        handleAssign(msg)
      elseif msg.dest then
        rednet.send(tonumber(msg.dest), msg, PROTO_ROUTER)
      end

    elseif msg.type == "where_main" or msg.type == "hop_find_main" then
      -- Peer looking for main: answer + forward via hub/peers.
      local hub = hubId()
      if mainId and mainInfo and id ~= mainId then
        local reply = {
          type = "main_here",
          main = true,
          mainRouterId = mainId,
          label = mainInfo.label or mainInfo.hostname,
          hostname = mainInfo.hostname or mainInfo.label,
          x = mainInfo.x, y = mainInfo.y, z = mainInfo.z,
          via = os.getComputerID(),
          hop = true,
        }
        rednet.send(id, reply, PROTO_ROUTER)
        rednet.send(mainId, {
          type = "where_main", from = id, via = os.getComputerID(),
          name = msg.name or msg.hostname,
        }, PROTO_ROUTER)
        for peerId in pairs(netPeers) do
          if peerId ~= id then
            rednet.send(peerId, {
              type = "where_main", from = id, via = os.getComputerID(),
              name = msg.name or msg.hostname,
            }, PROTO_ROUTER)
          end
        end
      elseif hub and id ~= hub then
        rednet.send(hub, msg, PROTO_ROUTER)
      elseif mainId and id ~= mainId then
        rednet.send(mainId, msg, PROTO_ROUTER)
      end

    elseif msg.type == "hello" and (msg.kind == "modem" or msg.kind == "router" or msg.autoName) then
      -- Hop toward home hub / MAIN / backbone peers.
      local hub = hubId()
      if hub and id ~= hub and id ~= os.getComputerID() then
        rednet.send(hub, {
          type = "hop_hello", from = id, via = os.getComputerID(),
          hello = msg,
        }, PROTO_ROUTER)
      end
      if mainId and mainId ~= hub and id ~= mainId then
        rednet.send(mainId, {
          type = "hop_hello", from = id, via = os.getComputerID(),
          hello = msg,
        }, PROTO_ROUTER)
      end
      if isBackbone() and (msg.kind == "modem" or msg.role == "modem") then
        if tonumber(msg.homeRouter) == os.getComputerID() or netCells[id] then
          addNetCell(id, msg.name or msg.hostname)
        end
      end

    elseif msg.type == "update" and id ~= os.getComputerID() then
      print("")
      print(("[OTA] Fleet update from #%s (v%s) — downloading..."):format(
        tostring(id), tostring(msg.targetVersion or "?")))
      if titanLib and titanLib.updateSelf then
        local prev = titanLib.systemVersion and titanLib.systemVersion() or nil
        local ok, detail = titanLib.updateSelf()
        if ok then
          local pkgs = type(detail) == "table" and detail.packages or nil
          if titanLib.markPendingUpdateAck then
            titanLib.markPendingUpdateAck(prev, msg.targetVersion, pkgs)
          end
          print("[OTA] Updated. Rebooting (will ACK main)..."); sleep(2); os.reboot()
        else
          print("[OTA] Failed: " .. tostring(detail))
          rednet.send(id, {
            type = "update_fail", version = prev, err = tostring(detail),
            name = os.getComputerLabel(), hostname = os.getComputerLabel(),
          }, PROTO_ROUTER)
        end
      else
        print("[OTA] No titan updateSelf — rebooting..."); sleep(1); os.reboot()
      end
    end
  end
end

-- Routers double as GPS hosts: answer gps.locate PINGs with our coordinates.
-- (Faithful to the built-in `gps host` protocol.) Only run when gpsCoords is set.
function gpsHostLoop()
  for _, side in ipairs(modems) do peripheral.call(side, "open", gps.CHANNEL_GPS) end
  while true do
    local _, side, ch, reply, message = os.pullEvent("modem_message")
    if ch == gps.CHANNEL_GPS and message == "PING" and reply then
      peripheral.call(side, "transmit", reply, gps.CHANNEL_GPS,
        { gpsCoords.x, gpsCoords.y, gpsCoords.z })
    end
  end
end

--------------------------------------------------------------------------------
-- Fleet map (MAIN): zoomed-out ASCII grid of routers/modems
-- Grid lines use - _ | \ /   Markers: r = main, m = modem
--------------------------------------------------------------------------------
mapScale = 16  -- blocks per cell (zoomed out by default)

function fleetMapNodes()
  local list = {}
  local myId = os.getComputerID()
  local rname = os.getComputerLabel() or ("Router-" .. myId)
  if gpsCoords then
    list[#list + 1] = {
      id = myId, name = rname, kind = "router",
      x = gpsCoords.x, y = gpsCoords.y, z = gpsCoords.z, main = true,
    }
  end
  for id, d in pairs(seen) do
    if id ~= myId and d.x and d.z
       and (d.kind == "modem" or d.kind == "router") then
      list[#list + 1] = {
        id = id,
        name = d.hostname or d.name or ("#" .. id),
        kind = d.kind,
        x = d.x, y = d.y, z = d.z,
        main = false,
        wired = d.wired or isWiredFresh(id) or nil,
      }
    end
  end
  return list
end

function mapOrigin(nodes)
  if gpsCoords then return gpsCoords.x, gpsCoords.z end
  if #nodes == 0 then return 0, 0 end
  local sx, sz = 0, 0
  for _, n in ipairs(nodes) do sx = sx + n.x; sz = sz + n.z end
  return math.floor(sx / #nodes + 0.5), math.floor(sz / #nodes + 0.5)
end

function mapAutoScale(nodes, ox, oz, gw, gh)
  local maxD = 8
  for _, n in ipairs(nodes) do
    maxD = math.max(maxD, math.abs(n.x - ox), math.abs(n.z - oz))
  end
  local half = math.max(2, math.floor(math.min(gw, gh) / 2) - 1)
  return math.max(2, math.ceil(maxD / half))
end

-- Background cell art from (-, _, |, \, /).
function mapGridChar(relX, relZ)
  if relX == 0 and relZ == 0 then return "+" end
  if relX == 0 then return "|" end
  if relZ == 0 then return "-" end
  if relX == relZ then return "\\" end
  if relX == -relZ then return "/" end
  if relZ % 4 == 0 then return "_" end
  if relX % 4 == 0 then return "|" end
  if (relX + relZ) % 6 == 0 then return "/" end
  if (relX - relZ) % 6 == 0 then return "\\" end
  if relZ % 2 == 0 then return "-" end
  return " "
end

-- Draw fleet map onto any term/monitor (`out`). opts.interactive adds key hints.
function drawFleetMapOn(out, scale, opts)
  opts = opts or {}
  local tw, th = out.getSize()
  out.setBackgroundColor(colors.black)
  out.clear()
  local colorOk = out.isColor and out.isColor()
  local function put(x, y, ch, fg)
    if x < 1 or y < 1 or x > tw or y > th then return end
    out.setCursorPos(x, y)
    if colorOk then
      out.setTextColor(fg or colors.white)
      out.setBackgroundColor(colors.black)
    end
    out.write(ch)
  end

  local nodes = fleetMapNodes()
  local ox, oz = mapOrigin(nodes)
  if not gpsCoords and #nodes == 0 then
    put(1, 1, "No GPS / modem positions yet.", colors.red)
    put(1, 2, "Set gpshost; wait for modem hellos.", colors.gray)
    if opts.interactive then put(1, 4, "[Q] quit", colors.gray) end
    return nodes, ox, oz, scale or mapScale
  end

  local top, bottom = 3, th - 3
  local left, right = 1, tw
  local gw, gh = right - left + 1, bottom - top + 1
  if gh < 4 then top, bottom = 2, th - 1 end
  gw, gh = right - left + 1, bottom - top + 1
  if not scale then
    scale = mapAutoScale(nodes, ox, oz, gw, math.max(4, gh))
  end
  mapScale = scale

  put(1, 1, ("FLEET MAP  origin %d,%d  %dm/cell"):format(ox, oz, scale), colors.yellow)
  if opts.interactive then
    put(1, 2, "r=main  m=rf  w=wired  N=up  +/- zoom  F fit  Q quit", colors.lightGray)
  else
    put(1, 2, "r=main  m=rf  w=wired  N=up   (map board)", colors.lightGray)
  end

  local cx = left + math.floor(gw / 2)
  local cy = top + math.floor(gh / 2)

  for gy = top, bottom do
    for gx = left, right do
      put(gx, gy, mapGridChar(gx - cx, gy - cy), colors.gray)
    end
  end
  put(cx, top, "N", colors.white)
  put(right, cy, "E", colors.white)
  put(cx, bottom, "S", colors.white)
  put(left, cy, "W", colors.white)

  local function cellOf(wx, wz)
    return cx + math.floor((wx - ox) / scale + 0.5),
           cy + math.floor((wz - oz) / scale + 0.5)
  end

  table.sort(nodes, function(a, b)
    if a.main ~= b.main then return not a.main end
    return (a.id or 0) < (b.id or 0)
  end)
  for _, n in ipairs(nodes) do
    local sx, sy = cellOf(n.x, n.z)
    if n.main or (n.kind == "router" and n.id == os.getComputerID()) then
      put(sx, sy, "r", colors.cyan)
    elseif n.wired then
      put(sx, sy, "w", colors.cyan)
    else
      put(sx, sy, "m", colors.lime)
    end
  end

  local y = th - 2
  if y < 1 then y = th end
  local parts = {}
  for _, n in ipairs(nodes) do
    local tag = (n.main or n.id == os.getComputerID()) and "r" or (n.wired and "w" or "m")
    parts[#parts + 1] = ("%s:%s"):format(tag, tostring(n.name):sub(1, 10))
  end
  put(1, y, table.concat(parts, "  "):sub(1, tw), colors.white)
  if opts.interactive then
    put(1, th, ("nodes:%d  scale:%d  [+/-] [F]fit [Q]"):format(#nodes, scale), colors.gray)
  else
    put(1, th, ("nodes:%d  scale:%d  `map false` for stats"):format(#nodes, scale), colors.gray)
  end

  if colorOk then
    out.setTextColor(colors.white)
    out.setBackgroundColor(colors.black)
  end
  return nodes, ox, oz, scale
end

drawMapBoard = function(mon)
  if not mon then return end
  monApplyScale(mon)
  local w, h = mon.getSize()
  local nodes = fleetMapNodes()
  local ox, oz = mapOrigin(nodes)
  local scale = mapAutoScale(nodes, ox, oz, w, math.max(4, h - 4))
  drawFleetMapOn(mon, scale, { interactive = false })
end

function fleetMapView()
  if not isMain() then
    print("map view is MAIN-only.")
    return
  end
  local nodes = fleetMapNodes()
  local ox, oz = mapOrigin(nodes)
  local tw, th = term.getSize()
  local scale = mapAutoScale(nodes, ox, oz, tw, math.max(5, th - 6))
  local timer = os.startTimer(2)
  while true do
    drawFleetMapOn(term, scale, { interactive = true })
    local ev, p1 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      timer = os.startTimer(2)
    elseif ev == "key" then
      if p1 == keys.q or p1 == keys.x or p1 == keys.escape then break
      elseif p1 == keys.equals or p1 == keys.numPadAdd then
        scale = math.max(2, math.floor(scale / 2))
      elseif p1 == keys.minus or p1 == keys.numPadSubtract then
        scale = math.min(256, scale * 2)
      elseif p1 == keys.f then
        nodes = fleetMapNodes()
        ox, oz = mapOrigin(nodes)
        scale = mapAutoScale(nodes, ox, oz, tw, math.max(5, th - 6))
      end
      timer = os.startTimer(0.1)
    elseif ev == "char" then
      if p1 == "q" or p1 == "Q" then break
      elseif p1 == "+" or p1 == "=" then scale = math.max(2, math.floor(scale / 2))
      elseif p1 == "-" then scale = math.min(256, scale * 2)
      elseif p1 == "f" or p1 == "F" then
        nodes = fleetMapNodes()
        ox, oz = mapOrigin(nodes)
        scale = mapAutoScale(nodes, ox, oz, tw, math.max(5, th - 6))
      end
      timer = os.startTimer(0.1)
    elseif ev == "terminate" then
      break
    end
  end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  if term.setTextColor then term.setTextColor(colors.white) end
end

--------------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------------
-- Shared by local console and SSH. Returns "exit" / false / true.
