import BleachFS
import Darwin
import Foundation
import Testing
@testable import BleachCore

final class Fixture: Sendable {
    let root: URL
    let now: Date
    init() throws {
        root = Files.canonicalURL(FileManager.default.temporaryDirectory).appendingPathComponent("bleach-tests-\(UUID().uuidString)")
        now = Date()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    var context: ScanContext { ScanContext(home: root, now: now) }
    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    @discardableResult func write(_ path: String, _ data: Data = Data(repeating: 37, count: 8192)) throws -> URL {
        let destination = url(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: destination)
        return destination
    }
    @discardableResult func cache(_ name: String = "org.bleach.fixture", days: Int = 20) throws -> URL {
        let path = "Library/Caches/\(name)"
        try write(path + "/cache.bin")
        try age(url(path), days: days)
        return url(path)
    }
    func age(_ path: URL, days: Int) throws {
        let date = now.addingTimeInterval(-Double(days) * 86_400)
        let enumerator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.path) }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
    }
    @discardableResult func app(_ name: String = "Example", id: String = "org.bleach.fixture.Example") throws -> URL {
        let directory = "Applications/\(name).app"
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.0"], format: .xml, options: 0)
        try write(directory + "/Contents/Info.plist", data)
        try write(directory + "/Contents/MacOS/Example")
        return url(directory)
    }
}

func reject(_ fragment: String, _ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected rejection containing '\(fragment)'") }
    catch { #expect(error.localizedDescription.localizedCaseInsensitiveContains(fragment), "Unexpected error: \(error)") }
}

func firstPlan(_ fixture: Fixture, engine: BleachEngine = BleachEngine()) async throws -> CleanupPlan {
    let plan = try await engine.scan(context: fixture.context)
    try #require(!plan.candidates.isEmpty)
    return plan
}
