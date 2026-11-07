# Development

Version 0.3.0 adds inactive-project review, custom Swift/Next output detection, bounded local growth baselines and APFS clone sharing for generated Playwright captures. Version 0.2 added shared discovery for unconfigured project artifacts, full-content expanded ZIP proofs and exact installed-app installer identity. Read [the discovery contract, resource bounds and measured coverage](DISCOVERY.md). ZIPFoundation 0.9.20 is exact-pinned; package resources and MIT notices are included by the build script. `bleach --licenses` embeds the notice for the standalone CLI.

## Source layout

| Module | Responsibility |
| --- | --- |
| `BleachCore` | Rules, immutable plans, recursive snapshots, exclusions, hashing, app inventory, recovery journal and system readings. One actor owns engine operations. |
| `BleachFS` | Small POSIX boundary: physical traversal, bounded largest-file aggregation, descriptor-relative no-follow operations, exclusive moves, locks, atomic journal writes and recovery-only erasure. |
| `BleachCLI` | Argument validation, terminal review, JSON, explicit scripting confirmation and output escaping. |
| `BleachApp` | Observation model, SwiftUI windows, tables, inspector, commands, Settings and original icon geometry. |

ZIPFoundation serves archive verification. The CLI links the official MCP Swift SDK; the native GUI does not. All bundled notices are in THIRD-PARTY-NOTICES.md. No Mole source is bundled. The app binary is named `BleachApp`; the CLI is `bleach`. Names differing only by case collide on standard macOS volumes.

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

## Project activity, growth and clone sharing

`InactiveProjects.swift` requires a locked reinstall recipe, complete bounded source/Git activity evidence and visible process-reference checks. Source modification, birth and ctime are considered; unknown activity retains the project. The owning repository is inspected for nested projects. Linked-worktree indirection is retained for manual review. No dependency item is auto-selected. Apply repeats activity, recipe and reference checks. `Processes.c` checks visible user-owned process working directories, executable/argument paths and vnode descriptors; arguments are not retained and environment values are not examined. Hidden or racing processes remain an OS limitation.

`ProjectOutputs.swift` recognizes compiler target triples/build descriptions and Next BUILD_ID/manifests/server/static layouts. It never classifies an arbitrary build/, tmp/ or work/ tree as disposable. The exact per-user Clang ModuleCache is derived from confstr only for the real default home; fixture homes disable it unless explicitly injected inside the fixture. npx and compiler caches are retained while visibly referenced.

`CacheLocations.swift` reads bounded, user-owned local configuration without executing tools or shell files. It supports npm's user `.npmrc` and cache environment variables, pip's user config/global cache-dir and cache environment variables, `GRADLE_USER_HOME`, `CARGO_HOME`, and `GOCACHE`/the user GOENV file. Custom roots stay inside the selected home, outside protected data. Custom pip roots expose only named HTTP/wheel/selfcheck buckets. Go requires its build-cache README. Cargo exposes only `registry/cache`, preserving source, Git checkouts, installed tools and credentials. Generic uv/pnpm/Bun/Yarn store names are protected. Fixture homes inherit no real cache environment.

Every rebuildable cache receives a visible process-reference check as well as app-owner checks. App helper bundle IDs count as running owners. `ChromiumCaches.swift` uses exact installed bundle IDs, known data roots and bounded profile layouts to find only HTTP/code/GPU/shader cache names. It never selects a whole profile, service-worker storage, cookies, IndexedDB or offline documents. New package-cache plans re-derive current configuration at apply; their typed `CacheProof` records the original boundary for no-overwrite restoration even if configuration changes. The scanner removes parent/child candidate overlap before calculating totals. Cache state stays on the same volume in Recovery until separately erased.

These rules are original implementations based on documented storage semantics. Read-only competitor findings and proprietary disassembly stay outside this repository. Relevant primary references: [npm cache](https://docs.npmjs.com/cli/cache/), [pip caching](https://pip.pypa.io/en/stable/topics/caching/), [Cargo home](https://doc.rust-lang.org/cargo/guide/cargo-home.html), [Go storage](https://go.dev/doc/manage-install), [Electron session caches](https://www.electronjs.org/docs/latest/api/session), and [uv cache safety](https://docs.astral.sh/uv/concepts/cache/). uv explicitly requires its own cache-management commands; Bleach does not move its shared cache as ordinary disposable files.

Chromium CRX archive caches are allowed only at browser data roots, preserving installed components and extensions. Google's exact per-user `Google/GoogleUpdater/crx_cache` also requires installed Chrome identity; active references to the separate `Library/Google/GoogleUpdater` executable tree retain it. See Chromium's [updater cache specification](https://chromium.googlesource.com/chromium/src/+/main/docs/updater/functional_spec.md) and [component/extension CRX cache implementation](https://chromium.googlesource.com/chromium/src/+/7eb44b05ca808d66b3324aa4ea3902becfa3b0e9%5E%21/).

Project processing caches start unchecked and require an idle owning project at scan and apply. Only `.contentlayer/.cache` beside a declared Contentlayer dependency/config and `.godot/imported` beside `project.godot` qualify. Contentlayer generated modules, Godot editor state, original assets and adjacent `.import` settings stay. Original sources must remain available for regeneration. See [Contentlayer artifact paths](https://raw.githubusercontent.com/timlrx/contentlayer2/main/packages/@contentlayer/core/src/_ArtifactsDir.ts) and [Godot's import process](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/import_process.html).

`Growth.swift` records only explicit complete snapshots, with a private atomic JSON file capped at 2 MB, eight roots and 256 immediate children each. Read-only comparisons neither create state nor advance a baseline. Duplicate/malformed keys and partial scans cannot become successful baselines. Identity changes invalidate the old comparison. Private deltas are not free-space receipts.

`StorageSharing.swift` accepts only selected full-hash duplicate captures on a cloning-capable volume. The standard Recovery write-ahead move preserves originals. Each temporary clone slot is persisted before creation. Cloning and COPYFILE_METADATA happen inside private Recovery storage; a verified clone moves exclusively into place and is verified again. Erasure rechecks the replacement and deletes only the identity-checked selected Recovery batch. Failed/recreated paths preserve originals. Undo/erasure discard only verified staged copies in that batch. This preserves data paths and independent writes without hard-link coupling; it does not promise an equal df change.

Run `python3 scripts/verify-storage-workflows.py --binary build/bleach` for the additional CLI canary. Positive inactivity fixtures use the injected clock because ctime cannot be backdated. Mutation tests use disposable homes only.

Prominent native buttons use `PrimaryButtonLabel` to resolve contrasting text from the SwiftUI appearance while retaining native styles, roles and shortcuts. macOS bezel tint does not also tint the label; verify enabled/disabled labels in both appearances.

## Native dashboard and automation (0.5)

`CleanupSelection` owns named presets and storage kinds. Thorough does not select dependency folders or personal data. Coloured SF Symbols share one kind mapping across grouped lists, tables, inspectors and menu bar. The segmented meter uses measured volume capacity/available bytes and keeps private cleanup estimates separate.

`ProcessMonitor` samples up to 8192 user-owned processes through libproc, retaining only PID and start identity, display name, footprint and CPU deltas. 100% CPU is one core. Actions recheck identity/ownership and target regular apps; Bleach and desktop/system UI stay protected. Fixture mode refuses to quit apps outside its home. GPU comes from optional IOAccelerator driver data; no per-process GPU number or memory-purge claim is synthesized. References: [Apple resource counters](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h), [NSRunningApplication](https://developer.apple.com/documentation/appkit/nsrunningapplication).

`AutomaticCleanupSettings` is optional in schema 1 preferences; old files decode to disabled. Invalid configurations fail closed. Auto uses a narrow raw-download/log scan, no project traversal, suggested/private-only candidates, current exclusions and visible reference/owner checks. Logs require 90 days without modification. At most32 items / 8 GB enter each pass. The app owns one 60-second loop and no login helper. Enabling requires a product confirmation; this task never enables it on the real home.

Direct deletion shares the existing write-ahead move and verified per-batch erase. It purges only the batch it just created. Failure/interruption leaves durable item states for inspection; existing recovery remains independent. Both frontends support the choice; CLI clean/apply/uninstall use `--permanent`. See [MCP](MCP.md) for agent tool permissions and provenance.
