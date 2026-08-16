# Titan cell miner — setup & `box`

Quick guide for **solo digs** with `quarry/workers/offline_miner.lua` (installer: **q → Quarry → Workers → Cell miner**).

The same turtle can later join a **site board** and claim **XZ cells** (`mode online` → `mine`). This doc is about standing it up and digging a rectangle with **`box`**.

---

## What it is

A mining turtle that digs from a fixed origin, one **Y layer at a time** (walk the plane, then drop one). No GPS or Parent Center needed for solo work — turtle + two chests.

---

## Requirements (solo / `box`)

| Need | Notes |
|------|--------|
| Mining turtle | Pickaxe on **RIGHT** upgrade (slot 2) |
| Fuel chest | On the turtle’s **LEFT** → fills **slot 16** (coal / charcoal / blocks) |
| Storage chest | **BEHIND** the turtle → dumps slots **1–14** |
| Slot 15 | Wireless modem (optional for solo; required for online/site) |
| GPS / site board | **Not** required for `box` |

Optional later: site computer **left of the storage chest** for multi-turtle cell fleets.

---

## Standing position (origin)

Place the turtle on the **top-front-left** corner of the dig, facing **into** the mine. That pose is origin `0,0,0`.

| Axis | Direction |
|------|-----------|
| **+X** | right (`W`) |
| **+Y** | **down** (`H` layers) |
| **+Z** | forward into the mine (`D`) |

```
        +Z (into mine / D)
       /
  0,0,0 —— +X (right / W)
      |
     +Y (down / H)
```

---

## First boot

1. Place chests (fuel left, storage behind) and stock coal in the fuel chest.
2. Put the turtle at origin, facing into the mine.
3. Run the miner. First boot (or type `setup`) will:
   - dump cargo behind
   - suck fuel from the left into slot 16
   - lock origin at the current pose
4. For solo digs: **`mode offline`** (default boot mode is `online`, which waits for a modem/site).

```
mode offline
setup          # redo chests / re-lock origin if you moved the turtle
status         # pose, fuel, saved job
```

---

## `box` command

### Usage

```
box <W>x<H>x<D>
```

| Param | Meaning |
|-------|---------|
| **W** | Width — blocks to the **right** (+X) |
| **H** | Height — how many **1-block layers down** (+Y) |
| **D** | Depth — blocks **forward** into the mine (+Z) |

All three must be ≥ 1. Footprint is `W × D`; total layers is `H`.

### What it does

- Digs the rectangle starting at origin `0,0,0`.
- Always **one Y layer at a time**: snake across the plane, then drop one Y in place.
- Saves progress to `offline_miner_job.cfg` (resume with `continue` / `resume`).
- When inventory is **full** (cargo slots 1–14 all occupied): home → dump behind → refill **slot 16** from left → resume.
- Slot **16** is fuel-only and is **never** dumped into storage; after a depot stop the turtle leaves with a coal stack in 16.
- Also returns early only when fuel is too low for the trip home (+ reserve), not when a single cargo slot remains free.
- Does **not** claim site **cells**. Cells are only for online `mine` on a site board. Same layer dig style; different job.

### Examples

```
box 9x6x10       # 9 right, 6 layers down, 10 forward
box 16x40x32     # wide pit: 16×32 footprint, 40 layers deep
box 1x20x1       # single column, 20 down
```

Close cousin (same digger, different args):

```
area 16x32 40    # W×L footprint, then layers down (aliases: quarry, flatten)
```

`area 16x32 40` ≈ `box 16x40x32` (W×H×D).

---

## Commands you need with `box`

```
mode offline              # solo dig — no site wait
box 9x6x10                # start dig
stop                      # pause; job stays saved
continue | resume         # pick up saved job
status                    # pose + fuel + saved job
job | clearjob            # show / forget saved job
home | dump | refuel      # depot helpers
setup                     # re-run chest setup + lock origin
help
```

After a hard `stop` with **no** site: put the turtle back at origin (`0,0,0`, facing in), then `continue`.

---

## Common mistakes

1. **Left in `online` mode** — turtle waits for modem/site instead of accepting a solo dig. Use `mode offline` first.
2. **Wrong corner / facing** — must be top-front-**left**, facing **+Z** into the mine, or the box digs the wrong way.
3. **Swapping H and D** — `box 9x6x10` is **6 layers down**, not 10. Depth is the third number.
4. **Confusing `box` with site cells** — `box` is one rectangle from origin. Multi-bot cells need a site board + `mode online` + `mine`.
5. **`continue` after moving the turtle** — offline resume assumes you are still at origin (or the saved pose). Re-seat at `0,0,0` facing in if unsure.
6. **Fuel / dump chests flipped** — fuel **left**, storage **behind**. Slot 16 is fuel-only and never emptied at the deposit; don’t put the modem there (use 15).
7. **Pick on the wrong side** — pickaxe on **RIGHT**; left upgrade (e.g. chunk loader) is never touched.

---

## More detail

Full quarry docs (online cells, site board, scanner, strip miner): see **Quarry** in [`README.md`](README.md).
