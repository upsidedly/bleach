#!/usr/bin/env python3
"""Exercise inactive review, growth and APFS sharing in a disposable home."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from importlib.util import module_from_spec, spec_from_file_location

PROJECT = Path(__file__).resolve().parent.parent
spec = spec_from_file_location("fixture", PROJECT / "scripts/make-fixture.py")
fixture_module = module_from_spec(spec)
spec.loader.exec_module(fixture_module)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=PROJECT / "build/bleach")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    root = Path(tempfile.mkdtemp(prefix="bleach-storage-workflows-")).resolve()
    checks = []
    try:
        fixture_module.create_fixture(root)

        def run(*arguments, code=0):
            process = subprocess.run([str(binary), *map(str, arguments), "--root", str(root), "--json"], capture_output=True, text=True, timeout=120)
            assert process.returncode == code, (arguments, process.returncode, process.stderr)
            assert "\x1b" not in process.stdout
            return json.loads(process.stdout) if code == 0 else process

        protected = [root / ".codex/sessions/fixture.jsonl", root / ".t3/userdata/fixture.sqlite"]
        digests = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in protected}
        scan = run("scan")
        assert all(Path(item["path"]).is_relative_to(root) for item in scan["candidates"])
        assert not any(item["rule"] == "clangModuleCache" for item in scan["candidates"])
        checks.append("custom-home scans never reach the real compiler cache")

        project = root / "Projects/Recent"
        (project / "node_modules").mkdir(parents=True)
        (project / "node_modules/data").write_bytes(b"dependency")
        (project / "package.json").write_text('{"name":"recent"}')
        (project / "package-lock.json").write_text('{"lockfileVersion":3}')
        inactive = run("inactive", project)
        assert not inactive["candidates"] and any("activity" in item["message"] for item in inactive["issues"])
        run("inactive", project, "--yes", code=1)
        checks.append("recent sources are retained; inactive review cannot implicitly apply")

        growth_file = root / "Library/Application Support/Bleach/growth.json"
        initial = run("growth", root / "Projects")
        assert not initial["recorded"] and not growth_file.exists()
        baseline = run("growth", root / "Projects", "--record")
        (project / "new-output").write_bytes(b"x" * 131072)
        comparison = run("growth", root / "Projects")
        assert comparison["previousDate"] and comparison["storage"]["privateBytes"] > baseline["storage"]["privateBytes"]
        assert not comparison["recorded"]
        checks.append("growth reads stay read-only; explicit baselines expose new private allocation")

        captures = root / "Projects/Captures"
        preview_file = root / "duplicates.json"
        report = run("duplicates", captures, "--output", preview_file)
        assert len(report["plan"]["candidates"]) == 1 and len(report["shareablePaths"]) == 1
        paths = [Path(path) for path in report["groups"][0]["files"]]
        hashes = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
        run("share", preview_file, code=1)
        run("share", preview_file, "--dry-run")
        assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in hashes.items())
        checks.append("sharing requires confirmation and dry-run preserves every copy")

        receipt = run("share", preview_file, "--yes")
        assert receipt["pathsPreserved"] == 1 and all(item["state"] == "erased" for item in receipt["batch"]["items"])
        assert receipt["privateBytesAfter"] < receipt["privateBytesBefore"]
        assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in hashes.items())
        assert paths[0].stat().st_ino != paths[1].stat().st_ino and all(path.stat().st_nlink == 1 for path in paths)
        checks.append("APFS sharing reduces measured private allocation and keeps both independent paths")
        with paths[1].open("r+b") as stream:
            stream.write(b"independent edit")
        assert hashlib.sha256(paths[0].read_bytes()).hexdigest() == hashes[paths[0]]
        checks.append("later in-place writes leave the other copy unchanged")

        run("growth", root / ".codex", "--record")
        run("growth", root / ".t3", "--record")
        assert not run("inactive", root / ".codex")["candidates"]
        assert not run("inactive", root / ".t3")["candidates"]
        assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in digests.items())
        checks.append("agent measurements preserve session and database contents")

        result = {"version": subprocess.check_output([str(binary), "--version"], text=True).strip(),
                  "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(), "checks": checks,
                  "sharingPrivateBytesBefore": receipt["privateBytesBefore"], "sharingPrivateBytesAfter": receipt["privateBytesAfter"],
                  "limits": "Disposable fixture only. No real home cleanup. Private allocation is not a volume free-space receipt. Old-project positive cases use an injected clock in core tests because ctime cannot be backdated."}
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
