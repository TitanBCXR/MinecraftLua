--[[
  image_loader.lua  -  Load a PNG onto an advanced (color) monitor
  Titan-Version: 1.0.2

  Needs an advanced computer + attached color monitor. Monitors are a 16-color
  character/blit grid (not a true framebuffer); pixels are quantized to the
  nearest CC palette colour.

  Usage:
      image_loader
      image_loader <path.png|http-url>

  Put PNGs under images/ on the computer (or pass any path / http URL). Commands:
      load <path|url> / path <path|url>
      github <url-or-path> [filename]   download from GitHub → images/, then load
      fetch <url> [filename]            download any http(s) PNG → images/, then load
      scale <n>     (1 = fit size; e.g. 0.5 / 1.5)
      fit           (reset to fit-to-monitor, letterboxed)
      monitor <side|find>
      redraw
      help
      quit

  GitHub examples:
      github TitanBCXR/MinecraftLua/images/Map.png
      github https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/images/Map.png
      fetch https://raw.githubusercontent.com/OWNER/REPO/main/path/file.png map.png
]]

local pngImage
do
  if not fs.exists("lib/png.lua") then
    error("Missing lib/png.lua — reinstall Tools → Image Loader", 0)
  end
  pngImage = dofile("lib/png.lua")
end

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
  if a ~= nil and a < 0.5 then return "f" end -- treat transparent as black letterbox
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

local function pixelRGBA(img, x, y)
  local px = img:get_pixel(x, y)
  if not px then return 0, 0, 0, 0 end
  local r = px.r or px.R or 0
  local g = px.g or px.G or 0
  local b = px.b or px.B or 0
  local a = px.a or px.A
  if a == nil then a = 1 end
  -- pngLua stores 0..1 floats
  if r > 1 or g > 1 or b > 1 then
    r, g, b = r / 255, g / 255, b / 255
  end
  if a > 1 then a = a / 255 end
  return r, g, b, a
end

--------------------------------------------------------------------------------
-- Monitor binding
--------------------------------------------------------------------------------
local mon = nil
local monName = nil

local function isColorTerm(t)
  if not t or not t.isColor then return false end
  local ok, col = pcall(function() return t.isColor() end)
  return ok and col == true
end

local function bindMonitor(sideOrFind)
  local target = nil
  local name = nil
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
  return true
end

--------------------------------------------------------------------------------
-- Image state + draw
--------------------------------------------------------------------------------
local img = nil
local imgPath = nil
local scaleMul = 1.0 -- relative to fit size

local function fitSize(srcW, srcH, dstW, dstH)
  if srcW < 1 or srcH < 1 or dstW < 1 or dstH < 1 then
    return 1, 1
  end
  local sx = dstW / srcW
  local sy = dstH / srcH
  local s = math.min(sx, sy)
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

local function redraw()
  if not mon then
    printError("No color monitor bound. Use: monitor find")
    return false
  end
  if not img then
    printError("No image loaded. Use: load images/foo.png")
    return false
  end

  local mw, mh = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  local fitW, fitH = fitSize(img.width, img.height, mw, mh)
  local dw = math.max(1, math.floor(fitW * scaleMul + 0.5))
  local dh = math.max(1, math.floor(fitH * scaleMul + 0.5))
  if dw > mw then dw = mw end
  if dh > mh then dh = mh end

  local ox = math.floor((mw - dw) / 2)
  local oy = math.floor((mh - dh) / 2)

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
    mon.setCursorPos(ox + 1, oy + row)
    mon.blit(text, fg, table.concat(bgChars))
  end
  return true
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
    printError("Do not paste through chat/edit. Or: github <owner/repo/path>")
  end
end

local function loadPng(path)
  path = tostring(path or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if path == "" then return nil, "Usage: load <path.png|http-url>" end

  local viaHttp = isHttpUrl(path)
  if not viaHttp then
    if not fs.exists(path) then return nil, "File not found: " .. path end
    if fs.isDir(path) then return nil, "Not a file: " .. path end
  end

  print("Decoding " .. path .. " …")
  local ok, result = pcall(pngImage, path)
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
  print(("Loaded %dx%d (%s)"):format(img.width, img.height, path))
  return true
end

local function urlBasename(url)
  local name = url:match("([^/]+)$") or "download.png"
  name = name:match("^([^?#]+)") or name
  if not name:lower():match("%.png$") then
    name = name .. ".png"
  end
  -- sanitize for CC paths
  name = name:gsub("[^%w%._%-]", "_")
  if name == "" or name == ".png" then name = "download.png" end
  return name
end

-- Always land under images/ (create dir). Bare filenames become images/<name>.
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

-- Resolve GitHub blob / short owner/repo/path forms to raw.githubusercontent.com
-- Default branch: main
local function resolveGithubRef(spec, defaultBranch)
  defaultBranch = defaultBranch or "main"
  spec = tostring(spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if spec == "" then return nil, "empty github ref" end

  local lower = spec:lower()
  if lower:sub(1, 7) == "http://" or lower:sub(1, 8) == "https://" then
    -- Already raw
    if lower:find("raw.githubusercontent.com/", 1, true) then
      return spec:match("^([^?#]+)") or spec
    end
    -- github.com/owner/repo/blob/branch/path
    local owner, repo, branch, path = spec:match(
      "^https?://github%.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$"
    )
    if owner then
      path = path:match("^([^?#]+)") or path
      return ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(owner, repo, branch, path)
    end
    -- github.com/owner/repo/raw/branch/path
    owner, repo, branch, path = spec:match(
      "^https?://github%.com/([^/]+)/([^/]+)/raw/([^/]+)/(.+)$"
    )
    if owner then
      path = path:match("^([^?#]+)") or path
      return ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(owner, repo, branch, path)
    end
    -- github.com/owner/repo/tree/branch/path (treat as file path)
    owner, repo, branch, path = spec:match(
      "^https?://github%.com/([^/]+)/([^/]+)/tree/([^/]+)/(.+)$"
    )
    if owner then
      path = path:match("^([^?#]+)") or path
      return ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(owner, repo, branch, path)
    end
    return nil, "not a GitHub file URL (use blob/raw URL or owner/repo/path)"
  end

  -- Optional: owner/repo@branch/path
  local owner, repo, branch, rest = spec:match("^([^/@]+)/([^/@]+)@([^/]+)/(.+)$")
  if owner and rest then
    return ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(owner, repo, branch, rest)
  end

  -- Short: owner/repo/path/to/file.png  (branch defaults to main)
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

local function fetchPng(url, saveAs)
  url = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if url == "" or not isHttpUrl(url) then
    return nil, "Usage: fetch <http-url> [filename]"
  end
  if not http then
    return nil, "http API not available (enable http in CC:Tweaked config)"
  end

  print("Fetching " .. url .. " …")
  local data, err = pngImage.fetchHttp(url)
  if not data then return nil, err or "fetch failed" end

  print("First 8 bytes: " .. pngImage.hexBytes(data, 8))
  if data:sub(1, 8) ~= pngImage.MAGIC then
    return nil, "Download is not a PNG: " .. pngImage.describePrefix(data)
  end

  local dest = imagesDest(saveAs, url)
  local wok, werr = pngImage.writeBinary(dest, data)
  if not wok then return nil, werr or ("cannot write " .. dest) end
  print("Saved " .. dest .. " (" .. tostring(#data) .. " bytes)")
  return loadPng(dest)
end

local function githubPng(spec, saveAs)
  spec = tostring(spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if spec == "" then
    return nil, "Usage: github <owner/repo/path.png|github-url> [filename]"
  end
  local url, err = resolveGithubRef(spec, "main")
  if not url then return nil, err end
  print("GitHub → " .. url)
  if saveAs == nil or saveAs == "" then
    saveAs = urlBasename(url)
  end
  return fetchPng(url, saveAs)
end

--------------------------------------------------------------------------------
-- CLI
--------------------------------------------------------------------------------
local function printHelp()
  print([[Image Loader — PNG → advanced monitor

  load <path|url>           load a .png from disk or http(s)
  path <path|url>           same as load
  github <ref> [filename]   download from GitHub → images/, then load
  fetch <url> [filename]    download PNG (binary) → images/, then load
  scale <n>                 size vs fit (1=fit, 0.5 half, 1.5 larger)
  fit                       reset scale to fit monitor (letterbox)
  monitor find              bind first color monitor
  monitor <side>            bind monitor on that side
  redraw                    draw again
  help
  quit

Examples:
  github TitanBCXR/MinecraftLua/images/Map.png
  github https://github.com/TitanBCXR/MinecraftLua/blob/main/images/Map.png
  fetch https://raw.githubusercontent.com/OWNER/REPO/main/a.png map.png

Copy PNGs as binary into world save computer/<id>/images/
(not via chat paste), or use github / fetch above.]])
end

local function handle(line)
  local cmd, rest = line:match("^(%S+)%s*(.*)$")
  if not cmd then return true end
  cmd = cmd:lower()
  rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")

  if cmd == "help" or cmd == "?" then
    printHelp()
  elseif cmd == "quit" or cmd == "exit" or cmd == "q" then
    return false
  elseif cmd == "load" or cmd == "path" then
    local ok, err = loadPng(rest)
    if not ok then printError(err) else redraw() end
  elseif cmd == "github" or cmd == "gh" then
    local ref, as = rest:match("^(%S+)%s*(.*)$")
    as = (as or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local ok, err = githubPng(ref, as ~= "" and as or nil)
    if not ok then printError(err) else redraw() end
  elseif cmd == "fetch" or cmd == "download" then
    local url, as = rest:match("^(%S+)%s*(.*)$")
    as = (as or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local ok, err = fetchPng(url, as ~= "" and as or nil)
    if not ok then printError(err) else redraw() end
  elseif cmd == "fit" then
    scaleMul = 1.0
    print("Scale = fit")
    redraw()
  elseif cmd == "scale" then
    local n = tonumber(rest)
    if not n or n <= 0 then
      printError("Usage: scale <number>  (current " .. tostring(scaleMul) .. ")")
    else
      scaleMul = n
      print("Scale = " .. tostring(scaleMul) .. "× fit")
      redraw()
    end
  elseif cmd == "monitor" then
    local arg = rest ~= "" and rest or "find"
    local ok, err = bindMonitor(arg)
    if not ok then printError(err) else
      print("Monitor: " .. tostring(monName))
      redraw()
    end
  elseif cmd == "redraw" or cmd == "draw" then
    redraw()
  else
    printError("Unknown command. Type help.")
  end
  return true
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------
if not term.isColor or not term.isColor() then
  -- Advanced computer preferred; still allow if a color monitor exists.
  print("Note: this computer is not advanced/color; a color monitor is still required.")
end

do
  local ok, err = bindMonitor("find")
  if not ok then
    printError(err or "No advanced (color) monitor attached.")
    printError("Attach a color monitor and run again, or use: monitor <side>")
    -- keep running so user can attach + `monitor find`
  else
    print("Monitor: " .. tostring(monName))
  end
end

if not fs.exists("images") then
  pcall(fs.makeDir, "images")
end

local argv = { ... }
if argv[1] and argv[1] ~= "" then
  local ok, err = loadPng(argv[1])
  if not ok then printError(err) else redraw() end
else
  print("Image Loader ready. Type help — PNGs go in images/")
end

while true do
  write("> ")
  local line = read()
  if line == nil then break end
  if not handle(line) then break end
end

print("Bye.")
