import Foundation

public enum BleachVersion {
    public static let current = "0.2.0"
    public static let planSchema = 1
}

public struct BleachError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct FileStamp: Codable, Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var links: UInt64
    public var size: Int64
    public var allocated: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public var changedSeconds: Int64
    public var changedNanoseconds: Int64
    public var mode: UInt32
    public var owner: UInt32
    public var flags: UInt32
    public var kind: Int
    public var dataless: Bool
    public var identity: String { "\(device):\(inode)" }
    public var modified: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1e9) }
}

public struct TreeSnapshot: Codable, Equatable, Sendable {
    public var root: FileStamp
    public var fingerprint: String
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var fileCount: Int
    public var entryCount: Int
    public var newestModification: Date
    public var hasCloudPlaceholder: Bool
    public var hasForeignOwner: Bool
    public var hasOtherVolume: Bool
}

public enum CleanupCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case caches, browsers, logs, developer, builds, installers, applications, appData, duplicates, archives
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .caches: "App caches"
        case .browsers: "Browser caches"
        case .logs: "Old logs"
        case .developer: "Developer caches"
        case .builds: "Build artifacts"
        case .installers: "Installers"
        case .applications: "Applications"
        case .appData: "App data"
        case .duplicates: "Duplicates"
        case .archives: "Expanded archives"
        }
    }
    public var symbol: String {
        switch self {
        case .caches: "square.stack.3d.up"
        case .browsers: "globe"
        case .logs: "doc.text"
        case .developer: "hammer"
        case .builds: "shippingbox"
        case .installers: "arrow.down.circle"
        case .applications: "app.dashed"
        case .appData: "folder.badge.gearshape"
        case .duplicates: "square.on.square"
        case .archives: "doc.zipper"
        }
    }
}

public enum RuleID: String, Codable, Sendable {
    case userCache, log, xcodeDerivedData, npmCache, pipCache, gradleCache, swiftPMCache
    case projectArtifact, installer, application, appRelatedData, duplicate, expandedArchive, archivedInstaller
    public var isRebuildableCache: Bool {
        switch self {
        case .userCache, .xcodeDerivedData, .npmCache, .pipCache, .gradleCache, .swiftPMCache: true
        default: false
        }
    }
}

public enum Recommendation: String, Codable, Sendable {
    case suggested, review, blocked
    public var label: String {
        switch self { case .suggested: "Suggested"; case .review: "Review"; case .blocked: "In use" }
    }
}

public struct DuplicateProof: Codable, Sendable, Equatable {
    public var keeperPath: String
    public var keeperStamp: FileStamp
    public var sha256: String
}

public struct ArchiveProof: Codable, Sendable, Equatable {
    public var expandedPath: String
    public var expandedRoot: FileStamp
    public var stripsRoot: Bool
    public var contentFingerprint: String
    public var fileCount: Int
    public var expandedBytes: Int64
}

public struct InstallerProof: Codable, Sendable, Equatable {
    public var installedPath: String
    public var bundleID: String
    public var version: String
    public var build: String
    public var installedInfo: FileStamp
    public var sourceInfoPath: String
}

public struct CleanupCandidate: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var title: String
    public var category: CleanupCategory
    public var rule: RuleID
    public var reason: String
    public var consequence: String
    public var recommendation: Recommendation
    public var blockedReason: String?
    public var snapshot: TreeSnapshot
    public var ownerBundleID: String?
    public var applicationPath: String?
    public var duplicateProof: DuplicateProof?
    public var archiveProof: ArchiveProof?
    public var installerProof: InstallerProof?
    public var allocatedBytes: Int64 { snapshot.allocatedBytes }
}

public struct ScanIssue: Codable, Sendable, Identifiable {
    public var id: String { path + message }
    public var path: String
    public var message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}

public struct DiscoveryReport: Codable, Sendable {
    public var plan: CleanupPlan
    public var roots: [String]
    public var directoriesVisited: Int
    public var projectsFound: Int
    public var archivesCompared: Int
    public var archivesMatched: Int
    public var verifiedArchiveFiles: Int
    public var verifiedExpandedBytes: Int64
    public var expandedBytesRead: Int64
    public var installedInstallers: Int
}

public struct CleanupPlan: Codable, Sendable, Identifiable {
    public var schemaVersion: Int = BleachVersion.planSchema
    public var id: UUID = UUID()
    public var createdAt: Date
    public var home: String
    public var origin: String
    public var candidates: [CleanupCandidate]
    public var issues: [ScanIssue]
    public var duration: Double
    public var scannedEntries: Int
    public var suggested: [CleanupCandidate] { candidates.filter { $0.recommendation == .suggested } }
    public var suggestedBytes: Int64 { suggested.reduce(0) { $0 + $1.allocatedBytes } }
    public var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.allocatedBytes } }

    public func selecting(_ paths: Set<String>) -> CleanupPlan {
        var copy = self
        copy.candidates = candidates.filter { paths.contains($0.path) }
        return copy
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var excludedPaths: [String] = []
    public var projectRoots: [String] = []
    public var minimumAgeDays: Int = 30
    public init() {}
    public func excludes(_ path: String) -> Bool {
        excludedPaths.contains { Files.pathIsWithin(path, $0) || Files.pathIsWithin($0, path) }
    }
}

public struct RunningOwner: Sendable {
    public var bundleID: String
    public var applicationPath: String
    public init(bundleID: String, applicationPath: String) { self.bundleID = bundleID; self.applicationPath = applicationPath }
}

public struct ScanContext: Sendable {
    public let home: URL
    public let state: URL
    public let now: Date
    public let runningOwners: [RunningOwner]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, state: URL? = nil,
                now: Date = Date(), runningOwners: [RunningOwner] = []) {
        self.home = Files.canonicalURL(home)
        self.state = (state ?? self.home.appendingPathComponent("Library/Application Support/Bleach"))
            .absoluteURL
        self.now = now
        self.runningOwners = runningOwners
    }
    public func homeURL(_ relative: String) -> URL { home.appendingPathComponent(relative) }
}

public enum RecoveryState: String, Codable, Sendable {
    case prepared, moved, restoring, restored, erasing, eraseInterrupted, erased, failed, conflict, missing
}

public struct RecoveryItem: Codable, Sendable, Identifiable {
    public var id: UUID
    public var candidate: CleanupCandidate
    public var slot: String
    public var state: RecoveryState
    public var message: String?
}

public struct RecoveryBatch: Codable, Sendable, Identifiable {
    public var schemaVersion: Int = 1
    public var id: UUID
    public var planID: UUID
    public var createdAt: Date
    public var home: String
    public var items: [RecoveryItem]
    public var finished: Bool
    public var availableBefore: Int64
    public var availableAfter: Int64
    public var recoverable: [RecoveryItem] { items.filter { [.moved, .conflict].contains($0.state) } }
    public var interruptedDeletions: [RecoveryItem] { items.filter { [.erasing, .eraseInterrupted].contains($0.state) } }
    public var heldBytes: Int64 { recoverable.reduce(0) { $0 + $1.candidate.allocatedBytes } }
    public var movedCount: Int { items.filter { $0.state == .moved }.count }
    public var problemCount: Int { items.filter { [.failed, .conflict, .missing, .eraseInterrupted].contains($0.state) }.count }
    public var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
}

public struct DiskEntry: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var fileCount: Int
}

public struct DiskReport: Codable, Sendable {
    public var path: String
    public var entries: [DiskEntry]
    public var largestFiles: [DiskEntry]
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var fileCount: Int
    public var entryCount: Int
    public var issues: [ScanIssue]
    public var duration: Double
    public var complete: Bool { issues.isEmpty }
}

public struct DuplicateGroup: Codable, Sendable, Identifiable {
    public var id: String { sha256 }
    public var sha256: String
    public var files: [String]
    public var bytesPerFile: Int64
}

public struct DuplicateReport: Codable, Sendable {
    public var path: String
    public var groups: [DuplicateGroup]
    public var plan: CleanupPlan
    public var filesInspected: Int
    public var filesHashed: Int
    public var bytesHashed: Int64
}

public struct InstalledApp: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var bundleID: String
    public var version: String
    public var running: Bool
    public var removable: Bool
}

public struct SystemSnapshot: Codable, Sendable {
    public var sampledAt: Date
    public var volumePath: String
    public var diskTotal: Int64
    public var diskAvailable: Int64
    public var memoryTotal: UInt64
    public var memoryUsed: UInt64
    public var memoryCompressed: UInt64
    public var swapUsed: UInt64?
    public var cpuPercent: Double?
    public var processorCount: Int
    public var uptime: Double
    public var hostname: String
}

public enum Display {
    public static func items(_ count: Int) -> String { "\(count) \(count == 1 ? "item" : "items")" }
    public static func bytes(_ count: Int64) -> String {
        if count == 0 { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
    public static func path(_ path: String, home: URL) -> String {
        path == home.path ? "~" : path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }
    public static func duration(_ seconds: Double) -> String { seconds < 1 ? String(format: "%.0f ms", seconds * 1_000) : String(format: "%.2f s", seconds) }
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let days = max(0, Int(now.timeIntervalSince(date) / 86_400))
        return days == 0 ? "Today" : days == 1 ? "1 day ago" : "\(days) days ago"
    }
    /// Filenames may contain terminal control sequences. Never print them raw.
    public static func terminalSafe(_ string: String) -> String {
        string.unicodeScalars.map { scalar in
            if scalar.value < 32 || (127...159).contains(scalar.value) {
                return String(format: "\\u{%02X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }
}

public enum JSONCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
