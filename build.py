#!/usr/bin/env python3
"""Build Oven.mpackage from src/Oven.lua.

    python3 build.py            # uses the repo name in REPO (e.g. cracksui/softbuns-oven)

Writes Oven.mpackage and VERSION (both committed, so `sbo update` can fetch them).
Runs tests/run.py first and stops if any fail (--no-tests skips them).
    python3 build.py --check    # is the committed package built from the current source?
"""
import os, re, subprocess, sys, zipfile
from xml.sax.saxutils import escape

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, "src", "Oven.lua"), encoding="utf-8").read()
version = re.search(r'M\.version = "([\d.]+)"', src).group(1)
repo_file = os.path.join(here, "REPO")
repo = open(repo_file).read().strip() if os.path.exists(repo_file) else "@@REPO@@"
src = src.replace("@@REPO@@", repo)

config = f'''mpackage = [[Oven]]
author = [[softbuns]]
title = [[Soft Bun's Oven (sbo) :: bakes raw Materia Magica output into something edible]]
description = [[Raw game text goes in, baked output comes out. Soft Bun's Oven rebuilds eq, item looks, containers, inventory, score, affects and mob examines into clean aligned layouts in the main window and a floating Inspector window. It remembers every item you look at and compares gear (against what you wear, a pinned item, or any two), and can move your prompt into a HUD bar with HP/SP/ST gauges. Type sbo for commands.]]
version = [[{version}]]
'''

xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE MudletPackage>
<MudletPackage version="1.001">
	<ScriptPackage>
		<ScriptGroup isActive="yes" isFolder="yes">
			<name>Soft Bun's Oven</name>
			<packageName></packageName>
			<script></script>
			<eventHandlerList />
			<Script isActive="yes" isFolder="no">
				<name>Soft Bun's Oven core</name>
				<packageName></packageName>
				<script>{escape(src)}</script>
				<eventHandlerList />
			</Script>
		</ScriptGroup>
	</ScriptPackage>
</MudletPackage>
'''

out = os.path.join(here, "Oven.mpackage")
if "--check" in sys.argv:
    try:
        with zipfile.ZipFile(out) as z:
            same = z.read("config.lua").decode() == config and z.read("Oven.xml").decode() == xml
        same = same and open(os.path.join(here, "VERSION")).read().strip() == version
    except Exception as e:
        same = False
    print(f"Oven.mpackage is v{version} from the current source" if same else
          "Oven.mpackage/VERSION weren't rebuilt from src/Oven.lua - run python3 build.py")
    sys.exit(0 if same else 1)

if "--no-tests" not in sys.argv:
    if subprocess.run([sys.executable, os.path.join(here, "tests", "run.py")]).returncode != 0:
        sys.exit("tests failed - not building (python3 build.py --no-tests to build anyway)")

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("config.lua", config)
    z.writestr("Oven.xml", xml)
with open(os.path.join(here, "VERSION"), "w") as f:
    f.write(version + "\n")
print(f"built Oven.mpackage v{version} (repo: {repo})")
