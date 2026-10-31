import BleachCore
import CryptoKit
import Darwin
import Foundation

struct Console {
    let color: Bool
    var interactive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["TERM"] != "dumb" }
    init(noColor: Bool = false) {
        color = !noColor && isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil && ProcessInfo.processInfo.environment["TERM"] != "dumb"
    }
    func style(_ text: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    func strong(_ text: String) -> String { style(text, "1") }
    func muted(_ text: String) -> String { style(text, "38;5;245") }
    func success(_ text: String) -> String { style(text, "38;5;108") }
    func warning(_ text: String) -> String { style(text, "38;5;180") }
    func clean(_ text: String) -> String { Display.terminalSafe(text) }
    func banner(_ detail: String) {
        print("\n  \(strong("◩  bleach"))  \(muted(detail))\n")
    }
    func note(_ text: String) { print("  \(muted(clean(text)))") }
    func json<T: Encodable>(_ value: T) throws {
        let data = try JSONCoding.encoder().encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    static func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

    static func shortID(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    func plan(_ plan: CleanupPlan, home: URL) {
        banner("\(plan.candidates.count) items · \(Display.duration(plan.duration))")
        if plan.candidates.isEmpty { print("  Nothing to clean in the scanned locations.") }
        for category in CleanupCategory.allCases {
            let items = plan.candidates.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            print("  \(strong(category.title))")
            for candidate in items {
                let marker = candidate.recommendation == .suggested ? success("●") : candidate.recommendation == .blocked ? warning("–") : muted("○")
                let size = Display.bytes(candidate.privateBytes).padding(toLength: 11, withPad: " ", startingAt: 0)
                print("  \(marker) \(size) \(clean(candidate.title))  \(muted(Self.shortID(candidate.path)))")
                print("                \(muted(clean(Display.path(candidate.path, home: home))))")
                if !candidate.storage.details.isEmpty { note("              \(Display.bytes(candidate.allocatedBytes)) allocated · \(candidate.storage.details)") }
                if let reason = candidate.blockedReason { print("                \(warning(clean(reason)))") }
                if candidate.installerProof != nil { print("                \(muted(clean(candidate.reason)))") }
            }
            print("")
        }
        print("  \(strong(Display.bytes(plan.suggestedPrivateBytes))) private bytes suggested · \(Display.bytes(plan.storage.privateBytes)) private across all candidates")
        note("\(Display.bytes(plan.totalBytes)) allocated\(plan.storage.details.isEmpty ? "" : " · " + plan.storage.details)")
        note("Sizes show private bytes. Shared, hard-linked and unverified allocation is excluded.")
        note("● Suggested   ○ Review   – In use")
        if !plan.issues.isEmpty {
            print("\n  \(warning("\(plan.issues.count) skipped or unavailable locations"))")
            for issue in plan.issues.prefix(8) { note("\(Display.path(issue.path, home: home)): \(issue.message)") }
            if plan.issues.count > 8 { note("Use --json to inspect every skipped location.") }
        }
        print("")
    }

    func receipt(_ batch: RecoveryBatch) {
        banner("batch \(batch.shortID)")
        let restored = batch.items.filter { $0.state == .restored }.count
        let erased = batch.items.filter { $0.state == .erased }.count
        if batch.movedCount > 0 {
            print("  \(success("✓")) \(batch.movedCount) items moved to recovery · \(strong(Display.bytes(batch.heldBytes))) allocated")
            note("No space is freed while these files are kept for recovery.")
            print("\n  Restore       \(strong("bleach undo \(batch.shortID)"))")
            print("  Free space    \(strong("bleach empty \(batch.shortID)"))")
        }
        if restored > 0 { print("  \(success("✓")) \(restored) items restored") }
        if erased > 0 { print("  \(success("✓")) \(erased) items deleted permanently") }
        if batch.problemCount > 0 {
            print("\n  \(warning("\(batch.problemCount) items need review"))")
            for item in batch.items where item.message != nil {
                note("\(item.candidate.title): \(item.message ?? "")")
            }
        }
        if batch.items.allSatisfy({ $0.state == .failed }) { note("No cleanup items moved.") }
        print("")
    }

    func confirm(_ message: String, yes: Bool) throws -> Bool {
        if yes { return true }
        guard interactive else { throw BleachError("Confirmation requires a terminal. Review --dry-run, then pass --yes to confirm this action.") }
        print("  \(message) [y/N] ", terminator: "")
        fflush(stdout)
        guard let input = readLine() else { return false }
        return input.lowercased() == "y" || input.lowercased() == "yes"
    }

    func disk(_ report: DiskReport, home: URL) {
        banner("Space · \(Display.duration(report.duration))")
        print("  \(strong(clean(Display.path(report.path, home: home))))\n")
        let maximum = max(1, report.entries.first?.storage.privateBytes ?? 1)
        for entry in report.entries.prefix(30) {
            let blocks = Int(Double(entry.storage.privateBytes) / Double(maximum) * 20)
            let bar = String(repeating: "━", count: blocks).padding(toLength: 20, withPad: " ", startingAt: 0)
            let size = Display.bytes(entry.storage.privateBytes).padding(toLength: 11, withPad: " ", startingAt: 0)
            print("  \(muted(bar))  \(size) \(entry.isSymbolicLink ? "↗" : entry.isDirectory ? "▸" : "·") \(clean(entry.name))")
            if !entry.storage.details.isEmpty { note("                        \(Display.bytes(entry.allocatedBytes)) allocated · \(entry.storage.details)") }
        }
        print("\n  \(strong(Display.bytes(report.storage.privateBytes))) private · \(Display.bytes(report.allocatedBytes)) allocated · \(Display.bytes(report.logicalBytes)) logical · \(report.fileCount) files")
        if !report.storage.details.isEmpty { note(report.storage.details) }
        note(StorageUsage.explanation)
        if !report.issues.isEmpty { note("Partial scan: \(report.issues.count) locations could not be read. Use --json for details.") }
        print("")
    }
}

enum TerminalKey { case up, down, space, enter, all, quit, other }

struct TerminalInput {
    private var saved = termios()
    private var active = false
    mutating func begin() -> Bool {
        guard tcgetattr(STDIN_FILENO, &saved) == 0 else { return false }
        var raw = saved
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return false }
        active = true
        return true
    }
    mutating func end() {
        if active { _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved); active = false }
    }
    private func byte() -> UInt8? {
        var value: UInt8 = 0
        return Darwin.read(STDIN_FILENO, &value, 1) == 1 ? value : nil
    }
    func key() -> TerminalKey {
        guard let first = byte() else { return .quit }
        switch first {
        case 3, 4, 113: return .quit
        case 32: return .space
        case 10, 13: return .enter
        case 97: return .all
        case 107: return .up
        case 106: return .down
        case 27:
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 30) > 0, byte() == 91, let third = byte() else { return .quit }
            return third == 65 ? .up : third == 66 ? .down : .other
        default: return .other
        }
    }
}

extension Console {
    /// System terminal semantics, with all output restored on normal and Ctrl-C
    /// paths. No raw input is entered when stdin/stdout are redirected.
    func menu() -> String? {
        let options = [("scan", "Clean up", "Review caches, logs, installers and developer data"),
                       ("discover", "Find More Space", "Discover project artifacts and verified expanded ZIPs"),
                       ("analyze", "Explore space", "See what is taking up room"),
                       ("duplicates", "Find duplicates", "Compare full file contents"),
                       ("apps", "Applications", "List apps and preview removal"),
                       ("history", "Recovery", "Restore or permanently delete a batch"),
                       ("status", "System", "Read CPU, memory and disk statistics")]
        var input = TerminalInput()
        guard interactive, input.begin() else { return nil }
        print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")
        defer { input.end(); print("\u{1B}[?25h\u{1B}[?1049l", terminator: ""); fflush(stdout) }
        var cursor = 0
        while true {
            var screen = "\u{1B}[H\u{1B}[2J\n  \(strong("◩  bleach"))  \(muted("A little more room."))\n\n"
            for (index, option) in options.enumerated() {
                screen += "  \(index == cursor ? strong("› " + option.1) : "  " + option.1)\n"
                screen += "    \(muted(option.2))\n\n"
            }
            screen += "  \(muted("↑ ↓  move    enter  open    q  quit"))\n"
            FileHandle.standardOutput.write(Data(screen.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            switch input.key() {
            case .up: cursor = (cursor - 1 + options.count) % options.count
            case .down: cursor = (cursor + 1) % options.count
            case .enter: return options[cursor].0
            case .quit: return nil
            default: break
            }
        }
    }

    func choose(from plan: CleanupPlan, home: URL) -> Set<String>? {
        guard !plan.candidates.isEmpty else { return [] }
        var input = TerminalInput()
        guard interactive, input.begin() else { return nil }
        print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")
        defer { input.end(); print("\u{1B}[?25h\u{1B}[?1049l", terminator: ""); fflush(stdout) }
        var selected = Set(plan.suggested.map(\.path))
        var cursor = 0
        while true {
            var dimensions = winsize()
            _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &dimensions)
            let pageSize = max(3, min(14, Int(dimensions.ws_row) - 18))
            let pageStart = (cursor / pageSize) * pageSize
            let total = plan.candidates.filter { selected.contains($0.path) }.reduce(Int64(0)) { $0 + $1.privateBytes }
            var screen = "\u{1B}[H\u{1B}[2J\n  \(strong("◩  bleach"))  \(muted("Review cleanup"))\n\n"
            screen += "  \(strong(Display.bytes(total))) private selected · \(selected.count) items\n"
            screen += "  \(muted("Recovery moves free no space. Shared blocks can remain after deletion."))\n\n"
            for index in pageStart..<min(plan.candidates.count, pageStart + pageSize) {
                let candidate = plan.candidates[index]
                let mark = candidate.recommendation == .blocked ? "–" : selected.contains(candidate.path) ? "●" : "○"
                let line = "\(index == cursor ? "›" : " ") \(mark)  \(Display.bytes(candidate.privateBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(clean(candidate.title))"
                screen += "  \(index == cursor ? strong(line) : line)\n"
            }
            let focused = plan.candidates[cursor]
            screen += "\n  \(muted(clean(Display.path(focused.path, home: home))))\n"
            screen += "  \(muted(clean("\(Display.bytes(focused.allocatedBytes)) allocated\(focused.storage.details.isEmpty ? "" : " · " + focused.storage.details)")))\n"
            screen += "  \(clean(focused.blockedReason ?? focused.reason))\n"
            screen += "  \(muted(clean(focused.consequence)))\n\n"
            screen += "  \(muted("↑ ↓ move   space select   a suggested   enter review   q cancel"))\n"
            FileHandle.standardOutput.write(Data(screen.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            switch input.key() {
            case .up: cursor = (cursor - 1 + plan.candidates.count) % plan.candidates.count
            case .down: cursor = (cursor + 1) % plan.candidates.count
            case .space:
                guard focused.recommendation != .blocked else { continue }
                if selected.contains(focused.path) { selected.remove(focused.path) } else { selected.insert(focused.path) }
            case .all: selected = Set(plan.suggested.map(\.path))
            case .enter: return selected
            case .quit: return nil
            default: break
            }
        }
    }
}
