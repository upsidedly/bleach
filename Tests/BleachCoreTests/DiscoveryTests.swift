import Darwin
import Foundation
import Testing
import ZIPFoundation
@testable import BleachCore

@Suite("Additional space discovery") struct DiscoveryTests {
    private func archive(_ fixture: Fixture, name: String = "Bundle", rooted: Bool = true,
                         contents: [(String, Data)] = [("notes.txt", Data("original bytes".utf8))],
                         method: CompressionMethod = .deflate) throws -> URL {
        let folder = "Downloads/\(name)"
        for (path, bytes) in contents { try fixture.write(folder + "/" + path, bytes) }
        let url = fixture.url(folder + ".zip")
        let zip = try Archive(url: url, accessMode: .create)
        for (path, bytes) in contents {
            try zip.addEntry(with: (rooted ? name + "/" : "") + path, type: .file,
                uncompressedSize: Int64(bytes.count), compressionMethod: method) { position, count in
                bytes.subdata(in: Int(position)..<min(Int(position) + count, bytes.count))
            }
        }
        return url
    }

    @Test func findsUnconfiguredProjectsAndPreservesSource() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.write("Projects/Forgotten/package.json", Data("{}".utf8))
        let generated = try fixture.write("Projects/Forgotten/node_modules/dependency/index.js")
        let baseline = try await engine.scan(context: fixture.context)
        let report = try await engine.discover(context: fixture.context)
        #expect(baseline.candidates.isEmpty)
        #expect(report.projectsFound == 1)
        #expect(report.plan.candidates.first?.rule == .projectArtifact)
        #expect(report.plan.candidates.first?.recommendation == .review)
        #expect(report.plan.suggested.isEmpty)
        let batch = try await engine.apply(report.plan, context: fixture.context)
        #expect(batch.movedCount == 1)
        #expect(!Files.exists(generated.path))
        #expect(Files.exists(fixture.url("Projects/Forgotten/package.json").path))
        let restored = try await engine.restore(batch: batch.id, context: fixture.context)
        #expect(restored.items.first?.state == .restored)
        #expect(Files.exists(generated.path))
    }

    @Test func recognizesSwiftRustAndNextManifestsWithoutGuessingFolders() async throws {
        let fixture = try Fixture()
        try fixture.write("Developer/Swift/Package.swift", Data("// swift-tools-version: 6.0".utf8))
        try fixture.write("Developer/Swift/.build/object")
        try fixture.write("Developer/Rust/Cargo.toml", Data("[package]".utf8))
        try fixture.write("Developer/Rust/target/object")
        try fixture.write("Developer/Web/package.json", Data("{\"dependencies\":{\"next\":\"15\"}}".utf8))
        try fixture.write("Developer/Web/.next/server")
        try fixture.write("Developer/Precious/target/notes")
        let report = try await BleachEngine().discover(context: fixture.context)
        #expect(report.projectsFound == 3)
        #expect(report.plan.candidates.count == 3)
        #expect(!report.plan.candidates.contains { $0.path.contains("Precious") })
    }

    @Test(arguments: [true, false]) func verifiesRootedAndFlatZIPContents(rooted: Bool) async throws {
        let fixture = try Fixture()
        let zip = try archive(fixture, rooted: rooted, contents: [("a/notes.txt", Data("full content".utf8)), ("empty", Data())])
        let report = try await BleachEngine().discover(context: fixture.context)
        #expect(report.archivesCompared == 1)
        #expect(report.archivesMatched == 1)
        #expect(report.verifiedArchiveFiles == 2)
        #expect(report.plan.candidates.first?.path == zip.path)
        #expect(report.plan.candidates.first?.archiveProof?.stripsRoot == rooted)
        #expect(report.plan.candidates.first?.recommendation == .review)
        #expect(report.plan.suggestedBytes == 0)
        #expect(!Files.exists(fixture.context.state.path))
    }

    @Test func ZIPCleanupRoundTripsAndKeepsTheExpandedCopy() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let zip = try archive(fixture)
        let original = try Data(contentsOf: zip)
        let report = try await engine.discover(context: fixture.context)
        let plan = try JSONCoding.decoder().decode(CleanupPlan.self, from: JSONCoding.encoder().encode(report.plan))
        let batch = try await engine.apply(plan, context: fixture.context)
        #expect(batch.movedCount == 1)
        #expect(!Files.exists(zip.path))
        #expect(try Data(contentsOf: fixture.url("Downloads/Bundle/notes.txt")) == Data("original bytes".utf8))
        _ = try await engine.restore(batch: batch.id, context: fixture.context)
        #expect(try Data(contentsOf: zip) == original)
    }

    @Test func differentSameLengthExpandedFileIsNeverSuggested() async throws {
        let fixture = try Fixture()
        _ = try archive(fixture)
        try fixture.write("Downloads/Bundle/notes.txt", Data("different data".utf8))
        let report = try await BleachEngine().discover(context: fixture.context)
        #expect(report.archivesCompared == 1)
        #expect(report.archivesMatched == 0)
        #expect(report.plan.candidates.isEmpty)
    }

    @Test func changedKeeperRejectsTheCompleteBatchBeforeAnyMove() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let zip = try archive(fixture)
        try fixture.write("Projects/Test/package.json", Data("{}".utf8))
        let dependency = try fixture.write("Projects/Test/node_modules/dep")
        let report = try await engine.discover(context: fixture.context)
        #expect(report.plan.candidates.count == 2)
        try fixture.write("Downloads/Bundle/notes.txt", Data("different data".utf8))
        await reject("differ") { _ = try await engine.apply(report.plan, context: fixture.context) }
        #expect(Files.exists(zip.path))
        #expect(Files.exists(dependency.path))
        #expect(try await engine.history(context: fixture.context).isEmpty)
    }

    @Test func cannotAlsoSelectFilesFromTheExpandedCopy() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let zip = try archive(fixture, contents: [("Cargo.toml", Data("[package]".utf8)), ("target/object", Data("output".utf8))])
        let report = try await engine.discover(context: fixture.context)
        #expect(report.plan.candidates.count == 2)
        await reject("also selected") { _ = try await engine.apply(report.plan, context: fixture.context) }
        #expect(Files.exists(zip.path))
        #expect(Files.exists(fixture.url("Downloads/Bundle/target/object").path))
    }

    @Test func updatedExclusionsProtectTheExpandedKeeper() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let zip = try archive(fixture)
        let report = try await engine.discover(context: fixture.context)
        var preferences = Preferences(); preferences.excludedPaths = [fixture.url("Downloads/Bundle").path]
        try await engine.updatePreferences(preferences, context: fixture.context)
        await reject("excluded") { _ = try await engine.apply(report.plan, context: fixture.context) }
        #expect(Files.exists(zip.path))
    }

    @Test func linkedExpandedFileAndAncestorAreRejected() async throws {
        let fixture = try Fixture()
        _ = try archive(fixture, contents: [("sub/notes", Data("bytes".utf8))])
        let file = fixture.url("Downloads/Bundle/sub/notes")
        let other = try fixture.write("Documents/notes", Data("bytes".utf8))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        #expect(try await BleachEngine().discover(context: fixture.context).archivesMatched == 0)
        try FileManager.default.removeItem(at: fixture.url("Downloads/Bundle/sub"))
        try FileManager.default.createSymbolicLink(at: fixture.url("Downloads/Bundle/sub"), withDestinationURL: fixture.url("Documents"))
        #expect(try await BleachEngine().discover(context: fixture.context).archivesMatched == 0)
    }

    @Test(arguments: ["../escape", "/absolute", "a/../notes", "a\\notes", "__MACOSX/metadata", ".env"])
    func rejectsUnsafeAndProtectedArchivePaths(path: String) async throws {
        let fixture = try Fixture()
        try fixture.write("Downloads/Bundle/notes", Data("bytes".utf8))
        let zip = try Archive(url: fixture.url("Downloads/Bundle.zip"), accessMode: .create)
        let bytes = Data("bytes".utf8)
        try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { position, count in
            bytes.subdata(in: Int(position)..<min(Int(position) + count, bytes.count))
        }
        let report = try await BleachEngine().discover(context: fixture.context)
        #expect(report.archivesMatched == 0)
        #expect(report.plan.candidates.isEmpty)
    }

    @Test func skippedEncryptedHeaderCannotBecomeAPartialMatch() async throws {
        let fixture = try Fixture()
        let url = try archive(fixture, contents: [("a", Data("a".utf8)), ("b", Data("b".utf8))])
        var data = try Data(contentsOf: url)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        let first = try #require(data.range(of: signature))
        let second = try #require(data.range(of: signature, in: first.upperBound..<data.count))
        data[second.lowerBound + 8] |= 1
        try data.write(to: url)
        let report = try await BleachEngine().discover(context: fixture.context)
        #expect(report.archivesMatched == 0)
        #expect(report.plan.issues.contains { $0.message.contains("incomplete ZIP") })
    }

    @Test func corruptedPayloadAndTruncatedArchiveAreRejected() async throws {
        let fixture = try Fixture()
        let url = try archive(fixture, contents: [("notes", Data("unique payload".utf8))], method: .none)
        var data = try Data(contentsOf: url)
        let payload = try #require(data.range(of: Data("unique payload".utf8)))
        data[payload.lowerBound] ^= 1
        try data.write(to: url)
        #expect(try await BleachEngine().discover(context: fixture.context).archivesMatched == 0)
        try data.dropLast(12).write(to: url)
        #expect(try await BleachEngine().discover(context: fixture.context).archivesMatched == 0)
    }

    @Test func caseCollisionsAndArchiveSymlinksAreRejected() async throws {
        let fixture = try Fixture()
        _ = try archive(fixture)
        let zip = try Archive(url: fixture.url("Downloads/Bundle.zip"), accessMode: .update)
        try zip.addEntry(with: "Bundle/NOTES.txt", type: .file, uncompressedSize: Int64(1)) { _, _ in Data([1]) }
        #expect(try await BleachEngine().discover(context: fixture.context).archivesMatched == 0)
        try zip.addEntry(with: "Bundle/link", type: .symlink, uncompressedSize: Int64(5)) { _, _ in Data("notes".utf8) }
        #expect(try await BleachEngine().discover(context: fixture.context).archivesMatched == 0)
    }

    @Test func boundsExpansionEntriesAndTraversal() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        _ = try archive(fixture, contents: [("large", Data(repeating: 5, count: 65_536))])
        var limits = DiscoveryLimits(); limits.archiveBytes = 1024
        #expect(try await engine.discover(context: fixture.context, limits: limits).archivesMatched == 0)
        limits = DiscoveryLimits(); limits.archiveEntries = 0
        #expect(try await engine.discover(context: fixture.context, limits: limits).archivesMatched == 0)
        limits = DiscoveryLimits(); limits.directories = 0
        let empty = try await engine.discover(context: fixture.context, limits: limits)
        #expect(empty.directoriesVisited == 0)
        #expect(empty.plan.candidates.isEmpty)
        #expect(!empty.plan.issues.isEmpty)
    }

    @Test func cancellationDoesNotReturnAPartialPlan() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        _ = try archive(fixture)
        let task = Task { try await engine.discover(context: fixture.context) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
    }

    @Test func hashingRejectsAReplacedParentEvenIfTheOpenFileIsUnchanged() throws {
        let fixture = try Fixture()
        let file = try fixture.write("Documents/Parent/value", Data("original".utf8))
        let stamp = try Files.stamp(file.path)
        var replaced = false
        #expect(throws: BleachError.self) {
            try Files.sha256(file.path, expected: stamp) {
                if !replaced {
                    replaced = true
                    try FileManager.default.moveItem(at: fixture.url("Documents/Parent"), to: fixture.url("Documents/Other"))
                    try fixture.write("Documents/Parent/value", Data("different".utf8))
                }
            }
        }
    }
}
