#!/usr/bin/env python3
"""Build Oven.mpackage from src/Oven.lua.

    python3 build.py            # uses the repo name in REPO (e.g. cracksui/softbuns-oven)

Writes Oven.mpackage and VERSION (both committed, so `sbo update` can fetch them).
"""
import os, re, zipfile
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
description = [[Raw game text goes in, baked output comes out. Soft Bun's Oven rebuilds eq, item looks, containers, inventory, score, affects and mob examines into clean aligned layouts in the main window and a floating oven window. It remembers every item you look at and compares gear (against what you wear, a pinned item, or any two), and can move your prompt into a HUD bar with HP/SP/ST gauges. Type sbo for commands.]]
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
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("config.lua", config)
    z.writestr("Oven.xml", xml)
with open(os.path.join(here, "VERSION"), "w") as f:
    f.write(version + "\n")
print(f"built Oven.mpackage v{version} (repo: {repo})")
