import Foundation
import Testing
@testable import BleachCore

struct OutputDiscoveryTests {
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
