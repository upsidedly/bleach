import BleachFS
import Darwin
import Foundation
import Testing
@testable import BleachCore

@Suite("Recovery and journaling") struct RecoveryTests {
    @Test func restorationNeverOverwritesRecreatedOriginal() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let cache = try fixture.cache()
        let batch = try await engine.apply(try await firstPlan(fixture, engine: engine), context: fixture.context)
        try fixture.write("Library/Caches/org.bleach.fixture/cache.bin", Data("new data".utf8))
        let result = try await engine.restore(batch: batch.id, context: fixture.context)
        #expect(result.items.first?.state == .conflict)
        #expect(try String(contentsOf: cache.appendingPathComponent("cache.bin"), encoding: .utf8) == "new data")
        let item = try #require(batch.items.first)
        #expect(Files.exists(RecoveryStore(context: fixture.context).itemURL(batch: batch.id, slot: item.slot).path))
    }

    @Test func erasingBatchNeverEmptiesMacTrash() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        let trash = try fixture.write(".Trash/personal.txt", Data("mine".utf8))
        let batch = try await engine.apply(try await firstPlan(fixture, engine: engine), context: fixture.context)
        let result = try await engine.erase(batch: batch.id, context: fixture.context)
        #expect(result.items.first?.state == .erased)
        #expect(result.recoverable.isEmpty)
        #expect(try String(contentsOf: trash, encoding: .utf8) == "mine")
    }

    @Test func writeAheadManifestReconcilesMoveBeforeOutcomeWrite() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        var batch = try await engine.apply(try await firstPlan(fixture, engine: engine), context: fixture.context)
        batch.items[0].state = .prepared; batch.finished = false
        try RecoveryStore(context: fixture.context).save(batch)
        let history = try await engine.history(context: fixture.context)
        #expect(history.first?.items.first?.state == .moved)
        #expect(history.first?.items.first?.message?.contains("interruption") == true)
        let restored = try await engine.restore(batch: batch.id, context: fixture.context)
        #expect(restored.items.first?.state == .restored)
    }

    @Test func interruptedRestoreIsRecognizedAfterRename() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        let batch = try await engine.apply(try await firstPlan(fixture, engine: engine), context: fixture.context)
        var restored = try await engine.restore(batch: batch.id, context: fixture.context)
        restored.items[0].state = .restoring
        try RecoveryStore(context: fixture.context).save(restored)
        #expect(try await engine.history(context: fixture.context).first?.items.first?.state == .restored)
    }

    @Test func interruptedPermanentDeletionIsNotAdvertisedAsUndoableAndCanResume() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        try fixture.write("Library/Caches/org.bleach.fixture/second.bin")
        var batch = try await engine.apply(try await firstPlan(fixture, engine: engine), context: fixture.context)
        let store = RecoveryStore(context: fixture.context)
        let item = try #require(batch.items.first)
        let held = store.itemURL(batch: batch.id, slot: item.slot)
        try FileManager.default.removeItem(at: held.appendingPathComponent("second.bin"))
        batch.items[0].state = .erasing
        try store.save(batch)
        let recovered = try #require(try await engine.history(context: fixture.context).first)
        #expect(recovered.items.first?.state == .eraseInterrupted)
        #expect(recovered.recoverable.isEmpty)
        let erased = try await engine.erase(batch: batch.id, context: fixture.context)
        #expect(erased.items.first?.state == .erased)
    }

    @Test func slotTraversalInManifestIsRejected() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        var batch = try await engine.apply(try await firstPlan(fixture, engine: engine), context: fixture.context)
        batch.items[0].slot = "../../Documents"
        try RecoveryStore(context: fixture.context).save(batch)
        await reject("Invalid recovery manifest") { _ = try await engine.erase(batch: batch.id, context: fixture.context) }
    }

    @Test func replacedRecoveryIdentityIsRetained() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        let batch = try await engine.apply(try await firstPlan(fixture, engine: engine), context: fixture.context)
        let store = RecoveryStore(context: fixture.context)
        let item = try #require(batch.items.first)
        let held = store.itemURL(batch: batch.id, slot: item.slot)
        try FileManager.default.moveItem(at: held, to: fixture.url("held-original"))
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: held.appendingPathComponent("keep"))
        let result = try await engine.erase(batch: batch.id, context: fixture.context)
        #expect(result.items.first?.state == .conflict)
        #expect(Files.exists(held.appendingPathComponent("keep").path))
    }

    @Test func changedRecoveryContentRequiresInspection() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        let batch = try await engine.apply(try await firstPlan(fixture, engine: engine), context: fixture.context)
        let item = try #require(batch.items.first)
        let held = RecoveryStore(context: fixture.context).itemURL(batch: batch.id, slot: item.slot)
        try Data("an app wrote through an open descriptor".utf8).write(to: held.appendingPathComponent("cache.bin"))
        let result = try await engine.erase(batch: batch.id, context: fixture.context)
        #expect(result.items.first?.state == .conflict)
        #expect(Files.exists(held.path))
    }

    @Test func separateProcessLockPreventsOverlappingOperations() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let cache = try fixture.cache()
        let plan = try await firstPlan(fixture, engine: engine)
        let store = RecoveryStore(context: fixture.context)
        try store.ensureStorage()
        let descriptor = try store.lock()
        defer { bl_close(descriptor) }
        await reject("Another Bleach operation") { _ = try await engine.apply(plan, context: fixture.context) }
        #expect(Files.exists(cache.path))
    }

    @Test func recoveryAndManifestArePrivate() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        let batch = try await engine.apply(try await firstPlan(fixture, engine: engine), context: fixture.context)
        let store = RecoveryStore(context: fixture.context)
        #expect(try Files.stamp(fixture.context.state.path).mode & 0o777 == 0o700)
        #expect(try Files.stamp(store.directory(batch.id).appendingPathComponent("batch.json").path).mode & 0o777 == 0o600)
    }

    @Test func exclusiveRenamePreservesDestination() throws {
        let fixture = try Fixture()
        let source = try fixture.write("source", Data("source".utf8))
        let destination = try fixture.write("destination", Data("destination".utf8))
        let stamp = try Files.stamp(source.path)
        #expect(bl_move_exclusive(source.path, destination.path, stamp.device, stamp.inode) == EEXIST)
        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "destination")
    }

    @Test func linkedStateDirectoryIsRefused() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        try fixture.write("Documents/existing")
        try FileManager.default.createDirectory(at: fixture.url("Library/Application Support"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.context.state, withDestinationURL: fixture.url("Documents"))
        let plan = try await firstPlan(fixture, engine: engine)
        await reject("Bleach") { _ = try await engine.apply(plan, context: fixture.context) }
        #expect(!Files.exists(fixture.url("Documents/Recovery").path))
    }
}
