--[[
  image_loader.lua  -  PNG → advanced (color) monitor (split UI)
  Titan-Version: 1.1.0

  Computer terminal: paste/enter a download link + short status/help.
  Color monitor: tap navigation GUI (list, Load / Fetch / Refresh / Fit / Prev / Next).

  Needs an advanced computer + attached color monitor. Monitors are a 16-color
  character/blit grid (not a true framebuffer); pixels are quantized to the
  nearest CC palette colour.

  Usage:
      image_loader
      image_loader <path.png|http-url>

  Put PNGs under images/ on the computer. Computer commands:
      <url>                   set download link (Fetch on monitor uses this)
      fetch [url] [filename]  download PNG → images/, then load
      github <ref> [filename] download from GitHub → images/, then load
      load <path|url>         load without changing link buffer
      up / down / prev / next navigate list
      fit / refresh / help / quit

  Persist: .image_loader.cfg (last link + last image).
]]

local pngImage
do
  if type(package) == "table" and type(package.path) == "string" then
    if not package.path:find("lib/%?%.lua", 1, false) and not package.path:find("lib/?.lua", 1, true) then
      package.path = "lib/?.lua;" .. package.path
    end
  end
  local function isPngModule(mod)
    return type(mod) == "table" and (mod.decodeFile or mod.decode or mod.readBinary)
  end
  local names = { "lib.png", "lib/png", "png" }
  for i = 1, #names do
    local ok, mod = pcall(require, names[i])
    if ok and isPngModule(mod) then
      pngImage = mod
      break
    end
  end
  if not pngImage and fs.exists("lib/png.lua") then
    local ok, mod = pcall(dofile, "lib/png.lua")
    if ok and isPngModule(mod) then
      pngImage = mod
    end
  end
  if not pngImage then
    error("Missing lib/png.lua — reinstall Tools → Image Loader", 0)
  end
end

--------------------------------------------------------------------------------
-- Shared state
--------------------------------------------------------------------------------
local CFG_PATH = ".image_loader.cfg"
local alive = true
local guiDirty = true
local statusMsg = "Ready"
local linkBuf = ""
local imageList = {} -- relative paths under images/
local selected = 1
local listScroll = 0
local img = nil
local imgPath = nil
local scaleMul = 1.0
local mon = nil
local monName = nil
local hitZones = {} -- filled each monitor draw

--------------------------------------------------------------------------------
-- CC default palette (RGB 0..1) + blit chars
--------------------------------------------------------------------------------
local PALETTE = {
  { colors.white,     0xF0 / 255, 0xF0 / 255, 0xF0 / 255, "0" },
  { colors.orange,    0xF2 / 255, 0xB2 / 255, 0x33 / 255, "1" },
  { colors.magenta,   0xE5 / 255, 0x7F / 255, 0xD8 / 255, "2" },
  { colors.lightBlue, 0x99 / 255, 0xB2 / 255, 0xF2 / 255, "3" },
  { colors.yellow,    0xDE / 255, 0xDE / 255, 0x6C / 255, "4" },
  { colors.lime,      0x7F / 255, 0xCC / 255, 0x19 / 255, "5" },
  { colors.pink,      0xF2 / 255, 0xB2 / 255, 0xCC / 255, "6" },
  { colors.gray,      0x4C / 255, 0x4C / 255, 0x4C / 255, "7" },
  { colors.lightGray, 0x99 / 255, 0x99 / 255, 0x99 / 255, "8" },
  { colors.cyan,      0x4C / 255, 0x99 / 255, 0xB2 / 255, "9" },
  { colors.purple,    0xB2 / 255, 0x66 / 255, 0xE5 / 255, "a" },
  { colors.blue,      0x33 / 255, 0x66 / 255, 0xCC / 255, "b" },
  { colors.brown,     0x7F / 255, 0x66 / 255, 0x4C / 255, "c" },
  { colors.green,     0x57 / 255, 0xA6 / 255, 0x4E / 255, "d" },
  { colors.red,       0xCC / 255, 0x4C / 255, 0x4C / 255, "e" },
  { colors.black,     0x19 / 255, 0x19 / 255, 0x19 / 255, "f" },
}

local function nearestBlit(r, g, b, a)
  if a ~= nil and a < 0.5 then return "f" end
  local best, bestD = "f", math.huge
  for i = 1, #PALETTE do
    local p = PALETTE[i]
    local dr, dg, db = r - p[2], g - p[3], b - p[4]
    local d = dr * dr + dg * dg + db * db
    if d < bestD then
      bestD, best = d, p[5]
    end
  end
  return best
end

local function pixelRGBA(image, x, y)
  local px = image:get_pixel(x, y)
  if not px then return 0, 0, 0, 0 end
  local r = px.r or px.R or 0
  local g = px.g or px.G or 0
  local b = px.b or px.B or 0
  local a = px.a or px.A
  if a == nil then a = 1 end
  if r > 1 or g > 1 or b > 1 then
    r, g, b = r / 255, g / 255, b / 255
  end
  if a > 1 then a = a / 255 end
  return r, g, b, a
end

local function setStatus(msg)
  statusMsg = tostring(msg or "")
  guiDirty = true
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local function loadCfg()
  if not fs.exists(CFG_PATH) then return end
  local f = fs.open(CFG_PATH, "r")
  if not f then return end
  local raw = f.readAll() or ""
  f.close()
  local link = raw:match("lastLink%s*=%s*(.-)\n") or raw:match("lastLink%s*=%s*(.+)$")
  local last = raw:match("lastImage%s*=%s*(.-)\n") or raw:match("lastImage%s*=%s*(.+)$")
  if link then
    link = link:gsub("^%s+", ""):gsub("%s+$", "")
    if link ~= "" then linkBuf = link end
  end
  if last then
    last = last:gsub("^%s+", ""):gsub("%s+$", "")
    if last ~= "" then imgPath = last end
  end
end

local function saveCfg()
  local f = fs.open(CFG_PATH, "w")
  if not f then return end
  f.write("lastLink=" .. tostring(linkBuf or "") .. "\n")
  f.write("lastImage=" .. tostring(imgPath or "") .. "\n")
  f.close()
end

--------------------------------------------------------------------------------
-- Monitor binding
--------------------------------------------------------------------------------
local function isColorTerm(t)
  if not t or not t.isColor then return false end
  local ok, col = pcall(function() return t.isColor() end)
  return ok and col == true
end

local function bindMonitor(sideOrFind)
  local target, name = nil, nil
  if sideOrFind == nil or sideOrFind == "find" then
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.getType(n) == "monitor" then
        local p = peripheral.wrap(n)
        if isColorTerm(p) then
          target, name = p, n
          break
        end
      end
    end
  else
    local side = tostring(sideOrFind):lower()
    if peripheral.getType(side) ~= "monitor" then
      return nil, "No monitor on side '" .. side .. "'"
    end
    target = peripheral.wrap(side)
    name = side
    if not isColorTerm(target) then
      return nil, "Monitor on '" .. side .. "' is not a color (advanced) monitor"
    end
  end
  if not target then
    return nil, "No advanced (color) monitor attached"
  end
  pcall(function()
    if target.setTextScale then target.setTextScale(0.5) end
  end)
  mon, monName = target, name
  guiDirty = true
  return true
end

--------------------------------------------------------------------------------
-- Image list / load / fetch
--------------------------------------------------------------------------------
local function listImages()
  imageList = {}
  if not fs.exists("images") then
    pcall(fs.makeDir, "images")
    return
  end
  local function walk(dir, prefix)
    local ok, names = pcall(fs.list, dir)
    if not ok or type(names) ~= "table" then return end
    table.sort(names)
    for _, name in ipairs(names) do
      local path = fs.combine(dir, name)
      local rel = prefix ~= "" and (prefix .. "/" .. name) or name
      if fs.isDir(path) then
        walk(path, rel)
      elseif name:lower():match("%.png$") then
        imageList[#imageList + 1] = fs.combine("images", rel):gsub("\\", "/")
      end
    end
  end
  walk("images", "")
  if selected > #imageList then selected = math.max(1, #imageList) end
  if selected < 1 then selected = 1 end
end

local function ensureSelectedVisible(visRows)
  visRows = math.max(1, visRows or 1)
  if #imageList == 0 then
    listScroll = 0
    return
  end
  if selected < 1 then selected = 1 end
  if selected > #imageList then selected = #imageList end
  if selected <= listScroll then listScroll = math.max(0, selected - 1) end
  if selected > listScroll + visRows then listScroll = selected - visRows end
  local maxScroll = math.max(0, #imageList - visRows)
  if listScroll > maxScroll then listScroll = maxScroll end
  if listScroll < 0 then listScroll = 0 end
end

local function fitSize(srcW, srcH, dstW, dstH)
  if srcW < 1 or srcH < 1 or dstW < 1 or dstH < 1 then
    return 1, 1
  end
  local s = math.min(dstW / srcW, dstH / srcH)
  local w = math.max(1, math.floor(srcW * s + 0.5))
  local h = math.max(1, math.floor(srcH * s + 0.5))
  return w, h
end

local function sampleBlit(srcX, srcY)
  local x = math.min(img.width, math.max(1, math.floor(srcX + 0.5)))
  local y = math.min(img.height, math.max(1, math.floor(srcY + 0.5)))
  local r, g, b, a = pixelRGBA(img, x, y)
  return nearestBlit(r, g, b, a)
end

local function drawImageInRect(termObj, ox, oy, mw, mh)
  if not img or mw < 1 or mh < 1 then return end
  local fitW, fitH = fitSize(img.width, img.height, mw, mh)
  local dw = math.max(1, math.floor(fitW * scaleMul + 0.5))
  local dh = math.max(1, math.floor(fitH * scaleMul + 0.5))
  if dw > mw then dw = mw end
  if dh > mh then dh = mh end
  local x0 = ox + math.floor((mw - dw) / 2)
  local y0 = oy + math.floor((mh - dh) / 2)
  local xScale = img.width / dw
  local yScale = img.height / dh
  for row = 1, dh do
    local text = string.rep(" ", dw)
    local fg = string.rep("0", dw)
    local bgChars = {}
    local srcY = (row - 0.5) * yScale + 0.5
    for col = 1, dw do
      local srcX = (col - 0.5) * xScale + 0.5
      bgChars[col] = sampleBlit(srcX, srcY)
    end
    termObj.setCursorPos(x0, y0 + row - 1)
    termObj.blit(text, fg, table.concat(bgChars))
  end
end

local function isHttpUrl(path)
  local p = tostring(path or ""):lower()
  return p:sub(1, 7) == "http://" or p:sub(1, 8) == "https://"
end

local function probeLocalPng(path)
  if not pngImage.readBinary then return end
  local data, err = pngImage.readBinary(path)
  if not data then
    printError("Read failed: " .. tostring(err))
    return
  end
  print(("File size: %d bytes"):format(#data))
  print("First 8 bytes: " .. pngImage.hexBytes(data, 8))
  if data:sub(1, 8) ~= pngImage.MAGIC then
    printError(pngImage.describePrefix(data))
    printError("Copy the PNG as binary into world save computer/<id>/images/")
  end
end

local function loadPng(path, quiet)
  path = tostring(path or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if path == "" then return nil, "Usage: load <path.png|http-url>" end

  local viaHttp = isHttpUrl(path)
  if not viaHttp then
    if not fs.exists(path) then return nil, "File not found: " .. path end
    if fs.isDir(path) then return nil, "Not a file: " .. path end
  end

  if not quiet then print("Decoding " .. path .. " …") end
  local decode = pngImage.decodeFile or pngImage
  local ok, result = pcall(decode, path)
  if not ok then
    if not viaHttp then probeLocalPng(path) end
    return nil, "PNG decode failed: " .. tostring(result)
  end
  if type(result) ~= "table" or not result.width then
    return nil, "Invalid PNG decode result"
  end
  img = result
  imgPath = path
  scaleMul = 1.0
  for i = 1, #imageList do
    if imageList[i] == path then
      selected = i
      break
    end
  end
  saveCfg()
  setStatus(("Loaded %dx%d"):format(img.width, img.height))
  if not quiet then
    print(("Loaded %dx%d (%s)"):format(img.width, img.height, path))
  end
  return true
end

local function urlBasename(url)
  local name = url:match("([^/]+)$") or "download.png"
  name = name:match("^([^?#]+)") or name
  if not name:lower():match("%.png$") then
    name = name .. ".png"
  end
  name = name:gsub("[^%w%._%-]", "_")
  if name == "" or name == ".png" then name = "download.png" end
  return name
end

local function imagesDest(saveAs, fallbackUrl)
  if not fs.exists("images") then fs.makeDir("images") end
  local name = saveAs
  if name == nil or name == "" then
    name = urlBasename(fallbackUrl or "download.png")
  end
  name = tostring(name):gsub("\\", "/")
  if name:sub(1, 7) == "images/" then
    local dir = fs.getDir(name)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    return name
  end
  name = name:match("([^/]+)$") or name
  name = name:gsub("[^%w%._%-]", "_")
  if name == "" then name = "download.png" end
  if not name:lower():match("%.png$") then name = name .. ".png" end
  return fs.combine("images", name)
end

local function resolveGithubRef(spec, defaultBranch)
  defaultBranch = defaultBranch or "main"
  spec = tostring(spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if spec == "" then return nil, "empty github ref" end

  local lower = spec:lower()
  if lower:sub(1, 7) == "http://" or lower:sub(1, 8) == "https://" then
    if lower:find("raw.githubusercontent.com/", 1, true) then
      return spec:match("^([^?#]+)") or spec
    end
    local owner, repo, branch, path = spec:match(
      "^https?://github%.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$"
    )
    if owner then
      path = path:match("^([^?#]+)") or path
      return ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(owner, repo, branch, path)
    end
    owner, repo, branch, path = spec:match(
      "^https?://github%.com/([^/]+)/([^/]+)/raw/([^/]+)/(.+)$"
    )
    if owner then
      path = path:match("^([^?#]+)") or path
      return ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(owner, repo, branch, path)
    end
    owner, repo, branch, path = spec:match(
      "^https?://github%.com/([^/]+)/([^/]+)/tree/([^/]+)/(.+)$"
    )
    if owner then
      path = path:match("^([^?#]+)") or path
      return ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(owner, repo, branch, path)
    end
    return nil, "not a GitHub file URL (use blob/raw URL or owner/repo/path)"
  end

  local owner, repo, branch, rest = spec:match("^([^/@]+)/([^/@]+)@([^/]+)/(.+)$")
  if owner and rest then
    return ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(owner, repo, branch, rest)
  end

  local parts = {}
  for part in spec:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  if #parts < 3 then
    return nil, "Usage: github <owner/repo/path.png>  (need owner, repo, and file path)"
  end
  owner, repo = parts[1], parts[2]
  local path = table.concat(parts, "/", 3)
  return ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(owner, repo, defaultBranch, path)
end

local function fetchPng(url, saveAs, quiet)
  url = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if url == "" or not isHttpUrl(url) then
    return nil, "Usage: fetch <http-url> [filename]"
  end
  if not http then
    return nil, "http API not available (enable http in CC:Tweaked config)"
  end

  linkBuf = url
  saveCfg()
  setStatus("Fetching…")
  if not quiet then print("Fetching " .. url .. " …") end
  local data, err = pngImage.fetchHttp(url)
  if not data then return nil, err or "fetch failed" end

  if not quiet then print("First 8 bytes: " .. pngImage.hexBytes(data, 8)) end
  if data:sub(1, 8) ~= pngImage.MAGIC then
    return nil, "Download is not a PNG: " .. pngImage.describePrefix(data)
  end

  local dest = imagesDest(saveAs, url)
  local wok, werr = pngImage.writeBinary(dest, data)
  if not wok then return nil, werr or ("cannot write " .. dest) end
  if not quiet then print("Saved " .. dest .. " (" .. tostring(#data) .. " bytes)") end
  listImages()
  return loadPng(dest, quiet)
end

local function githubPng(spec, saveAs, quiet)
  spec = tostring(spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if spec == "" then
    return nil, "Usage: github <owner/repo/path.png|github-url> [filename]"
  end
  local url, err = resolveGithubRef(spec, "main")
  if not url then return nil, err end
  if not quiet then print("GitHub → " .. url) end
  linkBuf = url
  if saveAs == nil or saveAs == "" then
    saveAs = urlBasename(url)
  end
  return fetchPng(url, saveAs, quiet)
end

local function loadSelected()
  if #imageList == 0 then return nil, "No PNGs in images/" end
  local path = imageList[selected]
  if not path then return nil, "Nothing selected" end
  return loadPng(path, true)
end

local function fetchFromLinkBuf()
  local link = tostring(linkBuf or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if link == "" then
    return nil, "No link on computer — paste a URL first"
  end
  if isHttpUrl(link) then
    if link:lower():find("github.com/", 1, true) and not link:lower():find("raw.githubusercontent.com/", 1, true) then
      return githubPng(link, nil, true)
    end
    return fetchPng(link, nil, true)
  end
  -- Short owner/repo/path
  if link:find("/", 1, true) and not link:find(" ", 1, true) then
    return githubPng(link, nil, true)
  end
  return nil, "Link is not an http(s) URL or GitHub ref"
end

local function selectDelta(d)
  if #imageList == 0 then return end
  selected = selected + d
  if selected < 1 then selected = #imageList end
  if selected > #imageList then selected = 1 end
  guiDirty = true
end

local function stepImage(d)
  if #imageList == 0 then return nil, "No PNGs in images/" end
  selectDelta(d)
  return loadSelected()
end

--------------------------------------------------------------------------------
-- Monitor GUI helpers
--------------------------------------------------------------------------------
local function monFill(x, y, w, h, bg, fg)
  if not mon then return end
  mon.setBackgroundColor(bg or colors.black)
  mon.setTextColor(fg or colors.white)
  local blank = string.rep(" ", math.max(0, w))
  for row = y, y + h - 1 do
    mon.setCursorPos(x, row)
    mon.write(blank)
  end
end

local function monText(x, y, s, fg, bg)
  if not mon then return end
  mon.setBackgroundColor(bg or colors.black)
  mon.setTextColor(fg or colors.white)
  mon.setCursorPos(x, y)
  mon.write(tostring(s or ""))
end

local function inRect(mx, my, r)
  return r and mx >= r.x and mx <= r.x + r.w - 1
    and my >= r.y and my <= r.y + r.h - 1
end

local function addHit(id, x, y, w, h, meta)
  hitZones[#hitZones + 1] = { id = id, x = x, y = y, w = w, h = h, meta = meta }
end

local function drawButton(x, y, w, h, label, bg, fg)
  monFill(x, y, w, h, bg, fg)
  local t = tostring(label or "")
  local tx = x + math.max(0, math.floor((w - #t) / 2))
  local ty = y + math.floor((h - 1) / 2)
  monText(tx, ty, t:sub(1, w), fg or colors.white, bg)
end

local function drawMonitorGui()
  if not mon then return end
  hitZones = {}
  local mw, mh = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  -- Title bar
  monFill(1, 1, mw, 1, colors.blue, colors.white)
  monText(2, 1, "Image Loader", colors.white, colors.blue)
  local st = tostring(statusMsg or "")
  if #st > mw - 16 then st = st:sub(1, math.max(1, mw - 19)) .. "…" end
  monText(math.max(2, mw - #st), 1, st, colors.yellow, colors.blue)

  local btnH = (mh >= 12) and 2 or 1
  local footerY = mh - btnH + 1
  local navW = math.min(18, math.max(10, math.floor(mw * 0.32)))
  if mw < 28 then navW = math.min(12, math.max(8, math.floor(mw * 0.4))) end
  local viewX = navW + 2
  local viewW = math.max(1, mw - viewX + 1)
  local bodyTop = 2
  local bodyH = math.max(1, footerY - bodyTop)
  local listTop = bodyTop + 1
  local listRows = math.max(1, bodyH - 1)

  -- Nav panel
  monFill(1, bodyTop, navW, bodyH, colors.gray, colors.white)
  monText(2, bodyTop, "images/", colors.white, colors.gray)
  ensureSelectedVisible(listRows)
  if #imageList == 0 then
    monText(2, listTop, "(empty)", colors.lightGray, colors.gray)
  else
    for row = 1, listRows do
      local idx = listScroll + row
      local path = imageList[idx]
      if not path then break end
      local name = path:match("([^/]+)$") or path
      local y = listTop + row - 1
      local selectedRow = (idx == selected)
      local bg = selectedRow and colors.white or colors.gray
      local fg = selectedRow and colors.black or colors.white
      monFill(1, y, navW, 1, bg, fg)
      monText(2, y, name:sub(1, navW - 2), fg, bg)
      addHit("file", 1, y, navW, 1, idx)
    end
  end

  -- View panel
  monFill(viewX, bodyTop, viewW, bodyH, colors.black, colors.white)
  if img then
    drawImageInRect(mon, viewX, bodyTop, viewW, bodyH)
  else
    local msg = "no image"
    monText(viewX + math.max(0, math.floor((viewW - #msg) / 2)), bodyTop + math.floor(bodyH / 2), msg, colors.lightGray, colors.black)
  end

  -- Footer buttons
  local labels = { "Load", "Fetch", "Refresh", "Fit", "Prev", "Next" }
  local ids = { "load", "fetch", "refresh", "fit", "prev", "next" }
  local gap = 1
  local n = #labels
  local totalGap = gap * (n - 1)
  local bw = math.max(4, math.floor((mw - totalGap) / n))
  local used = bw * n + totalGap
  local startX = 1 + math.max(0, math.floor((mw - used) / 2))
  for i = 1, n do
    local x = startX + (i - 1) * (bw + gap)
    local w = bw
    if i == n then w = math.max(bw, mw - x + 1) end
    local bg = colors.cyan
    if ids[i] == "fetch" then bg = colors.orange
    elseif ids[i] == "load" then bg = colors.green
    elseif ids[i] == "fit" then bg = colors.purple
    end
    drawButton(x, footerY, w, btnH, labels[i], bg, colors.white)
    addHit(ids[i], x, footerY, w, btnH)
  end
end

local function handleMonitorAction(id, meta)
  if id == "file" and meta then
    selected = meta
    guiDirty = true
    return
  end
  if id == "load" then
    local ok, err = loadSelected()
    if not ok then setStatus(err or "load failed") else setStatus("Loaded") end
  elseif id == "fetch" then
    local ok, err = fetchFromLinkBuf()
    if not ok then setStatus(err or "fetch failed") else setStatus("Fetched") end
  elseif id == "refresh" then
    listImages()
    setStatus(("Refreshed (%d)"):format(#imageList))
  elseif id == "fit" then
    scaleMul = 1.0
    setStatus("Fit")
  elseif id == "prev" then
    local ok, err = stepImage(-1)
    if not ok then setStatus(err or "prev failed") end
  elseif id == "next" then
    local ok, err = stepImage(1)
    if not ok then setStatus(err or "next failed") end
  end
  guiDirty = true
end

local function hitTest(mx, my)
  for i = #hitZones, 1, -1 do
    local z = hitZones[i]
    if inRect(mx, my, z) then
      return z.id, z.meta
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Computer terminal UI
--------------------------------------------------------------------------------
local function drawComputerUi()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  local tw = select(1, term.getSize())
  if term.isColor and term.isColor() then
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.clearLine()
    write(" Titan Image Loader ")
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    print()
  else
    print("=== Titan Image Loader ===")
  end
  print("")
  local linkShow = linkBuf ~= "" and linkBuf or "(none — paste a URL)"
  if #linkShow > tw - 7 then linkShow = "…" .. linkShow:sub(-(tw - 10)) end
  print("Link: " .. linkShow)
  print("Status: " .. tostring(statusMsg))
  if mon then
    print("Monitor: " .. tostring(monName) .. " (tap GUI)")
  else
    print("Monitor: none — attach a color monitor for the GUI")
  end
  local n = #imageList
  local cur = imgPath and (imgPath:match("([^/]+)$") or imgPath) or "(none)"
  print(("Images: %d  |  Showing: %s"):format(n, cur))
  print("")
  print("Paste a GitHub/raw URL, then Fetch on the monitor.")
  print("Or: fetch / github / load / up / down / help / quit")
  print("")
end

local function printHelp()
  print([[Image Loader — split UI

Computer (this screen):
  <url>                   set download link for monitor Fetch
  fetch [url] [filename]  download → images/, load
  github <ref> [filename] GitHub → images/, load
  load <path|url>         load a PNG
  up / down               move list selection
  prev / next             load previous / next image
  fit / refresh           fit scale / rescan images/
  monitor find|<side>     bind color monitor
  help / quit

Monitor (color):
  Tap a file in the list, then Load
  Fetch uses the link shown on this computer
  Refresh / Fit / Prev / Next

Examples:
  github TitanBCXR/MinecraftLua/images/Map.png
  https://raw.githubusercontent.com/OWNER/REPO/main/a.png]])
end

local function handleComputerLine(line)
  line = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then return true end

  -- Bare URL / github-ish path → set link buffer
  if isHttpUrl(line) then
    linkBuf = line
    saveCfg()
    setStatus("Link set — tap Fetch on monitor")
    print("Link set. Tap Fetch on the monitor (or type fetch).")
    return true
  end

  local cmd, rest = line:match("^(%S+)%s*(.*)$")
  if not cmd then return true end
  cmd = cmd:lower()
  rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")

  if cmd == "help" or cmd == "?" then
    printHelp()
  elseif cmd == "quit" or cmd == "exit" or cmd == "q" then
    alive = false
    return false
  elseif cmd == "link" then
    if rest == "" then
      print("Current link: " .. (linkBuf ~= "" and linkBuf or "(none)"))
    else
      linkBuf = rest
      saveCfg()
      setStatus("Link set")
      print("Link set.")
    end
  elseif cmd == "load" or cmd == "path" then
    local ok, err = loadPng(rest)
    if not ok then printError(err) end
  elseif cmd == "github" or cmd == "gh" then
    local ref, as = rest:match("^(%S+)%s*(.*)$")
    as = (as or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local ok, err = githubPng(ref, as ~= "" and as or nil)
    if not ok then printError(err) end
  elseif cmd == "fetch" or cmd == "download" then
    if rest == "" then
      local ok, err = fetchFromLinkBuf()
      if not ok then printError(err) end
    else
      local url, as = rest:match("^(%S+)%s*(.*)$")
      as = (as or ""):gsub("^%s+", ""):gsub("%s+$", "")
      local ok, err = fetchPng(url, as ~= "" and as or nil)
      if not ok then printError(err) end
    end
  elseif cmd == "fit" then
    scaleMul = 1.0
    setStatus("Fit")
    print("Scale = fit")
  elseif cmd == "scale" then
    local n = tonumber(rest)
    if not n or n <= 0 then
      printError("Usage: scale <number>  (current " .. tostring(scaleMul) .. ")")
    else
      scaleMul = n
      setStatus("Scale " .. tostring(scaleMul))
      print("Scale = " .. tostring(scaleMul) .. "× fit")
    end
  elseif cmd == "refresh" or cmd == "ls" then
    listImages()
    setStatus(("Refreshed (%d)"):format(#imageList))
    print(#imageList .. " PNG(s) in images/")
  elseif cmd == "up" then
    selectDelta(-1)
    if imageList[selected] then print("Selected: " .. imageList[selected]) end
  elseif cmd == "down" then
    selectDelta(1)
    if imageList[selected] then print("Selected: " .. imageList[selected]) end
  elseif cmd == "prev" then
    local ok, err = stepImage(-1)
    if not ok then printError(err) end
  elseif cmd == "next" then
    local ok, err = stepImage(1)
    if not ok then printError(err) end
  elseif cmd == "monitor" then
    local arg = rest ~= "" and rest or "find"
    local ok, err = bindMonitor(arg)
    if not ok then printError(err) else print("Monitor: " .. tostring(monName)) end
  elseif cmd == "redraw" or cmd == "draw" then
    guiDirty = true
  else
    -- Treat owner/repo/path as a link to set (not auto-fetch)
    if line:find("/", 1, true) and not line:find(" ", 1, true) then
      local parts = 0
      for _ in line:gmatch("[^/]+") do parts = parts + 1 end
      if parts >= 3 then
        linkBuf = line
        saveCfg()
        setStatus("Link set — tap Fetch or type github")
        print("GitHub ref stored. Tap Fetch on monitor or: github " .. line)
        return true
      end
    end
    printError("Unknown command. Type help.")
  end
  guiDirty = true
  return true
end

--------------------------------------------------------------------------------
-- Parallel loops
--------------------------------------------------------------------------------
local function computerLoop()
  while alive do
    drawComputerUi()
    write("> ")
    local line = read()
    if line == nil then
      alive = false
      break
    end
    if not handleComputerLine(line) then break end
  end
end

local function monitorLoop()
  while alive do
    if not mon then
      -- Soft retry in case a monitor was attached after start
      bindMonitor("find")
      if not mon then
        local t = os.startTimer(2)
        while alive do
          local ev, p1 = os.pullEvent()
          if ev == "timer" and p1 == t then break end
          if ev == "peripheral" then
            bindMonitor("find")
            if mon then break end
          end
        end
      end
    else
      if guiDirty then
        drawMonitorGui()
        guiDirty = false
      end
      local ev, p1, p2, p3 = os.pullEvent()
      if not alive then break end
      if ev == "monitor_touch" then
        if monName == nil or p1 == monName then
          local id, meta = hitTest(p2, p3)
          if id then
            handleMonitorAction(id, meta)
            drawMonitorGui()
            guiDirty = false
          end
        end
      elseif ev == "monitor_resize" then
        guiDirty = true
      elseif ev == "peripheral_detach" and tostring(p1) == tostring(monName) then
        mon, monName = nil, nil
        setStatus("Monitor detached")
      elseif ev == "key" then
        -- Drive selection from computer keyboard when not consumed by read()
        local K = keys
        if p1 == K.up then
          selectDelta(-1)
          drawMonitorGui()
          guiDirty = false
        elseif p1 == K.down then
          selectDelta(1)
          drawMonitorGui()
          guiDirty = false
        elseif p1 == K.enter then
          handleMonitorAction("load")
          drawMonitorGui()
          guiDirty = false
        elseif p1 == K.left then
          handleMonitorAction("prev")
          drawMonitorGui()
          guiDirty = false
        elseif p1 == K.right then
          handleMonitorAction("next")
          drawMonitorGui()
          guiDirty = false
        elseif p1 == K.f then
          handleMonitorAction("fetch")
          drawMonitorGui()
          guiDirty = false
        elseif p1 == K.r then
          handleMonitorAction("refresh")
          drawMonitorGui()
          guiDirty = false
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------
if not term.isColor or not term.isColor() then
  print("Note: this computer is not advanced/color; a color monitor is still required for the GUI.")
end

loadCfg()

if not fs.exists("images") then
  pcall(fs.makeDir, "images")
end
listImages()

do
  local ok, err = bindMonitor("find")
  if not ok then
    printError(err or "No advanced (color) monitor attached.")
    printError("Computer-only mode: paste URLs / fetch / load. Attach a color monitor for the GUI.")
    setStatus("No color monitor")
  else
    print("Monitor: " .. tostring(monName))
  end
end

local argv = { ... }
if argv[1] and argv[1] ~= "" then
  local arg1 = argv[1]
  if isHttpUrl(arg1) then
    linkBuf = arg1
    saveCfg()
    local ok, err = loadPng(arg1)
    if not ok then
      setStatus("Link set (load failed)")
      printError(err)
    end
  else
    local ok, err = loadPng(arg1)
    if not ok then
      linkBuf = arg1
      saveCfg()
      printError(err)
    end
  end
elseif imgPath and fs.exists(imgPath) then
  local ok, err = loadPng(imgPath, true)
  if not ok then setStatus(err or "restore failed") end
end

guiDirty = true

if mon then
  parallel.waitForAny(computerLoop, monitorLoop)
else
  -- Still run both: monitor loop retries attach; computer stays usable
  parallel.waitForAny(computerLoop, monitorLoop)
end

if mon then
  pcall(function()
    mon.setBackgroundColor(colors.black)
    mon.clear()
  end)
end
print("Bye.")
