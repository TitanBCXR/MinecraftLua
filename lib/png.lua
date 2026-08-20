--[[
  lib/png.lua  -  Compact PNG decoder for CC: Tweaked
  Titan-Version: 1.0.2

  Decodes non-interlaced PNG:
    - 8-bit grey / RGB / indexed / grey+A / RGBA
    - 1/2/4-bit grey + indexed (common texture exports)
    - 16-bit channels (high byte only)
    - tRNS transparency (palette / grey / RGB)

  Includes a small zlib/deflate inflater.

  Usage:
    local pngImage = dofile("lib/png.lua")
    local img = pngImage("images/logo.png")
    local r, g, b, a = img:get_pixel(1, 1):unpack()  -- 0..1 floats

  Paths starting with http:// or https:// are fetched with http binary mode.
]]

local band, bor, bxor, lshift, rshift = bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift

local PNG_MAGIC = "\137PNG\r\n\26\n"

--------------------------------------------------------------------------------
-- Binary I/O helpers (CC:Tweaked must use "rb" / http binary)
--------------------------------------------------------------------------------
local function hexBytes(data, n)
  n = math.min(n or 8, data and #data or 0)
  if n < 1 then return "(empty)" end
  local parts = {}
  for i = 1, n do
    parts[i] = ("%02X"):format(data:byte(i))
  end
  return table.concat(parts, " ")
end

local function describePrefix(data)
  if not data or #data == 0 then
    return "file is empty"
  end
  local b1, b2 = data:byte(1, 2)
  if b1 == 0xFF and b2 == 0xD8 then
    return "looks like JPEG (FF D8), not PNG — re-export as PNG"
  end
  local six = data:sub(1, 6)
  if six == "GIF87a" or six == "GIF89a" then
    return "looks like GIF, not PNG"
  end
  local head = data:sub(1, math.min(64, #data)):lower()
  if head:find("<!doctype", 1, true) or head:find("<html", 1, true) or head:find("<head", 1, true) then
    return "looks like HTML (download page / 404), not a PNG"
  end
  if b1 == 0xEF and b2 == 0xBB and data:byte(3) == 0xBF then
    return "UTF-8 BOM at start — file was likely saved/pasted as text"
  end
  if b1 == 0x89 and data:sub(2, 4) == "PNG" then
    -- 89 PNG present but CR/LF/SUB mangled (classic text-mode corruption)
    return "PNG-like start but signature bytes corrupted (often text-mode copy)"
  end
  return "expected 89 50 4E 47 0D 0A 1A 0A"
end

local function readBinaryFile(path)
  local f = fs.open(path, "rb")
  if not f then
    return nil, "cannot open " .. tostring(path) .. " (need binary mode \"rb\")"
  end
  local data = f.readAll and f.readAll() or nil
  if data == nil or data == "" then
    -- Byte-at-a-time fallback (binary handles return numbers from read())
    local chunks = {}
    while true do
      local b = f.read()
      if b == nil or b == "" then break end
      if type(b) == "number" then
        chunks[#chunks + 1] = string.char(b)
      else
        chunks[#chunks + 1] = b
      end
    end
    data = table.concat(chunks)
  end
  f.close()
  return data
end

local function writeBinaryFile(path, data)
  local f = fs.open(path, "wb")
  if not f then
    return nil, "cannot write " .. tostring(path)
  end
  -- Binary WriteHandle.write takes a byte number (not a string) on CC:Tweaked
  for i = 1, #data do
    f.write(data:byte(i))
  end
  f.close()
  return true
end

local function fetchHttpBinary(url)
  if not http or not http.get then
    return nil, "http API not available (enable http in CC:Tweaked config)"
  end
  -- Cache-buster (same pattern as github_install.lua)
  local fetchUrl = url
  if not fetchUrl:find("?", 1, true) then
    fetchUrl = fetchUrl .. "?cb=" .. tostring(os.epoch and os.epoch("utc") or os.time())
  end
  local h, err = http.get(fetchUrl, nil, true)
  if not h then
    -- Table-form request (some CC builds)
    local okCall, a, b = pcall(http.get, { url = fetchUrl, binary = true })
    if okCall then
      h, err = a, b
    else
      err = err or a
    end
  end
  if not h then
    return nil, "http get failed: " .. tostring(err or "unknown")
  end
  local code = h.getResponseCode and h.getResponseCode() or 200
  local data = h.readAll and h.readAll() or nil
  if (data == nil or data == "") and h.read then
    local chunks = {}
    while true do
      local b = h.read()
      if b == nil or b == "" then break end
      if type(b) == "number" then
        chunks[#chunks + 1] = string.char(b)
      else
        chunks[#chunks + 1] = b
      end
    end
    data = table.concat(chunks)
  end
  h.close()
  if code ~= 200 then
    local hint = (code == 404) and " (not found — check path/branch)" or ""
    return nil, "HTTP " .. tostring(code) .. hint
  end
  if not data or #data == 0 then
    return nil, "http response empty"
  end
  return data
end

--------------------------------------------------------------------------------
-- Byte reader
--------------------------------------------------------------------------------
local function Reader(data)
  local self = { data = data, pos = 1 }
  function self:tell() return self.pos end
  function self:seek(n) self.pos = self.pos + n end
  function self:eof() return self.pos > #self.data end
  function self:u8()
    local b = self.data:byte(self.pos)
    self.pos = self.pos + 1
    return b
  end
  function self:u16be()
    local a, b = self.data:byte(self.pos, self.pos + 1)
    self.pos = self.pos + 2
    return a * 256 + b
  end
  function self:u32be()
    local a, b, c, d = self.data:byte(self.pos, self.pos + 3)
    self.pos = self.pos + 4
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  function self:str(n)
    local s = self.data:sub(self.pos, self.pos + n - 1)
    self.pos = self.pos + n
    return s
  end
  return self
end

--------------------------------------------------------------------------------
-- Bitstream (LSB-first, for deflate)
--------------------------------------------------------------------------------
local function Bitstream(bytes)
  local self = { data = bytes, pos = 1, buf = 0, n = 0 }
  function self:bits(k)
    while self.n < k do
      if self.pos > #self.data then return nil end
      self.buf = self.buf + lshift(self.data:byte(self.pos), self.n)
      self.pos = self.pos + 1
      self.n = self.n + 8
    end
    local v = band(self.buf, rshift(0xFFFFFFFF, 32 - k))
    self.buf = rshift(self.buf, k)
    self.n = self.n - k
    return v
  end
  function self:align()
    local drop = self.n % 8
    if drop > 0 then self:bits(drop) end
  end
  return self
end

--------------------------------------------------------------------------------
-- Huffman
--------------------------------------------------------------------------------
local function maxIndex(lengths)
  local m = -1
  for k in pairs(lengths) do
    if type(k) == "number" and k > m then m = k end
  end
  return m
end

local function buildHuffman(lengths)
  local hi = maxIndex(lengths)
  local maxBits = 0
  for i = 0, hi do
    local L = lengths[i]
    if L and L > maxBits then maxBits = L end
  end
  if maxBits == 0 then error("empty huffman table", 0) end
  local blCount = {}
  for i = 0, maxBits do blCount[i] = 0 end
  for i = 0, hi do
    local L = lengths[i]
    if L and L > 0 then blCount[L] = blCount[L] + 1 end
  end
  local nextCode = {}
  local code = 0
  blCount[0] = 0
  for bits = 1, maxBits do
    code = (code + blCount[bits - 1]) * 2
    nextCode[bits] = code
  end
  local tbl = { maxBits = maxBits }
  for i = 0, hi do
    local L = lengths[i]
    if L and L > 0 then
      local c = nextCode[L]
      nextCode[L] = c + 1
      -- bit-reverse so LSB-first bitstream reads match canonical codes
      local rev, tmp = 0, c
      for _ = 1, L do
        rev = bor(lshift(rev, 1), band(tmp, 1))
        tmp = rshift(tmp, 1)
      end
      tbl[L * 0x10000 + rev] = i
    end
  end
  function tbl:decode(bs)
    local acc = 0
    for len = 1, self.maxBits do
      local b = bs:bits(1)
      if b == nil then return nil end
      acc = bor(acc, lshift(b, len - 1))
      local sym = self[len * 0x10000 + acc]
      if sym ~= nil then return sym end
    end
    error("invalid huffman code", 0)
  end
  return tbl
end

local FIXED_LIT, FIXED_DIST
local function fixedTables()
  if FIXED_LIT then return FIXED_LIT, FIXED_DIST end
  local lit = {}
  for i = 0, 143 do lit[i] = 8 end
  for i = 144, 255 do lit[i] = 9 end
  for i = 256, 279 do lit[i] = 7 end
  for i = 280, 287 do lit[i] = 8 end
  local dist = {}
  for i = 0, 31 do dist[i] = 5 end
  FIXED_LIT = buildHuffman(lit)
  FIXED_DIST = buildHuffman(dist)
  return FIXED_LIT, FIXED_DIST
end

local LEN_BASE = {
  [257]=3,[258]=4,[259]=5,[260]=6,[261]=7,[262]=8,[263]=9,[264]=10,
  [265]=11,[266]=13,[267]=15,[268]=17,[269]=19,[270]=23,[271]=27,[272]=31,
  [273]=35,[274]=43,[275]=51,[276]=59,[277]=67,[278]=83,[279]=99,[280]=115,
  [281]=131,[282]=163,[283]=195,[284]=227,[285]=258,
}
local LEN_EXTRA = {
  [257]=0,[258]=0,[259]=0,[260]=0,[261]=0,[262]=0,[263]=0,[264]=0,
  [265]=1,[266]=1,[267]=1,[268]=1,[269]=2,[270]=2,[271]=2,[272]=2,
  [273]=3,[274]=3,[275]=3,[276]=3,[277]=4,[278]=4,[279]=4,[280]=4,
  [281]=5,[282]=5,[283]=5,[284]=5,[285]=0,
}
local DIST_BASE = {
  [0]=1,[1]=2,[2]=3,[3]=4,[4]=5,[5]=7,[6]=9,[7]=13,[8]=17,[9]=25,
  [10]=33,[11]=49,[12]=65,[13]=97,[14]=129,[15]=193,[16]=257,[17]=385,
  [18]=513,[19]=769,[20]=1025,[21]=1537,[22]=2049,[23]=3073,[24]=4097,
  [25]=6145,[26]=8193,[27]=12289,[28]=16385,[29]=24577,
}
local DIST_EXTRA = {
  [0]=0,[1]=0,[2]=0,[3]=0,[4]=1,[5]=1,[6]=2,[7]=2,[8]=3,[9]=3,
  [10]=4,[11]=4,[12]=5,[13]=5,[14]=6,[15]=6,[16]=7,[17]=7,[18]=8,[19]=8,
  [20]=9,[21]=9,[22]=10,[23]=10,[24]=11,[25]=11,[26]=12,[27]=12,[28]=13,[29]=13,
}

local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function inflateBlock(bs, out)
  local bfinal = bs:bits(1)
  local btype = bs:bits(2)
  if btype == 0 then
    bs:align()
    local len = bs:bits(16)
    local nlen = bs:bits(16)
    if band(bxor(len, 0xFFFF), 0xFFFF) ~= nlen then
      error("bad uncompressed block length", 0)
    end
    for _ = 1, len do
      out[#out + 1] = bs:bits(8)
    end
  elseif btype == 1 or btype == 2 then
    local lit, dist
    if btype == 1 then
      lit, dist = fixedTables()
    else
      local hlit = bs:bits(5) + 257
      local hdist = bs:bits(5) + 1
      local hclen = bs:bits(4) + 4
      local clen = {}
      for i = 0, 18 do clen[i] = 0 end
      for i = 1, hclen do
        clen[CL_ORDER[i]] = bs:bits(3)
      end
      local clTree = buildHuffman(clen)
      local lengths = {}
      local n = 0
      local total = hlit + hdist
      while n < total do
        local sym = clTree:decode(bs)
        if sym < 16 then
          lengths[n] = sym
          n = n + 1
        elseif sym == 16 then
          local rep = bs:bits(2) + 3
          local prev = lengths[n - 1] or 0
          for _ = 1, rep do lengths[n] = prev; n = n + 1 end
        elseif sym == 17 then
          local rep = bs:bits(3) + 3
          for _ = 1, rep do lengths[n] = 0; n = n + 1 end
        else
          local rep = bs:bits(7) + 11
          for _ = 1, rep do lengths[n] = 0; n = n + 1 end
        end
      end
      local litLen, distLen = {}, {}
      for i = 0, hlit - 1 do litLen[i] = lengths[i] or 0 end
      for i = 0, hdist - 1 do distLen[i] = lengths[hlit + i] or 0 end
      lit = buildHuffman(litLen)
      dist = buildHuffman(distLen)
    end
    while true do
      local sym = lit:decode(bs)
      if sym < 256 then
        out[#out + 1] = sym
      elseif sym == 256 then
        break
      else
        local len = LEN_BASE[sym] + (bs:bits(LEN_EXTRA[sym]) or 0)
        local dsym = dist:decode(bs)
        local distance = DIST_BASE[dsym] + (bs:bits(DIST_EXTRA[dsym]) or 0)
        local start = #out - distance + 1
        for i = 1, len do
          out[#out + 1] = out[start + i - 1]
        end
      end
    end
  else
    error("unsupported deflate block type", 0)
  end
  return bfinal == 1
end

local function inflateZlib(raw)
  local bs = Bitstream(raw)
  local cmf = bs:bits(8)
  local flg = bs:bits(8)
  if band(cmf, 0x0F) ~= 8 then error("unsupported zlib compression method", 0) end
  if band(flg, 0x20) ~= 0 then
    bs:bits(32) -- preset dict (skip Adler)
  end
  local out = {}
  repeat
    local done = inflateBlock(bs, out)
  until done
  -- skip Adler-32
  bs:align()
  bs:bits(32)
  local chars = {}
  for i = 1, #out do chars[i] = string.char(out[i]) end
  return table.concat(chars)
end

--------------------------------------------------------------------------------
-- PNG filter reconstruct
--------------------------------------------------------------------------------
local function paeth(a, b, c)
  local p = a + b - c
  local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
  if pa <= pb and pa <= pc then return a end
  if pb <= pc then return b end
  return c
end

local function unfilterRowsEx(raw, height, stride, filterBpp)
  local out = {}
  local prev = {}
  for i = 1, stride do prev[i] = 0 end
  local pos = 1
  for row = 1, height do
    if pos > #raw then error("truncated PNG scanline data", 0) end
    local ftype = raw:byte(pos); pos = pos + 1
    local cur = {}
    for i = 1, stride do
      if pos > #raw then error("truncated PNG scanline data", 0) end
      cur[i] = raw:byte(pos); pos = pos + 1
    end
    if ftype == 0 then
      -- none
    elseif ftype == 1 then -- sub
      for i = 1, stride do
        local left = (i > filterBpp) and cur[i - filterBpp] or 0
        cur[i] = (cur[i] + left) % 256
      end
    elseif ftype == 2 then -- up
      for i = 1, stride do
        cur[i] = (cur[i] + prev[i]) % 256
      end
    elseif ftype == 3 then -- average
      for i = 1, stride do
        local left = (i > filterBpp) and cur[i - filterBpp] or 0
        cur[i] = (cur[i] + math.floor((left + prev[i]) / 2)) % 256
      end
    elseif ftype == 4 then -- paeth
      for i = 1, stride do
        local left = (i > filterBpp) and cur[i - filterBpp] or 0
        local up = prev[i]
        local upLeft = (i > filterBpp) and prev[i - filterBpp] or 0
        cur[i] = (cur[i] + paeth(left, up, upLeft)) % 256
      end
    else
      error("unsupported PNG filter " .. tostring(ftype), 0)
    end
    for i = 1, stride do
      out[#out + 1] = cur[i]
      prev[i] = cur[i]
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- Pixel object
--------------------------------------------------------------------------------
local Pixel = {}
Pixel.__index = Pixel
function Pixel.new(r, g, b, a)
  return setmetatable({ r = r, g = g, b = b, a = a or 1 }, Pixel)
end
function Pixel:unpack()
  return self.r, self.g, self.b, self.a
end

--------------------------------------------------------------------------------
-- Decode PNG file / path
--------------------------------------------------------------------------------
local function samplesPerPixel(colorType)
  if colorType == 0 then return 1 end
  if colorType == 2 then return 3 end
  if colorType == 3 then return 1 end
  if colorType == 4 then return 2 end
  if colorType == 6 then return 4 end
  error("unsupported PNG color type " .. tostring(colorType), 0)
end

local function channelScale(bitDepth)
  if bitDepth == 16 then return 65535 end
  if bitDepth == 8 then return 255 end
  if bitDepth == 4 then return 15 end
  if bitDepth == 2 then return 3 end
  if bitDepth == 1 then return 1 end
  return (2 ^ bitDepth) - 1
end

-- Unpack one scanline of packed samples into a flat array of sample values (0..max)
local function unpackSamples(rowBytes, width, bitDepth, spp)
  local samples = {}
  local max = channelScale(bitDepth)
  if bitDepth == 8 then
    for i = 1, #rowBytes do samples[i] = rowBytes[i] end
    return samples, max
  end
  if bitDepth == 16 then
    -- Keep high byte only (effective 8-bit)
    local n = 1
    for i = 1, #rowBytes, 2 do
      samples[n] = rowBytes[i] or 0
      n = n + 1
    end
    return samples, 255
  end
  -- 1 / 2 / 4-bit, MSB first within each byte
  local mask = max
  local total = width * spp
  local bitPos = 0
  local byteIndex = 1
  local current = rowBytes[1] or 0
  for i = 1, total do
    if bitPos >= 8 then
      bitPos = 0
      byteIndex = byteIndex + 1
      current = rowBytes[byteIndex] or 0
    end
    local shift = 8 - bitPos - bitDepth
    samples[i] = band(rshift(current, shift), mask)
    bitPos = bitPos + bitDepth
  end
  return samples, max
end

local function decodePng(bytes)
  if type(bytes) ~= "string" then
    error("PNG data must be a string (got " .. type(bytes) .. ")", 0)
  end
  local r = Reader(bytes)
  local sig = r:str(8)
  if sig ~= PNG_MAGIC then
    error(
      ("Not a PNG file (got %s — %s)"):format(hexBytes(bytes, 8), describePrefix(bytes)),
      0
    )
  end

  local width, height, bitDepth, colorType
  local palette = {} -- [i] = {r,g,b,a} floats
  local idat = {}
  local trns = nil

  while not r:eof() do
    if r.pos + 8 > #r.data then break end
    local len = r:u32be()
    local ctype = r:str(4)
    if r.pos + len + 4 - 1 > #r.data then
      error("truncated PNG chunk " .. ctype, 0)
    end
    local data = r:str(len)
    r:str(4) -- crc
    if ctype == "IHDR" then
      local hr = Reader(data)
      width = hr:u32be()
      height = hr:u32be()
      bitDepth = hr:u8()
      colorType = hr:u8()
      local comp, filter, inter = hr:u8(), hr:u8(), hr:u8()
      if comp ~= 0 or filter ~= 0 then error("unsupported PNG compression/filter method", 0) end
      if inter ~= 0 then error("interlaced PNG not supported", 0) end
      if bitDepth ~= 1 and bitDepth ~= 2 and bitDepth ~= 4 and bitDepth ~= 8 and bitDepth ~= 16 then
        error("unsupported PNG bit depth " .. tostring(bitDepth), 0)
      end
      -- Restrict: 16-bit only for grey/RGB/greyA/RGBA; indexed max 8
      if colorType == 3 and bitDepth == 16 then
        error("indexed PNG cannot be 16-bit", 0)
      end
      if (colorType == 2 or colorType == 4 or colorType == 6) and bitDepth < 8 then
        error("RGB/alpha PNG must be 8 or 16-bit", 0)
      end
    elseif ctype == "PLTE" then
      local n = math.floor(#data / 3)
      for i = 0, n - 1 do
        local o = i * 3 + 1
        palette[i] = {
          data:byte(o) / 255,
          data:byte(o + 1) / 255,
          data:byte(o + 2) / 255,
          1,
        }
      end
    elseif ctype == "tRNS" then
      trns = data
    elseif ctype == "IDAT" then
      idat[#idat + 1] = data
    elseif ctype == "IEND" then
      break
    end
  end

  if not width then error("missing IHDR", 0) end
  if #idat == 0 then error("missing IDAT", 0) end

  -- Apply tRNS to palette / store key colour
  local transGrey, transRGB
  if trns then
    if colorType == 3 then
      for i = 0, #trns - 1 do
        if palette[i] then
          palette[i][4] = trns:byte(i + 1) / 255
        end
      end
    elseif colorType == 0 and #trns >= 2 then
      transGrey = trns:byte(1) * 256 + trns:byte(2)
      -- We decode 16-bit as high-byte-only (0..255); match that. 8-bit uses low byte.
      if bitDepth == 16 then
        transGrey = rshift(transGrey, 8)
      elseif bitDepth == 8 then
        transGrey = band(transGrey, 0xFF)
      else
        transGrey = band(transGrey, channelScale(bitDepth))
      end
    elseif colorType == 2 and #trns >= 6 then
      local function u16(o) return trns:byte(o) * 256 + trns:byte(o + 1) end
      transRGB = { u16(1), u16(3), u16(5) }
      if bitDepth == 16 then
        transRGB = { rshift(transRGB[1], 8), rshift(transRGB[2], 8), rshift(transRGB[3], 8) }
      elseif bitDepth == 8 then
        transRGB = { band(transRGB[1], 0xFF), band(transRGB[2], 0xFF), band(transRGB[3], 0xFF) }
      end
    end
  end

  local inflated = inflateZlib(table.concat(idat))
  local spp = samplesPerPixel(colorType)
  local bitsPerPixel = bitDepth * spp
  local filterBpp = math.max(1, math.floor((bitsPerPixel + 7) / 8))
  local stride = math.floor((bitsPerPixel * width + 7) / 8)
  local expected = (stride + 1) * height
  if #inflated < expected then
    error("truncated PNG image data", 0)
  end
  local rawBytes = unfilterRowsEx(inflated, height, stride, filterBpp)

  local pixels = {} -- [y][x] = Pixel
  local rowOffset = 0
  for y = 1, height do
    pixels[y] = {}
    local row = {}
    for i = 1, stride do
      row[i] = rawBytes[rowOffset + i]
    end
    rowOffset = rowOffset + stride
    local samples, maxV = unpackSamples(row, width, bitDepth, spp)
    local si = 1
    for x = 1, width do
      local R, G, B, A = 0, 0, 0, 1
      if colorType == 0 then
        local g = samples[si]; si = si + 1
        local gf = g / maxV
        R, G, B = gf, gf, gf
        if transGrey ~= nil and g == transGrey then A = 0 end
      elseif colorType == 2 then
        local rv, gv, bv = samples[si], samples[si + 1], samples[si + 2]
        si = si + 3
        R, G, B = rv / maxV, gv / maxV, bv / maxV
        if transRGB and rv == transRGB[1] and gv == transRGB[2] and bv == transRGB[3] then
          A = 0
        end
      elseif colorType == 3 then
        local pi = samples[si]; si = si + 1
        local c = palette[pi] or { 0, 0, 0, 1 }
        R, G, B, A = c[1], c[2], c[3], c[4]
      elseif colorType == 4 then
        local g = samples[si]; local av = samples[si + 1]; si = si + 2
        local gf = g / maxV
        R, G, B, A = gf, gf, gf, av / maxV
      elseif colorType == 6 then
        local rv, gv, bv, av = samples[si], samples[si + 1], samples[si + 2], samples[si + 3]
        si = si + 4
        R, G, B, A = rv / maxV, gv / maxV, bv / maxV, av / maxV
      end
      pixels[y][x] = Pixel.new(R, G, B, A)
    end
  end

  local img = {
    width = width,
    height = height,
    depth = bitDepth,
    colorType = colorType,
    _pixels = pixels,
  }
  function img:get_pixel(x, y)
    local row = self._pixels[y]
    return row and row[x] or nil
  end
  return img
end

local function isHttpUrl(path)
  if type(path) ~= "string" then return false end
  local p = path:lower()
  return p:sub(1, 7) == "http://" or p:sub(1, 8) == "https://"
end

local function pngImage(path, custom_stream)
  local data
  if custom_stream and custom_stream.input then
    data = custom_stream.input
  elseif isHttpUrl(path) then
    local err
    data, err = fetchHttpBinary(path)
    if not data then error(err or "http fetch failed", 0) end
  else
    if not path then error("pngImage: path required", 0) end
    local err
    data, err = readBinaryFile(path)
    if not data then error(err or ("cannot open " .. tostring(path)), 0) end
  end
  return decodePng(data)
end

-- Expose helpers for the loader CLI
pngImage.decode = decodePng
pngImage.readBinary = readBinaryFile
pngImage.writeBinary = writeBinaryFile
pngImage.fetchHttp = fetchHttpBinary
pngImage.hexBytes = hexBytes
pngImage.describePrefix = describePrefix
pngImage.MAGIC = PNG_MAGIC

return pngImage
