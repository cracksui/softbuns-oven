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
| `score` | Your score, reorganised: level and exp-to-level first. This also teaches the prompt bar your max HP / SP / ST. |
| `eq` | Your equipment as a table, with armor and weapon breakdowns. |
| `look <something you wear>` | The item's stats, laid out. Do this for your worn gear once — Oven remembers it, so later items are compared against what you wear. |
| `sbo config bar on` | Moves your prompt into a fixed bar under the text, with gauges, your level and exp to level. |
| `sbo` | The full list of commands. |

Formatted output appears in the main window **and** in a floating **Inspector** window, which shows
the latest result with clickable **◀ older / newer ▶** lines to step back through the last 30.
Drag it by its title bar and resize it from its edges; it remembers where you put it.

---

## What gets baked

Commands work with the same abbreviations the game accepts (`eq`, `equ`, `equipment`…), and through your own
aliases in the game (`alias qr quest request`): Oven reads your alias list quietly once per session and follows
your `alias` / `unalias` changes, so `qr` is a quest request to Oven too.

Results open in the **Inspector** window, which has four tabs: **Inspector** (eq, items, score, comparisons,
with ◀ older / newer ▶), **Help** (game help pages and `sbo`'s command list), **Log** (`sbo log session`, `kills`,
`loot`, `deaths`, with links between them) and **Chat**. Whatever arrives brings its tab to the front (`sbo config tabs.auto off`
leaves you where you are and marks the tab with a •) - except chat, which never takes the window from you: the tab counts what you haven't read (`Chat (3)`).

**Chat** collects channel talk (`[CLAN] Name: '...'` and the channel's news, NOVICE), yells, shouts,
announcements, hints (`Local Hint: ...`), tells and says, in the game's own colours, with the time. Type
`channel` once so Oven knows the game's channel names. A row of chips along the top - `All · CLAN 2 · Tells` - picks what to show; each channel
gets its chip the first time it speaks, and its count is what you haven't read. Right-click a chip (or
`sbo chat mute clan`) to keep a channel out of All; click it to read it on its own. The main screen is unchanged.

| Command | Becomes |
|---|---|
| `eq` | slot table with short slot names, empty slots marked, and each item's AR and affects (from items you've looked at); armor table with the weakest location highlighted, defenses, weapon damage breakdown |
| `look` / `examine` / `identify` an item | stat grid, keywords, flags, affects, relics, weapon block, description |
| `ex` / `look` a creature | its description, then what it is using |
| `i`, `look in <container>` | one item per row, stack counts, capacity footer |
| `score` | level, exp to level and how long the next level will take at this session's pace; vitals and attribute gauges, standing, kill record |
| `aff` | resistances, spell and racial affects with their modifiers |
| `level` | exp needed for each upcoming level, what's still to go and how long it'll take at this session's pace |
| `skills spells`, `skills prof` | one row per skill: ★ class-recommended, school/type, SP, complexity, a learned gauge |
| `quest info` / `quest status` | your quests with progress gauges and next phase; a quest's page with levels, master, rewards, story and phases (✓ done, ▶ next) |
| `train` | attributes and vitals with current/max gauges, practice cost, and how many times you can afford each |
| `prac` / `prac all` at a trainer | every skill the trainer lists, one row each with a learned gauge, sorted by progress; ★ class-recommended skills, called out on top |
| `help <topic>` | the help page opens in the Inspector's **Help** tab, exactly as the game sends it |

## Quest tracker

Pin quests to an MMO-style **quest HUD** - a small translucent panel in the top corner of the game
screen - drag it anywhere (`sbo window reset` puts it back, `sbo config quest.side left|right` picks the
corner, `sbo config quest.opacity 0-100` how see-through it is): click **pin** under `quest info`
(or `sbo quest pin <id>` / `sbo quest pin all`, which quietly checks `quest info` and pins the unfinished quests it lists). A quest you take with `quest request` is pinned for you (`sbo quest autopin off` to stop). Each pinned quest shows its progress and its steps
(done ones greyed out, the next one marked ▶; they update as you finish them) - `sbo config quest.blurb on` adds the quest's description, which often
holds hints - updates whenever the game shows that quest, and re-checks quietly when you click it
(or `sbo quest refresh`). When Oven can place the next step - an NPC it has seen, a creature you've
killed somewhere, or a room on the map by name - the HUD shows where (green: the room the game names for that step; orange: one Oven found itself, a good guess),
and **`sbo quest go`** runs you there. A finished quest shows ✓ complete (and who to return to) and stays until you turn it in with `quest
complete` - then it comes off the HUD by itself (or click it to clear it sooner). Abandoned quests unpin themselves as soon as the game reports it.

Quests with a time limit show the time left next to their name on the quest panel (orange under 30
minutes, red under 10), and the prompt bar shows the one running out soonest (`quest 8h16m`). The game
gives limits in Alyrian minutes; one is 15 real seconds.

The game's `where is` only points at things in the area you're in. Oven remembers each answer as a
room (following the directions on the map), so `sbo go food` works from anywhere; for something it
hasn't found yet, it asks the game (walking to the right area first, if another area has it). While
you're idle it also learns each area's features by itself, one question at a time
(`sbo config map.wherelearn off` to stop).

## Comparing gear

Every item you look at is remembered (it survives logging out). Items, loot, kills, deaths and what's
in each room are kept in a database in your profile folder (`oven.db`), so nothing has to be capped.

- **Automatic:** look at an item and it's compared with whatever you wear in that slot
  (run `eq` and look at your worn item once so Oven knows it).
- **Pin one item:** `sbo eq compare against <name>` (or click **pin for comparing** under an item in the
  Inspector) — everything you look at next is compared against it. Handy in shops. `sbo eq compare against` stops.
- **Any two:** `sbo compare` compares the last two items you looked at;
  `sbo compare hook vs dagger` compares any two remembered items by part of their names.
- `sbo eq items` lists what Oven remembers.
- `sbo eq learn worn` looks at every worn item Oven doesn't know yet (the `?` in `eq`) in one go, quietly,
  then shows your `eq` again with their stats filled in.
- `sbo eq learn carried` does the same for everything you carry, then looks inside each container (bags,
  backpacks) and at what's in them, and shows your inventory again. If the game won't let Oven look at an
  item while it's in a container, it says so after the first try and skips the rest.

Green marks the better value in each row.

**Gear score.** Every worn item gets a score from your **build**: each stat times how much it matters
to you (+1 strength might count 3, +1 hp 0.2). Looking at an item shows its score against what you wear
there (`+5.5 (+31%) upgrade`), comparisons start with it and end with a **score breakdown** (each
stat's points, as value × weight, for both items), and `sbo upgrades` lists, slot by slot, the
best item you carry (your last `i`, and inside the bags you've looked in) that beats your gear - `sbo upgrades
all` searches every item you've ever looked at, shops included. Each suggestion says what makes the difference
(`+6 ar · −2.2 hp`); click it (or `sbo upgrades 2`) for the full comparison. The build starts from your class (Materia Magica's 16 classes each map to monk, melee, caster, healer,
thief, tank or paladin - and Oven reads `help classes` to place any it doesn't know by their group); `sbo eq build` shows the weights, `sbo eq build set strength 4` changes one, `sbo eq build pvp`
makes and switches to a new build, `sbo eq build reset` / `sbo eq build auto` go back. Stats already at their
maximum in `score` (Strength 20/20) count a quarter, since more of them is mostly wasted; `sbo eq build` shows
where each stat stands and, once you've read your race's help page, your race's maximums. Race pages'
weapon bonuses count too (a dwarf's +10% with bashing weapons makes a maul score higher; where a page
names no number, 10% is assumed - `sbo eq build set weapon:staff 20` sets your own). Your race's built-in
weaknesses, which the game reports as you log in (a sahuagin's *maladapted*: disease resistance -25), make
matching resistances on gear count for more.

## What Oven reads from the game's data (GMCP)

Materia Magica sends some things as data alongside the text, and Oven uses that wherever it can: your level and
exp to level (the bar stays current without `score`), your HP/SP/ST as they change (the bar's gauges move
mid-fight, between prompts) and their maximums, attribute maximums, quest steps as you finish them, room flags, the exact
target room of quest steps (`sbo quest go`), the creature you're fighting (kills are stored with its mob number and
race, deaths with what you were fighting) and your race's built-in weaknesses. With the game's `combat mode mxp` (combat text replaced by data, see `help combat`),
Oven shows a line above the prompt bar while you fight - each target's health bar and name, and with one target
how the fight's going - and draws one line per round in the game text (your hits and misses and theirs, out of
reach) with a summary when the fight ends (`sbo config combat.bar off` / `combat.lines off`, or `sbo config combat off` for both). What GMCP doesn't send - mail,
your group's lowest health, mount stamina - still comes from the prompt.

## Commands

Every part of the screen has one word, used for its command, its title and its settings: the
**inspector**, **help**, **log**, **chat** and **notes** tabs, the **quest** panel and the **map** panel. The word on
its own opens that part (`sbo log` opens the Log tab, `sbo map` the map panel); `sbo help {word}` lists
its commands. Every setting lives under `sbo config`, named after the part it changes (`chat.mirror`,
`quest.opacity`, `bar.width`).

Any start of a word works when only one command starts that way, like the game's own `que re`:
`sbo e up` is `sbo eq upgrades`, `sbo conf bar.w 12` is `sbo config bar.width 12`. When a start fits
more than one (`sbo co`: compare or config), Oven lists them rather than guessing. `oven` works as
well as `sbo`.

```
sbo                          the menu
sbo go {what}                walk/run to a trainer, shop, quest, NPC, room #,
                             bookmark, or a "where is" feature (food, bank…);
                             signpost runs when quicker
sbo stop                     stop a walk, or anything Oven is doing for you

sbo eq                       equipment and items (shown in the Inspector)
    compare [{a} vs {b}]     the last two items looked at, or two by name
    compare against [{item}] compare every look to one item; no item: stop
    upgrades [all|{n}]       best upgrade per slot; n: its full comparison
    learn [worn|carried]     look at items Oven doesn't know (both if left off)
    items                    the items Oven remembers
    build [{name}|set|reset|auto]   gear-score weights

sbo quest                    the quest panel
    pin {id|all}             onto the panel
    unpin {id|all}
    go [{id}]                to the next step
    refresh [{id}]           re-check pinned quests

sbo map                      the map panel, centred on you
    find {what|#}            NPCs, tags, rooms, nearest first (#: centre the map)
    shops [{item}]           shops you've listed, or who sells an item
                             (a shop is listed by itself when you stop in it)
    signposts                signpost runs and where each ends
    mark [{name}]            bookmark this room; no name: list them
    unmark {name}
    highlight [{what}]       light up every room with it (a traveler's path, trainers…);
                             "trainer in rune" narrows to an area; nothing: clear
    load [{file}]            load a map file

sbo inspector                the Inspector tab
    clear                    empty its history

sbo log                      the Log tab
    kills                    what you've killed, counts and exp
    loot [{text}]            pickups and where; text searches
    deaths                   recent deaths, with what led up to them
    session                  exp/hour, time and kills to the next level
    reset                    start a fresh session
    clear kills|loot         wipe all-time history (asks first)

sbo chat [{channel}|all]     the Chat tab
    mute / unmute {channel}  keep a channel out of All
    remove {channel}         drop a channel's chip
    clear                    empty the Chat tab

sbo notes                    the Notes tab: notes you keep, each with the room you
                             wrote it in ([go] walks back); type in its box + Enter
    add {text}               keep a note
    find {text}              only the notes with it
    remove {n}               remove note number n

sbo help [{word}|all]        the Help tab: the menu, one word's commands, or all

sbo window                   where the panels sit
    restore                  back where you put them
    reset                    back to the defaults

sbo version                  the version you have
    update [force|{file}]    get the newest (force: reinstall; or a local .mpackage)

sbo debug
    raw                      the last output as the game sent it
    gmcp                     what the game sends over GMCP
    samples on|off           log raw output to oven_samples.txt
    record start [{minutes}] record everything to oven_record.txt
    record stop
    record save [{note}]     save the last few hundred blocks

sbo config                   every setting, grouped, with its value
sbo config {name} {value}    change one (sbo set works too)
```

Shortcuts: `sbo compare` and `sbo upgrades` work without `eq`.

### Settings (`sbo config`)

```
Display        formatting on|off · main replace|keep · window on|off · tabs on|off
               tabs.auto on|off · font {n}
Inspector tab  inspector.mirror on|off
Help tab       help.window on|off · help.mirror on|off
Log tab        log.mirror on|off
Chat tab       chat.mirror on|off
Quest panel    quest.hud on|off · quest.autopin on|off · quest.blurb on|off
               quest.side left|right · quest.opacity 0-100
Map panel      map on|off · map.panel on|off · map.card on|off · map.shoplist on|off
               map.wherelearn on|off
               signposts.look on|off
Prompt bar     bar on|off · bar.mode gauges|raw · bar.session on|off · bar.session.style full|short
               bar.session.place top|bottom · bar.width {n} · bar.lines {n} · bar.font {n}
               bar.bg {r g b} · bar.blanks on|off
Combat bar     combat on|off · combat.bar on|off · combat.lines on|off
Equipment      eq.autocompare · eq.pickuplook · eq.stats · eq.empty · eq.donation (on|off)
               eq.slots short|full · eq.gamecolors on|off
Updates        update.auto on|off · record.window {n} · prompt {pattern}
```

`*.mirror` also shows that tab's output on the main screen. A number setting goes back to its default
with `default` (`sbo config bar.width default`).

Older commands (`sbo run`, `sbo eqstats off`, 0.51's `sbo gear` and `sbo places`…) still work; the first
time you use one, Oven tells you its new form.

## Updating

Type **`sbo version update`** (or click the version tag at the right end of the prompt bar). Oven checks this page for a newer version and installs it, keeping your
settings and remembered items. You'll also get a one-line notice when you log in if an update
is out. `sbo version update force` reinstalls even if you're current.

Want it hands-free? **`sbo config update.auto on`** checks every couple of minutes and installs new
versions by itself.

## Troubleshooting

- **Nothing is formatted.** Check you installed into the profile you're playing (Toolbox →
  Package Manager should list *Oven*), and that `sbo config formatting on` is set. Type `sbo` to see the current
  settings.
- **A layout looks wrong or something is missing.** Type `sbo debug raw` to see exactly what the game
  sent. Very short replies (one line) are left untouched on purpose.
- **The Inspector window disappeared.** `sbo config window on`. If it's off-screen, drag it back by its title
  bar or resize the Mudlet window.
- **The prompt bar overlaps something or looks off.** `sbo config bar off` puts the prompt back in the
  text. `sbo config bar.mode raw` shows the prompt as the game sends it instead of gauges.
- **Level / exp to level on the bar is out of date.** It's taken from your last `score`; type
  `score` to refresh it.
- **`sbo version update` says the download failed.** Check your internet connection, or reinstall by hand
  (step 3 above) — your settings are kept either way.

## Removing it

**Toolbox → Package Manager**, select *Oven*, click **Uninstall**. Your settings and remembered
items stay in your Mudlet profile folder (`oven_*.lua`) in case you reinstall; delete those files
too if you want a completely clean slate.

---

## Development

Source is `src/Oven.lua`. Game output is read in **blocks** (everything up to a prompt, with the commands that
caused it, the GMCP that changed and each line's colour). Recognisers registered with `M.addBlockKind` decide what a
block is (`room`, `help`...); readers registered with `M.addBlockReader(name, kind, fn)` only see blocks of their
kind - e.g. room NPCs are read only from room views whose name matches GMCP's `room.info`.

**Tests:** `pip install lupa`, then `python3 tests/run.py`. They load Oven under Lua 5.1 (what Mudlet runs) with
Mudlet stubbed out and replay recorded game output (`tests/fixtures`) through it: room views, help pages, kills,
loot, GMCP, the recorder, updates, and an in-session upgrade from the previous version. Fixtures come from
`sbo debug record save` recordings with other players renamed and chat and private GMCP left out - never commit a raw
recording.

**Releasing:** bump `M.version` in `src/Oven.lua`, run `python3 build.py` (runs the tests and won't build if any
fail, then writes `Oven.mpackage` and `VERSION`), commit all three and push. Players get it with `sbo version update`.

MIT licensed — see [LICENSE](LICENSE).
