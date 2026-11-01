import Foundation
import Testing
@testable import BleachCore

struct GrowthTests {
    @Test func readsDoNotCreateStateAndExplicitCapturesCompareChanges() async throws {
        let f = try Fixture(), engine = BleachEngine()
        let canary = "private-history-body-not-for-metadata"
        try f.write("Projects/First/data", Data(canary.utf8))
        let first = try await engine.growth(in: f.url("Projects"), context: f.context)
        #expect(first.previousDate == nil && !first.recorded)
        #expect(!Files.exists(f.context.state.path))
        let saved = try await engine.growth(in: f.url("Projects"), context: f.context, record: true)
        #expect(saved.recorded)
        try f.write("Projects/Second/data", Data(repeating: 17, count: 131_072))
        let compared = try await engine.growth(in: f.url("Projects"), context: f.context)
        #expect(compared.previousDate != nil && !compared.recorded)
        #expect((compared.privateChange ?? 0) >= 131_072)
        #expect(compared.entries.first?.path == f.url("Projects/Second").path)
        let metadata = try Data(contentsOf: f.context.state.appendingPathComponent("growth.json"))
        #expect(metadata.count < 100_000)
        #expect(String(data: metadata, encoding: .utf8)?.contains(canary) == false)
    }

    @Test func oversizedPartialInventoryCannotReplaceBaseline() async throws {
        let f = try Fixture(), engine = BleachEngine()
        try f.write("Projects/first")
        _ = try await engine.growth(in: f.url("Projects"), context: f.context, record: true)
        let file = f.context.state.appendingPathComponent("growth.json"), before = try Data(contentsOf: file)
        for index in 0..<257 { try f.write("Projects/item-\(index)", Data([1])) }
        let partial = try await engine.growth(in: f.url("Projects"), context: f.context, record: true)
        #expect(!partial.recorded && !partial.issues.isEmpty && partial.previousDate == nil)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func baselinesAreCappedAndMalformedHistoryIsRetained() async throws {
        let f = try Fixture(), engine = BleachEngine()
        for index in 0..<10 {
            try f.write("Folder-\(index)/file")
            _ = try await engine.growth(in: f.url("Folder-\(index)"), context: f.context, record: true)
        }
        let file = f.context.state.appendingPathComponent("growth.json")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((json["samples"] as? [Any])?.count == 8)
        let invalid = Data("{\"schema\":99,\"samples\":[]}".utf8)
        try invalid.write(to: file)
        await reject("Invalid growth") { _ = try await engine.growth(in: f.url("Folder-0"), context: f.context, record: true) }
        #expect(try Data(contentsOf: file) == invalid)
    }
}
