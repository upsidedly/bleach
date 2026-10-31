# Development

Version 0.2.0 adds shared discovery for unconfigured project artifacts, full-content expanded ZIP proofs and exact installed-app installer identity. Read [the discovery contract, resource bounds and measured coverage](DISCOVERY.md). ZIPFoundation 0.9.20 is exact-pinned; package resources and MIT notices are included by the build script. `bleach --licenses` embeds the notice for the standalone CLI.

## Source layout

| Module | Responsibility |
| --- | --- |
| `BleachCore` | Rules, immutable plans, recursive snapshots, exclusions, hashing, app inventory, recovery journal and system readings. One actor owns engine operations. |
| `BleachFS` | Small POSIX boundary: physical traversal, bounded largest-file aggregation, descriptor-relative no-follow operations, exclusive moves, locks, atomic journal writes and recovery-only erasure. |
| `BleachCLI` | Argument validation, terminal review, JSON, explicit scripting confirmation and output escaping. |
| `BleachApp` | Observation model, SwiftUI windows, tables, inspector, commands, Settings and original icon geometry. |

No third-party runtime dependencies or Mole source are bundled. The app binary is named `BleachApp`; the CLI is `bleach`. Names differing only by case collide on standard macOS volumes.

## Build and tests

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/check.sh
```

`build/Bleach.app` contains its own `bleach` executable. `build/bleach` is a standalone CLI copy. The build uses the selected Swift toolchain and SDK without changing Xcode selection, provisioning credentials or accepting license terms.

The installed CLT SwiftPM needs explicit framework and runtime paths for Swift Testing. `scripts/test.sh` supplies the local paths and disables XCTest for this Swift Testing-only target. With a normal full-Xcode selection it uses ordinary SwiftPM discovery. Bleach does not depend on Xcode at runtime.

For the C traversal boundary, a focused Address Sanitizer run is supported:

```sh
./scripts/test.sh --filter InspectionTests --sanitize address --scratch-path .build-asan
```

## Deterministic native verification

Create disposable files, not an in-app fake data model:

```sh
python3 scripts/make-fixture.py
open -n build/Bleach.app --args --root /returned/fixture/path --fixture-mode --auto-scan --appearance dark
```

`--root` selects a different home; both frontends use the same policy. `--fixture-mode` labels the window and enables a Verification menu only with an explicit non-default home. **⇧⌘0** sets an 880 × 580-point content area; **⇧⌘9** sets 1100 × 740. `--appearance light|dark` changes this app’s appearance, not the system preference. Normal launches do not contain verification controls or demo data.

Only disposable fixtures may be mutated by automated checks. Do not run cleanup on the real home merely to verify a feature. Use read-only analysis for any real-machine observation.

## Cleanup contract

1. Discover typed candidates from recognized roots; preserve unknown data.
2. Read the complete target, with physical traversal and no cross-volume descent. Reject partial, foreign-owned or cloud-only targets.
3. Record the root stamp and a deterministic SHA-256 of recursive metadata. This is a change detector, not a content checksum; duplicate proofs separately hash every byte.
4. Recheck the entire selected plan before moving its first item. Reject overlap, stale/foreign plans, mismatched rules and excluded targets.
5. Acquire a process-wide filesystem lock shared by app and CLI. Persist a private write-ahead manifest before moving anything.
6. Recheck current policy and contents, rename exclusively into a same-volume recovery slot, then persist the outcome. Compare again after moving; preserve or restore changed contents.
7. Restore exclusively, with no overwrite. Delete only a specifically selected recovery batch, with an intent persisted before erasure.

Interrupted pending moves are reconciled by source/destination identity. Remaining source files are kept; inspect or restore completed moves, then rescan the rest. Interrupted permanent deletion is marked separately and can resume; it is never presented as fully undoable. A recovery journal is a local record, not a tamper-proof audit trail or an all-or-nothing transaction.

Use POSIX `realpath` for physical roots. Foundation rewrites `/private/var` to `/var` even when resolving symlinks; that spelling would conflict with descriptor-relative no-follow access. Preserve lexical paths for validation and refuse redirected cleanup ancestors.

## Storage accounting

`Storage.c` queries `ATTR_CMNEXT_PRIVATESIZE` and `ATTR_CMNEXT_EXT_FLAGS` using `getattrlist`, with no-follow semantics, returned-attribute validation and device/inode matching. The packed reply uses four-byte alignment. Unsupported or replaced metadata stays unverified. Never infer private bytes from `st_blocks`, or current sharing from the historical `EF_MAY_SHARE_BLOCKS` flag. See Apple's [`getattrlist` attribute definitions](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/attr.h) and [returned-attribute packing](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_attrlist.c); the installed SDK's `getattrlist(2)` manual documents the private-size semantics.

Private, shared/snapshot-retained, hard-linked and unverified byte buckets sum to attributed allocation, after inode deduplication. Every multiply-linked regular file is conservatively excluded from private bytes, even if all names are in the scan. Shared totals are attributed references, not deduplicated extents. Neither total predicts volume free-space gain. The analyzer ranks by private bytes, then attributed allocation, then path.

Storage estimates are separate from identity stamps and recursive fingerprints: another clone's changes must not invalidate an otherwise unchanged saved plan or recovery batch. Optional snapshot storage preserves schema-1 plan/journal decoding; missing estimates are unverified, never assumed private. `StorageTests` exercises real disposable APFS clones, partial writes, outside links, sparse/reference handling, stale sharing flags, ranking, shared cleanup/duplicate accounting and legacy plan restoration. No snapshot is created and no real user data is changed by those tests.

## State

`~/Library/Application Support/Bleach/` is private (mode 700). Preferences store exclusions, project roots and the minimum log age (30 days by default). Earlier age values are clamped to 30 when read. Rebuildable caches are suggested at every age unless blocked or excluded. Recovery has one UUID folder per batch, private JSON manifests and UUID item slots. Journals are atomically replaced and synchronized. Reads do not create state folders or rewrite history. The same schema serves both interfaces.

Version 0.1 has no daemon, scheduler, global filesystem index, database, privileged helper, telemetry, updater or network service. Add one only for an observed need. Keep user recovery and accurate reporting ahead of wider cleanup coverage.
