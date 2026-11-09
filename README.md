# Soft Bun's Oven (`sbo`)

*by softbuns* — raw Materia Magica output goes in, baked output comes out.

A [Mudlet](https://www.mudlet.org/) package (tested target: Mudlet 5.1.1) that rebuilds the game's
walls of text into clean, aligned, colour-highlighted layouts — in the main window and in a
floating **oven window**.

## What it bakes

| Command (any abbreviation the game accepts) | Becomes |
|---|---|
| `eq` | slot table, armor resistance grid, defenses, weapon damage breakdown |
| `look` / `examine` / `identify` an item | stat grid, keywords, flags, affects, relics, weapon block, description |
| `ex` / `look` a mob | description + what it is using |
| `i`, `look in <container>` | one item per row, stack counts, capacity footer |
| `score` | level & exp to level first, vitals and attribute gauges, standing, kill record |
| `aff` | resistances, spell/racial affects with their modifiers |

Plus:

- **Gear compare** — every item you look at is remembered. Looking at an item automatically compares
  it with what you wear in that slot; `sbo pin <item>` compares everything against one item;
  `sbo compare <a> vs <b>` compares any two.
- **Prompt bar** — `sbo bar on` moves the prompt into a fixed bar under the text with HP/SP/ST
  gauges, your level and exp to level.

## Install

1. Download [`Oven.mpackage`](../../raw/main/Oven.mpackage).
2. In Mudlet: **Toolbox → Package Manager → Install**, pick the file (or drag it onto the Mudlet window).
3. Type `sbo` for the list of commands, `sbo test` for a demo.

## Update

Type `sbo update`. It checks this repository and installs the newest version, keeping your
settings and remembered items. You're also told on login when a new version is out.

## Development

Edit `src/Oven.lua`, bump `M.version`, then run `python3 build.py` and commit
`src/Oven.lua`, `Oven.mpackage` and `VERSION`.
