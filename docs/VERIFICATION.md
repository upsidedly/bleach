# Verification

## 0.5.1 · 7 November 2026

Release candidate on Apple silicon, macOS 27.2 and Swift 6.3.2; macOS 14 remains the deployment target.

- **Core coverage:** the full run exercised 129 tests in 13 suites. 128 passed; the active-capture test rejected an incomplete-inspection message even though the file was correctly retained. Its assertion now accepts either fail-closed diagnostic and verifies that both original payloads remain unchanged with the fixture process running. All six Sharing tests then passed. Passing evidence for the other unchanged cases is retained; process safety checks were not relaxed.
- **CLI:** all 13 packaged-binary integration checks passed, including outside-tree APFS clone accounting, dry-run and confirmation refusal, exact permanent deletion and retained history.
- **Artifact:** the 0.5.1 DMG passed its checksum, mounted read-only and contains the same signed app/CLI files as the build and installed bundle. Its Finder layout and drag-to-Applications target are present. The mounted CLI reports 0.5.1 and passed the full MCP stdio canary, including permission tiers, exact previews, bounds, move/restore, stale-file rejection, permanent deletion and shutdown.
- **Local update:** the previous app was backed up. All 110 existing settings/Recovery entries remained unchanged during installation, and Auto remains off. The existing local signing identity and privacy settings were preserved.
- **Native header:** a real read-only scan in the installed 0.5.1 app completed. The main content begins with the selected private-byte total, with no duplicate free-space meter; the sidebar retains its measured disk meter. Kind rows, centered/spaced disclosure carets, the inspector and both cleanup choices remain visible.

The native workflows and platform limits recorded for 0.5.0 remain applicable. This release does not claim an exact free-space gain, per-app GPU percentages, notarization or a newly executed older-runtime matrix.

**ACCEPT** for the verified 0.5.1 Apple silicon bundle and drag-and-drop DMG on this runtime.

## 0.5.0 · 7 November 2026

Apple silicon M4 Pro, macOS 27.2 and Swift 6.3.2 using Command Line Tools. Deployment target remains macOS 14.

- **Core:** 63 tests in six affected suites passed; after the narrow Auto scanner and process timing repairs, all 41 cases in the four affected suites passed, including the new Mach-tick/getrusage regression. Together these cover 64 distinct tests. Auto cases verify default-off migration, thresholds and pause, exclusions, raw-download classification, shared-allocation refusal, protection of useful files and isolation from existing Recovery. Storage and Recovery evidence remains current for their unchanged inputs.
- **Native cleanup:** dark standard/compact and final light compact renders covered the segmented measured-space meter, distinct kind icons, mixed checkboxes, presets, consistent selected totals and responsive action labels. Command search navigated to System using Return. Menu controls opened with ⇧⌘M, reviewed eight exact disposable paths, moved them and restored all eight using ⌘Z. A final single-item move and the explicit panel Undo button restored the log and displayed the outcome. Single-item permanent deletion displayed its exact path and irreversible confirmation, removed only the selected fake browser cache, and recorded an erased journal item.
- **Resources:** Memory/CPU/GPU selectors, matching charts, real app icons and grouped helper footprints rendered in light/dark. Switching All Processes to GPU resets the scope to Apps. A disposable app holding a 32 MiB Metal buffer exited through normal Quit and, on a separate launch, Force Quit with its warning. Bleach observed process disappearance and reported its last measured footprint. This proves the app-control interaction, not an exact system-memory or GPU-memory gain. Driver counters are device-wide; per-app GPU percentages are not fabricated.
- **Auto:** Settings started off. In a disposable home, accepting the opt-in at a 10% threshold allowed the actual scheduled one-minute loop to erase only the eligible npm download cache. The 60-day log, project dependencies, source, chat-history decoys and existing restored Recovery batch remained. Auto was then switched off. All 18 protected or restored payloads matched their original contents. Production preferences were never enabled for this check. Automatic scans do not enumerate project roots or generic app/browser caches.
- **CLI:** all 13 integration checks passed, including `--permanent` dry run, noninteractive confirmation refusal, exact selected-item deletion and retained chat-history data. The same run exercised the real outside-tree APFS clone/private-byte reporting.
- **MCP:** the packaged stdio canary passed initialization, ping, tool/resource/prompt discovery, read-only state preservation, access tiers, pagination, structured/text output agreement, root and symlink bounds, exact previews, confirmation refusal, move/restore, stale-file rejection, one-use tokens, permanent deletion, retained history and clean EOF shutdown. Agent settings were not changed. The official SDK is pinned to an upstream revision containing the Swift 6.3 concurrency fixes; no dependency source patches or relaxed concurrency checks are used.
- **Build:** both release products, version plist, generated icons and strict local signatures passed without new compiler warnings. The menu icon uses the filled bottle as a template image. No global appearance, display, power or access settings changed.
- **Local delivery:** the installed 0.5.0 app and embedded CLI match every file in the verified build and read-only-mounted DMG. The previous 0.4.0 app is backed up; all 110 existing settings/Recovery entries were unchanged. The DMG checksum, Finder layout and `/Applications` drag target passed. Its embedded CLI passed the same MCP canary, including mutation and permanent-delete fixtures.

The first mounted MCP run conservatively refused a disposable cache as missing or in use before mutation. A fresh two-session scan and the mounted run with improved candidate diagnostics passed. The precise transient cause was not established; a passing retry does not establish that this live-inspection refusal is eliminated. File-reference checks remain conservative under concurrent activity.

The native status item is installed in code, but this automation desktop supplies a zero-height status-bar anchor. Mouse-opening the OS menu icon and its anchored popover could not be exercised here; the same live controls were verified in the native keyboard-accessible panel. Older macOS runtimes, Intel, a full VoiceOver session and every accessibility preference were not executed. Existing APFS accounting remains distinct from measured free space. The app remains locally signed and is not notarized.

**ACCEPT** for the implemented controls and tested native paths on this runtime, with the status-bar environment limit above.

## 0.4.0 · 7 November 2026

Apple silicon, macOS 27.2, Swift 6.3.2 and the existing Command Line Tools; deployment target remains macOS 14.

- **65 targeted tests passed in five suites:** cache discovery, cleanup boundaries, Recovery, output discovery and the existing archive/discovery regressions. Twelve cache cases and two added project-processing cases cover current configuration checks, undo after configuration changes, protected/case-aliased paths, overlap, installed-app profiles, archive-only boundaries, live updater references, idle projects and preservation of source/session/offline-data decoys. Fixture owner snapshots are isolated from real apps; production still refreshes owners before each move.
- **Coverage comparison:** the installed 0.3.0 CLI found one 8 MiB cache in a disposable home. The new CLI found seven caches totaling 56 MiB private allocation, all suggested, with no scan issues. The six additional 8 MiB trees cover Cargo archives, Prisma downloads, a moved npm cache and Chromium HTTP/code/GPU caches. This is a constructed fixture, not a typical-Mac savings claim.
- **Native interaction:** the compiled app selected all seven fixture caches and displayed 58.7 MB in decimal units. Unchecking one reduced both totals to 50.3 MB and six items. Review listed the exact seven paths; Move to Recovery moved all seven, Undo returned them, and rescan selected all seven again. The final build repeated move/undo in light appearance, with real Chrome activity isolated from the fixture. Restored payload hashes and protected decoys matched. The filled bottle mark, new rows and totals were inspected in light/standard and dark/standard/compact windows. No global appearance or access settings changed.
- **Build:** both release products, generated icon assets, version plist and strict local code signatures passed. No new compiler warnings were reported. The shared C filesystem implementation and APFS accounting were unchanged; existing evidence for those algorithms remains historical evidence for its stated inputs.
- **Local delivery:** installed app, embedded CLI and icon match the built 0.4.0 bundle; the previous app is backed up. The DMG checksum passed, mounted read-only and contains the same signed files plus a drag-to-Applications symlink. Its embedded CLI discovered, moved and restored both project-processing cache fixtures while preserving original assets, import settings and generated modules.

Only disposable files were moved for verification. Live scans were read-only, and inaccessible app-data paths were retained. Older macOS runtimes, Intel and a full VoiceOver session were not rerun for this change. The existing local signing identity is retained; the app is not notarized.

**ACCEPT** for the added macOS cache coverage, safeguards and filled icon on the tested runtime.

## Earlier 0.3.0 release evidence

31 October 2026. Bleach 0.3.0, Apple silicon, macOS 27.2 on Mac16,8. Apple Swift 6.3.2, selected Command Line Tools, macOS 26.5 SDK, deployment target macOS 14. No global Xcode selection or system access settings were changed.

## Automated evidence

| Check | Result |
| --- | --- |
| `./scripts/test.sh` | 107 tests in 10 suites passed. |
| Final sharing reporting repair | All 6 `SharingTests` reran and passed; unchanged core evidence retained. |
| Address Sanitizer | 36 cases across Sharing, OutputDiscovery, InactiveProject and Inspection suites passed, with no reported sanitizer error. A unique disposable scratch build was removed afterward. |
| `scripts/verify-cli.py --binary build/bleach` | 12 integration checks passed against disposable files. |
| `scripts/verify-discovery.py --binary build/bleach` | All 5 expected opportunities found; decoys retained, independent allocation matched, apply/undo passed and kept copies stayed unchanged. |
| `scripts/verify-storage-workflows.py --binary build/bleach` | Seven workflow checks passed, including explicit baselines, protected agent data, confirmation refusal, clone sharing and independent in-place edits. |
| Same storage workflow against the CLI inside the mounted DMG | All seven checks passed. |
| Interactive terminal | Inactive-project menu entry, queued arrow input and `q` exit passed in an xterm PTY. |
| Release build | Both products built without new compiler warnings; plist, arm64 architecture and strict local signatures passed. |
| Local update | Installed app and CLI report 0.3.0; both executables, version plist and icon match the DMG. Prior app backed up; user settings and history retained. |
| DMG | Image checksum verified; mounted read-only; signed 0.3.0 app, background and Applications symlink verified. Finder icon positions were read from .DS_Store: app (160,180), Applications (440,180). |

Raw fixture reports and standalone CLI SHA-256 are in [discovery.json](benchmarks/discovery.json) and [storage-workflows.json](benchmarks/storage-workflows.json). The sharing fixture changed one extra copy from 1,048,576 private bytes to zero while retaining both paths. This is a constructed APFS fixture, not a general Mac savings or volume free-space claim. Older Mole comparison timings remain historical evidence for their documented source and workload.

The new tests cover source creation/modification/ctime, locked reinstall recipes, ambiguous package managers, live working directories and capture descriptors, apply-time recipe changes, custom outputs amid valuable build-folder media, fixture isolation from the real compiler cache, metadata-only growth reads, bounded/invalid baseline persistence, full-hash clone verification, permissions and xattrs, independent writes, changed keepers, recreated paths, staged Recovery copies and refusal to erase an edited replacement. Existing boundary, APFS, installer, archive and Recovery regressions also passed. Positive inactivity tests advance only the injected clock because ctime cannot be backdated.

## Native evidence

The compiled app was exercised through native accessibility and screenshot APIs with real disposable files, in light/dark appearances and 880×580 / 1100×740 content sizes.

- Cache defaults and private totals remained readable, with running Chrome disabled. The new Find More Space menu exposed generated-output and inactive-project reviews. The recent fixture was correctly retained, with a readable empty state and skipped reason.
- Keyboard sidebar navigation, refresh, selection and Escape cancellation worked. Growth exposed useful accessible row names, private-byte deltas and explicit baseline controls. A 16 KiB fixture addition appeared as +16 KB while refresh left the saved reference unchanged. Codex storage measurement displayed its history-preservation explanation.
- The sharing sheet showed the selected path, retained counterpart, private estimate and permanent Recovery step. Cancellation preserved selection. Native sharing then kept both capture paths, displayed zero private bytes for the extra copy and cleared selection. File contents and erased fixture journal states were checked afterward. A subsequent refresh removed the previous success receipt.
- A light-mode primary-button contrast defect was repaired using explicit appearance-aware text labels while preserving native styles, roles, focus and shortcuts. Light and dark rendered checks confirmed readable contrasting labels. Apple's [tint documentation](https://developer.apple.com/documentation/swiftui/view/tint(_:)) documents the platform distinction between bezel and label tint.
- A generic sharing confirmation rendered blank in the native capture. The final implementation uses the same native SwiftUI sheet approach as existing exact cleanup review; its contents and actions rendered and executed correctly.

Native and automated verification changed only disposable fixtures. The separately authorized old-project cleanup is not test evidence. No real chat, source or personal data was used as a mutation fixture. Task-owned native and sanitizer fixtures were removed.

## Limits

Runtime checks used the listed Apple silicon host. macOS 14 is the compiled deployment target, not a claim of an executed older-runtime matrix. Intel, a full VoiceOver session, every accessibility preference, network disks, actual power loss and every third-party app were not exercised. Native folder-picker and permission cases retain their earlier scope limits. Process checks cover visible user-owned working directories, executable/argument paths and vnode descriptors; inaccessible/racing references remain an OS limitation. Linked Git worktrees and unsupported reinstall recipes require manual review.

The bundle is locally signed and is not notarized. Recovery staging does not free space. Private, shared, hard-linked and unverified bytes remain distinct; neither allocation nor a private-byte delta promises an equal change in available space.

## Verdict

**ACCEPT** for the implemented macOS CLI/app scope on the tested runtime and the verified Apple silicon drag-and-drop DMG.
