#!/usr/bin/env python3
"""Measure extra discovery coverage and verify recovery using disposable files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import random
import shutil
import subprocess
import tempfile
import time
import zipfile

PROJECT = Path(__file__).resolve().parent.parent


def make_discovery_fixture(root):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if any(root.iterdir()):
        raise ValueError("Use an empty disposable fixture directory")
    random_source = random.Random(241029)

    def write(relative, size, random_bytes=False):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as stream:
            left = size
            while left:
                count = min(65536, left)
                stream.write(random_source.randbytes(count) if random_bytes else b"x" * count)
                left -= count
        return path

    cache = write("Library/Caches/org.bleach.fixture.Cache/data", 16 * 1024**2)
    expected = []
    for folder, manifest, contents, artifact, size in [
        ("Projects/Web", "package.json", '{"name":"fixture"}', "node_modules", 64),
        ("Developer/Swift", "Package.swift", "// swift-tools-version: 6.0", ".build", 96),
        ("Documents/code/Rust", "Cargo.toml", "[package]", "target", 48),
    ]:
        path = write(f"{folder}/{manifest}", 0)
        path.write_text(contents)
        os.utime(path, (time.time() - 120 * 86400,) * 2)
        write(f"{folder}/{artifact}/generated-data", size * 1024**2)
        expected.append(root / folder / artifact)
    expanded = write("Downloads/Trip Photos/photo.raw", 8 * 1024**2, True)
    expanded_zip = root / "Downloads/Trip Photos.zip"
    with zipfile.ZipFile(expanded_zip, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(expanded, "Trip Photos/photo.raw")
    expected.append(expanded_zip)
    app = root / "Applications/Example.app"
    info = write("Applications/Example.app/Contents/Info.plist", 0)
    identity = {"CFBundleIdentifier": "org.bleach.fixture.Example", "CFBundleName": "Example",
                "CFBundleShortVersionString": "1.2", "CFBundleVersion": "12"}
    info.write_bytes(plistlib.dumps(identity))
    binary = write("Applications/Example.app/Contents/MacOS/Example", 4 * 1024**2, True)
    installer = root / "Downloads/Unrelated-Name.zip"
    with zipfile.ZipFile(installer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(info, "Source.app/Contents/Info.plist")
        archive.write(binary, "Source.app/Contents/MacOS/Example")
    expected.append(installer)
    write("Downloads/Mismatch/notes", 4).write_bytes(b"keep")
    with zipfile.ZipFile(root / "Downloads/Mismatch.zip", "w") as archive:
        archive.writestr("Mismatch/notes", b"else")
    write("Downloads/Traversal/notes", 4)
    with zipfile.ZipFile(root / "Downloads/Traversal.zip", "w") as archive:
        archive.writestr("../outside", b"never read outside")
    with zipfile.ZipFile(root / "Downloads/Upgrade.zip", "w") as archive:
        archive.writestr("Example.app/Contents/Info.plist", plistlib.dumps({**identity, "CFBundleVersion": "13"}))
    write("Documents/Precious/target/notes", 1024)
    return {"expected": expected, "cache": cache.parent, "kept": [expanded, info, binary]}


def allocated(path):
    if path.is_file():
        return path.stat().st_blocks * 512
    return sum(os.lstat(Path(folder) / name).st_blocks * 512
               for folder, _, files in os.walk(path) for name in ["."] + files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=PROJECT / "build/bleach")
    parser.add_argument("--output", type=Path, default=PROJECT / "docs/benchmarks/discovery.json")
    parser.add_argument("--make-fixture", type=Path)
    args = parser.parse_args()
    if args.make_fixture:
        make_discovery_fixture(args.make_fixture.resolve())
        print(args.make_fixture.resolve())
        return
    binary = args.binary.resolve()
    root = Path(tempfile.mkdtemp(prefix="bleach-discovery-verification-")).resolve()
    try:
        fixture = make_discovery_fixture(root)

        def run(*arguments):
            process = subprocess.run([str(binary), *map(str, arguments), "--root", str(root), "--json"],
                                     capture_output=True, text=True, timeout=180)
            if process.returncode:
                raise RuntimeError(process.stderr)
            assert "\x1b" not in process.stdout
            return json.loads(process.stdout)

        baseline = run("scan")
        report = run("discover", "--output", root / "preview.json")
        actual = {Path(item["path"]) for item in report["plan"]["candidates"]}
        expected = set(fixture["expected"])
        assert actual == expected, (actual - expected, expected - actual)
        assert report["projectsFound"] == 3 and report["archivesMatched"] == 1 and report["installedInstallers"] == 1
        assert all(item["recommendation"] == "review" for item in report["plan"]["candidates"])
        baseline_bytes = sum(item["snapshot"]["allocatedBytes"] for item in baseline["candidates"])
        extra_bytes = sum(item["snapshot"]["allocatedBytes"] for item in report["plan"]["candidates"])
        assert baseline_bytes == allocated(fixture["cache"])
        assert extra_bytes == sum(allocated(path) for path in expected)
        kept = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in fixture["kept"]}
        original = {path: (path.stat().st_dev, path.stat().st_ino) for path in expected}
        run("apply", root / "preview.json", "--all", "--dry-run")
        batch = run("apply", root / "preview.json", "--all", "--yes")
        assert batch["finished"] and all(item["state"] == "moved" for item in batch["items"])
        assert not any(path.exists() for path in expected)
        assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in kept.items())
        restored = run("undo", batch["id"], "--yes")
        assert all(item["state"] == "restored" for item in restored["items"])
        assert all((path.stat().st_dev, path.stat().st_ino) == identity for path, identity in original.items())
        result = {
            "date": time.strftime("%Y-%m-%d"), "version": subprocess.check_output([str(binary), "--version"], text=True).strip(),
            "platform": platform.platform(), "bleachSHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "fixture": "16 MiB quick-scan cache; 3 unconfigured workspaces with 208 MiB generated data; an 8 MiB expanded ZIP; a 4 MiB installed-app ZIP; mismatched, traversal and upgrade decoys",
            "baselineAllocatedBytes": baseline_bytes, "additionalAllocatedBytes": extra_bytes,
            "combinedAllocatedBytes": baseline_bytes + extra_bytes,
            "coverageRatio": (baseline_bytes + extra_bytes) / baseline_bytes,
            "expectedCandidates": len(expected), "foundCandidates": len(actual),
            "projectsFound": report["projectsFound"], "expandedArchives": report["archivesMatched"],
            "installedAppInstallers": report["installedInstallers"],
            "quickScanSeconds": baseline["duration"], "discoverySeconds": report["plan"]["duration"],
            "allExpectedFound": True, "allDecoysRetained": True, "allocatedInventoryMatches": True,
            "keptCopiesUnchanged": True, "applyAndUndoPassed": True,
            "limits": "Constructed coverage fixture, not representative of a typical Mac or a comparison with Mole. Allocation is not a promise of free-space gain. Fixture changes only; no real home data touched."
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
