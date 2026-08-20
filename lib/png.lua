--[[
  lib/png.lua  -  Compact PNG decoder for CC: Tweaked
  Titan-Version: 1.0.0

  Decodes non-interlaced PNG (8-bit grey / RGB / indexed / grey+A / RGBA).
  Includes a small zlib/deflate inflater (MIT-style inflate port).

  Usage:
    local pngImage = dofile("lib/png.lua")
    local img = pngImage("images/logo.png")
    local r, g, b, a = img:get_pixel(1, 1):unpack()  -- 0..1 floats
]]

local band, bor, bxor, lshift, rshift = bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift

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
        local len = LEN_BASE[sym] + bs:bits(LEN_EXTRA[sym])
        local dsym = dist:decode(bs)
        local distance = DIST_BASE[dsym] + bs:bits(DIST_EXTRA[dsym])
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

local function unfilterRows(raw, width, height, bpp)
  local stride = width * bpp
  local out = {}
  local prev = {}
  for i = 1, stride do prev[i] = 0 end
  local pos = 1
  for row = 1, height do
    local ftype = raw:byte(pos); pos = pos + 1
    local cur = {}
    for i = 1, stride do
      cur[i] = raw:byte(pos); pos = pos + 1
    end
    if ftype == 0 then
      -- none
    elseif ftype == 1 then -- sub
      for i = 1, stride do
        local left = (i > bpp) and cur[i - bpp] or 0
        cur[i] = (cur[i] + left) % 256
      end
    elseif ftype == 2 then -- up
      for i = 1, stride do
        cur[i] = (cur[i] + prev[i]) % 256
      end
    elseif ftype == 3 then -- average
      for i = 1, stride do
        local left = (i > bpp) and cur[i - bpp] or 0
        cur[i] = (cur[i] + math.floor((left + prev[i]) / 2)) % 256
      end
    elseif ftype == 4 then -- paeth
      for i = 1, stride do
        local left = (i > bpp) and cur[i - bpp] or 0
        local up = prev[i]
        local upLeft = (i > bpp) and prev[i - bpp] or 0
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

local function decodePng(bytes)
  local r = Reader(bytes)
  if r:str(8) ~= "\137PNG\r\n\26\n" then
    error("Not a PNG file", 0)
  end

  local width, height, bitDepth, colorType
  local palette = {}
  local idat = {}

  while not r:eof() do
    local len = r:u32be()
    local ctype = r:str(4)
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
      if bitDepth ~= 8 then error("only 8-bit PNG supported (got " .. bitDepth .. ")", 0) end
    elseif ctype == "PLTE" then
      local n = math.floor(#data / 3)
      for i = 0, n - 1 do
        local o = i * 3 + 1
        palette[i] = {
          data:byte(o) / 255,
          data:byte(o + 1) / 255,
          data:byte(o + 2) / 255,
        }
      end
    elseif ctype == "IDAT" then
      idat[#idat + 1] = data
    elseif ctype == "IEND" then
      break
    end
  end

  if not width then error("missing IHDR", 0) end
  local inflated = inflateZlib(table.concat(idat))
  local spp = samplesPerPixel(colorType)
  local bpp = spp -- 8-bit only
  local expected = (width * bpp + 1) * height
  if #inflated < expected then
    error("truncated PNG image data", 0)
  end
  local raw = unfilterRows(inflated, width, height, bpp)

  local pixels = {} -- [y][x] = Pixel
  local idx = 1
  for y = 1, height do
    pixels[y] = {}
    for x = 1, width do
      local R, G, B, A = 0, 0, 0, 1
      if colorType == 0 then
        local g = raw[idx] / 255; idx = idx + 1
        R, G, B = g, g, g
      elseif colorType == 2 then
        R = raw[idx] / 255; G = raw[idx + 1] / 255; B = raw[idx + 2] / 255
        idx = idx + 3
      elseif colorType == 3 then
        local pi = raw[idx]; idx = idx + 1
        local c = palette[pi] or { 0, 0, 0 }
        R, G, B = c[1], c[2], c[3]
      elseif colorType == 4 then
        local g = raw[idx] / 255; A = raw[idx + 1] / 255; idx = idx + 2
        R, G, B = g, g, g
      elseif colorType == 6 then
        R = raw[idx] / 255; G = raw[idx + 1] / 255; B = raw[idx + 2] / 255
        A = raw[idx + 3] / 255; idx = idx + 4
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

local function pngImage(path, custom_stream)
  local data
  if custom_stream and custom_stream.input then
    data = custom_stream.input
  else
    if not path then error("pngImage: path required", 0) end
    local f = fs.open(path, "rb")
    if not f then error("cannot open " .. tostring(path), 0) end
    data = f.readAll()
    f.close()
  end
  return decodePng(data)
end

return pngImage
