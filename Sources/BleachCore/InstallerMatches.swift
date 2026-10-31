import BleachFS
import Darwin
import Foundation
import ZIPFoundation

enum InstallerMatches {
    private static func info(at url: URL) throws -> ([String: Any], FileStamp) {
        try Files.ensureRealDirectory(url.deletingLastPathComponent().path)
        let stamp = try Files.stamp(url.path)
        guard stamp.kind == 1, !stamp.dataless, stamp.size >= 0, stamp.size <= 1_048_576 else {
            throw BleachError("Installer identity metadata is linked, unavailable or too large")
        }
        let fd = bl_open_regular(url.path, stamp.device, stamp.inode)
        guard fd >= 0 else { throw Files.error(bl_last_error(), url.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        var after = BLStat()
        try Files.require(bl_stat_fd(fd, &after), url.path)
        guard data.count == stamp.size, FileStamp(after) == stamp, try Files.stamp(url.path) == stamp,
              let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw BleachError("App identity changed or could not be read")
        }
        return (object, stamp)
    }

    private static func match(_ source: [String: Any], sourcePath: String,
                              apps: [InstalledApp], context: ScanContext) throws -> InstallerProof? {
        guard let id = source["CFBundleIdentifier"] as? String, CleanupPolicy.validBundleID(id) else { return nil }
        guard ["CFBundleShortVersionString", "CFBundleVersion"].allSatisfy({ source[$0] == nil || source[$0] is String }) else { return nil }
        let version = source["CFBundleShortVersionString"] as? String ?? ""
        let build = source["CFBundleVersion"] as? String ?? ""
        guard !version.isEmpty || !build.isEmpty else { return nil }
        for app in apps.filter({ $0.bundleID == id }) {
            let url = URL(fileURLWithPath: app.path)
            guard ["/Applications", context.homeURL("Applications").path].contains(url.deletingLastPathComponent().path) else { continue }
            let (current, stamp) = try info(at: url.appendingPathComponent("Contents/Info.plist"))
            guard current["CFBundleIdentifier"] as? String == id,
                  ["CFBundleShortVersionString", "CFBundleVersion"].allSatisfy({ current[$0] == nil || current[$0] is String }),
                  current["CFBundleShortVersionString"] as? String ?? "" == version,
                  current["CFBundleVersion"] as? String ?? "" == build else { continue }
            return InstallerProof(installedPath: app.path, bundleID: id, version: version, build: build,
                installedInfo: stamp, sourceInfoPath: sourcePath)
        }
        return nil
    }

    static func zip(_ url: URL, apps: [InstalledApp], context: ScanContext,
                    maximumEntries: Int = 10_000) throws -> InstallerProof? {
        let deadline = Date().addingTimeInterval(10)
        return try ArchiveTwins.readArchive(url, maximumEntries: maximumEntries) { archive, expectedCount in
            var count = 0, entries: [Entry] = [], allPaths: [([String], Bool)] = [], seen: Set<String> = []
            for entry in archive {
                try Task.checkCancellation()
                guard Date() < deadline else { throw BleachError("Installer metadata time limit reached") }
                count += 1
                guard count <= expectedCount else { throw BleachError("Unexpected ZIP directory entries") }
                let parts = try ArchiveTwins.components(entry.path, directory: entry.type == .directory)
                allPaths.append((parts, entry.type == .directory))
                guard seen.insert(parts.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                    throw BleachError("Repeated ZIP installer path retained")
                }
                if (3...4).contains(parts.count), parts[parts.count - 3].hasSuffix(".app"),
                   parts.suffix(2).elementsEqual(["Contents", "Info.plist"]), entry.type == .file { entries.append(entry) }
            }
            guard count == expectedCount else { throw BleachError("Encrypted or incomplete ZIP installer retained") }
            guard entries.count == 1, let entry = entries.first, entry.uncompressedSize <= 1_048_576 else { return nil }
            let appPrefix = try ArchiveTwins.components(entry.path, directory: false).dropLast(2)
            guard allPaths.allSatisfy({ parts, directory in
                parts.starts(with: appPrefix) || (directory && appPrefix.starts(with: parts))
            }) else { return nil } // An archive containing source/documents is not just an app installer.
            var data = Data()
            let checksum = try archive.extract(entry, bufferSize: 65_536) { chunk in
                try Task.checkCancellation()
                guard Date() < deadline, data.count + chunk.count <= 1_048_576 else { throw BleachError("Installer identity metadata limit reached") }
                data.append(chunk)
            }
            guard data.count == entry.uncompressedSize, checksum == entry.checksum,
                  let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return try match(object, sourcePath: entry.path, apps: apps, context: context)
        }
    }

    /// Consult already-mounted images only. Discovery does not mount images,
    /// accept image licenses, launch apps or run installer scripts.
    static func mountedImages() throws -> [String: [String]] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate(); usleep(20_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            process.waitUntilExit()
        }
        try output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw BleachError("Could not inspect mounted image metadata")
        }
        let deadline = Date().addingTimeInterval(3)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw BleachError("Mounted image metadata timed out") }
            let read = Darwin.read(fd, &buffer, buffer.count)
            if read > 0 {
                guard data.count + read <= 4_194_304 else { throw BleachError("Mounted image metadata exceeds the inspection limit") }
                data.append(contentsOf: buffer.prefix(read))
            } else if read < 0 && errno != EAGAIN && errno != EINTR { throw BleachError("Could not read mounted image metadata") }
            else if read == 0 && !process.isRunning { break }
            else { usleep(10_000) }
        }
        guard process.terminationStatus == 0 else { throw BleachError("Mounted image inventory is unavailable") }
        return try mountedImages(from: data)
    }

    static func mountedImages(from data: Data) throws -> [String: [String]] {
        guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = object["images"] as? [[String: Any]] else { throw BleachError("Invalid mounted image inventory") }
        var result: [String: [String]] = [:]
        for image in images {
            guard let source = image["image-path"] as? String, source.hasPrefix("/"),
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            let volumes = entities.compactMap { $0["mount-point"] as? String }.filter { $0.hasPrefix("/") }
            result[Files.canonicalURL(URL(fileURLWithPath: source)).path, default: []].append(contentsOf: volumes)
        }
        return result
    }

    static func diskImage(_ url: URL, mounted: [String: [String]], apps: [InstalledApp], context: ScanContext) throws -> InstallerProof? {
        var matches: [InstallerProof] = []
        for path in mounted[url.path] ?? [] {
            let children = try Files.children(path)
            guard children.count <= 100 else { throw BleachError("Disk image inventory limit reached; image retained") }
            for app in children where app.pathExtension == "app" {
                guard (try? Files.stamp(app.path).kind) == 2 else { continue }
                let source = app.appendingPathComponent("Contents/Info.plist")
                let (object, _) = try info(at: source)
                if let proof = try match(object, sourcePath: source.path, apps: apps, context: context) { matches.append(proof) }
                else { return nil } // A multi-app image must not hide an uninstalled app.
            }
        }
        return matches.count == 1 ? matches.first : nil
    }
}
