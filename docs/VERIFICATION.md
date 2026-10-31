# Verification

29 October 2026. Scope: original source-build CLI and native macOS app, version 0.2.0. Testing used macOS 27.2 on Mac16,8, Apple Silicon, 24 GiB RAM, 12 logical cores, and Apple Swift 6.3.2 with the selected Command Line Tools SDK.

## Automated evidence

| Check | Result |
| --- | --- |
| `./scripts/test.sh` | 80 tests in 5 suites passed after 0.351 seconds. |
| `python3 scripts/verify-cli.py --binary build/bleach` | 10 integration checks passed against a disposable home. |
| Focused Address Sanitizer run of `InspectionTests` | 22 inspection cases passed; no reported sanitizer error. Retained for the unchanged C analysis/traversal implementation. |
| `./scripts/build.sh` | Both release products built; app plist and strict local code signature checks passed. |
| `zsh -n` for build/install/test/check scripts | Passed. |
| Interactive terminal menu | Arrow navigation and `q` exit passed in an `xterm-256color` PTY. |
| Local installation | Updated `/Applications/Bleach.app` and `~/.local/bin/bleach` to 0.2.0; strict signature verification passed. The previous app was backed up in private Bleach state; existing user settings/history were retained. |
| `python3 scripts/verify-discovery.py --binary build/bleach` | All 5 expected opportunities found, decoys retained, allocation matched independent inventory, exact plan applied and undone, kept copies unchanged. Raw coverage and binary SHA-256 are recorded in `docs/benchmarks/discovery.json`. |
| Read-only Mole comparison | All three fixture allocation totals matched independent `lstat` inventories. Warm-cache medians, full timings, hardware and binary hashes are in [the benchmark](benchmarks/results.md). |

The core cases cover cache default selection, recent/package caches, running-owner refusal, deep changes after preview, replaced roots, linked roots and ancestors, linked children, unreadable descendants, exclusions, malformed settings/plans/journals, stale plans, overlapping targets, cross-process locking, duplicate hashing, keeper changes, hard links, sparse files, exact app IDs, shared app data, no-overwrite restore, journal reconciliation and interrupted permanent deletion. The CLI canary verifies clean JSON, dry runs, confirmation refusal without a terminal, saved-plan selection, cleanup/undo, scoped permanent deletion, retained duplicate copies, protected Trash, output-file refusal, argument errors and live system readings.

## Native evidence

Version 0.2.0's real native Find More Space action added five review items and 230.7 MB (220 MiB) to the controlled fixture's existing 16.8 MB cache review. It preserved the existing selected total, displayed installed-app evidence (actual bundle ID, version 1.2 and build 12), updated the total after selecting that installer, and included it in the ⌘Return cleanup review. Compact 880 × 580 layout exposed all actions, readable wrapped evidence, vertical scrolling and no horizontal overflow. The review was cancelled; native verification did not move real-home data.

The installed final build was also inspected in light appearance at that compact size, confirming the same five discoveries and corrected singular installer label. It then reopened normally against the real home, showing version 0.2.0 without a load error. Both coverage and timing report hashes match the final standalone CLI.

The real compiled app was inspected through native accessibility and screenshot tools, using actual disposable fixture files. No user cache was moved or erased by these checks.

- Light and dark windows, normal desktop layout and an 880 × 580-point content area.
- Native cleanup selection, per-item inspector, running-app disabled controls and keyboard review via ⌘Return.
- Review sheet and an actual recoverable fixture move.
- GUI-created batch restored from the CLI; CLI-created batch restored from the GUI.
- Recovery states visibly updated after cross-interface operations.
- Compact cleanup table repaired to remove horizontal overflow while retaining category, review status, allocation, selection and the inspector.
- Real system readings displayed in the compact window.
- Accessibility tree exposed checkbox names, disabled state, navigation, table rows, actions and item descriptions. This is not a claim of a complete VoiceOver conformance audit.

The final cache-selection correction was checked in the running app: recent caches and npm cache started selected, Chrome's running-owner cache was disabled and unselected, and toggling an 8.4 MB cache changed both totals from 25 MB / 7 items to 16.6 MB / 6 items and back. The fixture scan completed in 47 ms. These fixture timings are functional evidence, not a whole-Mac speed claim.

A read-only scan of the real home paused inside macOS's Downloads directory access check. Cancellation returned the interface to its idle state. The system permission dialog could not be operated by the available native automation, so a completed real-home cleanup scan is not claimed. No access setting was changed and no real-home cleanup ran.

## Limits

The deployment target and compiler availability checks cover macOS 14+, but this session exercised only the listed Apple Silicon runtime. Intel, older macOS runtime behavior, a full VoiceOver session, network disks, remount/reboot identity changes, actual power loss, and every installed third-party app were not tested. Interrupted journal states were exercised with controlled filesystem fixtures. Read-only native folder-picker flows were not all completed through automation; their shared engine operations were covered by core and CLI tests.

The bundle is locally signed, not notarized. No remote repository, package, release, telemetry, privileged helper or update service was published or enabled. Recovery holds disk space until explicitly deleted, and estimated allocation cannot promise an equal free-space gain on APFS.

## Verdict

**ACCEPT** for the implemented local source-build scope on the tested macOS runtime. The discovery methods, cache defaults, dynamic selected total, shared cleanup and cross-interface recovery have current passing evidence. ZIP64, unmounted-image identity, PKG receipt analysis, distribution signing/notarization and the untested runtime/accessibility matrix remain outside this acceptance. Format/resource limits are documented in [DISCOVERY.md](DISCOVERY.md).
