--[[
  lib/router_hub_cmd.lua  -  Titan hub console / boot (part)
  Titan-Version: 1.4.3

  Loaded by router_main.lua into a shared env (setfenv). Do not run directly.
]]

function handleRouterCommand(a)
  local cmd = (a[1] or ""):lower()

  if cmd == "" then
    return true
  elseif cmd == "help" then
      print("role     - show main / router / modem role")
      print("main     - make THIS the MAIN hub (directory + OTA)")
      print("router   - ender backbone satellite (long-haul peer)")
      print("modem    - local RF cell repeater (short range)")
      print("link                 show backbone peers + modem cells")
      print("link peer <id>       peer this node to another ROUTER/MAIN")
      print("link home <id>       MODEM: set home MAIN/ROUTER")
      print("link modem <id>      MAIN/ROUTER: attach a modem cell")
      print("link unpeer|uncell|unhome <id>")
      print("hostname [name|auto] - set name (modems: auto = accept main assign)")
      print("stats    - relay counts (+ roster if main)")
      print("gpshost [x y z] - show / set this router's GPS host coords")
      print("reset [routes|names|all|hard] - wipe routing data (confirm)")
      if isMain() then
        print("  routes = roster; names = name assigns; all = both")
        print("screens  - monitor status (single screen)")
        print("screen <role> on|off|perm   one board at a time")
        print(("  on = show %ds then saver;  perm = stay on"):format(saverIdleSecs))
        print("view <roster|global|stats|gps|map>")
        print("  roster/local = this hub's modems+computers")
        print("  global       = backbone peers + remote mesh")
        print("idle [seconds]  temp-board timeout (default 120)")
        print("monrate [secs]  live board refresh rate (default 1)")
        print("map on|off|perm|view")
        print("versions - local vs GitHub package versions")
        print("devices  - list remembered systems (ONLINE / OFFLINE)")
        print("forget <id|host> - remove a system from the remembered roster")
        print("names    - modem name pool + assignments")
        print("name <id|host> <newname>  - force-assign a modem name (reboots it)")
        print("namepool add|remove <name>  - edit the unique-name list")
        print("ping     - re-discover the network")
        print("update [modems]|status - OTA online MODEMS only (+ SSH fallback)")
        print("update all|fleet       - OTA EVERY online device (+ SSH fallback)")
        print("forceupdate [-y]       - same as update modems")
        print("reauth   - tell the fleet to re-auth now (no download)")
        print("github [url] - show / set GitHub raw base for versions")
      else
        print("  routes = keep MAIN/home; hard/all = also forget MAIN + name")
      end
      print("ssh <id|label> [cmd] - remote shell (full device commands)")
      print("say <id|label> <msg> - print on that device's screen")
      print("exit")
  elseif cmd == "role" then
      print(("Role: %s  (id #%d)"):format(routerRole, os.getComputerID()))
      if isMain() then
        print("MAIN hub — OTA/directory. Use ender modem; peer routers with `link peer`.")
      elseif routerRole == "router" then
        print("ROUTER backbone — ender long-haul. Host local modems with `link modem`.")
      else
        print("MODEM cell — short-range RF. Set hub with `link home <routerId>`.")
      end
      printNetLinks()
    elseif cmd == "main" then
      if isMain() then
        claimMain()
        print("Already MAIN. Re-broadcast claim so devices refresh.")
      else
        write("Promote this node to MAIN hub? (other mains should run `modem`/`router`) [y/N] ")
        if read():lower() ~= "y" then print("Cancelled.") else
          patchRouterCfg({ role = "main" })
          print("Saved role=main. Rebooting..."); sleep(1); os.reboot()
        end
      end
    elseif cmd == "router" then
      if routerRole == "router" then
        print("Already a ROUTER backbone node.")
        printNetLinks()
      else
        write("Set role=ROUTER (ender backbone satellite, not MAIN)? [y/N] ")
        if read():lower() ~= "y" then print("Cancelled.") else
          if isMain() and fs.exists(ROSTER) then pcall(fs.delete, ROSTER) end
          patchRouterCfg({ role = "router" })
          print("Saved role=router. Use ender modem + `link peer <mainId>`. Rebooting...")
          sleep(1); os.reboot()
        end
      end
    elseif cmd == "modem" then
      if isModemRole() then
        print("Already a MODEM cell repeater.")
        printNetLinks()
      else
        write("Demote to MODEM (local RF cell)? [y/N] ")
        if read():lower() ~= "y" then print("Cancelled.") else
          patchRouterCfg({ role = "modem" })
          if fs.exists(ROSTER) then pcall(fs.delete, ROSTER) end
          print("Saved role=modem. Link home with `link home <routerId>`. Rebooting...")
          sleep(1); os.reboot()
        end
      end
    elseif cmd == "link" or cmd == "netlink" or cmd == "topology" then
      local sub = (a[2] or ""):lower()
      if sub == "" or sub == "status" or sub == "show" then
        printNetLinks()
        broadcastNetHello(true)
      elseif sub == "peer" or sub == "router" then
        local id = tonumber(a[3])
        if not id then
          print("Usage: link peer <routerId>")
          print("Peers this MAIN/ROUTER to another ender backbone node.")
        else
          local ok, err = addNetPeer(id, a[4])
          if not ok then print(tostring(err)) else
            rednet.send(id, {
              type = "net_link", action = "peer",
              with = os.getComputerID(),
              withName = os.getComputerLabel(),
              name = os.getComputerLabel(),
              role = routerRole,
            }, PROTO_ROUTER)
            broadcastNetHello(true)
            print(("Linked backbone peer #%d"):format(id))
          end
        end
      elseif sub == "home" then
        local id = tonumber(a[3])
        if not id then
          print("Usage: link home <mainOrRouterId>   (modem cells only)")
        elseif not isModemRole() then
          print("link home is for MODEM role. Use `modem` first, or `link modem` on the hub.")
        else
          local ok, err = setHomeRouter(id, a[4])
          if not ok then print(tostring(err)) else
            rednet.send(id, {
              type = "net_link", action = "cell",
              with = os.getComputerID(),
              withName = os.getComputerLabel(),
              name = os.getComputerLabel(),
            }, PROTO_ROUTER)
            broadcastNetHello(true)
            print(("Home router set to #%d"):format(id))
          end
        end
      elseif sub == "modem" or sub == "cell" then
        local id = tonumber(a[3])
        if not id then
          print("Usage: link modem <modemId>   (on MAIN/ROUTER)")
        elseif not isBackbone() then
          print("Only MAIN/ROUTER host modem cells.")
        else
          local ok, err = addNetCell(id, a[4])
          if not ok then print(tostring(err)) else
            rednet.send(id, {
              type = "net_link", action = "home",
              with = os.getComputerID(),
              withName = os.getComputerLabel(),
            }, PROTO_ROUTER)
            broadcastNetHello(true)
            print(("Attached modem cell #%d"):format(id))
          end
        end
      elseif sub == "unpeer" or sub == "unlink" then
        local ok, err = removeNetPeer(tonumber(a[3]))
        print(ok and "Removed peer." or tostring(err))
      elseif sub == "uncell" then
        local ok, err = removeNetCell(tonumber(a[3]))
        print(ok and "Removed cell." or tostring(err))
      elseif sub == "unhome" then
        homeRouterId = nil; saveNetLinks()
        print("Cleared home router.")
      elseif sub == "hello" or sub == "announce" then
        broadcastNetHello(true)
        print("Announced links on mesh.")
      else
        print("Usage: link | link peer <id> | link home <id> | link modem <id>")
      end
    elseif cmd == "devices" or cmd == "list" then
      if not isMain() then print("Roster is MAIN-only. Use `main` to promote."); else
        local on, off, unk = countOnlineOffline()
        print(("Remembered — ONLINE:%d  OFFLINE:%d  UNKNOWN:%d"):format(on, off, unk))
        local n = 0
        for _, id in ipairs(sortedIds()) do
          local d = seen[id]
          n = n + 1
          local st = statusOf(d, id)
          local age = (d.seen and d.seen > 0) and (ago(d.seen) .. "s ago") or "never"
          print(("#%-3d %-8s %-8s %-18s %s"):format(
            id, st, d.kind or "?", d.hostname or d.name or "?", age))
        end
        if n == 0 then print("(none yet — wait for devices to register)") end
      end
    elseif cmd == "forget" then
      if not isMain() then print("Roster is MAIN-only."); else
        local ref = a[2]
        if not ref then print("Usage: forget <id|hostname>"); else
          local id = tonumber(ref)
          if not id then
            local want = ref:lower()
            for sid, d in pairs(seen) do
              local host = tostring(d.hostname or d.name or ""):lower()
              if host == want or host:find(want, 1, true) then id = sid; break end
            end
          end
          if id and seen[id] then
            print(("Forgot %s (#%d)."):format(seen[id].hostname or "?", id))
            seen[id] = nil
            releaseModemName(id)
            rosterDirty = true
            saveRoster()
          else
            print("Unknown system: " .. tostring(ref))
          end
        end
      end
    elseif cmd == "reset" then
      local mode = (a[2] or "routes"):lower()
      if mode == "route" then mode = "routes" end
      local label
      if isMain() then
        if mode == "names" then
          label = "Clear modem NAME assignments on MAIN?"
        elseif mode == "all" or mode == "hard" then
          label = "Clear MAIN roster AND modem name assignments?"
          mode = "all"
        else
          label = "Clear MAIN roster / routing data? (keeps modem names)"
          mode = "routes"
        end
      else
        if mode == "all" or mode == "hard" then
          label = "Clear modem routing AND forget MAIN id + assigned name?"
          mode = "hard"
        else
          label = "Clear modem routing data? (keeps route to MAIN)"
          mode = "routes"
        end
      end
      write(label .. " [y/N] ")
      if read():lower() ~= "y" then
        print("Cancelled.")
      else
        local ok, msg = resetRouting(mode)
        if ok then
          print(msg)
          if isMain() then
            claimMain()
            print("Re-broadcast MAIN claim. Devices will re-register on next hello.")
          else
            print("Rebooting modem to reload slim cfg...")
            sleep(1)
            os.reboot()
          end
        else
          print(tostring(msg))
        end
      end
    elseif cmd == "map" or cmd == "fmap" or cmd == "fleetmap" then
      if not isMain() then print("map is MAIN-only.")
      else
        local sub = (a[2] or ""):lower()
        if sub == "" or sub == "status" then
          local mode = not screenOn.map and "saver"
            or (screenPerm.map and "PERM" or ("temp %ds"):format(saverIdleSecs))
          print(("Map board: %s"):format(mode))
          print("  map on|off|perm  — temp / off / permanent")
          print("  map view         — interactive map on this terminal")
        elseif sub == "true" or sub == "on" or sub == "1" or sub == "yes" then
          wakeBoard("map", false)
          print(("Map ON for %ds, then screensaver."):format(saverIdleSecs))
          drawBoards()
        elseif sub == "perm" or sub == "permanent" or sub == "always" then
          wakeBoard("map", true)
          print("Map ON permanently.")
          drawBoards()
        elseif sub == "false" or sub == "off" or sub == "0" or sub == "no" then
          setScreenOn("map", false)
          print("Map OFF (screensaver).")
        elseif sub == "view" or sub == "term" or sub == "live" then
          fleetMapView()
        elseif sub == "toggle" then
          if screenOn.map then setScreenOn("map", false) else wakeBoard("map", false) end
          print(("Map board: %s"):format(screenOn.map and "ON" or "OFF"))
          drawBoards()
        else
          print("Usage: map on|off|perm|view|toggle")
        end
      end
    elseif cmd == "view" or cmd == "display" then
      if not isMain() then print("view is MAIN-only.")
      else
        local role = normalizeScreenRole(a[2] or "")
        if role == "" then
          local left = boardWakeAt and math.max(0, math.floor(boardWakeAt + saverIdleSecs - os.clock())) or 0
          local live = enabledRoles()
          print(("Active: %s  focus=%s  temp-timeout=%ds (left %ds)"):format(
            #live > 0 and table.concat(live, ",") or "(saver)",
            screenFocus, saverIdleSecs, left))
          print("Usage: view <roster|local|global|stats|gps|map>")
          print("  roster/local — this hub's cell   global — whole mesh")
        elseif not isScreenRole(role) then
          print("Usage: view <roster|local|global|stats|gps|map>")
        else
          wakeBoard(role, false)
          local label = (role == "roster") and "local" or role
          print(("%s ON for %ds, then screensaver."):format(label, saverIdleSecs))
          drawBoards()
        end
      end
    elseif cmd == "idle" or cmd == "saver" then
      if not isMain() then print("idle is MAIN-only.")
      else
        local sec = tonumber(a[2])
        if not a[2] or a[2]:lower() == "status" then
          print(("Temp boards return to screensaver after %ds."):format(saverIdleSecs))
          print("Usage: idle <seconds>   (min 5)")
        elseif not sec or sec < 5 then
          print("Usage: idle <seconds>   (min 5)")
        else
          saverIdleSecs = math.floor(sec)
          saveScreenAssignments()
          print(("Temp-board timeout set to %ds."):format(saverIdleSecs))
        end
      end
    elseif cmd == "monrate" or cmd == "mrate" or cmd == "monitorrate" or cmd == "refreshrate" then
      if not isMain() then print("monrate is MAIN-only.")
      else
        if a[2] then
          monRate = clampMonRate(a[2])
          saveScreenAssignments()
        end
        print(("Monitor refresh: %.2fs  (live boards; screensaver stays smooth)"):format(monRate))
      end
    elseif cmd == "names" then
      if not isMain() then print("Name registry is MAIN-only."); else
        loadNameRegistry()
        print("Modem name assignments:")
        local any = false
        local ids = {}
        for id in pairs(nameAssign) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
        for _, id in ipairs(ids) do
          any = true
          print(("  #%d -> %s"):format(id, nameAssign[id]))
        end
        if not any then print("  (none yet)") end
        print("Name pool:")
        print("  " .. table.concat(namePool(), ", "))
      end
    elseif cmd == "name" then
      if not isMain() then print("Name assign is MAIN-only."); else
        local ref, newName = a[2], a[3] and table.concat(a, " ", 3) or nil
        if not ref or not newName then
          print("Usage: name <id|hostname> <newname>")
        else
          local id = tonumber(ref)
          if not id then
            local want = ref:lower()
            for sid, d in pairs(seen) do
              local host = tostring(d.hostname or d.name or ""):lower()
              if host == want or host:find(want, 1, true) then id = sid; break end
            end
            for sid, n in pairs(nameAssign) do
              if tostring(n):lower() == want then id = sid; break end
            end
          end
          if not id then
            print("Unknown modem: " .. tostring(ref))
          elseif nameTaken(newName, id) then
            print("Name already in use: " .. newName)
          else
            loadNameRegistry()
            nameAssign[id] = newName
            saveNameRegistry()
            if seen[id] then
              seen[id].hostname = newName
              seen[id].name = newName
              rosterDirty = true
            end
            rednet.send(id, {
              type = "here", assignHostname = newName, reboot = true,
              main = true, mainRouterId = os.getComputerID(),
              label = os.getComputerLabel(), hostname = os.getComputerLabel(),
            }, PROTO_ROUTER)
            print(("Assigned #%d -> %s (reboot sent)"):format(id, newName))
          end
        end
      end
    elseif cmd == "namepool" then
      if not isMain() then print("Name pool is MAIN-only."); else
        local sub = (a[2] or ""):lower()
        local pool = {}
        for _, n in ipairs(namePool()) do pool[#pool + 1] = n end
        if sub == "add" and a[3] then
          local n = table.concat(a, " ", 3)
          local exists = false
          for _, p in ipairs(pool) do if p:lower() == n:lower() then exists = true; break end end
          if exists then print("Already in pool: " .. n)
          else
            pool[#pool + 1] = n
            saveNameRegistry(pool)
            print("Added to pool: " .. n)
          end
        elseif sub == "remove" and a[3] then
          local n = table.concat(a, " ", 3):lower()
          local out = {}
          for _, p in ipairs(pool) do
            if p:lower() ~= n then out[#out + 1] = p end
          end
          saveNameRegistry(out)
          print("Removed from pool (if present): " .. table.concat(a, " ", 3))
        else
          print("Usage: namepool add <name> | namepool remove <name>")
          print("Pool: " .. table.concat(pool, ", "))
        end
      end
    elseif cmd == "hostname" or cmd == "host" then
      if not a[2] then
        print("hostname: " .. (os.getComputerLabel() or "(none)"))
        local c = loadRouterCfg() or {}
        if not isMain() then
          if c.manualHostname then
            print("Naming: manual")
          elseif c.assignedName then
            print("Naming: assigned by main (" .. c.assignedName .. ")")
          else
            print("Naming: waiting for main router unique-name assign")
          end
        end
      else
        local name = table.concat(a, " ", 2)
        if name:lower() == "auto" and not isMain() then
          patchRouterCfg({ manualHostname = false, assignedName = nil })
          print("Will accept next name from main router (announce + reboot).")
          rednet.broadcast({
            type = "hello", kind = "modem",
            name = "Modem-pending-" .. os.getComputerID(),
            hostname = "Modem-pending-" .. os.getComputerID(),
            autoName = true, needName = true,
          }, PROTO_ROUTER)
        else
          os.setComputerLabel(name)
          if not isMain() then
            patchRouterCfg({ manualHostname = true, assignedName = name })
          end
          if titanLib then
            local ok, err = titanLib.setHostname(name, isMain() and "router" or "modem")
            if ok then print("hostname set: " .. ok) else print(tostring(err)) end
          else
            rednet.broadcast({
              type = "hello", kind = isMain() and "router" or "modem",
              name = name, hostname = name, autoName = false,
            }, PROTO_ROUTER)
            print("hostname set: " .. name)
          end
          if isMain() then claimMain() end
          if not isMain() then print("(manual — use `hostname auto` to resume main assign)") end
        end
      end
    elseif cmd == "ping" then
      if not isMain() then print("Ping/discover is MAIN-only."); else
        rednet.broadcast({ type = "ping" }, "titan_net")
        rednet.broadcast({ type = "ping" }, "titan_dc")
        rednet.broadcast({ type = "ping" }, PROTO_ROUTER)
        print("Pinged.")
      end
    elseif cmd == "stats" then
      if isMain() then
        local on, off = countOnlineOffline()
        print(("[%s] Relayed %d. ONLINE:%d WIRED:%d OFFLINE:%d. rf:%d wire:%d"):format(
          routerRole:upper(), relayStats.relayed, on, countWiredOnline(), off,
          #wirelessModems, #wiredModems))
      else
        print(("[MODEM] Relayed %d messages. rf:%d wire:%d"):format(
          relayStats.relayed, #wirelessModems, #wiredModems))
      end
    elseif cmd == "screens" or cmd == "monitors" then
      if not isMain() then print("Screens are MAIN-only."); else
        refreshScreens()
        local names = listMonitorNames()
        local mode = anyLiveBoard() and ("board:" .. screenFocus) or "screensaver"
        print(("Monitor: %s   mode=%s"):format(displayMonName or "(none)", mode))
        if #names > 1 then
          print(("(%d monitors attached — using primary %s)"):format(#names, displayMonName or "?"))
        end
        print(("Boards (single screen, temp timeout %ds):"):format(saverIdleSecs))
        for _, role in ipairs(SCREEN_ROLES) do
          local modeR = not screenOn[role] and "off"
            or (screenPerm[role] and "PERM" or "temp")
          local mark = (screenOn[role] and role == screenFocus) and " <<<" or ""
          print(("  %-6s %-4s%s"):format(role, modeR, mark))
        end
        if boardWakeAt then
          local left = math.max(0, math.floor(boardWakeAt + saverIdleSecs - os.clock()))
          print(("Returns to screensaver in %ds."):format(left))
        end
      end
    elseif cmd == "screen" then
      if not isMain() then print("Screens are MAIN-only."); else
        local role = (a[2] or ""):lower()
        local target = (a[3] or ""):lower()
        local flag = (a[4] or ""):lower()
        if not isScreenRole(role) then
          print("Usage: screen <roster|local|global|stats|gps|map> <on|off|perm>")
          print(("  on   = show %ds then screensaver"):format(saverIdleSecs))
          print("  perm = stay on permanently")
          print("  roster/local = this hub   global = whole mesh")
          print("Example: screen local on   |   screen global perm")
        elseif target == "" then
          print(("Usage: screen %s <on|off|perm>"):format(role))
        elseif target == "on" or target == "true" or target == "1" or target == "yes" then
          local permanent = (flag == "perm" or flag == "permanent" or flag == "always")
          wakeBoard(role, permanent)
          local label = (normalizeScreenRole(role) == "roster") and "local" or normalizeScreenRole(role)
          if permanent then
            print(label .. " on permanently (single screen).")
          else
            print(("%s on for %ds, then screensaver."):format(label, saverIdleSecs))
          end
          drawBoards()
        elseif target == "perm" or target == "permanent" or target == "always" then
          wakeBoard(role, true)
          local label = (normalizeScreenRole(role) == "roster") and "local" or normalizeScreenRole(role)
          print(label .. " on permanently (single screen).")
          drawBoards()
        elseif target == "off" or target == "false" or target == "0" or target == "no" then
          setScreenOn(role, false)
          print(normalizeScreenRole(role) .. " off — screensaver.")
          -- Drop back to saver immediately (drawLoop will animate next tick).
          refreshScreens()
          if displayMon then clearMon(displayMon) end
        else
          print("Usage: screen <roster|local|global|stats|gps|map> <on|off|perm>")
        end
      end
    elseif cmd == "gpshost" then
      if a[2] and a[3] and a[4] then
        patchRouterCfg({ gps = { x = tonumber(a[2]), y = tonumber(a[3]), z = tonumber(a[4]) } })
        print("Saved GPS coords. Rebooting to start hosting..."); sleep(1); os.reboot()
      elseif gpsCoords then
        print(("Hosting GPS at %d, %d, %d."):format(gpsCoords.x, gpsCoords.y, gpsCoords.z))
      else
        print("Not hosting GPS. Usage: gpshost <x> <y> <z>")
      end
    elseif cmd == "versions" or cmd == "ver" then
      if not isMain() then print("versions is MAIN-only."); else
        print("Checking GitHub...")
        local remote, err = fetchGithubVersions()
        local localVer = localSystemVersion()
        print(("Local system:  %s"):format(tostring(localVer or "?")))
        if not remote then
          print("GitHub:        (failed) " .. tostring(err))
          print("Base: " .. githubBase())
        else
          print(("GitHub system: %s"):format(tostring(remote.system or "?")))
          print("Base: " .. ghState.base)
          local cmp = versionCmp(localVer, remote.system)
          if cmp < 0 then print("Status: GitHub is NEWER — run `update` (modems) or `update all`")
          elseif cmp > 0 then print("Status: local is ahead of GitHub")
          else print("Status: up to date with GitHub") end
          if type(remote.packages) == "table" then
            local localCat = nil
            if fs.exists("versions.lua") then
              local ok, c = pcall(dofile, "versions.lua")
              if ok then localCat = c end
            end
            local diffs = 0
            for path, ver in pairs(remote.packages) do
              local lv = localCat and localCat.packages and localCat.packages[path]
              if tostring(lv or "") ~= tostring(ver) then
                if diffs == 0 then print("Package diffs (local -> github):") end
                diffs = diffs + 1
                print(("  %-22s %s -> %s"):format(path, tostring(lv or "—"), tostring(ver)))
              end
            end
            if diffs == 0 then print("All listed packages match GitHub.") end
          end
        end
        -- Fleet versions from roster
        print("Fleet (online):")
        local any = false
        for _, id in ipairs(sortedIds()) do
          local d = seen[id]
          if isOnline(d) then
            any = true
            print(("  #%-3d %-16s v%s"):format(
              id, tostring(d.hostname or "?"):sub(1, 16), tostring(d.version or "?")))
          end
        end
        if not any then print("  (none online yet)") end
      end
    elseif cmd == "github" then
      if not isMain() then print("github is MAIN-only."); else
        if a[2] then
          local url = table.concat(a, " ", 2)
          if not url:find("/$") then url = url .. "/" end
          patchRouterCfg({ githubBase = url })
          print("GitHub base saved: " .. url)
        else
          print("GitHub base: " .. githubBase())
          print("Usage: github <raw-base-url/>")
        end
      end
    elseif cmd == "update" or cmd == "forceupdate" or cmd == "upgrade" then
      if not isMain() then
        print("OTA update is MAIN-only. Run `main` on this machine, or use the main router.")
      else
        local yes, scope, statusOnly = false, nil, false
        for i = 2, #a do
          local s = (a[i] or ""):lower()
          if s == "-y" or s == "--yes" or s == "yes" then
            yes = true
          elseif s == "status" or s == "stat" then
            statusOnly = true
          elseif s == "all" or s == "fleet" or s == "aoe" or s == "everyone" then
            scope = "all"
          elseif s == "modems" or s == "modem" or s == "extenders" then
            scope = "modems"
          elseif s == "help" or s == "?" then
            print("Usage:")
            print("  update              force-update online MODEMS only (default)")
            print("  update modems [-y]  same — mesh extenders only, SSH if no ACK")
            print("  update all [-y]     every online Titan device (broadcast + SSH)")
            print("  update status       ACK progress / package version diffs")
            print("  forceupdate [-y]    alias for update modems")
            return true
          end
        end
        -- `forceupdate` with no scope → modems; bare `update` → modems
        if not scope then
          scope = "modems"
        end
        if statusOnly then
          local exp, done, camp = campaignStatus()
          if not camp then
            print("No active update campaign. Run `update` (modems) or `update all`.")
          else
            local _, ackN, failN = campaignCounts()
            print(("Campaign [%s] target v%s  ok %d  fail %d  / %d%s"):format(
              tostring(camp.scope or "?"), tostring(camp.version),
              ackN or 0, failN or 0, exp or 0,
              camp.finishedAt and " (finished)" or ""))
            for id, name in pairs(camp.expected) do
              local ainfo = camp.acked[id]
              local finfo = camp.failed[id]
              if ainfo then
                local via = ainfo.via and (" via " .. ainfo.via) or ""
                print(("  OK  #%-3d %s%s"):format(id, tostring(name), via))
                for _, p in ipairs(ainfo.packages or {}) do
                  print(("      %s - version: %s - %s"):format(
                    tostring(p.name or "?"), tostring(p.from or "?"), tostring(p.to or "?")))
                end
              elseif finfo then
                print(("  FAIL #%-3d %s: %s"):format(id, tostring(name), tostring(finfo.err)))
              else
                local d = seen[id]
                print(("  ... #%-3d %-16s have v%s"):format(
                  id, tostring(name):sub(1, 16), tostring(d and d.version or "?")))
              end
            end
          end
        else
          runForceUpdate(scope, { yes = yes })
        end
      end
    elseif cmd == "reauth" then
      if not isMain() then print("reauth is MAIN-only."); else
        local rname = os.getComputerLabel() or ("Router-" .. os.getComputerID())
        rednet.broadcast({
          type = "reauth", from = os.getComputerID(), name = rname,
          mainRouterId = os.getComputerID(),
        }, PROTO_ROUTER)
        claimMain()
        print("Re-auth broadcast sent. Devices will re-auth to this main (bots also hit data server).")
      end
  elseif cmd == "ssh" then
      if not a[2] then print("Usage: ssh <id|label> [command...]")
      elseif titanLib and titanLib.sshIsAuthed and titanLib.sshIsAuthed() then
        print("Nested ssh from an SSH session is not supported.")
      elseif not titanLib then
        print("ssh needs lib/titan.lua on this router (re-install router role).")
      else
        local target = a[2]
        local parts = {}
        for i = 3, #a do parts[#parts + 1] = a[i] end
        local cmdline = #parts > 0 and table.concat(parts, " ") or nil
        titanLib.sshConnect(target, cmdline)
      end
  elseif cmd == "say" then
      if not a[2] or not a[3] then
        print("Usage: say <id|label> <message>")
      elseif not titanLib or not titanLib.say then
        print("say needs a newer lib/titan.lua on this router (run update).")
      else
        local target = a[2]
        local parts = {}
        for i = 3, #a do parts[#parts + 1] = a[i] end
        local ok, err = titanLib.say(target, table.concat(parts, " "))
        if ok then
          print("Said to " .. tostring(target) .. ".")
        else
          printError("say: " .. tostring(err))
        end
      end
  elseif cmd == "exit" or cmd == "quit" then
    return "exit"
  else
    return false
  end
  return true
end

function consoleLoop()
  print(("Titan router #%d [%s]. %d modem(s) (rf:%d wire:%d). Type 'help'."):format(
    os.getComputerID(), routerRole:upper(), #modems, #wirelessModems, #wiredModems))
  while true do
    write(isMain() and "router> " or "modem> ")
    local a = {}
    for word in tostring(read()):gmatch("%S+") do a[#a + 1] = word end
    local r = handleRouterCommand(a)
    if r == "exit" then return
    elseif r == false then
      print("Unknown: " .. tostring(a[1] or ""))
    end
  end
end

--------------------------------------------------------------------------------
-- Boot (MAIN / ROUTER hub). Wrapped so top-level locals stay under Lua's 200 limit.
--------------------------------------------------------------------------------
function runHub()
if fs.exists("lib/titan.lua") then
  titanLib = dofile("lib/titan.lua")
  if titanLib.setSshHandler then
    titanLib.setSshHandler(function(line)
      local a = {}
      for w in tostring(line):gmatch("%S+") do a[#a + 1] = w end
      local r = handleRouterCommand(a)
      if r == "exit" then
        print("Over SSH: type `exit` to disconnect (router keeps running).")
        return true
      end
      if r == false then
        print("Unknown: " .. tostring(a[1] or ""))
      end
      return true
    end)
  else
    print("[ssh] Update lib/titan.lua (run `update`) for full remote commands.")
  end
end

rcfg = loadRouterCfg() or {}
if rcfg.role == "modem" then
  print("This file is the MAIN/ROUTER hub runtime.")
  print("Role is modem — run `router` to load router_modem.lua.")
  return
elseif rcfg.role == "main" or rcfg.role == "router" then
  routerRole = rcfg.role
else
  print("")
  print("Hub role for this computer:")
  print("  M = MAIN hub (directory + OTA) — use an ENDER modem")
  print("  R = ROUTER backbone satellite — ENDER modem, long-haul peer")
  print("  (MODEM cells: run `router` and pick N — uses router_modem.lua)")
  write("[M/r] ")
  local ans = read():lower()
  if ans == "r" or ans == "router" then
    routerRole = "router"
  else
    routerRole = "main"
  end
  rcfg = patchRouterCfg({ role = routerRole })
  print("Role saved: " .. routerRole)
end
loadNetLinks()

if rcfg.gps then
  gpsCoords = rcfg.gps
elseif rcfg.gpsHost == false then
  -- previously opted out
else
  print("")
  print("Routers double as GPS hosts (place 4+ spread out for a constellation).")
  print("Host coords = MODEM block (F3 Targeted Block on the modem).")
  local x, y, z, info
  if titanLib and titanLib.gpsFix then
    x, y, z, info = titanLib.gpsFix({ timeout = 4, samples = 9 })
  else
    x, y, z = gps.locate(2)
    if x then
      x = math.floor(x + 0.5); y = math.floor(y + 0.5); z = math.floor(z + 0.5)
    end
  end
  if x then
    if info then
      print(("Auto-located: %d, %d, %d  (n=%d  Y %.2f..%.2f)"):format(
        x, y, z, info.n, info.yLo, info.yHi))
    else
      print(("Auto-located: %d, %d, %d"):format(x, y, z))
    end
    gpsCoords = { x = x, y = y, z = z }
  else
    print("Enter this MODEM's coordinates to host GPS (blank X = skip).")
    write("X: "); local sx = read()
    if sx ~= "" then
      write("Y: "); local sy = read(); write("Z: "); local sz = read()
      gpsCoords = { x = tonumber(sx) or 0, y = tonumber(sy) or 0, z = tonumber(sz) or 0 }
    end
  end
  if gpsCoords then
    patchRouterCfg({ gps = gpsCoords })
  else
    patchRouterCfg({ gpsHost = false })
  end
  if gpsCoords then print(("Hosting GPS at %d, %d, %d."):format(gpsCoords.x, gpsCoords.y, gpsCoords.z)) end
end

tasks = { repeaterLoop, consoleLoop, wiredLinkLoop }
if isMain() then
  tasks[#tasks + 1] = directoryLoop
  tasks[#tasks + 1] = pingLoop
  tasks[#tasks + 1] = rosterSaveLoop
  tasks[#tasks + 1] = drawLoop
  tasks[#tasks + 1] = githubWatchLoop
else
  -- ROUTER backbone + MODEM cells share the mesh side loop.
  tasks[#tasks + 1] = modemLoop
  -- Hop perimeter / net traffic toward home hub, MAIN, and backbone peers.
  tasks[#tasks + 1] = function()
    while true do
      local id, msg = rednet.receive("titan_net", 1)
      if type(msg) == "table" and id and isPerimeterTraffic(msg) then
        local cfg = loadRouterCfg() or {}
        local targets = {}
        local function add(t)
          t = tonumber(t)
          if t and t ~= id and t ~= os.getComputerID() then targets[t] = true end
        end
        add(homeRouterId)
        add(cfg.mainRouterId)
        add(cfg.homeRouter)
        for peerId in pairs(netPeers) do add(peerId) end
        local hop = {}
        for k, v in pairs(msg) do hop[k] = v end
        hop.hop = true
        hop.originId = tonumber(msg.originId) or tonumber(msg.sensorId) or id
        hop.viaModem = os.getComputerID()
        for tid in pairs(targets) do
          rednet.send(tid, hop, "titan_net")
          rednet.send(tid, hop, PROTO_ROUTER)
        end
      end
    end
  end
end
if gpsCoords then tasks[#tasks + 1] = gpsHostLoop end
if titanLib then
  tasks[#tasks + 1] = function()
    titanLib.sshHostLoop(roleKind())
  end
  if not isMain() then
    tasks[#tasks + 1] = function()
      sleep(2)
      titanLib.reportUpdatedIfPending(roleKind())
      while true do sleep(3600) end
    end
  end
end

print(("Role: %s"):format(routerRole:upper()))
if isMain() then
  local remembered = loadRoster()
  if remembered > 0 then
    print(("Loaded %d remembered system(s) from %s."):format(remembered, ROSTER))
  end
  loadNameRegistry()
  loadScreenAssignments()
  local nMon = refreshScreens()
  do
    local n = 0
    for _ in pairs(nameAssign) do n = n + 1 end
    if n > 0 then print(("Modem names: %d assigned. Type `names`."):format(n)) end
  end
  local onBits = {}
  for _, role in ipairs(SCREEN_ROLES) do
    local mode = not screenOn[role] and "off" or (screenPerm[role] and "perm" or "on")
    onBits[#onBits + 1] = role .. "=" .. mode
  end
  print("Boards: " .. table.concat(onBits, "  "))
  if nMon == 0 then
    print("No monitor yet — attach one for screensaver / boards.")
  else
    print(("Single screen on %s. Default=screensaver (%ds temp)."):format(
      displayMonName or "monitor", saverIdleSecs))
    print("Type `view local` / `view global` / `screen map perm`.")
  end
else
  -- ROUTER backbone (modem cells use router_modem.lua via bootstrap).
  print("ROUTER backbone — ender peers + local modem cells. Type `link`.")
  printNetLinks()
end
parallel.waitForAny(table.unpack(tasks))
for _, role in ipairs(SCREEN_ROLES) do
  local m = screens[role]
  if m then pcall(function() m.clear() end) end
end
if isMain() and rosterDirty then saveRoster() end
print("Router stopped.")
end -- runHub
