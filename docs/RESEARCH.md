# Research behind Bleach

Inspected 29 October 2026. Research informs an original implementation; it is not a claim of universal superiority.

## Baseline

[Mole](https://github.com/tw93/Mole) CLI at `a52876330b34705b488b3a7ef525cacc05d461df` already has clean, uninstall, optimize, analyze, status, purge, installer, slim, dry runs, exclusions and history. Its Analyze command has JSON output, concurrent scans and hard-link accounting. A native interface alone is not a differentiator: [Mole for Mac](https://mole.fit/) is a separate existing product. The official repository identifies `mole.fit` as its official app site; similarly named sites were excluded from this research.

Mole's [safety documentation](https://github.com/tw93/Mole/blob/a52876330b34705b488b3a7ef525cacc05d461df/SECURITY_AUDIT.md#known-limitations-and-future-work), M01–M04, explicitly records permanent cleanup without general undo, partial multi-file outcomes, and no transaction/crash-recovery guarantee. Bleach targets these workflow boundaries with journaled recovery batches and cross-interface restoration. Existing Mole protections are substantial; symlink checks, idle-owner checks, dry runs and size accounting are baseline expectations, not novel inventions.

## Other product evidence

| Primary source | Relevant finding | Bleach decision |
| --- | --- | --- |
| [Pearcleaner](https://github.com/alienator88/Pearcleaner#features) | App cleanup combines inventory, related files, exclusions and CLI access. Its current source is fair-code licensed. | Exact app identity and explicit related-file review; no source or visual assets copied. |
| [Czkawka](https://github.com/qarmin/czkawka) | Duplicate discovery and large-file review are useful alongside cleanup; one core serves multiple interfaces. | Add duplicate and space workflows to the same shared engine. |
| [fclones](https://github.com/pkolaczk/fclones) | File identity, staged grouping and content hashing matter; parallelism differs by device. | Group by size before full SHA-256, exclude hard-link aliases, stream content and bound work. No hash-only shortcut. |
| [Apple: Undo and redo](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo) | Recovery should be discoverable through native commands and keyboard shortcuts. | Recovery sidebar and Edit → Undo Cleanup, plus CLI batch IDs. |
| [Apple: Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) | State the consequence of destructive work at the decision point. | Separate recoverable move from explicit permanent deletion. |

## Filesystem and platform evidence

| Primary source | Engineering consequence |
| --- | --- |
| [Apple: About APFS](https://developer.apple.com/documentation/foundation/about-apple-file-system) | Sparse logical length and allocated bytes differ; clones can share storage; volume free space is shared. Report estimates honestly and measure actual volume availability separately. |
| [Apple: URL resource keys](https://developer.apple.com/documentation/foundation/urlresourcekey) | Symlink, regular-file and cloud state are distinct. Do not traverse aliases or download cloud placeholders to clean them. |
| [Apple: Trash API](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)) | A Trash move may rename its destination. Bleach instead uses its own named recovery slots and journals their exact original paths. |
| [Apple: Filesystem use](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively) | File operations can fail and should stay off the UI thread. Partial/unreadable scans remain visible and never authorize a partial target. |
| [Apple: File access and Full Disk Access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) | Permissions cannot be silently granted. Surface unavailable paths; do not escalate to root or pretend an unreadable directory is empty. |
| [Apple: App Sandbox](https://developer.apple.com/documentation/security/app-sandbox) | Mac App Store distribution requires sandboxing. This local direct-distribution utility has no App Store or notarization claim. |

The search result for MacPaw's “Measure Twice, Cut Once” report returned 404 when opened. It is not used as implementation or benchmark evidence.

## Improvements to prove

The 0.2.0 follow-up researched and implemented [additional discovery methods](DISCOVERY.md): manifest-aware workspaces, full-content expanded ZIPs and installed-app installer identity. ZIPFoundation's pinned upstream API and source were inspected, including its iterator's silent early termination; independent directory-count validation prevents a partial archive from becoming a copy proof. The comparison now includes incremental allocated coverage, retained decoys and apply/undo evidence, not just scan speed. No claim of inventing these ideas first is made.

1. Recoverable cleanup across caches, build artifacts, installers and selected duplicates; restore a CLI cleanup in the app and vice versa.
2. A saved, inspectable preview that refuses replaced or changed targets, rather than rerunning an unrelated cleanup.
3. Journal reconciliation after interruption and no-overwrite recovery.
4. Exact-content duplicate review and clear per-item reasons, costs and exclusions.
5. A native CLI/app pair with identical policy and persistent exclusions.
6. Reproducible scan measurements against the pinned Mole Analyze binary. Do not claim a speedup before measurement; report slower cases too.

## Coverage limits

This is not an attempt to duplicate Mole's entire mature catalog, paid app features, fan controls, architecture stripping, privileged system maintenance or hundreds of vendor-specific recipes. Bleach's measurable claims concern the implemented workflows and controlled benchmarks. Real concurrent owners can start after a final check; metadata is not an atomic lease on a third-party directory. Recovery minimizes consequences but cannot make that operating-system race disappear. Recovery journals are local user-owned records, not tamper-proof audit evidence.
