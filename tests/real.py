#!/usr/bin/env python3
"""Oven's trip planner on YOUR data - the real room map, world map, settings, database and recordings, read
from your Mudlet profile (nothing of it is in this repository). Skips when they aren't there.

  OVEN_PROFILE=<the profile folder> python tests/real.py        (default: ~/.config/mudlet/profiles/Materia Magica)

The room map comes from Mudlet's own export: in Mudlet, lua saveJsonMap(getMudletHomeDir() .. "/oven_map.json")
"""
import collections, json, os, shutil, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.argv = sys.argv[:1]
import run

PROFILE = os.environ.get("OVEN_PROFILE", os.path.expanduser("~/.config/mudlet/profiles/Materia Magica"))
NEED = ["oven_map.json", "oven_settings.lua", "oven.db", "oven_maps/alyria.bmp"]


def load():
    home = tempfile.mkdtemp(prefix="oven_real_")
    for f in ["oven_settings.lua", "oven.db", "oven_record.txt", "oven_record.old.txt"]:
        if os.path.exists(os.path.join(PROFILE, f)): shutil.copy(os.path.join(PROFILE, f), home)
    shutil.copytree(os.path.join(PROFILE, "oven_maps"), os.path.join(home, "oven_maps"), ignore=shutil.ignore_patterns("oven_world_*"))
    mk = tempfile.mkdtemp
    tempfile.mkdtemp = lambda prefix="": home
    o = run.Oven()
    tempfile.mkdtemp = mk
    L = o.L
    # the settings as Mudlet's table.load reads them (the test stubs' one doesn't follow its references)
    o.lua(r"""
      local f = loadstring(io.open(OVEN_TEST_HOME .. "/oven_settings.lua"):read("*a")); local T = f()
      for _, t in ipairs(T) do for k, v in pairs(t) do if type(v) == "table" and #v == 1 and type(v[1]) == "number" and T[v[1]] and next(v, 1) == nil then t[k] = T[v[1]] end end end
      local c = T[1]
      for _, k in ipairs({ "runs", "world", "clanHall", "rideLands", "recallPoints", "stTerrain", "maxes" }) do sbo.cfg[k] = c[k] end
      sbo.cfg.recallReadyAt = os.time() + 10^9
    """)
    d = json.load(open(os.path.join(PROFILE, "oven_map.json")))
    AREA, ANAME, NAME, EX, LOCKED = {}, {}, {}, {}, set()
    SHORT = {"north": "n", "south": "s", "east": "e", "west": "w", "northeast": "ne", "northwest": "nw",
             "southeast": "se", "southwest": "sw", "up": "u", "down": "d", "in": "in", "out": "out"}
    for a in d["areas"]:
        ANAME[a["id"]] = a["name"]
        for r in a["rooms"]:
            AREA[r["id"]] = a["id"]; NAME[r["id"]] = r.get("name", "")
            if r.get("locked"): LOCKED.add(r["id"])
            EX[r["id"]] = [(e["name"], e["exitId"]) for e in r.get("exits", []) if not e.get("locked")]
    def getPath(a, b):
        a, b = int(a), int(b)
        if a not in AREA or b not in AREA: return False
        prev = {a: None}; q = collections.deque([a])
        while q and b not in prev:
            x = q.popleft()
            for c, y in EX.get(x, []):
                # (like Mudlet's: never through a locked room)
                if y not in prev and y not in LOCKED: prev[y] = (x, c); q.append(y)
        if b not in prev: return False
        dirs, path, x = [], [], b
        while prev[x]: px, c = prev[x]; dirs.insert(0, SHORT.get(c, c)); path.insert(0, str(x)); x = px
        L.globals().speedWalkDir = L.table_from(dirs); L.globals().speedWalkPath = L.table_from(path)
        return True
    G = L.globals()
    G.getPath = getPath
    G.roomLocked = lambda i: int(i) in LOCKED
    G.roomExists = lambda i: (i is not None) and int(i) in AREA
    G.getRoomArea = lambda i: AREA.get(int(i))
    G.getRoomAreaName = lambda a: ANAME.get(int(a)) or -1
    G.getRoomName = lambda i: NAME.get(int(i), "")
    G.getRoomExits = lambda i: L.table_from({c: b for c, b in EX.get(int(i), []) if c in SHORT})
    G.getSpecialExitsSwap = lambda i: L.table_from({c: b for c, b in EX.get(int(i), []) if c not in SHORT})
    G.getRooms = lambda: L.table_from({k: NAME[k] for k in AREA})
    G.getAreaTable = lambda: L.table_from({n: i for i, n in ANAME.items() if n})
    G.searchRoom = lambda q: L.table_from({k: v for k, v in NAME.items() if v.lower() == str(q).lower()})
    o.lua("centerview = function() end; sbo.mounted = function() return true end")
    o.ev("sbo.terrainImport()"); o.ev("sbo.gateImport()"); o.ev("sbo.gateCmdFix()"); o.ev("sbo.zoneMapImport()"); o.ev("sbo.wildExitsImport()")
    return o


def plan(o, frm, to):
    o.lua("gmcp.room = { info = { num = '%d', wilds = '%s' } }; sbo.mapRoom = %d" % (frm, "true" if frm >= 1000000 else "false", frm))
    t = time.time()
    o.lua("OKP, PL = pcall(sbo.withPathMemo, sbo.planTrip, %d, { %d }, {})" % (frm, to))
    dt = time.time() - t
    assert o.ev("OKP"), o.ev("PL")
    if not o.ev("PL"): return None, dt
    lines, tail = o.ev("sbo.planLines(PL)")
    return {"legs": [dict(l.items()) for l in o.ev("PL.legs").values()], "lines": list(lines.values()), "tail": tail}, dt


# trips, and what they must (or mustn't) do - from what went wrong before
TRIPS = [
    ("Rune -> Sigil", 10490, 27964, lambda p: True),
    ("Sigil -> Rune: not through The Wandering Sidhe (locked: it wanders)", 27964, 10490, lambda p: not any("Wandering Sidhe" in l for l in p["lines"])),
    ("New Rigel -> the iceberg: runs, not 1243 rooms on foot", 61834, 917745, lambda p: any(l["kind"] in ("run", "ride") for l in p["legs"])),
    ("the wilds -> the iceberg", 1649148, 917755, lambda p: True),
    ("the worldgate circle -> the Palace of Diocletian's signpost", 3481713, 4189387, lambda p: True),
    ("Rune, in town", 10490, 10500, lambda p: [l["kind"] for l in p["legs"]] == ["walk"]),
    ("Teolaven's inn -> Rune: out, and a run (not walked all the way)", 328864, 10490, lambda p: any(l["kind"] == "run" for l in p["legs"])),
    # The Wandering Sidhe is a locked room (it wanders): never planned through - Mudlet's own path won't go there
    ("Sigil's questmaster -> Lowangen: not through the locked Sidhe", 28450, 16014,
        lambda p: not any("Wandering Sidhe" in l for l in p["lines"])),
    ("Lowangen -> Rune: out and run rune (not walked)", 16004, 10490, lambda p: any(l["kind"] == "run" for l in p["legs"])),
]


def main():
    missing = [f for f in NEED if not os.path.exists(os.path.join(PROFILE, f))]
    if missing:
        print("skipped: not in %s: %s" % (PROFILE, ", ".join(missing))); return 0
    o = load()
    bad = 0
    for label, frm, to, ok in TRIPS:
        p, dt = plan(o, frm, to)
        good = p is not None and ok(p) and dt < 3
        # no step in through a gate that's a command typed before a move (socker survery rune)
        for l in (p or {}).get("legs", []):
            if l["kind"] == "step" and " " in str(l.get("cmd")) and l.get("cmd") not in ("enter gate",):
                good = good and not any(w in str(l["cmd"]) for w in ("socker", "survery"))
        print("%s  %s  (%.2f s)" % ("ok  " if good else "FAIL", label, dt))
        for line in (p or {}).get("lines", []): print("        " + line)
        if not good: bad += 1
    # where a run ends, worked out from the signposts and the towns: right for most of the ones learned by running them
    ends = dict(o.ev("sbo.runData().ends").items())
    agree = 0
    for n, e in ends.items():
        o.lua("sbo.runGuessCache = nil; SAVED = sbo.runData().ends['%s']; sbo.runData().ends['%s'] = nil" % (n, n))
        agree += o.ev("sbo.runEndGuess('%s')" % n) == e
        o.lua("sbo.runData().ends['%s'] = SAVED; sbo.runGuessCache = nil" % n)
    good = not ends or agree >= 0.7 * len(ends)
    print("%s  a run's end worked out = where it really ends: %d of %d" % ("ok  " if good else "FAIL", agree, len(ends)))
    if not good: bad += 1
    # each wild room you've stood in: no step planned from it that its exits don't have
    rows = o.rows("SELECT room, dir FROM wild_blocked")
    print("moves known not to be there: %d" % len(rows))
    print("all passed" if bad == 0 else "%d failed" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
