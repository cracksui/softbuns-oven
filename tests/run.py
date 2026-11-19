#!/usr/bin/env python3
"""Oven's tests: load src/Oven.lua under Lua 5.1 (what Mudlet runs) with Mudlet stubbed out, and
replay recorded game output through it.

    pip install lupa
    python3 tests/run.py            # all tests
    python3 tests/run.py rooms kills   # only tests whose names contain one of these words

Fixtures in tests/fixtures are excerpts of `sbo record save` recordings, cleaned up: other players
renamed, chat and private GMCP (quests, gold) left out. Never commit a raw recording.
"""
import os, re, subprocess, sys, tempfile, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "stubs"))
import sql as stub_sql
from lupa import lua51

SRC = open(os.path.join(ROOT, "src", "Oven.lua"), encoding="utf-8").read().replace("@@REPO@@", "x/y")
STUBS = open(os.path.join(HERE, "stubs", "mudlet.lua"), encoding="utf-8").read()


def fixture(name):
    return os.path.join(HERE, "fixtures", name)


class Oven:
    """A fresh Lua 5.1 runtime with Oven loaded, its profile folder a new temp dir."""

    def __init__(self, before="", src=SRC, prev=None):
        self.home = tempfile.mkdtemp(prefix="oven_test_")
        os.chdir(self.home)
        self.L = lua51.LuaRuntime(unpack_returned_tuples=True)
        stub_sql.install(self.L)
        self.L.globals().OVEN_TEST_HOME = self.home
        self.L.execute(STUBS)
        if not os.environ.get("VERBOSE"):   # what Oven would show in Mudlet; VERBOSE=1 to see it
            self.L.execute("io.write = function() end; print = function() end")
        self.L.execute("gmcp = {}")
        if before:
            self.L.execute(before)
        if prev:
            self.L.execute(prev)
        self.L.execute(src)
        # as if the session's alias list had been read (game_aliases tests that part)
        self.L.execute("sbo.cfg.samples = false; sbo.aliasesAsked = true")
        self.sbo = self.L.globals().sbo

    def lua(self, code):
        return self.L.execute(code)

    def ev(self, expr):
        return self.L.eval(expr)

    def rows(self, q):
        t = self.L.eval('sbo.dbRows([[%s]])' % q)
        return [dict(r.items()) for r in t.values()]

    def set_gmcp(self, name, val):
        self.L.eval('''function(name, val)
          local top, sub = name:match("^([^.]+)%.?(.*)$")
          local f = loadstring("return " .. val); local v = f and f()
          gmcp[top] = gmcp[top] or {}
          if sub == "" then gmcp[top] = v else gmcp[top][sub] = v end
        end''')(name, val)

    def block(self, lines, cmds=(), fg=None):
        """One block through the pipeline; returns the kinds it was recognised as."""
        f = self.L.eval('''function(lines, cmds, fg)
          local b = { lines = {}, cmds = {}, prompt = true, fg = {} }
          for k, v in pairs(fg or {}) do b.fg[k] = v end
          for i = 1, #lines do b.lines[i] = lines[i] end
          for i = 1, #cmds do b.cmds[i] = cmds[i] end
          local names = {}
          for n in pairs(sbo.onBlock(b)) do names[#names + 1] = n end
          table.sort(names)
          return table.concat(names, ",")
        end''')
        return f(self.L.table_from(list(lines)), self.L.table_from(list(cmds)), self.L.table_from(fg or {}))

    def replay(self, path):
        """Every block of a recording, GMCP replayed alongside; returns the kinds, one per block."""
        out = []
        for b in read_recording(path):
            for n, v in b["gmcp"]:
                self.set_gmcp(n, v)
            out.append(self.block(b["lines"], b["cmds"], b["fg"]))
        return out

    def feed(self, *lines):
        """Lines as Mudlet hands them to the line trigger."""
        for l in lines:
            self.L.globals().line = l
            self.L.eval("sbo.onLine()")


def read_recording(path):
    raw = open(path, encoding="utf-8").read().split("\n")
    out, cur, i = [], None, 0
    while i < len(raw):
        l = raw[i]
        if l.startswith("===== "):
            cmds = l.split("cmd=")[1].split(" | room=")[0].split(" ; ")
            cur = {"cmds": [c.strip() for c in cmds if c.strip()], "gmcp": [], "lines": [], "fg": {}}
            out.append(cur)
        elif l.startswith("#####"):
            cur = None
        elif cur is not None and l.startswith("@gmcp "):
            while l.endswith("\\") and i + 1 < len(raw):
                i += 1
                l += "\n" + raw[i]
            name, val = l[6:].split(" = ", 1)
            cur["gmcp"].append((name, val))
        elif cur is not None and l.startswith("@fg "):
            for run in l[4:].split():
                rng, c = run.split("=")
                a, _, b = rng.partition("-")
                for k in range(int(a), int(b or a) + 1):
                    cur["fg"][k] = c
        elif cur is not None:
            cur["lines"].append(l)
        i += 1
    for b in out:
        while b["lines"] and b["lines"][-1] == "":
            b["lines"].pop()
    return out


def eq(got, want, what=""):
    if got != want:
        raise AssertionError(f"{what}: expected {want!r}, got {got!r}")


# --------------------------------------------------------------------------------------------
TESTS = []
def test(f):
    TESTS.append(f)
    return f


@test
def lua51_syntax():
    L = lua51.LuaRuntime()
    ok, err = L.eval("function(s) local f, err = loadstring(s, 'Oven.lua') return f ~= nil, err end")(SRC)
    assert ok, f"Lua 5.1 can't load Oven.lua: {err}"


@test
def commands_run():
    o = Oven()
    for c in ["", "session", "deaths", "record window", "kills", "gear"]:
        o.lua(f'sbo.command("{c}")')


@test
def formatters_on_samples():
    # samples/ holds raw captures with names in them, so it stays local; skipped elsewhere
    path = os.path.join(ROOT, "samples", "captures-2026-11-09.txt")
    if not os.path.exists(path):
        return "skipped (no local samples)"
    o = Oven()
    txt = open(path, encoding="utf-8").read()
    caps = re.findall(r"===== .*?kind=(\w+) \| cmd=(.*?)\n(.*?)\n===== end", txt, re.S)
    for kind, cmd, body in caps:
        r = o.sbo.format(kind, "", o.L.table_from(body.split("\n")), 80)
        assert r is not None, f"formatter failed for {cmd}"
    return f"{len(caps)} captures"


@test
def rooms_real_walk():
    o = Oven()
    kinds = o.replay(fixture("rooms.txt"))
    views = sum(1 for k in kinds if "room" in k.split(","))
    assert views >= 25, f"only {views} room views recognised"
    npcs = sorted((r["room"], r["tags"], r["text"]) for r in o.rows("SELECT room, tags, text FROM room_npcs"))
    texts = sorted(t for _, tg, t in npcs)
    eq(sorted(tg for _, tg, _ in npcs), ["Boss", "Shop", "Trainer", "Trainer"], "NPC tags")
    assert not any("Pip" in t or "Wren" in t or "Ashby" in t for t in texts), f"a player saved as an NPC: {texts}"
    return f"{views} room views, {len(npcs)} NPCs"


@test
def quest_phase_counter():
    o = Oven()
    f = o.ev("function(t) local p = sbo.phaseFromText(t) return p.text .. '|' .. tostring(p.done) .. '|' .. tostring(p.area) end")
    eq(f("[10/10] *Collect ten fallen leaves from the Oak from the forest floors."),
       "Collect ten fallen leaves from the Oak from the forest floors (10/10)|true|nil", "counter first, then the done star")
    eq(f("[3/10] Collect ten fallen leaves [Rune Forest]"), "Collect ten fallen leaves (3/10)|false|Rune Forest", "with an area")
    # "fallen leaves from" isn't someone leaving: the line stays in the quest's reply
    o.lua("sbo.cap = { kind = 'quest', questStarted = true, plain = {} }")
    eq(o.ev("sbo.belongs(sbo.cap, 'Phase 4: [10/10] *Collect ten fallen leaves from the Oak from the forest floors.')"), True, "belongs")


@test
def friends_where():
    me, pal = Oven(), Oven()
    for o in (me, pal):
        o.lua("""SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
          SENT = {}; send = function(c) SENT[#SENT+1] = c; sbo.onSend(nil, c) end
          GAGGED = 0; deleteLine = function() GAGGED = GAGGED + 1 end
          gmcp.char = { status = { state = "playing" } }
          sbo.lastStatusPrompt = "<281hp 696sp 457st>"
          roomExists = function(id) return tonumber(id) == 10522 or tonumber(id) == 10438 end
          getRoomName = function(id) return "Garden of Life" end
          getRoomArea = function() return 1 end; getRoomAreaName = function() return "Towne of Rune" end
          WALK = nil; sbo.mapWalkTo = function(id) WALK = id end""")
    pal.lua('sbo.mapRoom = 10522')
    me.lua('sbo.mapRoom = 10438')
    # not a friend yet: told no, and Pal sees that someone asked
    me.lua('sbo.command("go @pal")')
    ask = me.ev("SENT[#SENT]")
    assert ask.startswith("tell pal ") and any(x in ask for x in ["Where you at, bro??", "where u at", "where you at"]), ask
    nonce = ask.split("#")[-1]
    pal.feed(f"Me tells you '{ask[9:]}'")
    pal.lua("runTimers()")
    eq(pal.ev("GAGGED"), 1, "the asking tell is kept off Pal's screen")
    no = pal.ev("SENT[#SENT]")
    assert no.startswith("tell me ") and no.endswith(f" #{nonce}"), no
    eq(pal.ev(f"(sbo.wireParse({no[8:]!r}))"), "no", f"a non-friend is told no: {no}")
    assert any("asked where you are" in x for x in pal.ev("SAYS").values()), "Pal is told someone asked"
    me.feed(f"Pal tells you '{no[8:]}'"); me.lua("runTimers()")
    assert any("hasn't added you" in x for x in me.ev("SAYS").values()), list(me.ev("SAYS").values())
    eq(me.ev("WALK"), None, "no walk")
    # friends: the room comes back and Oven walks there
    pal.lua('sbo.command("friend add me"); SENT = {}; sbo.friendAnswered = {}')
    me.lua('sbo.command("friend add pal"); SAYS = {}; sbo.command("go pal")')
    nonce = me.ev("SENT[#SENT]").split("#")[-1]
    sent = me.ev("SENT[#SENT]")[9:]
    me.lua("GAGGED = 0"); me.feed(f"You tell Pal '{sent}'")
    eq(me.ev("GAGGED"), 1, "your own tell is hidden too")
    pal.feed(f"Me tells you '{sent}'"); pal.lua("runTimers()")
    at = pal.ev("SENT[#SENT]")
    assert "Garden of Life" in at and at.endswith(f"(room 10522) #{nonce}"), f"a friend is told the room: {at}"
    me.feed(f"Pal tells you, '{at[8:]}'"); me.lua("runTimers()")
    eq(me.ev("WALK"), 10522, "walks to Pal")
    # a stale or made-up answer does nothing
    me.lua("WALK = nil; GAGGED = 0"); me.feed("Pal tells you 'at the Bank rn (room 10438) #beef'"); me.lua("runTimers()")
    eq(me.ev("WALK"), None, "only answers to what was asked")
    # an ordinary tell stays on screen
    me.lua("GAGGED = 0"); me.feed("Pal tells you 'meet me at #3 bank'"); me.feed("Pal tells you 'where are you?'")
    eq(me.ev("GAGGED"), 0, "people's own tells are never hidden")
    # an Oven that hasn't updated yet still understood
    me.lua('sbo.command("friend where pal")'); n2 = me.ev("SENT[#SENT]").split("#")[-1]
    me.lua("SAYS = {}"); me.feed(f"Pal tells you '#oven at {n2} 10522'"); me.lua("runTimers()")
    assert any("Garden of Life" in x for x in me.ev("SAYS").values()), list(me.ev("SAYS").values())
    # offline
    me.lua('SAYS = {}; sbo.command("friend where pal")'); me.feed("They aren't here."); me.lua("runTimers()")
    assert any("isn't online" in x for x in me.ev("SAYS").values()), list(me.ev("SAYS").values())
    # nothing is sent outside the game
    me.lua('gmcp.char.status.state = "login"; SENT = {}; sbo.lastStatusPrompt = nil; sbo.lastPromptText = nil; sbo.command("go pal")')
    eq(len(list(me.ev("SENT").values())), 0, "not in the game: nothing sent")


@test
def mobs_seen():
    o = Oven()
    o.replay(fixture("rooms.txt"))
    rows = o.rows("SELECT room, ok, text FROM room_mobs")
    texts = [r["text"] for r in rows]
    assert "A salesman is here, peddling his wares." in texts, texts
    assert not any("Pip" in t or "Wren" in t or "Ashby" in t or t.startswith("You ") for t in texts), texts
    eq(sorted(r["name"] for r in o.rows("SELECT name FROM players")), ["ashby", "pip", "wren"], "players from their clan tags")
    f = o.ev("function(x, fg) local t, ok = sbo.mobLine(x, fg) return tostring(t) .. '|' .. tostring(ok) end")
    eq(f("A stray dog is here, wandering about forlornly.", "0,255,0"), "A stray dog is here, wandering about forlornly.|1", "green, an article")
    eq(f("A risen paladin enters into combat with Roarke.", "255,255,0"), "nil|nil", "not a creature's colour")
    eq(f("Sathan is here, guarding the eastern gate of Rune.", "0,255,0"), "Sathan is here, guarding the eastern gate of Rune.|1", "a named mob")
    eq(f("Moss the Brave is here.", "0,255,0"), "Moss the Brave is here.|0", "reads like a player: waits")
    eq(f("A barghest is here, fighting Moss. [92%]", "0,255,0"), "nil|nil", "mid-fight")
    eq(f("[Shop] A grocer stands here.", "0,255,0"), "nil|nil", "tagged: room_npcs")
    # the unconfirmed one: confirmed once you target it
    o.lua("""sbo.currentRoom = function() return 10522 end
      sbo.dbx("INSERT INTO room_mobs (room, key, text, seen, last, ok) VALUES (10522, 'moss the brave is here.', 'Moss the Brave is here.', 1, 1, 0)")""")
    eq(o.ev("#sbo.mobsFind('moss')"), 0, "not shown yet")
    o.set_gmcp("char.lasttargeted", '{ hp_percent = 100, race = "human", vnum = 4712, short_descr = "Moss the Brave" }')
    o.lua('sbo.onGmcpTarget()')
    eq(o.ev("sbo.mobsFind('moss')[1].race"), "human", "confirmed by GMCP")
    # found from the map: sbo go / map find / the search box
    o.lua("roomExists = function() return true end")
    targets = o.ev("(sbo.runTargets('salesman'))")
    assert any("salesman" in t.why for t in targets.values()), "runTargets finds it"
    # a name that turns out to be a player's is forgotten
    o.lua('sbo.notePlayer("Moss")')
    eq(o.ev("#sbo.mobsFind('moss')"), 0, "a player after all")
    o.lua('getRoomArea = function() return 1 end; getRoomAreaName = function() return "Towne of Rune" end; OUTV = nil; sbo.viewOut = function(l) OUTV = l end; sbo.command("map mobs salesman")')
    eq(o.ev("OUTV[2][1][2]"), "A salesman is here, peddling his wares.", "sbo map mobs lists it")


@test
def quest_targets():
    o = Oven()
    o.lua('roomExists = function() return true end; getRoomName = function(id) return "Room " .. id end; getRoomArea = function() return 1 end; getRoomAreaName = function() return "Towne of Rune" end')
    blocks = read_recording(fixture("quest_targets.txt"))
    def play(i):
        b = blocks[i]
        for n, v in b["gmcp"]: o.set_gmcp(n, v)
        if b["gmcp"]: o.lua("sbo.mapRoom = tonumber(gmcp.room.info.num)")
        o.block(b["lines"], b["cmds"], b["fg"])
    play(0)
    rows = o.rows("SELECT kind, key, room FROM quest_targets ORDER BY key")
    eq([(r["kind"], r["room"]) for r in rows], [("mob", 10522), ("mob", 10522)], "two [!] mobs")
    mob = o.rows("SELECT text, ok FROM room_mobs WHERE instr(key, 'a goblin') = 1")
    eq(mob, [{"text": "A goblin mercenary is here, hiding from the goblin slayer.", "ok": 1}], "saved as a mob, without the [!]")
    f = o.ev("function(x) local t, ok, w, q = sbo.mobLine(x, '0,255,0') return tostring(t) .. '|' .. tostring(q) end")
    eq(f("[!] Demonia, Knight Captain, stands here."), "Demonia, Knight Captain, stands here.|true", "a named one too")
    eq(f("[Shop] A grocer stands here."), "nil|nil", "other tags: room_npcs")
    play(0)   # the same room again: counted (an unconfirmed [!] one confirmed)
    eq(o.rows("SELECT seen FROM room_mobs WHERE room = 10522 AND instr(key, 'a master') = 1"), [{"seen": 2}], "seen again")
    play(1)   # the goblin again, no [!]: done with
    eq([r["key"] for r in o.rows("SELECT key FROM quest_targets")], ["a master necromancer is here, performing a dark ritual."], "unmarked: dropped")
    eq(o.ev("sbo.isTarget('mob', 'a goblin mercenary is here, hiding from the goblin slayer.')"), False, "memory agrees")
    o.lua("sbo.mapRoom = 10442"); play(2)
    eq(o.rows("SELECT key, holder, room FROM quest_targets WHERE kind = 'worn'"),
       [{"key": "an ebony shield", "holder": "samara, guardian of the crossing", "room": 10442}], "worn by a mob you look at")
    play(3)
    eq(o.rows("SELECT text, holder FROM quest_targets WHERE kind = 'shop'"), [{"text": "A shimmering white fish scale", "holder": "25 gold"}], "a shop's [!] item")
    eq(o.rows("SELECT COUNT(*) AS n FROM shop_items WHERE room = 10442")[0]["n"], 2, "and the [!] line is in its stock now")
    o.lua('OUTV = nil; OUTL = nil; sbo.viewOut = function(l, k) OUTV = l; OUTL = k end; sbo.command("map targets")')
    text = o.lua('local s = {} for _, r in ipairs(OUTV) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = "\\n" end return table.concat(s)')
    assert "worn by samara" in text and "fish scale" in text and "necromancer" in text, text
    # graded highlight: a roaming mob, brighter where seen more and lately; centred on the latest sighting
    o.lua("""HL = {}; highlightRoom = function(id, r1, g1, b1, r2, g2, b2, rad, a1, a2) HL[id] = a1 end; unHighlightRoom = function() end
      getPath = function() return false end; sbo.centerOn = function(id) CENTRE = id end
      sbo.dbx("INSERT OR REPLACE INTO room_mobs (room, key, text, seen, last, ok) VALUES (1, 'a janitor is here.', 'A janitor is here.', 40, %s, 1)", os.time() - 3600)
      sbo.dbx("INSERT OR REPLACE INTO room_mobs (room, key, text, seen, last, ok) VALUES (2, 'a janitor is here.', 'A janitor is here.', 1, %s, 1)", os.time() - 60 * 86400)
      sbo.dbx("INSERT OR REPLACE INTO room_mobs (room, key, text, seen, last, ok) VALUES (3, 'a janitor is here.', 'A janitor is here.', 2, %s, 1)", os.time() - 60)
      sbo.mapHighlightAll("janitor")""")
    hl = o.ev("HL")
    assert hl[1] > hl[3] > hl[2], dict(hl)
    eq(o.ev("CENTRE"), 3, "the latest sighting")
    # the quest panel: a step that names a mob Oven has seen
    eq(o.ev("sbo.questFindName('Defeat a janitor [Towne of Rune]')"), "janitor", "find ▸ for it")
    eq(o.ev("sbo.questFindName('Defeat a unicorn')"), None, "never seen: no link")
    o.lua("HL = {}; GOTO = nil; sbo.goTo = function(id) GOTO = id end; sbo.questAct({ id = '1', n = 1, find = 'janitor' })")
    eq(len(o.ev("HL")), 3, "the link lights them up")
    eq(o.ev("GOTO"), 3, "and goes to the latest sighting")
    # the map lights up every target's room by itself (violet), under your own highlight where they overlap
    o.lua("""sbo.mapHighlightAll(""); LIT = {}; highlightRoom = function(id, r) LIT[id] = r end
      unHighlightRoom = function(id) LIT[id] = nil end; sbo.targetLight()""")
    eq(sorted(o.ev("LIT").keys()), [10442, 10522], "the necromancer's room; Samara's and the herb shop's")
    eq(o.ev("LIT[10442]"), 190, "violet")
    o.lua('sbo.mapHighlightAll("janitor"); sbo.mapHighlights = {10442}; sbo.targetLight()')
    eq(o.ev("LIT[10442]"), 190, "kept, not cleared under yours")
    o.lua('sbo.cfg.mapTargets = false; sbo.mapHighlights = {}; sbo.targetLight()')
    eq(o.ev("LIT[10522]"), None, "map.targets off")
    o.lua('sbo.cfg.mapTargets = nil')
    o.lua('sbo.command("map targets clear")')
    eq(o.rows("SELECT COUNT(*) AS n FROM quest_targets")[0]["n"], 0, "cleared")
    o.lua("runTimers(); sbo.targetLight()")
    eq(o.ev("LIT[10522]"), None, "gone with them")


@test
def rooms_negatives():
    o = Oven()
    o.replay(fixture("negatives.txt"))
    rows = o.rows("SELECT tags, text FROM room_npcs")
    eq([r["text"] for r in rows], ["A slight man wearing a loose-fitting gray robe stands here."], "only the real trainer")


@test
def room_description_by_colour():
    o = Oven()
    b = read_recording(fixture("colour.txt"))[0]
    for n, v in b["gmcp"]:
        o.set_gmcp(n, v)
    f = o.ev('''function(lines, fg)
      local b = { lines = {}, cmds = {}, prompt = true, fg = {} }
      for k, v in pairs(fg) do b.fg[k] = v end
      for i = 1, #lines do b.lines[i] = lines[i] end
      local s = sbo.findRoomView(b)
      return s.title, #s.desc, #s.here
    end''')
    title, ndesc, nhere = f(o.L.table_from(b["lines"]), o.L.table_from(b["fg"]))
    eq((title, ndesc, nhere), ("Southern Courtyard", 5, 3), "title, description lines, occupants")


@test
def help_learning_kills_loot():
    o = Oven()
    o.replay(fixture("learn.txt"))
    g = o.sbo.cfg
    eq(g.classGroups["barbarian"], "fighter", "barbarian group")
    eq(g.classGroups["witch"], "cleric", "witch group")
    eq(g.classPrimary["barbarian"], "strength", "barbarian primary")
    bonus = [(x.kind, x.pct) for x in g.raceBonus["dwarf"].values()]
    assert ("bash", 10) in bonus, f"dwarf bonus {bonus}"
    kills = sorted((r["name"], r.get("exp")) for r in o.rows("SELECT name, exp FROM kills"))
    eq(kills, [("An insane marauder", 2704), ("An untamed boar", 8919)], "kills (none from help pages or chat)")
    loot = [r["item"] for r in o.rows("SELECT item FROM loot")]
    assert "a sword" not in loot, f"loot from a help page or chat: {loot}"
    assert "a battleaxe blessed by Gath" in loot and "an earth orb" in loot, f"loot {loot}"
    assert not g.classPrimary["monk"] or g.classPrimary["monk"] != "luck", "learned from a say"


@test
def help_paged():
    o = Oven()
    o.lua('''
      local function B(cmds, lines) sbo.onBlock({ cmds = cmds, lines = lines, prompt = true }) end
      B({ "help elf" }, { "[1100 ] ELF", "elf - a graceful playable race", "Elves deal 15% more damage with piercing weapons.", "Maximum racial stats", "Strength: 15  Agility: 21", "<prompt>" })
      sbo.cap = { kind = "help" }
      B({ "" }, { "Wisdom: 19  Luck: 17", "<prompt>" })
      sbo.cap = nil
      B({ "n" }, { "You walk north.", "<prompt>" })''')
    st = o.sbo.cfg.raceStats.elf
    eq((st.strength, st.agility, st.wisdom, st.luck), (15, 21, 19, 17), "elf stats across two pages")


@test
def kills_through_line_trigger():
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"')
    o.feed("An untamed boar has been slain!", "You receive 8,919 experience points.",
           "You take a tusk from the corpse of an untamed boar.")
    eq(o.rows("SELECT COUNT(*) AS c FROM kills")[0]["c"], 0, "nothing saved before the prompt")
    o.feed("[Mail]<270hp 550sp 401st>")
    k = o.rows("SELECT name, exp FROM kills")[0]
    eq((k["name"], k["exp"]), ("An untamed boar", 8919), "kill")
    eq(o.rows("SELECT item FROM loot")[0]["item"], "a tusk", "loot")


@test
def gmcp_data():
    o = Oven(before='''gmcp = { char = {
      status = {tnlpct="7.40", level=34, totallevel=34, tnl=251478, enemy="_empty"},
      maxstats = {maxst=401, maxhp=270, maxsp=550, strength=20, knowledge=21},
      worth = {gold=100, bank=200, qp=3},
      quests = { q3098 = { goals = { {phase_number=6, room_target=0}, {phase_number=7, room_target=10439} } } },
    }, room = { info = { num = "10439", name = "Runic Temple", flags = "safe, indoors, no-npcs, reinforced, library" } } }''')
    eq((o.ev("sbo.live.level"), o.ev("sbo.live.tnl"), o.ev("sbo.cfg.maxes.hp"), o.ev("sbo.cfg.char.stats.strength.max"), o.ev("sbo.live.worth.bank")),
       (34, 251478, 270, 20, 200), "level, tnl, max hp, max strength, bank")
    o.lua('gmcp.char.status.tnl = 250000; sbo.onGmcpStatus()')
    eq((o.ev("sbo.live.tnl"), o.ev("sbo.cfg.char.tnl")), (250000, 250000), "tnl follows GMCP")
    o.lua('''gmcp.char.affect_application_msg = {duration=-1, modifies="disease-res", target="you", skill="maladapted", modifier=-25}; sbo.onGmcpAffect()
             gmcp.char.affect_application_msg = {duration=30, modifies="strength", target="you", skill="giant", modifier=2}; sbo.onGmcpAffect()''')
    eq(dict(o.ev("sbo.innateMods()").items()), {"disease-res": -25}, "only permanent affects are racial")
    o.lua('''gmcp.char.lasttargeted = { short_descr = "a practice dummy", race = "animated statue", vnum = 4640, hp_percent = 100 }
             sbo.onGmcpTarget(); sbo.recordKill("A practice dummy")''')
    r = o.rows("SELECT vnum, race FROM kills")[0]
    eq((r["vnum"], r["race"]), (4640, "animated statue"), "kill mob number and race")
    eq(o.ev('(sbo.questTarget({ n = 7, text = "Visit someone" }, "3098"))'), 10439, "quest room from GMCP")
    o.lua('sbo.noteRoomFlags(10439, "[Mail][Library][SAFE]<270hp>")')
    eq(o.ev('table.concat(sbo.roomFlagsOf(10439).tags, "|")'), "safe|indoors|no-npcs|reinforced|library", "room flags from GMCP")


@test
def recorder_window():
    o = Oven(before='gmcp = { room = { info = { num = 10421, name = "Library" } }, char = { vitals = { hp = 270 } } }')
    o.lua('''
      sbo.recordFile = "oven_record.txt"; sbo.cfg.promptPattern = "<%d+hp"; sbo.cfg.recWindow = 5
      local function P(l) line = l; sbo.onLine() end
      for i = 1, 8 do sbo.onSend(nil, "look " .. i); P("line " .. i); P("[Library]<270hp>") end
      sbo.onSend(nil, "password hunter2"); P("ok"); P("[Library]<270hp>")
      sbo.command("record save test")''')
    eq(o.ev("#sbo.win.blocks"), 5, "window size")
    t = open(os.path.join(o.home, "oven_record.txt"), encoding="utf-8").read()
    assert "line 8" in t and "line 2" not in t, "window contents"
    assert "hunter2" not in t, "a password was recorded"


@test
def quest_pin_all_only_active():
    o = Oven()
    o.lua('''
      SENT = {}; send = function(c) SENT[#SENT + 1] = c end
      sbo.quests = { ["100"] = { name = "Old Gone", done = 1, total = 4 }, ["200"] = { name = "Current", done = 0, total = 3 } }
      sbo.command("quest pin all")''')
    eq(o.ev("SENT[1]"), "quest info", "asks the game for the current quests")
    eq(o.ev("next(sbo.cfg.questPins)"), None, "nothing pinned before the log is seen")
    o.lua('''sbo.rememberQuests({ list = { { id = "200", name = "Current", done = 0, total = 3 },
                                           { id = "300", name = "New", done = 1, total = 2 } }, other = {} })''')
    pins = sorted(o.ev("sbo.cfg.questPins").keys())
    eq(pins, ["200", "300"], "pin all, once the log arrives: only quests in it")
    o.lua('''sbo.cfg.questPins = {}; sbo.command("quest pin all")
             sbo.rememberQuests({ list = { { id = "300", name = "New", done = 1, total = 2 } }, other = {} })''')
    eq(sorted(o.ev("sbo.cfg.questPins").keys()), ["300"], "a quest gone from quest info isn't pinned")
    o.lua('sbo.questPin("200", true)')
    o.lua('''gmcp.char = { quests = { q300 = { quest_info = { vnum = 300, name = "New", abandoned = true, completed = false } } } }
             sbo.onGmcpQuests()''')
    eq(sorted(o.ev("sbo.cfg.questPins").keys()), ["200"], "abandoning a quest unpins it")
    o.lua('''sbo.cfg.questPins = {}; sbo.command("quest pin all")
             sbo.rememberQuests({ list = { { id = "200", name = "Current", done = 0, total = 3 } }, other = {} })''')
    eq(sorted(o.ev("sbo.cfg.questPins").keys()), ["200"], "pin all after abandoning")
    o.lua('''gmcp.char.quests = { q200 = { quest_info = { vnum = 200, name = "Current", abandoned = false, completed = true } } }
             sbo.onGmcpQuests()''')
    eq(o.ev("sbo.quests['200'].complete"), True, "completion from GMCP")


@test
def quest_info_typed_updates_pins():
    # the real reply to a plain "quest info" with one quest: that quest in full, no list
    reply = open(fixture("quest_info_one.txt"), encoding="utf-8").read().rstrip("\n").split("\n")
    for main in ("replace", "keep"):
        o = Oven()
        o.lua(f'''sbo.cfg.promptPattern = "<%d+hp"; sbo.cfg.main = "{main}"
          sbo.quests = {{ ["100"] = {{ name = "Old Gone", done = 1, total = 4, active = true }} }}
          sbo.cfg.questPins = {{ ["100"] = true }}
          sbo.onSend(nil, "quest info")''')
        o.feed(*reply, "[Mail]<270hp 550sp 401st>")
        o.L.execute("runTimers()")
        eq(o.ev("sbo.cfg.questPins['100']"), None, f"main={main}: dropped quest unpinned")
        eq(o.ev("sbo.quests['3098'].active"), True, f"main={main}: the one quest is active")
        eq(o.ev("sbo.quests['100']"), None, f"main={main}: a quest gone from the log is forgotten")
        # quest info for one quest by number says nothing about the others
        o.lua('sbo.questPin("3098", true); sbo.quests["100"] = { name = "Another", active = true }; sbo.onSend(nil, "quest info 3098")')
        o.feed(*reply, "[Mail]<270hp 550sp 401st>")
        o.L.execute("runTimers()")
        eq(o.ev("sbo.quests['100'].active"), True, f"main={main}: quest info <id> leaves other quests alone")
    # several quests: the list
    o = Oven()
    o.lua('''sbo.cfg.promptPattern = "<%d+hp"; sbo.cfg.questPins = { ["100"] = true }; sbo.onSend(nil, "quest info")''')
    o.feed("Quest #3098: Training in the Forest (6/6 complete)", "Quest #2503: Part-ay! (3/8 complete)", "[Mail]<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    eq(o.ev("sbo.cfg.questPins['100']"), None, "list: dropped quest unpinned")
    eq((o.ev("sbo.quests['2503'].active"), o.ev("sbo.quests['2503'].done")), (True, 3), "list: quests and progress")
    # sbo quest pin all, one quest
    o = Oven()
    o.lua('''sbo.cfg.promptPattern = "<%d+hp"; sbo.quests = { ["100"] = { name = "Old Gone", done = 1, total = 4 } }
      send = function(c) sbo.onSend(nil, c) end
      sbo.command("quest pin all")''')
    o.feed(*reply, "[Mail]<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    # every phase of this one is done (the * marks), so there's nothing to pin - but it was checked
    eq(o.ev("sbo.quests['3098'].active"), True, "pin all read the single-quest reply")
    eq(sorted(o.ev("sbo.cfg.questPins").keys()), [], "a finished quest isn't pinned")
    eq(o.ev("sbo.pinAllPending"), None, "pin all isn't left waiting")


@test
def inspector_tabs():
    o = Oven()
    o.lua('''sbo.cfg.window = true
      function FRONT() local f = {} for _, k in ipairs({ "view", "help", "log", "chat" }) do if WIDGETS["ovenTabs3Page_" .. k].shown then f[#f + 1] = k end end return table.concat(f, ",") end''')
    o.lua('sbo.viewAdd({ lines = { { { "white", "an item" } } }, links = {} })')
    eq(o.ev("FRONT()"), "view", "an item: Inspector tab")
    o.lua('sbo.showHelp("classes", { "[1065 ] CLASSES", "Character classes in Alyria are as follows:" })')
    eq(o.ev("FRONT()"), "help", "a help page: Help tab")
    eq(o.ev("sbo.helpContainer"), None, "no separate help window")
    assert "(in window)" in o.ev("CREATED[#CREATED]"), "help page built inside the window"
    o.lua('sbo.command("session")')
    eq(o.ev("FRONT()"), "log", "session: Log tab")
    o.lua('sbo.command("kills")'); eq(o.ev("FRONT()"), "log", "kills: Log tab")
    o.lua('WIDGETS.ovenTabs3_view.click()'); eq(o.ev("FRONT()"), "view", "clicking a tab")
    o.lua('sbo.command("tab help")'); eq(o.ev("FRONT()"), "help", "sbo tab help")
    eq(o.ev("WIDGETS.ovenTabs3_help.css").count(o.ev("sbo.hex('title')")), 1, "the front tab is highlighted (the palette's title colour)")
    o.lua('sbo.command("tabs off")')
    eq(o.ev("WIDGETS.ovenTabs3Box.shown"), False, "tabs off hides the bar")
    o.lua('sbo.showHelp("classes", { "[1065 ] CLASSES" })')
    assert o.ev("sbo.helpContainer") is not None, "tabs off: help gets its own window again"
    bad = [m for m in o.ev("CREATED").values() if "MAIN SCREEN" in m]
    assert not bad, bad


@test
def chat_tab():
    o = Oven()
    o.lua('sbo.cfg.window = true; sbo.viewAdd({ lines = { { { "white", "an item" } } }, links = {} })')
    o.replay(fixture("chat.txt"))
    got = [(e["ch"], e.get("who")) for e in (dict(x.items()) for x in o.ev("sbo.chat.lines").values())]
    eq(got, [("CLAN", "Moss"), ("CLAN", None), ("CLAN", "Bramble"), ("Tells", "Wren"),
             ("YELL", "A voice"), ("ANNOUNCEMENT", "A sepulchral voice"), ("HINT", "Local Hint"), ("NOVICE", None)],
       "chat lines (news once a channel is known; no NPC talk, room lines, help pages)")
    eq(list(o.ev("sbo.cfg.chatChannels").values()), ["AUCTION", "CLAN", "Tells", "YELL", "ANNOUNCEMENT", "HINT", "NOVICE"], "AUCTION from the start, then channels learned in order")
    eq(o.ev("sbo.cfg.chatGameChannels.SHOUT"), True, "the channel list is read")
    eq(o.ev("sbo.cfg.chatGameChannels.AUCTION"), False, "off channels too")
    eq(o.ev("WIDGETS.ovenTabs3Page_view.shown"), True, "chat doesn't take the window's focus")
    eq(o.ev("WIDGETS.ovenTabs3_chat.text"), "<center>Chat (8)</center>", "unread count on the tab")
    o.lua('sbo.command("tab chat")')
    eq(o.ev("WIDGETS.ovenTabs3_chat.text"), "<center>Chat</center>", "read once the tab is open")
    text = o.ev("WIDGETS.ovenChatConsole.text")
    assert "Bramble" in text and "Wren" in text, text
    o.lua('sbo.chatFilter("Tells")')
    text = o.ev("WIDGETS.ovenChatConsole.text")
    assert "Wren" in text and "Moss" not in text, f"filter: {text}"
    o2 = Oven()   # news on a channel nobody has talked on yet, once the channel list is known
    o2.lua('sbo.cfg.chatGameChannels = { CLAN = true }')
    eq(o2.ev('(sbo.chatFind("[CLAN] Pip has been slain in A Fetid Lane!"))'), "CLAN", "news from the channel list")
    eq(o2.ev('(sbo.chatFind("[QUEST] Something"))'), None, "unknown tags aren't channels")
    o.lua('sbo.command("chat mute clan"); sbo.chatFilter("All")')
    text = o.ev("WIDGETS.ovenChatConsole.text")
    assert "Moss" not in text and "Wren" in text, f"muted: {text}"
    assert "line-through" in o.ev("WIDGETS.ovenChatChipW3.css"), "muted chip is struck through"
    # too many to fit across: they wrap onto another row, and the bar grows
    o.lua('for _, c in ipairs({"GOSSIP", "NEWBIE", "TRADE", "MUSIC", "QUESTION"}) do table.insert(sbo.cfg.chatChannels, c) end; sbo.chatChips()')
    assert o.ev("sbo.chatBarH") >= 48, "more than one row"
    eq(o.ev("WIDGETS.ovenChatChipW1.chipRow"), 0, "All on the first")
    assert o.ev("WIDGETS.ovenChatChipW12.chipRow") >= 1, "the last on a later row"
    # an old chip left in the bar by an update is taken out
    o.lua('Geyser.Label:new({ name = "ovenChatChip1", width = 60 }, sbo.chatBar); sbo.chatChips()')
    eq(list(o.ev("sbo.chatBar.windows").values()), ["ovenChatChipArea"], "only the chip area in the bar")
    o.lua('sbo.chatFilter("CLAN")')
    assert "Moss" in o.ev("WIDGETS.ovenChatConsole.text"), "a muted channel can still be read on its own"
    # a line arriving is copied in whole (its links still work), not drawn again from its text
    o.lua("""COPIED = nil; copy = function() COPIED = line end
      appendBuffer = function(w) WIDGETS[w].text = WIDGETS[w].text .. "{BUF:" .. COPIED .. "}\\n" end
      sbo.chatFilter("All")""")
    o.feed("[AUCTION] Pip is auctioning a gnarled staff (min 500 gold).")
    o.block(["[AUCTION] Pip is auctioning a gnarled staff (min 500 gold).", "<281hp 696sp 457st> "])
    text = o.ev("WIDGETS.ovenChatConsole.text")
    assert "{BUF:[AUCTION] Pip is auctioning" in text, text
    eq(text.count("gnarled staff"), 1, "copied once, not drawn again")
    # the auction channel, however it's written
    for l in ["[AUCTION] Pip is auctioning a gnarled staff (min 500 gold).", "AUCTION: Pip bids 600 gold.",
              "Auction: the staff is sold to Wren.", "(Auction) Going once..."]:
        eq(o2.ev(f'(sbo.chatFind([[{l}]]))'), "AUCTION", l)
    eq(o2.ev('(sbo.chatFind([[The auction house is closed.]]))'), None, "not just any mention")


@test
def bar_group_health():
    o = Oven()
    for prompt in ("([97%]Roarke)[Mail]<270hp 501sp 401st>", "([96%]Bun)[Mail][SAFE]<261hp 504sp 400st>"):
        p = o.ev(f'sbo.parsePrompt("{prompt}")')
        g = p.group
        assert g is not None, prompt
        eq(list(p.tags.values()), ["Mail"] + (["SAFE"] if "SAFE" in prompt else []), "tags without the group")
        eq(p.rest, "", "nothing left over for the right side")
    o.lua('''sbo.bar = { rawEcho = function(self, h) BAR = h end }
             sbo.lastPromptText = "([97%]Roarke)[Mail]<270hp 501sp 401st>"; sbo.drawBar()''')
    bar = o.ev("BAR") or ""
    plain = __import__("re").sub("<[^>]+>", "", bar)
    i = plain.find("Roarke")
    assert i >= 0 and plain.find("97%") > i and plain.find("97%") - i < 12, f"name and health together: {plain}"
    assert i < plain.find("HP"), f"group comes first: {plain}"


AUCTION_INFO = """A small imp appears before you in a puff of smoke.
The imp shows you a tablet upon which is written:
This item is up for auction from Pip.
Item 'a tester's phasing barrier' is type armor, alignment 0, made of energy (in (new) condition),[Study][LTB]
has keywords 'energy shield phasing barrier testers', equipped as a shield.
This item weighs 0 stones and 2 pebbles, and is valued at 35,200 gold. {Cat. 6}
This level 241 item has the attributes: magic-resistant no-dispel
Armor resistance is 6.
This armor has the additional attributes: reflect-magic
Affects damage by -26.
*This item may be repaired 4 times.
This is part of the 'A Tester's Phasing Kit' set.
- Item 'a tester's phasing barrier'
- Item 'a tester's phasing goggles'
Grants knowledge at 100%: slow time - room affect that doubles the casting time of all spells (Requires 2 items).
A plain shield of shimmering energy, made for testing.  
The minimum bid on this item is [35,000] gp.
No bids on this item have been received."""


@test
def auction_info():
    o = Oven()
    eq(o.ev("(sbo.classify('auction info'))"), "item", "auction info is read like an item")
    eq(o.ev("(sbo.classify('auction bid 5000'))"), None, "a bid isn't")
    r = o.sbo.format("item", "", o.L.table_from(AUCTION_INFO.split("\n")), 90)
    f = o.ev("function(rows) local s={} for _,r in ipairs(rows) do for _,g in ipairs(r) do s[#s+1]=tostring(g[2]) end s[#s+1]='\\n' end return table.concat(s) end")
    out = f(r)
    auc = next(l for l in out.split("\n") if l.startswith("Auction"))
    assert "from Pip" in auc and "35,000" in auc and "no bids yet" in auc, auc
    assert "imp" not in out and "minimum bid on this item" not in out, f"the tablet's own lines are gone: {out}"
    assert "a tester's phasing goggles" in out, f"set pieces with apostrophes whole: {out}"
    assert "reflect-magic" in out and "with 2 set pieces" in out, out


@test
def gear_score_effects():
    o = Oven()
    o.lua("""sbo.cfg.char = { class = 'monk' }; sbo.cfg.skills = { parry = { lrnd = 40 } }
      HOOK = { name = 'a test hook', type = 'weapon', worn = 'wielded', grants = { { 'parry', '100%', 'move to block' } },
        special = 'poisoned', bonus = { { 'a test hook will, if its wielder\\'s opponent is poisoned, deal 3 damage' } },
        extra = { { 'Casts', { { 'x', "'sanctuary'" } } }, { 'Also', { { 'x', 'reflect-magic' } } } } }
      PLAIN = { name = 'a plain hook', type = 'weapon', worn = 'wielded' }""")
    e = o.ev("sbo.itemEffects(HOOK)")
    eq(round(e["skill:parry"], 2), 0.6, "parry at 100%, you have 40%: worth the 60% you'd gain")
    for k in ("weapon-special", "proc:hit", "spell:sanctuary", "attr:reflect-magic"):
        assert e[k], f"{k} counted"
    # roles: sanctuary is defense, the poison proc offense, parry defense
    r = o.ev("sbo.roleScores(HOOK)")
    assert r.defense > 4 and r.offense > 2, dict(r)   # parry; sanctuary is minor (help 1533)
    eq(o.ev("(sbo.spellInfo('haste')).offense"), 1, "haste is offense")
    assert o.ev("select(2, sbo.spellInfo('haste'))") > o.ev("select(2, sbo.spellInfo('levitation'))"), "haste is worth more"
    assert o.ev("sbo.gearScore(HOOK)") > o.ev("sbo.gearScore(PLAIN)") + 8, "effects add up"
    o.lua("sbo.cfg.skills.parry.lrnd = 100")
    eq(o.ev("sbo.itemEffects(HOOK)['skill:parry']"), None, "a skill you already have maxed adds nothing")
    # a set bonus: closer to the set = worth more
    o.lua("SETP = { name = 'a set piece', worn = 'on the body', set = { worn = '1', bonus = { { need = 2, text = '+5 strength' } } } }")
    eq(o.ev("sbo.itemEffects(SETP)['set-bonus']"), 1, "this piece completes it")
    o.lua("SETP.set.bonus[1].need = 4")
    eq(o.ev("sbo.itemEffects(SETP)['set-bonus']"), 0.5, "halfway there")
    # common stats a build leaves out still count
    o.lua("ACC = { name = 'a ring', worn = 'on a finger', affects = { { 'accuracy', '2' }, { 'damage-prcnt', '5' } } }")
    assert o.ev("sbo.gearScore(ACC)") >= 7, o.ev("sbo.gearScore(ACC)")


@test
def upgrade_gains_and_losses():
    o = Oven()
    o.lua("""sbo.cfg.char = { class = 'monk' }
      OLD = { name = 'a garb', worn = 'on the body', ar = '4', affects = { { 'accuracy', '2' } },
        extra = { { 'Casts', { { 'x', "'sanctuary'" }, { 'y', '  level ' }, { 'z', '20' } } } } }
      NEW = { name = 'a plate', worn = 'on the body', ar = '9', affects = { { 'hp', '13' } },
        grants = { { 'parry', '100%', 'block' } } }""")
    gain, lose = o.ev("function() return sbo.upgradeDiff(OLD, NEW, select(2, sbo.activeBuild())) end")()
    g = [x.text for x in gain.values()]; l = [x.text for x in lose.values()]
    assert "+5 ar-torso" in g and "+13 hp" in g and "parry 100%" in g, g
    assert "−2 accuracy" in l and "casts sanctuary" in l, l
    # AR: "Affects ar" covers every location; an item's own AR only where it's worn (ar-torso), a share of it
    o.lua("sbo.cfg.arLoc = { head = 5, torso = 16, arms = 14, legs = 18, tail = 5 }")
    eq(o.ev("sbo.itemStats({ ar = '10', worn = 'on the legs' })['ar-legs']"), 10, "a legs item's AR is legs AR")
    eq(o.ev("sbo.itemStats({ ar = '1', worn = 'worn as a shield' })['ar-arms']"), 1, "a shield covers the arms")
    w = "select(2, sbo.activeBuild())"
    eq(round(o.ev(f"sbo.statWeight({w}, 'ar') / sbo.statWeight({w}, 'ar-legs')"), 2), 5.0, "all five locations vs one")
    # by role: the plate is more defense (AR, hp) and less offense (accuracy) than the garb
    d = o.ev("sbo.roleScores(NEW)").defense - o.ev("sbo.roleScores(OLD)").defense
    assert d > 0, d
    assert o.ev("sbo.roleScores(OLD)").offense > o.ev("sbo.roleScores(NEW)").offense
    # leaning the build towards defense makes the plate score higher
    before = o.ev("sbo.gearScore(NEW)")
    o.lua("sbo.command('eq build role defense 2')")
    assert o.ev("sbo.gearScore(NEW)") > before, "a defensive lean favours the plate"
    eq(o.ev("sbo.roleMix().defense"), 2, "kept")


@test
def combat_model():
    o = Oven()
    # the starting point: eq's own numbers (as on 2026-11-12)
    o.ev("sbo.noteCombat")(o.L.table_from([
        "57 Damage: (+46 from weapon) (+9 from skill & strength) (+1 from weapon skillpower)",
        "55 Accuracy: (+7 from level) (+25 from weapon skill) (+16 from weapon) (+5 from agility)",
        "31% Critical Hit chance:  (+31 from staff)", "You have a 46% chance to resist a critical hit."]))
    o.lua("""sbo.cfg.char.class = 'monk'; sbo.cfg.char.stats = { agility = { cur = 9, max = 17 }, strength = { cur = 10, max = 20 } }
      sbo.cfg.maxes = { hp = 365, sp = 875 }; sbo.cfg.arLoc = { head = 5, torso = 16, arms = 14, legs = 18, tail = 5 }; sbo.cfg.arRate = 0.75
      sbo.cfg.skills = { staff = { lrnd = 85 }, mace = { lrnd = 0 } }""")
    # enhanced damage from eq: "38% chance for +3" -> +1.14 on average, on top of the 57
    o.ev("sbo.noteCombat")(o.L.table_from(["57 Damage: (+46 from weapon) (+9 from skill & strength) (38% chance for +3 from enhanced damage)",
        "55 Accuracy: (+16 from weapon)", "31% Critical Hit chance:"]))
    eq(round(o.ev("sbo.combatModel(nil, nil)").offense.parts.damage[1], 2), 58.14, "57 + 38% of 3")
    o.ev("sbo.noteCombat")(o.L.table_from([
        "57 Damage: (+46 from weapon) (+9 from skill & strength) (+1 from weapon skillpower)",
        "55 Accuracy: (+7 from level) (+25 from weapon skill) (+16 from weapon) (+5 from agility)",
        "31% Critical Hit chance:  (+31 from staff)", "You have a 46% chance to resist a critical hit."]))
    m = o.ev("sbo.combatModel(nil, { affects = { { 'damage-prcnt', '5' } } })")
    # 5% of the weapon's 46 = +2.3 damage on 57: +4.0% per swing
    eq(round(m.offense.pct, 1), 4.0, "damage-prcnt from the weapon's base damage")
    m = o.ev("sbo.combatModel({ affects = { { 'accuracy', '2' } } }, nil)")
    eq(round(m.offense.parts.accuracy[2], 2), round(55 - 4 / 3, 2), "gear accuracy counts 2/3 (help 1747)")
    m = o.ev("sbo.combatModel(nil, { affects = { { 'agility', '2' } } })")
    eq(m.offense.parts.accuracy[2], 56, "+2 agility = +1 accuracy ((agility+1)/2)")
    m = o.ev("sbo.combatModel(nil, { affects = { { 'agility', '20' } } })")
    eq(m.offense.parts.accuracy[2], 59, "but only up to the maximum: 9 -> 17")
    # defense: +1 AR everywhere vs on the legs only
    all_ = o.ev("sbo.combatModel(nil, { affects = { { 'ar', '1' } } })").defense.pct
    legs = o.ev("sbo.combatModel(nil, { affects = { { 'ar-legs', '1' } } })").defense.pct
    assert all_ > 4 * legs and legs > 0, (all_, legs)
    # a weapon of another kind: your skill with it, not your staff's
    o.lua("""STAFF = { name = 'a staff', worn = 'wielded', weapon = { summary = 'Your staff will deal High bash damage', dmgLevel = 'High', accuracy = 'Min', critChance = 'Max' }, keywords = 'staff' }
      MACE = { name = 'a mace', worn = 'wielded', weapon = { summary = 'Your mace will deal High bash damage', dmgLevel = 'High', accuracy = 'Max', critChance = 'Low' }, keywords = 'mace' }""")
    m = o.ev("sbo.combatModel(STAFF, MACE)")
    eq(round(m.offense.parts.accuracy[2]), 55 + 29 - 25, "+29 weapon accuracy, -25 from losing staff skill")
    assert m.offense.pct < 0, "worse: a skill you don't have, and far less crit"
    # attacks per round (help 2258 + help haste: +10 attack speed)
    eq(o.ev("sbo.attacksPerRound(10)"), 1.1, "no extra-attack skills: 10 speed = a 10% second attack")
    o.lua("sbo.cfg.skills['second attack'] = { lrnd = 95 }")
    eq(round(o.ev("sbo.attacksPerRound(10)"), 2), 2.05, "95% second attack: 5 to finish it, 5 into third attack")
    o.lua("sbo.cfg.skills['second attack'] = nil")
    m = o.ev("sbo.combatModel(nil, { extra = { { 'Casts', { { 'x', \"'haste'\" } } } } })")
    eq(round(m.offense.pct, 1), 10.0, "haste on gear: +10% damage per round")
    # sanctuary (help 1533): +3 damage to evil only if you're good; nothing to a neutral offense
    m = o.ev("sbo.combatModel(nil, { extra = { { 'Casts', { { 'x', \"'sanctuary'\" } } } } })")
    eq(round(m.offense.pct, 1), 0.0, "neutral: sanctuary adds no damage")
    # spells learned from their help pages
    o.ev("sbo.noteSpellHelp")(o.L.table_from(["[9999 ] STONE TEST", "*When you stone test, you will apply +5 ar for 10 minutes]"]))
    eq(o.ev("sbo.spellAffects('stone test').ar"), 5, "learned from the help page")
    # defense: a point of head AR protects more than one of tail AR (help 1085: 120% vs 50%)
    head = o.ev("sbo.combatModel(nil, { affects = { { 'ar-head', '1' } } })").defense.pct
    tail = o.ev("sbo.combatModel(nil, { affects = { { 'ar-tail', '1' } } })").defense.pct
    assert head > 2 * tail, (head, tail)
    # resilience against how hard you're really hit
    o.lua("sbo.cfg.char.hitTaken = nil; for i = 1, 5 do sbo.noteHitTaken(2, 60) end")
    eq(round(o.ev("sbo.cfg.char.hitTaken")), 30, "30 hp a hit")
    r = o.ev("sbo.combatModel(nil, { affects = { { 'resilience', '3' } } })").defense.pct
    assert 9 < r < 13, f"3 off a 30-damage hit: ~10% less damage, ~11% more effective hp: {r}"
    # regeneration (help 2334): haste halves it; sanity tiers speed up spell points
    m = o.ev("sbo.combatModel(nil, { extra = { { 'Casts', { { 'x', \"'haste'\" } } } } })")
    eq(round(m.hpRegen.pct), -50, "hasted: half the hp regen")
    o.lua("sbo.cfg.char.stats.sanity = { cur = 16, max = 18 }")
    m = o.ev("sbo.combatModel(nil, { affects = { { 'sanity', '2' } } })")
    eq(round(m.spRegen.pct, 1), 12.5, "sanity 16 -> 18: divisor 9 -> 8, +12.5% spell point regen")


@test
def attack_abilities():
    o = Oven()
    o.ev("sbo.noteAbilityHelp")(o.L.table_from(["[1487 ] SPARK", "*Pyromancy spell (5% complexity)",
        "*Character (Offensive) target, 2 second cast time", "*Spell Points Required: 49",
        "*Deals flames/lightning (2.2 base) damage."]))
    o.ev("sbo.noteAbilityHelp")(o.L.table_from(["[1348 ] KICK", "*Combat proficiency (10% complexity)",
        "*Character (Offensive) target, 2 second usage time", "*Deals bash/bash (1.3 base) damage."]))
    o.lua("sbo.cfg.abilitiesRead = 2; sbo.cfg.skills = { spark = { lrnd = 50 }, kick = { lrnd = 100 } }")
    mine = o.ev("sbo.myAbilities()")
    eq([x.name for x in mine.values()], ["kick", "spark"], "best per use first: 1.3 at 100% vs 2.2 at 50%")
    eq(round(o.ev("sbo.myAbilities()[2].perCost"), 2), 2.24, "spark: 1.1 per use, per 100 sp")
    lines = o.ev("sbo.abilitySwapLines(nil, { affects = { { 'fire-damage', '3' }, { 'damage-kick', '2' } } })")
    t = {x.name: x.text for x in lines.values()}
    eq(t, {"kick": "+2 damage-kick", "spark": "+3 fire-damage"}, "gear that boosts them")
    # an install that read the pages before practice costs were read: read again (from oven_help.txt)
    import tempfile
    hf = tempfile.mktemp()
    open(hf, "w").write("===== help 1487 [1487] | x\n[1487 ] SPARK\n*Pyromancy spell (5% complexity)\n*Costs 1.6 practices per percent learned.\n*Spell Points Required: 49\n*Deals flames/lightning (2.2 base) damage.\n===== end\n")
    o.lua(f"sbo.helpFile = '{hf}'; sbo.cfg.abilitiesRead = true; sbo.cfg.abilities.spark.practice = nil")
    o.ev("sbo.myAbilities()")
    eq(o.ev("sbo.cfg.abilities.spark.practice"), 1.6, "practice cost read on the second reading")
    # practise next: the most damage per use for the practices, up to 75%
    o.ev("sbo.noteAbilityHelp")(o.L.table_from(["[1490 ] CAUSE LIGHT", "*Diamancy spell (8% complexity)",
        "*Costs 1.8 practices per percent learned.", "*Spell Points Required: 54", "*Deals energy/pain (2.4 base) damage."]))
    o.lua("sbo.cfg.skills['cause light'] = { lrnd = 18 }; sbo.cfg.abilities.spark.practice = 1.6")
    f = o.ev("function() local out = {} sbo.abilitySection(out, 100) local s = {} for _, r in ipairs(out) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = '\\n' end return table.concat(s) end")
    text = f()
    assert "Practise next" in text and "spark" in text.split("Practise next")[1] and "40 practices" in text, f"spark: 2.2/1.6 beats cause light 2.4/1.8; 50→75 = 40: {text}"
    assert "?st" in text, "kick: stamina not in its help page"
    # any character: its own skills not read yet make the next batch
    o.lua("sbo.cfg.helpBatchesDone = {}; for _, b in ipairs(sbo.HELP_BATCHES) do sbo.cfg.helpBatchesDone[b.name] = true end; sbo.cfg.skills.dodge = { lrnd = 40 }")
    name, pages = o.ev("function() return sbo.helpNextBatch() end")()
    eq(name, "your skills and spells not read yet", "from the character's own skills")
    assert "dodge" in list(pages.values()), list(pages.values())


@test
def melee_by_weapon():
    o = Oven()
    o.lua("sbo.cfg.skills = { ['martial arts'] = { lrnd = 76 }, staff = { lrnd = 85 } }")
    staff = ["Your staff will deal High bash damage with Min accuracy, at Low range, with a Max chance to crit for 2x damage.",
      "57 Damage: (+46 from weapon) (+2 from +damage) (+9 from skill & strength) (+1 from weapon skillpower) (38% chance for +3 from enhanced damage) ",
      "51 Accuracy: (+4 from level) (+25 from weapon skill) (+16 from weapon) (+5 from agility) (+1 from personality) (+19 when martial arts activates) ",
      "31% Critical Hit chance:  (+31 from staff)"]
    fists = ["With hand to hand, you will deal Low water damage with Max accuracy, at Min range, with a High chance to crit for 2x damage.",
      "42 Damage: (+38 from weapon) (+1 from +damage) (+4 from skill & strength) (38% chance for +3 from enhanced damage) ",
      "80 Accuracy: (+4 from level) (+25 from weapon skill) (+45 from fists) (+5 from agility) (+1 from personality) (+19 when martial arts activates) ",
      "22% Critical Hit chance:  (+22 from hand to hand)"]
    o.ev("sbo.noteCombat")(o.ev("function(...) return {...} end")(*fists))
    o.ev("sbo.noteCombat")(o.ev("function(...) return {...} end")(*staff))
    # the dummy measured 38.7 a round with the staff: martial arts (18s cooldown) isn't every round
    now = o.ev("sbo.combatModel(nil, nil).offense.now")
    assert 37 < now < 40, now
    text = "\n".join("".join(str(g[2]) for g in r.values()) for r in o.ev("sbo.buildLines(100)").values())
    assert "now: staff" in text and "with fists" in text and "water" in text, text
    assert "42.1" in text and text.index("now: staff") < text.index("with fists"), text


@test
def quest_steps_are_links():
    o = Oven()
    o.lua("""SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
      sbo.quests['77'] = { name = 'Lemon Run', total = 2, done = 1, phases = {
        { n = 1, text = 'Speak with the abbot', done = true }, { n = 2, text = 'Bring a lemon to the abbot' } } }
      ROOMS = { [1] = 100, [2] = 200 }
      sbo.questTarget = function(ph) return ROOMS[ph.n], 'abbot' end
      roomExists = function() return true end; getRoomName = function(id) return 'room ' .. id end
      getPath = function() return false end
      WALKS = {}; sbo.mapWalkTo = function(id) WALKS[#WALKS+1] = id end""")
    html_acts = o.ev("function() local h, w, a = sbo.questCardHtml('77', sbo.quests['77']) local out = {} for k, v in pairs(a) do out[#out+1] = k .. '=' .. (v.fold and 'fold' or v.n) end table.sort(out) return table.concat(out, ',') , #h end")
    acts, nlines = html_acts()
    # line 1 the title; 2 step 1 (done); 3 step 2; 4 its "→ room 200  go ▸"
    eq(acts, "1=fold,2=1,3=2,4=2", "the title folds; every step line, and the go line, is a link")
    # each line is its own label: a click lands on exactly that line
    o.lua("""sbo.cfg.questPins = { ['77'] = true }; sbo.drawQuestTracker()
      getMousePosition = function() return 10, 10 end
      function CLICK(card, line) local l = WIDGETS['ovenQuestLine' .. card .. '_' .. line]; l.click({ button = 'LeftButton' }); sbo.hudRelease() end""")
    o.lua("CLICK(1, 2)")   # step 1 (finished)
    o.lua("CLICK(1, 4)")   # go ▸
    eq(list(o.ev("WALKS").values()), [100, 200], "a finished step still goes back to its place; go ▸ to the next")
    assert "(done)" in o.ev("SAYS[1]"), o.ev("SAYS[1]")
    # the cursor: a pointing hand on a link line
    o.lua("""CUR = {}; sbo.hudCallbacks({ setClickCallback = function() end, setMoveCallback = function() end, setReleaseCallback = function() end,
        setCursor = function(self, c) CUR[#CUR+1] = c end }, '77', { id = '77', n = 1 })
      sbo.hudCallbacks({ setClickCallback = function() end, setMoveCallback = function() end, setReleaseCallback = function() end,
        setCursor = function(self, c) CUR[#CUR+1] = c end }, '77', nil)""")
    eq(list(o.ev("CUR").values()), ["PointingHand", "OpenHand"], "a link line, a plain line")
    # the title line folds the quest (and unfolds it)
    o.lua("CLICK(1, 1); sbo.drawQuestTracker = function() end")
    eq((len(o.ev("WALKS")), o.ev("sbo.cfg.questFolded['77']")), (2, True), "folded, no walk")
    eq(o.ev("#select(1, sbo.questCardHtml('77', sbo.quests['77']))"), 1, "folded: the title alone")
    o.lua("sbo.questAct({ id = '77', fold = true })")
    eq(o.ev("sbo.cfg.questFolded['77']"), None, "unfolded")
    # the questmaster: a link back to where the quest was taken
    o.lua("""sbo.mapRoom = 555; sbo.questReplyRequest = true
      sbo.rememberQuests({ list = {}, detail = { id = '78', name = 'Supplies', master = 'the Abbot', total = 1, done = 0,
        phases = { { n = 1, text = 'Find a lemon' } } } }, false)""")
    eq(o.ev("sbo.quests['78'].masterRoom"), 555, "the room you took it in")
    h, w, a = o.ev("function() return sbo.questCardHtml('78', sbo.quests['78']) end")()
    last = max(a.keys())
    assert a[last].master and "the Abbot" in h[last] and "go ▸" in h[last], h[last]
    assert "&amp;" not in h[last], h[last]
    o.lua("WALKS = {}; sbo.questGoMaster('78')")
    eq(list(o.ev("WALKS").values()), [555], "back to the abbot")
    # "Return to your quest master": the abbot, back to the same room
    o.lua("WALKS = {}; sbo.quests['78'].turnIn = 'your quest master'; sbo.questGoMaster('78')")
    eq(list(o.ev("WALKS").values()), [555], "your quest master is the abbot")
    eq(o.ev("sbo.questReturnTo(sbo.quests['78'])"), "the Abbot", "shown as the abbot")
    o.lua("sbo.quests['78'].turnIn = nil")
    # another quest from the abbot, its room not known (taken before Oven kept it): where you took one from them
    o.lua("WALKS = {}; sbo.quests['79'] = { name = 'More', master = 'the Abbot', complete = true }; sbo.questGoMaster('79')")
    eq(list(o.ev("WALKS").values()), [555], "the abbot's room from the other quest")
    eq(o.ev("sbo.cfg.questMasterRooms['the abbot']"), 555, "kept by name")
    o.lua("sbo.quests['79'] = nil")
    # finished: its "return to" line is a link too
    o.lua("sbo.quests['78'].complete = true; sbo.quests['78'].done = 1; sbo.quests['78'].phases[1].done = true")
    h, w, a = o.ev("function() return sbo.questCardHtml('78', sbo.quests['78']) end")()
    assert any(v.master for v in a.values()), "the complete card's link"
    # and a turn-in button: sends quest complete 78
    line_no = [k for k, v in a.items() if v.turnIn][0]
    assert "turn in" in h[line_no] and "quest complete 78" in h[line_no], h[line_no]
    o.lua("""SENT = {}; send = function(c) SENT[#SENT+1] = c end
      gmcp.char = { status = { state = 'playing' } }; sbo.lastStatusPrompt = '<281hp 696sp 457st>'""")
    o.lua("sbo.questAct({ id = '78', turnIn = true })")
    eq(list(o.ev("SENT").values()), ["quest complete 78"], "turned in")
    # the reward: on the card, finished or not
    o.lua("sbo.quests['78'].rewards = { { '19', 'quest points' }, { '0', 'build points' }, { '6,640', 'experience points' } }; sbo.quests['78'].upTo = true")
    h = list(o.lua("return (sbo.questCardHtml('78', sbo.quests['78']))").values())
    import re as _re
    h = [_re.sub("<[^>]+>", "", x) for x in h]
    assert not any("&amp;" in x for x in h), h
    rw = [x for x in h if "quest points" in x]
    assert rw and "6,640" in rw[0] and "build points" not in rw[0] and "Up to" in rw[0], h


@test
def update_check_never_sticks():
    o = Oven()
    o.lua("""sbo.REPO = 'x/y'; sbo.cfg.updateCheck = true; DL = {}; downloadFile = function(f, u) DL[#DL+1] = f end
      sbo.checkForUpdate()""")
    assert o.ev("sbo.pending"), "checking"
    # Mudlet's error: (event, message, file) - the check ends, it doesn't hang
    o.lua("sbo.onDownload('sysDownloadError', 'Host not found', DL[#DL])")
    eq(o.ev("DL[#DL]"), o.ev("sbo.dl.version"), "the commit lookup failed: on to the version file")
    o.lua("sbo.onDownload('sysDownloadError', 'Host not found', DL[#DL])")
    eq(o.ev("sbo.pending"), None, "that failing too ends the check")
    # no answer at all: given up after 90 s, and the next check goes ahead
    o.lua("sbo.checkForUpdate(); sbo.pendingAt = os.time() - 120; DL = {}; sbo.checkForUpdate()")
    assert o.ev("#DL") > 0, "a fresh check started"


@test
def hidden_rooms_mapped():
    o = Oven()
    o.lua("""ROOMS, AREAS, EXITS, STUBS, NAMES = {}, {}, {}, {}, {}
      local nextArea = 100
      getAreaTable = function() local t = {} for n, id in pairs(AREAS) do t[n] = id end return t end
      addAreaName = function(n) nextArea = nextArea + 1; AREAS[n] = nextArea; return nextArea end
      deleteArea = function(id) for n, a in pairs(AREAS) do if a == id then AREAS[n] = nil end end
        for r, v in pairs(ROOMS) do if v.area == id then ROOMS[r] = nil end end end
      roomExists = function(id) return ROOMS[tonumber(id)] ~= nil end
      addRoom = function(id) ROOMS[id] = { x = 0, y = 0, z = 0 } end
      setRoomArea = function(id, a) ROOMS[id].area = a end
      setRoomName = function(id, n) NAMES[id] = n end
      setRoomCoordinates = function(id, x, y, z) ROOMS[id].x, ROOMS[id].y, ROOMS[id].z = x, y, z end
      getRoomCoordinates = function(id) local r = ROOMS[id] return r.x, r.y, r.z end
      setExit = function(a, b, d) EXITS[a .. d] = b end
      setExitStub = function(id, d, on) STUBS[id .. d] = on or nil end
      updateMap = function() end; centerview = function() end; getRoomArea = function(id) return ROOMS[id] and ROOMS[id].area end
      SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
      function GO(dir, name, exits) if dir then sbo.tempNoteSend(dir) end
        gmcp.room = { info = { num = -99, zone = 'Tower of Riga', name = name, exits = exits, wilds = 'false',
          coord = { id = 2, name = 'Verity Isle', x = 69, y = 32 } } }
        sbo.onRoom() end""")
    B = 2000000000
    # A Meeting of Corridors: east 42717, west 42715 - it's 42716
    o.lua("""GO(nil, 'A Meeting of Corridors', { n = -99, n_realnum = 42706, e = -99, e_realnum = 42717, w = -99, w_realnum = 42715 })""")
    eq(o.ev("sbo.mapRoom"), B + 42716, "worked out from east and west")
    assert o.ev("STUBS[%d .. 'n']" % (B + 42716)), "north: a stub (not seen yet)"
    # north, into the armory (one exit back south): it's 42706, through the exit taken
    o.lua("""GO('n', 'A Cluttered Armory', { s = -99, s_realnum = 42716 })""")
    eq(o.ev("sbo.mapRoom"), B + 42706, "through the exit taken")
    eq((o.ev("ROOMS[%d].x" % (B + 42706)), o.ev("ROOMS[%d].y" % (B + 42706))), (0, 1), "a step north")
    eq(o.ev("EXITS['%dn']" % (B + 42716)), B + 42706, "linked both ways")
    eq(o.ev("EXITS['%ds']" % (B + 42706)), B + 42716, "")
    eq(o.ev("NAMES[%d]" % (B + 42706)), "A Cluttered Armory", "named")
    # back south: the same room, not a new one
    o.lua("""GO('s', 'A Meeting of Corridors', { n = -99, n_realnum = 42706, e = -99, e_realnum = 42717, w = -99, w_realnum = 42715 })""")
    eq(o.ev("sbo.mapRoom"), B + 42716, "the same room again")
    # following a friend: nothing typed - the new room's way back to this one says where it is
    o.lua("""GO(nil, 'A Large Gallery', { e = -99, e_realnum = 42716, s = -99, s_realnum = 42725 })""")
    eq(o.ev("sbo.mapRoom"), B + 42715, "came west: the room west of the last one")
    eq(o.ev("ROOMS[%d].x" % (B + 42715)), -1, "placed a step west")
    # a stale direction from long ago doesn't mislead
    o.lua("""sbo.tempNoteSend('n'); sbo.tempLastDirAt = os.time() - 60
      GO(nil, 'A Meeting of Corridors', { n = -99, n_realnum = 42706, e = -99, e_realnum = 42717, w = -99, w_realnum = 42715 })""")
    eq(o.ev("sbo.mapRoom"), B + 42716, "back east, by the way back")
    # following, into a disguised room (no exits): the room comes first, then "Roarke drifts east. / You follow Roarke."
    o.lua("""GO(nil, 'Mirrored Hallway', {})""")
    eq(o.ev("sbo.mapRoom"), B + 42716, "not placed yet")
    o.feed("Roarke drifts east.", "You follow Roarke.")
    eq(o.ev("sbo.mapRoom"), B + 42717, "placed once the follow line says which way")
    eq(o.ev("ROOMS[%d].x" % (B + 42717)), 1, "a step east")
    # its real name, seen later, replaces the disguise; a disguised visit doesn't rename it back
    o.lua("""GO('w', 'A Meeting of Corridors', { n = -99, n_realnum = 42706, e = -99, e_realnum = 42717, w = -99, w_realnum = 42715 })
      GO('e', 'A Five-Way Intersection', { w = -99, w_realnum = 42716, e = -99, e_realnum = 42718 })""")
    eq(o.ev("NAMES[%d]" % (B + 42717)), "A Five-Way Intersection", "the real name")
    o.lua("""GO('w', 'A Meeting of Corridors', { n = -99, n_realnum = 42706, e = -99, e_realnum = 42717, w = -99, w_realnum = 42715 })
      GO('e', 'Mirrored Hallway', {})""")
    eq(o.ev("NAMES[%d]" % (B + 42717)), "A Five-Way Intersection", "kept")
    # out of the area: the temporary map goes
    o.lua("""gmcp.room = { info = { num = 27937, zone = 'Sigil', name = 'Street', wilds = 'false', coord = { id = 1, name = 'Alyria', x = 435, y = 1226 } } }
      sbo.onRoom()""")
    eq((o.ev("sbo.tempMap"), o.ev("next(AREAS)")), (None, None), "cleared on leaving")
    # one left over from last time: cleared at the start
    o.lua("addAreaName('Oven: Tower of Riga'); sbo.tempCleanup()")
    eq(o.ev("next(AREAS)"), None, "cleared at the start")


@test
def world_map_follows_through_a_portal():
    o = Oven()
    o.lua("""DL = {}; downloadFile = function(path, url) DL[#DL+1] = url end
      sbo.mapMode = 'world'; sbo.worldLabel = { echo = function() end, setStyleSheet = function() end, show = function() end, hide = function() end }
      local function at(num, map, x, y, wild) gmcp.room = { info = { num = num, wilds = wild, coord = { name = map, x = x, y = y } } }; sbo.worldOnRoom(); sbo.worldDrawNow() end
      AT = at""")
    o.lua("AT('3933989', 'Alyria', 1709, 1710, 'true')")
    o.lua("AT('6102034', 'Faerie Plane', 200, 200, 'true')")
    assert any("faerieplane.bmp" in u for u in o.ev("DL").values()), list(o.ev("DL").values())
    eq(o.ev("sbo.worldV.map"), "Faerie Plane", "the map you are on")


@test
def world_waterways():
    o = Oven()
    home = o.L.globals().OVEN_TEST_HOME
    # a colour learned from a waterway before: wrong (it's the land above) - forgotten
    o.lua("sbo.cfg.world = { offsets = {}, terrain = { ['552de2'] = 'sailable-bridge', ['618347'] = 'plain' } }")
    eq(o.ev("sbo.worldWaterUnlearn()"), 1, "one wrong colour")
    eq((o.ev("sbo.cfg.world.terrain['552de2']"), o.ev("sbo.cfg.world.terrain['618347']")), (None, "plain"), "the plain one stays")
    # a sail: each room kept, the steps between joined; not a terrain colour
    o.lua("""local function at(x, y, t) sbo.worldNote({ num = tostring(1060834 + y * 2300 + x), wilds = 'true', terrain = t, coord = { name = 'Alyria', x = x, y = y } }) end
      at(500, 1000, 'plain'); at(514, 1004, 'sailable-bridge'); at(514, 1005, 'sailable-bridge'); at(505, 1014, 'sailable-bridge'); at(600, 1100, 'plain')""")
    W = "sbo.cfg.world.water.Alyria"
    eq(o.ev("(function() local n = 0 for _ in pairs(" + W + ".pts) do n = n + 1 end return n end)()"), 3, "three waterway rooms")
    eq(o.ev("(function() local n = 0 for _ in pairs(" + W + ".segs) do n = n + 1 end return n end)()"), 2, "joined in order")
    eq(o.ev("sbo.cfg.world.terrain['552de2']"), None, "no terrain learned from them")
    # from a recording (hand-written): read once
    open(home + "/oven_record.txt", "w").write(
        '===== 2026-11-16 22:00:00 | cmd= | room=1\n'
        '@gmcp room.info = {["num"]="3480909",["terrain"]="sailable-bridge",["coord"]={["y"]=1052,["x"]=475,["name"]="Alyria"},["wilds"]="true"}\n'
        '@gmcp room.info = {["num"]="3467116",["terrain"]="sailable-bridge",["coord"]={["y"]=1046,["x"]=482,["name"]="Alyria"},["wilds"]="true"}\n')
    eq(o.ev("sbo.worldWaterImport()"), 2, "two from the recording")
    assert o.ev(W + ".segs['475,1052>482,1046']"), "joined"
    eq(o.ev("sbo.worldWaterImport()"), 0, "once")


@test
def world_natural_colours():
    import struct, os as _os
    o = Oven()
    home = o.L.globals().OVEN_TEST_HOME
    _os.makedirs(home + "/oven_maps", exist_ok=True)
    # a 7 x 5 bitmap: green (a forest kind) on the left, magenta (a water kind) on the right
    W_, H_ = 7, 5
    rowb = ((W_ * 3 + 3) // 4) * 4
    def col(x, y): return bytes([200, 0, 200]) if x >= 4 else bytes([0, 160, 0])   # (blue, green, red)
    body = b"".join(b"".join(col(x, y) for x in range(W_)).ljust(rowb, b"\0") for y in range(H_ - 1, -1, -1))
    head = b"BM" + struct.pack("<IHHI", 54 + len(body), 0, 0, 54) + struct.pack("<IiiHHIIiiII", 40, W_, H_, 1, 24, 0, len(body), 2835, 2835, 0, 0)
    open(home + "/oven_maps/alyria.bmp", "wb").write(head + body)
    o.lua("sbo.worldImage('Alyria'); sbo.worldHere = { map = 'Alyria', x = 3, y = 2, wild = true }")
    # the game's mini-map round you (you at 3,2): * forest on the left, ~ water on the right
    for l in ["****~~~", "***@~~~", "****~~~"]:
        o.lua("sbo.worldMapLine(%r, nil)" % l)
    o.lua("sbo.worldMapLine('A Leafy Path', nil)")
    eq((o.ev("(next(sbo.cfg.world.pal['00a000'].sym))"), o.ev("sbo.cfg.world.pal['00a000'].sym['*']"), o.ev("(next(sbo.cfg.world.pal['c800c8'].sym))")), ("*", 11, "~"), "each colour's symbol")
    # drawn naturally: the green kind as forest, the magenta kind as water
    r = o.ev("""(function() local img = sbo.worldImage('Alyria') local rows = sbo.worldCut(img, 3, 2, 1, 7, 1)
      local s = rows[1] local function px(i) local b, g, r = s:byte(i * 3 + 1, i * 3 + 3) return r .. ',' .. g .. ',' .. b end
      return px(1) .. ' ' .. px(6) end)()""")
    eq(r, "52,112,52 45,90,170", "forest green, water blue")
    # not seen yet: grey; the game's own colours on request
    o.lua("sbo.cfg.world.pal = {}; sbo.worldNaturalReset()")
    r = o.ev("(function() local s = sbo.worldCut(sbo.worldImage('Alyria'), 3, 2, 1, 7, 1)[1] local b, g, r = s:byte(4, 6) return r .. ',' .. g .. ',' .. b end)()")
    eq(r, "62,62,66", "unknown: grey")
    # (a colour in all four corners is the sea - this little map's corners differ, so there's none here)
    eq(o.ev("next(sbo.worldEdges or {})"), None, "no edge colour")
    o.lua("sbo.cfg.worldColours = 'game'")
    r = o.ev("(function() local s = sbo.worldCut(sbo.worldImage('Alyria'), 3, 2, 1, 7, 1)[1] local b, g, r = s:byte(4, 6) return r .. ',' .. g .. ',' .. b end)()")
    eq(r, "0,160,0", "map.colours game: the bitmap's own")
    # one that is: drawn deep blue - also for a map already loaded by an Oven from before
    o.lua("sbo.worldImages = {}; sbo.cfg.worldColours = 'natural'")
    body2 = b"".join(b"".join(bytes([85, 213, 32]) if (x in (0, W_ - 1) or y in (0, H_ - 1)) else col(x, y) for x in range(W_)).ljust(rowb, b"\0") for y in range(H_ - 1, -1, -1))
    open(home + "/oven_maps/alyria.bmp", "wb").write(head + body2)
    o.lua("sbo.worldImage('Alyria').edgeChecked = nil; sbo.worldEdges = nil; sbo.worldNaturalReset()")
    r = o.ev("(function() local s = sbo.worldCut(sbo.worldImage('Alyria'), 3, 2, 1, 7, 1)[1] local b, g, r = s:byte(4, 6) return r .. ',' .. g .. ',' .. b end)()")
    eq(r, "14,30,82", "the open sea: darker than deep water")
    # still deep blue once the sea has learned its ~ (the mini-map draws all water as ~)
    o.lua("sbo.cfg.world.pal['20d555'] = { sym = { ['~'] = 50 } }; sbo.worldNaturalReset()")
    eq(o.ev("table.concat(sbo.worldNaturalRGB('20d555'), ',')"), "14,30,82", "the open sea with ~: still the darkest")
    # water kinds share ~ but not a colour: told apart by a specific name (deep, shallow, river), else by the
    # game's own colour - "salt water" is both the dark sea (|B blue) and the lighter one (|C cyan)
    o.lua("""sbo.cfg.world.terrain = sbo.cfg.world.terrain or {}
      local pal, ter = sbo.cfg.world.pal, sbo.cfg.world.terrain
      for hex, v in pairs({ aa0001 = { 'deep water' }, aa0002 = { 'shallow water' }, aa0004 = { 'river' },
                            aa0006 = { 'salt water', '0,0,255' }, aa0007 = { 'salt water', '0,255,255' }, aa0008 = { 'salt water' } }) do
        pal[hex] = { sym = { ['~'] = 9 }, rgb = v[2] and { [v[2]] = 9 } or nil }; ter[hex] = v[1]
      end""")
    eq([o.ev("table.concat(sbo.worldNaturalRGB('%s'), ',')" % h) for h in ("aa0001", "aa0002", "aa0004", "aa0006", "aa0007", "aa0008")],
       ["28,58,135", "72,122,190", "50,100,180", "28,58,135", "45,90,170", "45,90,170"],
       "deep, shallow, river, salt water drawn blue (deep), salt water drawn cyan (the sea), salt water not seen yet")
    # two bands of the same "salt water" cyan: the one along the coast is the shallows
    o.lua("""local pal = sbo.cfg.world.pal
      pal['bb0001'] = { sym = { ['~'] = 9 }, rgb = { ['0,255,255'] = 9 } }; sbo.cfg.world.terrain['bb0001'] = 'salt water'
      pal['bb0002'] = { sym = { ['~'] = 9 }, rgb = { ['0,255,255'] = 9 } }; sbo.cfg.world.terrain['bb0002'] = 'salt water'
      pal['bb0003'] = { sym = { ['.'] = 9 } }
      local function b(h) return string.char(tonumber(h:sub(5, 6), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(1, 2), 16)) end
      sbo.worldNb = { [b('bb0001')] = { [b('bb0002')] = 50, [b('aa0006')] = 50 },
                      [b('bb0002')] = { [b('bb0001')] = 50, [b('bb0003')] = 40 } }""")
    eq([o.ev("table.concat(sbo.worldNaturalRGB('%s'), ',')" % h) for h in ("bb0001", "bb0002")], ["45,90,170", "72,122,190"], "the sea, the shallows by the beach")
    # (also when drawn as a colour that is two things: its ~ regions keep the shallows)
    o.lua("sbo.cfg.world.reg = { ['alyria.bmp'] = { bb0002 = { ['0,0'] = { ['~'] = 5 }, ['9,9'] = { ['.'] = 5 } } } }; sbo.worldNaturalReset(); sbo.worldAmbig('alyria.bmp')")
    eq(o.ev("(function() local s = sbo.worldRegColour('alyria.bmp', string.char(2, 0, 187), 1, 1) local b, g, r = s:byte(1, 3) return r .. ',' .. g .. ',' .. b end)()"), "72,122,190", "drawn: still the shallows")
    o.lua("sbo.cfg.world.reg = nil; sbo.worldNaturalReset()")
    o.lua("sbo.worldNb = nil")
    # a land colour keeps its symbol's colour whatever its name
    o.lua("sbo.cfg.world.pal['aa0005'] = { sym = { ['*'] = 9 } }; sbo.cfg.world.terrain['aa0005'] = 'deep water'")
    eq(o.ev("table.concat(sbo.worldNaturalRGB('aa0005'), ',')"), "52,112,52", "symbol first on land")
    # a line of game text isn't a map row; one that looks like one isn't read without an @
    # the ASCII colour palette: the mini-map's own colours. The colour GMCP gave the terrain when you stood on it (|B, |C…, as
    # your Mudlet draws them, learned from the mini-map); else the colour the mini-map drew its symbol in there -
    # not the marks over it (a mountain colour with magenta I's on it stays grey); else the symbol's usual colour;
    # else the natural one; the open sea stays the darkest
    o.lua("""sbo.cfg.worldColours = nil
      NATURAL_DEFAULT = sbo.worldColourMode()
      sbo.cfg.worldColours = 'ascii'
      local pal = sbo.cfg.world.pal
      pal['aa0009'] = { sym = { ['*'] = 3 } }
      pal['aa000a'] = { sym = { ['^'] = 616, I = 120 }, sc = { ['^'] = { ['128,128,128'] = 92 }, I = { ['255,0,255'] = 121 } } }
      pal['aa000b'] = { sym = { ['^'] = 5 } }
      pal['aa000c'] = { sym = { ['~'] = 9 }, sc = { ['~'] = { ['0,0,250'] = 9 } } }
      sbo.worldLookNote('aa000c', '~', '|B'); sbo.worldLookNote('aa0007', '~', '|C')
      sbo.worldLookNote('aa000d', '#', '|Y')
      -- (learned before 1.63.1: colours not kept by symbol)
      pal['aa000e'] = { sym = { ['~'] = 9891, ['%'] = 2461 }, rgb = { ['0,0,255'] = 8946, ['0,128,0'] = 2461 } }
      pal['aa000f'] = { sym = { ['^'] = 616, I = 120, ['='] = 182 }, rgb = { ['255,0,255'] = 121, ['128,128,128'] = 92 } }
      sbo.worldNaturalReset()""")
    eq(o.ev("NATURAL_DEFAULT"), "natural", "natural by default")
    eq([o.ev("table.concat(sbo.worldAsciiRGB('%s'), ',')" % h) for h in ("aa000a", "aa000b", "aa000c", "aa0007", "aa000d", "aa0009", "20d555", "aa000e", "aa000f")],
       ["128,128,128", "128,128,128", "0,0,250", "0,255,255", "255,255,0", "52,112,52", "14,30,82", "0,0,255", "128,128,128"],
       "mountain under magenta marks, another ^ not seen in colour, |B as this Mudlet draws it, |C, |Y, * never seen in colour (natural), open sea, old votes: sea mostly blue, mountain not magenta")
    # GMCP's look of the room you're in is kept by the bitmap colour under you
    o.lua("sbo.worldNote({ num = '1027', wilds = 'true', terrain = 'plain', coord = { name = 'Alyria', x = 3, y = 2, sym = '*', color = '|y' } })")
    eq(o.ev("(function() local n = 0 for k, v in pairs(sbo.cfg.world.look) do if v.col == '|y' then n = n + 1 end end return n end)()"), 1, "learned from GMCP")
    # one colour, two things: a wall line (magenta I) in one place, specks in the mountains (^) in another - each
    # drawn as what the mini-map showed for it nearby
    o.lua("""sbo.cfg.world.pal['00a000'] = { sym = { I = 5, ['^'] = 5 }, sc = { I = { ['255,0,255'] = 5 } } }
      sbo.cfg.world.look = {}
      sbo.cfg.world.reg = nil
      for i = 1, 5 do sbo.worldRegNote('alyria.bmp', '00a000', 1, 1, 'I') end
      for i = 1, 5 do sbo.worldRegNote('alyria.bmp', '00a000', 200, 200, '^') end
      sbo.cfg.world.pal['00a000'].sym.I = 6; sbo.cfg.world.pal['00a000'].sc['^'] = { ['128,128,128'] = 4 }
      sbo.worldNaturalReset()""")
    eq(o.ev("sbo.worldRegSym('alyria.bmp', '00a000', 3, 2)"), "I", "near the wall")
    eq(o.ev("sbo.worldRegSym('alyria.bmp', '00a000', 210, 190)"), "^", "in the mountains")
    r = o.ev("(function() local s = sbo.worldCut(sbo.worldImage('Alyria'), 3, 2, 1, 7, 1)[1] local b, g, r = s:byte(10, 12) return r .. ',' .. g .. ',' .. b end)()")
    eq(r, "255,0,255", "drawn as the wall there (2, 2)")
    eq(o.ev("table.concat(sbo.worldAsciiRGB('00a000', '^'), ',')"), "128,128,128", "and as the mountains' ^ elsewhere")
    # a colour that is the deep sea and a jungle walked through every day (seen as % far more often): unseen, it's
    # what it borders - the sea
    o.lua("""local pal = sbo.cfg.world.pal
      pal['cc0001'] = { sym = { ['~'] = 100, ['%'] = 900 } }
      pal['cc0002'] = { sym = { ['~'] = 50 } }; pal['cc0003'] = { sym = { ['.'] = 50 } }
      sbo.cfg.world.reg = nil; sbo.cfg.world.ctx = nil
      local function b(h) return string.char(tonumber(h:sub(5, 6), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(1, 2), 16)) end
      sbo.worldNb = { [b('cc0001')] = { [b('cc0002')] = 400, [b('cc0003')] = 30 } }
      sbo.worldNaturalReset()""")
    eq((o.ev("sbo.worldUsualSym('cc0001')"), o.ev("sbo.worldAreaSym('cc0001')")), ("%", "~"), "seen most as jungle, but it lies by the sea")
    o.lua("sbo.worldNb = nil; sbo.worldNaturalReset()")
    eq((o.ev("sbo.worldMapRowLike('The Light Forest')"), o.ev("sbo.worldMapRowLike('   ~~..!!@==')")), (False, True), "rows")


@test
def world_map():
    import struct, os as _os
    o = Oven()
    home = o.L.globals().OVEN_TEST_HOME
    _os.makedirs(home + "/oven_maps", exist_ok=True)
    # a 10 × 6 Alyria: green, with one blue pixel at (7, 2)
    W_, H_ = 10, 6
    rowb = ((W_ * 3 + 3) // 4) * 4
    px = {(7, 2): bytes([200, 0, 0])}
    body = b"".join(b"".join(px.get((x, y), bytes([0, 160, 0])) for x in range(W_)).ljust(rowb, b"\0") for y in range(H_ - 1, -1, -1))
    head = b"BM" + struct.pack("<IHHI", 54 + len(body), 0, 0, 54) + struct.pack("<IiiHHIIiiII", 40, W_, H_, 1, 24, 0, len(body), 2835, 2835, 0, 0)
    open(home + "/oven_maps/alyria.bmp", "wb").write(head + body)
    o.lua("""sbo.WORLD_FILES[1].offset = 1000
      roomExists = function(id) return true end; getRoomArea = function(id) return tonumber(id) >= 5000 and 7 or 1 end""")
    # a wild room's number is its pixel; GMCP teaches the numbering and the terrain's colour
    o.lua("""sbo.worldImage('Alyria')
      sbo.worldNote({ num = '1027', wilds = 'true', terrain = 'lake', coord = { name = 'Alyria', x = 7, y = 2 } })""")
    eq(o.ev("sbo.cfg.world.offsets.Alyria"), 1000, "offset learned")
    eq(o.ev("sbo.cfg.world.terrain['0000c8']"), "lake", "the blue pixel is a lake")
    p = o.ev("sbo.worldPos(1000 + 3 * 10 + 4)")
    eq((p.x, p.y), (4, 3), "room → pixel")
    # a town room: where GMCP said it was; another of its area: there too
    o.lua("sbo.worldNote({ num = '5001', wilds = 'false', coord = { name = 'Alyria', x = 2, y = 1 } })")
    eq((o.ev("sbo.worldPos(5001).x"), o.ev("sbo.worldPos(5001).y")), (2, 1), "a visited town room")
    o.lua("sbo.worldRoomXY = {}")
    eq(o.ev("sbo.worldPos(5999).x"), 2, "a room of the same area")
    o.lua("sbo.cfg.worldNatural = false")   # (the bitmap colours here; natural ones: world_natural_colours)
    # the cut-out at ×2, sharp: 4 × 4 screen pixels around (7, 2)
    n, w1, blue = o.ev("""function() local img = sbo.worldImage('Alyria') local r = sbo.worldCut(img, 7, 2, 2, 4, 4)
      return #r, #r[1], r[3]:sub(1 + 2 * 3, 3 + 2 * 3) == string.char(200, 0, 0) end""")()
    eq((n, w1, blue), (4, 12, True), "4 rows of 4 pixels, (7,2) in the middle, two screen pixels a room")
    # the bitmap it writes reads back
    ok = o.ev("""function() local img = sbo.worldImage('Alyria') local r = sbo.worldCut(img, 5, 3, 1, 8, 6) local b = sbo.worldBmp(r, 8)
      local function le(i) return b:byte(i) + b:byte(i + 1) * 256 end
      return b:sub(1, 2) == 'BM' and le(19) == 8 and le(23) == 6 and #b == 54 + 8 * 3 * 6 end""")()
    assert ok, "a 8 × 6 bitmap"
    # the panel: World draws a file with you on it; walking into the wilds switches to World, a town back to Local
    o.lua("""sbo.cfg.map = true; sbo.cfg.mapPanel = true; sbo.createMapPanel()
      gmcp.room = { info = { num = '1027', wilds = 'true', terrain = 'lake', coord = { name = 'Alyria', x = 7, y = 2 } } }
      sbo.worldWasWild = false; sbo.worldOnRoom(); runTimers()""")
    eq(o.ev("sbo.mapMode"), "world", "into the wilds: World")
    css = o.ev("WIDGETS.ovenWorldMap.css") or ""
    assert "border-image" in css and "oven_world_" in css, css
    o.lua("""gmcp.room.info = { num = '5001', wilds = 'false', coord = { name = 'Alyria', x = 2, y = 1 } }; sbo.worldOnRoom(); runTimers()""")
    eq(o.ev("sbo.mapMode"), "local", "back in town: Local")
    # the button switches by hand
    o.lua("sbo.mapSetMode('world')")
    eq((o.ev("sbo.mapMode"), o.ev("WIDGETS.ovenWorldMap.shown")), ("world", True), "switched")
    # zoom and drag
    o.lua("sbo.worldZoom(1)")
    eq(o.ev("sbo.worldV.zoomI"), 6, "zoomed in")
    o.lua("""MX, MY = 100, 100; getMousePosition = function() return MX, MY end
      sbo.worldPress({ button = 'LeftButton', x = 10, y = 10 }); MX = 140; sbo.worldMove(); sbo.worldRelease()""")
    eq(o.ev("sbo.worldV.follow"), False, "dragging stops following")
    o.lua("sbo.worldFollow()")
    eq(o.ev("sbo.worldV.follow"), True, "◎ follows again")
    # a search: zoomed and moved to fit its matches
    o.lua("""sbo.mapSearchRooms = function() return { 1000 + 1 * 10 + 1, 1000 + 4 * 10 + 8 } end
      sbo.worldLabel.get_width = function() return 120 end; sbo.worldLabel.get_height = function() return 80 end
      sbo.worldSearch('x')""")
    eq((o.ev("sbo.worldV.cx"), o.ev("sbo.worldV.cy"), o.ev("sbo.worldV.follow")), (5, 3, False), "centred on the matches")
    eq(o.ev("sbo.WORLD_ZOOMS[sbo.worldV.zoomI]"), 4, "as close as fits")
    # a walk that goes under: the underworld's part drawn on Alyria, in blue (the underworld learned from a room there)
    o.lua("""sbo.worldFound = nil; sbo.worldNote({ num = tostring(90000 + 2300 + 5), wilds = 'true', coord = { name = 'Underworld', x = 5, y = 1 } })
      sbo.worldNote({ num = '1027', wilds = 'true', coord = { name = 'Alyria', x = 7, y = 2 } })
      sbo.goAsk = nil; sbo.walk = { path = { 1000 + 2 * 10 + 6, 90000 + 1 * 2300 + 5 }, step = 1 }
      sbo.worldV = { zoomI = 4, follow = false, cx = 5, cy = 2, map = 'Alyria' }
      sbo.worldLabel.get_width = function() return 40 end; sbo.worldLabel.get_height = function() return 24 end
      local here = sbo.worldHere; sbo.worldHere = nil   -- (your marker would cover these few pixels)
      sbo.worldDrawNow(); sbo.worldHere = here""")
    eq(o.ev("sbo.cfg.world.offsets.Underworld"), 90000, "the underworld's numbering, from a room there")
    assert o.ev("sbo.worldStacked('Alyria', 'Underworld')") and not o.ev("sbo.worldStacked('Alyria', 'Faerie Plane')")
    blue = o.ev("""function() local f = io.open(sbo.worldLastFile, 'rb') local d = f:read('*a') f:close()
      return d:find(string.char(255, 150, 60), 55, true) ~= nil, d:find(string.char(30, 230, 255), 55, true) ~= nil end""")()
    assert blue == (True, True), f"the overland part yellow, the underworld part blue: {blue}"
    o.lua("sbo.worldLayer()")
    eq(o.ev("sbo.worldV.map"), "Underworld", "⇅: the layer below, same place")
    o.lua("sbo.worldLayer()")
    eq(o.ev("sbo.worldV.map"), "Alyria", "and back up")
    muted = o.ev("""function() local img = sbo.worldImage('Alyria') local r = sbo.worldCut(img, 7, 2, 1, 4, 4, true)
      local b, g, rr = r[3]:byte(7, 9) return rr + g + b end""")()
    assert muted < 200 * 0.6, f"the blue pixel, muted: {muted}"


    # the wheel zooms toward the mouse: the room under it stays under it
    o.lua("""sbo.worldFound = nil; sbo.walk = nil; sbo.worldLabel.get_width = function() return 200 end; sbo.worldLabel.get_height = function() return 120 end
      sbo.worldV = { zoomI = 3, follow = false, cx = 5, cy = 3, map = 'Alyria' }; sbo.worldDrawNow()
      function UNDER(ex, ey) local vw = sbo.worldView local z = vw.zoom local rp = z >= 1 and 1 / z or math.floor(1 / z + 0.5)
        return math.floor(vw.x0 + ex * rp) .. ',' .. math.floor(vw.y0 + ey * rp) end""")
    for d, ex, ey in [(120, 150, 30), (120, 150, 30), (-120, 150, 30), (120, 20, 100), (-120, 20, 100)]:
        before = o.ev("UNDER(%d, %d)" % (ex, ey))
        o.lua("sbo.worldWheel({ angleDeltaY = %d, x = %d, y = %d }); sbo.worldDrawNow()" % (d, ex, ey))
        eq(o.ev("UNDER(%d, %d)" % (ex, ey)), before, "zoom %+d at %d,%d keeps the room under the mouse" % (d, ex, ey))
    eq(o.ev("sbo.worldV.follow"), False, "and stops following (◎ to follow again)")

@test
def route_plan_text():
    o = Oven()
    o.lua("""sbo.mapRoom = 1
      -- 1-3 Sigil (area 1); 10 the north-gate signpost and 20 Vospire's east gate (area 2, the wilds); 30 Main Street (area 3)
      AREA = { [1] = 1, [2] = 1, [3] = 1, [10] = 2, [20] = 2, [30] = 3, [5] = 1 }
      NAMES = { [1] = 'Library', [10] = 'North Road', [20] = 'East Road', [30] = 'Main Street' }
      roomExists = function(id) return AREA[tonumber(id)] ~= nil end
      getRoomArea = function(id) return AREA[tonumber(id)] end
      getRoomAreaName = function(a) return ({ 'Sigil', 'Alyria', 'Vospire' })[a] end
      getRoomName = function(id) return NAMES[tonumber(id)] or ('room ' .. id) end
      ROUTES = { ['1>10'] = { {'n',2}, {'n',3}, {'n',10} }, ['20>30'] = { {'w',30} },
        ['1>30'] = {}, ['10>30'] = {} }
      for i = 1, 60 do table.insert(ROUTES['1>30'], { i == 30 and 'enter mirror' or 'w', i < 20 and 2 or (i < 59 and 10 or 30) }) end
      getPath = function(a, b) local r = ROUTES[tonumber(a) .. '>' .. tonumber(b)]; if not r then return false end
        speedWalkDir, speedWalkPath = {}, {}
        for i, x in ipairs(r) do speedWalkDir[i] = x[1]; speedWalkPath[i] = tostring(x[2]) end return true end
      sbo.signposts = function() return { { room = 10, dests = { vospire = 'north' } } } end
      sbo.signAt = function(r) if r == 10 then return { sign = "a weatherbeaten signpost outside Sigil's north gate" } end
        if r == 20 then return { sign = "a weatherbeaten signpost outside Vospire's east gate" } end end
      sbo.cfg.runs = { names = { vospire = {} }, ends = { vospire = 20 }, endsFixed = 1 }""")
    lines, sum = o.ev("function() return sbo.routePlanLines(1, 30) end")()
    eq(list(lines.values()), ["3 steps to the signpost outside Sigil's north gate", "run vospire to the signpost outside Vospire's east gate",
        "1 step to Main Street"], "a run, with its signposts, a line each")
    eq(sum, "about 29 steps instead of 60 on foot", "and what it saves")
    # printed as numbered lines
    o.lua("LOGS = {}; sbo.log = function(m) LOGS[#LOGS+1] = m end; sbo.sayPlan('walk:', ({ sbo.routePlanLines(1, 30) })[1], 'about 29')")
    logs = list(o.ev("LOGS").values())
    assert len(logs) == 5 and "1." in logs[1] and "3." in logs[3], logs
    # no run worth it: on foot, the areas and the mirror
    o.lua("sbo.cfg.runs.ends = {}; sbo.signposts = function() return {} end")
    lines, sum = o.ev("function() return sbo.routePlanLines(1, 30) end")()
    eq(list(lines.values()), ["60 steps on foot to Main Street", "through Sigil → Alyria → enter mirror → Vospire"], "on foot")


@test
def travel_by_ganuk():
    o = Oven()
    # a small map, searched like Mudlet does (Dijkstra): exits cost 1, special exits their weight
    o.lua("""SENT = {}; send = function(c) SENT[#SENT+1] = c; sbo.onSend(nil, c) end
      LOGS = {}; sbo.log = function(m) LOGS[#LOGS+1] = m end
      AREA, EX, SPECIAL, WEIGHT = {}, {}, {}, {}
      local NAMES = { 'Towne of Rune', 'Sigil', 'Alyria', 'Lowangen', 'The Towne of New Rigel', 'Megaleios Clan Hall', 'Mandrake Woods' }
      getRoomAreaName = function(a) return NAMES[a] end
      getAreaTable = function() local t = {} for i, n in ipairs(NAMES) do t[n] = i end return t end
      roomExists = function(id) return AREA[tonumber(id)] ~= nil end
      getRoomArea = function(id) return AREA[tonumber(id)] end
      getRoomName = function(id) return 'room ' .. id end
      function CHAIN(area, rooms, dir) for i, r in ipairs(rooms) do AREA[r] = area; EX[r] = EX[r] or {}
        if rooms[i + 1] then EX[r][#EX[r] + 1] = { dir, rooms[i + 1] } end end end
      addSpecialExit = function(a, b, cmd) if not AREA[a] or not AREA[b] then error('no room') end SPECIAL[a] = SPECIAL[a] or {}; SPECIAL[a][cmd] = b end
      removeSpecialExit = function(a, cmd) if SPECIAL[a] then SPECIAL[a][cmd] = nil end; WEIGHT[a .. cmd] = nil end
      setExitWeight = function(a, cmd, w) WEIGHT[a .. cmd] = w end
      CALLS = 0
      getPath = function(a, b)
        CALLS = CALLS + 1
        a, b = tonumber(a), tonumber(b)
        local dist, prev, done = { [a] = 0 }, {}, {}
        while true do
          local u, du
          for r, d in pairs(dist) do if not done[r] and (not du or d < du) then u, du = r, d end end
          if not u then return false end
          if u == b then break end
          done[u] = true
          local function relax(dir, v, w) if not dist[v] or du + w < dist[v] then dist[v] = du + w; prev[v] = { u, dir } end end
          for _, e in ipairs(EX[u] or {}) do relax(e[1], e[2], 1) end
          for cmd, v in pairs(SPECIAL[u] or {}) do relax(cmd, v, WEIGHT[u .. cmd] or 1) end
        end
        local dirs, path, r = {}, {}, b
        while r ~= a do table.insert(dirs, 1, prev[r][2]); table.insert(path, 1, tostring(r)); r = prev[r][1] end
        speedWalkDir, speedWalkPath = dirs, path
        return true
      end
      sbo.signposts = function() return {} end
      sbo.cfg.runs = { names = {}, ends = {}, endsFixed = 1 }
      gmcp.char = gmcp.char or {}; gmcp.char.worth = { gold = 2000, bank = 579098 }
      sbo.walkStep = function() WALK = sbo.walk end
      centerview = function() end; updateMap = function() end; REALWALK = sbo.mapWalkTo
      local tt = tempTimer; tempTimer = function(d, f, r) if d >= 5 then return 0 end return tt(d, f, r) end   -- (no stall checks)
      -- Rune: you (1) and Ganuk (10636); Sigil: its exit (500) and the target (600) - no road between
      CHAIN(1, { 1, 2, 3, 4, 5, 10636 }, 'e'); CHAIN(1, { 10637 }, 'x')
      CHAIN(2, { 500, 501, 502, 600 }, 'n')
      sbo.dbx("INSERT INTO shops (room, name, last) VALUES (10636, %s, 0)", "Ganuk's Express Travels")
      sbo.dbx("INSERT INTO shop_items (room, no, item, level, amount, cost, last) VALUES (10636, 4, 'A token for Sigil passage', 25, 'No limit', 3625, 0)")
      sbo.dbx("INSERT INTO shop_items (room, no, item, level, amount, cost, last) VALUES (10636, 12, 'A token for passage to Irda Isle', 25, 'No limit', 50000, 0)")
      sbo.dbx("INSERT INTO where_rooms (area, feature, room, start, dirs, t) VALUES ('Sigil', 'exit', 500, 0, '', 0)")
      sbo.mapRoom = 1""")
    eq((o.ev("#sbo.travelLinks()"), o.ev("sbo.travelLinks()[1].dest")), (2, "Sigil"), "read from the shop list")
    o.lua("sbo.goTo(600)")
    text = "\n".join(o.ev("LOGS").values())
    assert "5 steps to room 10636" in text and "Iron Worm to Sigil - 3,625 gold" in text and "about 3 steps on to room 600" in text, text
    assert "costs 3,625 gold in all" in text and "you carry 2,000" in text and "y to go" in text, text
    eq((o.ev("#SENT"), o.ev("next(SPECIAL[10636] or {})")), (0, None), "nothing sent; the map left as it was")
    eq(o.ev("sbo.goAnswer('n')"), True, "n")
    eq(o.ev("#SENT"), 0, "n: nothing")
    # y: walk to Ganuk, buy, down, give, land, walk on
    o.lua("sbo.goTo(600); sbo.goAnswer('y'); runTimers()")
    eq((o.ev("sbo.trip.waitAt"), o.ev("#WALK.dirs")), (10636, 5), "walking to Ganuk")
    o.lua("sbo.walk = nil; sbo.mapRoom = 10636; sbo.tripOnRoom(10636); runTimers()")
    eq(o.ev("SENT[#SENT]"), "shop buy 4", "the token")
    o.feed("Ganuk Jr. takes your payment and hands you a token for Sigil passage.")
    o.lua("runTimers()")
    eq(o.ev("SENT[#SENT]"), "down", "down to Ganuk")
    o.lua("sbo.mapRoom = 10637; sbo.travelOnRoom(10637); runTimers()")
    eq(o.ev("SENT[#SENT]"), "give token ganuk", "the token handed over")
    o.lua("runTimers(); WALKED = nil; sbo.mapWalkTo = function(id) WALKED = id end; CHAIN(2, { 499, 500 }, 'n'); sbo.mapRoom = 499; sbo.travelOnRoom(499); runTimers()")
    eq((o.ev("WALKED"), o.ev("sbo.trip"), o.ev("sbo.travel")), (600, None, None), "landed: on to the room asked for")
    # two runs in a row (no ride): the trip runs both
    o.lua("""CHAIN(3, { 3000, 3001 }, 'e'); CHAIN(3, { 3100, 3101 }, 'e'); CHAIN(2, { 3200, 3201 }, 'e')
      for i = 1, 200 do EX[3001][#EX[3001] + 1] = nil end
      local long = {} for i = 1, 150 do long[i] = 4000 + i end; long[1] = 3001; long[151] = 3100; CHAIN(3, long, 's')
      local long2 = {} for i = 1, 150 do long2[i] = 5000 + i end; long2[1] = 3101; long2[151] = 3200; CHAIN(3, long2, 's')
      AREA[3200], AREA[3201] = 2, 2
      sbo.signposts = function() return { { room = 3001, dests = { mid = 'south' } }, { room = 3101, dests = { far = 'south' } } } end
      sbo.cfg.runs = { names = { mid = {}, far = {} }, ends = { mid = 3100, far = 3200 }, endsFixed = 1 }
      sbo.signLabel = function(r) return 'signpost ' .. r end
      sbo.cfg.clanHall = nil; sbo.dbx("DELETE FROM shop_items")
      sbo.mapRoom = 3000; LOGS = {}; SENT = {}""")
    o.lua("sbo.goTo(3201)")
    text = "\n".join(o.ev("LOGS").values())
    assert "run mid" in text and "run far" in text and "y to go" in text, text
    o.lua("sbo.goAnswer('y'); runTimers(); sbo.walk = nil; sbo.mapRoom = 3001; sbo.tripOnRoom(3001); runTimers()")
    eq(o.ev("SENT[#SENT]"), "run mid", "the first run")
    o.lua("sbo.running.started = true; sbo.mapRoom = 3100; sbo.runStopped(true); runTimers(); sbo.walk = nil; sbo.mapRoom = 3101; sbo.tripOnRoom(3101); runTimers()")
    eq(o.ev("SENT[#SENT]"), "run far", "then the second")
    o.lua("WALKED = nil; sbo.mapWalkTo = function(id) WALKED = id end; sbo.running.started = true; sbo.mapRoom = 3200; sbo.runStopped(true); runTimers()")
    eq((o.ev("WALKED"), o.ev("sbo.trip")), (3201, None), "and the last step")
    o.lua("sbo.mapWalkTo = REALWALK")
    # a long walk through the wilds: the wild rooms made dearer and looked again - a run wins where there is one;
    # none: the plan says so (rooms 1,000,000 and up are the wilds)
    o.lua("""getRoomWeight = function(r) return RW and RW[r] or 1 end; setRoomWeight = function(r, w) RW = RW or {}; RW[r] = w end
      local function wild(a, b, n) local c = { a } for i = 1, n do c[#c + 1] = 1100000 + a * 1000 + i end c[#c + 1] = b; CHAIN(3, c, 'n') end
      CHAIN(7, { 7000 }, 'x'); CHAIN(5, { 7100 }, 'x'); AREA[7000], AREA[7100] = 7, 5
      wild(7000, 7100, 90); AREA[7000], AREA[7100] = 7, 5
      sbo.signposts = function() return {} end; sbo.cfg.runs = { names = {}, ends = {}, endsFixed = 1 }
      sbo.mapRoom = 7000; LOGS = {}; SENT = {}""")
    o.lua("sbo.goTo(7100)")
    text = "\n".join(o.ev("LOGS").values())
    assert "⚠ 90 rooms of wilds on foot" in text and "y to go" in text, text
    eq(o.ev("(function() local n, bad = 0, 0 for _, w in pairs(RW or {}) do n = n + 1; if w ~= 1 then bad = bad + 1 end end return n > 50 and bad == 0 end)()"), True, "the wild rooms made dearer for the search - and put back")
    # with a signpost run beside that walk: the search takes the run
    o.lua("""CHAIN(3, { 7000, 7050 }, 'e'); CHAIN(3, { 7060, 7100 }, 'e'); AREA[7050], AREA[7060] = 3, 3
      EX[7000] = { { 'e', 7050 }, { 'n', 8100001 } }; AREA[7000], AREA[7100] = 7, 5
      sbo.signposts = function() return { { room = 7050, dests = { townb = 'north' } } } end
      sbo.cfg.runs = { names = { townb = {} }, ends = { townb = 7060 }, endsFixed = 1 }
      LOGS = {}""")
    o.lua("sbo.goTo(7100)")
    text = "\n".join(o.ev("LOGS").values())
    assert "run townb" in text and "rooms of wilds" not in text, text
    # chained: the Worm to Lowangen, Gerry's balloon on to New Rigel (it takes off once bought)
    o.lua("""CHAIN(4, { 700, 701, 702, 703, 16091 }, 'w'); CHAIN(5, { 62000, 62001, 62100 }, 's')
      sbo.dbx("INSERT INTO shop_items (room, no, item, level, amount, cost, last) VALUES (10636, 1, 'A token for Lowangen passage', 25, 'No limit', 3625, 0)")
      sbo.dbx("INSERT INTO shops (room, name, last) VALUES (16091, %s, 0)", "Gerry's Hot Air Balloon Travels")
      sbo.dbx("INSERT INTO shop_items (room, no, item, level, amount, cost, last) VALUES (16091, 1, 'A ticket to New Rigel', 1, 'No limit', 2500, 0)")
      sbo.dbx("INSERT INTO where_rooms (area, feature, room, start, dirs, t) VALUES ('Lowangen', 'exit', 700, 0, '', 0)")
      sbo.dbx("INSERT INTO where_rooms (area, feature, room, start, dirs, t) VALUES ('The Towne of New Rigel', 'exit', 62000, 0, '', 0)")
      sbo.mapRoom = 1; LOGS = {}; CALLS = 0""")
    o.lua("sbo.goTo(62100)")
    text = "\n".join(o.ev("LOGS").values())
    assert "Iron Worm to Lowangen - 3,625 gold" in text and "4 steps to room 16091" in text and "balloon to New Rigel - 2,500 gold" in text, text
    assert "costs 6,125 gold in all" in text, text
    eq(o.ev("CALLS"), 2, "one search for the trip (and one for the walk on foot)")
    # the clan hall, walk out until Mandrake Woods' signpost is the nearest, recall, run to Rune
    o.lua("""CHAIN(6, { 384334 }, 'x'); CHAIN(3, { 1900988 }, 'x'); CHAIN(3, { 1500000 }, 'x'); CHAIN(1, { 10490, 10491, 10495 }, 'e')
      sbo.cfg.clanHall = 384334
      POS = { [384334] = { map = 'Alyria', x = 560, y = 216 }, [1900988] = { map = 'Alyria', x = 654, y = 365 }, [1500000] = { map = 'Alyria', x = 560, y = 150 } }
      sbo.worldPos = function(r) return POS[tonumber(r)] end
      sbo.signposts = function() return { { room = 1900988, dests = { rune = 'south' } }, { room = 1500000, dests = { civmar = 'north' } } } end
      sbo.cfg.runs = { names = { rune = {} }, ends = { rune = 10490 }, endsFixed = 1 }
      sbo.runForArea = function(id) return getRoomArea(id) == 1 and 'rune' or nil end
      sbo.signLabel = function(r) return r == 1900988 and 'signpost on the Shadow Road' or 'signpost near the hall' end
      sbo.mapRoom = 600; LOGS = {}; SENT = {}; sbo.mapWalkTo = function(id) WALKED = id end""")
    o.lua("sbo.goTo(10495)")
    text = "\n".join(o.ev("LOGS").values())
    for want in ["clan gohall to Megaleios Clan Hall", "out of the hall, 5 east, about 60 south", "recall to the signpost on the Shadow Road", "run rune to the", "about 2 steps on to room 10495", "the trip is free"]:
        assert want in text, (want, text)
    o.lua("sbo.goAnswer('y'); runTimers()")
    eq(o.ev("SENT[#SENT]"), "clan gohall", "first the hall")
    o.lua("""gmcp.room = { info = { num = '384334', wilds = 'false', exits = { n = '1558194' }, coord = { name = 'Alyria', x = 560, y = 216 } } }
      sbo.mapRoom = 384334; sbo.travelOnRoom(384334); runTimers()""")
    eq(o.ev("SENT[#SENT]"), "n", "out of the hall")
    steps = o.ev("""(function()
      local x, y, n = 560, 216, 0
      local D = { n = {0,-1}, s = {0,1}, e = {1,0}, w = {-1,0}, ne = {1,-1}, nw = {-1,-1}, se = {1,1}, sw = {-1,1} }
      while D[SENT[#SENT]] and n < 300 do
        local d = D[SENT[#SENT]]
        if n > 0 then x, y = x + d[1], y + d[2] end
        n = n + 1
        gmcp.room = { info = { num = tostring(2000000 + n), wilds = 'true', coord = { name = 'Alyria', x = x, y = y } } }
        sbo.mapRoom = 2000000 + n; sbo.travelCastStep()
      end
      return n
    end)()""")
    assert 10 < steps < 150, steps
    walked = [x for x in o.ev("SENT").values() if x in ("n", "s", "e", "w", "se", "sw", "ne", "nw")]
    eq((walked[:7], set(walked[7:])), (["n", "e", "e", "e", "e", "e", "s"], {"s"}), "out, 5 east, then south")
    eq(o.ev("SENT[#SENT]"), "cast 'word of recall'", "recall once it's the nearest")
    o.lua("runTimers(); WALKED = nil; sbo.mapRoom = 1900988; sbo.travelOnRoom(1900988); runTimers()")
    eq(o.ev("SENT[#SENT]"), "run rune", "recalled at the signpost: the run")
    o.lua("sbo.running.started = true; sbo.mapRoom = 10490; sbo.runStopped(true); runTimers()")
    eq((o.ev("WALKED"), o.ev("sbo.trip")), (10495, None), "the run's over: the last steps on foot")
    # a room of the wilds that isn't on the map (just outside the hall): planned from where it is - never "no route"
    o.lua("""sbo.travel = nil; sbo.trip = nil; POS[1595001] = { map = 'Alyria', x = 567, y = 232 }
      gmcp.room = { info = { num = '1595001', wilds = 'true', coord = { name = 'Alyria', x = 567, y = 232 } } }
      sbo.mapRoom = 1595001; LOGS = {}; SENT = {}""")
    eq(o.ev("roomExists(1595001)"), False, "not on the map")
    o.lua("sbo.goTo(10495)")
    text = "\n".join(o.ev("LOGS").values())
    assert "no route" not in text and "recall to the signpost on the Shadow Road" in text and "run rune" in text and "y to go" in text, text
    o.lua("sbo.goAnswer('y'); runTimers()")
    first = o.ev("SENT[1]")
    assert first in ("s", "se", "e", "clan gohall"), (first, list(o.ev("SENT").values()))
    # a recall point that's already the nearest outside the hall: still 30 rooms (north) before recalling
    cands = o.lua("""local c = sbo.clanRecallCandidates(10495) local o = {}
      for _, x in ipairs(c) do o[#o+1] = x.link.recall.room .. ':' .. x.link.clanRoute.dir .. x.link.clanRoute.n end return table.concat(o, ',')""")
    assert "1500000:n30" in cands, cands
    o.lua("""SENT = {}; sbo.trip = nil; sbo.travel = { stage = 'toCast', steps = 0, link = sbo.clanRecallCandidates(10495)[2].link }
      if sbo.travel.link.recall.room ~= 1500000 then sbo.travel.link = sbo.clanRecallCandidates(10495)[1].link end""")
    o.ev("""(function()
      local x, y, n = 560, 216, 0
      local D = { n = {0,-1}, s = {0,1}, e = {1,0} }
      gmcp.room = { info = { num = '1558194', wilds = 'true', coord = { name = 'Alyria', x = x, y = y } } }
      sbo.travelCastStep()
      while D[SENT[#SENT]] and n < 300 do
        local d = D[SENT[#SENT]]; x, y = x + d[1], y + d[2]; n = n + 1
        gmcp.room = { info = { num = tostring(2100000 + n), wilds = 'true', coord = { name = 'Alyria', x = x, y = y } } }
        sbo.travelCastStep()
      end
    end)()""")
    walked2 = list(o.ev("SENT").values())
    eq((walked2[:5], walked2[5:-1]), (["e"] * 5, ["n"] * 30), "5 east, 30 north, even though it was the nearest already")
    eq(walked2[-1], "cast 'word of recall'", "then recall")
    # in the wilds, nowhere on the map joined to anything: first straight to the nearest signpost, the trip on
    # from there (its run)
    o.lua("""sbo.mapWalkTo = REALWALK; sbo.trip = nil; sbo.travel = nil; sbo.cfg.clanHall = nil
      CHAIN(3, { 1250000 }, 'x'); POS[1250000] = { map = 'Alyria', x = 650, y = 360 }
      sbo.signposts = function() return { { room = 1900988, dests = { rune = 'south' } } } end
      sbo.cfg.runs = { names = { rune = {} }, ends = { rune = 10490 }, endsFixed = 1 }
      gmcp.room = { info = { num = '1250000', wilds = 'true', coord = { name = 'Alyria', x = 650, y = 360 } } }
      sbo.mapRoom = 1250000; LOGS = {}; SENT = {}""")
    o.lua("sbo.goTo(10495)")
    text = "\n".join(o.ev("LOGS").values())
    assert "about 5 rooms southeast to the signpost on the Shadow Road" in text and "run rune" in text and "y to go" in text, text
    o.lua("sbo.goAnswer('y'); runTimers()")
    eq(o.ev("SENT[#SENT]"), "se", "a room toward the signpost")
    o.lua("""gmcp.room = { info = { num = '1900988', wilds = 'true', coord = { name = 'Alyria', x = 654, y = 365 } } }
      sbo.mapRoom = 1900988; sbo.travelOnRoom(1900988); runTimers(); runTimers()""")
    eq(o.ev("SENT[#SENT]"), "run rune", "there: the run")
    o.lua("sbo.running = nil; sbo.trip = nil; sbo.travel = nil")
    # wilds to wilds (one area, the size of the world): no way on foot between the two shores - the Worm
    o.lua("""sbo.mapWalkTo = REALWALK; sbo.trip = nil; sbo.cfg.clanHall = nil
      sbo.signposts = function() return {} end; sbo.cfg.runs = { names = {}, ends = {}, endsFixed = 1 }
      sbo.dbx("INSERT INTO shop_items (room, no, item, level, amount, cost, last) VALUES (10636, 4, 'A token for Sigil passage', 25, 'No limit', 3625, 0)")
      CHAIN(3, { 1200001, 1200002 }, 'e'); EX[1200002][#EX[1200002] + 1] = { 'w', 1 }
      CHAIN(3, { 1300001 }, 'x'); EX[600][#EX[600] + 1] = { 'n', 1300001 }
      gmcp.room = { info = { num = '1200001', wilds = 'true', coord = { name = 'Alyria', x = 1, y = 1 } } }
      sbo.mapRoom = 1200001; LOGS = {}; SENT = {}""")
    o.lua("sbo.goTo(1300001)")
    text = "\n".join(o.ev("LOGS").values())
    assert "Iron Worm to Sigil" in text and "y to go" in text and "no route" not in text, text
    # an island in town (the Iceberg: no way off on the map, nor a ride): recall where you stand, to the nearest
    # signpost, the run from there
    o.lua("""sbo.mapWalkTo = REALWALK; sbo.trip = nil; sbo.travel = nil
      CHAIN(2, { 917741, 917742 }, 'n'); POS[917741] = { map = 'Alyria', x = 655, y = 366 }
      sbo.signposts = function() return { { room = 1900988, dests = { rune = 'south' } } } end
      sbo.cfg.runs = { names = { rune = {} }, ends = { rune = 10490 }, endsFixed = 1 }
      gmcp.room = { info = { num = '917741', wilds = 'false', exits = { n = '917742' }, coord = { name = 'Alyria', x = 655, y = 366 } } }
      sbo.mapRoom = 917741; LOGS = {}; SENT = {}""")
    o.lua("sbo.goTo(10495)")
    text = "\n".join(o.ev("LOGS").values())
    assert "recall to the signpost on the Shadow Road" in text and "run rune" in text and "y to go" in text and "no route" not in text, text
    o.lua("sbo.goAnswer('y'); runTimers()")
    eq(o.ev("SENT[#SENT]"), "cast 'word of recall'", "recalled where you stand")
    # the clan hall isn't on the map (it usually isn't): still clan gohall, out, east, south, recall
    o.lua("""sbo.trip = nil; sbo.travel = nil; AREA[384334] = nil; sbo.cfg.clanHall = 384334
      sbo.signposts = function() return { { room = 1900988, dests = { rune = 'south' } }, { room = 1500000, dests = { civmar = 'north' } } } end
      CHAIN(2, { 917800 }, 'x'); POS[917800] = { map = 'Alyria', x = 560, y = 230 }
      gmcp.room = { info = { num = '917800', wilds = 'false', exits = {}, coord = { name = 'Alyria', x = 560, y = 230 } } }
      sbo.mapRoom = 917800; LOGS = {}; SENT = {}""")
    o.lua("sbo.goTo(10495)")
    text = "\n".join(o.ev("LOGS").values())
    for want in ["clan gohall to your clan hall", "out of the hall, 5 east, about 60 south", "recall to the signpost on the Shadow Road", "run rune"]:
        assert want in text, (want, text)
    o.lua("sbo.goAnswer('y'); runTimers()")
    eq(o.ev("SENT[#SENT]"), "clan gohall", "the hall first")
    o.lua("""gmcp.room = { info = { num = '384334', wilds = 'false', exits = { n = '1558194' }, coord = { name = 'Alyria', x = 560, y = 216 } } }
      sbo.mapRoom = 384334; sbo.travelOnRoom(384334); runTimers()""")
    eq(o.ev("SENT[#SENT]"), "n", "landed: out of the hall")
    # standing in it: the plan starts with the walk out
    o.lua("sbo.trip = nil; sbo.travel = nil; LOGS = {}; SENT = {}; sbo.goTo(10495)")
    text = "\n".join(o.ev("LOGS").values())
    assert "out of the hall, 5 east" in text and "clan gohall" not in text and "run rune" in text and "y to go" in text, text


@test
def quest_shop_in_town_first():
    o = Oven()
    o.lua("""sbo.mapRoom = 1
      AREA = { [1] = 5, [28017] = 5, [10682] = 9, [22434] = 7 }
      roomExists = function(id) return AREA[tonumber(id)] ~= nil end
      getRoomArea = function(id) return AREA[tonumber(id)] end
      getPath = function(a, b) speedWalkDir = {}; for i = 1, (AREA[tonumber(b)] == 5 and 4 or 40) do speedWalkDir[i] = 'n' end return true end
      sbo.dbx("INSERT INTO shops (room, name) VALUES (10682, 'local butcher shop')")
      sbo.dbx("INSERT INTO shops (room, name) VALUES (28017, 'local butcher shop')")
      sbo.dbx("INSERT INTO shops (room, name) VALUES (22434, 'the Wandering Sidhe Bar')")
      sbo.dbx("INSERT INTO shop_items (room, item, cost) VALUES (10682, 'A T-bone steak', 125)")
      sbo.dbx("INSERT INTO shop_items (room, item, cost) VALUES (22434, 'A T-bone steak', 250)")""")
    room, why = o.ev("function() return sbo.questTarget({ n = 1, text = \"Locate and deliver a T-bone steak to Taron, Lord Vendredi's assistant\" }, nil) end")()
    eq(room, 28017, "the butcher's in town: same name as one that sells it")
    assert "likely sells" in why, why
    # a delivery: the HUD shows where to get it and where to take it
    o.lua("""sbo.quests['2452'] = { name = 'I Am On Your Side!', master = 'Lord Vendredi', masterRoom = 28450, total = 1, done = 0,
        phases = { { n = 1, text = "Locate and deliver a T-bone steak to Taron, Lord Vendredi's assistant" } } }
      AREA[28450] = 5; getRoomName = function(id) return 'room ' .. id end
      SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
      WALKS = {}; sbo.goTo = function(id) WALKS[#WALKS+1] = id end""")
    import re as _re
    h, w, a = o.ev("function() return sbo.questCardHtml('2452', sbo.quests['2452']) end")()
    plain = [_re.sub("<[^>]+>", "", x).replace("&nbsp;", " ") for x in h.values()]
    get = [k for k, v in a.items() if v.get][0]; dl = [k for k, v in a.items() if v.deliver][0]
    assert "room 28017" in plain[get - 1] and "get it" in plain[get - 1], plain
    assert "Taron" in plain[dl - 1] and "deliver" in plain[dl - 1], plain
    o.lua("sbo.questGoStep('2452', 1, 'deliver')")
    eq(list(o.ev("WALKS").values()), [28450], "Taron: with Lord Vendredi, where the quest was taken")
    # the step itself: the shop, until the steak's in your inventory - then Taron
    o.lua("WALKS = {}; sbo.questGoStep('2452', 1)")
    o.lua("sbo.cfg.carried = nil; sbo.drawQuestTracker = function() end")
    o.feed("Strecht, the butcher takes your payment and hands you a T-bone steak.")
    o.lua("sbo.questGoStep('2452', 1)")
    eq(list(o.ev("WALKS").values()), [28017, 28450], "shop first, Taron once you've bought it")
    import re as _re2
    h, w, a = o.ev("function() return sbo.questCardHtml('2452', sbo.quests['2452']) end")()
    assert not any("&amp;" in x for x in h.values()), list(h.values())
    # bought it, but the one it's for hasn't been seen: no more "get it" (each click was another shop),
    # sbo quest go says so instead of shopping
    o.lua("""sbo.quests['2680'] = { name = 'Outbreak', total = 1, done = 0,
        phases = { { n = 5, text = "Locate and deliver a T-bone steak to an ogre cook" } } }
      sbo.cfg.questPins = { ['2680'] = true }; SAYS = {}""")
    h, w, a = o.ev("function() return sbo.questCardHtml('2680', sbo.quests['2680']) end")()
    plain = [_re.sub("<[^>]+>", "", x).replace("&nbsp;", " ") for x in h.values()]
    assert not any(v.get for v in a.values()), ("no shop link while you have it", plain)
    assert any("you have it" in x for x in plain) and any("an ogre cook · not seen yet" in x for x in plain), plain
    o.lua("WALKS = {}; sbo.questGo('2680')")
    eq(list(o.ev("WALKS").values()), [], "sbo quest go: not to a shop")
    assert "you have it" in o.ev("SAYS[#SAYS]"), o.ev("SAYS[#SAYS]")
    # delivered (the game marks the step done): it's gone from what you carry - the shop is back
    o.lua("""gmcp.char = { quests = { q2680 = { quest_info = { vnum = 2680, name = "Outbreak", completed = false, abandoned = false },
        goals = { { phase_number = 5, phase_complete = true, goal_string = "*Phase 5: *Locate and deliver a T-bone steak to an ogre cook.\\r\\n" } } } } }
      sbo.onGmcpQuests()""")
    eq(o.ev("(function() for _, n in ipairs(sbo.cfg.carried.inv) do if n:find('T%-bone') then return n end end end)()"), None,
       "delivered: no longer carried")
    o.lua("sbo.quests['2452'].phases[1].done = false; WALKS = {}; sbo.questGoStep('2452', 1)")
    eq(list(o.ev("WALKS").values()), [28017], "another T-bone quest: the shop again")
    # no shop of that kind in town: the nearest that's listed
    o.lua("AREA[1] = 9")
    room, why = o.ev("function() return sbo.shopSelling('a T-bone steak') end")()
    eq(room, 10682, "in your area, and listed")


@test
def quest_panel_scrolls():
    o = Oven()
    o.lua("""getMainWindowSize = function() return 1600, 400 end
      sbo.cfg.questPins = {}
      for i = 1, 12 do
        local id = tostring(100 + i)
        sbo.quests[id] = { name = 'Quest ' .. i, total = 2, done = 0, phases = { { n = 1, text = 'Do a thing' }, { n = 2, text = 'Do another' } } }
        sbo.cfg.questPins[id] = true
      end
      sbo.drawQuestTracker()""")
    shown = lambda: [i for i in range(1, 13) if o.ev(f"sbo.questCards[{i}].shown")]
    first = shown()
    assert 0 < len(first) < 12 and first[0] == 1, first
    assert o.ev("sbo.ScrollDown.shown") and not o.ev("sbo.ScrollUp ~= nil and sbo.ScrollUp.shown"), "only ▼ at the top of the list"
    assert "more" in o.ev("sbo.ScrollDown.html")
    # the wheel (or ▼) moves on a card
    o.lua("sbo.questWheel({ angleDeltaY = -120 })")
    eq(shown()[0], 2, "scrolled down one")
    assert o.ev("sbo.ScrollUp.shown") and "▲ 1 more" in o.ev("sbo.ScrollUp.html")
    o.lua("sbo.questWheel({ angleDeltaY = 120 })")
    eq(shown()[0], 1, "and back")
    # folding cards makes room: all fit, no bars
    o.lua("""getMainWindowSize = function() return 1600, 480 end
      sbo.cfg.questFolded = {} for id in pairs(sbo.cfg.questPins) do sbo.cfg.questFolded[id] = true end sbo.drawQuestTracker()""")
    eq(shown(), list(range(1, 13)), "folded, all twelve fit")
    assert not o.ev("sbo.ScrollDown.shown")
    # lines spaced by Qt's measure of one line (13px here), not the font-size estimate (16 × 1.35)
    o.lua("""local old = Geyser.Label.new
      Geyser.Label.new = function(self, c, p) local t = old(self, c, p)
        if c.name == 'ovenQuestProbe' then t.getSizeHint = function() return 30, 13 end end return t end
      sbo.questProbe = nil; sbo.cfg.questFolded = {}; sbo.drawQuestTracker()""")
    eq(o.ev("sbo.questLineH"), 13, "measured")
    y1, y2 = o.ev("WIDGETS.ovenQuestLine1_2.y"), o.ev("WIDGETS.ovenQuestLine1_3.y")
    eq(y2 - y1, 13, "lines one measured line apart")
    # a title bar to grab it by: an open hand, and a click on it does nothing
    assert o.ev("WIDGETS.ovenQuestTitle.shown") and "Quests" in (o.ev("WIDGETS.ovenQuestTitle.html") or ""), "the title bar"
    assert o.ev("WIDGETS.ovenQuestTitle.y") < o.ev("WIDGETS.ovenQuestCard1.y"), "above the quests"
    o.lua("sbo.questAct({ drag = true })")
    # raised above the panel's background, even with no scroll bars
    o.lua("""RAISED = {}; for _, k in ipairs({ 'questHud', 'questTitle' }) do local w = sbo[k]; w.raise = function() RAISED[#RAISED+1] = k end end
      sbo.ScrollUp, sbo.ScrollDown = nil, nil; sbo.raiseQuestHud()""")
    r = list(o.ev("RAISED").values())
    assert "questTitle" in r and r.index("questTitle") > r.index("questHud"), r
    # the number: bright, not grey
    h = o.ev("select(1, sbo.questCardHtml('101', sbo.quests['101']))[1]")
    assert "<b>" in h and "#101" in h, h


@test
def go_stays_in_town():
    o = Oven()
    o.lua("""SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
      SENT = {}; send = function(c) SENT[#SENT+1] = c end
      DENIED = 0; denyCurrentSend = function() DENIED = DENIED + 1 end
      sbo.cfg.map = true; sbo.mapRoom = 1
      -- rooms 1-3 are in town (area 1), 9 is outside (area 2); 5 is in town but only reached through 9
      AREA = { [1] = 1, [2] = 1, [3] = 1, [5] = 1, [9] = 2 }
      PATHS = { [2] = { 1, 2 }, [3] = { 2, 3 }, [9] = { 2, 9 }, [5] = { 2, 9, 5 } }
      roomExists = function(id) return AREA[tonumber(id)] ~= nil end
      getRoomArea = function(id) return AREA[tonumber(id)] end
      getRoomAreaName = function(a) return a == 1 and "Towne of Rune" or "the wilds" end
      getRoomName = function(id) return "room " .. id end
      getPath = function(a, b) local p = PATHS[tonumber(b)]; if not p then return false end
        speedWalkPath = {}; speedWalkDir = {}
        for i, r in ipairs(p) do speedWalkPath[i] = tostring(r); speedWalkDir[i] = "n" end
        return true end
      WALKS = {}; sbo.mapWalkTo = function(id, onFoot) WALKS[#WALKS+1] = { id, onFoot or false } end
      gmcp.room = { info = { wilds = "false" } }""")
    walks = lambda: [tuple(w.values()) for w in o.ev("WALKS").values()]
    # a weaker match in town beats a better one outside it
    o.lua("""sbo.runTargets = function() return { { id = 9, why = "[Trainer] outside", rank = 1 }, { id = 3, why = "a trainer in town", rank = 2 } }, true end
      sbo.mapRun('trainer')""")
    eq(walks(), [(3, True)], "the one in town, walked (no signpost run)")
    # only outside: asked first
    o.lua("WALKS = {}; sbo.goTo(9)")
    assert walks() == [] and "y to go, n to stay" in o.ev("SAYS[#SAYS]"), o.ev("SAYS[#SAYS]")
    o.lua("sbo.onSend(nil, 'y'); runTimers()")
    eq((walks(), o.ev("DENIED")), ([(9, False)], 1), "y: goes, and isn't sent to the game")
    # n: stays
    o.lua("WALKS = {}; sbo.goTo(5); sbo.onSend(nil, 'n'); runTimers()")
    eq((walks(), o.ev("DENIED")), ([], 2), "n: stays (5 is in town, but the way there leaves it)")
    # anything else: the question's dropped, the command goes to the game
    o.lua("sbo.goTo(9); sbo.onSend(nil, 'look'); sbo.onSend(nil, 'y'); runTimers()")
    eq((walks(), o.ev("DENIED")), ([], 2), "another command: no walk, nothing held back")
    # already in the wilds: no question
    o.lua("gmcp.room.info.wilds = 'true'; sbo.goTo(9)")
    eq(walks(), [(9, False)], "in the wilds: just goes")


@test
def eqdb_list_and_lookup():
    o = Oven()
    eq(tuple(o.ev("function() return sbo.classify('check eqlookup 2acf8c203696532d8bdaa1064553483ec0a68fa5') end")()),
       ("item", "eqlookup 2acf8c203696532d8bdaa1064553483ec0a68fa5"), "clicking a result: an item page")
    eq(o.ev("sbo.classify('check time')"), None, "other checks are left alone")
    o.lua("""SENT = {}; send = function(c) SENT[#SENT+1] = c end
      R = {}; selectSection = function(a, n) SELN = n; return true end
      replace = function(t) R[#R+1] = t end; deselect = function() end; resetFormat = function() end
      FG = 0; setFgColor = function() FG = FG + 1 end
      GAG = 0; deleteLine = function() GAG = GAG + 1 end""")
    o.lua("sbo.eqdbNoteSend('eqdb wear legs levels 40 60')")
    def ln(text):
        o.L.globals().line = text
        return o.ev("sbo.eqdbLine")(text)
    assert ln(" --- Searching for between levels 40-60 --- ")
    assert "eqdb: levels 40-60" in o.ev("R[1]"), o.ev("R[1]")
    # a result: the number dimmed, the line itself (the link) kept
    assert ln("53   a pearl-inlaid nunchaku                 ") and o.ev("SELN") == 5 and o.ev("#R") == 1
    # the pager: answered
    assert ln("[C]ontinue [R]edraw [B]ack [E]xit: ") and o.ev("SENT[#SENT]") == "c" and o.ev("GAG") == 1
    assert ln("---------- Terminating at 100 results ----------") and "narrow the search" in o.ev("R[2]")
    # done: lines after it are someone else's
    assert not ln("53   something said in a channel")
    # clicking a result: the page is read like a look, and the item is known from then on
    o2 = Oven()
    robe = ["Item 'a black monk's robe' is type armor, alignment 0, made of cloth (in (new) condition),[EQDB]",
      "has keywords 'pile black cloth monks robe about cat2', equipped about the body.",
      "This item weighs 0 stones and 5 pebbles, and is valued at 1,125 gold. {Cat. 2}",
      "This level 25 item has no special attributes.", "Armor resistance is 3.", "*This item may be repaired 1 time.",
      "A nondescript black robe, the cowl is large and covers the head and face"]
    o2.lua('sbo.cfg.promptPattern = "<%d+hp"')
    o2.L.globals().ROBE = o2.L.table_from(robe)
    o2.lua("""sbo.onSend(nil, 'check eqlookup 2acf8c203696532d8bdaa1064553483ec0a68fa5')
      for _, l in ipairs(ROBE) do line = l; sbo.onLine() end
      line = '<270hp 550sp 401st>'; sbo.onLine(); runTimers()""")
    eq(o2.ev("sbo.items[\"a black monk's robe\"].level"), "25", "remembered")


@test
def eq_weapon_lines_belong():
    o = Oven()
    shape = o.ev("sbo.shapes.eq")
    for l in ["Your staff will deal High bash damage with Min accuracy, at Low range, with a Max chance to crit for 2x damage.",
              "Your weapon special attribute battering increases base damage on activation by 23% (10 per attack).",
              "Your hand armor special attribute battering-fists increases base damage on activation by 17% (6 per attack).",
              "With hand to hand, you will deal Low water damage with Max accuracy, at Min range, with a High chance to crit for 2x damage."]:
        assert shape(l, l), l
    # someone else's line still doesn't
    assert not shape("Your friend waves.", "Your friend waves.")


@test
def eq_wielded_weapon_block():
    o = Oven()
    lines = ["You are using:", "<wielded>           a sturdy white banded staff (new)", "", "Equipped weapon damage:",
      "Your staff will deal High bash damage with Min accuracy, at Low range, with a Max chance to crit for 2x damage.",
      "57 Damage: (+46 from weapon) (+2 from +damage) (+9 from skill & strength) (+1 from weapon skillpower) (38% chance for +3 from enhanced damage) ",
      "31% Critical Hit chance:  (+31 from staff)",
      "Your weapon special attribute battering increases base damage on activation by 16% (7 per attack)."]
    f = o.ev("function(...) local l = sbo.format('eq', '', {...}, 110) local s = {} for _, r in ipairs(l) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = '\\n' end return table.concat(s) end")
    text = f(*lines)
    assert "Weapon: staff" in text and "Special" in text and "battering increases" in text, text
    assert "enhanced damage (38% of hits)" in text, text
    assert "Your staff will deal" not in text, "the sentence is laid out, not repeated"


@test
def eq_reads_eq_first():
    o = Oven()
    o.lua("""SENT = {}; send = function(c) SENT[#SENT+1] = c; sbo.onSend(nil, c) end
      VIEWS = 0; sbo.viewLive = function(make) VIEWS = VIEWS + 1; MAKE = make end
      local q = sbo.quietly; sbo.quietly = function(c, k, fn) QFN = fn; return q(c, k, fn) end
      gmcp.char = { status = { state = "playing" } }; sbo.lastStatusPrompt = "<281hp 696sp 457st>" """)
    o.lua("sbo.command('eq')")
    eq(o.ev("SENT[#SENT]"), "eq", "eq sent first")
    eq(o.ev("VIEWS"), 0, "the page waits for the reply")
    o.ev("QFN")(o.ev("function(...) return {...} end")("You are using:", "<worn on hands>     fists of the Forest (new)", "",
      "With hand to hand, you will deal Low water damage with Max accuracy, at Min range, with a High chance to crit for 2x damage.",
      "42 Damage: (+38 from weapon) (+1 from +damage) (+4 from skill & strength) ",
      "80 Accuracy: (+4 from level) (+25 from weapon skill) (+45 from fists) ",
      "22% Critical Hit chance:  (+22 from hand to hand)"))
    eq((o.ev("VIEWS"), o.ev("sbo.cfg.char.combat.accuracy"), o.ev("sbo.cfg.char.combat.weapon")), (1, 80, "fists"), "read, then shown")
    page = o.ev("function() local l = MAKE(110) local s = {} for _, r in ipairs(l) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = '\\n' end return table.concat(s) end")()
    assert "Weapon: hand to hand" in page and "Offense" in page and page.index("Weapon: hand to hand") < page.index("Offense"), page
    # at a login prompt: nothing sent, the page as it was
    o.lua("SENT = {}; sbo.quietNext = nil; sbo.cap = nil; gmcp.char.status.state = 'login'; sbo.lastStatusPrompt = nil; sbo.lastPromptText = nil; sbo.command('eq')")
    eq((o.ev("#SENT"), o.ev("VIEWS")), (0, 2), "not in the game: no eq sent")


@test
def game_sounds():
    import os
    o = Oven()
    o.lua("""PLAYED = {}; playSoundFile = function(t) PLAYED[#PLAYED+1] = t end; STOPPED = 0; stopSounds = function() STOPPED = STOPPED + 1 end
      GAGGED = 0; local d = deleteLine; deleteLine = function() GAGGED = GAGGED + 1 end""")
    # no sounds installed: off the screen, a hint once
    o.feed("!!SOUND(mm_welcome.* V=100 L=1 P=50 T=misc)")
    eq((o.ev("GAGGED"), o.ev("#PLAYED")), (1, 0), "not installed: gagged, nothing played")
    # installed: played (the profile's media/mm)
    d = o.home + "/media/mm"; os.makedirs(d, exist_ok=True); open(d + "/mm_welcome.mp3", "wb").write(b"x")
    o.feed("!!SOUND(mm_welcome.* V=80 L=2 P=50 T=misc)")
    eq((o.ev("GAGGED"), o.ev("#PLAYED"), o.ev("PLAYED[1].volume"), o.ev("PLAYED[1].loops")), (2, 1, 80, 2), "played")
    assert o.ev("PLAYED[1].name").endswith("/media/mm/mm_welcome.mp3")
    o.feed("!!SOUND(Off)")
    eq(o.ev("STOPPED"), 1, "Off: stopped")
    # a line that only mentions it, or sounds off: left alone
    o.feed("Bob says '!!SOUND(mm_welcome)'")
    o.lua("sbo.cfg.sound = false"); o.feed("!!SOUND(mm_welcome.* V=100)")
    eq((o.ev("GAGGED"), o.ev("#PLAYED")), (3, 1), "sounds off: shown as is")


@test
def practice_dummy():
    o = Oven()
    o.lua("""SENT = {}; send = function(c) SENT[#SENT+1] = c; sbo.onSend(nil, c) end
      gmcp.char = { vitals = { hp = 371, sp = 871, st = 490 }, lasttargeted = { short_descr = "a practice dummy", hp_percent = 100 } }
      function ROUND(hit) gmcp.char.combat_mxp = { opponent_name = "a practice dummy", opponent_hp_percent = 100, you_hit = hit, you_miss = 1 - hit,
        opponent_hits = 0, opponent_misses = 0, you_defend = 0, opponent_defends = 0, your_hp_percent = 100, your_weapon_range = 4, distance_to_opponent = 2 }
        handlers["gmcp.char.combat_mxp"]() end""")
    o.lua("""sbo.cfg.abilitiesRead = 2
      sbo.cfg.abilities = { spark = { name = 'spark', kind = 'spell', sp = 49, base = 2.2, types = 'flames/lightning' },
        kick = { name = 'kick', kind = 'skill', base = 1.3, types = 'bash/bash' }, bash = { name = 'bash', kind = 'skill', base = 2.2, types = 'bash/bash' } }""")
    # a plain swing that hits: your melee
    o.lua("ROUND(1)"); o.feed("A practice dummy says 'I have [9956/10000hp 10000/10000sp 9993/10000st and -250 align]'")
    eq(o.ev("sbo.dummyLog().melee.sum"), 44, "a swing: 44")
    # bash, your swing missing that round: all bash; 109 stamina
    o.lua("send('bash dummy'); gmcp.char.vitals.st = 381; ROUND(0)")
    o.feed("You bash a practice dummy over the head with a scorpion shield.", "A practice dummy says 'I have [9641/10000hp 10000/10000sp 9993/10000st and -250 align]'")
    b = o.ev("sbo.dummyStats('bash')")
    eq((b.avg, b.cost, b.res), (359, 109, "st"), "bash: damage and stamina")
    # kick with the swing hitting too: the swing is taken off
    o.lua("gmcp.char.vitals.st = 487; send('kick dummy'); gmcp.char.vitals.st = 460; ROUND(1)")
    o.feed("You deliver a roundhouse kick to a practice dummy, connecting solidly.", "A practice dummy says 'I have [9643/10000hp 10000/10000sp 9993/10000st and -250 align]'")
    eq(o.ev("sbo.dummyStats('kick').avg"), 357 - 44, "kick: 357 minus a 44 swing")
    # a kick that misses: counted as a try that didn't land
    o.lua("send('kick dummy'); ROUND(0)")
    o.feed("You attempt to kick a practice dummy, but miss.", "A practice dummy says 'I have [10000/10000hp 10000/10000sp 9993/10000st and -250 align]'")
    k = o.ev("sbo.dummyStats('kick')")
    eq((k.n, k.tries, k.misses, round(k.per, 1)), (1, 2, 1, round((357 - 44) / 2, 1)), "kick: 1 of 2 landed")
    # two landings in one round (two kicks sent quickly): the round's damage shared
    o.lua("sbo.dummyLog().kick = nil; gmcp.char.vitals.st = 487; send('kick dummy'); send('kick dummy'); gmcp.char.vitals.st = 460; ROUND(0)")
    o.feed("You deliver a roundhouse kick to a practice dummy, connecting solidly.",
           "You deliver a roundhouse kick to a practice dummy, connecting solidly.",
           "A practice dummy says 'I have [9507/10000hp 10000/10000sp 9993/10000st and -250 align]'")
    k2 = o.ev("sbo.dummyStats('kick')")
    eq((k2.n, round(k2.avg, 1)), (2, 246.5), "493 between two kicks")
    # spark: two fizzles, then it works
    for _ in range(2):
        o.lua("send('cast spark dummy')"); o.feed("You have completed your casting.", "You lose your concentration.")
    o.lua("gmcp.char.vitals.sp = 761; send('cast spark dummy'); gmcp.char.vitals.sp = 712; ROUND(0)")
    o.feed("You have completed your casting.", "A brilliant spark arcs from your fingertips to a practice dummy.",
           "A practice dummy says 'I have [9706/10000hp 10000/10000sp 9993/10000st and -250 align]'")
    sp = o.ev("sbo.dummyStats('spark')")
    eq((sp.avg, sp.tries, sp.fails, sp.cost), (294, 3, 2, 49), "spark: 294, 2 of 3 fizzled, 49 sp")
    # "You cast spark one additional time": two landings in the round
    o.lua("sbo.dummyLog().spark = nil; send('cast spark dummy'); ROUND(0)")
    o.feed("You cast spark one additional time.", "You have completed your casting.", "A brilliant spark arcs from your fingertips to a practice dummy.",
           "A practice dummy says 'I have [9532/10000hp 10000/10000sp 9993/10000st and -250 align]'")
    eq(o.ev("sbo.dummyStats('spark').avg"), 234, "468 between two sparks")
    # faerie fire (a debuff) finishing in the same round as a bash: the bash keeps the round
    o.lua("sbo.dummyLog().bash = nil; send(\"cast 'faerie fire' dummy\"); gmcp.char.vitals.st = 490; send('bash dummy'); gmcp.char.vitals.st = 381; ROUND(0)")
    o.feed("You have completed your casting.", "A practice dummy is outlined by a faint pink glow.",
           "You bash a practice dummy over the head with a scorpion shield.", "A practice dummy says 'I have [9641/10000hp 10000/10000sp 9993/10000st and -250 align]'")
    eq(o.ev("sbo.dummyStats('bash').avg"), 359, "faerie fire doesn't take a share")
    o.lua("send('feed dummy'); ROUND(0)")
    o.feed("You attempt to bite into a practice dummy but can't manage to catch it.", "A practice dummy says 'I have [10000/10000hp 10000/10000sp 9993/10000st and -250 align]'")
    f_ = o.ev("sbo.dummyStats('feeding')")
    eq((f_.n, f_.misses), (0, 1), "a feed that didn't catch it: a miss")
    # another build (a new class, other gear): its own results, the old ones kept as history
    first = o.ev("sbo.dummyBuild()")
    o.lua("sbo.cfg.char = sbo.cfg.char or {}; sbo.cfg.char.class = 'barbarian'; sbo.cfg.char.level = 45")
    assert o.ev("sbo.dummyBuild()") != first and o.ev("sbo.dummyStats('kick')") is None, "a new build starts fresh"
    assert o.ev("sbo.cfg.dummy.builds[%r] ~= nil" % first), "the old build's results kept"
    o.lua("sbo.cfg.char.class = nil; sbo.cfg.char.level = nil")
    eq(o.ev("sbo.dummyBuild()"), first, "back")
    assert o.ev("sbo.dummyStats('kick').age") is not None, "each result has an age"
    # in the attack table
    o.lua("""sbo.cfg.abilitiesRead = 2; sbo.cfg.skills = { spark = { lrnd = 27 }, kick = { lrnd = 78 }, bash = { lrnd = 75 } }
      sbo.cfg.abilities = { spark = { name = 'spark', kind = 'spell', sp = 49, base = 2.2, types = 'flames/lightning' },
        kick = { name = 'kick', kind = 'skill', base = 1.3, types = 'bash/bash' }, bash = { name = 'bash', kind = 'skill', base = 2.2, types = 'bash/bash' } }""")
    f = o.ev("function() local out = {} sbo.abilitySection(out, 100) local s = {} for _, r in ipairs(out) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = '\\n' end return table.concat(s) end")
    text = f()
    assert "359/use" in text and "~109st" in text, text
    assert "most per stamina: kick" in text, f"kick: 156 a use for ~27 st beats bash 359 for 109: {text}"
    o.lua("SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end; sbo.command('eq dummy')")
    assert any("▶" in x for x in o.ev("SAYS").values()), list(o.ev("SAYS").values())
    o.lua("sbo.command('eq dummy reset')")
    eq(o.ev("sbo.dummyStats('kick')"), None, "this build's results cleared")


@test
def training_advice():
    o = Oven()
    o.lua("""sbo.cfg.char = { class = 'monk', race = 'sahuagin', stats = {
        knowledge = { cur = 12, max = 21 }, agility = { cur = 9, max = 17 }, vitality = { cur = 19, max = 19 },
        luck = { cur = 8, max = 17 } },
        innate = { { stat = 'stamina', mod = -211 }, { stat = 'disease-res', mod = -25 } } }
      sbo.cfg.classPrimary = { monk = 'knowledge' }""")
    # a racial weakness measured in points mustn't swamp everything (it made stamina count 4.3)
    eq(o.ev("select(2, sbo.activeBuild()).stamina"), 0.125, "stamina: its own small weight, a quarter more")
    eq(o.ev("select(2, sbo.activeBuild())['disease-res']"), 0.6, "a resistance weakness as before")
    f = o.ev("function(rows) local s={} for _,r in ipairs(rows) do for _,g in ipairs(r) do s[#s+1]=tostring(g[2]) end s[#s+1]='\\n' end return table.concat(s) end")
    out = f(o.ev("sbo.buildLines(100)"))
    assert "type eq once" in out, "nothing to work from yet"
    o.lua("""sbo.noteCombat({ "57 Damage: (+46 from weapon)", "55 Accuracy: (+16 from weapon)", "31% Critical Hit chance:" })
      sbo.cfg.maxes = { hp = 365, sp = 875 }; sbo.cfg.arLoc = { head = 5, torso = 16 }; sbo.cfg.arRate = 0.75""")
    out = f(o.ev("sbo.buildLines(100)"))
    assert "damage a round" in out and "effective hp" in out and "sp a tick" in out, out
    assert "score" not in out.lower().replace("type score", ""), f"no gear score: {out}"
    # what one more point of each really changes: agility = +0.5% to hit (help 1747); knowledge has no formula
    assert "next: agility" in out, out
    agi = next(l for l in out.split("\n") if l.strip().startswith("agility"))
    assert "+0.5% hit" in agi and "dodging ?" in agi, agi
    kn = next(l for l in out.split("\n") if l.strip().startswith("knowledge"))
    assert "SCC" in kn or "learning ?" in kn, f"knowledge: what it does to SCC (help 1613): {kn}"
    o.lua("sbo.cfg.char.level = 56; sbo.cfg.char.stats.vitality = { cur = 19, max = 19 }; sbo.cfg.char.stats.knowledge = { cur = 19, max = 21 }")
    kn = next(l for l in f(o.ev("sbo.buildLines(100)")).split("\n") if l.strip().startswith("knowledge"))
    assert "SCC capped" in kn, f"a level 56 monk is at the cap: {kn}"
    o.lua("sbo.cfg.char.stats.knowledge = { cur = 12, max = 21 }")
    vit = next(l for l in out.split("\n") if l.strip().startswith("vitality"))
    assert "max" in vit, "at max: nothing left to train"
    # the page follows the game: train knowledge, and the page on show is drawn again
    o.lua("sbo.cfg.window = true; sbo.command('eq')")
    page = lambda: o.ev("WIDGETS[sbo.viewPg.prefix .. sbo.viewPg.flip .. 'Label'].html")
    assert "12/21" in page(), page()
    TRAIN = ["You have 394 practice sessions.", "You may train the following vital statistics:",
             "Attribute Name        Current Stat   Practice Cost", "knowledge                 13/21           60",
             "agility                    9/17           80"]
    o.lua("runTimers()")
    # the train table shows what's trained (gear comes on top, in score): training once more = one more in total
    o.ev("sbo.noteTrain")(o.L.table_from([l.replace("13/21", "8/21") for l in TRAIN]))
    o.ev("sbo.noteTrain")(o.L.table_from([l.replace("13/21", "9/21") for l in TRAIN]))
    o.lua("runTimers()")
    assert "13/21" in page() and "12/21" not in page(), f"redrawn with the new number: {page()}"
    assert "13/21" in page(), page()
    eq(o.ev("sbo.cfg.char.trained.knowledge.cur"), 9, "trained 9 (gear brings it to 13)")
    eq(o.ev("sbo.cfg.char.trainCost.knowledge"), 60, "and what it costs")
    # trained all the way: the table leaves it out - its base is its maximum, not the last number it showed
    o.lua("sbo.cfg.char.stats.strength = { cur = 25, max = 22 }; sbo.cfg.char.trained.strength = { cur = 21, max = 22 }; sbo.cfg.char.trainCost.strength = 80")
    o.ev("sbo.noteTrain")(o.L.table_from(TRAIN))
    eq((o.ev("sbo.cfg.char.trained.strength.cur"), o.ev("sbo.cfg.char.trainCost.strength")), (22, None), "strength: trained to 22")
    st = next(l for l in f(o.ev("sbo.buildLines(100)")).split("\n") if l.strip().startswith("strength"))
    assert "25/22" in st and " 22 " in st and "with gear" in st, st


@test
def help_fetch():
    o = Oven()
    o.lua("""sbo.cfg.promptPattern = "<%d+hp"; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
      SENT = {}; send = function(c) SENT[#SENT+1] = c; sbo.onSend(nil, c) end
      sbo.lastUserCmdAt = -100""")
    o.set_gmcp("char.status", '{ state = "playing" }')
    o.feed("<270hp 550sp 401st>")
    o.lua('sbo.command("debug help crawl 3480")')
    eq(list(o.ev("SENT").values()), ["help 3480"], "the first page, quietly")
    o.feed("[3480 ] ADVENTURER'S GUIDE XB", "Dodging is 1% per 2 agility.", "SEE ALSO:",
           " [1347] dodge - move out of the way of an attack", "<270hp 550sp 401st>")
    TICK = "local due = {} for id, t in pairs(timers) do if t[1] <= 6 then due[#due + 1] = id end end for _, id in ipairs(due) do local t = timers[id]; if t then timers[id] = nil; t[2]() end end"
    o.lua(TICK); o.lua(TICK)
    text = open(o.ev("sbo.helpFile")).read()
    assert "===== help 3480 [3480]" in text and "Dodging is 1% per 2 agility." in text, text
    eq(list(o.ev("SENT").values())[-1], "help 1347", "crawl: then what it links to")
    # progress on the prompt bar while it reads
    o.lua("""sbo.cfg.bar = true; sbo.cfg.maxes = { hp = 300, sp = 600, st = 450 }
      sbo.bar = setmetatable({ rawEcho = function(self, h) BAR = h end }, { __index = function() return function() end end })
      sbo.lastPromptText = "<270hp 550sp 401st>"; sbo.drawBar()""")
    bar = __import__("re").sub("<[^>]+>", "", o.ev("BAR") or "")
    assert "▄ [v" in bar, f"one character, just left of the version: {bar}"
    o.feed("[1347 ] DODGING ATTACKS", "dodge - move out of the way", "<270hp 550sp 401st>")
    o.lua(TICK); o.lua(TICK); o.lua(TICK)
    assert "DODGING ATTACKS" in open(o.ev("sbo.helpFile")).read()
    assert any("2 pages saved" in m for m in o.ev("SAYS").values()), list(o.ev("SAYS").values())
    # a long page (a list): 3 screens, then out of the pager - not a stream of "c"s
    o.lua('SENT = {}; sbo.cfg.helpSaved = {}; sbo.command("debug help 2488")')
    o.feed("[2488 ] LIST OF ALL HELP ENTRIES", " [1000] magical items - a", "[C]ontinue [R]edraw [B]ack [E]xit: ")
    o.feed(" [1001] more - b", "[C]ontinue [R]edraw [B]ack [E]xit: ")
    o.feed(" [1002] more - c", "[C]ontinue [R]edraw [B]ack [E]xit: ")
    sent = list(o.ev("SENT").values())
    eq(sent, ["help 2488", "c", "c", "e"], f"two more screens, then exit: {sent}")
    o.lua('sbo.command("debug help stop")')
    # you type while it reads: it stops, and your command isn't swallowed
    o.lua('SENT = {}; SAYS = {}; sbo.cfg.helpSaved = {}; sbo.command("debug help 3480, 3481")')
    o.feed("[3480 ] ADVENTURER'S GUIDE", "some text")
    o.lua('sbo.onSend(nil, "look")')
    eq(o.ev("sbo.helpFetch"), None, "stopped")
    eq(o.ev("sbo.cap and sbo.cap.gag"), None, "nothing hidden any more")
    o.lua("runTimers()")
    assert any("you typed" in m for m in o.ev("SAYS").values()), list(o.ev("SAYS").values())
    # nothing before you're in the game
    o.lua('SENT = {}'); o.set_gmcp("char.status", '{ state = "login" }')
    o.lua('sbo.command("debug help haste")')
    eq(len(list(o.ev("SENT").values())), 0, "not at a login prompt")
    o.lua('sbo.command("debug help stop")')
    # stored batches: sbo debug help next reads the first, then the second, then what they link to
    o.set_gmcp("char.status", '{ state = "playing" }')
    o.lua("SENT = {}; SAYS = {}")
    o.lua('sbo.command("debug help next")')
    first = list(o.ev("SENT").values())
    eq(first[0], "help 2438", f"batch 1 starts: {first}")
    eq(o.ev("sbo.helpBatchName.name"), "skill power and defenses", "the stored batch")
    o.lua('sbo.command("debug help stop"); sbo.helpBatchName = nil')
    o.lua("for _, p in ipairs(sbo.HELP_BATCHES[1].pages) do sbo.cfg.helpSaved[p] = true end")
    eq(o.ev("(sbo.helpNextBatch())"), "casting and spell cost", "batch 1 read: batch 2 is next")
    o.lua("for i = 2, #sbo.HELP_BATCHES do for _, p in ipairs(sbo.HELP_BATCHES[i].pages) do sbo.cfg.helpSaved[p] = true end end; sbo.cfg.helpLinked = { '1347', '9001' }")
    eq(o.ev("(sbo.helpNextBatch())"), None, "then done: links aren't followed on their own")


@test
def death_saves_the_fight():
    o = Oven()
    eq(o.ev("sbo.cfg.recWindow"), 3000, "keeps about an hour of hunting")
    o.lua("SAVED = {}; sbo.windowSave = function(why) SAVED[#SAVED + 1] = why return 1 end")
    o.feed("The world goes black as a shifting shadow crushes the life from you, and tears your head from your body.")
    o.feed("Your disembodied soul rises from your ravaged corpse.")
    o.lua("runTimers()")
    eq(list(o.ev("SAVED").values()), ["you died"], "saved the moment you die, not after the maze")


@test
def ship_prompt():
    import re as _re
    o = Oven()
    p = o.ev('sbo.parsePrompt("[Mail](120hull --dir ANCHOR --wind 452, 1210) ")')
    S = p.ship
    eq((S.hull, S.dir, S.state, S.wind, S.x, S.y), (120, "--", "ANCHOR", "--", 452, 1210), "the ship's prompt")
    eq(list(p.tags.values()), ["Mail"], "tags"); eq(p.rest, "", "nothing left over")
    o.set_gmcp("char.status", '{ state = "playing" }')
    eq(o.ev('sbo.inGame("[Mail](120hull --dir ANCHOR --wind 452, 1210) ")'), True, "aboard a ship is in the game")
    o.lua('''sbo.cfg.bar = true; sbo.cfg.maxes = { hp = 300, sp = 700, st = 460 }
      sbo.bar = { rawEcho = function(self, h) BAR = h end }
      gmcp.char.vitals = { hp = 280, sp = 650, st = 400 }
      sbo.lastPromptText = "[Mail](96hull --dir ANCHOR --wind 452, 1210) "''')
    o.feed("Hull Strength:        120/120")
    o.lua("sbo.drawBar()")
    plain = _re.sub("<[^>]+>", "", o.ev("BAR") or "")
    assert "SHIP" in plain and "96/120" in plain and "anchored" in plain and "452,1210" in plain, plain
    assert plain.find("ST ") < plain.find("SHIP"), f"right after your pools, where the mount goes: {plain}"
    assert "(96hull" not in plain, f"not the raw text: {plain}"


@test
def quest_timers():
    import re as _re, time as _time
    o = Oven()
    lines = open(fixture("quest_login_daily.txt"), encoding="utf-8").read().rstrip("\n").split("\n")
    o.lua('sbo.cfg.promptPattern = "<%d+hp"')
    o.feed(*lines)
    o.feed("<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    left = o.ev("sbo.quests['3519'].deadline") - int(_time.time())
    assert abs(left - 1984 * 15) <= 5, f"1984 Alyrian minutes = 8h16m: {left}s"
    # GMCP: quest_info.timer is the deadline; -1 is none
    now = int(_time.time())
    o.lua(f"""gmcp.char = {{ quests = {{
        q52 = {{ quest_info = {{ vnum = 52, name = "Jail Time", completed = false, abandoned = false, timer = {now + 40 * 60} }}, goals = {{}} }},
        q60 = {{ quest_info = {{ vnum = 60, name = "Untimed", completed = false, abandoned = false, timer = -1 }}, goals = {{}} }} }} }}
      sbo.onGmcpQuests()""")
    eq(o.ev("sbo.quests['52'].deadline"), now + 40 * 60, "from GMCP")
    eq(o.ev("sbo.quests['60'].deadline"), None, "no limit")
    # the bar: only the soonest
    o.lua("""sbo.bar = { rawEcho = function(self, h) BAR = h end }
             sbo.lastPromptText = "[Mail]<270hp 501sp 401st>"; sbo.drawBar()""")
    plain = _re.sub("<[^>]+>", "", o.ev("BAR") or "")
    top = o.ev("(function() local t = {} for _, x in ipairs(sbo.topBarSegs or {}) do t[#t+1] = x[2] end return table.concat(t) end)()")
    assert "quest 40m" in top or "quest 39m" in top, top
    assert "8h" not in top, f"just the soonest: {top}"
    assert "quest" not in plain, f"on the top bar, not the prompt bar: {plain}"
    # the panel: each pinned quest's time
    o.lua("sbo.cfg.questPins = { ['52'] = true, ['3519'] = true }")
    card = o.lua("local h = sbo.questCardHtml('3519', sbo.quests['3519']); return table.concat(h, '\\n')")
    assert "8h1" in _re.sub("<[^>]+>", "", card) and "left" in card, card
    # turned in: no more timer
    o.lua("sbo.quests['52'].active = false")
    o.lua("sbo.drawBar()")
    top = o.ev("(function() local t = {} for _, x in ipairs(sbo.topBarSegs or {}) do t[#t+1] = x[2] end return table.concat(t) end)()")
    assert "quest 8h" in top, f"the next soonest: {top}"


@test
def quest_time_up():
    import time as _time
    o = Oven()
    o.lua('''sbo.cfg.promptPattern = "<%d+hp"; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end; sbo.notifyQuest = function(m) SAYS[#SAYS+1] = m end
      SENT = {}
      REPLY = { "                   Quest #3390 : Cooking Spaghetti and Pesto (  9/10  complete).", "A total of [1] quests." }
      send = function(c) SENT[#SENT+1] = c; sbo.onSend(nil, c); if c == "quest info" then for _, l in ipairs(REPLY) do line = l; sbo.onLine() end end; line = "<281hp 696sp 457st>"; sbo.onLine() end''')
    o.set_gmcp("char.status", '{ state = "playing" }')
    o.feed("<281hp 696sp 457st>")
    now = int(_time.time())
    o.lua(f"""sbo.quests['3519'] = {{ name = 'Daily Quest - Feeding Hungry Mouths', active = true, total = 1, done = 0, deadline = {now - 5} }}
      sbo.quests['3390'] = {{ name = 'Cooking Spaghetti and Pesto', active = true, total = 10, done = 9 }}
      sbo.cfg.questPins = {{ ['3519'] = true, ['3390'] = true }}""")
    o.lua("sbo.questTimeUpCheck(); runTimers()")
    eq(list(o.ev("SENT").values()), ["quest info"], "time's up: the quest log checked")
    eq(sorted(o.ev("sbo.cfg.questPins").keys()), ["3390"], "gone from the log: off the panel")
    assert any("no longer in your quest log" in m for m in o.ev("SAYS").values()), list(o.ev("SAYS").values())
    o.lua("SENT = {}; sbo.questTimeUpCheck(); runTimers()")
    eq(len(o.ev("SENT")), 0, "asked once")


@test
def tabs_auto_off():
    o = Oven()
    o.lua('''sbo.cfg.window = true
      function FRONT() local f = {} for _, k in ipairs({ "view", "help", "log", "chat" }) do if WIDGETS["ovenTabs3Page_" .. k].shown then f[#f + 1] = k end end return table.concat(f, ",") end
      sbo.viewAdd({ lines = { { { "white", "an item" } } }, links = {} })
      sbo.command("tabs auto off")''')
    eq(o.ev("sbo.cfg.tabAuto"), False, "setting saved")
    o.lua('sbo.showHelp("classes", { "[1065 ] CLASSES", "Character classes" })')
    eq(o.ev("FRONT()"), "view", "a help page doesn't take the window")
    eq(o.ev("WIDGETS.ovenTabs3_help.text"), "<center>Help •</center>", "the Help tab is marked")
    assert "(in window)" in o.ev("CREATED[#CREATED]"), "the page was still drawn in its tab"
    o.lua('sbo.command("tab help")')
    eq((o.ev("FRONT()"), o.ev("WIDGETS.ovenTabs3_help.text")), ("help", "<center>Help</center>"), "looking clears the mark")
    o.lua('sbo.viewAdd({ lines = { { { "white", "another" } } }, links = {} })')
    eq((o.ev("FRONT()"), o.ev("WIDGETS.ovenTabs3_view.text")), ("help", "<center>Inspector •</center>"), "an item while reading help")
    o.lua('sbo.command("kills")')
    eq(o.ev("FRONT()"), "log", "sbo kills, typed, still switches")
    o.lua('sbo.command("tabs auto on"); sbo.showHelp("x", { "[1 ] X" })')
    eq(o.ev("FRONT()"), "help", "auto on again")


@test
def help_both_places():
    o = Oven()
    def ask(setting):
        o.lua(f'''sbo.command("helpwindow {setting}"); MAIN = {{}}; sbo.onSend(nil, "help classes")
          sbo.cap.decho = {{ "<192,192,192>[1065 ] CLASSES", "<192,192,192>Character classes in Alyria" }}
          sbo.cap.plain = {{ "[1065 ] CLASSES", "Character classes in Alyria" }}
          sbo.finish("prompt"); runTimers()''')
        return "".join(o.ev("MAIN").values())
    o.lua('''sbo.cfg.window = true; MAIN = {}
      decho = function(w, t) if t == nil then t = w; w = "main" end if w == "main" then MAIN[#MAIN+1] = t end end
      cecho = decho''')
    main = ask("both")   # still accepted: same as sbo mirror help on
    assert "Character classes" in main and "→ help window" not in main, f"both: {main}"
    assert "Character classes" in o.ev("WIDGETS[sbo.helpPg.prefix .. sbo.helpPg.flip .. 'Label'].html"), "both: and in the Help tab"
    main = ask("on")
    assert "Character classes" not in main and "→ help window" in main, f"on: {main}"
    o.lua('sbo.command("mirror help on")'); main = ask("on")
    assert "→ help window" in main, "helpwindow on turns help mirroring off"
    o.lua('sbo.command("mirror help on"); MAIN = {}')
    o.lua('''sbo.onSend(nil, "help x"); sbo.cap.decho = { "<1,1,1>[1 ] X", "<1,1,1>a help line" }; sbo.cap.plain = { "[1 ] X", "a help line" }
             sbo.finish("prompt"); runTimers()''')
    assert "a help line" in "".join(o.ev("MAIN").values()), "sbo mirror help on"


@test
def mirror_tabs():
    o = Oven()
    o.lua('''sbo.cfg.window = true; sbo.cfg.promptPattern = "<%d+hp"; MAIN = {}
      local function keep(w, t) if t == nil then t = w; w = "main" end if w == "main" then MAIN[#MAIN+1] = t end end
      decho = keep; cecho = keep; echo = keep
      sbo.viewAdd({ lines = { { { "white", "x" } } }, links = {} })''')
    eq(dict(o.ev("sbo.cfg.mirror").items()), {"view": True, "help": False, "log": False, "chat": True}, "defaults")
    # log
    o.lua('MAIN = {}; sbo.command("session")')
    assert "Session" not in "".join(o.ev("MAIN").values()), "log off: session only in the Log tab"
    o.lua('sbo.command("mirror log on"); MAIN = {}; sbo.command("session")')
    assert "Session" in "".join(o.ev("MAIN").values()), "log on: session on the main screen too"
    assert "Session" in o.ev("WIDGETS[sbo.logPg.prefix .. sbo.logPg.flip .. 'Label'].html"), "...and in the Log tab"
    # inspector: a score through the capture
    def score():
        o.lua('''MAIN = {}; sbo.onSend(nil, "eq")
          sbo.cap.plain = { "You are using:", "<worn on head>       a cap (new)", "<worn on neck>       nothing" }
          sbo.cap.decho = sbo.cap.plain; sbo.finish("prompt"); runTimers()''')
        return "".join(o.ev("MAIN").values())
    assert "cap" in score(), "inspector on: layout on the main screen"
    o.lua('sbo.command("mirror inspector off")')
    assert "cap" not in score(), "inspector off: only in the Inspector"
    assert "cap" in o.ev("WIDGETS[sbo.viewPg.prefix .. sbo.viewPg.flip .. 'Label'].html"), "...which still has it"
    # chat
    o.lua('DELETED_LINES = 0; deleteLine = function() DELETED_LINES = DELETED_LINES + 1 end')
    o.feed("[CLAN] Moss: 'hi'")
    eq(o.ev("DELETED_LINES"), 0, "chat on: stays on the main screen")
    o.lua('sbo.command("mirror chat off")')
    o.feed("[CLAN] Moss: 'hi again'", "Moss waves.")
    eq(o.ev("DELETED_LINES"), 1, "chat off: chat taken off the main screen, other lines kept")
    o.feed("[Mail]<270hp 550sp 401st>")
    eq([dict(x.items())["msg"] for x in o.ev("sbo.chat.lines").values()], ["hi", "hi again"], "both in the Chat tab")
    # per channel: CLAN to the Chat tab only, tells still on the main screen
    o.lua('sbo.command("chat show all"); DELETED_LINES = 0; sbo.command("chat hide clan")')
    o.feed("[CLAN] Moss: 'clan only'", "Wren tells you 'still here'")
    eq(o.ev("DELETED_LINES"), 1, "CLAN hidden, the tell shown")
    eq(o.ev("sbo.cfg.chatHide.CLAN"), True, "kept")
    o.feed("[Mail]<270hp 550sp 401st>")
    o.lua('sbo.command("chat hide all"); sbo.command("chat show tells"); DELETED_LINES = 0')
    o.feed("[CLAN] Moss: 'x'", "Wren tells you 'y'")
    eq((o.ev("DELETED_LINES"), o.ev("sbo.cfg.mirror.chat")), (1, None), "all hidden, then tells shown: CLAN stays hidden")
    o.feed("[Mail]<270hp 550sp 401st>")
    # the history: kept in oven.db, back in the tab when Mudlet opens again; clear empties the tab, not the history
    n = o.ev("#sbo.chat.lines")
    o.lua("sbo.chat.lines = {}; sbo.chatLoad()")
    eq(o.ev("#sbo.chat.lines"), n, "reloaded from the history")
    eq(dict(o.ev("sbo.chat.lines[#sbo.chat.lines]").items())["msg"], "y", "in order, newest last")
    o.lua('sbo.command("chat clear"); sbo.chat.lines = {}; sbo.chatLoad()')
    eq(o.ev("#sbo.chat.lines"), 0, "cleared stays cleared")
    eq(o.ev("sbo.dbRow('SELECT COUNT(*) AS n FROM chat_log').n"), n, "the history itself is kept")
    o.lua('sbo.command("mirror bogus on")')


GAME = r'''
  SENT = {}
  local function item(n, kind) return { "Item '" .. n .. "' is type " .. kind .. ", alignment 0, made of steel (in (new) condition),",
    "has keywords 'x'.", "This item weighs 1 stones and 0 pebbles, and is valued at 10 gold." } end
  REPLY = {
    ["inventory"] = { " You are carrying:", "     a sword (new)", "(  2) a lime green vial (new)", "     a bag (new)",
                      "A total of 4 items weighing 2 stones, 0 pebbles (0pb gold weight)" },
    ['look "a sword"'] = item("a sword", "weapon"),
    ['look "a lime green vial"'] = item("a lime green vial", "potion"),
    ['look "a bag"'] = item("a bag", "container"),
    ['look in "a bag"'] = { "A bag contains:", "     a ring (new)", "     a cloak (new)", "A total of 2 (30 max) items weighing 0 st, 5 pbs (5 sts, 0 pbs max)." },
  }
  if INSIDE_OK then
    REPLY['look "a ring" in "a bag"'] = item("a ring", "jewelry")
    REPLY['look "a cloak" in "a bag"'] = item("a cloak", "armor")
  end
  send = function(c)
    SENT[#SENT + 1] = c
    sbo.onSend(nil, c)
    -- the game answers at once (the tests' timers all fire together, so a later reply would be too late)
    local r = REPLY[c] or { "You don't see that here." }
    for _, l in ipairs(r) do line = l; sbo.onLine() end
    line = "<270hp 550sp 401st>"; sbo.onLine()
  end
'''


@test
def learn_inventory_and_containers():
    for inside_ok in (True, False):
        o = Oven()
        o.lua(f'sbo.cfg.promptPattern = "<%d+hp"; INSIDE_OK = {"true" if inside_ok else "false"}; SAYS = {{}}; sbo.log = function(m) SAYS[#SAYS+1] = m end')
        o.lua(GAME)
        o.lua('sbo.items["a sword"] = nil; sbo.command("learn inv"); runTimers()')
        sent = list(o.ev("SENT").values())
        known = [n for n in ("a sword", "a lime green vial", "a bag", "a ring", "a cloak") if o.ev(f'sbo.items["{n}"] ~= nil')]
        says = list(o.ev("SAYS").values())
        if inside_ok:
            eq(known, ["a sword", "a lime green vial", "a bag", "a ring", "a cloak"], "everything carried and in the bag")
            assert 'look "a cloak" in "a bag"' in sent, sent
        else:
            eq(known, ["a sword", "a lime green vial", "a bag"], "carried items; the bag's can't be looked at")
            assert 'look "a cloak" in "a bag"' not in sent, f"stops after the first refusal: {sent}"
            assert any("inside a container" in m for m in says), says
        eq(sent[0], "inventory", "starts from the inventory")
        eq(sent[-1], "inventory", "shows the inventory at the end")
        assert any("learned" in m for m in says), says
    # nothing new the second time
    o.lua('SENT = {}; sbo.command("learn inv"); runTimers()')
    assert not any(c.startswith('look "a sword"') for c in o.ev("SENT").values()), "known items aren't looked at again"


@test
def pickup_looks_quietly():
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end')
    o.lua(GAME)
    o.set_gmcp("char.status", '{ state = "playing", position = "standing", enemy = "_empty" }')
    o.lua('sbo.items["a sword"] = nil; sbo.items["a bag"] = nil')
    o.feed("You take a sword from the corpse of a goblin.", "You get 12 gold coins from the corpse of a goblin.",
           "You take note of the directions on a weatherbeaten signpost near Lasler, and head north.",
           "<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    sent = list(o.ev("SENT").values())
    eq(sent, ['look "a sword"'], "the new item is looked at, the gold and the signpost aren't")
    assert not any("signpost" in r["item"] for r in o.rows("SELECT item FROM loot")), "a signpost isn't loot"
    assert o.ev('sbo.items["a sword"] ~= nil'), "and remembered"
    assert not any("looking at" in m for m in o.ev("SAYS").values()), "quietly"
    # mid-fight: waits for the fight to end
    o.lua('SENT = {}; sbo.fights = { x = { key = "x" } }')
    o.feed("You get a bag.", "<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    eq(len(o.ev("SENT")), 0, "not during a fight")
    o.lua('sbo.fights = {}')
    o.feed("<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    eq(list(o.ev("SENT").values()), ['look "a bag"'], "after it")
    # known items aren't looked at again; others' pickups aren't ours; off is off
    o.lua('SENT = {}')
    o.feed("You get a sword.", "Moss gets a lime green vial.", "<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    eq(len(o.ev("SENT")), 0, "known, or someone else's")
    o.lua('sbo.command("pickup look off"); sbo.items["a lime green vial"] = nil')
    o.feed("You get 2 of a lime green vial.", "<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    eq(len(o.ev("SENT")), 0, "switched off")
    o.lua('sbo.command("pickup look on")')
    o.feed("You get 2 of a lime green vial.", "<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    eq(list(o.ev("SENT").values()), ['look "a lime green vial"'], "a stack is looked at by its name")
    # not before you're playing
    o.lua('SENT = {}; sbo.items["a ring"] = nil')
    o.set_gmcp("char.status", '{ state = "login" }')
    o.feed("You get a ring.", "<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    eq(len(o.ev("SENT")), 0, "never before you're in the game")
    # an upgrade says so
    o.lua('''SAYS = {}
      sbo.noteCombat({ "57 Damage: (+46 from weapon)", "55 Accuracy: (+16 from weapon)", "31% Critical Hit chance:" })
      sbo.cfg.maxes = { hp = 365, sp = 875 }; sbo.cfg.arLoc = { torso = 10 }
      local function it(n, str) return { name = n, worn = "on body", level = 1, affects = { { "accuracy", tostring(str) } }, ar = 1, raw = {} } end
      sbo.remember(it("a worn vest", 1)); sbo.remember(it("a fine vest", 9)); sbo.remember(it("a poor vest", 0))
      sbo.eqNames = { "a worn vest" }
      sbo.pickupVerdict(sbo.items["a fine vest"]); sbo.pickupVerdict(sbo.items["a poor vest"])''')
    says = list(o.ev("SAYS").values())
    eq(len(says), 1, f"only the upgrade is mentioned: {says}")
    assert "a fine vest" in says[0] and "a worn vest" in says[0], says


MAP_GAME = r"""
  -- a town (area 2: rooms 1-3), the wilds (area 1: 100-250, signposts at 120, 150 and 250), Rune (area 3: 251-255)
  EXITS, AREA = {}, {}
  local function link(a, b) EXITS[a] = EXITS[a] or {}; EXITS[b] = EXITS[b] or {}; EXITS[a].e = b; EXITS[b].w = a end
  local chain = { 1, 2, 3 }
  for i = 100, 255 do chain[#chain + 1] = i end
  SIGNS = { [120] = true, [150] = true, [250] = true }
  for i = 1, #chain - 1 do link(chain[i], chain[i + 1]) end
  for _, id in ipairs(chain) do AREA[id] = id <= 3 and 2 or (id <= 250 and 1 or 3) end
  roomExists = function(id) return AREA[tonumber(id)] ~= nil end
  getRoomArea = function(id) return AREA[tonumber(id)] end
  getRoomName = function(id) return id == 250 and "Runic Highway" or ("Room " .. tostring(id)) end
  getRoomAreaName = function(a) return a == 3 and "Towne of Rune" or ("Area " .. tostring(a)) end
  centerview = function() end; highlightRoom = function() end; unHighlightRoom = function() end
  getPath = function(a, b)
    a, b = tonumber(a), tonumber(b)
    local prev, q, seen = {}, { a }, { [a] = true }
    while #q > 0 do
      local x = table.remove(q, 1)
      if x == b then break end
      for d, y in pairs(EXITS[x] or {}) do if not seen[y] then seen[y] = true; prev[y] = { x, d }; q[#q + 1] = y end end
    end
    if not seen[b] then return false end
    speedWalkDir, speedWalkPath = {}, {}
    local x = b
    while x ~= a do table.insert(speedWalkDir, 1, prev[x][2]); table.insert(speedWalkPath, 1, tostring(x)); x = prev[x][1] end
    return true
  end
  HERE = 1
  local function at(id)
    HERE = id
    gmcp.room = gmcp.room or {}
    gmcp.room.info = { num = tostring(id), wilds = (AREA[id] == 1) and "true" or "false" }
    sbo.onRoom()
  end
  AT = at
  SENT, OUTBOX = {}, {}
  send = function(c) SENT[#SENT + 1] = c; OUTBOX[#OUTBOX + 1] = c end
  local function lines(...) for _, l in ipairs({ ... }) do line = l; sbo.onLine() end end
  LINES = lines
  -- the timers waiting now (not ones they start), like time passing once
  local function tick()
    local snap, fired = {}, false
    for id, t in pairs(timers) do snap[id] = t end
    for id, t in pairs(snap) do if timers[id] then timers[id] = nil; t[2](); fired = true end end
    return fired
  end
  PUMP = function()
    repeat PUMP1() until not tick() and #OUTBOX == 0
  end
  PUMP1 = function()
    while #OUTBOX > 0 do
      local c = table.remove(OUTBOX, 1)
      sbo.onSend(nil, c)
      if EXITS[HERE] and EXITS[HERE][c] then at(EXITS[HERE][c]); lines("<270hp 550sp 401st>")
      elseif c == "run rune" and RUN_HOOK and RUN_HOOK() then
        -- (a test's own handling of this run)
      elseif c == "run rune" then
        if AREA[HERE] ~= 1 then lines("That only works in the wilds!", "<270hp 550sp 401st>")
        elseif not SIGNS[HERE] then lines("You need a signpost to run from.", "<270hp 550sp 401st>")
        else
          lines("You start running.", "<270hp 550sp 401st>")
          at(200); lines("You take note of the directions on a weatherbeaten signpost near Townton, and head east.", "You run eastward.", "<270hp 550sp 401st>")
          at(250); lines("You run eastward.", "     A weatherbeaten signpost is firmly planted here.", "You stop running.",
                         "Your travel abruptly comes to a halt.", "<270hp 550sp 401st>")
        end
      elseif c == "look signpost" then
        lines("You focus your powers of observation on a weatherbeaten signpost on the road:",
              "Item 'a weatherbeaten signpost on the road' is type roadsign, alignment 0, made of wood (in (new) condition),",
              "has keywords 'weatherbeaten signpost roadsign sign post Sepharia'.",
              "* rune is east.", "* townton is west.", "A weatherbeaten signpost is firmly planted here.", "<270hp 550sp 401st>")
      else lines("Huh?", "<270hp 550sp 401st>") end
    end
  end
"""


@test
def signpost_runs():
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; sbo.cfg.map = true; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end')
    o.lua(MAP_GAME)
    o.set_gmcp("char.status", '{ state = "playing" }')
    # look at a signpost: the run names
    o.lua('AT(120)')
    o.feed("You focus your powers of observation on a weatherbeaten signpost outside Townton's south gate:",
           "Item 'a weatherbeaten signpost outside Townton's south gate' is type roadsign, alignment 0, made of wood (in (new) condition),",
           "has keywords 'weatherbeaten signpost roadsign sign post Sepharia'.",
           "This level 1 item has the attributes: durable nodecay magic-resistant no-equipment-index none",
           "* rune is east.", "* towerofart is east.", "* townton is west.",
           "A weatherbeaten signpost is firmly planted here.", "<270hp 550sp 401st>")
    eq(sorted(o.ev("sbo.runData().names").keys()), ["rune", "towerofart", "townton"], "names from the signpost")
    # the user runs: Oven learns where it ends
    o.lua('SENT = {}; OUTBOX = { "run rune" }; PUMP()')
    eq(o.ev("sbo.runData().ends.rune"), 250, "the run's end is learned")
    assert not o.ev("sbo.runData().ends.towerofart"), "not one that wasn't run"
    # a long walk now uses it: to the signpost, run, the last few steps
    o.lua('AT(1); SENT = {}; sbo.mapWalkTo(255); PUMP()')
    eq(list(o.ev("SENT").values()), ["e"] * 23 + ["run rune"] + ["e"] * 5, "walk to the signpost, run, walk")
    eq(o.ev("HERE"), 255, "arrived")
    assert any("walk arrived" in m for m in o.ev("SAYS").values())
    # a short one doesn't
    o.lua('AT(1); SENT = {}; sbo.mapWalkTo(110); PUMP()')
    assert "run rune" not in list(o.ev("SENT").values()), "short walks stay on foot"
    # sbo run <name>: goes to where that run ends
    o.lua('AT(140); SENT = {}; sbo.command("run rune"); PUMP()')
    eq(o.ev("HERE"), 250, "sbo run rune: to the signpost, then the run")
    eq(list(o.ev("SENT").values())[0], "w", "back to the signpost first")
    # the game refuses: walks instead
    o.lua('SIGNS[120] = nil; AT(2); SENT = {}; sbo.mapWalkTo(255); PUMP()')
    eq(o.ev("HERE"), 255, "fell back to walking")
    assert any("walking instead" in m for m in o.ev("SAYS").values()), list(o.ev("SAYS").values())
    o.lua('sbo.command("signposts")')


@test
def mounted_run():
    # on a mount the game says "traveling", not "running" (recorded 2026-11-13: Oven took the run
    # for failed after 6 seconds, and its first step on foot halted the gryphon)
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; sbo.cfg.map = true; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end')
    o.lua(MAP_GAME)
    o.set_gmcp("char.status", '{ state = "playing" }')
    o.lua("""
      RUN_HOOK = function()
        if not SIGNS[HERE] then return false end
        LINES("You start traveling with a winged gryphon.", "<270hp 550sp 401st>")
        STEP = 0
        return true
      end
      -- the gryphon moves on a room each time timers tick (a second or so in the game)
      local tick = 0
      MOVE = function()
        if not STEP then return end
        STEP = STEP + 1
        if STEP == 1 then AT(200); LINES("You take note of the directions on a weatherbeaten signpost near Townton, and head east.", "You travel eastward on a winged gryphon.", "<270hp 550sp 401st>")
        elseif STEP == 2 then AT(250); LINES("You travel eastward on a winged gryphon.", "     A weatherbeaten signpost is firmly planted here.", "Your travel abruptly comes to a halt.", "<270hp 550sp 401st>"); STEP = nil end
      end
      sbo.dbx("INSERT OR REPLACE INTO signposts (room, sign, dests, exact, last) VALUES (120, 'a post', 'rune=east', 1, 1)")
    """)
    o.lua("AT(120); SENT = {}; sbo.mapWalkTo(255); PUMP1()")
    eq(list(o.ev("SENT").values()), ["run rune"], "runs from the signpost")
    # the run's 6-second check fires while the gryphon is still going
    o.lua("for id, t in pairs(timers) do if t[1] == 6 then timers[id] = nil; t[2]() end end")
    eq(o.ev("sbo.running and sbo.running.started"), True, "still running: the start was seen")
    o.lua("MOVE(); MOVE(); PUMP()")
    eq(o.ev("HERE"), 255, "arrived")
    assert not any("walking instead" in m for m in o.ev("SAYS").values()), list(o.ev("SAYS").values())
    eq(o.ev("sbo.runData().ends.rune"), 250, "the end is learned from a mounted run too")


@test
def run_stops_at_a_signpost_on_the_way():
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; sbo.cfg.map = true; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end')
    o.lua(MAP_GAME)
    o.set_gmcp("char.status", '{ state = "playing" }')
    # the game halts the run at the signpost at 150 (a junction) the first time
    o.lua("""
      SIGNS[150] = true
      HALTED = false
      RUN_HOOK = function()
        if HALTED or not SIGNS[HERE] then return false end
        HALTED = true
        LINES("You start running.", "<270hp 550sp 401st>")
        AT(150); LINES("You run eastward.", "     A weatherbeaten signpost is firmly planted here.", "You stop running.", "<270hp 550sp 401st>")
        return true
      end
      sbo.dbx("INSERT OR REPLACE INTO signposts (room, sign, dests, exact, last) VALUES (120, 'a post', 'rune=east', 1, 1)")
    """)
    o.lua('AT(1); SENT = {}; sbo.mapWalkTo(255); PUMP()')
    sent = list(o.ev("SENT").values())
    eq(sent.count("run rune"), 2, f"ran on from the signpost on the way: {sent}")
    eq(o.ev("HERE"), 255, "arrived")
    eq(o.ev("sbo.runData().ends.rune"), 250, "the end is the real end, not the junction")
    assert any("running on" in m for m in o.ev("SAYS").values()), list(o.ev("SAYS").values())
    # ends saved by an older Oven (maybe junctions) are forgotten once, then learned again
    o.lua("sbo.cfg.runs = { names = { rune = {} }, ends = { rune = 150 } }")
    eq(o.ev("sbo.runData().ends.rune"), None, "old ends forgotten")
    o.lua("sbo.runData().ends.rune = 250")
    eq(o.ev("sbo.runData().ends.rune"), 250, "only once")


@test
def signpost_learning():
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; sbo.cfg.map = true; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end')
    o.lua(MAP_GAME)
    o.set_gmcp("char.status", '{ state = "playing" }')
    # 0.48 and before logged "You take note…" as loot: it moves to the signposts
    o.lua('''sbo.dbx("INSERT INTO loot (t, who, item, n, room) VALUES (1, 'you', 'note of the directions on a weatherbeaten signpost near Townton, and head east', 1, 130)")
      sbo.dbClose(); sbo.dbOpen()''')
    eq(o.rows("SELECT COUNT(*) AS n FROM loot")[0]["n"], 0, "the old 'You take note…' rows are cleared")
    # standing at a signpost Oven hasn't read: it looks, quietly
    o.lua('AT(150); SENT = {}')
    o.feed("Room 150", "     A weatherbeaten signpost is firmly planted here.", "<270hp 550sp 401st>")
    o.lua('PUMP(); runTimers(); PUMP()')
    eq(list(o.ev("SENT").values()), ["look signpost"], "looked at")
    sp = o.ev("sbo.signAt(150)")
    eq(sorted(sp.dests.keys()), ["rune", "townton"], "its runs, kept with the room")
    assert sp.exact
    o.lua('SENT = {}')
    o.feed("Room 150", "     A weatherbeaten signpost is firmly planted here.", "<270hp 550sp 401st>")
    o.lua('runTimers(); PUMP()')
    eq(len(o.ev("SENT")), 0, "read once")
    # a run whose end isn't known: to the town the target is in, then walk on - and its end is learned
    assert not o.ev("sbo.runData().ends.rune")
    o.lua('AT(1); SENT = {}; sbo.mapWalkTo(255); PUMP()')
    eq(list(o.ev("SENT").values()), ["e"] * 53 + ["run rune"] + ["e"] * 5, "walk to the signpost, run to the town's name, walk")
    eq(o.ev("HERE"), 255, "arrived")
    eq(o.ev("sbo.runData().ends.rune"), 250, "and learned where it ends")
    assert not o.ev("sbo.signAt(200)"), "a signpost only noted in passing isn't kept"
    o.lua('sbo.command("signposts"); sbo.roomCardLines(150)')


@test
def shop_lists():
    shops = open(fixture("shop_list.txt"), encoding="utf-8").read().rstrip("\n").split("\n---\n")
    o = Oven()
    o.lua('''sbo.cfg.promptPattern = "<%d+hp"
      roomExists = function() return true end; getRoomName = function(id) return "Room " .. id end
      getRoomArea = function() return 1 end; getRoomAreaName = function() return "Towne of Rune" end''')
    for room, (cmd, text) in zip((10515, 10557, 10636), (("sh li", shops[0]), ("shop list", shops[1]), ("sh i", shops[2]))):
        o.lua(f'sbo.mapRoom = {room}; sbo.onSend(nil, "{cmd}")')
        o.feed(*text.split("\n"), "<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    eq([r["name"] for r in o.rows("SELECT name FROM shops ORDER BY room")],
       ["the Sushi Bar", "local potion shop", "Ganuk's Express Travels"], "the shops, by room")
    eq(o.rows("SELECT item, level, amount, cost FROM shop_items WHERE room = 10557 AND no = 13"),
       [{"item": "A potion of detect illusion", "level": 45, "amount": "No limit", "cost": 890}], "a row")
    eq(o.rows("SELECT COUNT(*) AS n FROM shop_items")[0]["n"], 13, "every item")
    # prices in another currency (the Van Pelt reward shop)
    o.lua('sbo.mapRoom = 10789; sbo.onSend(nil, "sh li")')
    o.feed(*shops[3].split("\n"), "<270hp 550sp 401st>")
    eq(o.rows("SELECT item, cost, currency FROM shop_items WHERE room = 10789 AND no = 4"),
       [{"item": "A voucher for a Skiff ship", "cost": 2, "currency": "rewardunits"}], "reward units")
    eq(o.rows("SELECT COUNT(*) AS n FROM shop_items WHERE room = 10789")[0]["n"], 4, "all of them")
    eq(o.rows("SELECT DISTINCT currency FROM shop_items WHERE room = 10515"), [{"currency": "gold"}], "gold as before")
    out = o.lua('local out = sbo.shopLines(80, "voucher"); local s = {} for _, r in ipairs(out) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = "\\n" end; return table.concat(s)')
    assert "rewardunits" in out, out
    out2 = o.lua('local out = sbo.shopLines(80, "item tuna"); local s = {} for _, r in ipairs(out) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end end; return table.concat(s)')
    assert "A tuna roll" in out2, f"'item' in front is ignored: {out2}"
    # stock changes: the list replaces what that shop had
    o.lua('sbo.mapRoom = 10515')
    o.feed("Welcome to the Sushi Bar!", "No.  Item Name                                    Level Amount       Cost",
           "     1) A tuna roll                                  10    998          [        260 gold]", "<270hp 550sp 401st>")
    eq(o.rows("SELECT item, cost FROM shop_items WHERE room = 10515"), [{"item": "A tuna roll", "cost": 260}], "restocked")
    # where to buy
    out = o.lua('local out, links = sbo.shopLines(80, "potion of cure"); local s = {} for _, r in ipairs(out) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = "\\n" end; return table.concat(s), #links')
    text, nlinks = out
    assert "cure light wounds" in text and "cure serious wounds" in text and "local potion shop" in text, text
    assert text.index("cure light") < text.index("cure serious"), "cheapest first"
    eq(nlinks, 2, "a walk link each")
    o.lua('sbo.command("shops"); sbo.command("shops token"); sbo.roomCardLines(10557)')


@test
def command_tree():
    o = Oven()
    o.lua('SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end; SENT = {}; send = function(c) SENT[#SENT+1] = c end')
    def says(cmd, typed=True):
        o.lua('SAYS = {}')
        o.L.globals().CMD = cmd
        o.lua('sbo.typedCommand(CMD)' if typed else 'sbo.command(CMD)')
        return " | ".join(o.ev("SAYS").values())
    # every command in the tree (and the menu, group lists, help all) runs
    for c in ["", "help all", "help eq", "help log", "config", "config bar", "version", "stop", "inspector", "log", "map", "quest", "chat"]:
        says(c)
    for e in o.ev("sbo.CMDS").values():
        if e.subs:
            says(e.name)
            for sub in e.subs.values():
                if not sub.listOnly:
                    r = says(e.name + " " + sub.name)
                    assert "failed" not in r, (e.name, sub.name, r)
    # short forms
    o.lua('sbo.cfg.barWidth = 10')
    says("conf bar.w 12")
    eq(o.ev("sbo.cfg.barWidth"), 12, "conf bar.w 12")
    says("config q.op 80")
    eq(o.ev("sbo.cfg.questHudOpacity"), 80, "config q.op 80")
    says("set eq.stats of")
    eq(o.ev("sbo.cfg.eqStats"), False, "set eq.stats of(f)")
    eq([(r["name"], r["value"], r["how"]) for r in o.rows("SELECT name, value, how FROM setting_log ORDER BY id DESC LIMIT 1")],
       [("eq.stats", "off", "typed")], "setting changes are logged, with how")
    says("off"); says("on")
    eq([r["value"] for r in o.rows("SELECT value FROM setting_log WHERE name = 'formatting' ORDER BY id")], ["off", "on"], "formatting too")
    assert "could be" in says("co"), "co: compare or config"
    assert "could be" in says("g"), "g: go or (0.51's) gear"
    assert "bar.session is" in says("config b.s"), "matched part by part: b.s = bar.session"
    assert "could be" in says("config e.s"), "e.s: eq.stats or eq.slots"
    r = says("config eq.stats")
    assert "eq.stats is off" in r, r
    assert "takes" in says("config eq.slots wide")
    # old commands still work, with a tip once a session
    r = says("eqstats on")
    assert "tip: that's sbo config eq.stats now" in r, r
    eq(o.ev("sbo.cfg.eqStats"), True, "old form works")
    assert "tip" not in says("eqstats off"), "the tip once"
    assert "tip" not in says("kills", typed=False), "not for Oven's own calls"
    # 0.51's names: still work, with a tip once
    r = says("gear items")
    assert "sbo gear is sbo eq now" in r, r
    r = says("ge up")
    assert "no command" not in r and "could be" not in r, f"0.51's short form ge up still works: {r}"
    o.lua('sbo.cfg.mirror.chat = true')
    says("config mirror.chat off")
    eq(o.ev("sbo.cfg.mirror.chat"), False, "an old setting name")
    says("config chat.mirror on")
    eq(o.ev("sbo.cfg.mirror.chat"), True, "the new one")
    assert "tip" in says("window clear"), "window clear -> inspector clear"
    assert "tip" in says("map panel off"), "an old map form"
    eq(o.ev("sbo.cfg.mapPanel"), False, "still works")
    # quest.hud
    says("config quest.hud off")
    eq(o.ev("sbo.cfg.questHud"), False, "quest HUD off")
    # stop
    o.lua('sbo.walk = { dirs = {"e"}, path = {2}, step = 1 }')
    assert "stopped the walk" in says("stop")
    eq(o.ev("sbo.walk"), None, "walk cancelled")
    assert "nothing to stop" in says("st")
    # log clear asks first
    o.lua("sbo.dbx(\"INSERT INTO kills (t, key, name, n) VALUES (1, 'x', 'a rat', 1)\")")
    assert "again within 30 seconds" in says("log clear kills")
    eq(o.rows("SELECT COUNT(*) AS n FROM kills")[0]["n"], 1, "not yet")
    says("log cl k")
    eq(o.rows("SELECT COUNT(*) AS n FROM kills")[0]["n"], 0, "cleared on the second ask")
    # learn: worn, then carried
    o.lua('SENT = {}; sbo.eqNames = {}')
    says("eq learn")
    assert "inventory" in list(o.ev("SENT").values()), list(o.ev("SENT").values())
    # compare against
    o.lua('sbo.remember({ name = "a fine vest", worn = "on body", level = 1, affects = {}, raw = {} })')
    says("eq compare against fine vest")
    assert o.ev("sbo.pinned") is not None, "comparing against it"
    assert "no longer comparing" in says("e comp against")
    eq(o.ev("sbo.pinned"), None, "stopped")
    # version
    assert "v" + o.ev("sbo.version") in says("version")


@test
def shop_listed_on_arrival():
    sushi = open(fixture("shop_list.txt"), encoding="utf-8").read().split("\n---\n")[0].split("\n")
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; GAGGED = 0; deleteLine = function() GAGGED = GAGGED + 1 end; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end')
    # as in a real session: the game's last status is from a fight hours ago
    o.set_gmcp("char.status", '{ state = "playing", position = "fighting", enemy = "_empty" }')
    o.L.globals().SUSHI = o.L.table_from(sushi)
    o.lua("""
      roomExists = function() return true end; getRoomName = function(id) return "Room " .. id end
      centerview = function() end
      SENT = {}
      send = function(c)
        SENT[#SENT + 1] = c
        sbo.onSend(nil, c)
        if c == "shop list" then
          for _, l in ipairs(SUSHI) do line = l; sbo.onLine() end
          line = "<270hp 550sp 401st>"; sbo.onLine()
        end
      end
      function ARRIVE(id)
        gmcp.room = { info = { num = tostring(id), wilds = "false" } }
        sbo.onRoom()
        line = "Kasan's Sushi Bar"; sbo.onLine()
        line = "<270hp 550sp 401st>"; sbo.onLine()
        runTimers()
      end
      sbo.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last) VALUES (10515, 'kasan', 'Kasan stands here.', 'Shop', 1, 1)")
    """)
    o.feed("<270hp 550sp 401st>")          # playing: a status prompt seen
    o.lua("ARRIVE(10515)")
    eq(list(o.ev("SENT").values()), ["shop list"], "listed on arrival")
    assert any("new shop: the Sushi Bar · 5 items" in m for m in o.ev("SAYS").values()), list(o.ev("SAYS").values())
    eq(o.rows("SELECT COUNT(*) AS n FROM shop_items WHERE room = 10515")[0]["n"], 5, "and saved")
    assert o.ev("GAGGED") >= len([l for l in sushi if l.strip()]), "quietly: off the main screen"
    o.lua('getRoomArea = function() return 1 end; getRoomAreaName = function() return "Towne of Rune" end; getRoomExits = function() return {} end')
    col = o.lua('for _, r in ipairs(sbo.roomCardLines(10515)) do for _, g in ipairs(r) do if tostring(g[2]):find("^%$ ") then return g[1] .. "|" .. g[2] end end end')
    eq(col, "oven_slot|$ the Sushi Bar", "a shop with its stock: the usual $ line")
    # not again within the hour; not in a room without a shop
    o.lua("SENT = {}; ARRIVE(1); ARRIVE(10515)")
    eq(len(o.ev("SENT")), 0, "once; none elsewhere")
    # not while walking through, not when switched off
    o.lua("SENT = {}; sbo.shopTried = {}; sbo.dbx('DELETE FROM shops'); sbo.running = { name = 'rune', started = true }; ARRIVE(1); sbo.running = { name = 'rune', started = true }; ARRIVE(10515); sbo.running = nil")
    eq(len(o.ev("SENT")), 0, "not while running past")
    o.lua("sbo.command('config map.shoplist off'); sbo.shopTried = {}; ARRIVE(1); ARRIVE(10515)")
    eq(len(o.ev("SENT")), 0, "switched off")
    # typed: shown as the game sends it
    o.lua("GAGGED = 0; sbo.command('config map.shoplist on'); sbo.onSend(nil, 'sh li')")
    o.feed(*sushi, "<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    eq(o.ev("GAGGED"), 0, "a list you ask for stays on the screen")
    o.lua("SAYS = {}")
    o.feed(*sushi, "<270hp 550sp 401st>")
    assert not any("shop" in m for m in o.ev("SAYS").values()), "a known shop you list yourself: no line"
    # listed once: never again by itself, however long ago (your own lists keep it up to date)
    o.lua("SENT = {}; sbo.shopTried = {}; sbo.dbx('UPDATE shops SET last = 1'); sbo.shopCheckedRoom = nil; ARRIVE(1); ARRIVE(10515)")
    eq(len(o.ev("SENT")), 0, "a known shop isn't listed again")
    eq(o.ev("sbo.classify('shout hello')"), None, "shout isn't shop")
    eq(o.ev("(sbo.classify('read sign'))"), "item", "read sign is a look")
    eq(o.ev("(sbo.classify('read'))"), None, "read on its own isn't")
    # fighting: an enemy named just now, not a stale position
    eq(o.ev("sbo.fighting()"), False, "stale 'fighting' with no enemy")
    o.set_gmcp("char.status", '{ state = "playing", position = "fighting", enemy = "a rat", enemypct = 80 }')
    o.lua("sbo.onGmcpStatus()")
    eq(o.ev("sbo.fighting()"), True, "an enemy, just now")
    o.lua("sbo.live.statusAt = os.time() - 120")
    eq(o.ev("sbo.fighting()"), False, "an enemy named two minutes ago and nothing since")
    # in and straight out: both rooms' GMCP before any of their text - asked the moment it's a shop
    o.lua("""SENT = {}; sbo.shopTried = {}; sbo.dbx('DELETE FROM shops')
      sbo.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last) VALUES (10557, 'oldman', 'An old man eyes you greedily.', 'Shop', 1, 1)")
      local send0 = send; send = function(c) SENT[#SENT + 1] = c end
      gmcp.room = { info = { num = "10557" } }; sbo.onRoom()
      gmcp.room = { info = { num = "10556" } }; sbo.onRoom()
      send = send0""")
    eq(list(o.ev("SENT").values()), ["shop list"], "asked inside, before stepping out")
    assert any("shop list sent" in n for n in o.ev("sbo.autoNotes").values()), "noted"
    # a first visit: nothing known about the room until its text shows the keeper's [Shop] tag
    o.lua("""runTimers(); SENT = {}; sbo.shopTried = {}
      gmcp.room = { info = { num = "10690", name = "Thumper Van Pelt's Reward Emporium" } }; sbo.onRoom()
      for _, l in ipairs({ "",
          " Thumper Van Pelt's Reward Emporium                     -      [      -",
          "(-------------------------------------------------)     W <---(M)---> E",
          "                                                        -      -      -",
          "",
          "  All glittering gems, tokens and exotic weapons, the obsidian countertop",
          "here is covered in riches and wealth and beautiful, beautiful money.  ",
          "     A vast mural covers the northern wall.",
          "*[Shop] A tree-sized ogre stares at you passively, avoiding a fight.",
          "'You want be Legend, Pip?' Thumper Van Pelt asks. 'Or Duelist?'",
          "",
          "<270hp 550sp 401st>" }) do line = l; sbo.onLine() end
      runTimers()""")
    eq(list(o.ev("SENT").values()), ["shop list"], "asked once the keeper's tag is read")


@test
def own_errands_wait_for_idle():
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; sbo.log = function() end')
    o.lua(GAME)
    o.set_gmcp("char.status", '{ state = "playing" }')
    o.lua('sbo.items["a sword"] = nil; sbo.items["a bag"] = nil; SENT = {}')
    # you're typing: picked-up items wait
    o.lua('sbo.onSend(nil, "n")')
    o.feed("You get a sword.", "You get a bag.", "<270hp 550sp 401st>")
    o.L.execute("for id, t in pairs(timers) do if t[1] <= 0.5 then timers[id] = nil; t[2]() end end")
    eq(len(o.ev("SENT")), 0, "nothing while you're typing")
    # quiet for a couple of seconds: one at a time
    o.L.execute("runTimers()")
    eq(list(o.ev("SENT").values()), ['look "a sword"', 'look "a bag"'], "then each, in turn")
    # Oven's own commands aren't you typing
    o.lua('sbo.lastUserCmdAt = nil; sbo.sendOwn("look x", false)')
    eq(o.ev("sbo.lastUserCmdAt"), None, "its own command doesn't count")
    o.lua('sbo.onSend(nil, "look x")')
    assert o.ev("sbo.lastUserCmdAt") is not None, "the same command typed by you does"


@test
def shop_refuses_you():
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; GAGGED = {}; deleteLine = function() GAGGED[#GAGGED + 1] = line end; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end')
    o.set_gmcp("char.status", '{ state = "playing", level = 23 }')
    o.lua("""
      sbo.live.level = 23
      roomExists = function() return true end; getRoomName = function(id) return "Room " .. id end
      getRoomArea = function() return 1 end; getRoomAreaName = function() return "Towne of Rune" end
      getRoomExits = function() return {} end
      centerview = function() end
      SENT = {}
      send = function(c)
        SENT[#SENT + 1] = c
        sbo.onSend(nil, c)
        if c == "shop list" then
          line = "A Gnomish Travel attendant tells you 'Sorry, but I cannot sell my wares to someone of your level of experience.'"; sbo.onLine()
          line = "<270hp 550sp 401st>"; sbo.onLine()
        end
      end
      function ARRIVE(id)
        gmcp.room = { info = { num = tostring(id) } }
        sbo.onRoom()
        line = "The Gnomish Travel Corporation, Rune Bureau"; sbo.onLine()
        line = "<270hp 550sp 401st>"; sbo.onLine()
        runTimers()
      end
      sbo.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last) VALUES (111125, 'gnome', 'A Gnomish Travel attendant is here.', 'Shop', 1, 1)")
    """)
    o.feed("<270hp 550sp 401st>")
    o.lua("ARRIVE(111125)")
    eq(list(o.ev("SENT").values()), ["shop list"], "asked")
    eq(o.rows("SELECT said, level FROM shop_refusals"), [{"said": "Sorry, but I cannot sell my wares to someone of your level of experience.", "level": 23}], "remembered, with your level")
    assert any("cannot sell my wares" in g for g in o.ev("GAGGED").values()), "Oven's own ask: the refusal kept off the screen"
    assert any("won't sell to you" in m for m in o.ev("SAYS").values()), "said once, as Oven's note"
    # same level: not asked again, even after the hour
    o.lua("SENT = {}; sbo.shopTried = {}; ARRIVE(1); ARRIVE(111125)")
    eq(len(o.ev("SENT")), 0, "not again at the same level")
    # a new level: once more
    o.lua("sbo.live.level = 24; sbo.shopTried = {}; ARRIVE(1); ARRIVE(111125)")
    eq(list(o.ev("SENT").values()), ["shop list"], "asked again at a new level")
    card = o.lua('local t = {} for _, r in ipairs(sbo.roomCardLines(111125)) do for _, g in ipairs(r) do t[#t+1] = tostring(g[2] or "") end end return table.concat(t)')
    assert "won't sell to you" in card, card
    col = o.lua('for _, r in ipairs(sbo.roomCardLines(111125)) do for _, g in ipairs(r) do if tostring(g[2]):find("^%$ ") then return g[1] end end end')
    eq(col, "oven_minus", "the shop's $ line in red: won't sell to you")
    o.lua('sbo.command("map shops")')
    # the same words from another shopkeeper (the wedding cleric at #10426)
    eq(o.ev("sbo.shopRefusal(\"The wedding cleric tells you 'Sorry, but I cannot sell my wares to someone of your level of experience.'\")") is not None, True, "the cleric too")
    # a player's tell isn't a shop refusal
    eq(o.ev("sbo.shopRefusal(\"Pip tells you 'I won't sell you my sword'\")"), None, "players are one word")


@test
def quiet_reply_once():
    # the reply is picked up at once: its handler runs once, not again as "no reply" later
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; NOTES = {}; send = function(c) sbo.onSend(nil, c) end')
    o.lua('sbo.quietly("shop list", "shop", function(l) NOTES[#NOTES+1] = l and ("reply " .. #l) or "no reply" end)')
    o.feed("There isn't a shopkeeper present.", "<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    eq(list(o.ev("NOTES").values()), ["reply 1"], "once")
    o.lua('NOTES = {}; send = function() end; sbo.quietly("shop list", "shop", function(l) NOTES[#NOTES+1] = l and "reply" or "no reply" end); runTimers()')
    eq(list(o.ev("NOTES").values()), ["no reply"], "and no reply when there is none")


@test
def traveling_sellers():
    o = Oven()
    o.lua('''roomExists = function() return true end; getRoomName = function(id) return "Room " .. id end
      getRoomArea = function() return 1 end; getRoomAreaName = function() return "Towne of Rune" end; getRoomExits = function() return {} end
      local hg = "A slender, older man is here, turning the handle of a hurdy-gurdy."
      for _, r in ipairs({ 10475, 10476, 10477 }) do
        sbo.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last) VALUES (%s, %s, %s, 'Shop', 1, %s)", r, hg:lower(), hg, r)
      end
      sbo.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last) VALUES (10477, 'stumpy', 'A short, stumpy man is here.', 'Boss', 1, 1)")
      sbo.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last) VALUES (10515, 'kasan', 'Kasan the samurai is here.', 'Shop', 1, 1)")
      sbo.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last) VALUES (10515, %s, %s, 'Shop', 1, 1)",
        hg:lower(), hg)''')
    eq(o.ev("sbo.isShopRoom(10476)"), False, "a street he walks through isn't a shop")
    eq(o.ev("sbo.isShopRoom(10515)"), True, "a room with its own shopkeeper still is")
    card = o.lua('local t = {} for _, r in ipairs(sbo.roomCardLines(10476)) do local x = "" for _, g in ipairs(r) do x = x .. tostring(g[2] or "") end t[#t+1] = x end return table.concat(t, "\\n")')
    assert "[Shop] [Traveling] A slender, older man" in card and "seen in 4 rooms" in card, card
    out = o.lua('local out = sbo.shopLines(80, ""); local s = {} for _, r in ipairs(out) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = "\\n" end; return table.concat(s)')
    assert "Traveling sellers" in out and "hurdy-gurdy" in out and "seen in 4 rooms" in out, out
    assert "sbo map highlight hurdy-gurdy" in out, "the command, on its line"
    first = o.lua('local _, links = sbo.shopLines(80, ""); return links[1][1]')
    assert first.startswith("highlight the path of A slender"), first
    eq(o.ev("sbo.isTraveler('kasan the samurai is here.')"), False, "one room: a shopkeeper")
    # light up his path on the map; centred on the latest sighting; cleared again
    o.lua("""LIT = {}; highlightRoom = function(id) LIT[id] = true end; unHighlightRoom = function(id) LIT[id] = nil end
      CENTRE = nil; sbo.centerOn = function(id) CENTRE = id end; sbo.log = function() end""")
    o.lua('sbo.command("map highlight hurdy-gurdy")')
    eq(sorted(o.ev("LIT").keys()), [10475, 10476, 10477, 10515], "every room he's been seen in")
    eq(o.ev("CENTRE"), 10477, "centred on where he was last seen")
    # a highlight that's showing picks up a new match by itself, without moving the map
    o.lua("CENTRE = nil; sbo.command('map highlight hurdy-gurdy')")
    o.lua('''CENTRE = nil
      sbo.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last) VALUES (10600, %s, %s, 'Shop', 1, 1)",
        "a slender, older man is here, turning the handle of a hurdy-gurdy.", "A slender, older man is here, turning the handle of a hurdy-gurdy.")
      sbo.mapLearned(); runTimers()''')
    assert o.ev("LIT[10600]"), "the new room lit up"
    eq(o.ev("CENTRE"), None, "the map didn't move")
    o.lua('sbo.command("map hi")')
    eq(len(o.ev("LIT")), 0, "cleared")
    # many different matches: centred on the nearest to you; "in {area}" narrows it
    o.lua('''sbo.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last) VALUES (900, 'tmpl', 'A Templeton trainer.', 'Trainer', 1, 99999)")
      sbo.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last) VALUES (10560, 'rune', 'A Rune trainer.', 'Trainer', 1, 1)")
      getRoomArea = function(id) return id == 900 and 2 or 1 end
      getRoomAreaName = function(a) return a == 2 and "Templeton" or "Towne of Rune" end
      sbo.mapRoom = 10500
      getPath = function(a, b) speedWalkDir = {} for i = 1, (b == 900 and 300 or 4) do speedWalkDir[i] = "e" end return true end''')
    o.lua('sbo.command("map highlight trainer")')
    eq(sorted(o.ev("LIT").keys()), [900, 10560], "every trainer")
    eq(o.ev("CENTRE"), 10560, "centred on the nearest, not the latest seen")
    o.lua('sbo.command("map highlight trainer in rune")')
    eq(sorted(o.ev("LIT").keys()), [10560], "only Rune's")


@test
def map_search_box():
    o = Oven()
    o.lua("""LIT = {}; highlightRoom = function(id) LIT[id] = true end; unHighlightRoom = function(id) LIT[id] = nil end
      roomExists = function(id) return id and id < 1000 end
      getRoomArea = function(id) return id < 100 and 1 or 2 end
      getRoomAreaName = function(a) return a == 1 and "Towne of Rune" or "Templeton" end
      getRoomName = function(id) return "a bakery" end
      searchRoom = function(q) if q == "bakery" then return { [5] = "a bakery", [6] = "the bakery", [500] = "Templeton bakery" } end return {} end
      centerview = function() end; getPath = function() return false end
      SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
      sbo.cfg.mapPanel = true; sbo.cfg.map = false; sbo.mapRoom = 1""")
    o.lua('sbo.createMapPanel()')
    o.lua('WIDGETS["ovenMapSearch"].action("bakery")')
    eq(sorted(o.ev("LIT").keys()), [5, 6], "the matches in the area on show light up")
    st = o.ev("WIDGETS['ovenMapFindStatus'].text")
    assert "2 here" in st and "3 in all" in st, st
    o.lua('sbo.centerOn(400)')
    eq(sorted(o.ev("LIT").keys()), [500], "another area: its matches")
    o.lua("""sbo.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last) VALUES (450, 'b', 'A baker of bakery goods.', '', 1, 1)")
      sbo.mapLearned(); runTimers()""")
    eq(sorted(o.ev("LIT").keys()), [450, 500], "a new match lights up")
    o.lua('WIDGETS["ovenMapFindClear"].click()')
    eq(len(o.ev("LIT")), 0, "cleared")
    eq(o.ev("WIDGETS['ovenMapFindStatus'].text"), "", "status cleared")


@test
def map_town_by_name():
    # "sbo map vir": the town Vir, not the shop selling "virga pastoris" nor New Kolvir
    o = Oven()
    o.lua("""roomExists = function(id) return id ~= nil end
      getAreaTable = function() return { ["Vir"] = 7, ["New Kolvir"] = 8, ["The Towne of Rune"] = 9 } end
      getAreaExits = function(a) if a == 7 then return { 701, 702 } end if a == 8 then return { 801 } end return {} end
      getAreaRooms = function(a) return { a * 100 } end
      getRoomArea = function(id) return math.floor(id / 100) end
      getRoomAreaName = function(a) return ({ [7] = "Vir", [8] = "New Kolvir", [1] = "Towne of Rune" })[a] or "" end
      getRoomName = function(id) return "room " .. id end
      searchRoom = function() return {} end
      SHOWN = nil; sbo.mapShow = function(id) SHOWN = id end
      getPath = function(a, b) speedWalkDir = {} for i = 1, (b == 702 and 3 or 9) do speedWalkDir[i] = "e" end return true end
      sbo.viewOut = function() end
      SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
      sbo.cfg.map = true; sbo.mapRoom = 150""")
    o.lua("""sbo.dbx("INSERT INTO shops (room, name) VALUES (160, 'herbs')")
      sbo.dbx("INSERT INTO shop_items (room, no, item, cost) VALUES (160, 1, 'A sprig of virga pastoris', 5)")""")
    ids = o.lua("local t = sbo.runTargets('Vir') local o = {} for _, x in ipairs(t) do if x.rank == 0.6 then o[#o+1] = x.id end end table.sort(o) return table.concat(o, ',')")
    eq(ids, "701,702", "Vir's ways in, not New Kolvir's")
    eq(o.ev("sbo.areasNamed('rune')[1].name"), "The Towne of Rune", "'Towne of' is skipped")
    o.lua('sbo.command("map Vir")')
    eq(o.ev("SHOWN"), 701, "sbo map vir shows the town")
    o.lua('SAYS = {}; sbo.command("map on")')
    assert any("following you" in x for x in o.ev("SAYS").values()), "sbo map on still works"
    o.lua('sbo.mapRoom = 150; sbo.goTo = function(id) GONE = id end; sbo.command("go vir")')
    eq(o.ev("GONE"), 702, "sbo go vir: the nearest way in")


@test
def scan_marks():
    o = Oven()
    o.lua("""SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
      SEL = {}; selectString = function(s) SEL[#SEL+1] = s; return 0 end
      BG = nil; setBgColor = function(r, g, b) BG = r .. "," .. g .. "," .. b end""")
    o.lua('sbo.command("scan mark centipede"); sbo.command("sc mark Wavering Shadow")')
    eq(list(o.ev("sbo.cfg.scanMarks").values()), ["centipede", "Wavering Shadow"], "kept")
    o.feed("A burrowing centipede is close by to the east.", "An undead corpse is right here to the west.",
           "A wavering shadow is a brief walk away to the west.", "You don't see anything to the north.")
    eq(list(o.ev("SEL").values()), ["A burrowing centipede", "A wavering shadow"], "marked names light up, others don't")
    eq(o.ev("BG"), "110,20,20", "on a dark red")
    o.lua('sbo.command("scan unmark centipede")')
    eq(list(o.ev("sbo.cfg.scanMarks").values()), ["Wavering Shadow"], "unmarked")
    o.lua('SAYS = {}; sbo.command("scan list")')
    assert "Wavering Shadow" in o.ev("SAYS[1]"), "sbo scan list"
    eq(o.ev("(sbo.scanParse('A priestess is not far off to the south.'))"), "A priestess", "a scan line")
    eq(o.ev("(sbo.scanParse('You say the priest is fine.'))"), None, "not a scan line")
    o.lua('SAYS = {}; sbo.command("st")')
    assert "nothing to stop" in o.ev("SAYS[1]"), "sbo st is still stop"


@test
def eq_stat_totals():
    o = Oven()
    o.lua("""sbo.cfg.eqStats = true
      sbo.items["a silver ring"] = { ar = 2, affects = { { "strength", 2 }, { "hit-roll", 1 } }, weight = { "0", "40" } }
      sbo.items["a cloak"] = { ar = 5, affects = { { "strength", 1 }, { "dexterity", -1 }, { "fire-damage", 2 } }, weight = { "1", "75" } }""")
    def eqtext(*lines):
        o.L.globals().EQL = o.L.table_from(list(lines))
        return o.lua("""local raw = {} for _, l in ipairs(EQL) do raw[#raw+1] = l end
          local rows = sbo.formatters.eq(raw, 90)
          local s = {} for _, r in ipairs(rows) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = "\\n" end
          return table.concat(s)""")
    out = eqtext("You are using:", "<worn on finger>      a silver ring (new)..it glows blue!",
        "<worn about body>    a cloak (badly worn)", "<held>               a torch", "",
        "(Torso   )  20  (Reduces damage taken by 15.000%)", "(Arms    )  19  (Reduces damage taken by 14.250%)")
    lines = out.split("\n")
    # the headings once at the top: a column per stat the gear has
    head = next(l for l in lines if "other" in l)
    assert lines.index(head) < next(i for i, l in enumerate(lines) if l.startswith("── ")), out
    assert "AR" in head and " sr" in head and " kn" not in head, head
    # the parts of the body follow the armour locations, their AR and damage cut in the header
    assert any(l.startswith("── torso") and "AR 20" in l and "15.00%" in l for l in lines), out
    assert any(l.startswith("── arms") and "AR 19" in l for l in lines), out
    ring = next(l for l in lines if "silver ring" in l)
    assert ring.split()[-3:] == ["2", "2", "(1)"], f"AR 2, str 2, one other (hit-roll): {ring}"
    cloak = next(l for l in lines if "a cloak" in l)
    assert cloak.split()[-3:] == ["5", "1", "(2)"], cloak
    assert "(badly worn)" in out and "glows" not in out, out
    assert "?" in next(l for l in lines if "a torch" in l), "never looked at"
    tot = next(l for l in lines if l.startswith("total"))
    assert "2 st 15 pb (from 2 of 3)" in tot and tot.split()[-3:] == ["7", "3", "(3)"], f"AR 7, str 3, three others: {tot}"
    assert "Armor " not in out, "no AR table at the bottom: it's in the headers"
    # the column off (sbo config eq.stats off): no table, the weight still there
    o.lua("sbo.command('config eq.stats off')")
    out = eqtext("You are using:", "<worn on finger>      a silver ring", "<worn about body>    a cloak")
    assert not any("AR" in l and l.rstrip().endswith("other") for l in out.split("\n")) and "2 st 15 pb" in out, out


WHERE_LIST = """Where is what? Features that Towne of Rune might contain that you may be interested in:
healer              post-office         lockers             bank                
food                blacksmith          questmaster         music-venue         
When you do find what you're looking for, you might also try WHERE IS <feature> TRACK to track towards your destination automatically."""


@test
def go_tab_completion():
    o = Oven()
    o.lua("""
      SUGG = {}
      addCmdLineSuggestion = function(w) SUGG[w] = true end
      removeCmdLineSuggestion = function(w) SUGG[w] = nil end
      sbo.say = function() end
    """)
    o.lua("""
      for _, f in ipairs({ "food", "post-office" }) do
        sbo.dbx("INSERT OR IGNORE INTO where_features (area, feature) VALUES (%s, %s)", "Towne of Rune", f)
      end
      sbo.dbx("INSERT OR REPLACE INTO marks (name, room, t) VALUES (%s, %s, %s)", "home", 7, 1)
      sbo.dbx("INSERT OR REPLACE INTO marks (name, room, t) VALUES (%s, %s, %s)", "my house", 8, 1)
      sbo.cfg.friends = { "roarke" }
      sbo.goSuggestRefresh()
    """)
    have = sorted(k for k in o.ev("SUGG").keys())
    for w in ("food", "post-office", "home", "roarke"):
        assert w in have, (w, have)
    assert "my house" not in have and "my" not in have, have   # Tab completes one word: multi-word names left out
    # a bookmark removed and a friend dropped: their suggestions go; the rest stay
    o.lua('sbo.unmarkRoom("home"); sbo.friendRemove("roarke"); runTimers()')
    have = sorted(k for k in o.ev("SUGG").keys())
    assert "home" not in have and "roarke" not in have and "food" in have, have
    # Oven's teardown takes only its own suggestions away
    o.lua('addCmdLineSuggestion("someone-elses"); sbo.goSuggestClear()')
    eq(sorted(k for k in o.ev("SUGG").keys()), ["someone-elses"], "teardown leaves other packages' suggestions")


@test
def where_is():
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end')
    o.set_gmcp("char.status", '{ state = "playing" }')
    o.L.globals().WL = o.L.table_from(WHERE_LIST.split("\n"))
    o.lua("""
      -- a street: 1 -s-> 2 -s-> 3 -w-> 4 -w-> 5 (the food)
      EX = { [1] = { south = 2 }, [2] = { north = 1, south = 3 }, [3] = { north = 2, west = 4 }, [4] = { east = 3, west = 5 }, [5] = { east = 4 } }
      roomExists = function(id) return EX[tonumber(id)] ~= nil end
      getRoomExits = function(id) return EX[tonumber(id)] end
      getRoomName = function(id) return "Room " .. id end
      getRoomArea = function() return 1 end; getRoomAreaName = function() return "Towne of Rune" end
      centerview = function() end; highlightRoom = function() end; unHighlightRoom = function() end
      getPath = function(a, b) speedWalkDir, speedWalkPath = { "s" }, { tostring(b) } return true end
      sbo.cfg.map = true
      function AT(id) gmcp.room = { info = { num = tostring(id), zone = "Towne of Rune" } }; sbo.onRoom() end
      SENT = {}
      REPLY = { ["where is"] = WL, ["where is food"] = { "You sense that food may be located s, s, w, w." },
                ["where is bank"] = { "You sense that bank may be located s, s, w, w, w, w, w, w, w, w, w, s." },
                ["where is questmaster"] = { "You sense that questmaster may be located n, n." } }
      send = function(c)
        SENT[#SENT + 1] = c
        sbo.onSend(nil, c)
        for _, l in ipairs(REPLY[c] or { "Huh?" }) do line = l; sbo.onLine() end
        line = "<281hp 696sp 457st>"; sbo.onLine()
      end
      AT(1)
    """)
    o.feed("<281hp 696sp 457st>")
    # you type it: the area's features, and where food is (worked out on the map)
    o.lua('send("where is"); send("where is food")')
    eq(sorted(r["feature"] for r in o.rows("SELECT feature FROM where_features WHERE area = 'Towne of Rune'")),
       ["bank", "blacksmith", "food", "healer", "lockers", "music-venue", "post-office", "questmaster"], "the features")
    eq(o.rows("SELECT room, start, dirs FROM where_rooms WHERE feature = 'food'"), [{"room": 5, "start": 1, "dirs": "s, s, w, w"}], "food: room 5")
    # directions off the map: kept, no room
    o.lua('send("where is bank")')
    eq([r.get("room") for r in o.rows("SELECT room, dirs FROM where_rooms WHERE feature = 'bank'")], [None], "off the map: no room, directions kept")
    # sbo go food: from anywhere, the room it learned
    o.lua("WALKED = nil; sbo.mapWalkTo = function(id) WALKED = id end; AT(3); SENT = {}")
    o.lua('sbo.command("go food")')
    eq(o.ev("WALKED"), 5, "sbo go food")
    # something Oven hasn't found yet but the area has: it asks the game
    o.lua('SENT = {}; sbo.command("go questmaster")')
    assert "where is questmaster" in list(o.ev("SENT").values()), list(o.ev("SENT").values())
    # learning by itself while you're idle: one feature at a time
    o.lua("runTimers(); sbo.whereAsked = {}; SENT = {}; sbo.lastUserCmdAt = nil; sbo.whereLearnTick()")
    sent = list(o.ev("SENT").values())
    eq(len(sent), 1, f"one question: {sent}")
    assert sent[0].startswith("where is ") and sent[0] not in ("where is food",), sent
    o.lua("SENT = {}; sbo.cfg.whereLearn = false; sbo.whereLearnTick()")
    eq(len(o.ev("SENT")), 0, "switched off")
    # typing: no learning
    o.lua("sbo.cfg.whereLearn = true; SENT = {}; sbo.onSend(nil, 'look'); sbo.whereLearnTick()")
    eq(len([c for c in o.ev("SENT").values() if c.startswith("where")]), 0, "not while you're typing")
    # where is (players) isn't read as a feature question
    eq(o.ev("sbo.classify('where')"), None, "plain where")
    card = o.lua('getRoomExits = function() return {} end; local t = {} for _, r in ipairs(sbo.roomCardLines(5)) do for _, g in ipairs(r) do t[#t+1] = tostring(g[2] or "") end end return table.concat(t)')
    assert "where is food" in card, card


@test
def loot_that_binds():
    o = Oven()
    f = lambda l: o.ev(f'(function() local e = sbo.parseLoot([[{l}]]) return e and (e.who .. "|" .. e.item) or "nil" end)()')
    eq(f("A bottle of pesto emits a bright flare of white light as you take it and it binds with you."), "you|a bottle of pesto", "a binding pickup")
    eq(f("A pair of boots glows softly as you take it."), "you|a pair of boots", "a name with an -s word")
    eq(f("A bottle of pesto: you can't carry so much weight."), "nil", "not picked up")
    eq(f("You get a sword."), "you|a sword", "as before")


@test
def notes_tab():
    o = Oven()
    o.lua('''sbo.cfg.window = true; sbo.cfg.tabs = true; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
      roomExists = function() return true end; getRoomName = function(id) return "Palace Kitchen and Bakery" end
      gmcp.room = { info = { num = "28840", zone = "Palace of Diocletian" } }; sbo.mapRoom = 28840
      WALKED = nil; sbo.mapWalkTo = function(id) WALKED = id end
      OPENED = nil; openUrl = function(u) OPENED = u end
      BOXTEXT = ''
      printCmdLine = function(n, t) BOXTEXT = t end; appendCmdLine = function(n, t) BOXTEXT = BOXTEXT .. t end
      getCmdLine = function() return BOXTEXT end; clearCmdLine = function() BOXTEXT = '' end
      -- (like Mudlet: Enter hands the box's text over once a line)
      function ENTER() for l in (BOXTEXT .. '\\n'):gmatch('(.-)\\n') do WIDGETS['ovenNotesInput'].action(l) end runTimers() end
      function TYPE(t) BOXTEXT = BOXTEXT .. t end''')
    # notes kept before 1.49 (in the database): copied into the file the first time
    o.lua('''sbo.dbx("INSERT INTO notes (t, text, room, room_name, area) VALUES (%s, %s, %s, %s, %s)", os.time(), "an old note", 28840, "Palace Kitchen and Bakery", "Palace of Diocletian")''')
    o.lua('sbo.command("notes")')
    eq(o.ev("WIDGETS['ovenTabs3Page_notes'].shown"), True, "sbo notes: the Notes tab")
    f = o.home + "/oven_notes.md"
    text = open(f).read()
    assert "an old note" in text and "Palace Kitchen and Bakery · Palace of Diocletian #28840" in text, text
    # typing straight into the box: Enter adds lines, nothing's saved until Save
    o.lua("TYPE('cook gives pesto'); ENTER(); TYPE('for 250 gold'); ENTER()")
    assert "pesto" not in open(f).read(), "Enter never saves"
    eq(o.ev("BOXTEXT"), "cook gives pesto\nfor 250 gold\n", "the lines in the box")
    eq((o.ev("WIDGETS['ovenNotesSave'].shown"), o.ev("WIDGETS['ovenNotesCancel'].shown")), (True, True), "Save, Cancel: with text in the box")
    o.lua("WIDGETS['ovenNotesSave'].click()")
    text = open(f).read()
    assert text.rstrip().endswith("#28840\ncook gives pesto\nfor 250 gold"), text
    eq((o.ev("sbo.noteEdit"), o.ev("BOXTEXT")), (None, ""), "saved, the box empty")
    eq((o.ev("WIDGETS['ovenNotesSave'].shown"), o.ev("WIDGETS['ovenNotesCancel'].shown")), (False, False), "nothing to save: no buttons")
    # written straight into the file: several lines - the tab follows the file
    open(f, "a").write("\n## 2026-11-16 02:00 · the abbot\nwolf kills me in 2 rounds\ntreant guards the lemon tree\n")
    o.lua("sbo.notesTimer = nil; sbo.notesWatch(); runTimers()")   # (the test's timers don't repeat)
    shown = o.ev("WIDGETS['ovenNotesConsole'].text")
    assert "wolf kills me in 2 rounds\ntreant guards the lemon tree" in shown, shown
    links = o.ev("WIDGETS['ovenNotesConsole'].links")
    [l for l in links.values() if "[go]" in l[1]][0][2]()
    eq(o.ev("WALKED"), 28840, "[go] walks to where it was written")
    # [edit]: the note in the box; another line; Save puts it back in its place
    [l for l in links.values() if "[edit]" in l[1]][-1][2]()
    eq(o.ev("BOXTEXT"), "wolf kills me in 2 rounds\ntreant guards the lemon tree", "the note in the box")
    assert "editing note #3" in (o.ev("WIDGETS['ovenNotesStatus'].text") or "")
    o.lua("ENTER(); TYPE('ask the abbot'); WIDGETS['ovenNotesSave'].click()")
    text = open(f).read()
    assert "the abbot\nwolf kills me in 2 rounds\ntreant guards the lemon tree\nask the abbot" in text, text
    eq(text.count("ask the abbot"), 1, "saved once")
    # Cancel: left as it was; the commands too
    o.lua("sbo.noteEditStart(1); TYPE(' changed'); WIDGETS['ovenNotesCancel'].click()")
    assert "changed" not in open(f).read(), "Cancel: left as it was"
    o.lua("TYPE('from the command'); sbo.command('notes save')")
    assert "from the command" in open(f).read()
    o.lua("TYPE('not this'); sbo.command('notes cancel')")
    assert "not this" not in open(f).read()
    # a Mudlet whose box can't be refilled: the box empties on Enter - the lines are kept, shown above, saved
    o.lua("""sbo.noteBoxWorks = nil; printCmdLine = function() end
      TYPE('first line'); ENTER(); BOXTEXT = ''; TYPE('second line'); ENTER(); BOXTEXT = ''""")
    shown = o.ev("WIDGETS['ovenNotesConsole'].text")
    assert "writing a new note" in shown and "first line\nsecond line" in shown, shown
    o.lua("TYPE('third'); WIDGETS['ovenNotesSave'].click()")
    assert open(f).read().rstrip().endswith("first line\nsecond line\nthird"), open(f).read()
    o.lua("sbo.noteBoxWorks = nil; printCmdLine = function(n, t) BOXTEXT = t end")
    o.lua('sbo.command("notes find pesto")')
    shown = o.ev("WIDGETS['ovenNotesConsole'].text")
    assert "pesto" in shown and "treant" not in shown, shown
    o.lua('sbo.command("notes remove 1")')
    text = open(f).read()
    assert "an old note" not in text and "pesto" in text and "treant" in text, text


@test
def tab_dragged_out():
    o = Oven()
    o.lua('''sbo.cfg.window = true; sbo.cfg.tabs = true; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end''')
    o.lua('sbo.command("log")')
    eq(o.ev("WIDGETS['ovenViewer'].titleText"), "⠿⠿ Oven", "the window isn't called Inspector too (the grip like the quest panel's)")
    # a click is just a click
    o.lua('MOUSE = {950, 50}; WIDGETS["ovenTabs3_log"].click(); MOUSE = {955, 52}; sbo.tabRelease("log")')
    eq(o.ev("sbo.tabIsOut('log')"), False, "clicked, not dragged")
    # dragged and let go inside the window: still a tab
    o.lua('MOUSE = {950, 50}; WIDGETS["ovenTabs3_log"].click(); MOUSE = {1100, 200}; sbo.tabRelease("log")')
    eq(o.ev("sbo.tabIsOut('log')"), False, "dropped inside the window")
    # dragged out
    o.lua('MOUSE = {950, 50}; WIDGETS["ovenTabs3_log"].click(); MOUSE = {300, 300}; sbo.tabRelease("log")')
    eq(o.ev("sbo.tabIsOut('log')"), True, "dropped outside: its own window")
    eq(o.ev("WIDGETS['ovenTab_log'].titleText"), "⠿⠿ Log", "titled by its tab")
    eq(o.ev("WIDGETS['ovenTab_log'].x0"), 260, "where it was dropped")
    eq(o.ev("WIDGETS['ovenTabs3_log'].shown"), False, "its tab leaves the bar")
    eq(o.ev("sbo.tabOn"), "view", "the Oven window shows another tab")
    eq(o.ev("sbo.cfg.tabsOut.log"), True, "remembered")
    # the window follows the mouse while the tab is dragged; Mudlet may not say when it's let go
    o.lua('WIDGETS["ovenTab_log"].items["dock into the Oven window"]()')
    o.lua('MOUSE = {950, 50}; WIDGETS["ovenTabs3_log"].click(); MOUSE = {960, 60}; sbo.tabDragMove("log")')
    eq(o.ev("sbo.tabIsOut('log')"), False, "a small move: still a tab")
    o.lua('MOUSE = {700, 100}; sbo.tabDragMove("log")')
    eq(o.ev("sbo.tabIsOut('log')"), True, "past the window's edge: torn off")
    eq(o.ev("WIDGETS['ovenTabs3_log'].shown"), True, "its tab stays while still held")
    o.lua('MOUSE = {400, 500}; sbo.tabDragMove("log")')
    eq(o.ev("WIDGETS['ovenTab_log'].x0"), 360, "follows the mouse")
    o.lua('runTimers()')
    eq(o.ev("WIDGETS['ovenTabs3_log'].shown"), False, "stopped moving: its tab leaves the bar")
    eq(o.ev("sbo.tabDrag"), None, "drag over")
    # its window dragged back onto the tabs: a tab again (the tab bar sits at the top of the window)
    o.lua('WIDGETS["ovenTabs3Bar"].get_x = function() return 900 end; WIDGETS["ovenTabs3Bar"].get_y = function() return 60 end')
    o.lua('WIDGETS["ovenTabs3Bar"].get_width = function() return 500 end; WIDGETS["ovenTabs3Bar"].get_height = function() return 24 end')
    o.lua('MOUSE = {600, 400}; handlers["AdjustableContainerRepositionFinish"]("AdjustableContainerRepositionFinish", "ovenTab_log", 500, 400)')
    eq(o.ev("sbo.tabIsOut('log')"), True, "let go elsewhere: stays a window")
    o.lua('MOUSE = {1000, 70}; handlers["AdjustableContainerRepositionFinish"]("AdjustableContainerRepositionFinish", "ovenTab_log", 520, 400)')
    eq(o.ev("sbo.tabIsOut('log')"), True, "resized, not moved: stays a window")
    o.lua('MOUSE = {1000, 70}; handlers["AdjustableContainerRepositionFinish"]("AdjustableContainerRepositionFinish", "ovenTab_log", 520, 400)')
    eq(o.ev("sbo.tabIsOut('log')"), False, "dropped on the tabs: a tab again")
    eq(o.ev("WIDGETS['ovenTabs3_log'].shown"), True, "its tab is back")
    o.lua('sbo.tabUndock("log", 300, 300); sbo.tabDragEnd("log")')
    # new content for it shows its window, and leaves the Oven window's tab alone
    o.lua('WIDGETS["ovenTab_log"]:hide(); sbo.command("log session")')
    eq(o.ev("WIDGETS['ovenTab_log'].shown"), True, "its window comes back for new content")
    eq(o.ev("sbo.tabOn"), "view", "...not the Oven window's tab")
    eq(o.ev("WIDGETS['ovenTabs3Page_view'].shown"), True, "the Inspector still in front")
    # docked back from its right-click menu
    o.lua('WIDGETS["ovenTab_log"].items["dock into the Oven window"]()')
    eq(o.ev("sbo.tabIsOut('log')"), False, "back in the Oven window")
    eq(o.ev("WIDGETS['ovenTabs3_log'].shown"), True, "its tab is back")
    eq(o.ev("WIDGETS['ovenTab_log'].shown"), False, "its window gone")
    eq(o.ev("sbo.cfg.tabsOut.log"), None, "forgotten")
    # and by command
    o.lua('sbo.command("window undock notes")')
    eq(o.ev("sbo.tabIsOut('notes')"), True, "sbo window undock notes")
    o.lua('sbo.command("window dock notes")')
    eq(o.ev("sbo.tabIsOut('notes')"), False, "sbo window dock notes")
    # an update mid-session keeps the tab labels: they're wired to the new code again
    o.lua('WIDGETS["ovenTabs3_help"].click = function() end; sbo.createWindow()')
    o.lua('MOUSE = {950, 50}; WIDGETS["ovenTabs3_help"].click(); MOUSE = {300, 300}; sbo.tabRelease("help")')
    eq(o.ev("sbo.tabIsOut('help')"), True, "old labels drag too")
    o.lua('sbo.runTimers = nil'); o.lua('runTimers()')


@test
def item_sets():
    o = Oven()
    lines = ["You focus your powers of observation on a city guard signet ring:",
             "Item 'a city guard signet ring' is type jewelry, alignment 0, made of iron (in (new) condition),",
             "has keywords 'city guard cityguard id ring signet', equipped on the finger.",
             "This item weighs 0 stones and 2 pebbles, and is valued at 2,250 gold. {Cat. 2}",
             "This level 20 item has no special attributes.",
             "Affects saving-spell by 1.", "Affects personality by 2.",
             "*This item may be repaired 3 times.",
             "This is part of the 'Runic Cityguard's Full Regalia' set.",
             "You are currently wearing 1 of 13 items from the set.",
             "- Item 'a standard issue sword'", "* Item 'a city guard signet ring'", "- Item 'a war banner'",
             "Affects knowledge by 1 (Requires 10 items).",
             "When wielding a sword, increases damage by 10% (Requires 10 items).",
             "Forged from iron, this ring is the only true piece of equipment."]
    o.L.globals().R = o.L.table_from(lines)
    it = o.lua("local raw = {} for _, l in ipairs(R) do raw[#raw+1] = l end return sbo.parseItem(raw)")
    eq(it.set.name, "Runic Cityguard's Full Regalia", "the set")
    eq((it.set.worn, it.set.total), ("1", "13"), "wearing 1 of 13")
    eq([(p.name, p.worn) for p in it.set.pieces.values()],
       [("a standard issue sword", False), ("a city guard signet ring", True), ("a war banner", False)], "the pieces")
    eq([b.text for b in it.set.bonus.values()], ["+1 knowledge", "sword damage +10%"], "the bonuses")
    eq([a[1] for a in it.affects.values()], ["saving-spell", "personality"], "set bonuses aren't the item's own stats")
    assert not any("Item '" in n for n in it.notes.values()), list(it.notes.values())


@test
def item_search():
    o = Oven()
    o.lua("""sbo.cfg.window = false; OUT = {}
      sbo.viewOut = function(lines, links) local t = {} for _, r in ipairs(lines) do for _, g in ipairs(r) do t[#t+1] = tostring(g[2] or "") end t[#t+1] = "\\n" end OUT = { table.concat(t), links } end
      roomExists = function() return true end; getRoomName = function(id) return "Room " .. id end
      getRoomArea = function() return 1 end; getRoomAreaName = function() return "Towne of Rune" end
      getPath = function(a, b) speedWalkDir = {} for i = 1, (b == 10468 and 4 or 40) do speedWalkDir[i] = "e" end return true end
      sbo.mapRoom = 10500
      sbo.cfg.carried = { inv = { "a cute little pixie bag" }, bags = { ["a cute little pixie bag"] = { "a hunk of cheese" } }, at = 1 }
      sbo.remember({ name = "a hunk of cheese", type = "food", level = 1, affects = {}, raw = {} })
      sbo.dbx("INSERT INTO shops (room, name, last) VALUES (10468, 'local general store', 1)")
      sbo.dbx("INSERT INTO shop_items (room, no, item, level, amount, cost, last, currency) VALUES (10468, 1, 'A hunk of cheese', 1, 'No limit', 25, 1, 'gold')")
      sbo.dbx("INSERT INTO shops (room, name, last) VALUES (900, 'a far store', 1)")
      sbo.dbx("INSERT INTO shop_items (room, no, item, level, amount, cost, last, currency) VALUES (900, 1, 'A hunk of cheese', 1, 'No limit', 20, 1, 'gold')")
      sbo.dbx("INSERT INTO loot (t, who, item, src, n, room) VALUES (1, 'you', 'a hunk of cheese', 'a rat', 1, 10600)")
      sbo.quests = { ["2682"] = { name = "Cheese and Wine", phases = { { n = 3, text = "Recover and Keep a hunk of cheese", done = true } } } }""")
    o.lua('sbo.command("it cheese")')
    text = o.ev("OUT[1]")
    for want in ("You have", "in a cute little pixie bag", "Known", "Sold at", "local general store", "25 gold",
                 "Picked up", "from a rat", "Quests", "Cheese and Wine"):
        assert want in text, (want, text)
    assert text.index("local general store") < text.index("a far store"), "nearest shop first"
    links = [l[1] for l in o.ev("OUT[2]").values()]
    assert any(l.startswith("go to local general store") for l in links), links
    # short forms: i is still the Inspector, it is item
    eq(o.ev("sbo.cmdPick(sbo.CMDS, 'i').name"), "inspector", "i stays inspector")
    eq(o.ev("sbo.cmdPick(sbo.CMDS, 'it').name"), "item", "it is item")
    # sbo go cheese: the nearest shop that sells it
    o.lua("WALKED = nil; sbo.mapWalkTo = function(id) WALKED = id end; sbo.cfg.map = true; sbo.log = function() end")
    o.lua('sbo.command("go cheese")')
    eq(o.ev("WALKED"), 10468, "sbo go cheese")


@test
def help_ends_at_see_also():
    # help look during the game's auto-run: the next step arrived before any prompt
    lines = open(fixture("help_then_autorun.txt"), encoding="utf-8").read().rstrip("\n").split("\n")
    o = Oven()
    o.lua('''sbo.cfg.window = true; sbo.cfg.promptPattern = "<%d+hp"; GAGGED = {}
      deleteLine = function() GAGGED[#GAGGED + 1] = line end''')
    o.lua('sbo.onSend(nil, "help look")')
    o.feed(*lines)
    o.feed("<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    gagged = list(o.ev("GAGGED").values())
    assert not any("Great North Road" in g or "You travel" in g or "runs in" in g for g in gagged), \
        f"the auto-run step was taken off the main screen: {[g for g in gagged if 'Road' in g or 'travel' in g]}"
    assert any("[1132] description" in g for g in gagged), "the help page itself went to the Help tab"
    page = o.ev("WIDGETS[sbo.helpPg.prefix .. sbo.helpPg.flip .. 'Label'].html") or ""
    assert "Great North Road" not in page and "LOOK" in page, "the Help tab has only the help page"


@test
def upgrades_from_what_you_carry():
    o = Oven()
    o.lua('''
      -- (accuracy: something the model calculates - help 1747)
      sbo.noteCombat({ "57 Damage: (+46 from weapon)", "55 Accuracy: (+16 from weapon)", "31% Critical Hit chance:" })
      sbo.cfg.maxes = { hp = 365, sp = 875 }; sbo.cfg.arLoc = { torso = 10 }
      local function it(n, ar, str) return { name = n, worn = "on body", level = 1, affects = { { "accuracy", tostring(str) } }, ar = ar, raw = {} } end
      sbo.remember(it("a worn vest", 1, 1))
      sbo.remember(it("a shop breastplate", 1, 9))     -- looked at in a shop
      sbo.remember(it("a bagged hauberk", 1, 5))       -- in your backpack
      sbo.remember(it("a dropped tunic", 1, 7))        -- in a bag you no longer have
      sbo.eqNames = { "a worn vest" }
      function UP(all) local t = {} for _, r in ipairs(sbo.upgradeLines(100, all)) do local x = {} for _, seg in ipairs(r) do x[#x+1] = seg[2] end t[#t+1] = table.concat(x) end return table.concat(t, "\\n") end''')
    eq("type i" in o.ev("UP(false)"), True, "before any inventory: asks for one")
    def contents(cmd, lines):
        o.lua(f'sbo.onSend(nil, "{cmd}")')
        o.lua("sbo.cap.plain = {" + ",".join(repr(l).replace("\\'", "'") for l in lines) + "}; sbo.cap.decho = sbo.cap.plain; sbo.finish('prompt'); runTimers()")
    contents("i", [" You are carrying:", "     a leather backpack (new)", "A total of 1 items weighing 1 stones, 0 pebbles (0pb gold weight)"])
    contents("l in backpack", ["A leather backpack contains:", "     a bagged hauberk (new)", "A total of 1 (30 max) items weighing 0 st, 5 pbs (5 sts, 0 pbs max)."])
    contents("l in pouch", ["A small pouch contains:", "     a dropped tunic (new)", "A total of 1 (30 max) items weighing 0 st, 5 pbs (5 sts, 0 pbs max)."])
    mine = o.ev("UP(false)")
    assert "a bagged hauberk" in mine and "in a leather backpack" in mine, mine
    assert "a shop breastplate" not in mine and "a dropped tunic" not in mine, f"only what you carry: {mine}"
    every = o.ev("UP(true)")
    assert "a shop breastplate" in every, f"sbo upgrades all: the best of everything seen: {every}"
    # the command: in the Inspector and (sbo mirror inspector on, the default) on the main screen
    o.lua('''sbo.cfg.window = true; MAIN = {}
      echo = function(w, t) if t == nil then t = w; w = "main" end if w == "main" then MAIN[#MAIN+1] = t end end
      sbo.command("upgrades")''')
    assert "a bagged hauberk" in "".join(o.ev("MAIN").values()), "sbo upgrades on the main screen"
    assert "a bagged hauberk" in o.ev("WIDGETS[sbo.viewPg.prefix .. sbo.viewPg.flip .. 'Label'].html"), "...and in the Inspector"
    o.lua('sbo.command("mirror inspector off"); MAIN = {}; sbo.command("upgrades")')
    assert "a bagged hauberk" not in "".join(o.ev("MAIN").values()), "mirror inspector off: only in the Inspector"
    assert "+4 accuracy" in mine and "hit 55→57.7%" in mine, f"why: the stats, and what they change: {mine}"
    eq(o.ev("#sbo.viewHist[#sbo.viewHist].links") >= 1, True, "a link per upgrade")
    o.lua('sbo.command("upgrades compare 1")')
    page = o.ev("WIDGETS[sbo.viewPg.prefix .. sbo.viewPg.flip .. 'Label'].html")
    assert "wearing B instead of A" in page and "a bagged hauberk" in page, "sbo upgrades compare 1: the full comparison"
    o.lua('sbo.viewHist[#sbo.viewHist - 1].links[1][2]()')   # the link on the list does the same
    assert "wearing B instead of A" in o.ev("WIDGETS[sbo.viewPg.prefix .. sbo.viewPg.flip .. 'Label'].html")


@test
def compare_score_breakdown():
    # no gear score: what the swap changes, by category, in the game's numbers
    o = Oven()
    o.lua('''
      sbo.noteCombat({ "57 Damage: (+46 from weapon)", "55 Accuracy: (+16 from weapon)", "31% Critical Hit chance:" })
      sbo.cfg.maxes = { hp = 365, sp = 875 }; sbo.cfg.arLoc = { torso = 10, legs = 10 }; sbo.cfg.arRate = 0.75
      local function it(n, aff) return { name = n, worn = "on body", level = 1, affects = aff, raw = {} } end
      A = it("a vest", { { "accuracy", "1" }, { "hp", "20" } })
      B = it("a hauberk", { { "accuracy", "4" } })
      local t = {} for _, r in ipairs(sbo.compareLines(A, B, 90)) do local x = {} for _, seg in ipairs(r) do x[#x+1] = seg[2] end t[#t+1] = table.concat(x) end
      TEXT = table.concat(t, "\\n")''')
    text = o.ev("TEXT")
    assert "wearing B instead of A" in text and "Score" not in text and "score" not in text, text
    off = next(l for l in text.split("\n") if l.strip().startswith("Offense"))
    assert "hit 55→57%" in off and "per round" in off, off
    de = next(l for l in text.split("\n") if l.strip().startswith("Defense"))
    assert "hp 365→345" in de, de


@test
def quest_request_pins():
    reply = open(fixture("quest_request.txt"), encoding="utf-8").read().rstrip("\n").split("\n")
    for cmd, setting, want in (("quest request", "on", True), ("que req", "on", True), ("que re", "on", True), ("quest request", "off", None), ("quest info 1547", "on", None),
                               ("quest undertake 1547", "on", True)):
        o = Oven()
        o.lua(f'sbo.cfg.promptPattern = "<%d+hp"; sbo.command("quest autopin {setting}"); sbo.onSend(nil, "{cmd}")')
        o.feed(*reply, "<270hp 550sp 401st>")
        o.L.execute("runTimers()")
        eq(o.ev("(sbo.cfg.questPins or {})['1547']"), want, f"{cmd} with autopin {setting}")
        eq(o.ev("sbo.quests['1547'] and sbo.quests['1547'].name"), "War and Peace", "the quest is read either way")


@test
def quest_login_daily_pins():
    # the daily quest handed out at login: no command typed
    lines = open(fixture("quest_login_daily.txt"), encoding="utf-8").read().rstrip("\n").split("\n")
    for setting, want in (("on", True), ("off", None)):
        o = Oven()
        o.lua(f'sbo.cfg.promptPattern = "<%d+hp"; sbo.command("quest autopin {setting}")')
        o.feed(*lines)
        o.feed("<281hp 696sp 457st>")
        o.L.execute("runTimers()")
        eq(o.ev("(sbo.cfg.questPins or {})['3519']"), want, f"pinned with autopin {setting}")
        eq(o.ev("sbo.quests['3519'] and sbo.quests['3519'].name"), "Daily Quest - Feeding Hungry Mouths", "read")
        eq(o.ev("sbo.quests['3519'].total"), 1, "its one phase")
        ph = o.ev("sbo.quests['3519'].phases[1]")
        eq((ph.text, ph.area), ("Locate and deliver sprutter spritz [Cooking Adventurers] to a bag lady", "Towne of Rune"),
           "the area is the last bracket; the item's bracket stays in the text")
    # [Group] is a tag, not an area; and steps saved wrong by 0.52.0 are read again
    p = o.ev('sbo.phaseFromText("*Defeat 5/5 of a lost demon [Rune Forest] [Group].")')
    eq((p.text, p.area, list(p.tags.values()), p.done), ("Defeat 5/5 of a lost demon", "Rune Forest", ["Group"], True), "tags")
    o.lua('''sbo.quests["9"] = { name = "x", phases = { { n = 1, text = "Defeat 5/5 of a lost demon", area = "Rune Forest] [Group" } } }
      sbo.fixQuestPhases()''')
    eq((o.ev('sbo.quests["9"].phases[1].area'), o.ev('sbo.phaseLabel(sbo.quests["9"].phases[1])')),
       ("Rune Forest", "1. Defeat 5/5 of a lost demon · Rune Forest · Group"), "fixed on load")


@test
def quest_given_by_another_command():
    # "use card spaghetti and pesto" hands you a new quest, its details in full
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; SENT = {}; send = function(c) SENT[#SENT+1] = c; sbo.onSend(nil, c) end')
    o.set_gmcp("char.status", '{ state = "playing" }')
    o.feed("<281hp 696sp 457st>")
    o.lua('sbo.onSend(nil, "use card spaghetti and pesto")')
    o.feed("This index card will now allow you to cook spaghetti and pesto when it is held.",
           "This quest [3390] is called 'Cooking Spaghetti and Pesto',",
           "for Adventurers levels 20 to 240.",
           "Spaghetti and pesto is an easy meal with a ton of flavor.  It is a popular",
           "meal in Alyria, and all of the ingredients are fairly easy to find.  ",
           "Upon successful completion of this quest you can receive:",
           "*Up to 0 quest points, 0 practice points, 0 experience points,",
           "0 build points, 0 piety, and 0 gold pieces.",
           "This quest has no time limit.",
           "Cooking Spaghetti and Pesto consists of:",
           "Phase 1: Journey to Li's Diner [The Towne of Xaventry].",
           "Phase 2: Recover and Keep a plate of spaghetti [Cooking Adventurers].",
           "Phase 5: Journey to Dlerick's Restaurant.",
           "For beginning your career as a cook, the Powers have granted thee a Mark.",
           "",
           "You have gained the Mark of Cooking!",
           "<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    eq(o.ev("sbo.quests['3390'] and sbo.quests['3390'].name"), "Cooking Spaghetti and Pesto", "read")
    eq(o.ev("(sbo.cfg.questPins or {})['3390']"), True, "pinned")
    ph = o.ev("sbo.quests['3390'].phases[1]")
    eq((ph.text, ph.area), ("Journey to Li's Diner", "The Towne of Xaventry"), "its steps")
    assert "quest info" in list(o.ev("SENT").values()), "and the quest log checked quietly"
    # a quest command's own reply isn't read twice
    o.lua('SENT = {}; sbo.cfg.questPins = {}; sbo.onSend(nil, "quest info 3390")')
    o.feed("This quest [3390] is called 'Cooking Spaghetti and Pesto',", "for Adventurers levels 20 to 240.", "<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    eq(o.ev("(sbo.cfg.questPins or {})['3390']"), None, "quest info doesn't pin")


@test
def quest_list_with_daily():
    import time as _time
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; sbo.log = function() end')
    o.lua("sbo.quests['3519'] = { name = 'Daily Quest - Feeding Hungry Mouths', active = true }")
    o.lua('sbo.onSend(nil, "quest info")')
    o.feed("             Daily Quest #3519 : Daily Quest - Feeding Hungr (  0/1   complete).  [2h 16min 58s]",
           "                   Quest #3390 : Cooking Spaghetti and Pesto (  0/10  complete).",
           "A total of [2] quests.",
           "Type QUEST STATUS <#> for complete information on that quest.",
           "<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    eq(o.ev("sbo.quests['3519'].name"), "Daily Quest - Feeding Hungry Mouths", "the whole name kept, not 'Feeding Hungr'")
    eq((o.ev("sbo.quests['3519'].done"), o.ev("sbo.quests['3519'].total")), (0, 1), "its progress")
    left = o.ev("sbo.quests['3519'].deadline") - int(_time.time())
    assert abs(left - (2 * 3600 + 16 * 60 + 58)) <= 5, f"time left from [2h 16min 58s]: {left}"
    eq(o.ev("sbo.quests['3390'].active"), True, "the other quest")
    # pin all: both
    o.lua("sbo.cfg.questPins = {}; sbo.pinAllFromList = true; sbo.questPin('all', true); sbo.pinAllFromList = nil")
    eq(sorted(o.ev("sbo.cfg.questPins").keys()), ["3390", "3519"], "pin all pins the daily too")


@test
def quest_hint_paragraphs_and_folding():
    import re as _re
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; sbo.log = function() end; sbo.cfg.questHudBlurb = true')
    o.lua('sbo.onSend(nil, "quest info 3390")')
    o.feed("This quest [3390] is called 'Cooking Spaghetti and Pesto',",
           "for Adventurers levels 20 to 240.",
           "Spaghetti and pesto is an easy meal with a ton of flavor.  It is a popular",
           "meal in Alyria, and all of the ingredients are fairly easy to find.  ",
           "",
           "Your journey begins at Li's Diner in Xaventry.  They serve a plate of",
           "spaghetti there, but their cooks do not season it very well.  ",
           "",
           "The cooks in the Palace of Diocletian are known to use a lot of pesto in",
           "their creations, and they undoubtedly have some.  ",
           "Upon successful completion of this quest you can receive:",
           "This quest has no time limit.",
           "Cooking Spaghetti and Pesto consists of:",
           "Phase 1: Journey to Li's Diner [The Towne of Xaventry].",
           "<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    desc = list(o.ev("sbo.quests['3390'].desc").values())
    assert "" in desc, f"the paragraph breaks are kept: {desc}"
    card = lambda: [_re.sub("<[^>]+>", "", x).replace("\xa0", " ") for x in o.lua("return (sbo.questCardHtml('3390', sbo.quests['3390']))").values()]
    folded = card()
    assert any("more line" in x and "click to open" in x for x in folded), folded
    assert not any("Palace of Diocletian" in x for x in folded), "folded: the rest hidden"
    o.lua("sbo.questHudClick('3390')")
    opened = card()
    assert any("Palace of Diocletian" in x for x in opened), opened
    i = next(k for k, x in enumerate(opened) if "Li's Diner in Xaventry" in x)
    assert opened[i - 1].strip() == "", f"a gap between paragraphs: {opened[i-2:i+1]}"
    assert any("click to fold" in x for x in opened), opened
    o.lua("sbo.questHudClick('3390')")
    assert any("click to open" in x for x in card()), "folded again"
    # paragraphs with no blank line between them (the daily quest): a line ending in two spaces, or one
    # longer than the game wraps at, ends its paragraph
    lines = open(fixture("quest_login_daily.txt"), encoding="utf-8").read().rstrip("\n").split("\n")
    o.feed(*lines, "<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    desc = list(o.ev("sbo.quests['3519'].desc").values())
    eq(desc[1], "", f"after the DAILY line: {desc}")
    eq(desc[desc.index("sustenance they need to thrive.") + 1], "", "after 'thrive.  '")
    assert not any("velocity token" in d for d in desc), f"rewards aren't the hint: {desc}"
    eq(list(o.ev("sbo.quests['3519'].rewardItems").values()), ["a velocity token", "a dusty curious coin"], "they're rewards")
    o.lua("sbo.cfg.questHintOpen = { ['3519'] = true }")
    panel = " ".join(_re.sub("<[^>]+>", "", x).replace("\xa0", " ") for x in o.lua("return (sbo.questCardHtml('3519', sbo.quests['3519']))").values())
    panel = _re.sub(r"\s+", " ", panel)   # a phrase can wrap across lines
    assert "you areAdventurer" not in panel and "you are Adventurer" in panel, f"lines don't glue together: {panel}"
    assert "Up to" in panel and "25,000 gold pieces" in panel and "a velocity token" in panel, panel
    assert "0 piety" not in panel, "rewards of nothing left out"
    # and the quest info layout shows them, and the time left
    o.L.globals().LINES = o.L.table_from(lines[lines.index(next(l for l in lines if l.startswith("This quest"))):])
    lay = o.lua('local raw = {} for _, l in ipairs(LINES) do raw[#raw+1] = l end local out = sbo.formatters.quest(raw, 100) local t = {} for _, r in ipairs(out) do for _, g in ipairs(r) do t[#t+1] = tostring(g[2] or "") end t[#t+1] = "\\n" end return table.concat(t)')
    assert "a velocity token" in lay and "a dusty curious coin" in lay, lay
    assert "Time left" in lay and "8h" in lay, lay


@test
def quest_hint_colours():
    import re as _re
    o = Oven()
    o.lua('sbo.cfg.questHudBlurb = true; sbo.log = function() end')
    plain = ["This quest [3390] is called 'Cooking Spaghetti and Pesto',",
             "that they don't mind the public using.  Type where is cooking-mixing-bowl",
             "to get directions, and then journey to that kitchen and enter the command",
             "cook spaghetti and pesto.  ",
             "Cooking Spaghetti and Pesto consists of:", "Phase 1: Journey to Li's Diner [The Towne of Xaventry]."]
    decho = ["<192,192,192:0,0,0>This quest [3390] is called 'Cooking Spaghetti and Pesto',<r>",
             "<192,192,192:0,0,0>that they don't mind the public using.  Type <r><0,255,255:0,0,0>where is cooking-mixing-bowl<r>",
             "<192,192,192:0,0,0>to get directions, and then journey to that kitchen and enter the command<r>",
             "<0,255,255:0,0,0>cook spaghetti and pesto<r><192,192,192:0,0,0>.  <r>",
             "<192,192,192:0,0,0>Cooking Spaghetti and Pesto consists of:<r>", "<192,192,192:0,0,0>Phase 1: Journey to Li's Diner [The Towne of Xaventry].<r>"]
    o.L.globals().P = o.L.table_from(plain); o.L.globals().D = o.L.table_from(decho)
    o.lua("local q = sbo.parseQuests(P, D); sbo.rememberQuests(q, false); sbo.cfg.questHintOpen = { ['3390'] = true }")
    html = "\n".join(o.lua("return (sbo.questCardHtml('3390', sbo.quests['3390']))").values())
    assert 'rgb(0,255,255)">where' in html and 'rgb(0,255,255)">cooking-mixing-bowl' in html, html
    text = _re.sub("<[^>]+>", "", html)
    assert "pesto." in text and "pesto ." not in text, f"no space before the full stop: {text}"


@test
def quest_done_before_taken_again():
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; sbo.log = function() end')
    # done in the past: complete, turned in, every step done
    o.lua("""sbo.quests['1348'] = { name = 'Again', active = false, complete = true, turnedIn = 1, turnIn = 'Someone', done = 2, total = 2,
      phases = { { n = 1, text = 'Visit A', done = true }, { n = 2, text = 'Visit B', done = true } } }""")
    # taken again
    o.feed("You undertake the quest 'Again', #1348.", "This quest [1348] is called 'Again',", "for Adventurers levels 1 to 250.",
           "Again consists of:", "Phase 1: Visit A.", "Phase 2: Visit B.", "<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    eq((o.ev("sbo.quests['1348'].complete"), o.ev("sbo.quests['1348'].turnedIn")), (None, None), "not complete any more")
    eq(o.ev("sbo.questFinished(sbo.quests['1348'])"), False, "in progress")
    eq(o.ev("(sbo.cfg.questPins or {})['1348']"), True, "pinned")
    # pin all takes it too, from the list
    o.lua("sbo.quests['1348'].complete = true; sbo.cfg.questPins = {}")
    o.lua('sbo.onSend(nil, "quest info")')
    o.feed("                   Quest #1348 : Again (  0/2  complete).", "A total of [1] quests.", "<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    eq(o.ev("sbo.questFinished(sbo.quests['1348'])"), False, "the list says 0/2: in progress")
    o.lua("sbo.pinAllFromList = true; sbo.questPin('all', true); sbo.pinAllFromList = nil")
    eq(list(o.ev("sbo.cfg.questPins").keys()), ["1348"], "pin all")
    o.lua('sbo.command("quest clear 1348")')
    eq((o.ev("sbo.quests['1348']"), o.ev("sbo.cfg.questPins['1348']")), (None, None), "sbo quest clear")


@test
def pin_unknown_quest():
    o = Oven()
    o.lua("""sbo.cfg.promptPattern = "<%d+hp"; SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
      sbo.notifyQuest = function(m) SAYS[#SAYS+1] = m end
      REPLY = {
        ["quest info 1348"] = { "This quest [1348] is called 'The Lord's New Clothes',", "for Adventurers levels 40 to 90.",
                                "The Lord's New Clothes consists of:", "Phase 1: Recover and Keep a big sombrero." },
        ["quest info 9999"] = { "You are not on that quest." } }
      SENT = {}
      send = function(c) SENT[#SENT+1] = c; sbo.onSend(nil, c); for _, l in ipairs(REPLY[c] or {}) do line = l; sbo.onLine() end; line = "<281hp 696sp 457st>"; sbo.onLine() end""")
    o.lua('sbo.command("quest pin 1348"); runTimers()')
    eq(list(o.ev("SENT").values()), ["quest info 1348"], "asked the game")
    eq(o.ev("sbo.quests['1348'].name"), "The Lord's New Clothes", "the card has the quest")
    eq(o.ev("sbo.cfg.questPins['1348']"), True, "pinned")
    o.lua('sbo.command("quest pin 9999"); runTimers()')
    eq(o.ev("sbo.cfg.questPins['9999']"), None, "not yours: unpinned")
    assert any("isn't a quest you have" in m and "You are not on that quest" in m for m in o.ev("SAYS").values()), list(o.ev("SAYS").values())


@test
def formatting_off_still_reads():
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; sbo.cfg.enabled = false; GAGGED = 0; deleteLine = function() GAGGED = GAGGED + 1 end')
    o.lua('sbo.onSend(nil, "quest info 1348")')
    o.feed("This quest [1348] is called 'The Lord's New Clothes',", "for Adventurers levels 40 to 90.",
           "The Lord's New Clothes consists of:", "Phase 1: Recover and Keep a big sombrero [Towne of Rune].", "<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    eq(o.ev("sbo.quests['1348'] and sbo.quests['1348'].name"), "The Lord's New Clothes", "formatting off: still read")
    eq(o.ev("GAGGED"), 0, "and the game's text left alone")


@test
def quest_go_prefers_a_shop_with_the_item():
    o = Oven()
    o.lua("""roomExists = function() return true end; getRoomName = function(id) return "Room " .. id end
      getRoomArea = function() return 1 end; getRoomAreaName = function() return "Rune" end
      getPath = function(a, b) speedWalkDir = {} for i = 1, (b == 300 and 9 or 3) do speedWalkDir[i] = "e" end return true end
      sbo.mapRoom = 1
      sbo.dbx("INSERT INTO shops (room, name, last) VALUES (62538, 'Jepar''s Imported Cuisine', 1)")
      sbo.dbx("INSERT INTO shop_items (room, no, item, level, amount, cost, last, currency) VALUES (62538, 1, 'A bottle of white wine', 1, 'No limit', 145, 1, 'gold')")
      gmcp.char = { quests = { q2682 = { quest_info = { vnum = 2682 }, goals = { { phase_number = 4, room_target = 62538 } } } } }""")
    ph = "{ n = 4, text = 'Recover and Keep a bottle of Sepharian white wine' }"
    # no shop sells it: the game's room
    eq(o.ev(f"(sbo.questTarget({ph}, '2682'))"), 62538, "the game's room when no shop has it")
    # a shop that sells exactly it: there instead; plain white wine doesn't count
    o.lua("""sbo.questTargetCache = {}
      sbo.dbx("INSERT INTO shops (room, name, last) VALUES (300, 'Randol''s Fine Wines', 1)")
      sbo.dbx("INSERT INTO shop_items (room, no, item, level, amount, cost, last, currency) VALUES (300, 1, 'A bottle of Sepharian white wine', 1, '5', 500, 1, 'gold')")""")
    room = o.ev(f"(sbo.questTarget({ph}, '2682'))")
    eq(room, 300, "the shop that sells it")
    why = o.lua(f"local _, w = sbo.questTarget({ph}, '2682') return w")
    assert "Randol" in why and "Sepharian" in why, why


@test
def quest_request_after_quest_timer():
    # quest timer's reply isn't one Oven reads; the request typed after it must still be read as the request
    reply = open(fixture("quest_request.txt"), encoding="utf-8").read().rstrip("\n").split("\n")
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; sbo.log = function() end; sbo.notifyQuest = function() end')
    o.lua('sbo.onSend(nil, "quest timer")')
    o.feed("You are unburdened by any timer and may request a new quest.", "<281hp 696sp 457st>")
    o.lua('sbo.onSend(nil, "quest req")')
    o.feed("You ask Lord Agrippa for a quest.", *reply, "<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    eq(o.ev("(sbo.cfg.questPins or {})['1547']"), True, "the request's quest is pinned")
    # and a quest Oven had no record of, brought up some other way, is pinned too; quest info isn't
    o.lua("sbo.cfg.questPins = {}; sbo.quests = {}")
    o.lua('sbo.onSend(nil, "quest info 1547")')
    o.feed(*reply, "<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    eq(o.ev("(sbo.cfg.questPins or {})['1547']"), None, "looking a quest up doesn't pin it")


@test
def quest_step_done_inside_a_reply():
    o = Oven()
    o.lua("""sbo.cfg.promptPattern = "<%d+hp"; sbo.log = function() end
      SENT = {}; send = function(c) SENT[#SENT+1] = c end
      sbo.quests = { ["3213"] = { name = "Warpstones Tutorial", active = true, total = 4, done = 0, phases = {} } }
      sbo.cfg.questPins = { ["3213"] = true }""")
    o.lua('sbo.onSend(nil, "quest identify 2")')
    o.feed("You ask Lord Agrippa for a description of one of his wares.", "Lord Agrippa tells you:",
           "Item 'a garnet gemstone' is type warp-stone, alignment 0, made of stone (in (new) condition),[EQDB]",
           "Lord Agrippa tells you, 'I can sell you this item for 300 questpoints.'",
           "You have completed a part of quest #3213!", "<281hp 696sp 457st>")
    o.L.execute("runTimers()")
    assert "quest info 3213" in list(o.ev("SENT").values()), list(o.ev("SENT").values())


@test
def quest_steps_update():
    reply = open(fixture("quest_request.txt"), encoding="utf-8").read().rstrip("\n").split("\n")
    o = Oven()
    o.lua('sbo.cfg.promptPattern = "<%d+hp"; sbo.onSend(nil, "quest request")')
    o.feed(*reply, "<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    eq((o.ev("sbo.quests['1547'].done"), o.ev("sbo.quests['1547'].total")), (0, 5), "from the request")
    # the game's GMCP after step 1 (goal_string as it sends it: * for done, a newline after)
    o.lua('''gmcp.char = { quests = { q1547 = { quest_info = { vnum = 1547, name = "War and Peace", completed = false, abandoned = false },
      goals = { { phase_number = 1, phase_complete = true, goal_string = "*Phase 1: *Journey to The Edible Loaf [Towne of Rune].\\r\\n" },
                { phase_number = 2, phase_complete = false, goal_string = "Phase 2: Locate and deliver a waybread [Towne of Rune] to a stray dog [Towne of Rune].\\r\\n" },
                { phase_number = 5, phase_complete = false, goal_string = "Phase 5: Visit Lord Agrippa [Towne of Rune].\\r\\n" } } } } }
      sbo.onGmcpQuests()''')
    eq(o.ev("sbo.quests['1547'].done"), 1, "step 1 done from GMCP")
    eq(o.ev("sbo.quests['1547'].phases[1].done"), True, "")
    eq(o.ev("sbo.quests['1547'].phases[5].text"), "Visit Lord Agrippa", "a hidden step's text once revealed")
    # the HUD keeps the done step, greyed
    o.lua('sbo.cfg.questPins = { ["1547"] = true }; H = sbo.questCardHtml("1547", sbo.quests["1547"])')
    html = o.ev("type(H) == 'table' and table.concat(H, '\\n') or H")
    assert "Journey to The Edible Loaf" in html and "waybread" in html, f"done and open steps both on the HUD: {html}"
    done_line = [l for l in html.split("\n") if "Edible Loaf" in l][0]
    assert "▶" not in done_line, "the next-step marker moves past the done step"
    # a completion line without GMCP: a quiet re-check of that quest
    o.lua('SENT = {}; send = function(c) SENT[#SENT + 1] = c end; sbo.questGmcpAt = {}')
    o.feed("You have completed a part of quest #1547, 'War and Peace'!")
    o.L.execute("runTimers()")
    eq(list(o.ev("SENT").values()), ["quest info 1547"], "re-checks the quest")
    o.lua('SENT = {}')
    o.feed("Moss says, 'I completed my quest 'Other Thing' yesterday'")
    o.L.execute("runTimers()")
    eq(list(o.ev("SENT").values()), [], "not for quests you don't have pinned")


@test
def quest_step_done_real():
    # finishing step 1 of Jail Time, as recorded: GMCP with the new state, and the game's line
    o = Oven()
    o.lua('''sbo.cfg.promptPattern = "<%d+hp"; sbo.cfg.questPins = { ["52"] = true }
      sbo.quests = { ["52"] = { name = "Jail Time", done = 0, total = 4, active = true, phases = {
        { n = 1, text = "Journey to The Entrance to Rune Prison", area = "Towne of Rune" }, { n = 2, text = "Journey to Prison Entrance", area = "Lowangen" },
        { n = 3, text = "Visit the prison captain" }, { n = 4, text = "Defeat a sickly prisoner", area = "Lowangen" } } } }
      SENT = {}; send = function(c) SENT[#SENT + 1] = c end''')
    b = read_recording(fixture("quest_step_done.txt"))[0]
    for n, v in b["gmcp"]:
        o.set_gmcp(n, v)
    o.lua("sbo.onGmcpQuests()")
    o.feed(*b["lines"])
    o.L.execute("runTimers()")
    eq((o.ev("sbo.quests['52'].done"), o.ev("sbo.quests['52'].phases[1].done"), o.ev("sbo.quests['52'].phases[2].done == true")), (1, True, False), "step 1 done")
    eq(list(o.ev("SENT").values()), [], "GMCP brought it: no extra quest info")
    eq(o.ev("(sbo.noteQuestProgress(\"You have completed a part of quest #52, 'Jail Time'!\"))"), "52", "the game's line is recognised")
    o.lua('sbo.questGmcpAt = {}')
    o.feed("You have completed a part of quest #52, 'Jail Time'!", "Your next task is Phase 4: Defeat a sickly prisoner [Lowangen].")
    o.L.execute("runTimers()")
    # the last step
    o.feed("All parts of your quest 'Jail Time' are complete.", "Return to Lord Agrippa in time to receive your reward!")
    eq((o.ev("sbo.quests['52'].complete"), o.ev("sbo.quests['52'].turnIn")), (True, "Lord Agrippa"), "complete, and who to return to")
    card = o.ev('sbo.questCardHtml("52", sbo.quests["52"])')
    card = "\n".join(card[0].values())   # (lines, width)
    assert "return to Lord Agrippa" in card, card
    o.L.execute("runTimers()")
    eq(list(o.ev("SENT").values()), ["quest info 52"], "no GMCP with it: quest info 52, quietly")


@test
def quest_stays_until_turned_in():
    for log, want in (("other quest", None), ("still there", True), ("empty", None)):
        o = Oven()
        o.lua(f'''sbo.cfg.promptPattern = "<%d+hp"; SENT = {{}}
          sbo.quests = {{ ["52"] = {{ name = "Jail Time", done = 4, total = 4, complete = true, active = true }},
                         ["7"] = {{ name = "Other", done = 0, total = 2, active = true }} }}
          sbo.cfg.questPins = {{ ["52"] = true }}
          local replies = {{
            ["quest complete"] = {{ "Lord Agrippa takes your report and rewards you." }},
            ["quest info"] = ({{ ["other quest"] = {{ "Quest #7: Other (0/2 complete)", "Quest #9: Third (1/3 complete)" }},
                               ["still there"] = {{ "Quest #52: Jail Time (4/4 complete)", "Quest #7: Other (0/2 complete)" }},
                               ["empty"] = {{ "You are not on any quests." }} }})["{log}"],
          }}
          send = function(c)
            SENT[#SENT + 1] = c
            sbo.onSend(nil, c)
            for _, l in ipairs(replies[c] or {{}}) do line = l; sbo.onLine() end
            line = "<270hp>"; sbo.onLine()
          end''')
        o.lua('sbo.drawQuestTracker()')
        eq(o.ev("sbo.cfg.questPins['52']"), True, "a finished quest stays pinned")
        o.lua('send("quest complete"); runTimers()')
        eq(list(o.ev("SENT").values()), ["quest complete", "quest info"], "checks the log after quest complete")
        eq(o.ev("sbo.cfg.questPins['52']"), want, f"log: {log}")


@test
def quest_turn_in_real():
    o = Oven()
    o.lua('''sbo.cfg.promptPattern = "<%d+hp"; SENT = {}
      sbo.quests = { ["52"] = { name = "Jail Time", done = 4, total = 4, complete = true, active = true } }
      sbo.cfg.questPins = { ["52"] = true }
      send = function(c) SENT[#SENT + 1] = c end
      sbo.onSend(nil, "quest com")''')
    o.feed("You inform Lord Agrippa you have completed your quest 'Jail Time'.",
           "Lord Agrippa tells you, 'Congratulations on the completion of thy quest, Hero!'",
           "Lord Agrippa tells you, 'As a reward for thy valor, I am awarding you 27 quest points, 18,000 experience points, 1 alignment, 3 practices, and 5,000 gold pieces.'",
           "<270hp>")
    o.L.execute("runTimers()")
    eq(o.ev("sbo.cfg.questPins['52']"), None, "unpinned straight away")
    eq(list(o.ev("SENT").values()), [], "no quest info needed")
    eq([e for e in (dict(x.items()) for x in o.ev("sbo.chat.lines").values())], [], "the quest master's tells aren't chat")


@test
def quest_givers_any_npc():
    o = Oven()
    o.lua('''sbo.cfg.promptPattern = "<%d+hp"; SENT = {}; send = function(c) SENT[#SENT + 1] = c end
      sbo.quests = { ["3098"] = { name = "Training in the Forest", done = 6, total = 6, master = "The head park keeper", active = true },
                     ["90"] = { name = "Bridge Trial", done = 2, total = 2, active = true } }
      sbo.cfg.questPins = { ["3098"] = true, ["90"] = true }''')
    o.feed("All parts of your quest 'Bridge Trial' are complete.", "Return to Samara in time to receive your reward!", "<270hp>")
    eq(o.ev("sbo.quests['90'].turnIn"), "Samara", "any quest giver")
    o.feed("You inform the head park keeper you have completed your quest 'Training in the Forest'.", "<270hp>")
    eq(o.ev("sbo.cfg.questPins['3098']"), None, "turned in to the head park keeper")
    o.feed("You inform Samara you have completed your quest 'Bridge Trial'.",
           "Samara tells you, 'Congratulations on the completion of thy quest, Hero!'", "<270hp>")
    eq(o.ev("sbo.cfg.questPins['90']"), None, "turned in to Samara")
    eq(o.ev("sbo.quests['90']"), None, "turned in: its record is gone too")
    eq(o.ev("#sbo.chat.lines"), 0, "a one-word quest giver's tell isn't chat")
    o.feed("Wren tells you 'nice one'", "<270hp>")
    eq(o.ev("#sbo.chat.lines"), 1, "a player's tell still is")


@test
def game_aliases():
    o = Oven()
    o.lua('''sbo.cfg.promptPattern = "<%d+hp"; SENT = {}; sbo.aliasesAsked = nil
      REPLY = {
        ["alias"] = { "Currently defined aliases:", " 1. 'pp' performs action 'cast 'pressure points''",
                      " 2. 'cl' performs action 'cast 'cure light''", " 3. 'feed' performs action 'cast feeding'", "A total of 3/100 aliases." },
        ["alias qr quest request"] = { "You have aliased 'qr' to perform action 'quest request'." },
        ["alias cl cast 'cure serious'"] = { "Alias 'cl' has been realiased to 'cast 'cure serious'' from 'cast 'cure light''." },
        ["unalias feed"] = { "Alias removed." },
      }
      send = function(c)
        SENT[#SENT + 1] = c
        sbo.onSend(nil, c)
        for _, l in ipairs(REPLY[c] or {}) do line = l; sbo.onLine() end
        line = "<270hp>"; sbo.onLine()
        if c == "unalias feed" then REPLY["alias"] = { "Currently defined aliases:", " 1. 'pp' performs action 'cast 'pressure points''",
          " 2. 'cl' performs action 'cast 'cure serious''", " 3. 'qr' performs action 'quest request'", "A total of 3/100 aliases." } end
      end''')
    # logging in: nothing may be sent at the password question, even though it looks like a prompt
    o.lua('isPrompt = function() return line == "Password:" or line:find("<") ~= nil end')
    o.feed("By what name do you wish to be known?")
    o.feed("Password:")
    o.L.execute("runTimers()")
    eq(list(o.ev("SENT").values()), [], "nothing sent at the login screen")
    o.lua('gmcp.char = gmcp.char or {}; gmcp.char.status = { state = "playing" }')
    o.feed("Welcome back!", "<270hp>")      # the first prompt in the game
    o.L.execute("runTimers()")
    eq(list(o.ev("SENT").values()), ["alias"], "reads the list once, quietly, at the first prompt in the game")
    eq(o.ev("sbo.cfg.gameAliases.pp"), "cast 'pressure points'", "an alias with quotes in it")
    o.lua('send("alias qr quest request"); send("alias cl cast \'cure serious\'"); runTimers()')
    eq((o.ev("sbo.cfg.gameAliases.qr"), o.ev("sbo.cfg.gameAliases.cl")), ("quest request", "cast 'cure serious'"), "added and changed")
    eq(o.ev('sbo.expandAlias("qr")'), "quest request", "qr is a quest request to Oven")
    eq(o.ev('(sbo.classify(sbo.expandAlias("qr")))'), "quest", "")
    # an alias for help: the block is a help page, so nothing in it is read as kills, loot or chat
    o.lua("sbo.cfg.gameAliases.h = 'help'")
    o.lua('sbo.onSend(nil, "h slay")')
    eq(o.ev("sbo.recCur.cmds[#sbo.recCur.cmds]"), "help slay", "the chunk knows the command as help")
    o.feed("The dragon has been slain!", "<270hp>")
    eq(o.ev("sbo.dbRow('SELECT COUNT(*) AS c FROM kills').c"), 0, "no kill read from that help page")
    o.lua('SENT = {}; send("unalias feed"); runTimers()')
    eq(list(o.ev("SENT").values()), ["unalias feed", "alias"], "after unalias: the list again")
    eq(o.ev("sbo.cfg.gameAliases.feed"), None, "removed")
    o.lua('SENT = {}'); o.feed("<270hp>"); o.L.execute("runTimers()")
    eq(list(o.ev("SENT").values()), [], "not again in the same session")
    o.lua('handlers["sysConnectionEvent"]()'); o.feed("<270hp>"); o.L.execute("runTimers()")
    eq(list(o.ev("SENT").values()), ["alias"], "again after reconnecting")


@test
def in_game_rule():
    o = Oven()
    ig = lambda p: o.ev(f'sbo.inGame("{p}")')
    o.lua("gmcp.char = nil; gmcp.room = nil")
    eq(ig("Password:"), False, "the login screen")
    eq(ig("[Mail]<281hp 696sp 457st> "), False, "a prompt, but no sign from GMCP yet")
    o.lua('gmcp.room = { info = { num = "10614" } }')
    eq(ig("[Mail]<281hp 696sp 457st> "), True, "no char.status this login (the game sends it rarely): the room will do")
    eq(ig("Password:"), False, "a room left over from before, at a password prompt: still no")
    o.lua('gmcp.char = { status = { state = "login" } }')
    eq(ig("[Mail]<281hp 696sp 457st> "), False, "char.status says not playing: it wins")
    o.lua('gmcp.char = { status = { state = "playing" } }')
    eq(ig("[Mail]<281hp 696sp 457st> "), True, "playing")


@test
def messages_survive_the_bar():
    # Mudlet deletes the line the cursor is on: a message printed while the prompt is handled was
    # deleted along with the prompt (the bar takes it). Messages wait until the line is done.
    sushi = open(fixture("shop_list.txt"), encoding="utf-8").read().split("\n---\n")[0].split("\n")
    o = Oven()
    o.lua("""sbo.cfg.promptPattern = "<%d+hp"; sbo.cfg.bar = true
      sbo.bar = setmetatable({}, { __index = function() return function() end end })
      SHOWN = {}
      cecho = function(w, t) if t == nil then t = w end SHOWN[#SHOWN + 1] = t end
      deleteLine = function() table.remove(SHOWN) end
      sbo.mapRoom = 10515""")
    o.lua('sbo.onSend(nil, "sh li")')
    o.feed(*sushi, "<270hp 550sp 401st>")
    o.L.execute("runTimers()")
    shown = "".join(o.ev("SHOWN").values())
    assert "new shop: the Sushi Bar" in shown, f"the message was deleted with the prompt: {shown[-300:]}"


@test
def prompt_with_text_after_it():
    # the game went on right after a prompt, on the same line: the prompt to the bar, the rest stays
    o = Oven()
    o.lua("""sbo.cfg.promptPattern = "^<%d+hp"; sbo.cfg.bar = true
      sbo.bar = setmetatable({}, { __index = function() return function() end end })
      BARS = {}; local bu = sbo.barUpdate; sbo.barUpdate = function(d) BARS[#BARS + 1] = d end
      SEL = nil; selectSection = function(a, n) SEL = { a, n } return true end
      REPLACED = nil; replace = function(t) REPLACED = { SEL[1], SEL[2], t } end; deselect = function() end
      copy2decho = function() return string.sub(line, SEL[1] + 1, SEL[1] + SEL[2]) end""")
    eq(o.ev('sbo.promptHead("<281hp 696sp 444st> You receive an index card containing a recipe.")'), "<281hp 696sp 444st>", "the head")
    eq(o.ev('sbo.promptHead("[Mail]<281hp 696sp 444st> You receive a card.")'), "[Mail]<281hp 696sp 444st>", "with tags")
    eq(o.ev('sbo.promptHead("A sign reads <beware> of the dog.")'), None, "not a prompt")
    o.feed("<281hp 696sp 444st> You receive an index card containing a recipe.")
    eq(list(o.ev("REPLACED").values()), [0, 20, ""], "the prompt and its space taken off the line")
    eq(list(o.ev("BARS").values()), ["<281hp 696sp 444st> "], "and onto the bar")
    # aboard a ship
    eq(o.ev('sbo.promptHead("[Mail](120hull --dir ANCHOR --wind 452, 1210) ship info")'), "[Mail](120hull --dir ANCHOR --wind 452, 1210)", "a ship's prompt")
    eq(o.ev('sbo.promptHead("Roarke (the bold) waves.")'), None, "brackets in game text")
    o.lua("BARS = {}; GAG = 0; deleteLine = function() GAG = GAG + 1 end; isPrompt = function() return true end")
    o.feed("[Mail](120hull --dir ANCHOR --wind 452, 1210) ")
    eq(len(list(o.ev("BARS").values())), 1, "the ship prompt goes to the bar")
    eq(o.ev("GAG"), 1, "and off the game text")


@test
def quest_target_colours():
    o = Oven(before='''gmcp = { char = { quests = { q52 = { goals = { { phase_number = 1, room_target = 10733 } } } } } }
      roomExists = function() return true end; getRoomName = function(id) return ({ [10733] = "The Entrance to Rune Prison", [77] = "The Edible Loaf" })[id] end
      getRoomArea = function() return 1 end; getRoomAreaName = function() return "Towne of Rune" end
      searchRoom = function(n) if n:lower():find("edible loaf") then return { ["77"] = "The Edible Loaf" } end return {} end''')
    o.lua('''sbo.quests = { ["52"] = { name = "Jail Time", total = 1, done = 0, phases = { { n = 1, text = "Journey to The Entrance to Rune Prison", area = "Towne of Rune" } } },
                            ["1547"] = { name = "War and Peace", total = 1, done = 0, phases = { { n = 1, text = "Journey to The Edible Loaf", area = "Towne of Rune" } } } }
      color_table.pale_green = { 152, 251, 152 }; color_table.orange = { 255, 165, 0 }''')
    exact = "\n".join(o.ev('sbo.questCardHtml("52", sbo.quests["52"])')[0].values())
    guess = "\n".join(o.ev('sbo.questCardHtml("1547", sbo.quests["1547"])')[0].values())
    # (the palette's gain colour for the game's own room, its warning colour for a guess)
    assert "rgb(40,255,80)\">The Entrance to Rune Prison" in exact, exact
    assert "rgb(255,145,0)\">The Edible Loaf" in guess, guess


@test
def mob_formation():
    lines = open(fixture("mob_formation.txt"), encoding="utf-8").read().rstrip("\n").split("\n")
    o = Oven()
    r = o.sbo.format("item", "jan", o.L.table_from(lines), 100)
    text = ["".join(seg[j][2] for j in range(1, len(seg) + 1)) for seg in (r[i] for i in range(1, len(r) + 1))]
    para = [t for t in text if "janitors who work" in t or "workload" in t]
    assert not any("[" in t or "Formation" in t for t in para), f"formation run into the description: {para}"
    grid = [t for t in text if t.startswith("[")]
    eq(len(grid), 5, "the grid, row by row")
    assert grid[0].split() [:3] == ["[------------]", "[vagabond", "]"], grid[0]
    assert any("formation of 2" in t and "Box Formation" in t for t in text), text


@test
def bar_from_gmcp():
    o = Oven()
    o.lua('''sbo.cfg.bar = true; sbo.cfg.maxes = { hp = 300, sp = 700, st = 460 }
      sbo.bar = { rawEcho = function(self, h) BAR = h end }
      sbo.lastPromptText = "[Mail]<291hp 696sp 457st>"
      gmcp.char = { vitals = { hp = 120, sp = 650, st = 400 } }
      sbo.drawBar()''')
    plain = __import__("re").sub("<[^>]+>", "", o.ev("BAR") or "")
    assert "120" in plain and "291" not in plain, f"HP from GMCP, not the prompt: {plain}"
    assert "Mail" in o.ev("(function() local t = {} for _, x in ipairs(sbo.topBarSegs or {}) do t[#t+1] = x[2] end return table.concat(t) end)()") and "Mail" not in plain, "the prompt's Mail flag: up on the top bar"
    o.lua('gmcp.char.vitals.hp = 80; handlers["gmcp.char.vitals"]()')
    plain = __import__("re").sub("<[^>]+>", "", o.ev("BAR") or "")
    assert " 80" in plain, f"redrawn when vitals change, no prompt needed: {plain}"


@test
def shop_and_quest_id_like_look():
    o = Oven()
    for cmd, kind in [("sh id 9", "item"), ("shop identify 3", "item"), ("quest id 2", "item"), ("que ident 12", "item"),
                      ("sh li", "shop"), ("shop list", "shop"), ("quest info", "quest"), ("quest request", "quest")]:
        eq(o.ev("function(c) return (sbo.classify(c)) end")(cmd), kind, cmd)
    # the reply: the shopkeeper's two lines, then the item - laid out like a look, its name the title
    lines = ["You ask the trainer of neophytes for a description of one of her wares.", "The trainer of neophytes tells you:",
      "Item 'a pair of cleric's leggings' is type armor, alignment 0, made of bronze (in (new) condition),[EQDB]",
      "has keywords 'pair clerics leggings', equipped on the legs.",
      "This item weighs 0 stones and 25 pebbles, and is valued at 29,800 gold. {Cat. 5}",
      "Armor resistance is 23.", "Affects sp-regen by 10."]
    o.L.globals().IL = o.L.table_from(lines)
    text = o.ev("""(function() local raw = {} for _, l in ipairs(IL) do raw[#raw+1] = l end local l = sbo.format('item', '9', raw, 100)
      local s = {} for _, r in ipairs(l) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = '\\n' end return table.concat(s) end)()""")
    assert "a pair of cleric's leggings" in text.split("\n")[0] and "Armor" in text and "sp-regen" in text, text
    assert "You ask the trainer" not in text and "tells you:" not in text, "the shop's boilerplate goes: " + text
    # an artifact replica the shop doesn't stock now: "Level 241 item '…'", chatter before, a line after
    lines = ["'Keep in mind, thessse artifactsss are no more than replicasss.' a cobra blacksmith says to you.",
      "You ask a cobra blacksmith for a description of one of his wares.", "A cobra blacksmith tells you:",
      "Level 241 item 'an oval energy belt' is type jewelry, with keywords '_21517_2000000101795037597",
      "  oval pure energy belt shimmering translucent piece'", "and is equipped around the waist.",
      "*This item may be repaired 4 times.", "The air around this unique belt seems to actually be writhing in pain.", "",
      "+++ an oval energy belt will, each time a nexus is opened, detect that", "fact and alert its wearer to that fact.",
      "This item is beyond your power to identify further.", "A cobra blacksmith tells you 'An oval energy belt is currently unavailable.'"]
    o.L.globals().IL = o.L.table_from(lines)
    text = o.ev("""(function() local raw = {} for _, l in ipairs(IL) do raw[#raw+1] = l end local l = sbo.format('item', '17', raw, 100)
      local s = {} for _, r in ipairs(l) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = '\\n' end return table.concat(s) end)()""")
    head = text.split("\n")[0]
    assert "an oval energy belt" in head and "241" in text and "around the waist" in text, text
    bonus = text[text.index("+++"):]
    assert "beyond your power" not in bonus and "unavailable" not in bonus, "the bonus ends where it ends: " + bonus


@test
def a_move_is_not_a_containers_contents():
    o = Oven()
    def run(move):
        o.lua("""sbo.cfg.window = true; ADDED = 0; sbo.viewAdd = function() ADDED = ADDED + 1 end
          CARRIED = 0; sbo.updateCarried = function() CARRIED = CARRIED + 1 end
          gmcp.room = { info = { num = '206864' } }
          sbo.start('contents', 'safe', 'look in safe')
          sbo.cap.plain = { '  Large bay windows afford a view into the hallway to the north, where',
            '     A tiny imp stands inside a glass bottle, silently pounding on the walls.' }
          sbo.cap.decho = { '', '' }""")
        if move: o.lua("gmcp.room.info.num = '206886'")
        o.lua("sbo.finish('prompt'); runTimers()")
        return o.ev("ADDED"), o.ev("CARRIED")
    eq(run(True), (0, 0), "sw, then look in safe: the room's description isn't the safe's contents")
    eq(run(False), (1, 1), "without a move: laid out as before")


@test
def marks_on_quest_panel():
    o = Oven()
    eq(o.ev("function(c) return (sbo.classify(c)) end")("mark info bravery"), "markinfo", "mark info")
    eq(o.ev("function(c) return (sbo.classify(c)) end")("mark list"), None, "mark list: not")
    lines = ["[Bravery                   ] - Levels  60 - 100", "Visit the statued guard of the Proving Grounds. ",
      "  Grants 35-50 practices. Grants 250,000 experience. ", "  * Located in 'Ogre Village', Alyria",
      "  * Located in 'Irda Isle', Alyria", "", "  Restrictions:", "  Bravery must be attempted while alive."]
    # the reply's lines belong to it - the header too (it looks like a channel line: "[Judgment   ] ...")
    o.lua("sbo.start('markinfo', 'bravery', 'mark info bravery')")
    eq([bool(o.ev("function(l) return sbo.belongs(sbo.cap, l) end")(l)) for l in lines[:4]], [True] * 4, "the reply is the mark's")
    eq(bool(o.ev("function(l) return sbo.belongs(sbo.cap, l) end")("[CLAN] Cobb: 'welcome back'")), False, "a channel line isn't")
    o.lua("sbo.cap = nil")
    o.L.globals().ML = o.L.table_from(lines)
    o.lua("""SENTQ = nil; sbo.inGame = function() return true end
      sbo.quietly = function(cmd, kind, fn) SENTQ = cmd .. '|' .. kind; local t = {} for _, l in ipairs(ML) do t[#t+1] = l end fn(t) end
      RAN = nil; sbo.mapRun = function(w) RAN = w end""")
    o.lua("sbo.command('quest mark bravery')")
    eq(o.ev("SENTQ"), "mark info bravery|markinfo", "asked quietly")
    Mk = "sbo.cfg.markPins.bravery"
    eq((o.ev(Mk + ".lo"), o.ev(Mk + ".hi"), o.ev("#" + Mk + ".located"), o.ev(Mk + ".restrict[1]")),
       (60, 100, 2, "Bravery must be attempted while alive."), "read")
    eq(o.ev(Mk + ".hint[1]"), "Visit the statued guard of the Proving Grounds.", "the hint")
    # on the panel: its card, title count
    text = o.ev("(function() local t = {} for j = 1, 20 do local w = WIDGETS['ovenQuestLine1_' .. j] if w then t[#t+1] = tostring(w.html) end end return table.concat(t, '\\n') end)()")
    for want in ["Mark", "Bravery", "60-100", "Proving Grounds", "Ogre Village", "Irda Isle", "35-50", "practices", "250,000", "while alive", "take it off"]:
        assert want in text, (want, text)
    assert "Marks" in (o.ev("WIDGETS['ovenQuestTitle'].html") or ""), o.ev("WIDGETS['ovenQuestTitle'].html")
    # go ▸ on a place walks there; ✕ takes it off
    o.lua("sbo.questAct({ mark = 'bravery', go = 'Irda Isle' })")
    eq(o.ev("RAN"), "Irda Isle", "go ▸")
    o.lua("sbo.questAct({ mark = 'bravery', fold = true })")
    assert "Proving Grounds" not in str(o.ev("WIDGETS['ovenQuestLine1_2'].html") or "") or not o.ev("WIDGETS['ovenQuestLine1_2'].shown")
    # a tutorial mark: the quest that grants it
    tut = o.ev("""(function() local m = sbo.markParse({ "[Minimalism                ] - Levels  61 - 120", "  * Granted by quest #3276",
      "  To begin this tutorial, QUEST UNDERTAKE 3276" }) return m.quest .. '|' .. m.hint[1] end)()""")
    eq(tut, "3276|To begin this tutorial, QUEST UNDERTAKE 3276", "tutorial mark")
    o.lua("sbo.command('quest unmark brav')")
    eq(o.ev("next(sbo.cfg.markPins)"), None, "unmarked")


@test
def levelling_log():
    o = Oven()
    o.lua("""sbo.cfg.char = { class = 'monk' }
      gmcp.char = { status = { level = 18, totallevel = 78 } }""")
    o.feed("You gain 10 hit points, 5 spell points, 9 stamina, and 12 practices!",
           "Due to your experiences, you have earned a 1 point increase in courage.",
           "You have become more learned at 'cure poison' (9%).",
           "You have gained 1 new proficiency: second attack",
           "Your maximum 'strength' has been adjusted from 20 to 22.",
           "A gnome barbarian has been slain!")
    o.lua("runTimers()")
    r = o.ev("sbo.dbRow('SELECT * FROM levels ORDER BY id DESC LIMIT 1')")
    eq((r.kind, r["class"], r.level, r.total, r.hp, r.sp, r.st, r.pracs), ("level", "monk", 18, 78, 10, 5, 9, 12), "the level and what it gave")
    eq((r.attrs, r.skills, r.learned, r.maxes), ("courage +1", "cure poison 9%", "second attack", "strength 20→22"), "and what came with it")
    # a class change
    o.feed("'Softbuns, you are now a Barbarian!' Lord Vashir exclaims.")
    o.lua("runTimers()")
    r = o.ev("sbo.dbRow('SELECT * FROM levels ORDER BY id DESC LIMIT 1')")
    eq((r.kind, r["class"]), ("class", "barbarian"), "now a barbarian")
    text = o.ev("(function() local s = {} for _, row in ipairs(sbo.levelLines(100)) do for _, g in ipairs(row) do s[#s+1] = tostring(g[2]) end s[#s+1] = '\\n' end return table.concat(s) end)()")
    assert "+10 hp +5 sp +9 st +12 pr" in text and "better at cure poison 9%" in text and "now a barbarian" in text, text
    assert "★ attribute gains: 1" in text and "(courage)" in text, text
    assert any(l.startswith("★ ") and "monk 18" in l for l in text.split("\n")), "the level with it starred"


@test
def scc_multiclass():
    o = Oven()
    # a monk 60, now a barbarian 45 (knowledge 22, vitality 18): score says SCC 79 - the parts added, capped
    o.lua("""sbo.cfg.char = { class = 'barbarian', level = 45, path = { 'monk', 'barbarian' },
      stats = { knowledge = { cur = 22, max = 22 }, vitality = { cur = 18, max = 19 } } }""")
    scc, cap, raw = o.ev("function() local a, b, c = sbo.sccFor() return a, b, c end")()
    eq((round(raw, 1), cap, scc), (96.7, 79, 79), "78.2 + 18.5, capped at 65 + 7 × 2")


@test
def one_palette():
    # no colour outside the palette: hex codes and "<r,g,b>" only in the helpers and the panels' frames
    import re as _re
    src = open(os.path.join(ROOT, "src", "Oven.lua"), encoding="utf-8").read()
    frame = {"#333", "#333333", "#555", "#555555", "#2a2a2a", "#8a7430"}
    # (a colour code sits in a string or a style: after a quote, a space or a colon - not Lua's #list)
    hexes = [h for h in _re.findall(r"(?<=[\"':])\s*#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b", src) if h.strip().lower() not in frame and h.strip().lower() != "#c0c0c0"]
    rgbs = _re.findall(r'"<\d{1,3},\d{1,3},\d{1,3}>', src)
    eq((hexes, rgbs), ([], []), "every colour from the palette")
    o = Oven()
    eq((o.ev("sbo.hex('title')"), o.ev("sbo.drgb('title')")), ("#ffc800", "<255,200,0>"), "a role's RGB")


@test
def levelling_import():
    o = Oven()
    rec = """===== 2026-11-15 20:58:10 | cmd= | room=1
@gmcp char.status = {["level"]=9,["totallevel"]=69}
You gain 10 hit points, 5 spell points, 9 stamina, and 12 practices!
You have become more learned at 'parry' (2%).
===== 2026-11-15 20:58:11 | cmd= | room=1
@gmcp char.status = {["level"]=10,["totallevel"]=70}
===== 2026-11-15 21:08:00 | cmd= | room=1
You gain 10 hit points, 5 spell points, 9 stamina, and 12 practices!
You have gained 1 new proficiency: second attack
===== 2026-11-15 21:08:01 | cmd= | room=1
@gmcp char.status = {["level"]=11,["totallevel"]=71}
"""
    open(o.home + "/oven_record.txt", "w").write(rec)
    o.lua("SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end; sbo.cfg.char = { class = 'barbarian' }; sbo.command('log levels import')")
    assert "2 level-ups found in your recordings, 2 added" in o.ev("SAYS[#SAYS]"), o.ev("SAYS[#SAYS]")
    rows = o.ev("sbo.dbRows('SELECT level, total, skills, learned FROM levels ORDER BY t')")
    got = [(r.level, r.total, r.skills, r.learned) for r in rows.values()]
    eq(got, [(10, 70, "parry 2%", ""), (11, 71, "", "second attack")], "the level GMCP said next, and what came with it")
    o.lua("sbo.command('log levels import')")
    assert "0 added" in o.ev("SAYS[#SAYS]"), "not twice"


@test
def tabs_stay_put():
    o = Oven()
    o.lua("""sbo.cfg.window = true; sbo.cfg.tabs = true; sbo.createWindow(); sbo.tabShow('chat')
      sbo.lastUserCmdAt = -1000""")
    # something Oven shows by itself: the Inspector gets it, the Chat tab stays in front, the Inspector marked
    o.lua("sbo.viewOut({ { { 'white', 'a looked-at item' } } }, {})")
    eq(o.ev("sbo.tabOn"), "chat", "not taken away from Chat")
    assert o.ev("sbo.tabNew.view"), "the Inspector marked as new"
    # something you just asked for: it comes to the front
    o.lua("sbo.lastUserCmdAt = os.clock and (getEpoch and getEpoch() or os.clock()) or 0; sbo.viewOut({ { { 'white', 'your eq' } } }, {})")
    eq(o.ev("sbo.tabOn"), "view", "what you asked for comes forward")


@test
def formation_chat():
    o = Oven()
    for line, want in [("Roarke tells the formation 'like... wtf lol'", ("Formation", "Roarke", "like... wtf lol")),
                       ("You tell the formation 'yoy yoy'", ("Formation", "you", "yoy yoy"))]:
        got = o.ev("function(l) return sbo.chatFind(l) end")(line)
        eq(tuple(got) if isinstance(got, tuple) else got, want, line)


@test
def class_plan():
    o = Oven()
    # the redundancy rule, against the game's own analyses
    for counts, units in [("{ monk = 1, priest = 1 }", 1), ("{ monk = 2 }", 2), ("{ monk = 3 }", 5), ("{ monk = 4 }", 9),
                          ("{ monk = 2, priest = 1 }", 3), ("{ monk = 1, priest = 1, druid = 1 }", 2)]:
        eq(o.ev("sbo.classUnits(%s)" % counts), units, counts)
    sk = o.ev("sbo.classPathSkills({ 'monk', 'monk', 'priest' })")
    eq((sk["cure light"].skp, sk["mace"].skp, sk["kick"].skp, sk["hand to hand"].skp), (45, 36, 24, 0), "spells 15 a unit, proficiencies 12, hand to hand none")
    assert "sahuagin" not in list(o.ev("sbo.classPathRaces({ 'monk', 'priest' })").values()), "a sahuagin can't be monk then priest"
    o.lua("""sbo.cfg.char = { class = 'monk', race = 'sahuagin', path = { 'monk' } }
      sbo.viewOut = function(out, links) OUT, LINKS = out, links end
      sbo.classPlan('')""")
    text = o.ev("(function() local s = {} for _, r in ipairs(OUT) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = '\\n' end return table.concat(s) end)()")
    lines = [l for l in text.split("\n") if l.startswith("  ") and not l.strip().startswith("class")]
    assert lines[0].split()[0] == "monk" and "+1410" in lines[0], lines[0]
    assert "not sahuagin" in next(l for l in lines if l.split()[0] == "priest"), "priest last, marked"
    o.lua("sbo.classPlan('mo pri')")
    text = o.ev("(function() local s = {} for _, r in ipairs(OUT) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = '\\n' end return table.concat(s) end)()")
    assert "Class path: monk → priest" in text and "not sahuagin" in text and "Only from priest" in text, text
    # SCC (help 1613), at level 60 in each: a monk with knowledge 22 and vitality 17 is 77.7, capped at 72 (what score said)
    o.lua("sbo.cfg.char.stats = { knowledge = { cur = 22 }, vitality = { cur = 17 }, wisdom = { cur = 14 }, courage = { cur = 14 }, personality = { cur = 9 } }")
    scc, cap, raw = o.ev("function() return sbo.classPathScc({ 'monk' }) end")()
    eq((round(raw, 1), cap, scc), (77.7, 72, 72), "monk alone")
    scc, cap, raw = o.ev("function() return sbo.classPathScc({ 'monk', 'priest' }) end")()
    eq((round(raw, 2), cap, scc), (138.7, 79, 79), "monk, priest: the two added (what the game does), capped")
    eq((o.ev("sbo.classPathToken({ 'monk', 'priest' })"), o.ev("sbo.classPathToken({ 'monk', 'wizard' })"), o.ev("sbo.classPathToken({ 'monk', 'monk' })")),
       (False, True, True), "two mages, or monk again: a token")
    o.lua("sbo.classPlan('monk wizard')")
    text = o.ev("(function() local s = {} for _, r in ipairs(OUT) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = '\\n' end return table.concat(s) end)()")
    assert "needs a greater token" in text and "250 black tourmalines" in text and "SCC:" in text, text
    # what a level gives (help experience): a monk with max vitality 19, knowledge 21, wisdom 16, as a first class:
    # hp 4*19/13 = 5.8 - 1, sp 4*21/12*2 = 14 - 1, st 4*19/11 = 6.9 - 1, practices 4*16/5 + 2.5 + 1 = 16.3 - 1
    o.lua("sbo.cfg.char.stats = { knowledge = { cur = 22, max = 21 }, vitality = { cur = 17, max = 19 }, wisdom = { cur = 14, max = 16 }, courage = { cur = 14, max = 16 }, personality = { cur = 9, max = 14 } }")
    hp, sp, st, pr = o.ev("function() return sbo.classLevelGains('monk', 1, true) end")()
    eq((round(hp, 2), round(sp, 2), round(st, 2), round(pr, 2)), (5.0, 13.0, 5.91, 15.3), "monk, a first class (hp at its minimum 5)")
    hp, sp, st, pr = o.ev("function() return sbo.classLevelGains('paladin', 2, false) end")()
    eq((round(hp, 2), round(sp, 2)), (9.69, 5.0), "paladin second: fighter hp ×2, sp ×0.8 (at the minimum)")


@test
def class_learn():
    o = Oven()
    o.lua("""SENT = {}; send = function(c) SENT[#SENT+1] = c; sbo.onSend(nil, c) end
      SAYS = {}; sbo.log = function(m) SAYS[#SAYS+1] = m end
      gmcp.char = { status = { state = 'playing' } }; sbo.lastStatusPrompt = '<281hp 696sp 457st>'
      sbo.userIdle = function() return true end
      sbo.cfg.char = { class = 'monk' }
      sbo.cfg.classGroups = { monk = 'mage', mage = 'mage', priest = 'cleric', cleric = 'cleric' }
      local q = sbo.quietly; sbo.quietly = function(c, k, fn) QFN = fn; return q(c, k, fn) end""")
    q, total = o.ev("function() return sbo.classLearnQueue() end")()
    eq(list(q.values()), ["monk monk", "priest priest", "monk monk monk", "monk priest", "monk monk monk monk",
        "monk monk priest", "monk priest druid", "priest monk", "monk monk skillsummary"], "each class doubled, and the checks")
    o.lua("sbo.command('class learn')")
    eq(o.ev("SENT[#SENT]"), "skills analyze monk monk", "asked quietly")
    o.lua("QFN({ 'Skills analyzed for: monk/monk', '  kick  ...' }); sbo.quietNext = nil; sbo.cap = nil; runTimers()")
    text = open(o.home + "/oven_classes.txt").read()
    assert "===== analyze monk monk |" in text and "Skills analyzed for" in text, text
    # typing stops it; running it again skips what's saved
    o.lua("sbo.onSend(nil, 'look')")
    eq(o.ev("sbo.classFetch"), None, "stopped when you typed")
    q, total = o.ev("function() return sbo.classLearnQueue() end")()
    eq(list(q.values())[0], "priest priest", "carries on where it stopped")


@test
def score_tail_tidy():
    o = Oven()
    o.lua("sbo.quests['3390'] = { name = 'Cooking Adventurers' }")
    lines = ["Player Information for: Softbuns", "  Hours Played:      107        Age:            15 years (Born 9/17/1504) [Created: In Antiquity]",
      "  Class Level:        60        Total Level:    60", "  Class:           monk         Alignment:      42 (+neutral)",
      "  Hit Points:        426/426    Practices:      122", "  Strength:           13/20     Vitality:       17/19",
      "  Race:               sahuagin  Gender:         non-sexual",
      "* If CPKed, your hoard would be valued at 67,668 gp.", "* You are carrying 13 items weighing 11 stones and 50 pebbles.",
      "* The next phase of quest #3390 is: Phase 10: Keep cooking for players until you obtain the mark of spaghetti-and-pesto.",
      "* The next phase of quest #3519 is: Phase 1: Locate and deliver a brick of cream cheese to the janitor."]
    o.L.globals().SL = o.L.table_from(lines)
    out = o.lua("""local raw = {} for _, l in ipairs(SL) do raw[#raw+1] = l end local l = sbo.format('score', '', raw, 100)
      local s = {} for _, r in ipairs(l) do for _, g in ipairs(r) do s[#s+1] = tostring(g[2]) end s[#s+1] = "\\n" end return table.concat(s)""")
    assert "Quests" in out and "#3390  Cooking Adventurers · step 10" in out and "#3519  step 1" in out, out
    assert "The next phase" not in out, out
    assert "13 items · 11 st 50 pb" in out and "67,668 gp" in out, out
    last = [l for l in out.split("\n") if l.strip()][-1]
    assert last.startswith("107 hours played") and "quest" not in last and "CPK" not in last, last


@test
def bar_room_flags():
    o = Oven()
    o.lua("""sbo.cfg.bar = true; sbo.cfg.maxes = { hp = 300 }; sbo.lastPromptText = "[Library][SAFE]<291hp>"
      sbo.showBar(true)""")
    o.set_gmcp("room.info", '{ num = "28035", flags = "safe, high-regen, no-npcs, reinforced, library, indoors" }')
    o.lua("sbo.drawBar()")
    top = o.ev("(function() local t = {} for _, x in ipairs(sbo.topBarSegs or {}) do t[#t+1] = x[2] end return table.concat(t) end)()")
    assert "high-regen · no-npcs · reinforced" in top, top
    assert "indoors" not in top and "library" not in top and "safe" not in top, f"left out, or the prompt shows it: {top}"
    o.lua('sbo.command("config bar.roomflags off")')
    top = o.ev("(function() local t = {} for _, x in ipairs(sbo.topBarSegs or {}) do t[#t+1] = x[2] end return table.concat(t) end)()")
    assert "high-regen" not in top, top


@test
def next_quest_countdown():
    o = Oven()
    o.lua("""sbo.cfg.bar = true; sbo.cfg.barSession = true; sbo.cfg.maxes = { hp = 300 }; sbo.lastPromptText = "<291hp>"
      sbo.showBar(true); SAYS = {}; sbo.say = function(m) SAYS[#SAYS+1] = m end
      T0 = os.time(); os.time = function() return T0 end""")
    top = lambda: o.ev("(function() local t = {} for _, x in ipairs(sbo.topBarSegs or {}) do t[#t+1] = x[2] end return table.concat(t) end)()")
    o.block(["You have 19 Alyrian minutes remaining until you can request another quest.", "<291hp>"], ["quest request rewarding"])
    eq(o.ev("sbo.cfg.questNextAt - T0"), 19 * 15, "an Alyrian minute is 15 real seconds")
    assert "next quest 4:45" in top(), top()
    o.lua("T0 = T0 + 46; sbo.questNextTick()")
    assert "next quest 3:59" in top(), "counts itself down: " + top()
    o.block(["You have less than an Alyrian minute remaining until you can request another quest.", "<291hp>"], ["quest req"])
    eq(o.ev("sbo.cfg.questNextAt - T0"), 15, "less than a minute: 15 seconds at most")
    o.lua("T0 = T0 + 20; sbo.questNextTick()")
    assert "next quest ready" in top(), top()
    eq(list(o.ev("SAYS").values()), ["you can request another quest now"], "said once")
    o.lua("sbo.questNextTick()")
    eq(len(o.ev("SAYS")), 1, "only once")
    # quest info shows a quest the same way: not a quest taken
    o.block(["This quest [146] is called 'Prodigal Psionics',", "for Adventurers levels 90 to 120.", "<291hp>"], ["quest info 146"])
    assert "next quest ready" in top(), "quest info isn't taking one: " + top()
    o.block(["You ask Lord Vendredi for a quest.", "This quest [146] is called 'Prodigal Psionics',", "for Adventurers levels 90 to 120.",
             "You have 160 Alyrian minute remaining to complete this quest.", "<291hp>"], ["quest request rewarding"])
    eq(o.ev("sbo.cfg.questNextAt"), None, "a quest taken: gone")
    assert "next quest" not in top(), top()
    o.lua("sbo.cfg.questNextAt = T0 - 5"); o.block(["You undertake the quest 'Daily Quest - Feeding Hungry Mouths', #3519.", "<291hp>"], [])
    eq(o.ev("sbo.cfg.questNextAt"), None, "a quest handed to you: gone too")
    # 'ready' isn't kept forever
    o.lua("sbo.cfg.questNextAt = T0 + 30; T0 = T0 + 30 + 601; sbo.questNextTick()")
    eq(o.ev("sbo.cfg.questNextAt"), None, "ready shown ten minutes, then gone")


@test
def top_bar():
    o = Oven()
    o.lua("""sbo.cfg.bar = true; sbo.cfg.barSession = true; sbo.cfg.maxes = { hp = 300, sp = 700, st = 460 }
      sbo.lastPromptText = "[SAFE][Mail]<291hp 696sp 457st>"
      sbo.cfg.char = { level = 57, tnl = 12000 }
      sbo.showBar(true)""")
    top = o.ev("(function() local t = {} for _, x in ipairs(sbo.topBarSegs or {}) do t[#t+1] = x[2] end return table.concat(t) end)()")
    bottom = o.ev("WIDGETS.ovenPromptBarLabel.html") or ""
    import re as _re
    bottom = _re.sub("<[^>]+>", "", bottom)
    assert "Mail" in top and "L57" in top and "xp/hr" in top, top
    assert "SAFE" in bottom and "HP" in bottom and "Mail" not in bottom and "L57" not in bottom, bottom
    assert o.ev("WIDGETS.ovenSessionBarLabel.shown") and o.ev("getBorderTop()") > 0, "the top line takes room at the top"
    # rows left over (updates, Mudlet keeping the border): exactly one row at the very top, however many there were
    h = o.ev("getBorderTop()")
    for left in (h, 3 * h):
        o2 = Oven(prev="setBorderTop(%d)" % left)
        o2.lua("""sbo.cfg.bar = true; sbo.cfg.maxes = { hp = 300, sp = 700, st = 460 }; sbo.lastPromptText = "<291hp 696sp 457st>"; sbo.showBar(true)""")
        eq((o2.ev("getBorderTop()"), o2.ev("WIDGETS.ovenSessionBarLabel.y")), (h, 0), f"one row at the top (border was {left})")
    # the same background as the prompt bar, also after a colour change
    eq(o.ev("WIDGETS.ovenSessionBarLabel.css"), o.ev("WIDGETS.ovenPromptBarLabel.css"), "same colour")
    o.lua("sbo.command('bar bg 40 10 10')")
    eq(o.ev("WIDGETS.ovenSessionBarLabel.css"), o.ev("WIDGETS.ovenPromptBarLabel.css"), "same colour after a change")
    # top bar off, a row left over from before: given back
    o4 = Oven(prev="setBorderTop(40)")
    o4.lua("""sbo.cfg.bar = true; sbo.cfg.barTop = false; sbo.cfg.maxes = { hp = 300 }; sbo.lastPromptText = "<291hp>"; sbo.showBar(true)""")
    eq(o4.ev("getBorderTop()"), 0, "no leftover row")
    # off: all on the prompt bar again
    o.lua("sbo.command('config bar.top off')")
    bottom = _re.sub("<[^>]+>", "", o.ev("WIDGETS.ovenPromptBarLabel.html") or "")
    assert "Mail" in bottom and "L57" in bottom, bottom


@test
def bar_leaves_questions():
    o = Oven()
    o.lua('''sbo.cfg.bar = true; sbo.cfg.promptPattern = "[<?]"; GONE = {}
      local nop = function() end
      sbo.bar = { rawEcho = function(self, h) BAR = h end, move = nop, resize = nop, show = nop, hide = nop, setStyleSheet = nop }
      sbo.barRight = getBorderRight()
      deleteLine = function() GONE[#GONE + 1] = line end''')
    o.feed("[Mail]<291hp 696sp 457st>")
    eq(list(o.ev("GONE").values()), ["[Mail]<291hp 696sp 457st>"], "your prompt goes to the bar")
    o.lua("GONE = {}")
    o.feed("Do you really want to quit (y/N)?")
    eq(list(o.ev("GONE").values()), [], "a question stays in the game text")
    eq(o.ev("sbo.lastPromptText"), "[Mail]<291hp 696sp 457st>", "the bar keeps your last prompt")


@test
def notes_off_the_bar():
    o = Oven()
    o.lua('''sbo.cfg.bar = true; LOG = {}; sbo.log = function(m) LOG[#LOG + 1] = m end
      local nop = function() end
      sbo.bar = { rawEcho = function(self, h) BAR = h end, move = nop, resize = nop, show = nop, hide = nop, setStyleSheet = nop }
      sbo.lastPromptText = "[Mail]<291hp 696sp 457st>"
      sbo.quests = { ["52"] = { name = "Jail Time", total = 4, done = 1, phases = {} } }
      sbo.cfg.questPins = { ["52"] = true }
      CARDS = {}
      local old = Geyser.Label.new
      Geyser.Label.new = function(self, c, p) local t = old(self, c, p); t.rawEcho = function(x, m) CARDS[c.name] = m end; return t end
      sbo.notifyQuest("Jail Time: step 1 done (1/4)")
      sbo.notifyWalk("arrived")
      sbo.drawBar()''')
    bar = o.ev("BAR") or ""
    assert "step 1 done" not in bar and "arrived" not in bar, "nothing on the bar but the prompt"
    assert "step 1 done" in (o.ev("CARDS.ovenQuestLine1_1") or ""), "the quest note is on the quest HUD"
    assert any("walk arrived" in m for m in o.ev("LOG").values()), "the walk note is a line in the game text"


@test
def panel_layout_kept():
    o = Oven(before='''
      Adjustable.Container.new = function(self, o)
        local t = { name = o.name, gx = 100, gy = 50, gw = 400, gh = 300, saves = 0 }
        function t:show() end function t:hide() end
        function t:get_x() return t.gx end function t:get_y() return t.gy end
        function t:get_width() return t.gw end function t:get_height() return t.gh end
        local function px(v, total) if type(v) == "string" then return tonumber(v:match("[%d%.]+")) / 100 * total end return v end
        function t:move(x, y) t.gx, t.gy = px(x, 1600), px(y, 900) end
        function t:resize(w, h) t.gw, t.gh = px(w, 1600), px(h, 900) end
        function t:save() t.saves = t.saves + 1 end
        return t
      end''')
    o.lua('sbo.cfg.window = true; sbo.createWindow(); C = sbo.container')
    # you drag and resize the Inspector
    o.lua('C.gx, C.gy, C.gw, C.gh = 800, 90, 640, 450; sbo.panelsSave()')
    f = dict(o.ev("sbo.cfg.panels.ovenViewer").items())
    eq((round(f["x"], 3), round(f["w"], 3)), (0.5, 0.4), "saved as parts of the window")
    eq(o.ev("C.saves") >= 1, True, "Mudlet's own copy saved too")
    # something else moves it on connect; Oven puts it back
    o.lua('C.gx, C.gy = 0, 0; handlers["sysConnectionEvent"](); runTimers()')
    eq((round(o.ev("C.gx")), round(o.ev("C.gy"))), (800, 90), "put back after connecting")
    # a new session: the window is made in its saved place
    o.lua('sbo.container = nil; sbo.createWindow()')
    eq(round(o.ev("sbo.container.gx")), 800, "made where you left it")
    o.lua('sbo.command("layout reset")')
    eq(o.ev("sbo.cfg.panels"), None, "reset forgets it")


@test
def combat_mxp_lines():
    o = Oven()
    o.lua('''OUT = {}
      decho = function(w, t) if t == nil then t = w end OUT[#OUT + 1] = (t:gsub("<[^>]+>", "")) end
      local function round(t) gmcp.char = gmcp.char or {}; gmcp.char.combat_mxp = t; handlers["gmcp.char.combat_mxp"]() end
      -- as recorded: "a mental patient", a round where you hit and it missed
      round({ opponent_hp_percent = 27, opponent_hits = 0, your_hp_percent = 100, your_weapon_range = 2, you_defend = 0,
              opponent_misses = 1, opponent_name = "a mental patient", opponent_defends = 0, you_hit = 1, you_miss = 0, distance_to_opponent = 2 })
      round({ opponent_hp_percent = 5, opponent_hits = 1, your_hp_percent = 92, your_weapon_range = 2, you_defend = 1,
              opponent_misses = 0, opponent_name = "a mental patient", opponent_defends = 1, you_hit = 2, you_miss = 1, distance_to_opponent = 3 })''')
    o.feed("A mental patient has been slain!")
    o.L.execute("runTimers()")
    out = list(o.ev("OUT").values())
    eq(len(out), 3, f"two rounds and a summary: {out}")
    assert "a mental patient" in out[0] and "27%" in out[0] and "you 1 hit" in out[0] and "it 1 missed" in out[0], out[0]
    assert "out of reach" in out[1], out[1]
    assert "slain" in out[2] and "2 rounds" in out[2] and "you hit 3/5" in out[2] and "it hit 1/3" in out[2], out[2]
    # the dummy fight, as recorded: you hit, you miss... then flee east - no char.status at all
    o.lua('''OUT = {}; gmcp.room = { info = { num = "10422", name = "Combat Training" } }
      local function round(hit) gmcp.char.combat_mxp = { opponent_hp_percent = 100, opponent_hits = 0, your_hp_percent = 100, your_weapon_range = 2,
        you_defend = 0, opponent_misses = 0, opponent_name = "a practice dummy", opponent_defends = 0, you_hit = hit, you_miss = 1 - hit, distance_to_opponent = 2 }
        handlers["gmcp.char.combat_mxp"]() end
      round(1); round(0); round(1)
      gmcp.room.info = { num = "10542", name = "Antechamber" }; handlers["gmcp.room.info"]()''')
    out = list(o.ev("OUT").values())
    eq(len(out), 4, f"three rounds and a summary: {out}")
    assert "you left" in out[3] and "3 rounds" in out[3] and "you hit 2/3" in out[3], out[3]
    # no rounds for a while (combat mode normal mid-fight): summary from the timer
    o.lua('OUT = {}; round = nil; gmcp.char.combat_mxp.opponent_name = "a rat"; handlers["gmcp.char.combat_mxp"](); runTimers()')
    out = list(o.ev("OUT").values())
    assert len(out) == 2 and "a rat" in out[1] and "1 round" in out[1], out
    # two at once, rounds alternating: no summary until each one is done
    o.lua('''OUT = {}
      local function round(name, hit) gmcp.char.combat_mxp = { opponent_hp_percent = 50, opponent_hits = 1, your_hp_percent = 90, your_weapon_range = 2,
        you_defend = 0, opponent_misses = 0, opponent_name = name, opponent_defends = 0, you_hit = hit, you_miss = 1 - hit, distance_to_opponent = 1 }
        handlers["gmcp.char.combat_mxp"]() end
      round("a goblin", 1); round("a wolf", 0); round("a goblin", 1); round("a wolf", 1)''')
    eq(len(list(o.ev("OUT").values())), 4, "four round lines, no summaries in between")
    o.feed("A goblin has been slain!")
    o.lua("runTimers()")
    out = list(o.ev("OUT").values())
    summ = [x for x in out if "rounds" in x or "round " in x and "·" in x]
    assert any("a goblin" in x and "slain" in x and "2 rounds" in x and "you hit 2/2" in x for x in out), out
    assert any("a wolf" in x and "2 rounds" in x and "you hit 1/2" in x for x in out), "the wolf's own summary (its rounds stopped)"
    o.lua('OUT = {}; sbo.command("combat off"); gmcp.char.combat_mxp.opponent_name = "a rat"; handlers["gmcp.char.combat_mxp"]()')
    eq(list(o.ev("OUT").values()), [], "sbo combat off")


@test
def combat_line_in_place():
    o = Oven()
    # a fake main window: decho appends to BUF, the last entry is the line being written
    o.lua('''BUF = { "" }
      decho = function(w, t) if t == nil then t = w end t = t:gsub("<[^>]+>", "")
        local parts = {} for seg in (t .. "\\n"):gmatch("([^\\n]*)\\n") do parts[#parts + 1] = seg end
        BUF[#BUF] = BUF[#BUF] .. parts[1]
        for i = 2, #parts do BUF[#BUF + 1] = parts[i] end end
      getCurrentLine = function() return BUF[#BUF] end
      function GAME(t) BUF[#BUF] = BUF[#BUF] .. t; BUF[#BUF + 1] = "" end
      function ROUND(pct, dist) gmcp.char = gmcp.char or {}; gmcp.char.combat_mxp = { opponent_hp_percent = pct, opponent_hits = 0,
        your_hp_percent = 100, your_weapon_range = 2, you_defend = 0, opponent_misses = 1, opponent_name = "a mental patient",
        opponent_defends = 0, you_hit = 1, you_miss = 0, distance_to_opponent = dist or 2 }; handlers["gmcp.char.combat_mxp"]() end
      sbo.lastPromptText = "<281hp 696sp 457st>"''')
    o.lua('ROUND(90); GAME(""); GAME("<281hp 696sp 457st>"); ROUND(70); GAME(""); ROUND(50)')
    buf = [x for x in o.ev("BUF").values() if x.strip()]
    fights = [x for x in buf if x.startswith("⚔")]
    eq(len(fights), 1, f"one line for the fight: {buf}")
    assert "50%" in fights[0] and "▼20" in fights[0] and "round 3" in fights[0] and "~3 to go" in fights[0], fights[0]
    assert "<281hp" in buf[0], f"the prompt stays: {buf}"
    # other game text in between: a new line from then on
    o.lua('GAME("A mental patient screams in pain."); ROUND(40, 3)')
    fights = [x for x in o.ev("BUF").values() if x.startswith("⚔")]
    eq(len(fights), 2, "a new line after other text")
    assert "out of reach (3 › 2)" in fights[1], fights[1]
    # killed: the exp and gold go in the summary, which takes the fight line's place
    o.feed("A mental patient has been slain!")
    o.feed("You receive 1,444 experience points.")
    o.feed("You take 146 gold coins.")
    o.lua("runTimers()")
    fights = [x for x in o.ev("BUF").values() if x.startswith("⚔")]
    eq(len(fights), 2, f"the summary replaced the live line: {fights}")
    s = fights[1]
    assert "slain" in s and "4 rounds" in s and "+1,444 xp" in s and "+146 gold" in s, s


@test
def combat_bar():
    o = Oven()
    o.lua('''sbo.cfg.bar = true; BARS = {}
      local nop = function() end
      sbo.bar = { rawEcho = function(self, h) end, move = nop, resize = nop, show = nop, hide = nop, setStyleSheet = nop }
      local old = Geyser.Label.new
      Geyser.Label.new = function(self, c, p) local t = old(self, c, p)
        t.rawEcho = function(x, m) BARS[c.name] = (m:gsub("<[^>]+>", "")) end
        t.move = function(x, a, b) t.y = b end; t.resize = nop; t.show = function() t.shown = true end; t.hide = function() t.shown = false end
        return t end
      decho = nop
      function ROUND(name, pct, hit) gmcp.char = gmcp.char or {}; gmcp.char.combat_mxp = { opponent_hp_percent = pct, opponent_hits = 0, your_hp_percent = 100,
        your_weapon_range = 2, you_defend = 0, opponent_misses = 1, opponent_name = name, opponent_defends = 0, you_hit = hit, you_miss = 1 - hit,
        distance_to_opponent = 1 }; handlers["gmcp.char.combat_mxp"]() end
      ROUND("a mental patient", 62, 1)''')
    bar = o.ev("BARS.ovenCombatBarLabel") or ""
    assert "62%" in bar and "a mental patient" in bar and bar.index("62%") < bar.index("a mental patient"), f"health bar, then the name: {bar}"
    assert "you hit 1/1" in bar, bar
    eq(o.ev("sbo.cbar.shown"), True, "shown while fighting")
    eq(o.ev("sbo.cbar.y < 900 - 20"), True, "above the prompt bar")
    o.lua('gmcp.char.combat_mxp.opponent_hp_percent = 50; gmcp.char.combat_mxp.distance_to_opponent = 3; handlers["gmcp.char.combat_mxp"]()')
    bar = o.ev("BARS.ovenCombatBarLabel")
    assert "▼12" in bar and "OUT OF REACH (3 › 2)" in bar and "~5 to go" in bar, bar
    o.lua('ROUND("a wolf", 30, 0)')
    bar = o.ev("BARS.ovenCombatBarLabel")
    assert bar.index("a wolf") < bar.index("others:") < bar.index("a mental patient 50%"), f"the latest in full, the other compressed: {bar}"
    # twenty of them: as many as fit, lowest health first, then "+N more"
    o.lua('for i = 1, 20 do ROUND("a goblin " .. i, 100 - i * 4, 1) end; ROUND("a wolf", 30, 1)')
    bar = o.ev("BARS.ovenCombatBarLabel")
    assert "more" in bar and len(bar) < 200, f"fits on one line: {bar}"
    others = bar.split("others: ")[1]
    assert others.startswith("a goblin 20 20%"), f"lowest health first: {others}"
    o.feed("A mental patient has been slain!"); o.feed("A wolf has been slain!")
    o.lua("for i = 1, 20 do line = 'A goblin ' .. i .. ' has been slain!'; sbo.onLine() end")
    eq(o.ev("sbo.cbarShown"), False, "gone the moment the last one dies (no timers run)")
    o.lua("runTimers()")
    eq(o.ev("sbo.cbar.shown"), False, "gone once the fights are over")
    o.lua('sbo.command("combat bar off"); ROUND("a rat", 90, 1)')
    eq(o.ev("sbo.cbar.shown"), False, "sbo combat bar off")


@test
def update_follows_main():
    o = Oven()
    a, b = "a" * 40, "b" * 40
    def tip(body):
        open(o.ev("sbo.dl.api"), "w").write(body)
        o.lua('URLS = {}; downloadFile = function(p, u) URLS[#URLS + 1] = u end; sbo.pending = "check"; sbo.onDownload("sysDownloadDone", sbo.dl.api)')
        return o.ev("sbo.updSha"), o.ev("URLS[1]")
    sha, url = tip(f"0040{b} refs/heads/main-old\n003f{a} refs/heads/main\n0000")
    eq(sha, a, "latest commit on main")
    assert url.endswith(f"/{a}/VERSION"), url


@test
def upgrade_in_session():
    prev = previous_release()
    if not prev:
        return "skipped (no previous release in git)"
    o = Oven(prev=prev.replace("@@REPO@@", "x/y"), src="CREATED = {}\n" + SRC)
    o.lua('sbo.showHelp("item", {" [1087] general"}) sbo.viewAdd({lines={{{"white","eq"}}}, links={}}) sbo.command("") sbo.command("")')
    made = list(o.ev("CREATED").values())
    bad = [m for m in made if "MAIN SCREEN" in m]
    assert not bad, f"panels on the main screen after upgrading: {bad}"
    return f"from v{re.search(r'M.version = \"([^\"]+)\"', prev).group(1)}"


def previous_release():
    """The last committed Oven.lua that differs from the working copy."""
    for ref in ("HEAD", "HEAD~1"):
        try:
            s = subprocess.run(["git", "show", f"{ref}:src/Oven.lua"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
        except Exception:
            return None
        if s.replace("@@REPO@@", "x/y") != SRC:
            return s
    return None


def main():
    words = sys.argv[1:]
    failed = 0
    for t in TESTS:
        if words and not any(w in t.__name__ for w in words):
            continue
        try:
            note = t()
            print(f"  ok    {t.__name__}" + (f"  ({note})" if note else ""))
        except Exception as e:
            failed += 1
            print(f"  FAIL  {t.__name__}: {e}")
            if not isinstance(e, AssertionError):
                traceback.print_exc()
    print(f"{failed} failed" if failed else "all passed")
    return 1 if failed else 0


if __name__ == "__main__":
    os.chdir(ROOT)
    sys.exit(main())
