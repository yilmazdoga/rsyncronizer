# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for Rsyncronizer. Build from gui/:
#     pyinstaller rsyncronizer.spec
# Produces dist/rsyncronizer/ (onedir) and, on macOS, dist/Rsyncronizer.app.

import os
import sys

repo = os.path.abspath(os.path.join(SPECPATH, os.pardir))

# The engine file set comes from the single-source manifest — never a
# hard-coded list (the stale-engine class of bug lives that way).
engine_files = []
with open(os.path.join(repo, "lib", "engine-manifest.txt")) as _mf:
    for _line in _mf:
        _line = _line.strip()
        if _line and not _line.startswith("#"):
            engine_files.append(_line)
datas = []
for rel in engine_files:
    dest = os.path.join("engine", os.path.dirname(rel)) if os.path.dirname(rel) else "engine"
    datas.append((os.path.join(repo, rel), dest))
# The window/desktop icon and the toolbar coffee icon, at runtime under assets/.
datas.append((os.path.join(SPECPATH, "assets", "icon-256.png"), "assets"))
datas.append((os.path.join(SPECPATH, "assets", "coffee.png"), "assets"))

with open(os.path.join(repo, "VERSION")) as fh:
    version = fh.read().strip()

a = Analysis(
    ["rsyncronizer.py"],
    pathex=[SPECPATH],
    binaries=[],
    datas=datas,
    hiddenimports=[],
    hookspath=[],
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="rsyncronizer",
    debug=False,
    strip=False,
    upx=False,
    console=False,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="rsyncronizer",
)

if sys.platform == "darwin":
    app = BUNDLE(
        coll,
        name="Rsyncronizer.app",
        icon=os.path.join(SPECPATH, "assets", "icon.icns"),
        bundle_identifier="com.yilmazdoga.rsyncronizer",
        version=version,
        info_plist={
            "NSHighResolutionCapable": True,
            "CFBundleShortVersionString": version,
        },
    )
