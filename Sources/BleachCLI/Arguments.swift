import BleachCore
import Foundation

struct Arguments {
    var command = ""
    var positionals: [String] = []
    var flags: Set<String> = []
    var values: [String: [String]] = [:]

    static let commands = ["scan", "discover", "inactive", "growth", "share", "clean", "apply", "analyze", "duplicates", "apps", "uninstall", "history", "undo", "empty", "protect", "config", "status", "completion"]
    private static let valueOptions: Set<String> = ["root", "state", "output", "select", "projects", "category", "min-size", "limit", "keep", "add-project", "remove-project", "age-days"]
    private static let switches: Set<String> = ["json", "yes", "dry-run", "no-color", "help", "version", "licenses", "all", "with-data", "watch", "remove", "record"]
    private static let aliases = ["-h": "--help", "-v": "--version", "-n": "--dry-run", "-y": "--yes", "-j": "--json"]

    init(_ input: [String]) throws {
        var index = 0
        var positionalOnly = false
        while index < input.count {
            let token = Self.aliases[input[index]] ?? input[index]
            index += 1
            if token == "--" { positionalOnly = true; continue }
            if !positionalOnly && token.hasPrefix("-") {
                guard token.hasPrefix("--") else { throw BleachError("Unknown option \(token). Use --help.") }
                let parts = token.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                if Self.switches.contains(name) {
                    guard parts.count == 1 else { throw BleachError("--\(name) does not take a value") }
                    flags.insert(name)
                } else if Self.valueOptions.contains(name) {
                    let value: String
                    if parts.count == 2 { value = String(parts[1]) }
                    else {
                        guard index < input.count, !input[index].hasPrefix("--") else { throw BleachError("--\(name) needs a value") }
                        value = input[index]; index += 1
                    }
                    guard !value.isEmpty else { throw BleachError("--\(name) needs a value") }
                    if !["projects", "select"].contains(name), values[name] != nil { throw BleachError("--\(name) was supplied more than once") }
                    values[name, default: []].append(value)
                } else { throw BleachError("Unknown option --\(name). Use --help.") }
            } else if command.isEmpty { command = token }
            else { positionals.append(token) }
        }
        guard command.isEmpty || Self.commands.contains(command) else { throw BleachError("Unknown command '\(Display.terminalSafe(command))'. Use bleach --help.") }
        let common: Set<String> = ["root", "state", "json", "no-color", "help", "version", "licenses"]
        let allowed: [String: Set<String>] = [
            "": [], "scan": ["projects", "category", "output"], "discover": ["output"], "inactive": ["output"],
            "growth": ["record"],
            "share": ["select", "yes", "dry-run"],
            "clean": ["projects", "category", "select", "all", "yes", "dry-run"],
            "apply": ["select", "all", "yes", "dry-run"],
            "analyze": ["limit"], "duplicates": ["output", "min-size", "keep"],
            "apps": [], "uninstall": ["output", "yes", "dry-run", "with-data"],
            "history": [], "undo": ["yes"], "empty": ["yes", "dry-run"],
            "protect": ["remove"], "config": ["add-project", "remove-project", "age-days"],
            "status": ["watch"], "completion": []
        ]
        let unsupported = flags.union(values.keys).subtracting(common.union(allowed[command] ?? []))
        if let option = unsupported.sorted().first { throw BleachError("--\(option) is not valid for '\(command)'") }
        let maxPositionals = ["discover": 1, "inactive": 1, "growth": 1, "share": 1, "apply": 1, "analyze": 1, "duplicates": 1, "uninstall": 1, "undo": 1, "empty": 1, "protect": 1, "completion": 1][command] ?? 0
        guard positionals.count <= maxPositionals else { throw BleachError("Too many arguments for '\(command)'") }
    }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func value(_ name: String) -> String? { values[name]?.first }
    func url(_ string: String) -> URL {
        let url = URL(fileURLWithPath: (string as NSString).expandingTildeInPath)
        return URL(fileURLWithPath: Files.lexicalPath(url.path))
    }
    func integer(_ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = value(name) else { return fallback }
        guard let value = Int(raw), range.contains(value) else { throw BleachError("--\(name) must be between \(range.lowerBound) and \(range.upperBound)") }
        return value
    }
}
