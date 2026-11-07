import Foundation

public struct AutomaticCleanupSettings: Codable, Equatable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable { case gigabytes = "GB", percent = "%" }
    public var enabled = false
    public var threshold = 10
    public var unit = Unit.gigabytes
    public var packageDownloads = true
    public var oldLogs = true
    public var pausedUntil: Date?
    public init() {}
    public var valid: Bool { (1...(unit == .percent ? 30 : 100)).contains(threshold) && (packageDownloads || oldLogs || !enabled) }
    public func targetBytes(total: Int64) -> Int64 {
        guard valid, total > 0 else { return 0 }
        return unit == .percent ? Int64(Double(total) * Double(threshold) / 100) : min(total, Int64(threshold) * 1_000_000_000)
    }
    public func shouldRun(total: Int64, available: Int64, now: Date) -> Bool {
        enabled && valid && total > 0 && available >= 0 && available < targetBytes(total: total) && (pausedUntil.map { $0 <= now } ?? true)
    }
    public func allows(_ item: CleanupCandidate, now: Date = Date()) -> Bool {
        guard item.recommendation == .suggested, item.privateBytes > 0,
              item.storage.sharedBytes == 0, item.storage.hardLinkedBytes == 0, item.storage.unverifiedBytes == 0 else { return false }
        if oldLogs && item.rule == .log { return now.timeIntervalSince(item.snapshot.newestModification) >= 90 * 86_400 }
        guard packageDownloads else { return false }
        if item.rule == .npmCache { return true }
        guard item.rule == .packageDownloadCache, let proof = item.cacheProof else { return false }
        switch proof.kind {
        case .npm, .cargoArchives: return true
        case .pip: return ["http", "http-v2", "selfcheck"].contains(URL(fileURLWithPath: item.path).lastPathComponent)
        case .npx, .gradle, .prisma, .goBuild: return false
        }
    }
}

extension BleachEngine {
    /// Journal first, erase only this newly created batch. Existing Recovery,
    /// source paths recreated by apps, and unrelated items are never swept.
    public func deletePermanently(_ plan: CleanupPlan, context: ScanContext) async throws -> RecoveryBatch {
        let moved = try await apply(plan, context: context)
        try Task.checkCancellation()
        guard moved.movedCount > 0 else { return moved }
        return try erase(batch: moved.id, context: context)
    }

    public func automaticCleanup(context: ScanContext) async throws -> RecoveryBatch? {
        try await runAutomaticCleanup(context: context, capacity: SystemReader.disk(at: context.home))
    }

    func runAutomaticCleanup(context: ScanContext, capacity disk: (total: Int64, available: Int64)) async throws -> RecoveryBatch? {
        let initial = try preferences(context: context)
        let settings = initial.automaticCleanup ?? AutomaticCleanupSettings()
        guard settings.shouldRun(total: disk.total, available: disk.available, now: context.now) else { return nil }
        let plan = try await scan(context: context, automaticOnly: true)
        try Task.checkCancellation()
        guard try preferences(context: context) == initial else { throw BleachError("Cleanup preferences changed; automatic cleanup stopped") }
        // A bounded pass; the next minute rechecks real available space rather
        // than assuming allocated/private bytes became free on this volume.
        let needed = settings.targetBytes(total: disk.total) - disk.available
        var bytes: Int64 = 0
        var selected: Set<String> = []
        for item in plan.candidates.filter({ settings.allows($0, now: context.now) }).sorted(by: { $0.privateBytes < $1.privateBytes }) {
            guard item.privateBytes <= 8_000_000_000 - bytes, selected.count < 32 else { continue }
            selected.insert(item.path); bytes += item.privateBytes
            if bytes >= needed { break }
        }
        guard !selected.isEmpty else { return nil }
        return try await deletePermanently(plan.selecting(selected), context: context)
    }
}
