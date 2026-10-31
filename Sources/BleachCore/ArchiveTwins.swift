import BleachFS
import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

struct DiscoveryLimits: Sendable {
    var directories = 20_000
    var depth = 8
    var archives = 64
    var archiveEntries = 10_000
    var archiveBytes: Int64 = 8 * 1024 * 1024 * 1024
    var totalArchiveBytes: Int64 = 16 * 1024 * 1024 * 1024
    var archiveSeconds: TimeInterval = 30
    var seconds: TimeInterval = 120
}

enum ArchiveTwins {
    /// ZIPFoundation's sequence stops silently on an unreadable/encrypted
    /// header. Independently require the complete, single-disk ZIP32 envelope
    /// and compare its declared entry count with the successfully read entries.
    /// ZIP64, split archives and trailing data deliberately remain unsupported.
    private static func entryCount(fd: Int32, size: Int64, maximum: Int) throws -> Int {
        guard size >= 22 else { throw BleachError("Incomplete ZIP archive") }
        let count = Int(min(size, 65_557))
        var tail = [UInt8](repeating: 0, count: count)
        let read = tail.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(size - Int64(count))) }
        guard read == count else { throw BleachError("Could not read the complete ZIP directory") }
        func u16(_ index: Int) -> Int { Int(tail[index]) | Int(tail[index + 1]) << 8 }
        func u32(_ index: Int) -> Int64 { Int64(u16(index)) | Int64(u16(index + 2)) << 16 }
        for index in stride(from: count - 22, through: 0, by: -1) {
            guard tail[index..<(index + 4)].elementsEqual([0x50, 0x4b, 0x05, 0x06]),
                  index + 22 + u16(index + 20) == count else { continue }
            let entries = u16(index + 10)
            guard u16(index + 4) == 0, u16(index + 6) == 0, u16(index + 8) == entries,
                  entries > 0, entries < 65_535, entries <= maximum,
                  u32(index + 12) < 0xffff_ffff, u32(index + 16) < 0xffff_ffff,
                  u32(index + 16) + u32(index + 12) == size - Int64(count) + Int64(index) else {
                throw BleachError("ZIP64, split, empty or oversized archive retained for manual review")
            }
            return entries
        }
        throw BleachError("Incomplete ZIP directory or unsupported trailing data")
    }

    static func readArchive<T>(_ url: URL, maximumEntries: Int,
                               body: (Archive, Int) throws -> T) throws -> T {
        let original = try Files.stamp(url.path)
        guard original.kind == 1, original.links == 1, original.owner == getuid(), !original.dataless else {
            throw BleachError("Only a local, owned regular ZIP can be inspected")
        }
        let fd = bl_open_regular(url.path, original.device, original.inode)
        guard fd >= 0 else { throw Files.error(bl_last_error(), url.path) }
        defer { bl_close(fd) }
        let expected = try entryCount(fd: fd, size: original.size, maximum: maximumEntries)
        let archive = try Archive(url: URL(fileURLWithPath: "/dev/fd/\(fd)"), accessMode: .read)
        let result = try body(archive, expected)
        var after = BLStat()
        try Files.require(bl_stat_fd(fd, &after), url.path)
        guard FileStamp(after) == original, try Files.stamp(url.path) == original else {
            throw BleachError("ZIP changed during inspection; scan again")
        }
        return result
    }

    static func components(_ path: String, directory: Bool) throws -> [String] {
        let name = directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !name.isEmpty, !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              !path.contains("\u{fffd}"), !name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != "__MACOSX" }) else {
            throw BleachError("Unsafe, ambiguous or metadata-only ZIP path retained")
        }
        return parts
    }

    static func prove(_ url: URL, policy: CleanupPolicy, limits: DiscoveryLimits = DiscoveryLimits(),
                      consume: (Int64) throws -> Void = { _ in }) throws -> ArchiveProof {
        let started = Date()
        func check() throws {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(started) <= limits.archiveSeconds else {
                throw BleachError("ZIP comparison time limit reached; archive retained")
            }
        }
        let folder = url.deletingPathExtension()
        guard url.pathExtension.lowercased() == "zip", Files.pathIsWithin(url.path, policy.context.home.path),
              !policy.protectedUserPath(url.path), !policy.protectedUserPath(folder.path),
              policy.exclusionReason(url.path) == nil, policy.exclusionReason(folder.path) == nil else {
            throw BleachError("Archive or expanded folder is protected or excluded")
        }
        try Files.ensureRealDirectory(folder.path)
        let root = try Files.stamp(folder.path), original = try Files.stamp(url.path)
        guard root.kind == 2, root.owner == getuid(), !root.dataless,
              original.kind == 1, original.links == 1, original.owner == getuid(), !original.dataless,
              original.device == root.device else { throw BleachError("Only local, owned archive/folder pairs can be compared") }
        // The reader opens a duplicate of an already checked, read-only file
        // descriptor. It cannot follow a replacement of the original pathname.
        return try readArchive(url, maximumEntries: limits.archiveEntries) { archive, expectedCount in
        var entries: [(Entry, [String])] = []
        var seen: Set<String> = []
        var declaredBytes: Int64 = 0
        for entry in archive {
            try check()
            guard entries.count < expectedCount, entry.type != .symlink,
                  entry.type != .directory || entry.uncompressedSize == 0,
                  entry.uncompressedSize <= UInt64(max(0, limits.archiveBytes - declaredBytes)) else {
                throw BleachError("Linked or oversized ZIP content retained")
            }
            let parts = try components(entry.path, directory: entry.type == .directory)
            let identity = parts.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(identity).inserted else { throw BleachError("Repeated or case-colliding ZIP path retained") }
            entries.append((entry, parts))
            if entry.type == .file { declaredBytes += Int64(entry.uncompressedSize) }
        }
        guard entries.count == expectedCount else { throw BleachError("Encrypted, unsupported or incomplete ZIP entries retained") }
        let strip = entries.allSatisfy { entry, parts in
            parts.first == folder.lastPathComponent && (parts.count > 1 || entry.type == .directory)
        }
        var records: [String] = []
        var keepers: [(String, FileStamp)] = []
        var files = 0
        var verifiedBytes: Int64 = 0
        for (entry, rawParts) in entries {
            try check()
            let parts = strip ? Array(rawParts.dropFirst()) : rawParts
            if parts.isEmpty {
                guard entry.type == .directory else { throw BleachError("Ambiguous expanded archive path") }
                continue
            }
            let target = parts.reduce(folder) { $0.appendingPathComponent($1) }
            guard !policy.protectedUserPath(target.path), policy.exclusionReason(target.path) == nil else {
                throw BleachError("Protected content in the expanded archive; retained")
            }
            try Files.ensureRealDirectory(target.deletingLastPathComponent().path)
            let kept = try Files.stamp(target.path)
            guard kept.owner == getuid(), !kept.dataless, kept.device == root.device else {
                throw BleachError("Expanded copy is cloud-only, mounted or owned by another user")
            }
            if entry.type == .directory {
                guard kept.kind == 2 else { throw BleachError("Expanded folder structure does not match") }
                continue
            }
            guard kept.kind == 1, kept.size >= 0, UInt64(kept.size) == entry.uncompressedSize else {
                throw BleachError("Expanded file is missing, linked or has a different size")
            }
            var hash = SHA256()
            var bytes: Int64 = 0
            let checksum = try archive.extract(entry, bufferSize: 1_048_576) { chunk in
                try check()
                guard Int64(chunk.count) <= kept.size - bytes,
                      Int64(chunk.count) <= limits.archiveBytes - verifiedBytes - bytes else {
                    throw BleachError("ZIP expanded-byte limit reached; retained")
                }
                bytes += Int64(chunk.count)
                try consume(Int64(chunk.count))
                hash.update(data: chunk)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard bytes == kept.size, checksum == entry.checksum,
                  try Files.sha256(target.path, expected: kept, check: check) == digest else {
                throw BleachError("Expanded file contents differ from the ZIP archive")
            }
            verifiedBytes += bytes; files += 1
            keepers.append((target.path, kept))
            records.append(parts.joined(separator: "/") + "\0" + String(bytes) + "\0" + digest + "\0")
        }
        for (path, stamp) in keepers {
            try check()
            try Files.ensureRealDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            guard try Files.stamp(path) == stamp else { throw BleachError("Expanded copy changed during comparison; scan again") }
        }
        guard files > 0, try Files.stamp(folder.path) == root else { throw BleachError("Archive pair changed during comparison; scan again") }
        var contents = SHA256()
        for record in records.sorted() { contents.update(data: Data(record.utf8)) }
        return ArchiveProof(expandedPath: folder.path, expandedRoot: root, stripsRoot: strip,
            contentFingerprint: contents.finalize().map { String(format: "%02x", $0) }.joined(),
            fileCount: files, expandedBytes: verifiedBytes)
        }
    }
}
