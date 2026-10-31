import BleachFS
import CryptoKit
import Darwin
import Foundation

extension FileStamp {
    init(_ s: BLStat) {
        device = s.device; inode = s.inode; links = s.links
        size = s.size; allocated = max(0, s.allocated)
        modifiedSeconds = s.modified_sec; modifiedNanoseconds = s.modified_nsec
        changedSeconds = s.changed_sec; changedNanoseconds = s.changed_nsec
        mode = s.mode; owner = s.owner; flags = s.flags; kind = Int(s.type); dataless = s.dataless != 0
    }
    var fingerprintFields: String {
        "\(device)|\(inode)|\(links)|\(size)|\(allocated)|\(modifiedSeconds)|\(modifiedNanoseconds)|\(changedSeconds)|\(changedNanoseconds)|\(mode)|\(owner)|\(flags)|\(kind)"
    }
}

public enum Files {
    /// Foundation's standardized/resolved URLs rewrite /private/var to /var on
    /// macOS. POSIX no-follow operations need the actual physical spelling.
    public static func lexicalPath(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
    public static func canonicalURL(_ url: URL) -> URL {
        let path = lexicalPath(url.path)
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
    public static func stamp(_ path: String) throws -> FileStamp {
        var raw = BLStat()
        let code = bl_read_stat(path, &raw)
        guard code == 0 else { throw error(code, path) }
        return FileStamp(raw)
    }
    public static func exists(_ path: String) -> Bool { (try? stamp(path)) != nil }
    static func optionalStamp(_ path: String) throws -> FileStamp? {
        var raw = BLStat()
        let code = bl_read_stat(path, &raw)
        if code == ENOENT { return nil }
        guard code == 0 else { throw error(code, path) }
        return FileStamp(raw)
    }
    public static func error(_ code: Int32, _ path: String) -> BleachError {
        BleachError("\(Display.terminalSafe(path)): \(String(cString: strerror(code)))")
    }
    static func require(_ code: Int32, _ path: String) throws {
        guard code == 0 else { throw error(code, path) }
    }
    static func makeDirectory(_ url: URL) throws { try require(bl_make_directories(url.path), url.path) }
    static func ensureRealDirectory(_ path: String) throws {
        let fd = bl_open_directory(path)
        guard fd >= 0 else { throw error(bl_last_error(), path) }
        bl_close(fd)
    }
    static func atomicWrite(_ data: Data, directory: URL, name: String) throws {
        let code = data.withUnsafeBytes { bl_atomic_write(directory.path, name, $0.baseAddress, $0.count) }
        try require(code, directory.appendingPathComponent(name).path)
    }
    static func children(_ path: String) throws -> [URL] {
        try ensureRealDirectory(path)
        return try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func readPrivateFile(_ url: URL, limit: Int64 = 16_000_000) throws -> Data {
        let stamp = try stamp(url.path)
        guard stamp.kind == 1, stamp.owner == getuid(), stamp.size <= limit else {
            throw BleachError("Invalid local settings or journal file: \(url.path)")
        }
        let fd = bl_open_regular(url.path, stamp.device, stamp.inode)
        guard fd >= 0 else { throw error(bl_last_error(), url.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try handle.read(upToCount: Int(limit) + 1), data.count <= limit else {
            throw BleachError("Local settings or journal is too large: \(url.path)")
        }
        return data
    }
    static func sha256(_ path: String, expected: FileStamp, check: () throws -> Void = { try Task.checkCancellation() }) throws -> String {
        guard expected.kind == 1, !expected.dataless else { throw BleachError("Only local regular files can be hashed: \(path)") }
        let fd = bl_open_regular(path, expected.device, expected.inode)
        guard fd >= 0 else { throw error(bl_last_error(), path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var hash = SHA256()
        while true {
            try check()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        var after = BLStat()
        try require(bl_stat_fd(fd, &after), path)
        guard FileStamp(after) == expected, try stamp(path) == expected else { throw BleachError("File changed while hashing; scan again: \(path)") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func pathIsWithin(_ path: String, _ parent: String) -> Bool { path == parent || path.hasPrefix(parent + "/") }
}

/// One native physical traversal. The callback and its context stay on the
/// calling thread; fts never follows symbolic links or crosses mounted volumes.
final class WalkAccumulator {
    let rootPath: String
    let expectedDevice: UInt64
    let collect: Bool
    let fingerprint: Bool
    let deadline: Date?
    let skip: (String, FileStamp) -> Bool
    var root: FileStamp?
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var fileCount = 0
    var entryCount = 0
    var newest = Date.distantPast
    var hasCloud = false
    var hasForeign = false
    var hasOtherVolume = false
    var issues: [ScanIssue] = []
    var records: [(String, FileStamp)] = []
    var hash = SHA256()
    var seen: Set<String> = []
    var wasCancelled = false
    var timedOut = false

    init(rootPath: String, expectedDevice: UInt64, collect: Bool, fingerprint: Bool, deadline: Date?,
         skip: @escaping (String, FileStamp) -> Bool) {
        self.rootPath = rootPath; self.expectedDevice = expectedDevice
        self.collect = collect; self.fingerprint = fingerprint; self.skip = skip
        self.deadline = deadline
    }
    func visit(path: String, stamp: FileStamp, error: Int32) -> Int32 {
        if Task.isCancelled { wasCancelled = true; return 1 }
        if let deadline, Date() > deadline { timedOut = true; return 1 }
        if error != 0 {
            issues.append(ScanIssue(path: path, message: String(cString: strerror(error))))
            return 2
        }
        if root == nil { root = stamp }
        if stamp.device != expectedDevice {
            hasOtherVolume = true
            issues.append(ScanIssue(path: path, message: "Mounted volume skipped"))
            return 2
        }
        if path != rootPath && skip(path, stamp) { return 2 }
        entryCount += 1
        hasCloud = hasCloud || stamp.dataless
        hasForeign = hasForeign || stamp.owner != getuid()
        newest = max(newest, Date(timeIntervalSince1970: Double(stamp.modifiedSeconds)))
        if fingerprint {
            let relative = path == rootPath ? "." : String(path.dropFirst(rootPath.count + 1))
            // A same-volume rename changes the root ctime, not its contents.
            // The separate root stamp still binds preflight to that ctime.
            var fields = stamp
            if path == rootPath { fields.changedSeconds = 0; fields.changedNanoseconds = 0 }
            let bytes = Data((relative + "\0" + fields.fingerprintFields + "\0").utf8)
            hash.update(data: bytes)
        }
        let countBytes = stamp.links <= 1 || stamp.kind == 2 || seen.insert(stamp.identity).inserted
        if countBytes {
            allocated += stamp.allocated
            if stamp.kind == 1 { logical += max(0, stamp.size); fileCount += 1 }
        }
        if collect { records.append((path, stamp)) }
        return stamp.dataless && stamp.kind == 2 ? 2 : 0
    }
}

struct WalkResult {
    var snapshot: TreeSnapshot
    var issues: [ScanIssue]
    var records: [(String, FileStamp)]
}

enum FileWalker {
    static func walk(_ path: String, collect: Bool = false, fingerprint: Bool = true, deadline: Date? = nil,
                     skip: @escaping (String, FileStamp) -> Bool = { _, _ in false }) throws -> WalkResult {
        let initial = try Files.stamp(path)
        guard initial.kind != 3 else { throw BleachError("Symbolic link skipped: \(path)") }
        try Files.ensureRealDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        let accumulator = WalkAccumulator(rootPath: path, expectedDevice: initial.device,
                                          collect: collect, fingerprint: fingerprint, deadline: deadline, skip: skip)
        let context = Unmanaged.passUnretained(accumulator).toOpaque()
        let result = bl_walk(path, { rawPath, rawStamp, error, opaque in
            guard let rawPath, let rawStamp, let opaque else { return 1 }
            let state = Unmanaged<WalkAccumulator>.fromOpaque(opaque).takeUnretainedValue()
            return state.visit(path: String(cString: rawPath), stamp: FileStamp(rawStamp.pointee), error: error)
        }, context)
        if accumulator.timedOut { throw BleachError("Scan time budget reached; incomplete target retained: \(path)") }
        if accumulator.wasCancelled || result == ECANCELED { throw CancellationError() }
        if result != 0 { accumulator.issues.append(ScanIssue(path: path, message: String(cString: strerror(result)))) }
        guard let root = accumulator.root else { throw BleachError("Could not read \(path)") }
        let final = try Files.stamp(path)
        if final != initial { accumulator.issues.append(ScanIssue(path: path, message: "Changed during scan; scan again")) }
        let digest = accumulator.hash.finalize().map { String(format: "%02x", $0) }.joined()
        return WalkResult(snapshot: TreeSnapshot(root: root, fingerprint: digest,
            logicalBytes: accumulator.logical, allocatedBytes: accumulator.allocated,
            fileCount: accumulator.fileCount, entryCount: accumulator.entryCount,
            newestModification: accumulator.newest, hasCloudPlaceholder: accumulator.hasCloud,
            hasForeignOwner: accumulator.hasForeign, hasOtherVolume: accumulator.hasOtherVolume),
            issues: accumulator.issues, records: accumulator.records)
    }

    static func completeSnapshot(_ path: String, deadline: Date? = nil) throws -> TreeSnapshot {
        let result = try walk(path, deadline: deadline)
        guard result.issues.isEmpty else { throw BleachError("Incomplete scan: \(result.issues[0].path): \(result.issues[0].message)") }
        guard !result.snapshot.hasCloudPlaceholder else { throw BleachError("Cloud placeholder retained: \(path)") }
        guard !result.snapshot.hasForeignOwner else { throw BleachError("Contains files owned by another user: \(path)") }
        return result.snapshot
    }
}
