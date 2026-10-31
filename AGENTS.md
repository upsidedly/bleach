# Bleach

Native macOS app and CLI. `BleachApp` and `bleach` link `BleachCore`; the GUI is not a wrapper around shell commands. Keep executable names distinct beyond casing, because standard macOS volumes are case-insensitive.

Read `docs/DEVELOPMENT.md` for the safety contract. Never verify by deleting or moving real user data. Use disposable fixture homes via `scripts/make-fixture.py` and `--root`. Default scans, analysis, history and app inventories are read-only. Do not add sudo, global Trash emptying, automatic deletion, guessed app-data matches, telemetry or network access.

Preserve exact rule/path checks, complete recursive snapshots, current exclusions, running-owner checks, same-volume recovery, write-ahead manifests, per-item durable outcomes, cross-process locks and no-overwrite restoration. Permanent erasure must stay confined to a specifically selected, identity-checked Bleach recovery batch. Partial permanent deletion must never be labeled fully recoverable. Do not claim that moving to recovery frees space or that APFS allocation equals free-space gain.

Use `./scripts/build.sh`, `./scripts/test.sh`, and targeted cases from `./scripts/check.sh` as appropriate. The CLT test script supplies installed Swift Testing framework/runtime paths; do not change global Xcode selection or accept licenses as a side effect. Run the relevant failed/affected checks after a narrow repair; retain unchanged passing evidence. Native UI verification is owned by Intentional+ Swift. Keep the Tuck/Snap icon and README family, native controls, literal copy and low visual clutter.

Performance claims must identify fixtures, warmed/cold state, repeats, source revision, tool settings and limits. `scripts/benchmark.py` is read-only; use a pinned Mole Analyze binary, never its destructive commands. Do not publish, push or invent a download URL without the user's authority.
