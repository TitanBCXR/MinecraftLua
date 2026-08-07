--[[
  router.lua  -  Titan network router bootstrap (CC: Tweaked)
  Titan-Version: 1.4.0

  Detects this computer's role from router.cfg (or asks once), ensures the
  matching runtime file is installed, then runs it:

    MAIN / ROUTER  →  router_main.lua   (directory, OTA, boards, backbone)
    MODEM          →  router_modem.lua  (local RF cell + mesh hop)

  Auto-install sources (first that works):
    1) already on disk
    2) .titan-install manifest (github / pastebin / host)
    3) GitHub raw (TitanBCXR/MinecraftLua)

  Run:  router
]]

local RCFG = "router.cfg"
local GH_BASE = "https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/"
local MANIFEST = ".titan-install"

local HUB_FILE = "router_main.lua"
local MODEM_FILE = "router_modem.lua"
local SHARED = { "lib/titan.lua", "versions.lua" }

--------------------------------------------------------------------------------
-- Tiny helpers (keep this file well under the 200-local limit)
--------------------------------------------------------------------------------
local function loadCfg()
  if not fs.exists(RCFG) then return {} end
  local f = fs.open(RCFG, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  return type(d) == "table" and d or {}
end

local function saveCfg(c)
  local f = fs.open(RCFG, "w")
  f.write(textutils.serialize(c))
  f.close()
end

local function httpGet(url)
  if not http then return nil, "http disabled" end
  local h, err = http.get(url)
  if not h then return nil, err or "request failed" end
  local code = h.getResponseCode and h.getResponseCode() or 200
  local data = h.readAll()
  h.close()
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
  if not data or data == "" then return nil, "empty" end
  return data
end

local function writeFile(path, data)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  if not f then return false, "write failed" end
  f.write(data)
  f.close()
  return true
end

local function readManifest()
  if not fs.exists(MANIFEST) then return nil end
  local f = fs.open(MANIFEST, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  return type(d) == "table" and d or nil
end

local function trackPackage(path)
  if not fs.exists("lib/titan.lua") then return end
  local ok, titan = pcall(dofile, "lib/titan.lua")
  if not ok or type(titan) ~= "table" then return end
  if titan.addPackage then
    pcall(titan.addPackage, path)
  elseif titan.readPackageList and titan.writePackageList then
    local list = titan.readPackageList() or {}
    local seen = false
    for _, p in ipairs(list) do if p == path then seen = true; break end end
    if not seen then
      list[#list + 1] = path
      pcall(titan.writePackageList, list)
    end
  end
end

local function fetchFromManifest(path)
  local m = readManifest()
  if not m then return nil, "no manifest" end
  if m.source == "github" and m.base then
    local base = m.base
    if not base:find("/$") then base = base .. "/" end
    return httpGet(base .. path .. "?cb=" .. os.epoch("utc"))
  elseif m.source == "pastebin" and m.codes and m.codes[path] then
    return httpGet("https://pastebin.com/raw/" .. m.codes[path] .. "?cb=" .. os.epoch("utc"))
  elseif m.source == "host" then
    -- Prefer titan OTA if available.
    if fs.exists("lib/titan.lua") then
      local ok, titan = pcall(dofile, "lib/titan.lua")
      if ok and titan and titan.updateSelf then
        -- Fall through to github below if host pull is awkward; try broadcast file get via update list.
      end
    end
    return nil, "host source — install via host or github"
  end
  return nil, "unknown manifest source"
end

local function ensureFile(path, required)
  if fs.exists(path) and not fs.isDir(path) then
    return true, "present"
  end
  print("[router] Missing " .. path .. " — downloading…")
  local data, err = fetchFromManifest(path)
  if not data then
    data, err = httpGet(GH_BASE .. path .. "?cb=" .. os.epoch("utc"))
  end
  if not data then
    if required then
      return false, err or "download failed"
    end
    print("[router] Optional skip: " .. path .. " (" .. tostring(err) .. ")")
    return false, err
  end
  local ok, werr = writeFile(path, data)
  if not ok then return false, werr end
  local ver = data:match("[Tt]itan%-[Vv]ersion:%s*([%d%.]+)")
  print("[router] Installed " .. path .. (ver and (" v" .. ver) or ""))
  trackPackage(path)
  return true, "downloaded"
end

local function detectRole()
  local c = loadCfg()
  local role = tostring(c.role or ""):lower()
  if role == "main" or role == "router" or role == "modem" then
    return role, false
  end
  print("")
  print("== Titan Router ==")
  print("Network role for this computer:")
  print("  M = MAIN hub (directory + OTA boards) — prefer ENDER modem")
  print("  R = ROUTER backbone satellite — ENDER modem")
  print("  N = MODEM local RF cell — normal wireless modem")
  write("[M/r/n] ")
  local ans = read():lower()
  if ans == "n" or ans == "no" or ans == "modem" then
    role = "modem"
  elseif ans == "r" or ans == "router" then
    role = "router"
  else
    role = "main"
  end
  c.role = role
  saveCfg(c)
  print("Role saved: " .. role)
  return role, true
end

--------------------------------------------------------------------------------
-- Open a modem early so host-based installs / mesh are possible later
--------------------------------------------------------------------------------
do
  local any = false
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      any = true
    end
  end
  if not any then
    error("No modem attached. Put a wireless or wired modem on this computer.", 0)
  end
end

os.setComputerLabel(os.getComputerLabel() or ("Router-" .. os.getComputerID()))

--------------------------------------------------------------------------------
-- Resolve role → ensure packages → hand off
--------------------------------------------------------------------------------
local role = select(1, detectRole())
local runtime = (role == "modem") and MODEM_FILE or HUB_FILE

-- Shared deps first (titan helps package tracking).
for _, path in ipairs(SHARED) do
  local ok, err = ensureFile(path, path == "lib/titan.lua")
  if not ok and path == "lib/titan.lua" then
    printError("[router] Need lib/titan.lua: " .. tostring(err))
    print("Install via github_install / host, then run router again.")
    return
  end
end

local ok, err = ensureFile(runtime, true)
if not ok then
  printError("[router] Could not install " .. runtime .. ": " .. tostring(err))
  print("Place " .. runtime .. " on this computer (installer / host / wget) and retry.")
  return
end

-- Keep the other runtime optional (handy if role changes later).
if runtime == HUB_FILE then
  ensureFile(MODEM_FILE, false)
else
  ensureFile(HUB_FILE, false)
end

print(("[router] Role %s → %s"):format(role:upper(), runtime))
local fn, lerr = loadfile(runtime)
if not fn then
  printError("[router] loadfile failed: " .. tostring(lerr))
  return
end
local okRun, runErr = pcall(fn)
if not okRun then
  printError("[router] " .. runtime .. " error: " .. tostring(runErr))
end
