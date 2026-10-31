import Foundation
import Testing
import ZIPFoundation
@testable import BleachCore

@Suite("Installed-app installer evidence") struct InstallerMatchTests {
    private func installer(_ fixture: Fixture, version: String = "1.0", extraSource: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: fixture.url("Downloads"), withIntermediateDirectories: true)
        let url = fixture.url("Downloads/Completely-Different-Name.zip")
        let archive = try Archive(url: url, accessMode: .create)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.bleach.fixture.Example",
            "CFBundleShortVersionString": version], format: .xml, options: 0)
        var files = [("Source.app/Contents/Info.plist", info), ("Source.app/Contents/MacOS/Source", Data("not executed".utf8))]
        if extraSource { files.append(("important-source.swift", Data("source".utf8))) }
        for (path, bytes) in files {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate) { position, count in
                bytes.subdata(in: Int(position)..<min(Int(position) + count, bytes.count))
            }
        }
        return url
    }

    @Test func matchesActualBundleIdentityRatherThanFilenameAndRestores() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let app = try fixture.app()
        let zip = try installer(fixture)
        let report = try await engine.discover(context: fixture.context)
        #expect(report.installedInstallers == 1)
        let item = try #require(report.plan.candidates.first)
        #expect(item.rule == .archivedInstaller)
        #expect(item.recommendation == .review)
        #expect(item.installerProof?.installedPath == app.path)
        #expect(item.reason.contains("already installed"))
        let batch = try await engine.apply(report.plan, context: fixture.context)
        #expect(batch.movedCount == 1)
        #expect(!Files.exists(zip.path))
        #expect(Files.exists(app.path))
        _ = try await engine.restore(batch: batch.id, context: fixture.context)
        #expect(Files.exists(zip.path))
    }

    @Test(arguments: ["2.0", ""])
    func differentOrUnknownVersionsDoNotQualify(version: String) async throws {
        let fixture = try Fixture()
        try fixture.app()
        _ = try installer(fixture, version: version)
        let report = try await BleachEngine().discover(context: fixture.context)
        #expect(report.installedInstallers == 0)
        #expect(report.plan.candidates.isEmpty)
    }

    @Test func sameAppNameWithDifferentIDDoesNotQualify() async throws {
        let fixture = try Fixture()
        try fixture.app("Source", id: "org.someone.Else")
        _ = try installer(fixture)
        #expect(try await BleachEngine().discover(context: fixture.context).installedInstallers == 0)
    }

    @Test func appRemovedOrUpdatedAfterPreviewInvalidatesInstallerEvidence() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let app = try fixture.app()
        let zip = try installer(fixture)
        let report = try await engine.discover(context: fixture.context)
        try FileManager.default.removeItem(at: app)
        await reject("identity changed") { _ = try await engine.apply(report.plan, context: fixture.context) }
        #expect(Files.exists(zip.path))
    }

    @Test func installedAppCannotAlsoBeRemovedInTheBatch() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let app = try fixture.app()
        let zip = try installer(fixture)
        var report = try await engine.discover(context: fixture.context)
        let uninstall = try await engine.uninstallPlan(appPath: app, context: fixture.context)
        report.plan.candidates += uninstall.candidates.filter { $0.rule == .application }
        await reject("also selected") { _ = try await engine.apply(report.plan, context: fixture.context) }
        #expect(Files.exists(zip.path))
        #expect(Files.exists(app.path))
    }

    @Test func sourceArchiveContainingAnAppIsNotAnInstaller() async throws {
        let fixture = try Fixture()
        try fixture.app()
        _ = try installer(fixture, extraSource: true)
        #expect(try await BleachEngine().discover(context: fixture.context).installedInstallers == 0)
    }

    @Test func mountedImageMappingRequiresTheActualSourceImage() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.app()
        let image = try fixture.write("Downloads/Installer.dmg")
        let info = try Data(contentsOf: fixture.url("Applications/Example.app/Contents/Info.plist"))
        try fixture.write("Mounted/Anything.app/Contents/Info.plist", info)
        let data = try PropertyListSerialization.data(fromPropertyList: ["images": [
            ["image-path": image.path, "system-entities": [["mount-point": fixture.url("Mounted").path]]]
        ]], format: .xml, options: 0)
        let mounted = try InstallerMatches.mountedImages(from: data)
        let apps = try await engine.installedApps(context: fixture.context)
        #expect(try InstallerMatches.diskImage(image, mounted: mounted, apps: apps, context: fixture.context)?.bundleID == "org.bleach.fixture.Example")
        #expect(try InstallerMatches.diskImage(fixture.url("Downloads/Other.dmg"), mounted: mounted, apps: apps, context: fixture.context) == nil)
    }

    @Test func snapshotDeadlineNeverAuthorizesAnIncompleteTarget() throws {
        let fixture = try Fixture()
        let cache = try fixture.cache()
        #expect(throws: BleachError.self) { try FileWalker.completeSnapshot(cache.path, deadline: .distantPast) }
    }
}
