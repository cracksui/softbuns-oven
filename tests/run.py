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
    eq(o.ev("WIDGETS.ovenTabs3_help.css").count("e6c35c"), 1, "the front tab is highlighted")
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
    eq(list(o.ev("sbo.cfg.chatChannels").values()), ["CLAN", "Tells", "YELL", "ANNOUNCEMENT", "HINT", "NOVICE"], "channels learned in order")
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
    assert "line-through" in o.ev("WIDGETS.ovenChatChip2.css"), "muted chip is struck through"
    o.lua('sbo.chatFilter("CLAN")')
    assert "Moss" in o.ev("WIDGETS.ovenChatConsole.text"), "a muted channel can still be read on its own"


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
    assert "quest 40m" in plain or "quest 39m" in plain, plain
    assert "8h" not in plain, f"just the soonest: {plain}"
    assert plain.find("quest") < plain.find("HP"), f"at the left: {plain}"
    # the panel: each pinned quest's time
    o.lua("sbo.cfg.questPins = { ['52'] = true, ['3519'] = true }")
    card = o.lua("local h = sbo.questCardHtml('3519', sbo.quests['3519']); return table.concat(h, '\\n')")
    assert "8h1" in _re.sub("<[^>]+>", "", card) and "left" in card, card
    # turned in: no more timer
    o.lua("sbo.quests['52'].active = false")
    o.lua("sbo.drawBar()")
    plain = _re.sub("<[^>]+>", "", o.ev("BAR") or "")
    assert "quest 8h" in plain, f"the next soonest: {plain}"


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
      local function it(n, str) return { name = n, worn = "on body", level = 1, affects = { { "strength", tostring(str) } }, ar = 1, raw = {} } end
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
    eq(col, "light_sky_blue|$ the Sushi Bar", "a shop with its stock: the usual $ line")
    # not again within the hour; not in a room without a shop
    o.lua("SENT = {}; ARRIVE(1); ARRIVE(10515)")
    eq(len(o.ev("SENT")), 0, "once; none elsewhere")
    # not while walking through, not when switched off
    o.lua("SENT = {}; sbo.shopTried = {}; sbo.dbx('DELETE FROM shops'); sbo.running = { name = 'rune', started = true }; ARRIVE(1); ARRIVE(10515); sbo.running = nil")
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
    eq(col, "tomato", "the shop's $ line in red: won't sell to you")
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


WHERE_LIST = """Where is what? Features that Towne of Rune might contain that you may be interested in:
healer              post-office         lockers             bank                
food                blacksmith          questmaster         music-venue         
When you do find what you're looking for, you might also try WHERE IS <feature> TRACK to track towards your destination automatically."""


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
      WALKED = nil; sbo.mapWalkTo = function(id) WALKED = id end''')
    o.lua('sbo.command("notes")')
    eq(o.ev("WIDGETS['ovenTabs3Page_notes'].shown"), True, "sbo notes: the Notes tab")
    # typed in the box
    o.lua('WIDGETS["ovenNotesInput"].action("cook gives pesto for 250 gold")')
    eq(o.rows("SELECT text, room, room_name, area FROM notes"),
       [{"text": "cook gives pesto for 250 gold", "room": 28840, "room_name": "Palace Kitchen and Bakery", "area": "Palace of Diocletian"}], "kept, with where")
    o.lua('sbo.command("notes add the daily resets at midnight")')
    text = o.ev("WIDGETS['ovenNotesConsole'].text")
    assert "cook gives pesto" in text and "daily resets" in text and "Palace Kitchen" in text, text
    # its links: walk there, delete
    links = o.ev("WIDGETS['ovenNotesConsole'].links")
    go = [l for l in links.values() if "[go]" in l[1]][0]
    go[2]()
    eq(o.ev("WALKED"), 28840, "[go] walks to where it was written")
    o.lua('sbo.command("notes find pesto")')
    text = o.ev("WIDGETS['ovenNotesConsole'].text")
    assert "pesto" in text and "daily resets" not in text, text
    o.lua('sbo.command("notes remove 1")')
    eq(len(o.rows("SELECT id FROM notes")), 1, "removed")
    # kept for good: in the database
    eq(o.rows("SELECT text FROM notes"), [{"text": "the daily resets at midnight"}], "in the database")


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
      local function it(n, ar, str) return { name = n, worn = "on body", level = 1, affects = { { "strength", tostring(str) } }, ar = ar, raw = {} } end
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
    assert "+4 strength" in mine, f"why: the stats that make the difference: {mine}"
    eq(o.ev("#sbo.viewHist[#sbo.viewHist].links") >= 1, True, "a link per upgrade")
    o.lua('sbo.command("upgrades compare 1")')
    page = o.ev("WIDGETS[sbo.viewPg.prefix .. sbo.viewPg.flip .. 'Label'].html")
    assert "Score breakdown" in page and "a bagged hauberk" in page, "sbo upgrades compare 1: the full comparison"
    o.lua('sbo.viewHist[#sbo.viewHist - 1].links[1][2]()')   # the link on the list does the same
    assert "Score breakdown" in o.ev("WIDGETS[sbo.viewPg.prefix .. sbo.viewPg.flip .. 'Label'].html")


@test
def compare_score_breakdown():
    o = Oven()
    o.lua('''
      local function it(n, aff) return { name = n, worn = "on body", level = 1, affects = aff, raw = {} } end
      A = it("a vest", { { "strength", "1" }, { "hp", "20" } })
      B = it("a hauberk", { { "strength", "4" } })
      local t = {} for _, r in ipairs(sbo.compareLines(A, B, 90)) do local x = {} for _, seg in ipairs(r) do x[#x+1] = seg[2] end t[#t+1] = table.concat(x) end
      TEXT = table.concat(t, "\\n")
      PA, PB = sbo.scoreParts(A), sbo.scoreParts(B)''')
    text = o.ev("TEXT")
    assert "Score breakdown" in text, text
    total = lambda p: round(sum(x.points for x in p.values()), 1)
    eq((total(o.ev("PA")), total(o.ev("PB"))), (o.ev("sbo.gearScore(A)"), o.ev("sbo.gearScore(B)")), "the parts add up to the score")
    row = [l for l in text.split("\n") if l.startswith("strength") and "×" in l]
    assert row and "+1×" in row[0] and "+4×" in row[0], row


@test
def quest_request_pins():
    reply = open(fixture("quest_request.txt"), encoding="utf-8").read().rstrip("\n").split("\n")
    for cmd, setting, want in (("quest request", "on", True), ("que req", "on", True), ("que re", "on", True), ("quest request", "off", None), ("quest info 1547", "on", None)):
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
    assert "Rewards" in panel and "25,000 gold pieces" in panel and "a velocity token" in panel, panel
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
    assert "rgb(152,251,152)\">The Entrance to Rune Prison" in exact, exact
    assert "rgb(255,165,0)\">The Edible Loaf" in guess, guess


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
    assert "Mail" in plain, "the prompt's tags stay"
    o.lua('gmcp.char.vitals.hp = 80; handlers["gmcp.char.vitals"]()')
    plain = __import__("re").sub("<[^>]+>", "", o.ev("BAR") or "")
    assert " 80" in plain, f"redrawn when vitals change, no prompt needed: {plain}"


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
    assert "step 1 done" in (o.ev("CARDS.ovenQuestCard1") or ""), "the quest note is on the quest HUD"
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
    o.lua('ROUND("a wolf", 30, 0)')
    bar = o.ev("BARS.ovenCombatBarLabel")
    assert bar.index("a wolf") < bar.index("others:") < bar.index("a mental patient 62%"), f"the latest in full, the other compressed: {bar}"
    # twenty of them: as many as fit, lowest health first, then "+N more"
    o.lua('for i = 1, 20 do ROUND("a goblin " .. i, 100 - i * 4, 1) end; ROUND("a wolf", 30, 1)')
    bar = o.ev("BARS.ovenCombatBarLabel")
    assert "more" in bar and len(bar) < 200, f"fits on one line: {bar}"
    others = bar.split("others: ")[1]
    assert others.startswith("a goblin 20 20%"), f"lowest health first: {others}"
    o.feed("A mental patient has been slain!"); o.feed("A wolf has been slain!")
    o.lua("for i = 1, 20 do line = 'A goblin ' .. i .. ' has been slain!'; sbo.onLine() end; runTimers()")
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
