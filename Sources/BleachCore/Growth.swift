import BleachFS
import Foundation

public struct GrowthEntry: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var previous: StorageUsage?
    public var current: StorageUsage?
    public var privateChange: Int64? {
        previous == nil ? nil : (current?.privateBytes ?? 0) - (previous?.privateBytes ?? 0)
    }
}

public struct GrowthReport: Codable, Sendable {
    public var path: String
    public var sampledAt: Date
    public var previousDate: Date?
    public var entries: [GrowthEntry]
    public var storage: StorageUsage
    public var previousStorage: StorageUsage?
    public var availableOnVolume: Int64
    public var recorded: Bool
    public var issues: [ScanIssue]
    public var privateChange: Int64? { previousStorage.map { storage.privateBytes - $0.privateBytes } }
}

private struct GrowthSample: Codable {
    var path: String
    var identity: String
    var date: Date
    var storage: StorageUsage
    var entries: [DiskEntry]
}

private struct GrowthHistory: Codable {
    var schema = 1
    var samples: [GrowthSample] = []
}

extension BleachEngine {
    /// One complete, cancellable physical scan. Only an explicit record action
    /// writes a bounded metadata baseline; transcripts and file contents are not read.
    public func growth(in folder: URL, context: ScanContext, record: Bool = false) throws -> GrowthReport {
        let root = Files.canonicalURL(folder)
        guard Files.pathIsWithin(root.path, context.home.path), try Files.stamp(root.path).kind == 2 else { throw BleachError("Choose a local folder inside this home") }
        let identity = try Files.stamp(root.path).identity
        let disk = try analyze(root, largestLimit: 0)
        var issues = disk.issues
        if disk.entries.count > 256 { issues.append(ScanIssue(path: root.path, message: "More than 256 direct children; choose a smaller folder. No baseline was saved.")) }
        let store = RecoveryStore(context: context)
        var lock: Int32 = -1
        if record && issues.isEmpty { try store.ensureStorage(); lock = try store.lock() }
        defer { bl_close(lock) }
        let file = context.state.appendingPathComponent("growth.json")
        var history = GrowthHistory()
        if try Files.optionalStamp(file.path) != nil {
            history = try JSONCoding.decoder().decode(GrowthHistory.self, from: Files.readPrivateFile(file, limit: 2_000_000))
            guard history.schema == 1, history.samples.count <= 8, Set(history.samples.map(\.path)).count == history.samples.count,
                  history.samples.allSatisfy({ sample in sample.entries.count <= 256 && Set(sample.entries.map(\.path)).count == sample.entries.count && sample.entries.allSatisfy { entry in URL(fileURLWithPath: entry.path).deletingLastPathComponent().path == sample.path } }) else { throw BleachError("Invalid growth history; existing metadata retained") }
        }
        let before = issues.isEmpty ? history.samples.first { $0.path == root.path && $0.identity == identity } : nil
        let current = Dictionary(uniqueKeysWithValues: disk.entries.prefix(256).map { ($0.path, $0) })
        let previous = Dictionary(uniqueKeysWithValues: (before?.entries ?? []).map { ($0.path, $0) })
        let paths = Set(current.keys).union(previous.keys)
        let entries = paths.map { path in
            GrowthEntry(path: path, previous: before == nil ? nil : previous[path]?.storage ?? StorageUsage(), current: current[path]?.storage)
        }.sorted {
            let left = $0.privateChange ?? $0.current?.privateBytes ?? 0, right = $1.privateChange ?? $1.current?.privateBytes ?? 0
            return left == right ? $0.path < $1.path : left > right
        }
        try Task.checkCancellation()
        let shouldRecord = record && issues.isEmpty
        if shouldRecord {
            guard try Files.stamp(root.path).identity == identity else { throw BleachError("Folder changed during measurement; baseline retained") }
            history.samples.removeAll { $0.path == root.path }
            history.samples.append(GrowthSample(path: root.path, identity: identity, date: context.now, storage: disk.storage, entries: disk.entries))
            history.samples.sort { $0.date == $1.date ? $0.path < $1.path : $0.date > $1.date }
            history.samples = Array(history.samples.prefix(8))
            let data = try JSONCoding.encoder().encode(history)
            guard data.count <= 2_000_000 else { throw BleachError("Growth metadata limit reached; baseline retained") }
            try Files.atomicWrite(data, directory: context.state, name: "growth.json")
        }
        return GrowthReport(path: root.path, sampledAt: context.now, previousDate: before?.date, entries: entries,
            storage: disk.storage, previousStorage: before?.storage, availableOnVolume: SystemReader.disk(at: root).available,
            recorded: shouldRecord, issues: issues)
    }
}
