import Foundation
import Testing
@testable import BleachCore

struct CacheDiscoveryTests {
    @Test func browserArchiveCachesKeepInstalledComponentsAndUpdaterBinaries() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.app("Chrome", id: "com.google.Chrome")
        for path in ["Library/Application Support/Google/Chrome/component_crx_cache/update.crx", "Library/Application Support/Google/Chrome/extensions_crx_cache/extension.crx", "Library/Application Support/Google/GoogleUpdater/crx_cache/update.crx"] { try f.write(path) }
        let component = try f.write("Library/Application Support/Google/Chrome/WidevineCdm/installed.component")
        let updater = try f.write("Library/Google/GoogleUpdater/version/updater")
        let plan = try await engine.scan(context: f.context)
        #expect(plan.candidates.count == 3)
        #expect(plan.candidates.allSatisfy { $0.recommendation == .suggested })
        let batch = try await engine.apply(plan, context: f.context)
        #expect(batch.movedCount == 3, "\(batch.items.map { $0.message ?? $0.state.rawValue })")
        #expect(Files.exists(component.path) && Files.exists(updater.path))
        let restored = try await engine.restore(batch: batch.id, context: f.context)
        #expect(restored.items.allSatisfy { $0.state == .restored }, "\(restored.items.map { $0.message ?? $0.state.rawValue })")
        var forged = try #require(plan.candidates.first)
        forged.path = f.url("Library/Application Support/Google/Chrome/Default/component_crx_cache").path
        #expect(!CleanupPolicy(context: f.context, preferences: Preferences()).ruleMatches(forged))
    }

    @Test func updaterExecutableReferencesProtectItsSeparateDownloadCache() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.app("Chrome", id: "com.google.Chrome")
        try f.write("Library/Application Support/Google/GoogleUpdater/crx_cache/update.crx")
        let executable = f.url("Library/Google/GoogleUpdater/version/updater")
        try f.write("Library/Google/GoogleUpdater/version/updater")
        let input = Pipe(), output = Pipe()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf ready; read -r value", executable.path]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        #expect(try output.fileHandleForReading.read(upToCount: 5) == Data("ready".utf8))
        let plan = try await engine.scan(context: f.context)
        #expect(plan.candidates.count == 1)
        #expect(plan.candidates.first?.recommendation == .blocked)
    }

    @Test func downloadArchivesAreSuggestedButLinkedStoresAndSourceStay() async throws {
        let f = try Fixture(), engine = BleachEngine()
        let cargo = try f.write(".cargo/registry/cache/example/crate.crate")
        try f.write(".cache/prisma/engine")
        let source = try f.write(".cargo/registry/src/example/precious.rs")
        let command = try f.write(".cargo/bin/my-command")
        let uv = try f.write(".cache/uv/archive-v0/package/source.py")
        let yarn = try f.write(".yarn/berry/cache/package.zip")
        try f.write("Library/Caches/uv/archive-v0/package/source.py")
        let plan = try await engine.scan(context: f.context)
        #expect(plan.candidates.count == 2)
        #expect(plan.candidates.allSatisfy { $0.rule == .packageDownloadCache && $0.recommendation == .suggested })
        let batch = try await engine.apply(plan, context: f.context)
        #expect(batch.movedCount == 2, "\(batch.items.map { $0.message ?? $0.state.rawValue })")
        for file in [source, command, uv, yarn] { #expect(Files.exists(file.path)) }
        #expect(!Files.exists(cargo.path))
        let restored = try await engine.restore(batch: batch.id, context: f.context)
        #expect(restored.items.allSatisfy { $0.state == .restored }, "\(restored.items.map { $0.message ?? $0.state.rawValue })")
        #expect(Files.exists(cargo.path))
    }

    @Test func movedCachesUseCurrentConfigurationAndOnlyNamedBuckets() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.write(".npmrc", Data("cache=\"~/Moved/npm data\"\n".utf8))
        try f.write("Library/Application Support/pip/pip.conf", Data("[global]\ncache-dir = ~/Moved/pip\n".utf8))
        for path in ["Moved/npm data/_cacache/data", "Moved/npm data/_npx/data", "Moved/pip/http-v2/data", "Moved/pip/wheels/data", "Moved/gradle/caches/data"] { try f.write(path) }
        let keep = try f.write("Moved/pip/notes.txt")
        let context = ScanContext(home: f.root, cacheEnvironment: ["GRADLE_USER_HOME": f.url("Moved/gradle").path])
        let plan = try await engine.scan(context: context)
        #expect(plan.candidates.count == 5)
        #expect(plan.candidates.allSatisfy { $0.recommendation == .suggested })
        let batch = try await engine.apply(plan, context: context)
        #expect(batch.movedCount == 5, "\(batch.items.map { $0.message ?? $0.state.rawValue })")
        #expect(Files.exists(keep.path))
        let restored = try await engine.restore(batch: batch.id, context: context)
        #expect(restored.items.allSatisfy { $0.state == .restored }, "\(restored.items.map { $0.message ?? $0.state.rawValue })")
    }

    @Test func changedConfigurationInvalidatesSavedCachePlan() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.write(".npmrc", Data("cache=~/Moved/old\n".utf8))
        let data = try f.write("Moved/old/_cacache/data")
        let plan = try await engine.scan(context: f.context)
        #expect(plan.candidates.count == 1)
        try f.write(".npmrc", Data("cache=~/Moved/new\n".utf8))
        await reject("cleanup rule") { _ = try await engine.apply(plan, context: f.context) }
        #expect(Files.exists(data.path))
    }

    @Test func changingCacheConfigurationAfterCleanupDoesNotStrandUndo() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.write(".npmrc", Data("cache=~/Moved/old\n".utf8))
        let data = try f.write("Moved/old/_cacache/data")
        let batch = try await engine.apply(try await engine.scan(context: f.context), context: f.context)
        try f.write(".npmrc", Data("cache=~/Moved/new\n".utf8))
        #expect(try await engine.restore(batch: batch.id, context: f.context).items.first?.state == .restored)
        #expect(Files.exists(data.path))
    }

    @Test func cacheOverridesCannotReachProtectedOrForeignRoots() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.write(".codex/_cacache/sessions")
        try f.write(".t3/caches/state.sqlite")
        let context = ScanContext(home: f.root, cacheEnvironment: ["NPM_CONFIG_CACHE": f.url(".codex").path, "GRADLE_USER_HOME": f.url(".t3").path, "CARGO_HOME": "/Users/matthew/.cargo", "PIP_CACHE_DIR": f.root.path])
        #expect(try await engine.scan(context: context).candidates.isEmpty)
        #expect(f.context.cacheEnvironment.isEmpty)
        #expect(CacheLocations.resolve("$(touch sentinel)", context: f.context) == nil)
        #expect(CacheLocations.resolve(f.root.path + "/a/../b", context: f.context) == nil)
        #expect(!CacheLocations.safe(f.url(".CODEX/_cacache").path, context: f.context))
        #expect(!CacheLocations.safe(f.url("Library/Caches/UV/_cacache").path, context: f.context))
    }

    @Test func movedCachesInsideGenericCachesNeverOverlap() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.write("Library/Caches/moved/_cacache/data")
        let context = ScanContext(home: f.root, cacheEnvironment: ["NPM_CONFIG_CACHE": f.url("Library/Caches/moved").path])
        let plan = try await engine.scan(context: context)
        #expect(plan.candidates.count == 1)
        #expect(plan.candidates.first?.path == f.url("Library/Caches/moved").path)
        #expect(try await engine.apply(plan, context: context).movedCount == 1)
    }

    @Test func chromiumCacheSelectionPreservesSessionsAndOfflineData() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.app("Figma", id: "com.figma.Desktop")
        let base = "Library/Application Support/Figma/DesktopProfile/v43/"
        for path in ["Cache/data", "Code Cache/js/data", "GPUCache/data"] { try f.write(base + path) }
        let protected = ["Cookies", "Local Storage/db", "IndexedDB/db", "Service Worker/CacheStorage/offline", "Session Storage/session"]
        for path in protected { try f.write(base + path) }
        try f.write("Library/Application Support/Figma/random/Cache/precious")
        let plan = try await engine.scan(context: f.context)
        #expect(plan.candidates.count == 3)
        #expect(plan.candidates.allSatisfy { $0.category == .caches })
        #expect(plan.candidates.allSatisfy { $0.rule == .chromiumCache && $0.recommendation == .suggested })
        let batch = try await engine.apply(plan, context: f.context)
        #expect(batch.movedCount == 3)
        for path in protected { #expect(Files.exists(f.url(base + path).path)) }
        #expect(try await engine.restore(batch: batch.id, context: f.context).items.allSatisfy { $0.state == .restored })
    }

    @Test func chromiumOwnerHelpersAndForgedProfilesAreRetained() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.app("Notion", id: "notion.id")
        try f.write("Library/Application Support/Notion/Partitions/notion/Cache/data")
        let context = ScanContext(home: f.root, runningOwners: [RunningOwner(bundleID: "notion.id.helper", applicationPath: "/Applications/Notion.app/Contents/Frameworks/Helper.app")])
        let plan = try await engine.scan(context: context)
        var candidate = try #require(plan.candidates.first)
        #expect(candidate.recommendation == .blocked)
        #expect(plan.suggestedPrivateBytes == 0)
        candidate.path = f.url("Library/Application Support/Notion/Partitions/notion/IndexedDB").path
        #expect(!CleanupPolicy(context: f.context, preferences: Preferences()).ruleMatches(candidate))
        candidate.path = f.url("Library/Application Support/Notion/not-a-profile/Cache").path
        #expect(!CleanupPolicy(context: f.context, preferences: Preferences()).ruleMatches(candidate))
    }

    @Test func activeReferencesAlsoProtectExistingPackageCaches() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.write(".npm/_cacache/data")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        process.currentDirectoryURL = f.url(".npm/_cacache")
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let plan = try await engine.scan(context: f.context)
        #expect(plan.candidates.first?.recommendation == .blocked)
        #expect(plan.suggestedPrivateBytes == 0)
    }

    @Test func movedGoCacheNeedsItsOwnMarkerAndRetainsConfiguration() async throws {
        let f = try Fixture(), engine = BleachEngine()
        let context = ScanContext(home: f.root, cacheEnvironment: ["GOCACHE": f.url("Moved/go-build").path])
        try f.write("Moved/go-build/00/data")
        #expect(try await engine.scan(context: context).candidates.isEmpty)
        try f.write("Moved/go-build/README", Data("This directory holds cached build artifacts from the Go build system.\n".utf8))
        let plan = try await engine.scan(context: context)
        #expect(plan.candidates.count == 1)
        let batch = try await engine.apply(plan, context: context)
        let restored = try await engine.restore(batch: batch.id, context: context)
        #expect(restored.items.first?.state == .restored, "\(restored.items.map { $0.message ?? $0.state.rawValue })")
    }
}
