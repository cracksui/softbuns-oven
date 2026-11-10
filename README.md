# Soft Bun's Oven (`sbo`)

*by softbuns* — raw Materia Magica output goes in, baked output comes out.

Soft Bun's Oven is a package for the [Mudlet](https://www.mudlet.org/) client that turns
Materia Magica's walls of text — `eq`, item looks, `score`, `aff`, your inventory — into clean,
aligned, colour-highlighted layouts. It also remembers gear you look at so you can compare it,
and can move your prompt into a status bar with HP / SP / ST gauges.

```
── a venomous hook ──────────────────────────────────────────
Type       weapon                Level      13
Worn       wielded as a weapon   Align      50
Weight     0 st 12 pb            Value      4,425 gold
Special    poisoned
Grants     parry 100%  move to block a weapon with your weapon

▸ Weapon
Damage    High pierce   Accuracy  Low
Range     Min           Crit      Max (2x)
```

---

## First-time install

### 1. Get Mudlet

Download and install Mudlet from **https://www.mudlet.org/download/** (version 5 or newer).

### 2. Connect to Materia Magica

1. Start Mudlet. The **Connect** window opens.
2. If Materia Magica is in the list, pick it. Otherwise click **New** and fill in:
   - **Profile name:** `Materia Magica`
   - **Server address:** `materiamagica.com`
   - **Port:** `23`
3. Click **Connect** and log in to your character.

### 3. Install Soft Bun's Oven

**Option A — one line (easiest).** While connected, copy this line, paste it into Mudlet's
command bar (where you type game commands) and press Enter:

```
lua installPackage("https://raw.githubusercontent.com/cracksui/softbuns-oven/main/Oven.mpackage")
```

**Option B — by hand.**

1. Download **[Oven.mpackage](../../raw/main/Oven.mpackage)** (or open `Oven.mpackage` in the file
   list above and click the **↓ Download raw file** button).
2. In Mudlet, open **Toolbox → Package Manager**, click **Install**, and choose the file you
   downloaded. (Dragging the file onto the Mudlet window works too.)

When it's installed you'll see:

```
[Soft Bun's Oven] v0.7.0 by softbuns :: preheated :: raw stream in, baked output out :: type sbo for commands
```

The package is installed into the profile you have open, so if you play several characters in
separate profiles, install it in each.

### 4. Your first five minutes

| Type this | What happens |
|---|---|
| `sbo test` | Shows a demo, so you can see what the layouts look like. |
| `score` | Your score, reorganised: level and exp-to-level first. This also teaches the prompt bar your max HP / SP / ST. |
| `eq` | Your equipment as a table, with armor and weapon breakdowns. |
| `look <something you wear>` | The item's stats, laid out. Do this for your worn gear once — Oven remembers it, so later items are compared against what you wear. |
| `sbo bar on` | Moves your prompt into a fixed bar under the text, with gauges, your level and exp to level. |
| `sbo` | The full list of commands. |

Formatted output appears in the main window **and** in a floating **Inspector** window, which shows
the latest result with clickable **◀ older / newer ▶** lines to step back through the last 30.
Drag it by its title bar and resize it from its edges; it remembers where you put it.

---

## What gets baked

Commands work with the same abbreviations the game accepts (`eq`, `equ`, `equipment`…).

| Command | Becomes |
|---|---|
| `eq` | slot table with short slot names, empty slots marked, and each item's AR and affects (from items you've looked at); armor table with your weakest location, defenses, weapon damage breakdown |
| `look` / `examine` / `identify` an item | stat grid, keywords, flags, affects, relics, weapon block, description |
| `ex` / `look` a creature | its description, then what it is using |
| `i`, `look in <container>` | one item per row, stack counts, capacity footer |
| `score` | level, exp to level and how long the next level will take at this session's pace; vitals and attribute gauges, standing, kill record |
| `aff` | resistances, spell and racial affects with their modifiers |
| `level` | exp needed for each upcoming level, what's still to go and how long it'll take at this session's pace |
| `help <topic>` | the help page opens in its own **help window**, exactly as the game sends it |

## Comparing gear

Every item you look at is remembered (it survives logging out).

- **Automatic:** look at an item and it's compared with whatever you wear in that slot
  (run `eq` and look at your worn item once so Oven knows it).
- **Pin one item:** `sbo pin <name>` (or click **pin for comparing** under an item in the
  Inspector) — everything you look at next is compared against it. Handy in shops. `sbo unpin` stops.
- **Any two:** `sbo compare` compares the last two items you looked at;
  `sbo compare hook vs dagger` compares any two remembered items by part of their names.
- `sbo items` lists what Oven remembers.

Green marks the better value in each row.

## Commands

```
sbo                       list of commands
sbo test                  demo
sbo on|off                turn formatting on / off
sbo main replace|keep     replace the raw text in the main window, or leave it alone
                          (keep = formatted output only in the Inspector)
sbo window on|off         show / hide the Inspector window
sbo clear                 clear the Inspector's history
sbo font [size]           Inspector / help window font size (leave the number off for the default)
sbo raw                   reprint the last output exactly as the game sent it
sbo compare / pin / unpin / items / autocompare on|off     gear comparison (see above)
sbo session [reset]       exp gained, exp/hour, time and kills to next level
sbo gamecolors on|off     keep the game's own colours on item names
sbo eqstats on|off        AR / affects column in eq (look at an item once to fill it in)
sbo empty on|off          show empty slots in eq
sbo donation on|off       show / hide empty donation-only slots (amulet, face, aura)
sbo slots short|full      short slot names in eq tables, or the game's full ones
sbo helpwindow on|off     game help pages (and the sbo command list) in their own window
sbo bar on|off            prompt bar
sbo bar gauges|raw        prompt bar as gauges, or the prompt exactly as the game sends it
sbo bar session on|off    session time, kills/deaths and exp per hour - on the bar when it fits, else their own line
sbo bar session full|short  time · k/d · xp/hr, or just xp/hr
sbo bar session top|bottom  where that line goes: top of the screen (default) or under the bar
sbo bar bg [r g b]        prompt bar background colour, 0-255 each (no numbers = default)
sbo bar blanks on|off     keep / remove the blank line before each prompt (removed by default)
sbo bar width [n]         length of each gauge (default 10)
sbo bar lines [n]         prompt bar height
sbo bar font [n]          prompt bar font size (0 or no number = same as the main window)
sbo update                get the newest version
sbo update auto on|off    install new versions automatically
```

Any number setting goes back to its default if you leave the number off (e.g. `sbo bar width`).

`oven` works as well as `sbo`.

## Updating

Type **`sbo update`**. Oven checks this page for a newer version and installs it, keeping your
settings and remembered items. You'll also get a one-line notice when you log in if an update
is out. `sbo update force` reinstalls even if you're current.

Want it hands-free? **`sbo update auto on`** checks every couple of minutes and installs new
versions by itself.

## Troubleshooting

- **Nothing is formatted.** Check you installed into the profile you're playing (Toolbox →
  Package Manager should list *Oven*), and that `sbo on` is set. Type `sbo` to see the current
  settings.
- **A layout looks wrong or something is missing.** Type `sbo raw` to see exactly what the game
  sent. Very short replies (one line) are left untouched on purpose.
- **The Inspector window disappeared.** `sbo window on`. If it's off-screen, drag it back by its title
  bar or resize the Mudlet window.
- **The prompt bar overlaps something or looks off.** `sbo bar off` puts the prompt back in the
  text. `sbo bar raw` shows the prompt as the game sends it instead of gauges.
- **Level / exp to level on the bar is out of date.** It's taken from your last `score`; type
  `score` to refresh it.
- **`sbo update` says the download failed.** Check your internet connection, or reinstall by hand
  (step 3 above) — your settings are kept either way.

## Removing it

**Toolbox → Package Manager**, select *Oven*, click **Uninstall**. Your settings and remembered
items stay in your Mudlet profile folder (`oven_*.lua`) in case you reinstall; delete those files
too if you want a completely clean slate.

---

## Development

Source is `src/Oven.lua`. To release: bump `M.version` in it, run `python3 build.py` (writes
`Oven.mpackage` and `VERSION`), and commit all three. Players get it with `sbo update`.

MIT licensed — see [LICENSE](LICENSE).
