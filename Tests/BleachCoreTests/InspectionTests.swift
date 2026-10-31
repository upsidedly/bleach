import Darwin
import Foundation
import Testing
@testable import BleachCore

@Suite("Space, duplicates and applications") struct InspectionTests {
    @Test func countsPhysicalHardLinkOnce() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let file = try fixture.write("Space/first.bin")
        try FileManager.default.linkItem(at: file, to: fixture.url("Space/second.bin"))
        let report = try await engine.analyze(fixture.url("Space"))
        #expect(report.fileCount == 1)
        #expect(report.logicalBytes == 8192)
        #expect(report.allocatedBytes >= (try Files.stamp(file.path).allocated))
        #expect(report.complete)
    }

    @Test func sparseLogicalLengthIsSeparateFromAllocation() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let file = try fixture.write("Space/sparse.bin", Data())
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1_073_741_824)
        try handle.close()
        let report = try await engine.analyze(fixture.url("Space"))
        #expect(report.logicalBytes == 1_073_741_824)
        #expect(report.allocatedBytes < 1_048_576)
    }

    @Test func sameSizeIsNotProofOfDuplicateContent() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.write("Documents/a", Data("same".utf8))
        try fixture.write("Documents/b", Data("same".utf8))
        try fixture.write("Documents/c", Data("nope".utf8))
        let report = try await engine.duplicates(in: fixture.url("Documents"), context: fixture.context)
        #expect(report.groups.count == 1)
        #expect(report.groups.first?.files.count == 2)
        #expect(report.filesHashed == 3)
        #expect(report.plan.candidates.count == 1)
        #expect(report.plan.candidates.first?.recommendation == .review)
    }

    @Test func hardLinkAliasesAreNotDuplicates() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let file = try fixture.write("Documents/a")
        try FileManager.default.linkItem(at: file, to: fixture.url("Documents/b"))
        let report = try await engine.duplicates(in: fixture.url("Documents"), context: fixture.context)
        #expect(report.groups.isEmpty)
        #expect(report.filesHashed == 0)
    }

    @Test func uniqueLengthsAvoidUnnecessaryHashing() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        for count in 1...12 { try fixture.write("Documents/\(count)", Data(repeating: 7, count: count)) }
        let report = try await engine.duplicates(in: fixture.url("Documents"), context: fixture.context)
        #expect(report.filesInspected == 12)
        #expect(report.filesHashed == 0)
    }

    @Test func duplicateCleanupKeepsAndRevalidatesOriginal() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let first = try fixture.write("Documents/a"), second = try fixture.write("Documents/b")
        let report = try await engine.duplicates(in: fixture.url("Documents"), context: fixture.context)
        let batch = try await engine.apply(report.plan, context: fixture.context)
        #expect(batch.movedCount == 1)
        #expect(Files.exists(first.path)); #expect(!Files.exists(second.path))
        _ = try await engine.restore(batch: batch.id, context: fixture.context)
        #expect(try Data(contentsOf: first) == Data(contentsOf: second))
    }

    @Test func changedKeeperRefusesDuplicateCleanup() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.write("Documents/a"); try fixture.write("Documents/b")
        let report = try await engine.duplicates(in: fixture.url("Documents"), context: fixture.context)
        try fixture.write("Documents/a", Data("changed".utf8))
        await reject("retained duplicate copy changed") { _ = try await engine.apply(report.plan, context: fixture.context) }
        #expect(Files.exists(fixture.url("Documents/b").path))
    }

    @Test func userCanChooseWhichDuplicateToKeep() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.write("Documents/a"); let keep = try fixture.write("Documents/b")
        let report = try await engine.duplicates(in: fixture.url("Documents"), context: fixture.context)
        let changed = try await engine.retaining(keep.path, in: report)
        #expect(changed.plan.candidates.first?.path == fixture.url("Documents/a").path)
        let batch = try await engine.apply(changed.plan, context: fixture.context)
        #expect(batch.movedCount == 1)
        #expect(Files.exists(keep.path))
    }

    @Test func cannotSelectEveryCopyThroughCraftedPlan() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.write("Documents/a"); let second = try fixture.write("Documents/b")
        let report = try await engine.duplicates(in: fixture.url("Documents"), context: fixture.context)
        let alternate = try await engine.retaining(second.path, in: report)
        var invalid = report.plan
        invalid.candidates += alternate.plan.candidates
        await reject("also selected") { _ = try await engine.apply(invalid, context: fixture.context) }
    }

    @Test func photoLibrariesAndCredentialsAreNotHashed() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.write("Documents/Photos.photoslibrary/a")
        try fixture.write("Documents/Photos.photoslibrary/b")
        let report = try await engine.duplicates(in: fixture.url("Documents"), context: fixture.context)
        #expect(report.filesHashed == 0)
        await reject("protected") { _ = try await engine.duplicates(in: fixture.url(".ssh"), context: fixture.context) }
    }

    @Test func appPreviewUsesExactBundleIdentityAndNeverGuessesDataNames() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let app = try fixture.app()
        try fixture.write("Library/Preferences/org.bleach.fixture.Example.plist")
        try fixture.write("Library/Application Support/Example/user-data")
        try fixture.write("Library/Group Containers/org.bleach.fixture.Example/shared")
        let plan = try await engine.uninstallPlan(appPath: app, context: fixture.context)
        #expect(plan.candidates.count == 2)
        #expect(plan.candidates.contains { $0.category == .appData })
        #expect(!plan.candidates.contains { $0.path.contains("Group Containers") || $0.path.contains("Support/Example") })
        #expect(plan.suggested.isEmpty)
    }

    @Test func secondInstallProtectsSharedAppData() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let app = try fixture.app("One")
        try fixture.app("Two")
        try fixture.write("Library/Preferences/org.bleach.fixture.Example.plist")
        let plan = try await engine.uninstallPlan(appPath: app, context: fixture.context)
        #expect(plan.candidates.count == 1)
        #expect(plan.issues.first?.message.contains("Another copy") == true)
    }

    @Test func dataCannotBeRemovedWithoutSelectingApp() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let app = try fixture.app()
        try fixture.write("Library/Preferences/org.bleach.fixture.Example.plist")
        var plan = try await engine.uninstallPlan(appPath: app, context: fixture.context)
        plan.candidates.removeAll { $0.rule == .application }
        await reject("not selected") { _ = try await engine.apply(plan, context: fixture.context) }
    }

    @Test func systemAppBundleIDIsProtected() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let app = try fixture.app("Protected", id: "com.apple.Fixture")
        await reject("System apps are protected") { _ = try await engine.uninstallPlan(appPath: app, context: fixture.context) }
    }

    @Test func invalidBundleIdentifiersCannotEscapePreferencesFolder() throws {
        #expect(!CleanupPolicy.validBundleID("../../Documents"))
        #expect(!CleanupPolicy.validBundleID("org..app"))
        #expect(!CleanupPolicy.validBundleID("org.app/../../file"))
        #expect(CleanupPolicy.validBundleID("org.example.App-2"))
    }

    @Test func terminalControlBytesCannotForgeOutput() {
        let value = Display.terminalSafe("name\u{1B}[2J\nsecond\r\u{7}")
        #expect(!value.contains("\u{1B}"))
        #expect(!value.contains("\n"))
        #expect(value.contains("\\u{1B}"))
    }

    @Test func largestFileHeapKeepsExactTopResults() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        for index in 1...12 { try fixture.write("Space/file-\(index)", Data(repeating: 15, count: index * 8192)) }
        let report = try await engine.analyze(fixture.url("Space"), largestLimit: 3)
        #expect(report.largestFiles.map(\.name) == ["file-12", "file-11", "file-10"])
        #expect(report.fileCount == 12)
    }

    @Test func analysisAggregatesNestedChildrenAndHardLinksConsistently() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let file = try fixture.write("Space/a/deep/one", Data(repeating: 2, count: 8192))
        try fixture.write("Space/b/two", Data(repeating: 3, count: 16384))
        try FileManager.default.linkItem(at: file, to: fixture.url("Space/b/link-to-one"))
        let report = try await engine.analyze(fixture.url("Space"), largestLimit: 0)
        #expect(report.entries.map(\.name) == ["b", "a"])
        #expect(report.entries.reduce(0) { $0 + $1.allocatedBytes } == report.allocatedBytes)
        #expect(report.fileCount == 2)
        #expect(report.logicalBytes == 24576)
        #expect(report.largestFiles.isEmpty)
    }

    @Test func nativeAnalyzerDoesNotFollowNestedLinks() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let precious = try fixture.write("Documents/keep", Data(repeating: 2, count: 65536))
        try fixture.write("Space/own", Data(repeating: 3, count: 4096))
        try FileManager.default.createSymbolicLink(at: fixture.url("Space/link"), withDestinationURL: precious.deletingLastPathComponent())
        let report = try await engine.analyze(fixture.url("Space"))
        #expect(report.fileCount == 1)
        #expect(report.logicalBytes == 4096)
        #expect(!report.largestFiles.contains { $0.path.contains("Documents") })
    }

    @Test func nativeAnalyzerReportsUnreadableDirectoryAsPartial() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.write("Space/readable")
        let restricted = try fixture.write("Space/locked/file").deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        let report = try await engine.analyze(fixture.url("Space"))
        #expect(!report.complete)
        #expect(report.fileCount == 1)
        #expect(report.issues.contains { $0.path == restricted.path })
    }

    @Test func canonicalPathsPreservePhysicalPrivateVarSpelling() throws {
        let physical = Files.canonicalURL(FileManager.default.temporaryDirectory)
        #expect(physical.path.hasPrefix("/private/"))
        try Files.ensureRealDirectory(physical.path)
        #expect(Files.lexicalPath("/private/tmp/a/../b") == "/private/tmp/b")
    }

    @Test func secretsAndKnownCloudRootsAreExcludedFromDuplicateHashing() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.write("Documents/.env"); try fixture.write("Documents/private.key")
        try fixture.write("Documents/Dropbox/one"); try fixture.write("Documents/Dropbox/two")
        let report = try await engine.duplicates(in: fixture.url("Documents"), context: fixture.context)
        #expect(report.filesInspected == 0)
        #expect(report.filesHashed == 0)
    }

    @Test func appAndExplicitlySelectedDataMoveAndRestoreTogether() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let app = try fixture.app()
        let data = try fixture.write("Library/Preferences/org.bleach.fixture.Example.plist")
        let plan = try await engine.uninstallPlan(appPath: app, context: fixture.context)
        let batch = try await engine.apply(plan, context: fixture.context)
        #expect(batch.movedCount == 2)
        #expect(!Files.exists(app.path)); #expect(!Files.exists(data.path))
        let restored = try await engine.restore(batch: batch.id, context: fixture.context)
        #expect(restored.items.allSatisfy { $0.state == .restored })
        #expect(Files.exists(app.path)); #expect(Files.exists(data.path))
    }
}
