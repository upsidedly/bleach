import Foundation
import Testing
@testable import BleachCore

struct OutputDiscoveryTests {
    @Test func processingCachesRequireTheirProjectsAndPreserveGeneratedModulesAndImportSettings() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.write("Projects/Game/project.godot", Data("config_version=5\n[application]\nconfig/name=\"Fixture\"".utf8))
        try f.write("Projects/Game/.godot/imported/asset.ctex")
        let settings = try f.write("Projects/Game/art/asset.png.import")
        let asset = try f.write("Projects/Game/art/asset.png")
        let editor = try f.write("Projects/Game/.godot/editor/state")
        try f.write("Projects/Web/package.json", Data("{\"dependencies\":{\"contentlayer2\":\"0.5.8\"}}".utf8))
        try f.write("Projects/Web/contentlayer.config.ts", Data("export default {}".utf8))
        try f.write("Projects/Web/.contentlayer/.cache/v0.5.8/processed.json")
        let generated = try f.write("Projects/Web/.contentlayer/generated/index.js")
        let source = try f.write("Projects/Web/content/article.md")
        try f.write("Projects/Decoy/.contentlayer/.cache/precious")
        try f.write("Projects/Decoy/.godot/imported/precious")
        let plan = try await engine.discover(in: f.url("Projects"), context: f.context).plan
        #expect(plan.candidates.count == 2)
        #expect(plan.candidates.allSatisfy { $0.rule == .projectProcessingCache && $0.recommendation == .review })
        let quick = try await engine.scan(context: f.context, additionalProjectRoots: [f.url("Projects")])
        #expect(Set(quick.candidates.map(\.path)) == Set(plan.candidates.map(\.path)))
        let batch = try await engine.apply(plan, context: f.context)
        #expect(batch.movedCount == 2)
        for file in [settings, asset, editor, generated, source] { #expect(Files.exists(file.path)) }
        #expect(try await engine.restore(batch: batch.id, context: f.context).items.allSatisfy { $0.state == .restored })
    }

    @Test func activeProcessingProjectIsRetainedEvenWhenItsCacheHasNoOpenFiles() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.write("Projects/Game/project.godot", Data("config_version=5".utf8))
        try f.write("Projects/Game/.godot/imported/asset.ctex")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["60"]
        process.currentDirectoryURL = f.url("Projects/Game")
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let plan = try await engine.discover(in: f.url("Projects"), context: f.context).plan
        #expect(plan.candidates.count == 1)
        #expect(plan.candidates.first?.recommendation == .blocked)
    }

    @Test func customOutputsAreFoundWithoutDeletingMixedBuildFolders() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.write("Projects/Swift/Package.swift", Data("// swift-tools-version: 6.0".utf8))
        let swift = "Projects/Swift/build/spm/arm64-apple-macosx"
        try f.write(swift + "/release/description.json", Data("{}".utf8))
        try f.write(swift + "/release/output.o")
        let checkout = try f.write("Projects/Swift/build/spm/checkouts/Dependency/source.swift")
        let precious = try f.write("Projects/Swift/build/music/song.wav")
        try f.write("Projects/Web/package.json", Data("{\"dependencies\":{\"next\":\"16\"}}".utf8))
        let next = "Projects/Web/tmp/custom-output"
        for marker in ["BUILD_ID", "build-manifest.json", "routes-manifest.json", "server/data", "static/data"] { try f.write(next + "/" + marker, marker == "BUILD_ID" ? Data("fixture-build".utf8) : Data(repeating: 37, count: 8192)) }
        let plan = try await engine.discover(in: f.url("Projects"), context: f.context).plan
        #expect(Set(plan.candidates.map(\.path)) == [f.url(swift).path, f.url(next).path])
        #expect(plan.candidates.allSatisfy { $0.rule == .customBuildOutput && $0.recommendation == .review })
        let batch = try await engine.apply(plan, context: f.context)
        #expect(batch.movedCount == 2)
        #expect(Files.exists(checkout.path) && Files.exists(precious.path))
        let restored = try await engine.restore(batch: batch.id, context: f.context)
        #expect(restored.items.allSatisfy { $0.state == .restored })
    }

    @Test func customHomesDoNotReachTheRealCompilerCache() async throws {
        let f = try Fixture(), engine = BleachEngine()
        #expect(f.context.compilerCache == nil)
        try f.write("CompilerCache/data")
        let context = ScanContext(home: f.root, compilerCache: f.url("CompilerCache"))
        let plan = try await engine.scan(context: context)
        let candidate = try #require(plan.candidates.first { $0.rule == .clangModuleCache })
        #expect(candidate.recommendation == .suggested)
        let batch = try await engine.apply(plan.selecting([candidate.path]), context: context)
        #expect(batch.movedCount == 1)
        #expect(try await engine.restore(batch: batch.id, context: context).items.first?.state == .restored)
    }
}
