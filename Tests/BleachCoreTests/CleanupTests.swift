import BleachFS
import Darwin
import Foundation
import Testing
@testable import BleachCore

@Suite("Cleanup boundaries") struct CleanupTests {
    @Test func selectsRebuildableCachesRegardlessOfAge() async throws {
        let fixture = try Fixture()
        try fixture.cache("old", days: 20); try fixture.cache("recent", days: 1)
        try fixture.write("Documents/precious.txt"); try fixture.write(".ssh/id_ed25519")
        let plan = try await BleachEngine().scan(context: fixture.context)
        #expect(plan.candidates.count == 2)
        #expect(plan.candidates.first { $0.title == "old" }?.recommendation == .suggested)
        #expect(plan.candidates.first { $0.title == "recent" }?.recommendation == .suggested)
        #expect(plan.suggestedBytes == plan.totalBytes)
        #expect(!Files.exists(fixture.context.state.path))
    }

    @Test func selectsPackageCachesWithoutRequiringManualReview() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.write(".npm/_cacache/packages")
        try fixture.write(".gradle/caches/modules")
        try fixture.write(".cache/pip/download")
        let plan = try await engine.scan(context: fixture.context)
        #expect(plan.candidates.count == 3)
        #expect(plan.candidates.allSatisfy { $0.recommendation == .suggested })
        #expect(plan.suggestedBytes == plan.totalBytes)
    }

    @Test func keepsRunningAppCachesOutOfDefaultSelection() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        let context = ScanContext(home: fixture.root, now: fixture.now,
            runningOwners: [RunningOwner(bundleID: "org.bleach.fixture", applicationPath: "/Applications/Fake.app")])
        let plan = try await engine.scan(context: context)
        #expect(plan.candidates.first?.recommendation == .blocked)
        #expect(plan.suggestedBytes == 0)
    }

    @Test func exportedPlanRoundTripsAndRestoresExactData() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let cache = try fixture.cache()
        let original = try Data(contentsOf: cache.appendingPathComponent("cache.bin"))
        let plan = try await firstPlan(fixture, engine: engine)
        let decoded = try JSONCoding.decoder().decode(CleanupPlan.self, from: JSONCoding.encoder().encode(plan))
        let batch = try await engine.apply(decoded, context: fixture.context)
        #expect(batch.movedCount == 1)
        #expect(!Files.exists(cache.path))
        #expect(batch.heldBytes == plan.totalBytes)
        let result = try await engine.restore(batch: batch.id, context: fixture.context)
        #expect(result.items.first?.state == .restored)
        #expect(try Data(contentsOf: cache.appendingPathComponent("cache.bin")) == original)
    }

    @Test func changedDeepDescendantInvalidatesPreview() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.write("Library/Caches/deep/a/b/value", Data("before".utf8))
        let plan = try await firstPlan(fixture, engine: engine)
        try fixture.write("Library/Caches/deep/a/b/value", Data("after!".utf8))
        await reject("Changed since preview") { _ = try await engine.apply(plan, context: fixture.context) }
        #expect(Files.exists(fixture.url("Library/Caches/deep/a/b/value").path))
    }

    @Test func addedDescendantInvalidatesPreview() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        let plan = try await firstPlan(fixture, engine: engine)
        try fixture.write("Library/Caches/org.bleach.fixture/new-file")
        await reject("Changed since preview") { _ = try await engine.apply(plan, context: fixture.context) }
    }

    @Test func replacedRootIsRejected() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let cache = try fixture.cache()
        let plan = try await firstPlan(fixture, engine: engine)
        try FileManager.default.moveItem(at: cache, to: fixture.url("old-cache"))
        try fixture.cache()
        await reject("Changed since preview") { _ = try await engine.apply(plan, context: fixture.context) }
    }

    @Test func preflightsEveryTargetBeforeMovingAny() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let first = try fixture.cache("a"), second = try fixture.cache("b")
        let plan = try await firstPlan(fixture, engine: engine)
        try fixture.write("Library/Caches/b/changed")
        await reject("Changed since preview") { _ = try await engine.apply(plan, context: fixture.context) }
        #expect(Files.exists(first.path)); #expect(Files.exists(second.path))
    }

    @Test func linkedCacheRootNeverTraversesDocuments() async throws {
        let fixture = try Fixture()
        let precious = try fixture.write("Documents/precious.txt")
        try FileManager.default.createDirectory(at: fixture.url("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.url("Library/Caches/trap"), withDestinationURL: precious.deletingLastPathComponent())
        let plan = try await BleachEngine().scan(context: fixture.context)
        #expect(plan.candidates.isEmpty); #expect(!plan.issues.isEmpty)
        #expect(Files.exists(precious.path))
    }

    @Test func linkedAncestorFailsClosed() async throws {
        let fixture = try Fixture()
        try fixture.write("Documents/candidate/file")
        try FileManager.default.createDirectory(at: fixture.url("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.url("Library/Caches"), withDestinationURL: fixture.url("Documents"))
        let plan = try await BleachEngine().scan(context: fixture.context)
        #expect(plan.candidates.isEmpty); #expect(!plan.issues.isEmpty)
        #expect(Files.exists(fixture.url("Documents/candidate/file").path))
    }

    @Test func symlinkInsideCacheIsMovedAndErasedWithoutFollowingIt() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let cache = try fixture.cache()
        let precious = try fixture.write("Documents/keep.txt", Data("keep".utf8))
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("link"), withDestinationURL: precious)
        let batch = try await engine.apply(try await firstPlan(fixture, engine: engine), context: fixture.context)
        let erased = try await engine.erase(batch: batch.id, context: fixture.context)
        #expect(erased.items.first?.state == .erased)
        #expect(try String(contentsOf: precious, encoding: .utf8) == "keep")
    }

    @Test func unreadableDescendantNeverProducesPartialCleanupTarget() async throws {
        let fixture = try Fixture()
        try fixture.cache()
        let restricted = try fixture.write("Library/Caches/org.bleach.fixture/restricted/file").deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        let plan = try await BleachEngine().scan(context: fixture.context)
        #expect(plan.candidates.isEmpty)
        #expect(!plan.issues.isEmpty)
    }

    @Test func descendantExclusionProtectsItsWholeCandidate() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        var preferences = Preferences()
        preferences.excludedPaths = [fixture.url("Library/Caches/org.bleach.fixture/cache.bin").path]
        try await engine.updatePreferences(preferences, context: fixture.context)
        let plan = try await engine.scan(context: fixture.context)
        #expect(plan.candidates.isEmpty)
        #expect(plan.issues.contains { $0.message.contains("Excluded") })
    }

    @Test func exclusionAddedAfterPreviewIsEnforcedAtApply() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        let cache = try fixture.cache()
        let plan = try await firstPlan(fixture, engine: engine)
        var preferences = Preferences(); preferences.excludedPaths = [cache.path]
        try await engine.updatePreferences(preferences, context: fixture.context)
        await reject("Excluded") { _ = try await engine.apply(plan, context: fixture.context) }
        #expect(Files.exists(cache.path))
    }

    @Test func corruptExclusionsStopCleanup() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        try fixture.write("Library/Application Support/Bleach/preferences.json", Data("{bad".utf8))
        await reject("Cannot read Bleach exclusions") { _ = try await engine.scan(context: fixture.context) }
    }

    @Test func repeatedOrOverlappingTargetsAreRefused() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        var plan = try await firstPlan(fixture, engine: engine)
        plan.candidates.append(plan.candidates[0])
        await reject("Overlapping") { _ = try await engine.apply(plan, context: fixture.context) }
    }

    @Test func expiredAndForeignHomePlansAreRefused() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        var plan = try await firstPlan(fixture, engine: engine)
        plan.createdAt = fixture.now.addingTimeInterval(-86_401)
        await reject("expired") { _ = try await engine.apply(plan, context: fixture.context) }
        plan.createdAt = fixture.now; plan.home = "/Users/someone-else"
        await reject("Invalid") { _ = try await engine.apply(plan, context: fixture.context) }
    }

    @Test func forgedDocumentsRuleDoesNotAuthorizeCleanup() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        let document = try fixture.write("Documents/precious.txt")
        var plan = try await firstPlan(fixture, engine: engine)
        plan.candidates[0].path = document.path
        plan.candidates[0].snapshot = try FileWalker.completeSnapshot(document.path)
        await reject("does not match") { _ = try await engine.apply(plan, context: fixture.context) }
        #expect(Files.exists(document.path))
    }

    @Test func liveOwnerIsBlockedEvenIfPlanRecommendationsAreForged() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.cache()
        var plan = try await firstPlan(fixture, engine: engine)
        plan.candidates[0].recommendation = .suggested
        let context = ScanContext(home: fixture.root, now: fixture.now,
            runningOwners: [RunningOwner(bundleID: "org.bleach.fixture", applicationPath: "/Applications/Fake.app")])
        await reject("running") { _ = try await engine.apply(plan, context: context) }
    }

    @Test func artifactsNeedMatchingManifestsAndExplicitProjectRoots() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        try fixture.write("Projects/valid/package.json", Data("{}".utf8))
        try fixture.write("Projects/valid/node_modules/pkg/index.js")
        try fixture.write("Projects/invalid/target/personal.txt")
        let standard = try await engine.scan(context: fixture.context)
        #expect(standard.candidates.isEmpty)
        let withProjects = try await engine.scan(context: fixture.context, additionalProjectRoots: [fixture.url("Projects")])
        #expect(withProjects.candidates.count == 1)
        #expect(withProjects.candidates.first?.rule == .projectArtifact)
        #expect(withProjects.candidates.first?.recommendation == .review)
    }

    @Test func cancellationStopsScanWithoutCreatingRecovery() async throws {
        let fixture = try Fixture(), engine = BleachEngine()
        for index in 0..<200 { try fixture.write("Library/Caches/cache/\(index)") }
        let task = Task { try await engine.scan(context: fixture.context) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(!Files.exists(fixture.context.state.path))
    }
}
