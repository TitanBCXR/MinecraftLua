--[[
  console.lua  -  Basic terminal commands for a CC: Tweaked device

  A tiny, self-contained command console you can run on any computer or turtle.
  It gives you a handful of everyday commands (files, labels, GPS, fuel, movement)
  in one prompt, and falls through to the normal CraftOS shell for anything it
  doesn't know - so it's a friendly superset of the default terminal.

  Install it with the Titan installer (pick "Terminal console"), or drop this
  file on a device and run:  console.lua

  No dependencies. Type `help` once it's running. `exit` to quit.
]]

local VERSION  = "1.0"
local running  = true
local commands = {}                       -- name -> { help = str, fn = function(args) }
local history  = {}
local cwd      = (shell and shell.dir()) or ""

-- Give this device a friendly label if it doesn't have one yet.
os.setComputerLabel(os.getComputerLabel() or ("Console-" .. os.getComputerID()))

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function def(name, help, fn) commands[name] = { help = help, fn = fn } end
local function alias(a, b) commands[a] = commands[b] end

local function color(c) if term.setTextColor then term.setTextColor(c) end end

-- Resolve a user path against the current directory.
local function resolve(p)
  if not p or p == "" then return cwd end
  if p:sub(1, 1) == "/" then return fs.combine("", p) end
  return fs.combine(cwd, p)
end

-- Open every attached modem so gps/rednet work, plus the repeat channel for mesh.
local function openModems()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      pcall(peripheral.call, side, "open", rednet.CHANNEL_REPEAT)
    end
  end
end

-- Background mesh relay so a console device also hops rednet for neighbours.
local function relayLoop()
  local REPEAT, relayed = rednet.CHANNEL_REPEAT, {}
  while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
      local side, channel, replyChannel, message = p1, p2, p3, p4
      if channel == REPEAT and type(message) == "table"
         and message.nMessageID and message.nRecipient and not relayed[message.nMessageID] then
        relayed[message.nMessageID] = os.startTimer(30)
        for _, s in ipairs(peripheral.getNames()) do
          if peripheral.getType(s) == "modem" and rednet.isOpen(s) then
            peripheral.call(s, "transmit", REPEAT, replyChannel, message)
            if message.nRecipient ~= REPEAT then
              peripheral.call(s, "transmit", message.nRecipient, replyChannel, message)
            end
          end
        end
      end
    elseif event == "timer" then
      for mid, timer in pairs(relayed) do
        if timer == p1 then relayed[mid] = nil; break end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Commands: general
--------------------------------------------------------------------------------
def("help", "list commands (help <name> for detail)", function(a)
  if a[1] and commands[a[1]:lower()] then
    print(a[1]:lower() .. "  -  " .. commands[a[1]:lower()].help)
    return
  end
  local names = {}
  for n in pairs(commands) do names[#names + 1] = n end
  table.sort(names)
  color(colors.yellow); print("Console commands:"); color(colors.white)
  for _, n in ipairs(names) do
    print(("  %-10s %s"):format(n, commands[n].help))
  end
end)

def("clear", "clear the screen", function()
  term.clear(); term.setCursorPos(1, 1)
end)
alias("cls", "clear")

def("echo", "print text", function(a) print(table.concat(a, " ")) end)

def("ls", "list files [dir]", function(a)
  local dir = resolve(a[1])
  if not fs.isDir(dir) then printError("not a directory: " .. dir); return end
  local items = fs.list(dir); table.sort(items)
  for _, name in ipairs(items) do
    if fs.isDir(fs.combine(dir, name)) then
      color(colors.green); print(name .. "/")
    else
      color(colors.white); print(name)
    end
  end
  color(colors.white)
end)
alias("dir", "ls")

def("cat", "show a file's contents", function(a)
  local f = resolve(a[1])
  if not a[1] or not fs.exists(f) or fs.isDir(f) then printError("no such file"); return end
  local h = fs.open(f, "r"); print(h.readAll()); h.close()
end)

def("mkdir", "make a directory", function(a)
  if not a[1] then printError("usage: mkdir <dir>"); return end
  fs.makeDir(resolve(a[1]))
end)

def("rm", "delete a file or directory", function(a)
  if not a[1] then printError("usage: rm <path>"); return end
  local p = resolve(a[1])
  if not fs.exists(p) then printError("no such path"); return end
  fs.delete(p); print("removed " .. p)
end)

def("cd", "change directory", function(a)
  local d = resolve(a[1] or "")
  if not fs.isDir(d) then printError("not a directory"); return end
  cwd = d
  if shell then shell.setDir(d) end
end)

def("pwd", "print working directory", function() print("/" .. cwd) end)

def("run", "run a program: run <prog> [args]", function(a)
  if not shell then printError("no shell available"); return end
  local prog = table.remove(a, 1)
  if not prog then printError("usage: run <program> [args]"); return end
  shell.run(prog, table.unpack(a))
end)

--------------------------------------------------------------------------------
-- Commands: device info
--------------------------------------------------------------------------------
def("label", "get or set the computer label", function(a)
  if a[1] then
    local name = table.concat(a, " ")
    os.setComputerLabel(name); print("label set: " .. name)
  else
    print(os.getComputerLabel() or "(no label)")
  end
end)

def("id", "show this computer's id", function() print("computer id: " .. os.getComputerID()) end)

def("time", "show in-game time and day", function()
  print(("time %s   day %d"):format(textutils.formatTime(os.time(), false), os.day()))
end)

def("about", "console / OS version", function()
  print("Titan console v" .. VERSION)
  if os.version then print(os.version()) end
end)

def("pos", "locate via GPS", function()
  openModems()
  local x, y, z = gps.locate(2)
  if x then
    print(("gps: %d, %d, %d"):format(math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)))
  else
    printError("no GPS fix (need a wireless modem + GPS hosts in range)")
  end
end)

def("net", "find/register with the Titan router", function()
  openModems()
  rednet.broadcast({ type = "hello" }, "titan_router")
  local deadline, found = os.clock() + 2, false
  while os.clock() < deadline do
    local id, msg = rednet.receive("titan_router", deadline - os.clock())
    if id == nil then break end
    if type(msg) == "table" and msg.type == "here" then
      found = true
      print(("Connected via Router #%d '%s' (%d devices online)"):format(
        id, msg.label or "?", msg.devices or 0))
    end
  end
  if not found then
    printError("No router found. Run router.lua on a computer with a modem in range.")
  end
end)

-- Loaded once so the SSH host loop and client share the same reply inbox.
local titanLib = nil
if fs.exists("lib/titan.lua") then
  titanLib = dofile("lib/titan.lua")
end

def("ssh", "remote shell: ssh <id|label> [command...]", function(a)
  openModems()
  if not a[1] then
    print("Usage: ssh <computer id or label> [command]")
    print("  ssh 3              interactive session")
    print("  ssh Miner-12 ls    run one command remotely")
    print("Auth: Parent Center master password.")
    return
  end
  if not titanLib then
    printError("ssh needs lib/titan.lua (re-install via Titan installer, or copy lib/).")
    return
  end
  local target = table.remove(a, 1)
  local cmdline = #a > 0 and table.concat(a, " ") or nil
  titanLib.sshConnect(target, cmdline)
end)

def("reboot", "restart this device", function() os.reboot() end)
def("shutdown", "power off this device", function() os.shutdown() end)
def("exit", "leave the console", function() running = false end)
alias("quit", "exit")

--------------------------------------------------------------------------------
-- Commands: turtle-only (added only when running on a turtle)
--------------------------------------------------------------------------------
if turtle then
  def("fuel", "show fuel level", function()
    print("fuel: " .. tostring(turtle.getFuelLevel()))
  end)

  def("refuel", "consume fuel items from inventory", function()
    for s = 1, 16 do turtle.select(s); turtle.refuel() end
    turtle.select(1)
    print("fuel: " .. tostring(turtle.getFuelLevel()))
  end)

  local moves = {
    forward = turtle.forward, back = turtle.back, up = turtle.up, down = turtle.down,
    left = turtle.turnLeft, right = turtle.turnRight,
  }
  def("move", "move <forward|back|up|down|left|right> [n]", function(a)
    local fn = moves[(a[1] or ""):lower()]
    if not fn then printError("usage: move <forward|back|up|down|left|right> [n]"); return end
    local n = tonumber(a[2]) or 1
    for i = 1, n do
      if not fn() then printError("blocked after " .. (i - 1)); break end
    end
  end)
end

--------------------------------------------------------------------------------
-- REPL
--------------------------------------------------------------------------------
local function complete(line)
  if line == "" or line:find("%s") then return {} end
  local out = {}
  for name in pairs(commands) do
    if #name > #line and name:sub(1, #line) == line then out[#out + 1] = name:sub(#line + 1) end
  end
  table.sort(out)
  return out
end

local function dispatch(line)
  local t = {}
  for w in line:gmatch("%S+") do t[#t + 1] = w end
  local name = table.remove(t, 1)
  local c = commands[name:lower()]
  if c then
    local ok, err = pcall(c.fn, t)
    if not ok then printError("error: " .. tostring(err)) end
  elseif shell then
    if not shell.run(name, table.unpack(t)) then printError("unknown command: " .. name) end
  else
    printError("unknown command: " .. name)
  end
end

term.clear(); term.setCursorPos(1, 1)
color(colors.yellow)
print("== Titan console v" .. VERSION .. " ==")
color(colors.white)
print("Type 'help' for commands, 'exit' to quit.")
openModems()

local function promptLoop()
  while running do
    color(colors.cyan)
    write((os.getComputerLabel() or ("#" .. os.getComputerID())) .. ":/" .. cwd .. "> ")
    color(colors.white)
    local line = read(nil, history, complete)
    if line and line:match("%S") then
      history[#history + 1] = line
      dispatch(line)
    end
  end
end

-- Relay + SSH host while the console is open (mesh + inbound remote shell).
local tasks = { promptLoop, relayLoop }
if titanLib then
  tasks[#tasks + 1] = function() titanLib.sshHostLoop("console") end
end
parallel.waitForAny(table.unpack(tasks))

print("Console closed.")
