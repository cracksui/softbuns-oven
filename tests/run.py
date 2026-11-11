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
        self.L.execute("sbo.cfg.samples = false")
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
    for c in ["", "session", "test", "deaths", "record window", "kills", "gear"]:
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
    eq(o.ev("SENT[1]"), "quest", "asks for the quest log first")
    eq(o.ev("next(sbo.cfg.questPins)"), None, "nothing pinned before the log is seen")
    o.lua('''sbo.rememberQuests({ list = { { id = "200", name = "Current", done = 0, total = 3 },
                                           { id = "300", name = "New", done = 1, total = 2 } }, other = {} })''')
    pins = sorted(o.ev("sbo.cfg.questPins").keys())
    eq(pins, ["200", "300"], "pin all, once the log arrives: only quests in it")
    o.lua('sbo.command("quest pin all")')
    eq(sorted(o.ev("sbo.cfg.questPins").keys()), ["200", "300"], "pin all again doesn't bring back a dropped quest")
    o.lua('''gmcp.char = { quests = { q300 = { quest_info = { vnum = 300, name = "New", abandoned = true, completed = false } } } }
             sbo.onGmcpQuests()''')
    eq(sorted(o.ev("sbo.cfg.questPins").keys()), ["200"], "abandoning a quest unpins it")
    o.lua('sbo.command("quest pin all")')
    eq(sorted(o.ev("sbo.cfg.questPins").keys()), ["200"], "an abandoned quest isn't pinned again")
    o.lua('''gmcp.char.quests = { q200 = { quest_info = { vnum = 200, name = "Current", abandoned = false, completed = true } } }
             sbo.onGmcpQuests()''')
    eq(o.ev("sbo.quests['200'].complete"), True, "completion from GMCP")


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
    o.lua('sbo.showHelp("item", {" [1087] general"}) sbo.viewAdd({lines={{{"white","eq"}}}, links={}}) sbo.command("") sbo.command("test")')
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
