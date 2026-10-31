import BleachFS
import Darwin
import Foundation
import Testing
@testable import BleachCore

@Suite("APFS storage accounting") struct StorageTests {
    private let size = 2 * 1024 * 1024

    private func clone(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard clonefile(source.path, destination.path, 0) == 0 else { throw Files.error(errno, destination.path) }
    }

    @Test func independentAllocationRemainsPrivate() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let source = try fixture.write("Space/independent", Data(repeating: 7, count: size))
        let report = try await engine.analyze(fixture.url("Space"))
        let entry = try #require(report.entries.first)
        #expect(entry.storage.privateBytes == (try Files.stamp(source.path).allocated))
        #expect(entry.storage.privateBytes > 0)
        #expect(report.storage.allocatedBytes == report.allocatedBytes)
        #expect(report.storage.sharedBytes == 0)
    }

    @Test func cloneOutsideFolderIsNotPrivateStorage() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let source = try fixture.write("Elsewhere/original", Data(repeating: 7, count: size))
        try clone(source, to: fixture.url("Space/reference"))
        let report = try await engine.analyze(fixture.url("Space"))
        #expect(report.logicalBytes == Int64(size))
        #expect(report.allocatedBytes >= Int64(size))
        #expect(report.storage.privateBytes == 0)
        #expect(report.storage.sharedBytes == Int64(size))
        #expect(report.storage.cloneFiles == 1)
        #expect(report.storage.unverifiedBytes == 0)
        #expect(try FileWalker.completeSnapshot(fixture.url("Space").path).storage == report.storage)
    }

    @Test func partiallyChangedCloneCountsOnlyItsPrivateExtents() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let source = try fixture.write("Elsewhere/original", Data(repeating: 7, count: size))
        let copy = fixture.url("Space/partial")
        try clone(source, to: copy)
        let handle = try FileHandle(forWritingTo: copy)
        try handle.write(contentsOf: Data(repeating: 9, count: 65_536))
        try handle.synchronize(); try handle.close()
        let report = try await engine.analyze(fixture.url("Space"))
        #expect(report.storage.privateBytes >= 65_536)
        #expect(report.storage.privateBytes < report.allocatedBytes)
        #expect(report.storage.sharedBytes > 0)
        #expect(report.storage.privateBytes + report.storage.sharedBytes == report.allocatedBytes)
        #expect(report.storage.cloneFiles == 0)
    }

    @Test func historicalCloneFlagDoesNotSuppressNowPrivateBytes() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let source = try fixture.write("Space/original", Data(repeating: 7, count: size))
        let copy = fixture.url("Elsewhere/clone")
        try clone(source, to: copy)
        try FileManager.default.removeItem(at: copy)
        let report = try await engine.analyze(fixture.url("Space"))
        #expect(report.storage.privateBytes == Int64(size))
        #expect(report.storage.sharedBytes == 0)
        #expect(report.storage.cloneFiles == 0)
    }

    @Test func externalHardLinkIsExcludedFromPrivateEstimate() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let source = try fixture.write("Space/original", Data(repeating: 7, count: size))
        try FileManager.default.linkItem(at: source, to: fixture.url("retained-link"))
        let report = try await engine.analyze(fixture.url("Space"))
        #expect(report.fileCount == 1)
        #expect(report.storage.privateBytes == 0)
        #expect(report.storage.hardLinkedBytes == Int64(size))
        #expect(report.storage.hardLinkedFiles == 1)
        #expect(try FileWalker.completeSnapshot(fixture.url("Space").path).storage == report.storage)
    }

    @Test func privateUsageDeterminesLargestFileRanking() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let source = try fixture.write("Elsewhere/original", Data(repeating: 7, count: size))
        try clone(source, to: fixture.url("Space/large-clone"))
        try fixture.write("Space/small-private", Data(repeating: 3, count: 65_536))
        let report = try await engine.analyze(fixture.url("Space"), largestLimit: 1)
        #expect(report.entries.first?.name == "small-private")
        #expect(report.largestFiles.map(\.name) == ["small-private"])
    }

    @Test func cacheAndDuplicatePlansUseSameCloneAccounting() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let source = try fixture.write("Documents/a", Data(repeating: 7, count: size))
        try clone(source, to: fixture.url("Documents/b"))
        let cache = fixture.url("Library/Caches/org.bleach.fixture.Clone")
        try clone(source, to: cache.appendingPathComponent("clone"))
        let plan = try await engine.scan(context: fixture.context)
        let candidate = try #require(plan.candidates.first { $0.path == cache.path })
        #expect(candidate.recommendation == .suggested)
        #expect(candidate.privateBytes == 0)
        #expect(candidate.storage.sharedBytes == Int64(size))
        let duplicates = try await engine.duplicates(in: fixture.url("Documents"), context: fixture.context)
        #expect(duplicates.groups.count == 1)
        #expect(duplicates.plan.candidates.count == 1)
        #expect(duplicates.plan.storage.privateBytes == 0)
        #expect(duplicates.plan.storage.sharedBytes == Int64(size))
    }

    @Test func unreadableOrReplacedStorageMetadataStaysUnverified() throws {
        let fixture = try Fixture()
        let file = try fixture.write("file")
        var stamp = BLStat()
        try Files.require(bl_read_stat(file.path, &stamp), file.path)
        stamp.inode += 1
        var usage = BLStorage()
        bl_measure_storage(file.path, &stamp, &usage)
        #expect(usage.private_bytes == 0)
        #expect(usage.shared_bytes == 0)
        #expect(usage.unverified_bytes == stamp.allocated)
        bl_measure_storage(fixture.url("missing").path, &stamp, &usage)
        #expect(usage.unverified_bytes == stamp.allocated)
    }

    @Test func oldSavedPlansDecodeAndStillApplyWithUnverifiedSizes() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        let plan = try await engine.scan(context: fixture.context)
        var json = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(plan)) as? [String: Any])
        var candidates = try #require(json["candidates"] as? [[String: Any]])
        for index in candidates.indices {
            var snapshot = try #require(candidates[index]["snapshot"] as? [String: Any])
            snapshot.removeValue(forKey: "storage")
            candidates[index]["snapshot"] = snapshot
        }
        json["candidates"] = candidates
        let old = try JSONCoding.decoder().decode(CleanupPlan.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.storage.privateBytes == 0)
        #expect(old.storage.unverifiedBytes == old.totalBytes)
        let batch = try await engine.apply(old, context: fixture.context)
        #expect(batch.movedCount == 1)
        let restored = try await engine.restore(batch: batch.id, context: fixture.context)
        #expect(restored.items.first?.state == .restored)
    }

    @Test func outsideCloneChangesEstimateWithoutInvalidatingUnchangedPlan() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let cache = try fixture.cache()
        let plan = try await engine.scan(context: fixture.context)
        let candidate = try #require(plan.candidates.first)
        #expect(candidate.privateBytes > 0)
        try clone(cache.appendingPathComponent("cache.bin"), to: fixture.url("Documents/retained-clone"))
        let current = try FileWalker.completeSnapshot(cache.path)
        #expect(current.storageUsage.privateBytes == 0)
        #expect(current.matchesFileState(candidate.snapshot))
        let batch = try await engine.apply(plan, context: fixture.context)
        #expect(batch.movedCount == 1)
        #expect(Files.exists(fixture.url("Documents/retained-clone").path))
        #expect(try await engine.restore(batch: batch.id, context: fixture.context).items.first?.state == .restored)
    }

    @Test func finderAliasOnlyCountsBookmarkFile() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let target = try fixture.write("Elsewhere/large", Data(repeating: 7, count: size))
        let alias = try fixture.write("Space/alias", Data())
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        let report = try await engine.analyze(fixture.url("Space"))
        #expect(report.fileCount == 1)
        #expect(report.logicalBytes < Int64(size))
        #expect(report.allocatedBytes < Int64(size))
        #expect(report.entries.first?.isDirectory == false)
    }
}
