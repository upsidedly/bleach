import BleachFS
import Darwin
import Foundation

public struct SharedReplacement: Codable, Sendable {
    public var stamp: FileStamp
    public var sha256: String
}

public struct StagedClone: Codable, Sendable {
    public var slot: String
    public var stamp: FileStamp?
}

public struct SharingReceipt: Codable, Sendable {
    public var batch: RecoveryBatch
    public var pathsPreserved: Int
    public var privateBytesBefore: Int64
    public var privateBytesAfter: Int64?
}

public enum StorageSharing {
    static func eligiblePaths(in plan: CleanupPlan) -> [String] {
        plan.candidates.filter { candidate in
            candidate.privateBytes > 0 && candidate.snapshot.root.flags == 0 && candidate.snapshot.root.links == 1 && isGeneratedCapture(candidate.path) && candidate.duplicateProof.map { isGeneratedCapture($0.keeperPath) && $0.keeperStamp.flags == 0 && $0.keeperStamp.links == 1 } == true
        }.map(\.path)
    }
    /// Restrict the first implementation to recognizable Playwright captures.
    /// Ordinary duplicate documents, source and application data are excluded.
    public static func isGeneratedCapture(_ path: String) -> Bool {
        let file = URL(fileURLWithPath: path)
        guard ["zip", "png", "webm"].contains(file.pathExtension.lowercased()),
              file.pathComponents.contains(where: { ["test-results", "playwright-report", "artifacts"].contains($0) }) || path.contains("/report/data/") else { return false }
        var parent = file.deletingLastPathComponent()
        for _ in 0..<12 {
            let manifest = parent.appendingPathComponent("package.json")
            if ProjectOutputs.regular(manifest), let data = try? Data(contentsOf: manifest),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let dependencies = (json["dependencies"] as? [String: Any] ?? [:]).merging(json["devDependencies"] as? [String: Any] ?? [:]) { first, _ in first }
                if dependencies["@playwright/test"] != nil || dependencies["playwright"] != nil { return true }
            }
            parent.deleteLastPathComponent()
        }
        return false
    }
}

extension BleachEngine {
    /// The original is moved by the existing write-ahead Recovery protocol.
    /// Only verified clones permit erasure of that exact, identity-checked batch.
    public func shareDuplicateStorage(_ plan: CleanupPlan, context: ScanContext) async throws -> SharingReceipt {
        guard plan.origin == "duplicates", !plan.candidates.isEmpty else { throw BleachError("Choose generated copies from a duplicate preview") }
        let policy = CleanupPolicy(context: context, preferences: try PreferencesStore(context: context).load())
        var before: Int64 = 0
        for candidate in plan.candidates {
            guard candidate.rule == .duplicate, let proof = candidate.duplicateProof,
                  candidate.privateBytes > 0,
                  StorageSharing.isGeneratedCapture(candidate.path), StorageSharing.isGeneratedCapture(proof.keeperPath),
                  candidate.snapshot.root.links == 1, candidate.snapshot.root.flags == 0,
                  proof.keeperStamp.links == 1, proof.keeperStamp.flags == 0,
                  candidate.snapshot.root.device == proof.keeperStamp.device,
                  policy.exclusionReason(proof.keeperPath) == nil,
                  try URL(fileURLWithPath: candidate.path).resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning == true else {
                throw BleachError("Only local, unlinked Playwright captures on a cloning-capable volume can share storage")
            }
            try policy.validate(candidate)
            let current = try FileWalker.completeSnapshot(candidate.path)
            guard current.matchesFileState(candidate.snapshot), current.storageUsage.privateBytes > 0 else { throw BleachError("Capture changed or has no private allocation to share; scan again") }
            before += current.storageUsage.privateBytes
            try ProjectReview.requireIdle(candidate.path, includeWorkingDirectory: false)
            try ProjectReview.requireIdle(proof.keeperPath, includeWorkingDirectory: false)
        }
        var batch = try await apply(plan, context: context)
        if batch.problemCount == 0 {
            batch = try createSharedCopies(batch, context: context)
            if batch.problemCount == 0 { batch = try erase(batch: batch.id, context: context) }
        }
        let replaced = batch.items.filter { $0.sharedReplacement != nil }
        let measured = replaced.compactMap { try? FileWalker.completeSnapshot($0.candidate.path).storageUsage.privateBytes }
        let complete = batch.items.allSatisfy { $0.state == .erased } && replaced.count == plan.candidates.count
        let after = complete && measured.count == replaced.count ? measured.reduce(0, +) : nil
        return SharingReceipt(batch: batch, pathsPreserved: replaced.count, privateBytesBefore: before, privateBytesAfter: after)
    }

    func createSharedCopies(_ input: RecoveryBatch, context: ScanContext) throws -> RecoveryBatch {
        let store = RecoveryStore(context: context)
        let lock = try store.lock()
        defer { bl_close(lock) }
        var batch = try store.load(input.id)
        for index in batch.items.indices where batch.items[index].state == .moved {
            try Task.checkCancellation()
            let item = batch.items[index], candidate = item.candidate
            do {
                guard let proof = candidate.duplicateProof else { throw BleachError("Missing duplicate proof") }
                let held = store.itemURL(batch: batch.id, slot: item.slot)
                let original = try FileWalker.completeSnapshot(held.path)
                guard original.root.identity == candidate.snapshot.root.identity, original.fingerprint == candidate.snapshot.fingerprint,
                      try Files.stamp(proof.keeperPath) == proof.keeperStamp,
                      try Files.sha256(held.path, expected: original.root) == proof.sha256,
                      try Files.sha256(proof.keeperPath, expected: proof.keeperStamp) == proof.sha256 else { throw BleachError("Capture or retained copy changed; original remains in Recovery") }
                try ProjectReview.requireIdle(proof.keeperPath, includeWorkingDirectory: false)
                let cloneSlot = UUID().uuidString.lowercased()
                let staged = store.itemURL(batch: batch.id, slot: cloneSlot)
                batch.items[index].stagedClone = StagedClone(slot: cloneSlot, stamp: nil)
                try store.save(batch)
                var keeper = proof.keeperStamp.nativeMetadata, metadata = original.root.nativeMetadata
                try Files.require(bl_clone_copy(proof.keeperPath, &keeper, held.path, &metadata, staged.path), staged.path)
                let prepared = try Files.stamp(staged.path)
                batch.items[index].stagedClone?.stamp = prepared
                try store.save(batch)
                guard prepared.kind == 1, prepared.owner == original.root.owner, prepared.mode == original.root.mode,
                      prepared.size == original.root.size, prepared.modifiedSeconds == original.root.modifiedSeconds,
                      prepared.modifiedNanoseconds == original.root.modifiedNanoseconds,
                      try Files.sha256(staged.path, expected: prepared) == proof.sha256 else { throw BleachError("Replacement verification failed; original remains in Recovery") }
                try Files.require(bl_move_exclusive(staged.path, candidate.path, prepared.device, prepared.inode), candidate.path)
                let replacement = try Files.stamp(candidate.path)
                guard replacement.identity == prepared.identity, try Files.sha256(candidate.path, expected: replacement) == proof.sha256 else { throw BleachError("Replacement changed after creation; original remains in Recovery") }
                batch.items[index].sharedReplacement = SharedReplacement(stamp: replacement, sha256: proof.sha256)
                batch.items[index].stagedClone = nil
            } catch is CancellationError { throw CancellationError() }
            catch {
                batch.items[index].state = .conflict
                batch.items[index].message = "\(error.localizedDescription). Original retained in Recovery; an existing path is never overwritten."
            }
            try store.save(batch)
        }
        return batch
    }
}
