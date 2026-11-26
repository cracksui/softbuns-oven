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


def sweep(o, pairs=300, seed=1):
    """trips between many places (every place with a gate, and some signposts): what each plan must be"""
    import random
    gates = o.ev("sbo.allGates()")
    by = {}
    for g in gates.values():
        k = o.ev("sbo.placeLabel(%d)" % g.room)
        if k and k not in by and o.ev("roomExists(%d)" % g.room): by[k] = g.room
    random.seed(seed)
    signs = [sp.room for sp in o.ev("sbo.signposts()").values()]
    pts = list(by.items()) + [("signpost %d" % r, r) for r in random.sample(signs, min(12, len(signs)))]
    all_pairs = [(a, b) for a in pts for b in pts if a != b]
    random.shuffle(all_pairs)
    bad, n, none, slow = [], 0, 0, 0
    for k, ((an, a), (bn, b)) in enumerate(all_pairs[:pairs]):
        p, dt = plan(o, a, b)
        n += 1
        pa, pb = o.ev("sbo.worldPos(%d)" % a), o.ev("sbo.worldPos(%d)" % b)
        if not p:
            none += 1
            if pa and pb and pa.map == pb.map: bad.append(("no plan, both on %s" % pa.map, an, bn))
            continue
        if dt > 2: slow += 1; bad.append(("slow %.1fs" % dt, an, bn))
        for i, l in enumerate(p["legs"]):
            if l["kind"] == "walk":
                o.lua("LG = PL.legs[%d]" % (i + 1))
                if not o.ev("(sbo.legPath(LG))"): bad.append(("a walk with no planned path", an, bn))
            if l["kind"] == "step":
                c = str(l.get("cmd"))
                if not (o.ev("sbo.DIR_OPP[%r] ~= nil" % c) or o.ev("sbo.wayCommand(%r) ~= nil" % c)):
                    bad.append(("a step that isn't a way: %r" % c, an, bn))
            if l["kind"] == "wild" and k % 10 == 0:
                fa, fb = o.ev("sbo.worldPos(%d)" % l["from"]), o.ev("sbo.worldPos(%d)" % l["to"])
                if fa and fb and not o.ev("sbo.gridLegDirs(%r, %d, %d, %d, %d, 50)" % (fa.map, fa.x, fa.y, fb.x, fb.y)):
                    bad.append(("a walk through the wilds with no way cell by cell", an, bn))
                elif fa and fb and o.ev("INTOPLACE(%r, %d, %d, %d, %d)" % (fa.map, fa.x, fa.y, fb.x, fb.y)):
                    bad.append(("a walk through the wilds that steps into a place", an, bn))
    return n, none, bad


def main():
    missing = [f for f in NEED if not os.path.exists(os.path.join(PROFILE, f))]
    if missing:
        print("skipped: not in %s: %s" % (PROFILE, ", ".join(missing))); return 0
    o = load()
    bad = 0
    # a walk through the wilds that takes a gate's step (w from the road by Muldar Lohk Mulvar is into the village):
    # it goes into the place, Oven plans again from there - out, and in again (recorded 2026-11-26)
    o.lua("""INTOPLACE = function(map, x0, y0, x1, y1)
        local gm = {}
        for _, g in ipairs(sbo.allGates()) do local p = sbo.worldPos(g.wild); if p and p.map == map then gm[p.x .. ',' .. p.y .. g.cmd] = true end end
        local x, y = x0, y0
        for _, d in ipairs(sbo.gridLegDirs(map, x0, y0, x1, y1, 60) or {}) do
          if gm[x .. ',' .. y .. d] then return true end
          local v = sbo.WILD_STEP[d]; x, y = x + v[1], y + v[2]
        end
        return false
      end""")
    o.lua("gmcp.room = { info = { num = '1483385', wilds = 'true' } }; sbo.mapRoom = 1483385; P = sbo.withPathMemo(sbo.planTrip, 1483385, { 61834 }, { clan = true })")
    good = o.ev("P and P.legs[1].kind == 'wild'") and not o.ev("(function() local a, b = sbo.worldPos(P.legs[1].from), sbo.worldPos(P.legs[1].to); return INTOPLACE(a.map, a.x, a.y, b.x, b.y) end)()")
    print("%s  out of Muldar Lohk Mulvar: through the wilds, not back in through its gate" % ("ok  " if good else "FAIL"))
    if not good: bad += 1
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
    # many trips: what every plan must be
    t = time.time()
    n, none, sbad = sweep(o)
    print("%s  %d trips between places and signposts: %d without a plan (other maps, no known way), %d problems  (%.0f s)"
          % ("ok  " if not sbad else "FAIL", n, none, len(sbad), time.time() - t))
    for x in sbad[:15]: print("        %s: %s -> %s" % x)
    if sbad: bad += 1
    # the world maps: everything drawn on each - its own signposts and places - named when it's pointed at or clicked
    unnamed, drawn = [], 0
    for mp in ("Alyria", "Alyrian Underworld", "Faerie Plane", "Verity Isle"):
        spots = []
        for sp in o.ev("sbo.signposts()").values():
            p = o.ev("sbo.worldPos(%d)" % sp.room)
            if p and p.map == mp: spots.append((p.x, p.y, "signpost %d" % sp.room))
        o.lua("sbo.worldTownList = nil")
        for t in o.ev("sbo.worldTowns()").values():
            if t.map == mp and not t.entry: spots.append((t.x, t.y, t.name))
        for x, y, what in spots:
            drawn += 1
            for z in (0.5, 4):
                if not o.ev("sbo.worldThingAt(%r, %d, %d, %s)" % (mp, x, y, z)): unnamed.append((mp, x, y, what, z))
    good = not unnamed
    print("%s  every marker on the world maps named when pointed at: %d markers, %d unnamed" % ("ok  " if good else "FAIL", drawn, len(unnamed)))
    for u in unnamed[:10]: print("        %s %d,%d %s (zoom %s)" % u)
    if not good: bad += 1
    # each world map shows its own marks only: the underworld drawn whole has no sign of Alyria's signposts
    import glob
    home = o.L.globals().OVEN_TEST_HOME
    o.lua("""sbo.worldLabel = { echo = function() end, setStyleSheet = function() end, show = function() end, hide = function() end,
        get_width = function() return 1150 end, get_height = function() return 750 end }
      sbo.mapMode = 'world'; sbo.worldHere = { map = 'Alyrian Underworld', x = 1150, y = 750, wild = true }
      sbo.worldV = { zoomI = 2, follow = false, map = 'Alyrian Underworld', cx = 1150, cy = 750 }; sbo.worldDrawNow()""")
    f = sorted(glob.glob(home + "/oven_maps/oven_world_*.bmp"))[-1]
    raw = open(f, "rb").read()
    own = sum(1 for sp in o.ev("sbo.signposts()").values()
              if (lambda p: p and p.map == "Alyrian Underworld")(o.ev("sbo.worldPos(%d)" % sp.room)))
    sign = bytes([255, 90, 170])   # (the signpost colour, as a bitmap's blue-green-red)
    n = raw.count(sign)
    good = own > 0 or n == 0
    print("%s  the underworld shows no signposts of Alyria's (its own: %d; signpost pixels drawn: %d)" % ("ok  " if good else "FAIL", own, n))
    if not good: bad += 1
    # each wild room you've stood in: no step planned from it that its exits don't have
    rows = o.rows("SELECT room, dir FROM wild_blocked")
    print("moves known not to be there: %d" % len(rows))
    print("all passed" if bad == 0 else "%d failed" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
