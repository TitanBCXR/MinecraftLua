# images/

Place `.png` files here on the ComputerCraft computer, then run:

```
image_loader
image_loader images/my_picture.png
```

Requires an **advanced (color) monitor** for the nav GUI. The loader quantizes to CC’s 16-colour palette and scales to fit (letterboxed) in the monitor view panel.

## Split UI

| Where | What |
|-------|------|
| **Computer** | Paste/enter a download link; status; short commands (`fetch`, `github`, `load`, `help`, `quit`) |
| **Monitor** | Title bar + `images/` list + view area + **Load / Fetch / Refresh / Fit / Prev / Next** |

**Fetch** on the monitor uses the link currently shown on the computer. Last link / last image are saved in `.image_loader.cfg`.

## How to copy PNGs correctly (binary)

CC:Tweaked stores each computer’s files under the world save:

```
<world>/computer/<id>/images/Map.png
```

Copy the PNG **as a binary file** into that folder (OS file explorer, `cp`, etc.).

**Do not:**

- Paste PNG contents through the in-game terminal / chat / `edit`
- Open/save the PNG in a text editor
- Rename a JPEG/HTML download to `.png` without converting

Those corrupt the 8-byte PNG signature (`89 50 4E 47 0D 0A 1A 0A`). A classic failure is text-mode mangling of `0D 0A 1A` (CR/LF/SUB).

If decode fails, the loader prints the first 8 bytes in hex so you can see corruption (e.g. `FF D8` = JPEG, `<!DOCTYPE` / `3C 21` = HTML).

## Download from GitHub / HTTP (binary)

With HTTP enabled in the CC:Tweaked config:

**On the computer** — paste a URL, then tap **Fetch** on the monitor; or:

```
image_loader
> github TitanBCXR/MinecraftLua/images/Map.png
> github https://github.com/TitanBCXR/MinecraftLua/blob/main/images/Map.png
> https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/images/Map.png
> fetch
```

- `github` resolves blob / short `owner/repo/path` forms to **raw.githubusercontent.com** (default branch `main`; optional `owner/repo@branch/path`).
- Downloads use **binary** HTTP and write with `fs.open(..., "wb")` into `images/`, then auto-load.
- Prefer raw PNG URLs — HTML pages (404 / blob UI) will be rejected with a clear error.

## Supported PNG kinds

Non-interlaced: RGB8, RGBA8, greyscale, greyscale+alpha, palette (1/2/4/8-bit), optional `tRNS`, and 16-bit channels (high byte). Typical Minecraft / map exports work when the file is a real binary PNG.
