<p align="center">
  <img src="docs/assets/bleach-icon.png" width="96" height="96" alt="Bleach icon">
</p>
<h1 align="center">Bleach</h1>
<p align="center">A little more room. A way back.</p>
<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-242424?logo=apple&amp;logoColor=white" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&amp;logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Privacy-Local_only-555555" alt="Local only">
</p>

Bleach reviews caches, logs, installers, build artifacts, apps and duplicate files. Use the native Mac app or the `bleach` command. Both share one cleanup engine, the same exclusions and the same recovery history. Its original monochrome icon follows the local Tuck and Snap family.

## Clean up

Open Bleach and choose **Scan Your Mac**. Scanning changes nothing. Rebuildable caches start selected, including recent caches and package-manager caches. The large number shows private bytes in your selection and updates as you select or deselect items. Shared blocks appear separately. Installers, project artifacts and personal app data wait for your choice. Known running app caches are marked **In use** and stay unselected.

On first use, macOS may ask to access Downloads while looking for installers. Respond to that system dialog to let the scan continue, or cancel the scan in Bleach.

Select a row to see its path, size, why it was found and what removing it changes. **Review Cleanup…** shows the exact selection before moving it to **Recovery**.

Recovery keeps files on disk. Restore a batch to put its files back, or choose **Delete Permanently…** to remove them. Blocks shared with another file or snapshot may remain. Bleach never empties your Mac’s Trash. A recreated original path is kept alongside the recovery copy until you resolve the conflict.

## Find more space

Choose **Find More Space** after a scan, or press **⇧⌘F**. It adds evidence-backed items to the same review:

- **Forgotten project artifacts:** discovers dependency/build folders beside valid project manifests in common workspace folders. Source stays in place; each generated folder needs your choice.
- **Already expanded ZIPs:** checks every supported archived file against its adjacent expanded folder with full SHA-256 and ZIP integrity checks. This finds redundant compressed copies that ordinary duplicate-file hashes miss.
- **Already-installed app installers:** matches a ZIP app installer or an already-mounted DMG to an installed app by bundle ID, version and build. A matching filename is insufficient. Different versions remain unmarked; offline backups can still be worth keeping.

These items start unchecked. The app reports their private bytes separately and keeps the large number tied to your actual selection. Installed apps, project source and expanded folders stay in place. Archive contents and installed-app identity are rechecked before a cleanup moves anything.

In the controlled coverage fixture, these methods found **220 MiB beyond the quick scan's 16 MiB**, including every expected item and none of the mismatched/unsafe/upgrade decoys. This is a constructed fixture, not a typical-Mac savings claim. See [discovery evidence, reproduction and format limits](docs/DISCOVERY.md).

## In the terminal

Run `bleach` for the keyboard-controlled menu. Use **↑ / ↓** or **j / k** to move, **Space** to select, **a** to select suggested items, **Return** to review and **q** to cancel.

```sh
bleach scan                              # Read-only cleanup review
bleach discover                          # Find projects, expanded ZIPs and installed-app installers
bleach discover ~/Projects --output more.json
bleach clean                             # Choose items and confirm a recoverable cleanup
bleach analyze ~/Downloads               # Separate private and shared disk usage
bleach duplicates ~/Documents            # Compare complete file contents
bleach apps                              # List installed apps
bleach uninstall /Applications/App.app -n # Preview app removal
bleach history                           # Inspect recovery batches
bleach undo                              # Restore the latest recoverable batch
bleach empty <batch>                      # Confirm permanent deletion of one batch
```

Save a preview to review or apply later:

```sh
bleach scan --output preview.json
bleach apply preview.json --dry-run
bleach apply preview.json
```

Saved plans expire after 24 hours. Bleach rechecks file identity, recursive metadata, exclusions and running owners before moving anything. A changed item requires a fresh scan. When applying a plan, choose individual paths or the IDs shown in terminal output with repeated `--select` options.

`--json` produces structured output. `--yes` confirms a requested operation in scripts; redirected input never counts as confirmation. `NO_COLOR` and `--no-color` disable color. Generate completion with `bleach completion zsh`, `bash` or `fish`.

## More ways to make room

| View | What it does |
| --- | --- |
| Space | Ranks folders and files by private disk usage, with shared allocation shown separately. Drill into a folder or reveal a file in Finder. |
| Duplicates | Groups equal-length files by full SHA-256. Choose which copy to keep; review the extras before cleanup. |
| Applications | Reviews a user-owned app and exact bundle-ID matches. Personal data is a separate choice; shared app-group data stays in place. |
| Recovery | Shares cleanup batches between the CLI and app. Interrupted moves are reconciled from their journal. |
| System | Shows measured CPU, memory, swap and disk availability. |

Add project folders in **Settings**, or use `bleach config --add-project ~/Projects`. Bleach recognizes `node_modules`, `.build`, `target` and `.next` beside matching manifests. It keeps source files. Exclude a folder with `bleach protect <path>` or the item’s context menu; the exclusion applies to both interfaces.

## APFS and references

Bleach asks macOS for each file's private allocation (`ATTR_CMNEXT_PRIVATESIZE`) rather than treating `du`-style allocation as a savings estimate. The CLI and app use the same accounting:

| Size | Meaning |
| --- | --- |
| Private | Bytes macOS reports as belonging only to that file, outside clones and snapshots. This drives the large number and Space ranking. |
| Allocated | Blocks attributed to the files. APFS clones can each report the same shared blocks, so this total can exceed physical usage. |
| Logical | File contents' length. Sparse files can have a large logical size with little allocation. |

A fully shared APFS clone can show **2 MB allocated, 0 KB private**. A partially changed clone contributes only its private extents. Shared or snapshot-retained bytes are shown separately, including when the other clone is outside the scanned folder. Bleach does not search your whole disk for the other copy.

Hard links are counted once and excluded from the private estimate. Symbolic links and Finder aliases never add their targets' contents; mounted volumes are not traversed. Unsupported or unavailable private-size metadata is labeled **unverified** and excluded from the private number. Older saved plans remain usable but their sizes are unverified until rescanned.

Private bytes are a conservative per-file measure, not an exact folder footprint or promised free-space gain. Removing every copy in a clone or hard-link group may free more. Shared-byte totals can include repeated references to the same blocks. Allocation can change after scanning, and moving files to Recovery frees no space.

## Improvements over Mole CLI

Bleach builds on the workflows researched in [Mole](https://github.com/tw93/Mole), with an original implementation:

- Recoverable cleanup batches with cross-interface undo and per-item interruption recovery.
- Exact saved previews that reject changed targets and newly excluded files.
- Full-content duplicate review with a retained copy revalidated before cleanup.
- Native tables, item explanations, keyboard commands and shared CLI/app state.
- APFS private/shared accounting across cleanup, duplicate review and folder analysis.
- Read-only analysis [timings, source revision, method and limits](docs/benchmarks/results.md) are recorded with raw results. Those earlier allocation-only timings do not measure the added APFS metadata queries.

Mole has a broader catalog of vendor-specific recipes and system maintenance. Bleach does not alter system services, strip signed apps, purge memory or promise a general Mac speedup. See the [research](docs/RESEARCH.md) for the comparison and sources.

## Download

Download the latest [release](https://github.com/upsidedly/bleach/releases/latest), open the `.dmg`, and drag **Bleach** into **Applications**. These builds are for Apple silicon Macs. Quit an older Bleach before replacing it.

The app is locally signed and is not notarized. macOS may require first-launch approval in **System Settings → Privacy & Security**.

The bundled CLI is at `/Applications/Bleach.app/Contents/MacOS/bleach`.

## Install from source

Use macOS 14 or later with Swift 6 and the macOS SDK. From this folder:

```sh
./scripts/install.sh
open /Applications/Bleach.app
~/.local/bin/bleach
```

Add `~/.local/bin` to your `PATH` to use `bleach` directly. Quit Bleach before updating. The installer signs locally and backs up an earlier app or unrelated CLI.

For a build without installation, run `./scripts/build.sh`. The outputs are `build/Bleach.app` and `build/bleach`.

## Privacy and limits

Bleach uses no network, account, telemetry, privileged helper or background cleaner. Cleanup stays within recognized user-owned locations. Credentials, browser profiles, photo libraries, known cloud roots and shared application groups are outside automatic cleanup. Unreadable targets are skipped with a reason. Grant Full Disk Access in System Settings only if you want to inspect additional protected locations.

Recovery uses same-volume moves; cross-volume cleanup is refused. Available space may differ from allocated bytes because APFS clones, snapshots, hard links and other apps can share or change disk allocation. A running owner can start after its last check; the recovery journal reduces consequences but does not lock third-party applications.

## Development

Run `./scripts/test.sh` for core tests and `./scripts/check.sh` for tests plus CLI integration checks. The test script supports the installed Command Line Tools Testing framework without changing the global Xcode selection.

See [development notes](docs/DEVELOPMENT.md), [verification](docs/VERIFICATION.md) and the [benchmark](docs/benchmarks/results.md).

ZIP reading uses exact-pinned ZIPFoundation 0.9.20; [its MIT notice](docs/THIRD-PARTY-NOTICES.md) is included in the app and `bleach --licenses`. No archive is extracted or installer launched during discovery.
