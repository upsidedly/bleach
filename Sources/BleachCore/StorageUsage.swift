import BleachFS
import Foundation

/// Mutually exclusive allocation buckets, not a prediction of free-space gain.
/// Private bytes exclude every multiply-linked inode, even when all its names
/// happen to be inside the scan. Removing whole clone/link groups can free more.
public struct StorageUsage: Codable, Equatable, Sendable {
    public var privateBytes: Int64 = 0
    public var sharedBytes: Int64 = 0
    public var hardLinkedBytes: Int64 = 0
    public var unverifiedBytes: Int64 = 0
    public var sharedFiles: Int = 0
    public var cloneFiles: Int = 0
    public var hardLinkedFiles: Int = 0
    public var symbolicLinks: Int = 0

    public init() {}
    init(_ value: BLStorage) {
        privateBytes = value.private_bytes; sharedBytes = value.shared_bytes
        hardLinkedBytes = value.hard_linked_bytes; unverifiedBytes = value.unverified_bytes
        sharedFiles = Int(value.shared_files); cloneFiles = Int(value.clone_files)
        hardLinkedFiles = Int(value.hard_linked_files); symbolicLinks = Int(value.symbolic_links)
    }
    static func unverified(_ allocated: Int64) -> Self {
        var value = Self(); value.unverifiedBytes = allocated; return value
    }
    public static func sum(_ values: some Sequence<Self>) -> Self {
        var total = Self()
        for value in values {
            total.privateBytes += value.privateBytes; total.sharedBytes += value.sharedBytes
            total.hardLinkedBytes += value.hardLinkedBytes; total.unverifiedBytes += value.unverifiedBytes
            total.sharedFiles += value.sharedFiles; total.cloneFiles += value.cloneFiles
            total.hardLinkedFiles += value.hardLinkedFiles; total.symbolicLinks += value.symbolicLinks
        }
        return total
    }
    public var allocatedBytes: Int64 { privateBytes + sharedBytes + hardLinkedBytes + unverifiedBytes }
    public var details: String {
        var parts: [String] = []
        if sharedBytes > 0 { parts.append("\(Display.bytes(sharedBytes)) shared or snapshot-retained") }
        if hardLinkedBytes > 0 { parts.append("\(Display.bytes(hardLinkedBytes)) hard-linked") }
        if unverifiedBytes > 0 { parts.append("\(Display.bytes(unverifiedBytes)) unverified") }
        if cloneFiles > 0 { parts.append("\(cloneFiles) full APFS \(cloneFiles == 1 ? "clone" : "clones")") }
        if symbolicLinks > 0 { parts.append("\(symbolicLinks) \(symbolicLinks == 1 ? "link" : "links") · targets excluded") }
        return parts.joined(separator: " · ")
    }
    public static let explanation = "Private bytes are reported by macOS as not shared with clones or snapshots. Hard-linked and unverified allocation is excluded. Removing a whole clone or hard-link group may free more. Recovery moves free no space; allocation can change after scanning."
}
