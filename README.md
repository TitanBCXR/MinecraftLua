# Titan Bot Network (CC: Tweaked)

A wireless dispatch system for Minecraft's **CC: Tweaked** mod (active packages):

- **`datacenter.lua`** — Parent Center (master password / fleet authority).
- **`console.lua`** — terminal console with mesh/`ssh` helpers.
- **`admin.lua`** — pocket admin tablet (live boards, quarry, gates/perimeter, where-track).
- **`router.lua`** (+ hub net/ui/cmd) — mesh repeater / MAIN router.
- **`offline_miner.lua`** — quarry turtle: solo `area`/`box`, or online **cell fleet**.
- **`offline_site.lua`** — site board: XZ **cells** (target 20×20, min 4), one bot/cell, full-H layer digs, dual pose, `where`.
- **`perimeter_sensor.lua` / `perimeter_manager.lua`** — Player Detector territory (one manager + admin alerts).
- **`tetris.lua`** — pocket Tetris (local LB cache; **Noisy** note-block Korobeiniki).
- **`minesweeper.lua`** — lightweight pocket Minesweeper (no modem required).
- **`lib/titan.lua`** — shared library (protocol, messaging, navigation).

Older packages (hub/bot/poi/miner/…) live under [`archive/`](archive/) and are not in the installer menu.

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

### Recommended: GitHub installer

On an **advanced (color) pocket**, the installer opens a tap-friendly tile GUI.
Other devices keep the classic text menu.

On each device:

```
wget run https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/github_install.lua
```

Pick a role (Parent Center, console, admin, router, offline miner, site board,
perimeter, or Everything). Legacy `host.lua` rednet install is in `archive/`.

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

Each device needs (active installer roles):

| Device            | Files                                      |
|-------------------|--------------------------------------------|
| Parent Center     | `datacenter.lua`, `lib/titan.lua`          |
| Console           | `console.lua`, `lib/titan.lua`             |
| Admin tablet      | `admin.lua`, `lib/titan.lua`               |
| Network router    | `router.lua`, hub libs, `versions.lua`     |
| Offline miner     | `offline_miner.lua`, `lib/titan.lua`, `exclude.txt` |
| Quarry site board | `offline_site.lua`, `lib/titan.lua` (+ modem) |
| Perimeter sensor/manager | `perimeter_*.lua`, `lib/titan.lua`  |
| Games (submenu **g**) | `tetris.lua` / `minesweeper.lua` (+ titan for Tetris) |

Keep `lib/titan.lua` in a `lib` folder next to the program. Older roles are in
[`archive/`](archive/).

## 4. Run

- **Hub:** `hub.lua` — watch the monitor, type commands in the terminal.
- **Bots:** `bot.lua` — the turtle calibrates its heading (needs GPS + one clear/diggable space + fuel), sets home, then waits for orders.
- **POIs:** `poi.lua` — first run asks for a name/description and reads GPS coords (or type them in). Use the menu to summon bots.

Tip: rename a device with `label set <name>` so it shows a friendly name on the status board.

Tip: auto-start needs **quotes** around the filename in `startup.lua`:

```lua
shell.run("offline_miner.lua")
```

Without quotes Lua treats `offline_miner.lua` as a table index and crashes on boot.

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

1. A locked station **prompts for the master password immediately** (no need to type `password` / `login` first). Same after `lock` / `logout`.
2. It reads the **interacting player's display name** (via an Advanced Peripherals **Player Detector** next to the computer) and asks for a password (masked).
3. The attempt is checked against the master password:
   - if this computer holds the master floppy → checked locally;
   - otherwise it broadcasts to find who holds the floppy and asks that master to verify (the real password never travels the network — only the attempt does, and only a true/false comes back);
   - if **no master is online/found → always "Wrong password"**, even if none exists.
4. On success the terminal unlocks into admin mode for that player. On failure you can retry, or use locked helpers (`initmaster`, `help`).

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

Locked (bot) mode — password prompt appears on its own; these are fallbacks:

```
password|login  prompt for the master password again
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
2. Log into a Parent Center terminal (password prompt on start / after lock).
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

**Slots:** **16** = fuel (never dumped). **15** = equipment hot-swap (modem **or**
chunk loader). With `selfchunk on`, the miner digs offline with a chunk loader
equipped and parks the modem in slot 15; on dump/refuel it swaps the modem back
on to use GPS/mesh, then returns to chunk mode.

**Fuel budget:** tracks burn rate vs movement (`eco`). It always reserves enough
fuel to return to the fuel chest/home. When a tank can’t dig further and still
return, it saves **depot coords**, prints them, and waits. Place the turtle there
with a **fuel chest on the LEFT** and **storage BEHIND** — it auto-detects and
continues (`depot` to reprint coords).

### Setup

```
set1 / set2       opposite corners (GPS or x z)
sety <top> <bot>  vertical range
home              start pose (chest one block behind)
chest / storage   storage chest
fuelchest here    optional fuel chest
selfchunk on      dig with chunk loader (modem in slot 15)
modem | chunk | swap
mine / continue / stop / status
```

Site markers can send `storage`, `fuelchest`, and `selfchunk` with the job so
fleet miners pick those up automatically.

---

# Perimeter (Player Detector)

Track players entering / leaving your territory with Advanced Peripherals
**Player Detector** blocks on the Titan mesh.

### Layouts

- **Single sensor:** one detector covering the whole area (leave side unset,
  raise `range`). On ENTER the board shows **approach bearing** (player position
  vs the detector).
- **Multi-gate:** one sensor per edge; `here` then `assign all` maps
  N/NE/E/SE/S/SW/W/NW from GPS.

Sensors **bind to one manager** (not the whole mesh). The manager can forward
ENTER/EXIT to an **admin tablet**; the tablet **Stats** board shows recent
activity, and **Gates** / `live perimeter` is the full activity screen
(polls the manager every **2 seconds**, with enter/exit **player Y**).

### Perimeter manager (`perimeter_manager.lua`)

One board computer (installer → **"Perimeter manager"**), ideally with a monitor + GPS:

```
here                 set territory origin (stand at center)
assign all           auto-map sensors to N/NE/E/SE/S/SW/W/NW from GPS
rename <id|gate> Main Gate
set <id|all> range 50
set <id> range x 80
set <id> range z 40
set <id> range y 256
set <id> side ne
set <id> side clear  whole-area mode (no gate side)
set <id|all> gpshost on|off|here|<x> <y> <z>
set <id|all> poll 0.5
set <id|all> autoname
ignore add Steve     allowed player (no alerts; pushed to sensors)
ignore remove Steve | ignore list | ignore clear
admin <tabletId>     forward ENTER/EXIT to that admin pocket
admin clear | admin
update | forceupdate OTA this board + every perimeter sensor
sensors | status | log
newlog | logs        rotate / list disk event logs
```

Shows who’s inside, entry / approach sector, timestamps, and a rolling ENTER/EXIT log.
Events are appended under `perimeter_logs/` and reloaded on boot (latest file).
Logs over **5 MB** are deleted automatically; `newlog` starts a fresh file and
removes the previous one.

Sensors auto-bind to this manager on hello (`managerId` pushed). Override on a
sensor with `manager <id>` / `manager clear`.

**Mesh:** sensors out of direct range still reach **their** manager through the
**MAIN router** (targeted hop, not a flood to every manager).

**`update` / `forceupdate`:** refreshes the manager, pushes OTA to every known
perimeter sensor over rednet, then **SSH**es any that don’t ACK (master password)
and runs `update -y` on them.

### Perimeter sensor (`perimeter_sensor.lua`)

Install on each gate or as one territory detector (installer → **"Perimeter sensor"**):

- Computer + wireless modem + Player Detector + GPS coverage
- Default **range 50** per axis (half-extent from detector); no side = whole-area
- ENTER/EXIT report **approach bearing** + **player Y** (Y is cached while inside
  so EXIT still has a level after the player leaves detector range)
- Axis ranges: `range x 80`, `range z 40`, `range y 256` (or `range 50` for all)
- **GPS host** for routers/nav: on by default once GPS is known (`gpshost here|off|x y z`)
- Multi-gate: `auto` / manager `assign`, or `side ne`, `name My Gate`, `autoname`
- `manager <id>` locks reports to one manager (auto-bound on first hello)

Manager can push `side` / `range` / `rangex|y|z` / `name` / ignore / `managerId` remotely.
Overlapping gates use a grace timer so walking between detectors doesn’t false-exit.

---

# Offline miner (`offline_miner.lua`) + site board (`offline_site.lua`)

Needs no GPS or Parent Center for solo digs — turtle + two chests. Stand at the
**top-front-left** corner of the dig, facing into the mine. That pose is origin
`0,0,0`:

| Axis | Direction |
|------|-----------|
| +X   | right     |
| +Y   | down      |
| +Z   | forward (into the mine) |

**First boot** (or `setup`):

| Side / slot | Role |
|-------------|------|
| Chest **LEFT** | Fuel → **slot 16** (coal stays there) |
| Chest **BEHIND** | Storage → dumps slots **1–14** |
| **Slot 15** | Wireless modem (online mode) |
| Upgrade **RIGHT** | Pickaxe (modem swaps with this side only; left/loader untouched) |
| Site PC (optional) | Left of the storage chest |

### Network mode

```
mode offline              solo dig — no site board, no admin check-ins
mode online               modem + site claims / admin tablet (default)
```

Use **offline** for a lone turtle (`area` / `box` / …). Use **online** for the
same dig style plus site check-ins and multi-turtle projects.

**Online boot:** waits until a wireless modem is in inventory (slot 15), joins
the site board, claims an **XZ cell**, travels with modem on, digs full height
layer-by-layer inside that cell, then homes and requests the next free cell.

**Label:** each turtle sets `V{major}.{minor}-Miner{id}` from the miner version and
computer id (e.g. `V1.5-Miner12`).

### Turtle commands

```
area 16x32 40             W×L footprint, 40 layers down (aliases: quarry, flatten)
box 9x6x10                W×H×D — 9 right, 6 layers down, 10 forward
tunnel 32 [3]             player-tall corridor (optional width)
stair 3x20 down           width × steps, up|down (player-tall)
equip | tool | pick       mount best pick from inventory
mode online|offline       site/admin on or off
join                      find site board (online)
mine                      claim from site until none left
continue | resume         resume saved / site job
job | clearjob            show / forget saved job
home | dump | refuel | setup | stop | status | site | help
```

### How it digs

- **`box` / `area` (solo):** always **one Y layer at a time** — walk the plane
  (snake rows), then drop one Y in place. No dig-up, no neighbor spin-dig.
- **Facing:** stays on the dig-line heading while mining. It only faces into the
  mine (`+Z`) at **origin** (home / depot / band start). Turns only when the
  next step needs a new direction.
- **Check-ins (online):** modem swap at depot dumps and when a **layer** finishes
  (not every row — keeps speed up).
- **Other turtles:** never attack them. If one is ahead, bypass to its own right:
  `R F L F L F R`.
- **tunnel / stair:** stay player-tall (2 high).

### Fuel SOS

At **0 fuel** the computer still runs. The turtle equips the modem and broadcasts
`quarry_sos` to the **admin tablet** and **MAIN router monitors** until coal is
restored (`quarry_sos_clear`). If it can’t walk home, it SOS in place.

### Job memory + reboot resume

Progress and pose save to `offline_miner_job.cfg` (synced to the site when
online). A finished dig clears the file.

On **reboot** (online): the turtle talks to the site, restores saved pose, and
auto-continues when fuel allows. If fuel is only enough for the depot, it
refuels there first, then continues. `continue` / `resume` do the same by hand.

After a hard `stop` with no site: put the turtle back at origin (`0,0,0` facing
in) and run `continue`.

When inventory fills it returns home, dumps behind, refuels from the left, then
resumes. Optional `exclude.txt` is honored if present.

### Site board (`offline_site.lua`) — XZ cells

Left of the storage chest. Auto-learns W×L×H from turtle reports, or lock with
`setup`. Splits the footprint into **cells** (target **20×20**, min **4×4**,
edge remainders allowed). **One bot per cell.** Each bot digs that cell’s full
`H` **one Y layer at a time**, then marks the cell complete and gets another.

**Lifecycle:** `leave_origin` (modem on) → travel → `arrive_cell` → dig inside
cell AABB → home → `cell_done` → next free cell. Site computes **quarry-relative
and world** pose (via `origin`). Outside-cell pose → `quarry_return_home`.
GPS turtle fixes are stubbed for a later constellation pass.

```
# site board
setup 215x100 13 20          # footprint + optional cell size
cellsize 16                  # rebuild free cells (keeps completed)
cells                        # list free / assigned / complete
origin 1343 95 1084 south    # GPS of quarry 0,0,0 + facing into mine
where 12                     # admin distance track
reband                       # recall fleet home (keeps cell assigns)
clear | clearminers          # wipe turtles/jobs; assigned→free
clearcells                   # all cells free again
status | turtles | jobs

# turtles (mode online)
mine                         # claim cells until none left
clearjob                     # forget local dig + assign

# admin tablet
quarry                       # cells %, per-turtle cell + rel/world pose
where 5 12                   # site #5 bot #12 → live GPS track
```

Progress % = cells complete (+ partial credit on active cells). Statuses include
`travel` / `arrive` / `mining` / `homing` / `sos`.

Install via the installer → **"Offline miner"** / **"Offline quarry site board"**.

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
hostname [name]   get or set network hostname (updates router roster)
packages              list desired packages + versions
packages add <name>   add a package to the `packages` file
packages remove <name> remove from the `packages` file
packages update       download every package listed in `packages`
update [-y]           same as `packages update` (`-y` reboots without asking)
ssh <id|label> [cmd...]   remote shell (master password)
reboot|shutdown   power control
exit | quit       leave the console
```

`hostname MyBase-PC` sets the computer label and immediately re-registers with
the router so the status board shows the new name. Alias: `host`.

Each installed device gets a plain-text **`packages`** file (desired package
paths, one per line). Installers create it; you can edit it or use
`packages add` / `packages remove`. **`update` downloads exactly that list**
from the install source (GitHub / pastebin / `host.lua`). Extras on disk that
aren’t listed show as `*` and are not updated.

Bump versions in `versions.lua` (and each file’s `Titan-Version:` header) when
you ship a change; current system version is **1.6.0** (`offline_site` **1.3.0**,
`offline_miner` **1.5.0**, `admin` **1.5.0**).

**Cell fleet:** the site board owns unique XZ cells; miners obey cell assigns and
drop stale local jobs. Archived packages are under `archive/` (not in installers).

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

**Boots with a login screen GUI** (before network loops start — same floppy as
Parent Center). Type the master password in the field and press Enter. Deploy /
SSH / fleet control need an unlocked session. No master online → denied until
the floppy is up. **Lock** returns you to the login screen.

### Two UIs (same program)

| Mode | Who it’s for | How to enter |
|------|----------------|--------------|
| **Simple** (default) | Anyone — phone home with app tiles | Boot choice / `mode simple` |
| **Advanced** | Terminal users — command line | Boot choice / `mode advanced` |

**Simple (phone home):** colored app tiles (Stats, Miners, Deploy, Quarry, …).
Tap a tile or press `1`–`0`. Left/right (or `a`/`d`) flips pages (10 apps each).
`E` exits. Wizards and live boards open from the matching app.

**Advanced:** type commands as before. `help` is **paginated** — 10 commands per
page; enter a page number, or `n`/`p` for next/prev. Over SSH, `help 2` prints
one page.

```
help [page]              paginated command list (10 / page)
live [board] | quarry | bots | miners | loaders | markers | pending
connections | link | link auto | connect <id|name>
deploy | flatten | dc | park | stop | continue | mode simple|advanced
```

**Live boards** pull the same local / global / stats / GPS / bots / quarry views
as the MAIN router monitor (`board_req`). An **advanced (color) pocket** gets the
pretty GUI; a normal pocket stays mono. Keys: `1`–`6` select board, `←`/`→`
cycle, `r` refresh, `q` quit.

**Quarry board** lists each offline miner’s claim, status, and **last known pose**
(`@x,y,z` relative to quarry origin). Out-of-fuel turtles show **SOS** (from
`quarry_sos` broadcasts) until cleared.

**`link`** builds the ender-router backbone and attaches local RF modems. Prefer
`link auto` once hubs have GPS, or `link 5 12` to peer two routers / attach a
modem to a hub. Simple menu item **10** opens the same tools.

Pocket workflow: Simple menu **8** (connect) / **9** (Parent Center), or Advanced
`connections` → `connect ParentCenter` (or `dc`). Control is gated by the
master password — pull the master floppy and every login (including the tablet)
is denied.

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

`router.lua` is a **bootstrap**: it reads `router.cfg` (or asks once), downloads
the matching runtime if needed, then runs it:

| Role | Runtime file |
|------|----------------|
| **MAIN** / **ROUTER** | `router_main.lua` + `lib/router_hub_*.lua` |
| **MODEM** | `router_modem.lua` |

Missing files are pulled from the install manifest or GitHub automatically.
Hub logic is split across `lib/router_hub_net.lua`, `lib/router_hub_ui.lua`, and
`lib/router_hub_cmd.lua` (avoids Lua’s 200-local limit).

Ties the whole network together over wireless. Three roles:

| Role | Modem | Job |
|------|--------|-----|
| **MAIN** | Ender | Directory, OTA, re-auth; long-haul hub |
| **ROUTER** | Ender | Backbone satellite; peers with MAIN/other routers |
| **MODEM** | Normal RF | Local cell coverage (~64 blocks); homes to a hub |

```
[MAIN ender] <-----ender-----> [ROUTER ender] <-----ender-----> [ROUTER …]
     |                              |
 [modem RF]  [modem RF]        [modem RF]     ← local area coverage
```

Use the **admin tablet** `link` command (or `link` on each node) to peer routers
and attach modems:

```
link                 show topology
link <idA> <idB>     smart link (router↔router or modem→router)
link peer 5 12       force backbone peer
link modem 20 5      attach modem #20 to hub #5
link auto            peer all routers; each modem → nearest hub (GPS)
```

- **Repeater:** re-transmits rednet traffic so devices out of direct range still
  reach each other. Local **MODEMS** fill a site; **ROUTER/MAIN** ender links
  span the map. **Rednet hops ≠ GPS** — place 4+ GPS-capable hubs (or
  `gpshost.lua`) near distant areas too.
- **Directory + status boards (MAIN):** two roster views on the monitor —
  **local** (`view local` / `screen roster`) for this hub’s modems and computers,
  and **global** (`view global`) for **MAIN / backbone routers** and remote mesh
  cells (RF modems and end devices are **not** counted as global “routers”).
  Also `devices` / `forget` in the console. **Advanced (color) monitors** get a
  denser GUI (header bars, status chips, alternating rows); plain monitors stay
  mono. Layout and text scale auto-adjust from the screen size (`tiny` → `large`).
  Quarry **fuel SOS** overlays show on MAIN monitors when an offline miner is
  out of coal.
- **GPS host:** each hub can host GPS (`gpshost <x> <y> <z>`).

Install via installer → **"Network router"**.

**OTA update** (MAIN router only):

| Command | Target |
|---------|--------|
| `update` / `forceupdate` | Online **modems** only (mesh extenders) |
| `update all` / `update fleet` | **Every** online Titan device |
| `update status` | ACK progress |

Both force paths refresh MAIN, push OTA over rednet, wait for ACKs, then **SSH**
into stragglers (`update -y`, master password). Modem updates are **unicast** so
miners/workers/admin are not touched. `update all` still **broadcasts** to the
whole fleet. The monitor switches to an ACK board (hostname + package from→to)
and restores when done.

Every device with a `.titan-install` manifest re-downloads from its install
source (GitHub / pastebin / host) and reboots. Keep `host.lua` running if the
fleet was installed that way.

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
