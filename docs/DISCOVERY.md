# Finding additional space

Bleach 0.2.0 adds **Find More Space** to Clean up and `bleach discover [folder]` to the CLI. This is a read-only discovery step, followed by the existing exact preview and recoverable cleanup. It does not erase data, launch an installer or unpack archives to disk.

## Three methods

| Method | Evidence | What stays |
| --- | --- | --- |
| Workspace discovery | A generated folder beside a matching `package.json`, `Package.swift` or `Cargo.toml`. Next.js output also needs a Next dependency. Manifest age is context, never proof of disuse. | Manifests and source. Removing locally edited generated files can lose those edits; review is required. |
| Expanded ZIP | Every supported archived file matches a corresponding local file by full SHA-256, byte length and ZIP CRC. Directory structure must exist too. | The adjacent expanded folder. ZIP metadata and offline-backup value may differ. |
| Installed-app installer | A single-app ZIP's Info.plist, or an app on a mapped already-mounted DMG, matches an installed app's exact bundle ID, version and build. | The installed app. Payload byte identity is not claimed. Different or unknown versions do not qualify. |

Default workspace roots are `~/Projects`, `~/Developer`, `~/Code`, `~/code`, `~/Dev`, `~/src`, `~/Desktop/Projects`, `~/Documents/Projects`, `~/Documents/code`, `~/Downloads`, plus configured project roots. A supplied CLI folder restricts discovery to that folder. Exclusions and recognized protected/cloud roots remain authoritative. The tool does not descend into generated dependency trees looking for more candidates.

New discoveries start unchecked. The selected total still describes exactly what is checked; a separate line reports additional allocation discovered. Existing installer rows can gain installed-app evidence without counting their bytes twice.

## Recovery contract

Before moving anything, the complete selected plan is revalidated. Each item is checked again immediately before its move. Expanded ZIPs require a fresh content comparison and stable local keeper identities. A batch cannot also remove the expanded keeper or anything inside it. Installed-app installers require current matching app metadata; a batch cannot remove that app too. Replaced parents, linked keepers, changed files, exclusions, incomplete reads and malformed evidence cause refusal.

This is evidence at inspection time, not an operating-system lease on third-party files. Another process can still change a keeper after its final check. Files moved into recovery keep their disk allocation until the user explicitly deletes that batch.

## Measured incremental coverage

The constructed fixture contains a 16 MiB quick-scan cache, three unconfigured project folders with 208 MiB of generated data, an 8 MiB expanded ZIP, a 4 MiB ZIP for an installed app, and mismatched/unsafe/upgrade decoys.

| Measurement | Result |
| --- | ---: |
| Quick scan allocation | 16 MiB |
| Additional allocation discovered | 220 MiB, including ZIP/container overhead |
| Expected opportunities found | 5 of 5 |
| Decoys incorrectly offered | 0 |
| Independent allocation inventory | Matched |
| Selected fixture cleanup and undo | Passed; original identities restored |
| Expanded copies and installed app | Unchanged |

The combined fixture coverage is about 14.75× the quick scan. This fixture was deliberately constructed to exercise the new methods. It does not establish typical-Mac savings, a Mole coverage comparison or equal free-space gain on APFS. The CLI SHA-256, precise bytes, platform and timings are saved in [discovery.json](benchmarks/discovery.json).

Reproduce against a release build:

```sh
./scripts/build.sh
python3 scripts/verify-discovery.py --binary build/bleach
```

The script writes, moves, restores and removes its own temporary fixture only. It never uses the real home as its fixture.

## Deliberate limits

- ZIP32, single-disk archives with complete directories and stored/deflated entries are supported. ZIP64, encryption, trailing payloads, duplicate/case-colliding names, symlink entries in expanded-copy proofs, unsafe names and `__MACOSX` metadata are retained. Unsupported is not equivalent to unnecessary.
- An expanded ZIP must have an adjacent folder with the same stem, with either rooted or flat entry names. Additional unarchived files in that folder are allowed. An app installer ZIP must contain just one app bundle, optionally inside one wrapper directory; source archives containing an app are not classified as installers.
- DMGs are inspected only when already mounted and mapped to their actual image path by `hdiutil info -plist`. Discovery does not mount images, accept licenses, execute packages, infer `.pkg` receipts or claim to recognize unmounted images by filename. Unmatched DMG/PKG/XIP files remain in ordinary installer review.
- Work is bounded: 20,000 directories, depth 8, 64 ZIPs, 10,000 entries per ZIP, 8 GiB expanded data per archive, 16 GiB total archive data streamed, 30 seconds per expanded-copy comparison and a 120-second discovery budget. Limits produce skipped reasons. OS filesystem/permission calls can themselves remain pending; cancellation checks resume when those calls return.
- Installed-app matching is identity/version evidence, not a signature, trust assessment or proof every installer payload byte equals the installed app. No installer is automatically selected.

## Sources and decision

[ZIPFoundation's streaming-consumer API](https://github.com/weichsel/ZIPFoundation#closure-based-reading-and-writing) supplies ZIP reads without filesystem extraction; [release 0.9.20](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.20) is pinned in `Package.resolved`, with its [MIT notice](THIRD-PARTY-NOTICES.md) preserved. Bleach independently checks the ZIP32 directory entry count because the library iterator can stop on unsupported/encrypted entries; partial iteration must never become a complete-copy proof.

[npm's documented clean-install behavior](https://docs.npmjs.com/cli/v7/commands/npm-ci/) confirms that ordinary `node_modules` is reinstallable, but cannot prove a particular tree contains no local edits. This is why discovered build/dependency folders remain manual choices. APFS clone replacement, guessed browser-profile cache paths and VM compaction were deferred: each changes file identity or application-managed state and needs a separate, substantiated recovery contract.
