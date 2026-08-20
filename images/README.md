# images/

Place `.png` files here on the ComputerCraft computer, then run:

```
image_loader
image_loader images/my_picture.png
```

Requires an **advanced (color) monitor**. The loader quantizes to CC’s 16-colour palette and scales to fit (letterboxed).

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

```
image_loader
> github TitanBCXR/MinecraftLua/images/Map.png
> github https://github.com/TitanBCXR/MinecraftLua/blob/main/images/Map.png
> github https://raw.githubusercontent.com/TitanBCXR/MinecraftLua/main/images/Map.png Map.png
> fetch https://raw.githubusercontent.com/OWNER/REPO/main/path/to/file.png map.png
```

- `github` resolves blob / short `owner/repo/path` forms to **raw.githubusercontent.com** (default branch `main`; optional `owner/repo@branch/path`).
- Both commands use **binary** HTTP and write with `fs.open(..., "wb")` into `images/`, then auto-load.
- Prefer raw PNG URLs — HTML pages (404 / blob UI) will be rejected with a clear error.

## Supported PNG kinds

Non-interlaced: RGB8, RGBA8, greyscale, greyscale+alpha, palette (1/2/4/8-bit), optional `tRNS`, and 16-bit channels (high byte). Typical Minecraft / map exports work when the file is a real binary PNG.
