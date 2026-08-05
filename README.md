# Titan Bot Network (CC: Tweaked)

A wireless dispatch system for Minecraft's **CC: Tweaked** mod:

- **`hub.lua`** — control computer with a monitor that shows live bot status + a command console.
- **`bot.lua`** — a turtle that reports status, navigates by GPS, and executes tasks.
- **`poi.lua`** — a "point of interest" computer that marks a location by coordinates and can summon a bot.
- **`miner.lua`** — quarry turtle: digs between two corners down to a floor Y, skipping `exclude.txt`.
- **`lib/titan.lua`** — shared library (protocol, messaging, navigation). Copy this onto **every** device.

```
Hub (monitor + modem)  <--rednet-->  Bots (turtles)
        ^                                 ^
        |------------- rednet ------------|
                    POIs (computers)
```

## 1. Requirements

- CC: Tweaked installed.
- **Wireless modem** on every device (hub, each bot/turtle, each POI). An Ender Modem gives unlimited range; a normal wireless modem is range-limited.
- A **monitor** attached to the hub computer (optional, but that's where the status board draws).
- Turtles need **fuel** (coal, charcoal, etc.) in their inventory, or run a server with unlimited turtle fuel.

## 2. Set up a GPS constellation (needed for navigation)

Bots locate themselves and drive to coordinates using `gps.locate`, which needs at least **4 GPS host computers** in range.

**Easy way — `gpshost.lua`:** install it on each GPS computer (installer → **"GPS host"**, or `wget` it). It asks for that computer's coordinates (or auto-detects if a constellation already exists), saves them, offers to auto-start on boot, and hosts. Repeat on 4+ computers, spread out.

**Manual way:**

1. Place 4 computers high up, each with a wireless (ideally ender) modem.
2. On each, note its real world coords (F3 in-game) and run:
   ```lua
   gps host <x> <y> <z>
   ```
   (Built-in program — the 3 args are that computer's own coordinates.)
3. Set them to auto-run on boot by making a `startup.lua`:
   ```lua
   shell.run("gps", "host", "123", "72", "-45")
   ```

**Placement matters:** spread the hosts out — don't put them in a straight line or all at the same height, or the fix fails (that's the "Could not determine position" you'll see on a bot). Vary X, Z **and** Y. Ender modems give unlimited range.

Full guide: <https://tweaked.cc/guide/gps_setup.html>

## 3. Install the files onto your in-game devices

### Recommended: self-hosted installer (over your in-game network)

You don't need pastebin or an external web host. One CC computer serves every
file to the rest over rednet:

1. Put all the Titan files on **one** computer (the "host"). If they're on your
   PC, copy them into that computer's `computer/<id>/` folder in the world save,
   or seed them once with pastebin. Give the host a **wireless/ender modem**.
2. On the host, run:

   ```
   host.lua
   ```

3. On every **other** device, seed just the tiny `install.lua` once (pastebin
   get / a floppy / type it in), then run:

   ```
   install.lua
   ```

   It finds the host, asks what this device is (Hub, Bot, POI, Parent Center,
   Bots Computer, Worker, Install host, or Everything), downloads exactly the
   files that role needs, offers to write a `startup.lua`, and can launch it.

Tip: choose **"Install host"** on a second computer to make another share point,
or **"Everything"** to pull the whole system onto one machine.

### Install from GitHub

`github_install.lua`'s `RAW_BASE` is set to this repo, so on each device just run:

```
wget run https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/github_install.lua
```

It pulls the chosen role's files straight from GitHub. Use the **raw**
(`raw.githubusercontent.com`) URL, not the `github.com/.../blob/...` page.
There's also `pastebin_install.lua` for a Pastebin-code workflow.

### Manual alternatives

The `.lua` files also install by hand:

- **Pastebin:** `pastebin get <code> <name>` after uploading, or
- **`wget`:** host the files and `wget <url> <name>`, or
- Open the world save's `computer/<id>/` folder and copy the files in directly, or
- Type them in via the in-game editor: `edit bot.lua`.

Each device needs:

| Device            | Files                                      |
|-------------------|--------------------------------------------|
| Install host      | all files + `host.lua`                     |
| Hub computer      | `hub.lua`, `lib/titan.lua`                 |
| Each turtle (bot) | `bot.lua`, `lib/titan.lua`                 |
| Miner turtle      | `miner.lua`, `lib/titan.lua`, `exclude.txt` |
| Each POI computer | `poi.lua`, `lib/titan.lua`                 |

(The **Install host** runs `host.lua` and serves everything else over rednet;
see §3. Fresh devices only need `install.lua` to pull their files.)

Keep `lib/titan.lua` in a `lib` folder next to the program.

## 4. Run

- **Hub:** `hub.lua` — watch the monitor, type commands in the terminal.
- **Bots:** `bot.lua` — the turtle calibrates its heading (needs GPS + one clear/diggable space + fuel), sets home, then waits for orders.
- **POIs:** `poi.lua` — first run asks for a name/description and reads GPS coords (or type them in). Use the menu to summon bots.

Tip: rename a device with `label set <name>` so it shows a friendly name on the status board.

## 5. Hub console commands

```
list                     list bots and POIs
send   <bot> <poi>       send a bot to a named POI
goto   <bot> <x> <y> <z> send a bot to raw coordinates
return <bot>             send a bot home
refuel <bot>             refuel from the bot's inventory
stop   <bot>             cancel current task
ping                     re-discover everyone
help                     command list
exit                     quit the hub
```

`<bot>` is the turtle's label or its computer id.

## 6. Adding your own bot jobs

Open `bot.lua` and add a function to the `jobs` table, e.g.:

```lua
function jobs.chopTree(cmd)
  -- your turtle logic; return true on success, or false, "reason"
  return true
end
```

Then add its name to `jobList` in `poi.lua`, or trigger it from the hub by
dispatching a `goto` with a `job` field. The bot runs the job once it arrives.

---

# Titan Data Center (`datacenter.lua`)

A **single self-contained script** that every data-center computer runs. It figures
out its own role and keeps admin terminals locked until a player logs in.

## Roles (automatic)

- **Master** — the computer that has the **master floppy disk** inserted (a floppy holding a file named `master.pw`). It stores the master password + the registry of every station and answers login checks.
- **Station** — every other computer. Locked in **bot mode** until someone logs in, then it becomes an **admin terminal** for that session.

## Login flow

1. A locked station only accepts the `password` command.
2. `password` reads the **interacting player's display name** (via an Advanced Peripherals **Player Detector** next to the computer) and prompts for a password (masked).
3. The attempt is checked against the master password:
   - if this computer holds the master floppy → checked locally;
   - otherwise it broadcasts to find who holds the floppy and asks that master to verify (the real password never travels the network — only the attempt does, and only a true/false comes back);
   - if **no master is online/found → always "Wrong password"**, even if none exists.
4. On success the terminal unlocks into admin mode for that player.

## First-time setup (bootstrap the master password)

There's a chicken-and-egg: you need the password to log in, but setting it needs admin.
So on the master-to-be computer, with a **blank floppy** in its disk drive, run once from the locked screen:

```
initmaster
```

This writes `master.pw` to the floppy and makes that computer the master. Afterward, changing it requires logging in and running `setmaster`.

## Install / run

Put `datacenter.lua` on **every** data-center computer (master + stations). No shared
library needed — it's one file. Each computer also needs a wireless modem. On first run
it asks for a **station name** (saved to `station.cfg`) and registers with the master,
which lists all stations on its screen/monitor.

Optional per station: an Advanced Peripherals **Player Detector** placed adjacent, so
logins capture the real player name. Without one, sessions log in as `operator`.

Tip: to auto-start on boot, create `startup.lua` containing `shell.run("datacenter.lua")`.

## Commands

Locked (bot) mode:

```
password        log in with the master password
whoami          show the interacting player
status          this station's status
initmaster      first-time master password setup (blank floppy)
```

Admin mode (after login):

```
stations        list every registered station
storage         scan attached storage inventories
find <item>     search storage for an item
scan            find online computers + who holds the master floppy
bots            live bot roster: active count + gathering vs building
bot <name>      a specific bot's location, state and task
locate <name>   alias of 'bot'
pending         list worker turtles awaiting deployment
deploy <id> <builder|gatherer> <name> [x y z]   deploy a worker
rename <name>   rename this station
setmaster       change the master password (master computer only)
who | status    session / station info
lock | logout   re-lock this terminal
reboot          restart this computer
```

The master computer also shows a **BOT NETWORK** panel on its monitor: the number
of active bots and how many are gathering vs building. The `bots` / `bot` /
`locate` commands are admin-only (they require the master-password login), so
bot location data is gated behind the master floppy.

## Data-center notes

- **Storage** commands read any attached **inventory** peripherals (chests, barrels, storage drawers, and AE2/Refined Storage bridges that expose an inventory). Connect them with wired modems for a big networked store.
- The **master password lives only on the floppy**. Pull the floppy and the whole network denies logins — that's your kill switch.
- **Multiple passwords:** `master.pw` may contain several passwords **separated by commas** — any one of them is accepted (e.g. `alice123,bob456,ops789`). Each entry is trimmed of surrounding spaces; empty entries are ignored. Set them at once via `initmaster`/`setmaster` (type them comma-separated), or edit `master.pw` on the floppy directly.
- Player-name reading requires **Advanced Peripherals** (the Player Detector). Plain CC: Tweaked has no vanilla way to read a player's name.
- This runs on its own protocol (`titan_dc`) and can coexist with the bot network above on the same computers.

---

---

# Builders & Gatherers (`worker.lua` + `botserver.lua`)

An automated work force layered on the same `lib/titan.lua` network. Bots are
either **builders** or **gatherers**, coordinated by the **Bots Computer**.

| File           | Runs on                | Purpose |
|----------------|------------------------|---------|
| `botserver.lua`| a computer (+ monitor) | The "Bots Computer": tracks bots, the gather board, coal requests, preset builds, and stuck alerts |
| `worker.lua`   | turtles                | A builder or gatherer bot (uses `lib/titan.lua`) |

## Deployment is driven by the Parent Center

Workers are **deployed from the Parent Center** (`datacenter.lua`) — the admin
side whose commands are locked behind the **master-password disk drive**. A
worker turtle never prompts for a password itself:

1. Run `worker.lua` on a fresh turtle. With no config it prints *"awaiting
   deployment"* and just waits, beaconing itself to the network.
2. Log into a Parent Center terminal (`password`, unlocked by the master floppy).
3. Run `pending` to see waiting turtles, then:

   ```
   deploy <id|name> <builder|gatherer> <name> [depX depY depZ]
   ```

   The Parent Center pushes that config to the turtle; it calibrates, sets home,
   saves `worker.cfg`, and starts working. `[depX depY depZ]` optionally sets a
   gatherer's storage drop-off chest.

Because `pending`/`deploy` are **admin** commands, nobody can deploy a worker
unless they've logged into a Parent Center with the master password. To
re-deploy a running worker, deploy it again (or run `redeploy` on the turtle to
re-announce it as pending).

## Gatherers

- **Never break blocks.** They navigate with digging disabled; if they get stuck they broadcast a `STUCK` alert (with coordinates) to the monitor/hub and the Bots Computer, then move on.
- Pull the **gather board** from the server and empty registered chests, keeping only what each chest's filter accepts, then deposit to storage.
- **Coal delivery:** pull coal from storage and drop it at the start-point chests of bots that requested fuel.

Chest access convention: bots sit **directly above** a chest and use suck/drop
down. Register the **chest's own coordinates** (the bot targets `y+1`).

### Gather filter semantics

A gather post carries an `accepts` list:

- `accepts = "all"` → take everything.
- `accepts = {"minecraft:iron_ingot", ...}` → **whitelist**, take only those.
- add `mode = "exclude"` → **blacklist**, take everything *except* the list.

Builders auto-register their output chest as *"take everything except coal"*
(`accepts = {coal, charcoal}, mode = "exclude"`) so gatherers empty their output
but leave fuel behind. Adjust in `worker.lua` (`deployChest`) to taste.

## Builders

- On startup a builder can deploy an **output chest** (`chest` command): it places a chest in front, registers it as a gather post, and asks for coal.
- Reports position/status continuously (shown on the hub + Bots Computer).
- **Scan a structure into a preset** (`scan <name> <W> <H> <L>`): starting **on top of the front-left corner** (one block above the highest corner, facing along the length), it serpentines the `W×H×L` box, recording each block's relative position + type, **never breaking restricted blocks**, saves `builds/<name>.txt`, and uploads it to the server. (This excavates the source while preserving it as reusable data.)
- **Build a preset** (`build <name>`): loads the preset (local file or from the server) and places it bottom-up at the bot's current position, using matching blocks from its inventory (reports any it's missing).

## Restricted blocks

`lib/titan.lua` has `titan.RESTRICTED` (+ `RESTRICTED_PREFIXES`). **No bot ever
breaks these** — bedrock, chests/barrels/hoppers, spawners, obsidian, and
anything from ComputerCraft / Advanced Peripherals by default. Edit that list to
protect more blocks.

## Running

1. Run `botserver.lua` on the Bots Computer (give it a monitor to see the board).
2. Make sure a Data Center master is online (`datacenter.lua` + master floppy) so bots can be set up.
3. Put fuel + (for builders) chests/building blocks in each turtle, then run `worker.lua` and complete setup.

### Bots Computer console

```
bots                              list bots + types
gathers | coal | builds | alerts  show each board
scan  <bot> <name> <W> <H> <L>    order a builder to scan a box into a preset
build <bot> <name> [x y z]        order a builder to build a preset
order <bot> goto <x> <y> <z>      move a bot
ping | help | exit
```

### Worker (turtle) console

```
status | login | help
scan <name> <W> <H> <L>    (builder, needs master password)
build <name>               (builder, needs master password)
chest                      (builder) deploy + register output chest
deposit <x> <y> <z>        set the storage drop-off (chest coords)
redeploy                   re-announce to the Parent Center for (re)deployment
home | reboot
```

## Travel altitude & backfill

For any long hop (horizontal distance ≥ `nav.CRUISE_MIN`, default 12), bots use
`nav.travelTo`, which:

1. **Climbs to Y = 250** (or as high as it can — it stops early if it hits the world ceiling or a restricted block) and flies across open sky, then drops onto the target.
2. **Backfills** the vertical shafts it digs. Blocks broken while climbing out are plugged straight back, and the shaft dug to drop onto a spot is remembered and re-filled the next time the bot leaves — *before* it deposits, so it still has the dug blocks on hand. Restricted blocks are never broken.

Notes:
- Backfill places a block only when a **matching item** is in the bot's inventory, so keep some spare dirt/cobble if you want gap-free repairs; builders normally carry blocks already.
- Gatherers still won't tunnel **horizontally** (they report `STUCK` instead), but they *may* dig **straight up/down** for cruise travel because those shafts get re-filled.
- Tune `nav.CRUISE_Y` and `nav.CRUISE_MIN` at the top of the nav section in `lib/titan.lua`.

## Worker notes & limitations

- Scanning assumes a roughly box-shaped build that fits the given `W×H×L`, with the bot placed above the highest corner. Non-flat tops/overhangs may scan imperfectly.
- Building is best-effort: it needs the right blocks in the turtle's inventory and handles simple structures; it doesn't do complex gravity/overhang ordering or auto-restock.
- Item filtering on pickup is done by sucking a chest's contents then returning what isn't accepted (turtles can't inspect a chest's contents without a wired-modem peripheral).
- Coordinate everything with **ender modems** for range, and keep a GPS constellation up for navigation.

---

# Miner (`miner.lua`)

Quarry turtle. Marks two opposite corners of an area, a floor Y, and digs the
box layer-by-layer. Blocks listed in `exclude.txt` (plus the built-in
restricted list: bedrock, chests, computers, etc.) are **never broken**.

Install via the installer → **"Miner"** (needs GPS + fuel + wireless modem).

### Setup

```
set1              stand at corner 1 → mark GPS
set2              stand at corner 2 → mark GPS
sety <y>          floor Y to dig down to (e.g. sety -59)
deposit           stand ABOVE a chest → dump inventory here when full
home              optional return point
exclude           reload & list exclude.txt
mine              start
stop              abort
status            show config / progress
```

### `exclude.txt`

One block/item id per line (`minecraft:obsidian`, etc.). `#` starts a comment.
A starter file ships with the install; edit it on the turtle with `edit exclude.txt`.

The mined volume is the XZ rectangle between loc1 and loc2, from the higher of
the two corner Y values down to `floorY`. When the inventory fills it returns to
`deposit`, drops everything down into the chest, then continues.

---

## Notes & limitations

- Navigation digs through obstacles by default and moves axis-by-axis (up → X → Z → down). It's simple, not a full pathfinder; keep routes reasonably clear or pre-tunnel long corridors.
- Heading calibration steps the turtle forward once then back — give it room and fuel on startup.
- Range: with normal wireless modems, devices must be within range (and modems don't reach across dimensions). Use ender modems for unlimited/cross-dimension range.

---

# Terminal console (`console.lua`)

A command console for any computer or turtle — a friendly superset of the
default CraftOS shell. Install with the installer → **"Terminal console"**
(pulls `console.lua` + `lib/titan.lua` for `ssh` / mesh).

Any command it doesn't recognise is passed through to the normal shell, so you
keep `edit`, `lua`, etc.

```
help [cmd]        list commands (or detail for one)
clear | cls       clear the screen
echo <text>       print text
ls [dir] | dir    list files            pwd              print working dir
cd <dir>          change directory       cat <file>       show a file
mkdir <dir>       make a directory       rm <path>        delete a file/dir
run <prog> ...    run a program
label [name]      get/set the label      id               show computer id
time              in-game time and day   about            version info
pos               locate via GPS         net              find Titan router
ssh <id|label> [cmd...]   remote shell (master password)
reboot|shutdown   power control
exit | quit       leave the console
```

---

# Remote shell (`ssh`)

Rednet "SSH" to any Titan device on the mesh (bots, workers, miners, routers,
Parent Center, etc.). Gated by the **Parent Center master password**.

```
ssh 12                 interactive session on computer #12
ssh Miner-5            by label (partial match ok)
ssh Worker-3 ls        one-shot: run `ls` remotely and print output
```

On the far side, each line runs through that computer's CraftOS `shell` (output
captured and sent back). Type `exit` to disconnect. Every program using
`titan.networkLoop` hosts an SSH endpoint; console/admin/router also have an
`ssh` client command.

On a **turtle** you also get:

```
fuel              show fuel level
refuel            burn fuel items from inventory
move <forward|back|up|down|left|right> [n]
```

Supports tab-completion of command names and up/down input history.

---

# Admin tablet (`admin.lua`)

A mobile master terminal for a **pocket computer** — the "Live" computer you
keep on you. It listens to the whole network and lets you monitor and command it
from your pocket.

Needs a **pocket computer with a wireless modem** upgrade and `lib/titan.lua`
(install with the installer → **"Admin tablet"**, or `wget` both files). The
tablet itself needs no GPS.

**Monitoring is open; every command that controls a bot requires `login`** with
the master password — verified against the Parent Center's master floppy, just
like the disk-drive lock. No master online → denied.

```
VIEW  : live            full-screen auto-refreshing dashboard (any key exits)
        bots            roster: id, name, type, state, pos, fuel
        pois            points of interest
        pending         workers awaiting deployment
        stuck           recent STUCK alerts
        ping            re-discover everyone
BOT   : send <bot> <poi>            dispatch to a named POI
        goto <bot> <x> <y> <z>      dispatch to coordinates
        return <bot> | refuel <bot> | stop <bot>
DEPLOY: deploy <bot> <builder|gatherer> <name> [x y z]
BUILD : scan <bot> <name> <W> <H> <L> | build <bot> <name> [x y z]
REMOTE: ssh <id|label> [cmd...]     remote shell (also needs master password)
        login | lock | exit
```

`<bot>` is a turtle's label or its computer id. Because control is gated by the
master password, losing the tablet doesn't hand over the network — pull the
master floppy and every login (including the tablet's) is denied.

---

# GPS locator (`locator.lua`)

A pocket **handheld map**: shows your live GPS position, lets you save waypoints,
and gives distance + compass bearing to each — plus the network's POIs and bots.
The personal counterpart to the admin tablet (that one commands bots; this one
helps *you* navigate).

Needs a **pocket computer with a wireless modem**, `lib/titan.lua`, and an
existing GPS constellation. (A pocket PC can't *host* GPS — hosts must be
stationary; use `gpshost.lua` for that. This tool only *locates*.)

```
here            show current position
live            full-screen radar: position, heading, nearest targets
mark <name>     save your current spot as a waypoint
wp              list waypoints with distance + bearing
go <name>       bearing to one waypoint
del <name>      delete a waypoint
pois | bots     network targets with distance + bearing
exit
```

Bearings are absolute compass directions (e.g. `84m NE up3`). Once you start
walking, it infers your facing from movement and adds a relative cue
(`ahead` / `left` / `right` / `behind`).

---

# Network router (`router.lua`)

Ties the whole network together over wireless. Run one (or several) on a
computer with a wireless (ideally **ender**) modem. It does three things:

- **Repeater:** re-transmits rednet traffic — **both broadcasts and directed
  messages** (bot commands, worker deploys, auth checks) — so devices out of
  direct modem range still reach each other. Chain several routers to blanket a
  big base; duplicate messages are de-duplicated so they never loop. (Same
  mechanism as CraftOS's built-in `repeat`, but with a roster + dashboard.)
- **Directory:** listens to every Titan protocol and keeps a live registry of
  who's online (bots, workers, hubs, POIs, data center, tablets). With a monitor
  attached it shows the roster + relay stats.
- **GPS host:** routers double as GPS hosts. On first run each router asks for
  its coordinates (or auto-detects if a constellation already exists) and then
  answers `gps.locate` requests. Place **4+ routers, spread out**, and they *are*
  your GPS constellation as well as the network backbone — no separate GPS
  computers needed. Coords are saved to `router.cfg`; re-set them any time with
  the `gpshost <x> <y> <z>` console command.

Install it via the installer → **"Network router"** (option **11**;
self-contained, no lib). Console: `devices`, `ping`, `stats`, `gpshost`,
`update`, `exit`.

**OTA update:** from the main router console, run `update` (confirms first).
Every device that was installed via an installer (and has a `.titan-install`
manifest) re-downloads its files from the same source (GitHub / pastebin /
install host) and reboots. Keep `host.lua` running if the fleet was installed
that way.

**Auto-registration + mesh relay:** every networked program (bot, worker/builder/
gatherer, miner/excavator, hub, POI, Bots Computer, data center, admin tablet,
locator, console, install host) announces itself to the router **and runs a
local rednet hop relay**. If a turtle is in wireless range of peers but not the
main router, it still forwards traffic — so deploy/commands/status hop across
the fleet. The router also periodically pings the network so devices register
no matter which booted first.

**Mesh API** (in `lib/titan.lua`): programs call `titan.networkLoop("kind")` as
a parallel task — that covers announce, OTA update listen, and hop relay.

**Manual check from any device:** the terminal console (`console.lua`) has a
`net` command — it pings the router and reports `Connected via Router #<id>
(<n> devices online)`, or tells you no router is in range.

Tip: with **ender modems** you already have unlimited range, so a router is
mainly useful for **plain wireless modems** (extending range) or as a **central
directory/monitor** of everything on the network.
