#!/usr/bin/env python3
"""Create real disposable files for CLI/native verification. No home data used."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import tempfile
import time


def create_fixture(root: Path) -> Path:
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if any(root.iterdir()):
        raise ValueError("Fixture destination must be empty")

    def write(relative: str, size: int, value: int = 37) -> Path:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with path.open("wb") as stream:
            block = bytes([value]) * min(size, 65536)
            left = size
            while left:
                part = block[:min(left, len(block))]
                stream.write(part)
                left -= len(part)
        return path

    caches = [
        ("com.figma.Desktop", 8 * 1024**2, 45),
        ("org.bleach.fixture.Preview", 4 * 1024**2, 35),
        ("com.linear", 2 * 1024**2, 20),
        ("org.bleach.fixture.Recent", 768 * 1024, 1),
        ("com.google.Chrome", 3 * 1024**2, 20),
    ]
    age_roots = []
    for index, (name, size, age) in enumerate(caches):
        path = write(f"Library/Caches/{name}/data.bin", size, 41 + index)
        age_roots.append((path.parent, age))
    for relative, size, age in [
        ("Library/Logs/FixtureKit/old.log", 128 * 1024, 60),
        ("Library/Developer/Xcode/DerivedData/Sketch-fkpr/Build/product.o", 6 * 1024**2, 35),
        (".npm/_cacache/content-v2/packages", 3 * 1024**2, 40),
        ("Downloads/Sketch-Installer.dmg", 5 * 1024**2, 60),
        ("Projects/Sketch/node_modules/example/index.js", 1024**2, 28),
    ]:
        file = write(relative, size, 73)
        target = file.parent
        if "DerivedData" in relative:
            target = root / "Library/Developer/Xcode/DerivedData/Sketch-fkpr"
        elif "node_modules" in relative:
            target = root / "Projects/Sketch/node_modules"
        elif relative.endswith(".dmg"):
            target = file
        age_roots.append((target, age))
    write("Projects/Sketch/package.json", 0).write_text('{"name":"fixture-sketch","dependencies":{"example":"1.0.0"}}')
    write("Documents/Keep/Field Notes.pdf", 128 * 1024, 94)
    write("Documents/Copy/Field Notes.pdf", 128 * 1024, 94)
    write("Documents/Unique.txt", 4096, 61)
    write(".Trash/personal-file.txt", 30, 71)
    write(".ssh/id_fixture", 200, 25)
    write("Library/Preferences/org.bleach.fixture.Sample.plist", 256, 12)
    app_info = write("Applications/Sample.app/Contents/Info.plist", 0)
    app_info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.bleach.fixture.Sample", "CFBundleName": "Sample", "CFBundleShortVersionString": "1.0"}))
    write("Applications/Sample.app/Contents/MacOS/Sample", 1024, 33)
    state = root / "Library/Application Support/Bleach"
    state.mkdir(parents=True, mode=0o700)
    (state / "preferences.json").write_text(json.dumps({
        "schemaVersion": 1, "excludedPaths": [], "projectRoots": [str(root / "Projects")], "minimumAgeDays": 30
    }))
    (state / "preferences.json").chmod(0o600)
    for path, days in age_roots:
        stamp = time.time() - days * 86400
        if path.is_dir():
            for current, dirs, files in os.walk(path, topdown=False):
                for name in files + dirs:
                    os.utime(Path(current) / name, (stamp, stamp), follow_symlinks=False)
        os.utime(path, (stamp, stamp), follow_symlinks=False)
    return root


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    destination = args.output or Path(tempfile.mkdtemp(prefix="bleach-native-fixture-"))
    print(create_fixture(destination.resolve()))
