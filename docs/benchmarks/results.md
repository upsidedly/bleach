# Disk-scan benchmark

The first table is historical: it measures the earlier allocation-only scanner. Current scans also query APFS private allocation; their additional cost and clone accuracy are measured below.

Measured 2026-10-29 on macOS-27.2-arm64-arm-64bit-Mach-O, Mac16,8, 24 GiB RAM and 12 logical cores.

Mole CLI commit: `a52876330b34705b488b3a7ef525cacc05d461df`. Both binaries ran read-only JSON analysis on the same local fixtures.

| Fixture | Unique files | Bleach median | Mole median | Mole / Bleach |
| --- | ---: | ---: | ---: | ---: |
| wide-small-files | 12,288 | 26.46 ms | 81.21 ms | 3.07× |
| deep-small-files | 6,144 | 19.14 ms | 54.57 ms | 2.85× |
| sparse-and-hardlinks | 33 | 8.48 ms | 53.94 ms | 6.36× |

One unmeasured warm-up per tool, then 7 measured runs per case with alternating order. Timings include process launch and JSON output. Filesystem caches were warm; this is not a cold-cache or whole-Mac cleanup benchmark.

Allocated totals match an independent `lstat` inventory in every comparable case. The sparse/hard-link fixture has 35 pathnames but 33 unique physical regular files; Mole reports the pathname count, Bleach reports the unique count. Both report the same allocated bytes. APFS clones and snapshots can share blocks, so allocation does not promise an equal free-space gain.

The first Bleach implementation was slower on the two large trees (see [baseline.json](baseline.json)). Moving read-only aggregation into the native traversal removed per-file Swift/Foundation object creation. Recovery and cleanup validation remain in the shared Swift engine.

See [raw timings and binary hashes](results.json). No deletion command ran. These synthetic fixtures do not prove performance on every Mac, live home directory, external disk or network volume.

Reproduce after building Bleach:

```sh
MOLE_SRC=$(mktemp -d "${TMPDIR:-/tmp}/bleach-mole-benchmark.XXXXXX")
git clone https://github.com/tw93/Mole.git "$MOLE_SRC"
git -C "$MOLE_SRC" checkout a52876330b34705b488b3a7ef525cacc05d461df
go -C "$MOLE_SRC" build -o "$MOLE_SRC/mole-analyze" ./cmd/analyze
python3 scripts/benchmark.py --mole-analyze "$MOLE_SRC/mole-analyze" --bleach build/bleach
```

Go build metadata confirms the pinned VCS revision, unmodified source, and go1.26.10. The benchmark script verifies that revision before running. Go is needed only to reproduce this external comparison; Bleach has no Go dependency.

## APFS accounting

Measured 2026-10-31 on macOS 27.2, Apple M4 Pro (Mac16,8). The released v0.2.0 CLI and the clone-aware release build analyzed identical disposable APFS fixtures. Each had one warm-up followed by seven alternating runs, including process launch and JSON output. No cleanup command ran.

| Fixture | Files | Earlier median | Clone-aware median | Current accounting |
| --- | ---: | ---: | ---: | --- |
| Independent 1 KiB files | 6,400 | 14.93 ms | 37.80 ms | 25 MiB allocated and private |
| Full clones; original retained outside scan | 128 | 7.03 ms | 7.95 ms | 256 MiB attributed allocation, **0 private bytes** |

The new metadata queries add 22.87 ms on the 6,400-file fixture (about 3.6 µs per file). This trades scan throughput for a useful distinction: the clone-only folder no longer presents repeated references to a retained original as private storage. The allocated totals and file counts still match the earlier scanner. These warm-cache fixtures do not predict whole-disk timing, snapshot coverage or guaranteed free-space gain.

See the [raw runs, fixture recipes, binary hashes and accounting source hashes](apfs-accounting.json). The CLI canary and `StorageTests` separately verify full clones, partial divergence, hard links, symbolic links, Finder aliases and conservative metadata fallback.
