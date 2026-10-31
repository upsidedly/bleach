#!/usr/bin/env python3
"""Exercise actual CLI contracts against a disposable home, never the real home."""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("fixtures", PROJECT / "scripts/make-fixture.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=PROJECT / ".build/release/bleach")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        raise SystemExit("Build the CLI first: swift build -c release --product bleach")
    root = fixtures.create_fixture(Path(tempfile.mkdtemp(prefix="bleach-cli-canary-")).resolve())
    checked = []

    def run(*args, status=0, parse=True):
        result = subprocess.run([str(binary), *args, "--root", str(root)], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=60, env={**os.environ, "NO_COLOR": "1"})
        assert result.returncode == status, (args, result.returncode, result.stdout, result.stderr)
        assert "\x1b" not in result.stdout, "Escape sequence in redirected/NO_COLOR output"
        return json.loads(result.stdout) if parse else result

    try:
        plan_file = root / "preview.json"
        plan = run("scan", "--json", "--output", str(plan_file))
        assert len(plan["candidates"]) >= 7
        assert not any(".ssh" in item["path"] or ".Trash" in item["path"] for item in plan["candidates"])
        assert next(item for item in plan["candidates"] if item["path"].endswith("org.bleach.fixture.Recent"))["recommendation"] == "suggested"
        assert next(item for item in plan["candidates"] if item["rule"] == "npmCache")["recommendation"] == "suggested"
        checked.append("scan JSON, categories, preview export and protected user data")
        stale = root / "Library/Caches/org.bleach.fixture.Preview"
        digest = hashlib.sha256((stale / "data.bin").read_bytes()).hexdigest()
        run("clean", "--all", status=1, parse=False)
        assert stale.is_dir()
        checked.append("noninteractive cleanup refuses implicit confirmation")
        dry = run("apply", str(plan_file), "--select", str(stale), "--dry-run", "--json")
        assert len(dry["candidates"]) == 1 and stale.is_dir()
        checked.append("exact saved-plan selection and dry run")
        receipt = run("apply", str(plan_file), "--select", str(stale), "--yes", "--json")
        assert receipt["items"][0]["state"] == "moved" and not stale.exists()
        batch = receipt["id"]
        history = run("history", "--json")
        assert history[0]["id"] == batch
        checked.append("saved-plan apply, durable batch and clean JSON output")
        restored = run("undo", batch, "--json")
        assert restored["items"][0]["state"] == "restored"
        assert hashlib.sha256((stale / "data.bin").read_bytes()).hexdigest() == digest
        checked.append("history-to-undo round trip preserves full contents")
        dupes_file = root / "duplicates.json"
        dupes = run("duplicates", str(root / "Documents"), "--json", "--output", str(dupes_file))
        assert len(dupes["groups"]) == 1
        duplicate_batch = run("apply", str(dupes_file), "--yes", "--json")
        held = root / "Library/Application Support/Bleach/Recovery" / duplicate_batch["id"].lower() / "items"
        assert held.is_dir()
        run("empty", duplicate_batch["id"], "--yes", "--json")
        assert not any(held.iterdir())
        assert (root / ".Trash/personal-file.txt").is_file()
        assert (root / "Documents/Copy/Field Notes.pdf").is_file()
        checked.append("duplicate proof, retained copy and batch-scoped permanent deletion")
        space = run("analyze", str(root / "Documents"), "--json")
        assert space["fileCount"] == 2 and space["allocatedBytes"] > 0
        checked.append("read-only disk inventory JSON")
        # Real copy-on-write clones, including an original outside the scan.
        source = root / "Storage/retained-original"
        source.parent.mkdir()
        source.write_bytes(b"x" * (2 * 1024**2))
        clone = root / "Storage/Space/clone"
        clone.parent.mkdir()
        libc = ctypes.CDLL(None, use_errno=True)
        libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        assert libc.clonefile(os.fsencode(source), os.fsencode(clone), 0) == 0, ctypes.get_errno()
        space = run("analyze", str(clone.parent), "--json")
        assert space["allocatedBytes"] == source.stat().st_blocks * 512
        assert space["storage"]["privateBytes"] == 0
        assert space["storage"]["sharedBytes"] == space["allocatedBytes"]
        assert space["storage"]["cloneFiles"] == 1
        assert space["storage"]["unverifiedBytes"] == 0
        text = run("analyze", str(clone.parent), parse=False).stdout
        assert "full APFS clone" in text and "private" in text and "shared" in text
        checked.append("APFS clone outside scanned folder: private/shared JSON and text agree")
        cache_clone = root / "Library/Caches/org.bleach.fixture.Clone/clone"
        cache_clone.parent.mkdir()
        assert libc.clonefile(os.fsencode(source), os.fsencode(cache_clone), 0) == 0, ctypes.get_errno()
        clone_plan = run("scan", "--json")
        candidate = next(item for item in clone_plan["candidates"] if item["path"] == str(cache_clone.parent))
        assert candidate["recommendation"] == "suggested"
        assert candidate["snapshot"]["storage"]["privateBytes"] == 0
        assert candidate["snapshot"]["storage"]["sharedBytes"] == source.stat().st_blocks * 512
        checked.append("shared cache remains selected without inflating private bytes")
        run("scan", "--output", str(plan_file), status=1, parse=False)
        assert json.loads(plan_file.read_text())["id"] == plan["id"]
        checked.append("preview export refuses an existing output file")
        run("analyze", "--yes", status=1, parse=False)
        run("scan", "--unknown-option", status=1, parse=False)
        checked.append("unknown and command-inappropriate options are rejected")
        status = run("status", "--json")
        assert 0 <= status["cpuPercent"] <= 100
        assert 0 <= status["memoryUsed"] <= status["memoryTotal"]
        assert 0 <= status["diskAvailable"] <= status["diskTotal"]
        assert status["uptime"] > 0
        checked.append("live macOS metrics are bounded and valid JSON")
        print(json.dumps({"result": "PASS", "checks": checked, "count": len(checked)}, indent=2))
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
