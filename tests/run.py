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
        eq(o.ev("sbo.quests['100'].active"), False, f"main={main}: old quest inactive")
        # quest info for one quest by number says nothing about the others
        o.lua('sbo.questPin("3098", true); sbo.quests["100"].active = true; sbo.onSend(nil, "quest info 3098")')
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
      function FRONT() local f = {} for _, k in ipairs({ "view", "help", "log", "chat" }) do if WIDGETS["ovenTabs2Page_" .. k].shown then f[#f + 1] = k end end return table.concat(f, ",") end''')
    o.lua('sbo.viewAdd({ lines = { { { "white", "an item" } } }, links = {} })')
    eq(o.ev("FRONT()"), "view", "an item: Inspector tab")
    o.lua('sbo.showHelp("classes", { "[1065 ] CLASSES", "Character classes in Alyria are as follows:" })')
    eq(o.ev("FRONT()"), "help", "a help page: Help tab")
    eq(o.ev("sbo.helpContainer"), None, "no separate help window")
    assert "(in window)" in o.ev("CREATED[#CREATED]"), "help page built inside the window"
    o.lua('sbo.command("session")')
    eq(o.ev("FRONT()"), "log", "session: Log tab")
    o.lua('sbo.command("kills")'); eq(o.ev("FRONT()"), "log", "kills: Log tab")
    o.lua('WIDGETS.ovenTabs2_view.click()'); eq(o.ev("FRONT()"), "view", "clicking a tab")
    o.lua('sbo.command("tab help")'); eq(o.ev("FRONT()"), "help", "sbo tab help")
    eq(o.ev("WIDGETS.ovenTabs2_help.css").count("e6c35c"), 1, "the front tab is highlighted")
    o.lua('sbo.command("tabs off")')
    eq(o.ev("WIDGETS.ovenTabs2Box.shown"), False, "tabs off hides the bar")
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
    eq(o.ev("WIDGETS.ovenTabs2Page_view.shown"), True, "chat doesn't take the window's focus")
    eq(o.ev("WIDGETS.ovenTabs2_chat.text"), "<center>Chat (8)</center>", "unread count on the tab")
    o.lua('sbo.command("tab chat")')
    eq(o.ev("WIDGETS.ovenTabs2_chat.text"), "<center>Chat</center>", "read once the tab is open")
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
def tabs_auto_off():
    o = Oven()
    o.lua('''sbo.cfg.window = true
      function FRONT() local f = {} for _, k in ipairs({ "view", "help", "log", "chat" }) do if WIDGETS["ovenTabs2Page_" .. k].shown then f[#f + 1] = k end end return table.concat(f, ",") end
      sbo.viewAdd({ lines = { { { "white", "an item" } } }, links = {} })
      sbo.command("tabs auto off")''')
    eq(o.ev("sbo.cfg.tabAuto"), False, "setting saved")
    o.lua('sbo.showHelp("classes", { "[1065 ] CLASSES", "Character classes" })')
    eq(o.ev("FRONT()"), "view", "a help page doesn't take the window")
    eq(o.ev("WIDGETS.ovenTabs2_help.text"), "<center>Help •</center>", "the Help tab is marked")
    assert "(in window)" in o.ev("CREATED[#CREATED]"), "the page was still drawn in its tab"
    o.lua('sbo.command("tab help")')
    eq((o.ev("FRONT()"), o.ev("WIDGETS.ovenTabs2_help.text")), ("help", "<center>Help</center>"), "looking clears the mark")
    o.lua('sbo.viewAdd({ lines = { { { "white", "another" } } }, links = {} })')
    eq((o.ev("FRONT()"), o.ev("WIDGETS.ovenTabs2_view.text")), ("help", "<center>Inspector •</center>"), "an item while reading help")
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
    for cmd, setting, want in (("quest request", "on", True), ("que req", "on", True), ("quest request", "off", None), ("quest info 1547", "on", None)):
        o = Oven()
        o.lua(f'sbo.cfg.promptPattern = "<%d+hp"; sbo.command("quest autopin {setting}"); sbo.onSend(nil, "{cmd}")')
        o.feed(*reply, "<270hp 550sp 401st>")
        o.L.execute("runTimers()")
        eq(o.ev("(sbo.cfg.questPins or {})['1547']"), want, f"{cmd} with autopin {setting}")
        eq(o.ev("sbo.quests['1547'] and sbo.quests['1547'].name"), "War and Peace", "the quest is read either way")


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
    eq(list(o.ev("SENT").values()), ["quest info 52"], "no GMCP with it: quest info 52, quietly")


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
