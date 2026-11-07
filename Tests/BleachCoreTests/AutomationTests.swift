import Foundation
import Testing
@testable import BleachCore

@Suite struct AutomationTests {
    @Test func legacyPreferencesStayDisabled() throws {
        let data = Data(#"{"schemaVersion":1,"excludedPaths":[],"projectRoots":[],"minimumAgeDays":30}"#.utf8)
        let old = try JSONCoding.decoder().decode(Preferences.self, from: data)
        #expect(old.automaticCleanup == nil)
        #expect(!AutomaticCleanupSettings().enabled)
    }

    @Test func thresholdsPauseAndUnavailableDisk() {
        let now = Date()
        var settings = AutomaticCleanupSettings()
        #expect(!settings.shouldRun(total: 100_000_000_000, available: 0, now: now))
        settings.enabled = true
        #expect(settings.shouldRun(total: 100_000_000_000, available: 9_000_000_000, now: now))
        #expect(!settings.shouldRun(total: 100_000_000_000, available: 10_000_000_000, now: now))
        #expect(!settings.shouldRun(total: -1, available: -1, now: now))
        settings.unit = .percent; settings.threshold = 5
        #expect(settings.targetBytes(total: 200_000_000_000) == 10_000_000_000)
        settings.pausedUntil = now.addingTimeInterval(3600)
        #expect(!settings.shouldRun(total: 200_000_000_000, available: 1, now: now))
        settings.pausedUntil = now.addingTimeInterval(-1)
        #expect(settings.shouldRun(total: 200_000_000_000, available: 1, now: now))
        settings.threshold = 31
        #expect(!settings.valid)
    }

    @Test func automaticPassPreservesUsefulDataAndPriorRecovery() async throws {
        let f = try Fixture(), engine = BleachEngine()
        let oldCache = try f.cache("org.bleach.fixture.old")
        let oldPlan = try await firstPlan(f, engine: engine)
        let previous = try await engine.apply(oldPlan.selecting([oldCache.path]), context: f.context)
        let useful = try f.cache("org.bleach.fixture.useful")
        try f.write(".npm/_cacache/content-v2/data")
        let log = try f.write("Library/Logs/Fixture/old.log"); try f.age(log.deletingLastPathComponent(), days: 100)
        let recentLog = try f.write("Library/Logs/Recent/keep.log"); try f.age(recentLog.deletingLastPathComponent(), days: 60)
        try f.write(".codex/sessions/keep.jsonl")
        try f.write("Projects/Keep/node_modules/module.js")
        try f.write("Projects/Keep/package.json", Data(#"{"name":"keep"}"#.utf8))
        try f.write("Library/Developer/Xcode/DerivedData/Keep/Build/output.o")
        var preferences = Preferences(); var settings = AutomaticCleanupSettings(); settings.enabled = true
        preferences.automaticCleanup = settings
        preferences.projectRoots = [f.url("Projects").path]
        try await engine.updatePreferences(preferences, context: f.context)
        let narrow = try await engine.scan(context: f.context, automaticOnly: true)
        #expect(narrow.candidates.allSatisfy { $0.rule == .log || $0.rule == .npmCache || $0.rule == .packageDownloadCache })
        let full = try await engine.scan(context: f.context)
        #expect(full.candidates.filter { $0.kind == .dependencies }.allSatisfy { !CleanupLevel.thorough.includes($0) })
        let result = try await engine.runAutomaticCleanup(context: f.context, capacity: (100_000_000_000, 0))
        let batch = try #require(result)
        #expect(batch.items.count == 2)
        #expect(batch.items.allSatisfy { $0.state == .erased })
        #expect(!FileManager.default.fileExists(atPath: f.url(".npm/_cacache").path))
        #expect(!FileManager.default.fileExists(atPath: log.path))
        for path in [useful.path, recentLog.path, f.url(".codex/sessions/keep.jsonl").path, f.url("Projects/Keep/node_modules/module.js").path,
                     f.url("Library/Developer/Xcode/DerivedData/Keep/Build/output.o").path] { #expect(FileManager.default.fileExists(atPath: path)) }
        let restored = try await engine.restore(batch: previous.id, context: f.context)
        #expect(restored.items.first?.state == .restored)
        #expect(FileManager.default.fileExists(atPath: oldCache.path))
    }

    @Test func autoHonorsExclusionsAndRejectsBuildCaches() async throws {
        let f = try Fixture(), engine = BleachEngine()
        let path = try f.write(".npm/_cacache/content-v2/data").deletingLastPathComponent().deletingLastPathComponent()
        try f.write(".cargo/registry/cache/host/crate")
        try f.write(".cache/prisma/engine")
        var preferences = Preferences(); preferences.excludedPaths = [path.path]
        var settings = AutomaticCleanupSettings(); settings.enabled = true; preferences.automaticCleanup = settings
        try await engine.updatePreferences(preferences, context: f.context)
        let plan = try await engine.scan(context: f.context)
        #expect(plan.candidates.filter { $0.path.contains("prisma") }.allSatisfy { !settings.allows($0) })
        let batch = try await engine.runAutomaticCleanup(context: f.context, capacity: (100_000_000_000, 0))
        #expect(batch?.items.allSatisfy { $0.candidate.cacheProof?.kind == .cargoArchives } == true)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test func permanentSelectionDoesNotEraseAnotherBatch() async throws {
        let f = try Fixture(), engine = BleachEngine()
        let keep = try f.cache("org.bleach.fixture.keep")
        let first = try await firstPlan(f, engine: engine)
        let held = try await engine.apply(first.selecting([keep.path]), context: f.context)
        let remove = try f.cache("org.bleach.fixture.remove")
        let second = try await firstPlan(f, engine: engine)
        let erased = try await engine.deletePermanently(second.selecting([remove.path]), context: f.context)
        #expect(erased.items.allSatisfy { $0.state == .erased })
        let restored = try await engine.restore(batch: held.id, context: f.context)
        #expect(restored.items.allSatisfy { $0.state == .restored })
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(!FileManager.default.fileExists(atPath: remove.path))
    }
}
