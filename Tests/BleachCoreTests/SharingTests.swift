import BleachFS
import Darwin
import Foundation
import Testing
@testable import BleachCore

struct SharingTests {
    private func captures(_ f: Fixture) throws -> URL {
        try f.write("Projects/Web/package.json", Data("{\"devDependencies\":{\"@playwright/test\":\"1.56\"}}".utf8))
        let data = Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try f.write("Projects/Web/test-results/run/trace.zip", data)
        try f.write("Projects/Web/playwright-report/data/trace.zip", data)
        return f.url("Projects/Web")
    }

    @Test func sharingKeepsBothPathsMetadataAndIndependentWrites() async throws {
        let f = try Fixture(), engine = BleachEngine(), root = try captures(f)
        let target = f.url("Projects/Web/test-results/run/trace.zip")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        let attribute = Data("capture-metadata".utf8)
        #expect(attribute.withUnsafeBytes { setxattr(target.path, "org.bleach.fixture", $0.baseAddress, $0.count, 0, 0) } == 0)
        let original = try Data(contentsOf: target)
        let report = try await engine.duplicates(in: root, context: f.context)
        #expect(report.shareablePaths == [target.path])
        let receipt = try await engine.shareDuplicateStorage(report.plan, context: f.context)
        #expect(receipt.pathsPreserved == 1)
        #expect(receipt.batch.items.allSatisfy { $0.state == .erased })
        #expect(try Data(contentsOf: target) == original)
        #expect(try Files.stamp(target.path).mode & 0o777 == 0o640)
        var copied = [UInt8](repeating: 0, count: 64)
        let size = getxattr(target.path, "org.bleach.fixture", &copied, copied.count, 0, 0)
        #expect(size == attribute.count && Data(copied.prefix(max(0, size))) == attribute)
        #expect((receipt.privateBytesAfter ?? Int64.max) < receipt.privateBytesBefore)
        let keeper = try #require(report.plan.candidates.first?.duplicateProof?.keeperPath)
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data([1, 2, 3, 4])); try handle.close()
        #expect(try Data(contentsOf: URL(fileURLWithPath: keeper)) == original)
        #expect(try Data(contentsOf: target) != original)
    }

    @Test func changedKeepersAndOrdinaryDocumentsAreRejectedBeforeMoving() async throws {
        let f = try Fixture(), engine = BleachEngine(), root = try captures(f)
        let report = try await engine.duplicates(in: root, context: f.context)
        let keeper = try #require(report.plan.candidates.first?.duplicateProof?.keeperPath)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: keeper))
        await reject("changed") { _ = try await engine.shareDuplicateStorage(report.plan, context: f.context) }
        #expect(report.plan.candidates.allSatisfy { Files.exists($0.path) })
        try f.write("Documents/a.txt"); try f.write("Documents/b.txt")
        let documents = try await engine.duplicates(in: f.url("Documents"), context: f.context)
        await reject("Only local") { _ = try await engine.shareDuplicateStorage(documents.plan, context: f.context) }
        #expect(Files.exists(f.url("Documents/a.txt").path))
    }

    @Test func nativeCloneCannotOverwriteAnExistingPath() throws {
        let f = try Fixture()
        let keeper = try f.write("keeper"), held = try f.write("held"), destination = try f.write("destination", Data("keep".utf8))
        var source = try Files.stamp(keeper.path).nativeMetadata, metadata = try Files.stamp(held.path).nativeMetadata
        #expect(bl_clone_copy(keeper.path, &source, held.path, &metadata, destination.path) == EEXIST)
        #expect(try Data(contentsOf: destination) == Data("keep".utf8))
        #expect(Files.exists(held.path))
    }

    @Test func activeCaptureIsRetained() async throws {
        let f = try Fixture(), engine = BleachEngine(), root = try captures(f)
        let report = try await engine.duplicates(in: root, context: f.context)
        let target = try #require(report.plan.candidates.first?.path)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail"); process.arguments = ["-f", target]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        _ = try pipe.fileHandleForReading.read(upToCount: 1)
        await reject("running process") { _ = try await engine.shareDuplicateStorage(report.plan, context: f.context) }
        #expect(Files.exists(target))
    }

    @Test func occupiedReplacementPathKeepsTheRecoveryOriginal() async throws {
        let f = try Fixture(), engine = BleachEngine(), root = try captures(f)
        let report = try await engine.duplicates(in: root, context: f.context)
        let moved = try await engine.apply(report.plan, context: f.context)
        let target = try #require(report.plan.candidates.first?.path)
        let newContents = Data("new file at original path".utf8)
        try newContents.write(to: URL(fileURLWithPath: target))
        let result = try await engine.createSharedCopies(moved, context: f.context)
        #expect(result.items.first?.state == .conflict)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == newContents)
        #expect(result.recoverable.count == 1)
    }

    @Test func editedReplacementPreventsOriginalErasure() async throws {
        let f = try Fixture(), engine = BleachEngine(), root = try captures(f)
        let report = try await engine.duplicates(in: root, context: f.context)
        let moved = try await engine.apply(report.plan, context: f.context)
        let shared = try await engine.createSharedCopies(moved, context: f.context)
        #expect(shared.items.first?.sharedReplacement != nil)
        let target = try #require(report.plan.candidates.first?.path)
        try Data("later edit".utf8).write(to: URL(fileURLWithPath: target))
        let result = try await engine.erase(batch: moved.id, context: f.context)
        #expect(result.items.first?.state == .conflict)
        #expect(result.items.first?.message?.contains("replacement changed") == true)
        #expect(result.recoverable.count == 1)
    }
}
