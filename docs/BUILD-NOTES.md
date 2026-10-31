# Bleach build record

## Intent

Build an original Mac cleaner with a command-line interface and native SwiftUI application. Match the restrained monochrome icon family and literal, centered-icon/badge README convention of the local Tuck and Snap projects. Both interfaces link the same Swift engine; neither shells out to Mole. No competitor source is incorporated.

Primary task: inspect space, understand each candidate, choose precisely, move a reviewed batch into recovery, and either restore it or explicitly delete it permanently. Secondary tasks: disk drill-down, exact duplicate review, app removal, exclusions, and real system statistics.

## Platform and authority

- Build mode, Intentional+ Swift; My Taste and Ponytail are advisors.
- macOS 14+, Swift 6, Apple Silicon authoring machine; no iOS or Android claim.
- Keyboard and pointer, standard window/menus, native lists, tables, file panels and confirmation dialogs.
- Default macOS appearance; light/dark, minimum 880 × 580 and a larger desktop window.
- Local-only, no accounts, telemetry, privileged helper, network, launch daemon or automatic deletion.
- Create `QOL/Bleach`; inspect Tuck/Snap, leave their files alone. No publication authorized.
- Verification may mutate disposable fixtures only, never the user's real cleanup candidates.

## Architecture and consequential decisions

`BleachCLI` and `BleachApp` → `BleachCore` → small `BleachFS` POSIX boundary. SwiftUI owns presentation; an actor owns scanning and storage operations; immutable Sendable records cross the boundary. Foundation/CryptoKit/AppKit/Darwin provide platform operations. Version 0.2 adds exact-pinned ZIPFoundation 0.9.20 for streamed ZIP reads, preserving its MIT notice and package resources.

- A saved cleanup plan records exact paths, identities and recursive metadata fingerprints; apply rechecks rule eligibility, exclusions, running owners, home, plan lifetime and current snapshots.
- Quarantine is on the same volume. Same-volume rename preserves file data and metadata; a write-ahead manifest records pending/moved/restored/erased outcomes. Cross-volume moves are refused rather than copied then deleted.
- Cleanup is recoverable by default. Permanent deletion only operates on a specifically selected Bleach recovery batch. It never empties the user's Trash.
- Recovery never overwrites an original path recreated by an app. A conflicting item remains in recovery.
- Physical allocation and logical file length are separate. Hard links are counted once per inventory. APFS shared extents/snapshots and other disk activity prevent a guarantee that estimated allocation equals newly available volume space.
- Exclusions persist and apply at scan and mutation time. Unreadable/malformed exclusions fail closed.
- Known regenerable caches are eligible; developer artifacts need matching project manifests; installers and user files require deliberate review. Credentials, browser profiles, photo libraries, cloud roots, source code and shared application groups are excluded from automatic cleanup.
- Per Matthew's feedback, all eligible rebuildable caches start selected regardless of age. Known running-owner caches remain blocked. The header tracks the actual selected allocation, matching the footer; the age preference applies to logs.
- Duplicate discovery groups by length before full streaming SHA-256. Physical hard links are not duplicate savings. One copy is retained and its content revalidated before moving another.
- App removal uses exact bundle identifiers, never fuzzy name deletion; app data is never selected automatically.

## Evidence plan

Build both executables with strict Swift 6 checks. Test actual fixture filesystem boundaries: symlinks and linked ancestors, partial scans, changed descendants, overlap, exclusions changed after scan, no-overwrite restore, journal reconciliation, concurrent-process lock, malformed plans, root refusal, hard links, sparse allocation, duplicate identity/content and app-data boundaries. Exercise CLI JSON, invalid options, noninteractive confirmation and end-to-end apply/undo/erase against a disposable home. Benchmark pinned Mole Analyze JSON and Bleach Analyze JSON on identical fixtures with alternating repeated runs and exact inventory checks. Inspect actual native renders and automate the fixture scan/recovery flow. Record measured outcomes and untested platform limits here and in the research/benchmark notes.

## Environment inspected

macOS 27.2, Apple Swift 6.3.2, arm64. Command Line Tools are selected. Full Xcode 27.1 is present but `xcodebuild -showsdks` asks for license acceptance; use the existing Command Line Tools SDK where possible without changing system settings or accepting legal terms.

## Additional space discovery

Requested outcome: find additional, evidenced space opportunities beyond the quick cache scan. Intentional+ Swift remains the sole owner in Build mode, with Research and My Taste as advisors. Preserve the native layout, automatic cache selection, exact preview and recovery contracts.

- Automatically discover generated dependency/build trees beside matching manifests in common workspace folders, without requiring each repository to be configured. These remain manual review, with source/manifest context; modification time is not proof of disuse.
- Detect an adjacent ZIP and expanded folder by comparing every supported archive file with the corresponding local file using full SHA-256. Byte-identical archive files themselves are not required, so this finds redundancy ordinary file duplicate hashes miss. Retain the expanded folder; never extract an archive while scanning.
- Archive evidence must be revalidated for the complete selection before any move and again immediately before its move. Reject selected keepers, unsafe paths, links, cloud placeholders, unsupported metadata, encrypted/corrupt archives, changed copies and configured exclusions. Bound directory traversal, entries, expanded bytes and elapsed work.
- Use exact-pinned ZIPFoundation for streaming ZIP reads rather than a custom ZIP parser or private system-library declarations. This adds one MIT dependency; preserve its notice and package resources. Revisit if its reader cannot satisfy bounded no-write operation from a pinned file descriptor.
- Prove incremental allocated coverage against the current quick scan on a controlled fixture. Exercise archive false positives, keeper changes, path traversal, resource bounds and actual recoverable apply/undo. Inspect the real native action and resulting evidence in compact layout; retain unrelated passing checks.
- Matthew additionally requested installers for apps already installed. Compare exact bundle ID, version and build in ZIP app installers and already-mounted DMGs. Retain other versions and unsupported formats for ordinary review; never classify from filenames alone, mount images automatically or execute installer code.
