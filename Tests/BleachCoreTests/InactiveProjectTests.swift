import Foundation
import Testing
@testable import BleachCore

struct InactiveProjectTests {
    // ctime cannot be backdated. Advance only the injected clock to model an old
    // project without weakening production activity checks.
    private func oldContext(_ f: Fixture) -> ScanContext { ScanContext(home: f.root, now: f.now.addingTimeInterval(120 * 86_400)) }
    private func project(_ f: Fixture, name: String = "Projects/Old", python: Bool = false) throws -> URL {
        let manifests: [String: String] = python ? ["pyproject.toml": "[project]\nname='old'\nversion='0.1.0'", "uv.lock": "version = 1"] : ["package.json": "{\"name\":\"old\"}", "package-lock.json": "{\"lockfileVersion\":3}"]
        for (path, text) in manifests {
            let file = try f.write(name + "/" + path, Data(text.utf8))
            let old = f.now.addingTimeInterval(-90 * 86_400)
            try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: file.path)
        }
        let environment = python ? ".venv" : "node_modules"
        try f.write(name + "/" + environment + "/" + (python ? "pyvenv.cfg" : "dependency/data"))
        return f.url(name + "/" + environment)
    }

    @Test func oldLockedEnvironmentsRoundTripAndKeepSource() async throws {
        let f = try Fixture(), engine = BleachEngine()
        let node = try project(f), python = try project(f, name: "Projects/Python", python: true)
        let plan = try await engine.inactiveProjects(in: f.url("Projects"), context: oldContext(f))
        #expect(Set(plan.candidates.map(\.path)) == [node.path, python.path])
        #expect(plan.suggested.isEmpty)
        #expect(plan.candidates.allSatisfy { $0.projectEvidence?.reinstallCommand.isEmpty == false })
        let batch = try await engine.apply(plan, context: oldContext(f))
        #expect(batch.movedCount == 2)
        #expect(Files.exists(f.url("Projects/Old/package-lock.json").path))
        let restored = try await engine.restore(batch: batch.id, context: oldContext(f))
        #expect(restored.items.allSatisfy { $0.state == .restored })
        #expect(Files.exists(python.path))
    }

    @Test func recentSourceAndAmbiguousRecipesAreRetained() async throws {
        let f = try Fixture(), engine = BleachEngine()
        _ = try project(f)
        try f.write("Projects/Old/source.swift")
        _ = try project(f, name: "Projects/Ambiguous")
        try f.write("Projects/Ambiguous/bun.lock", Data("{}".utf8))
        let plan = try await engine.inactiveProjects(in: f.url("Projects"), context: f.context)
        #expect(plan.candidates.isEmpty)
        #expect(plan.issues.contains { $0.message.contains("activity") })
        #expect(plan.issues.contains { $0.message.contains("lockfile") })
    }

    @Test func recipeAndSourceAreRecheckedBeforeMoving() async throws {
        let f = try Fixture(), engine = BleachEngine()
        let environment = try project(f)
        let plan = try await engine.inactiveProjects(in: f.url("Projects"), context: oldContext(f))
        #expect(plan.candidates.count == 1)
        try f.write("Projects/Old/package-lock.json", Data("changed".utf8))
        await reject("changed") { _ = try await engine.apply(plan, context: oldContext(f)) }
        #expect(Files.exists(environment.path))
    }

    @Test func liveWorkingDirectoryProtectsOldProject() async throws {
        let f = try Fixture(), engine = BleachEngine()
        let environment = try project(f)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["20"]
        child.currentDirectoryURL = environment.deletingLastPathComponent()
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let plan = try await engine.inactiveProjects(in: f.url("Projects"), context: oldContext(f))
        #expect(plan.candidates.isEmpty)
        #expect(plan.issues.contains { $0.message.contains("running process") })
    }

    @Test func newFileWithOldMtimeStillProtectsProject() async throws {
        let f = try Fixture(), engine = BleachEngine()
        _ = try project(f)
        let source = try f.write("Projects/Old/new-source.swift")
        try FileManager.default.setAttributes([.modificationDate: f.now.addingTimeInterval(-120 * 86_400)], ofItemAtPath: source.path)
        let plan = try await engine.inactiveProjects(in: f.url("Projects"), context: f.context)
        #expect(plan.candidates.isEmpty)
    }
}
