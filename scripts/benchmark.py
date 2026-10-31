#!/usr/bin/env python3
"""Compare read-only JSON disk scans on identical, disposable APFS fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile
import time

PROJECT = Path(__file__).resolve().parent.parent
MOLE_REVISION = "a52876330b34705b488b3a7ef525cacc05d461df"


def fixture(root, case):
    root.mkdir()
    if case == "wide-small-files":
        for directory in range(256):
            folder = root / f"cache-{directory:04d}"
            folder.mkdir()
            for number in range(48):
                (folder / f"part-{number:03d}").write_bytes(bytes([(directory + number) % 255]) * 8192)
    elif case == "deep-small-files":
        for leaf in range(128):
            folder = root.joinpath(*(f"level-{(leaf >> bit) & 1}" for bit in range(6, -1, -1)))
            folder.mkdir(parents=True, exist_ok=True)
            for number in range(48):
                (folder / f"part-{number:03d}").write_bytes(bytes([(leaf + number) % 255]) * 4096)
    elif case == "sparse-and-hardlinks":
        for index in range(32):
            (root / f"file-{index:03d}").write_bytes(bytes([index]) * 32768)
        os.link(root / "file-000", root / "hardlink-a")
        os.link(root / "file-000", root / "hardlink-b")
        with (root / "sparse-1GiB").open("wb") as stream:
            stream.truncate(1024**3)


def inventory(root):
    seen = set()
    logical = allocated = files = 0
    for folder, dirs, names in os.walk(root):
        allocated += os.lstat(folder).st_blocks * 512
        for name in names:
            stat = os.lstat(Path(folder) / name)
            identity = (stat.st_dev, stat.st_ino)
            if identity in seen:
                continue
            seen.add(identity)
            logical += stat.st_size
            allocated += stat.st_blocks * 512
            files += 1
    return {"uniqueFiles": files, "logicalBytes": logical, "allocatedBytes": allocated}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bleach", type=Path, default=PROJECT / ".build/release/bleach")
    parser.add_argument("--mole-analyze", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--output", type=Path, default=PROJECT / "docs/benchmarks/results.json")
    args = parser.parse_args()
    if args.runs < 3:
        parser.error("Use at least three measured runs")
    bleach, mole = args.bleach.resolve(), args.mole_analyze.resolve()
    mole_build = subprocess.check_output(["go", "version", "-m", str(mole)], text=True)
    revision = re.search(r"vcs\.revision=([0-9a-f]+)", mole_build)
    if not revision or revision.group(1) != MOLE_REVISION or "vcs.modified=false" not in mole_build:
        parser.error("Use a VCS-stamped Mole analyzer built from the pinned, unmodified source revision")
    commands = {"bleach": [str(bleach), "analyze", "--json"], "mole": [str(mole), "--json"]}
    temporary = Path(tempfile.mkdtemp(prefix="bleach-benchmark-")).resolve()
    metadata = {
        "date": time.strftime("%Y-%m-%d"), "platform": platform.platform(),
        "machine": platform.machine(), "moleRevision": MOLE_REVISION,
        "hardware": {key: subprocess.check_output(["/usr/sbin/sysctl", "-n", key], text=True).strip() for key in ["hw.model", "hw.memsize", "hw.ncpu"]},
        "moleBuild": {"goVersion": mole_build.splitlines()[0].split()[-1], "vcsRevisionVerified": True, "sourceModified": False},
        "bleachSHA256": hashlib.sha256(bleach.read_bytes()).hexdigest(),
        "moleAnalyzeSHA256": hashlib.sha256(mole.read_bytes()).hexdigest(),
        "method": "Release binary end-to-end wall time, JSON stdout, one unmeasured warm-up each, alternating order, warm filesystem cache. No cleanup commands run.",
        "runsPerCase": args.runs, "cases": [],
    }
    try:
        for case in ["wide-small-files", "deep-small-files", "sparse-and-hardlinks"]:
            root = temporary / case
            fixture(root, case)
            expected = inventory(root)
            timings = {"bleach": [], "mole": []}
            latest = {}
            for run in range(-1, args.runs):
                for name in (["bleach", "mole"] if run % 2 else ["mole", "bleach"]):
                    started = time.perf_counter()
                    process = subprocess.run([*commands[name], str(root)], capture_output=True, text=True, timeout=60)
                    elapsed = time.perf_counter() - started
                    if process.returncode:
                        raise RuntimeError((name, process.returncode, process.stderr))
                    latest[name] = json.loads(process.stdout)
                    if run >= 0:
                        timings[name].append(elapsed * 1000)
            b, m = latest["bleach"], latest["mole"]
            assert b["fileCount"] == expected["uniqueFiles"], (case, "Bleach file count", b["fileCount"], expected)
            assert b["allocatedBytes"] == expected["allocatedBytes"], (case, "Bleach allocation", b["allocatedBytes"], expected)
            assert b["logicalBytes"] == expected["logicalBytes"], (case, "Bleach logical bytes", b["logicalBytes"], expected)
            assert not b["issues"], (case, b["issues"])
            comparable = m.get("total_size") == expected["allocatedBytes"] and m.get("scan_status") == "complete"
            row = {
                "name": case, "expected": expected,
                "bleach": {"medianMs": statistics.median(timings["bleach"]), "runsMs": timings["bleach"], "files": b["fileCount"], "allocatedBytes": b["allocatedBytes"]},
                "mole": {"medianMs": statistics.median(timings["mole"]), "runsMs": timings["mole"], "files": m.get("total_files"), "allocatedBytes": m.get("total_size"), "scanStatus": m.get("scan_status")},
                "sameAllocationAndComplete": comparable,
                "ratioMoleOverBleach": statistics.median(timings["mole"]) / statistics.median(timings["bleach"]) if comparable else None,
            }
            metadata["cases"].append(row)
            print(json.dumps(row, separators=(",", ":")), flush=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(metadata, indent=2) + "\n")
        hardware = metadata["hardware"]
        lines = ["# Disk-scan benchmark", "", f"Measured {metadata['date']} on {metadata['platform']}, {hardware['hw.model']}, {int(hardware['hw.memsize']) / 1024**3:g} GiB RAM and {hardware['hw.ncpu']} logical cores.", "",
                 f"Mole CLI commit: `{MOLE_REVISION}`. Both binaries ran read-only JSON analysis on the same local fixtures.", "",
                 "| Fixture | Unique files | Bleach median | Mole median | Mole / Bleach |", "| --- | ---: | ---: | ---: | ---: |"]
        for row in metadata["cases"]:
            ratio = f"{row['ratioMoleOverBleach']:.2f}×" if row["ratioMoleOverBleach"] is not None else "Not comparable"
            lines.append(f"| {row['name']} | {row['expected']['uniqueFiles']:,} | {row['bleach']['medianMs']:.2f} ms | {row['mole']['medianMs']:.2f} ms | {ratio} |")
        lines += ["", f"One unmeasured warm-up per tool, then {args.runs} measured runs per case with alternating order. Timings include process launch and JSON output. Filesystem caches were warm; this is not a cold-cache or whole-Mac cleanup benchmark.", "",
                  "Allocated totals match an independent `lstat` inventory in every comparable case. The sparse/hard-link fixture has 35 pathnames but 33 unique physical regular files; Mole reports the pathname count, Bleach reports the unique count. Both report the same allocated bytes. APFS clones and snapshots can share blocks, so allocation does not promise an equal free-space gain.", "",
                  "The first Bleach implementation was slower on the two large trees (see [baseline.json](baseline.json)). Moving read-only aggregation into the native traversal removed per-file Swift/Foundation object creation. Recovery and cleanup validation remain in the shared Swift engine.", "",
                  "See [raw timings and binary hashes](results.json). No deletion command ran. These synthetic fixtures do not prove performance on every Mac, live home directory, external disk or network volume.", "",
                  "Reproduce after building Bleach:", "", "```sh",
                  'MOLE_SRC=$(mktemp -d "${TMPDIR:-/tmp}/bleach-mole-benchmark.XXXXXX")',
                  'git clone https://github.com/tw93/Mole.git "$MOLE_SRC"',
                  f'git -C "$MOLE_SRC" checkout {MOLE_REVISION}',
                  'go -C "$MOLE_SRC" build -o "$MOLE_SRC/mole-analyze" ./cmd/analyze',
                  'python3 scripts/benchmark.py --mole-analyze "$MOLE_SRC/mole-analyze" --bleach build/bleach', "```", "",
                  f"Go build metadata confirms the pinned VCS revision, unmodified source, and {metadata['moleBuild']['goVersion']}. The benchmark script verifies that revision before running. Go is needed only to reproduce this external comparison; Bleach has no Go dependency.", ""]
        args.output.with_suffix(".md").write_text("\n".join(lines))
        print(f"Saved {args.output}")
    finally:
        shutil.rmtree(temporary)


if __name__ == "__main__":
    main()
