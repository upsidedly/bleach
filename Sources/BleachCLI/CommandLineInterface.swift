import AppKit
import BleachCore
import BleachMCP
import Darwin
import Foundation

enum CommandLineInterface {
    static func run() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            if arguments.has("version") { print("bleach \(BleachVersion.current)"); return }
            if arguments.has("licenses") { print(ThirdPartyNotices.text); return }
            if arguments.has("help") { print(help); return }
            let console = Console(noColor: arguments.has("no-color"))
            let engine = BleachEngine()
            let home = arguments.value("root").map(arguments.url) ?? FileManager.default.homeDirectoryForCurrentUser
            let state = arguments.value("state").map(arguments.url)
            let needsOwners = arguments.command.isEmpty || ["scan", "clean", "apply", "apps", "uninstall"].contains(arguments.command)
            let owners = needsOwners ? await RunningApplications.snapshot() : []
            let context = ScanContext(home: home, state: state, runningOwners: owners)
            var command = arguments.command
            let fromMenu = command.isEmpty && console.interactive && !arguments.has("json")
            if fromMenu {
                guard let selected = console.menu() else { return }
                command = selected
            }
            if command.isEmpty { print(help); return }
            switch command {
            case "mcp":
                guard !arguments.has("allow-permanent-delete") || arguments.has("allow-mutations") else { throw BleachError("--allow-permanent-delete also requires --allow-mutations") }
                try await BleachMCPServer.run(home: home, state: state, allowMutations: arguments.has("allow-mutations"), allowPermanentDelete: arguments.has("allow-permanent-delete"))
            case "scan", "clean":
                if !arguments.has("json") { console.note("Scanning local files…") }
                var plan = try await engine.scan(context: context, additionalProjectRoots: (arguments.values["projects"] ?? []).map(arguments.url))
                if let rawCategory = arguments.value("category") {
                    guard let category = CleanupCategory(rawValue: rawCategory) else { throw BleachError("Unknown category. Use caches, browsers, logs, developer, builds or installers.") }
                    plan.candidates = plan.candidates.filter { $0.category == category }
                }
                if command == "scan", !fromMenu {
                    try export(plan, arguments: arguments)
                    if arguments.has("json") { try console.json(plan) } else { console.plan(plan, home: context.home); console.note("bleach clean to choose items · --output plan.json to save an exact preview") }
                } else { try await clean(plan: plan, arguments: arguments, console: console, engine: engine, context: context) }
            case "inactive":
                let plan = try await engine.inactiveProjects(in: arguments.positionals.first.map(arguments.url), context: context)
                try export(plan, arguments: arguments)
                if arguments.has("json") { try console.json(plan) }
                else {
                    console.plan(plan, home: context.home)
                    console.note("Inactive dependencies only. Source, Git, lockfiles and chat context stay. Save with --output plan.json, then bleach apply plan.json.")
                }
            case "discover":
                if !arguments.has("json") { console.note("Finding project artifacts and verifying expanded ZIP contents…") }
                let report = try await engine.discover(in: arguments.positionals.first.map(arguments.url), context: context)
                try export(report.plan, arguments: arguments)
                if arguments.has("json") { try console.json(report) }
                else {
                    console.plan(report.plan, home: context.home)
                    console.note("\(report.projectsFound) projects · \(report.archivesMatched)/\(report.archivesCompared) ZIP pairs matched · \(report.verifiedArchiveFiles) archived files verified · \(report.installedInstallers) installers match installed apps")
                    console.note("\(Display.bytes(report.plan.storage.privateBytes)) private bytes to review. Project source and expanded folders stay in place.")
                    if fromMenu { try await clean(plan: report.plan, arguments: arguments, console: console, engine: engine, context: context) }
                    else { console.note("Save with --output plan.json, then bleach apply plan.json to choose items.") }
                }
            case "share":
                guard let raw = arguments.positionals.first else { throw BleachError("Usage: bleach share duplicates.json [--select path] [--dry-run | --yes]") }
                var plan = try JSONCoding.decoder().decode(CleanupPlan.self, from: boundedRead(arguments.url(raw), limit: 64_000_000))
                if let selectors = arguments.values["select"] {
                    let paths = Set(selectors.map { arguments.url($0).path })
                    guard paths.isSubset(of: Set(plan.candidates.map(\.path))) else { throw BleachError("A selected path is missing from this preview") }
                    plan = plan.selecting(paths)
                }
                guard plan.origin == "duplicates", !plan.candidates.isEmpty,
                      plan.candidates.allSatisfy({ StorageSharing.isGeneratedCapture($0.path) && $0.duplicateProof.map { StorageSharing.isGeneratedCapture($0.keeperPath) } == true }) else { throw BleachError("Select only generated Playwright captures from a duplicate preview") }
                if arguments.has("dry-run") {
                    if arguments.has("json") { try console.json(plan) } else { console.plan(plan, home: context.home); console.note("Dry run: paths and contents remain unchanged.") }
                    return
                }
                guard try console.confirm("Share storage for \(plan.candidates.count) copies? Both paths and file contents stay. Verified originals are permanently erased from this specific Recovery batch.", yes: arguments.has("yes")) else { return }
                let receipt = try await engine.shareDuplicateStorage(plan, context: context)
                if arguments.has("json") { try console.json(receipt) }
                else { console.receipt(receipt.batch); console.note("\(receipt.pathsPreserved) copy paths preserved using clones. Review Recovery if any original was retained.") }
                if receipt.batch.problemCount > 0 { exit(2) }
            case "apply":
                guard let path = arguments.positionals.first else { throw BleachError("Usage: bleach apply plan.json [--dry-run | --yes]") }
                let data = try boundedRead(arguments.url(path), limit: 64_000_000)
                let plan = try JSONCoding.decoder().decode(CleanupPlan.self, from: data)
                try await clean(plan: plan, arguments: arguments, console: console, engine: engine, context: context, saved: true)
            case "growth":
                guard let raw = arguments.positionals.first else { throw BleachError("Usage: bleach growth <folder> [--record] [--json]") }
                let report = try await engine.growth(in: arguments.url(raw), context: context, record: arguments.has("record"))
                if arguments.has("json") { try console.json(report) }
                else {
                    console.banner("Growth · \(console.clean(Display.path(report.path, home: context.home)))")
                    for entry in report.entries {
                        let delta = entry.privateChange.map { ($0 >= 0 ? "+" : "−") + Display.bytes(abs($0)) } ?? "baseline"
                        print("  \(console.clean(delta))  \(console.clean(Display.path(entry.path, home: context.home)))")
                    }
                    console.note("\(Display.bytes(report.availableOnVolume)) available on volume. Private changes can reflect sharing; they are not a free-space receipt.")
                    console.note(report.recorded ? "Complete metadata baseline saved locally; at most 8 folders, 256 direct children each." : "Read-only comparison. Use --record to save the next baseline.")
                    for issue in report.issues { console.note(issue.message) }
                }
            case "analyze":
                let path = arguments.positionals.first.map(arguments.url) ?? context.home
                let limit = try arguments.integer("limit", default: 60, range: 0...1000)
                let report = try await engine.analyze(path, largestLimit: limit)
                if arguments.has("json") { try console.json(report) } else { console.disk(report, home: context.home) }
            case "duplicates":
                let path = arguments.positionals.first.map(arguments.url) ?? context.homeURL("Downloads")
                let minimum = try arguments.integer("min-size", default: 1, range: 1...Int.max)
                if !arguments.has("json") { console.note("Comparing full file contents in \(Display.path(path.path, home: context.home))…") }
                var report = try await engine.duplicates(in: path, context: context, minimumSize: Int64(minimum))
                if let keeper = arguments.value("keep") { report = try await engine.retaining(arguments.url(keeper).path, in: report) }
                try export(report.plan, arguments: arguments)
                if arguments.has("json") { try console.json(report) }
                else {
                    console.banner("Duplicates · \(report.groups.count) groups")
                    for group in report.groups {
                        print("  \(console.strong(Display.bytes(group.bytesPerFile))) logical each · \(group.files.count) copies")
                        for (index, file) in group.files.enumerated() {
                            print("  \(index == 0 ? console.success("keep") : "copy")  \(console.clean(Display.path(file, home: context.home)))")
                        }
                        print("")
                    }
                    console.note("\(report.filesHashed) files hashed out of \(report.filesInspected) inspected. Hard-link aliases and cloud files are excluded.")
                    console.note("\(Display.bytes(report.plan.storage.privateBytes)) private in extra copies · \(Display.bytes(report.plan.totalBytes)) allocated including shared blocks.")
                    if fromMenu { try await clean(plan: report.plan, arguments: arguments, console: console, engine: engine, context: context) }
                    else { console.note("Save with --output plan.json, then bleach apply plan.json to choose copies.") }
                }
            case "apps":
                let apps = try await engine.installedApps(context: context)
                if arguments.has("json") { try console.json(apps) }
                else {
                    console.banner("\(apps.count) applications")
                    for app in apps {
                        print("  \(app.running ? console.success("●") : console.muted("·")) \(console.clean(app.name)) \(console.muted(app.version))")
                        console.note("  \(Display.path(app.path, home: context.home))\(app.removable ? "" : " · protected")")
                    }
                    print("")
                    console.note("bleach uninstall /Applications/Example.app --dry-run")
                }
            case "uninstall":
                guard let path = arguments.positionals.first else { throw BleachError("Usage: bleach uninstall /Applications/Example.app --dry-run") }
                let plan = try await engine.uninstallPlan(appPath: arguments.url(path), context: context)
                try export(plan, arguments: arguments)
                if arguments.value("output") != nil || arguments.has("dry-run") {
                    if arguments.has("json") { try console.json(plan) } else { console.plan(plan, home: context.home) }
                } else {
                    var selected = plan
                    if !arguments.has("with-data") { selected.candidates.removeAll { $0.category == .appData } }
                    try await clean(plan: selected, arguments: arguments, console: console, engine: engine, context: context, saved: true)
                }
            case "history":
                let history = try await engine.history(context: context)
                if arguments.has("json") { try console.json(history) }
                else {
                    console.banner("Recovery")
                    if history.isEmpty { print("  No cleanup batches yet.\n") }
                    for batch in history {
                        print("  \(console.strong(batch.shortID))  \(batch.createdAt.formatted(date: .abbreviated, time: .shortened))  \(Display.bytes(batch.heldBytes)) allocated · \(batch.recoverable.count) recoverable\(batch.problemCount > 0 ? " · \(batch.problemCount) need review" : "")")
                    }
                    print("")
                    console.note("bleach undo <batch> to restore · bleach empty <batch> to delete permanently")
                }
            case "undo", "empty":
                let history = try await engine.history(context: context)
                let batch = try resolveBatch(arguments.positionals.first, history: history, requireID: command == "empty")
                if command == "empty", arguments.has("dry-run") {
                    if arguments.has("json") { try console.json(batch) } else { console.receipt(batch); console.note("Dry run: no files changed.") }
                    return
                }
                let count = batch.recoverable.count + (command == "empty" ? batch.interruptedDeletions.count : 0)
                guard count > 0 else { throw BleachError("This batch has no \(command == "undo" ? "recoverable" : "retained") items") }
                if command == "empty" {
                    guard try console.confirm("Delete \(count) items from batch \(batch.shortID) permanently? This cannot be undone.", yes: arguments.has("yes")) else { console.note("Cancelled."); return }
                }
                let receipt = command == "undo" ? try await engine.restore(batch: batch.id, context: context) : try await engine.erase(batch: batch.id, context: context)
                if arguments.has("json") { try console.json(receipt) } else { console.receipt(receipt) }
                if receipt.problemCount > 0 { exit(2) }
            case "protect":
                var preferences = try await engine.preferences(context: context)
                if let raw = arguments.positionals.first {
                    let path = arguments.url(raw).path
                    if arguments.has("remove") { preferences.excludedPaths.removeAll { $0 == path } }
                    else if !preferences.excludedPaths.contains(path) { preferences.excludedPaths.append(path); preferences.excludedPaths.sort() }
                    try await engine.updatePreferences(preferences, context: context)
                } else if arguments.has("remove") { throw BleachError("Usage: bleach protect --remove <path>") }
                if arguments.has("json") { try console.json(preferences) }
                else {
                    console.banner("Protected paths")
                    if preferences.excludedPaths.isEmpty { console.note("No custom exclusions. Built-in protections always apply.") }
                    for path in preferences.excludedPaths { print("  \(console.clean(Display.path(path, home: context.home)))") }
                    print("")
                }
            case "config":
                var preferences = try await engine.preferences(context: context)
                var changed = false
                if let raw = arguments.value("add-project") {
                    let path = arguments.url(raw).path
                    if !preferences.projectRoots.contains(path) { preferences.projectRoots.append(path) }
                    changed = true
                }
                if let raw = arguments.value("remove-project") { preferences.projectRoots.removeAll { $0 == arguments.url(raw).path }; changed = true }
                if arguments.value("age-days") != nil { preferences.minimumAgeDays = try arguments.integer("age-days", default: 30, range: 30...3650); changed = true }
                if changed { try await engine.updatePreferences(preferences, context: context) }
                try console.json(preferences)
            case "status":
                if arguments.has("watch"), !console.interactive { throw BleachError("--watch requires a terminal. Use bleach status --json for scripts.") }
                repeat {
                    let sample = try await SystemReader.sample(at: context.home)
                    if arguments.has("watch") { print("\u{1B}[H\u{1B}[2J", terminator: "") }
                    if arguments.has("json") { try console.json(sample) }
                    else {
                        console.banner("System · \(sample.hostname)")
                        print("  CPU       \(sample.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Unavailable") · \(sample.processorCount) cores")
                        print("  Memory    \(Display.bytes(Int64(sample.memoryUsed))) / \(Display.bytes(Int64(sample.memoryTotal)))")
                        print("  Swap      \(sample.swapUsed.map { Display.bytes(Int64($0)) } ?? "Unavailable")")
                        print("  Disk      \(sample.diskAvailable < 0 ? "Unavailable" : Display.bytes(sample.diskAvailable) + " available / " + Display.bytes(sample.diskTotal))")
                        print("  Uptime    \(Int(sample.uptime / 3600))h\n")
                        console.note(arguments.has("watch") ? "Updates every 2 seconds. Ctrl-C to stop." : "Measured from macOS. No health score or memory-boost claims.")
                    }
                    if !arguments.has("watch") { break }
                    try await Task.sleep(for: .seconds(2))
                } while !Task.isCancelled
            case "completion":
                let shell = arguments.positionals.first ?? "zsh"
                switch shell {
                case "zsh": print("#compdef bleach\n_arguments '1:command:(\(Arguments.commands.joined(separator: " ")))' '*:file:_files'")
                case "bash": print("complete -W '\(Arguments.commands.joined(separator: " ")) --help --json --dry-run --yes --output --projects' bleach")
                case "fish":
                    for command in Arguments.commands { print("complete -c bleach -f -a \(command)") }
                default: throw BleachError("Choose zsh, bash or fish")
                }
            default: print(help)
            }
        } catch is CancellationError { Console.stderr("bleach: cancelled. Review bleach history for interrupted work."); exit(130) }
        catch { Console.stderr("bleach: \(Display.terminalSafe(error.localizedDescription))"); exit(1) }
    }

    private static func clean(plan: CleanupPlan, arguments: Arguments, console: Console, engine: BleachEngine,
                              context: ScanContext, saved: Bool = false) async throws {
        var selected: Set<String>
        if let selectors = arguments.values["select"] {
            selected = []
            for selector in selectors {
                let matches = plan.candidates.filter { $0.path == arguments.url(selector).path || Console.shortID($0.path) == selector.lowercased() }
                guard matches.count == 1, let candidate = matches.first else { throw BleachError("Selection '\(selector)' is missing or ambiguous") }
                selected.insert(candidate.path)
            }
        } else if arguments.has("all") || saved { selected = Set(plan.candidates.filter { $0.recommendation != .blocked }.map(\.path)) }
        else { selected = Set(plan.suggested.map(\.path)) }
        if console.interactive && !arguments.has("yes") && !arguments.has("dry-run") && !arguments.has("json") {
            var review = plan
            if saved { review.candidates = review.candidates.map { var item = $0; if selected.contains(item.path) && item.recommendation != .blocked { item.recommendation = .suggested }; return item } }
            guard let choice = console.choose(from: review, home: context.home) else { console.note("Cancelled."); return }
            selected = choice
        }
        let chosen = plan.selecting(selected)
        if arguments.has("dry-run") {
            if arguments.has("json") { try console.json(chosen) } else { console.plan(chosen, home: context.home); console.note("Dry run: no files changed.") }
            return
        }
        guard !chosen.candidates.isEmpty else {
            if arguments.has("json") { try console.json(chosen) }
            else { console.note("Nothing selected. Use --select <id> or --all to include reviewed items.") }
            return
        }
        if !arguments.has("json") { console.plan(chosen, home: context.home) }
        let permanent = arguments.has("permanent")
        let question = permanent ? "Permanently delete \(chosen.candidates.count) reviewed items? This cannot be undone. Existing Recovery batches stay." : "Move \(chosen.candidates.count) items to recovery? Files stay recoverable until you delete this batch."
        guard try console.confirm(question, yes: arguments.has("yes")) else {
            console.note("Cancelled."); return
        }
        let receipt = try await (permanent ? engine.deletePermanently(chosen, context: context) : engine.apply(chosen, context: context))
        if arguments.has("json") { try console.json(receipt) } else { console.receipt(receipt) }
        if receipt.problemCount > 0 { exit(2) }
    }

    private static func export(_ plan: CleanupPlan, arguments: Arguments) throws {
        guard let path = arguments.value("output") else { return }
        let url = arguments.url(path)
        try JSONCoding.encoder().encode(plan).write(to: url, options: .withoutOverwriting)
        Console.stderr("Saved preview: \(Display.terminalSafe(url.path))")
    }

    private static func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw BleachError("Plan is too large") }
        return data
    }

    private static func resolveBatch(_ selector: String?, history: [RecoveryBatch], requireID: Bool) throws -> RecoveryBatch {
        guard let selector else {
            guard !requireID, let latest = history.first(where: { !$0.recoverable.isEmpty }) else { throw BleachError("Choose a batch from bleach history") }
            return latest
        }
        let matches = history.filter { $0.id.uuidString.lowercased().hasPrefix(selector.lowercased()) }
        guard selector.count >= 4, matches.count == 1, let batch = matches.first else { throw BleachError("Batch ID is missing or ambiguous. Use bleach history.") }
        return batch
    }

    static let help = """
    ◩  bleach — a little more room.

    Inspect first. Choose precisely. Keep a way back.

    USAGE
      bleach                           Interactive terminal menu
      bleach scan                      Review caches, logs and installers
      bleach discover [folder]         Find project artifacts and verified expanded ZIPs
      bleach clean                     Choose items and move them to recovery
      bleach inactive [folder]         Review old dependencies with locked reinstall recipes
      bleach growth <folder> [--record] Compare private allocation; explicitly save metadata
      bleach share duplicates.json     Keep capture paths using APFS clones; confirm erasure
      bleach analyze [folder]          Separate private, shared and logical space
      bleach duplicates [folder]       Find full-content duplicates (Downloads by default)
      bleach apps                      List installed applications
      bleach uninstall <app>           Review removal; personal app data stays by default
      bleach history                   List cleanup and recovery batches
      bleach undo [batch]              Restore a batch (latest recoverable by default)
      bleach empty <batch>             Delete one recovery batch permanently
      bleach protect [path]            Exclude a path, or list custom exclusions
      bleach protect --remove <path>   Remove an exclusion
      bleach config                    Read preferences as JSON
      bleach status [--watch]          Read real CPU, memory and disk statistics
      bleach mcp                       Local MCP server over stdio (read only)
      bleach completion [zsh|bash|fish] Print shell completion

    EXACT PREVIEWS
      bleach scan --output plan.json
      bleach apply plan.json --dry-run
      bleach apply plan.json           Review and confirm the exact saved targets

    OPTIONS
      --json                           Machine-readable output, no color or banners
      --dry-run, -n                    Preview clean, apply, uninstall or empty
      --yes, -y                        Confirm the requested operation without a prompt
      --select <path|id>               Choose a scan/apply item; may be repeated
      --all                            Choose all non-busy items, including review items
      --projects <folder>              Scan project artifacts; may be repeated
      --category <name>                Restrict scan/clean to a category
      --with-data                      Include exact app-data matches when uninstalling
      --record                         Save a complete growth baseline (at most 8 folders)
      --permanent                      Delete reviewed clean/apply/uninstall items irreversibly
      --allow-mutations                MCP: expose move-to-Recovery and restore tools
      --allow-permanent-delete         MCP: also expose irreversible selected-item deletion
      --keep <path>                    Choose the retained copy in a duplicate group
      --output <file>                  Export a plan from scan, duplicates or uninstall
      --root <home>                    Inspect a different user home (also for fixtures)
      --state <folder>                 Use a private state folder inside that home
      --no-color                       Disable color; NO_COLOR is also respected
      --version, -v                    Print version
      --licenses                       Print bundled dependency notices
      --help, -h                       Print this help

    PREFERENCES
      bleach config --add-project ~/Projects
      bleach config --remove-project ~/Projects
      bleach config --age-days 30       # Minimum log age; caches start selected

    Recovery files still use disk space. Empty a specific batch to free it.
    Emptying a batch cannot be undone. Bleach never empties your Mac's Trash.
    Run as your normal user. No sudo, account, server or telemetry.
    """
}
