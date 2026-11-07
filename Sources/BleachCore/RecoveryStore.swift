import BleachFS
import Darwin
import Foundation

struct PreferencesStore {
    let context: ScanContext
    var url: URL { context.state.appendingPathComponent("preferences.json") }

    func load() throws -> Preferences {
        guard try Files.optionalStamp(url.path) != nil else { return Preferences() }
        do {
            let data = try Files.readPrivateFile(url, limit: 1_000_000)
            var preferences = try JSONCoding.decoder().decode(Preferences.self, from: data)
            guard preferences.schemaVersion == 1, (1...3650).contains(preferences.minimumAgeDays), preferences.automaticCleanup?.valid != false,
                  preferences.excludedPaths.allSatisfy({ $0.hasPrefix("/") && Files.lexicalPath($0) == $0 }),
                  preferences.projectRoots.allSatisfy({ Files.pathIsWithin($0, context.home.path) }) else {
                throw BleachError("Invalid preferences; cleanup stopped")
            }
            preferences.minimumAgeDays = max(30, preferences.minimumAgeDays)
            return preferences
        } catch { throw BleachError("Cannot read Bleach exclusions; cleanup stopped. \(error.localizedDescription)") }
    }

    func save(_ preferences: Preferences) throws {
        let store = RecoveryStore(context: context)
        try store.ensureStorage()
        let lock = try store.lock()
        defer { bl_close(lock) }
        try Files.atomicWrite(try JSONCoding.encoder().encode(preferences), directory: context.state, name: "preferences.json")
    }
}

struct RecoveryStore {
    let context: ScanContext
    var recovery: URL { context.state.appendingPathComponent("Recovery") }

    func ensureStorage() throws {
        guard Files.pathIsWithin(context.state.path, context.home.path), context.state.path != context.home.path else {
            throw BleachError("Bleach's state folder must be inside this home")
        }
        try Files.makeDirectory(context.state)
        let stamp = try Files.stamp(context.state.path)
        guard stamp.owner == getuid(), stamp.kind == 2, stamp.mode & 0o077 == 0 else {
            throw BleachError("Bleach's state folder must be a private, user-owned directory (mode 700)")
        }
        try Files.makeDirectory(recovery)
        let recoveryStamp = try Files.stamp(recovery.path)
        guard recoveryStamp.owner == getuid(), recoveryStamp.mode & 0o077 == 0 else {
            throw BleachError("Recovery folder permissions must be private (mode 700)")
        }
    }

    func lock() throws -> Int32 {
        let fd = bl_acquire_lock(context.state.appendingPathComponent("operation.lock").path)
        guard fd >= 0 else {
            let code = bl_last_error()
            if code == EWOULDBLOCK { throw BleachError("Another Bleach operation is running. Wait for it to finish.") }
            throw Files.error(code, context.state.path)
        }
        return fd
    }

    func directory(_ id: UUID) -> URL { recovery.appendingPathComponent(id.uuidString.lowercased()) }
    func itemURL(batch: UUID, slot: String) -> URL { directory(batch).appendingPathComponent("items").appendingPathComponent(slot) }

    func create(_ batch: RecoveryBatch) throws {
        let path = directory(batch.id)
        guard !Files.exists(path.path) else { throw BleachError("Recovery batch already exists") }
        try Files.makeDirectory(path.appendingPathComponent("items"))
        try save(batch)
    }

    func save(_ batch: RecoveryBatch) throws {
        try Files.atomicWrite(try JSONCoding.encoder().encode(batch), directory: directory(batch.id), name: "batch.json")
    }

    func load(_ id: UUID) throws -> RecoveryBatch {
        let url = directory(id).appendingPathComponent("batch.json")
        let batch = try JSONCoding.decoder().decode(RecoveryBatch.self, from: Files.readPrivateFile(url))
        let slots = batch.items.flatMap { [$0.slot] + ($0.stagedClone.map { [$0.slot] } ?? []) }
        guard batch.id == id, batch.schemaVersion == 1, batch.home == context.home.path,
              batch.items.count <= 100_000,
              Set(batch.items.map(\.slot)).count == batch.items.count,
              Set(slots).count == slots.count, slots.allSatisfy({ UUID(uuidString: $0) != nil && !$0.contains("/") }),
              batch.items.allSatisfy({ UUID(uuidString: $0.slot) != nil && !$0.slot.contains("/") && $0.candidate.snapshot.root.inode > 0 && $0.candidate.allocatedBytes >= 0 }) else {
            throw BleachError("Invalid recovery manifest; no files were changed: \(url.path)")
        }
        return try reconcile(batch)
    }

    /// Observes the write-ahead states. Reading history does not rewrite data.
    func reconcile(_ input: RecoveryBatch) throws -> RecoveryBatch {
        var batch = input
        for index in batch.items.indices {
            let item = batch.items[index]
            guard [.prepared, .restoring, .erasing].contains(item.state) else { continue }
            let original = try Files.optionalStamp(item.candidate.path)
            let held = try Files.optionalStamp(itemURL(batch: batch.id, slot: item.slot).path)
            let expected = item.candidate.snapshot.root
            let heldMatches = held?.identity == expected.identity
            let originalMatches = original?.identity == expected.identity
            switch item.state {
            case .erasing:
                batch.items[index].state = held == nil ? .erased : heldMatches ? .eraseInterrupted : .conflict
                batch.items[index].message = held == nil ? "Permanent deletion completed before interruption." : "Deletion was interrupted. Inspect the remaining files before retrying."
            case .restoring:
                batch.items[index].state = originalMatches && held == nil ? .restored : heldMatches ? .moved : .conflict
                batch.items[index].message = originalMatches && held == nil ? nil : "Restore was interrupted; remaining files are retained."
            case .prepared:
                batch.items[index].state = heldMatches ? .moved : originalMatches && held == nil ? .failed : .conflict
                batch.items[index].message = heldMatches ? "Recovered a move completed before interruption." : originalMatches && held == nil ? "Not moved before interruption." : "Interrupted operation needs review; no automatic overwrite."
            default: break
            }
        }
        return batch
    }

    func history() throws -> [RecoveryBatch] {
        guard try Files.optionalStamp(recovery.path) != nil else { return [] }
        return try Files.children(recovery.path).compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            return try load(id)
        }.sorted { $0.createdAt > $1.createdAt }
    }
}

extension BleachEngine {
    public func preferences(context: ScanContext) throws -> Preferences { try PreferencesStore(context: context).load() }

    public func updatePreferences(_ preferences: Preferences, context: ScanContext) throws {
        guard geteuid() != 0 else { throw BleachError("Run Bleach as your normal user, without sudo.") }
        guard (30...3650).contains(preferences.minimumAgeDays), preferences.schemaVersion == 1, preferences.automaticCleanup?.valid != false,
              preferences.excludedPaths.allSatisfy({ $0.hasPrefix("/") && Files.lexicalPath($0) == $0 }),
              preferences.projectRoots.allSatisfy({ Files.pathIsWithin($0, context.home.path) }) else {
            throw BleachError("Invalid preferences")
        }
        try PreferencesStore(context: context).save(preferences)
    }

    public func history(context: ScanContext) throws -> [RecoveryBatch] { try RecoveryStore(context: context).history() }

    public func apply(_ plan: CleanupPlan, context: ScanContext) async throws -> RecoveryBatch {
        guard geteuid() != 0 else { throw BleachError("Run Bleach as your normal user, without sudo.") }
        guard plan.schemaVersion == BleachVersion.planSchema, plan.home == context.home.path,
              ["scan", "duplicates", "uninstall", "discover", "inactive"].contains(plan.origin), !plan.candidates.isEmpty, plan.candidates.count <= 10_000 else {
            throw BleachError("Invalid or empty cleanup plan")
        }
        let age = context.now.timeIntervalSince(plan.createdAt)
        guard age >= -300, age <= 86_400 else { throw BleachError("This plan has expired. Scan again before cleaning.") }
        let sorted = plan.candidates.sorted { $0.path < $1.path }
        for (index, candidate) in sorted.enumerated() {
            for earlier in sorted.prefix(index) where Files.pathIsWithin(candidate.path, earlier.path) {
                throw BleachError("Overlapping or repeated targets in plan: \(earlier.path) and \(candidate.path)")
            }
        }
        let store = RecoveryStore(context: context)
        try store.ensureStorage()
        let lock = try store.lock()
        defer { bl_close(lock) }
        let preferences = try PreferencesStore(context: context).load()
        let policy = CleanupPolicy(context: context, preferences: preferences)
        let vaultDevice = try Files.stamp(store.recovery.path).device
        // Validate the complete selection before moving its first item.
        for candidate in plan.candidates {
            try Task.checkCancellation()
            try policy.validate(candidate)
            let current = try FileWalker.completeSnapshot(candidate.path)
            guard current.matchesFileState(candidate.snapshot) else { throw BleachError("Changed since preview; scan again: \(candidate.path)") }
            guard current.root.device == vaultDevice else { throw BleachError("Recovery must be on the same volume: \(candidate.path)") }
            if candidate.rule == .duplicate {
                try validateDuplicate(candidate, selected: Set(plan.candidates.map(\.path)), policy: policy)
            }
            if candidate.rule == .expandedArchive {
                try validateArchive(candidate, selected: plan.candidates, policy: policy)
            }
            if candidate.installerProof != nil {
                try validateInstaller(candidate, selected: plan.candidates, policy: policy)
            }
        }
        try validateUninstallSelection(plan, context: context)
        let available = SystemReader.disk(at: context.home).available
        var batch = RecoveryBatch(id: UUID(), planID: plan.id, createdAt: context.now, home: context.home.path,
            items: plan.candidates.map { RecoveryItem(id: UUID(), candidate: $0, slot: UUID().uuidString.lowercased(), state: .prepared) },
            finished: false, availableBefore: available, availableAfter: available)
        try store.create(batch)
        for index in batch.items.indices {
            if Task.isCancelled {
                for pending in batch.items.indices where batch.items[pending].state == .prepared {
                    batch.items[pending].state = .failed; batch.items[pending].message = "Cancelled before this item moved."
                }
                try store.save(batch)
                return batch
            }
            let candidate = batch.items[index].candidate
            let destination = store.itemURL(batch: batch.id, slot: batch.items[index].slot)
            do {
                // Recheck after preflight and immediately before the move.
                let currentPreferences = try PreferencesStore(context: context).load()
                let freshOwners = context.refreshRunningOwners ? await RunningApplications.snapshot() : []
                let currentContext = ScanContext(home: context.home, state: context.state, now: context.now,
                                                runningOwners: context.runningOwners + freshOwners, compilerCache: context.compilerCache,
                                                cacheEnvironment: context.cacheEnvironment, refreshRunningOwners: context.refreshRunningOwners)
                let currentPolicy = CleanupPolicy(context: currentContext, preferences: currentPreferences)
                try currentPolicy.validate(candidate)
                guard try FileWalker.completeSnapshot(candidate.path).matchesFileState(candidate.snapshot) else {
                    throw BleachError("Changed since preview; retained in place.")
                }
                if candidate.rule == .duplicate {
                    try validateDuplicate(candidate, selected: Set(plan.candidates.map(\.path)), policy: currentPolicy)
                }
                if candidate.rule == .expandedArchive {
                    try validateArchive(candidate, selected: plan.candidates, policy: currentPolicy)
                }
                if candidate.installerProof != nil {
                    try validateInstaller(candidate, selected: plan.candidates, policy: currentPolicy)
                }
                if candidate.rule == .appRelatedData {
                    guard batch.items.contains(where: { $0.candidate.path == candidate.applicationPath && $0.state == .moved }) else {
                        throw BleachError("The app was not moved; related data is kept in place.")
                    }
                    try validateUninstallSelection(plan, context: currentContext)
                }
                let stamp = candidate.snapshot.root
                try Files.require(bl_move_exclusive(candidate.path, destination.path, stamp.device, stamp.inode), candidate.path)
                let moved = try FileWalker.completeSnapshot(destination.path)
                if moved.fingerprint != candidate.snapshot.fingerprint {
                    let restore = bl_move_exclusive(destination.path, candidate.path, stamp.device, stamp.inode)
                    batch.items[index].state = restore == 0 ? .restored : .conflict
                    batch.items[index].message = "Changed during the move; \(restore == 0 ? "returned to its original location" : "retained in recovery for review")."
                } else { batch.items[index].state = .moved }
            } catch {
                let held = try Files.optionalStamp(destination.path)
                batch.items[index].state = held?.identity == candidate.snapshot.root.identity ? .moved : held == nil ? .failed : .conflict
                batch.items[index].message = error.localizedDescription
            }
            // A durable outcome after each move, never just a final log line.
            try store.save(batch)
        }
        batch.finished = true
        batch.availableAfter = SystemReader.disk(at: context.home).available
        try store.save(batch)
        return batch
    }

    private func validateInstaller(_ candidate: CleanupCandidate, selected: [CleanupCandidate], policy: CleanupPolicy) throws {
        guard let proof = candidate.installerProof,
              !selected.contains(where: { Files.pathIsWithin(proof.installedPath, $0.path) || Files.pathIsWithin($0.path, proof.installedPath) }),
              policy.exclusionReason(proof.installedPath) == nil else {
            throw BleachError("The installed app is excluded or also selected; installer retained")
        }
        let apps = try installedApps(context: policy.context).filter { $0.path == proof.installedPath }
        let url = URL(fileURLWithPath: candidate.path)
        let current: InstallerProof?
        if candidate.rule == .archivedInstaller {
            current = try InstallerMatches.zip(url, apps: apps, context: policy.context)
        } else if candidate.rule == .installer && url.pathExtension.lowercased() == "dmg" {
            current = try InstallerMatches.diskImage(url, mounted: InstallerMatches.mountedImages(), apps: apps, context: policy.context)
        } else { throw BleachError("Invalid installer evidence") }
        guard current == proof else { throw BleachError("Installed app or installer identity changed; scan again") }
    }

    private func validateArchive(_ candidate: CleanupCandidate, selected: [CleanupCandidate], policy: CleanupPolicy) throws {
        guard let proof = candidate.archiveProof, proof.fileCount > 0, proof.contentFingerprint.count == 64,
              !selected.contains(where: { Files.pathIsWithin($0.path, proof.expandedPath) || Files.pathIsWithin(proof.expandedPath, $0.path) }),
              policy.exclusionReason(proof.expandedPath) == nil else {
            throw BleachError("The expanded archive copy is excluded or also selected; files retained")
        }
        guard try ArchiveTwins.prove(URL(fileURLWithPath: candidate.path), policy: policy) == proof else {
            throw BleachError("Expanded archive evidence changed; scan again")
        }
    }

    private func validateDuplicate(_ candidate: CleanupCandidate, selected: Set<String>, policy: CleanupPolicy) throws {
        guard let proof = candidate.duplicateProof, proof.sha256.count == 64,
              !selected.contains(proof.keeperPath), !policy.protectedUserPath(proof.keeperPath),
              Files.pathIsWithin(proof.keeperPath, policy.context.home.path),
              proof.keeperPath != candidate.path,
              proof.keeperStamp.identity != candidate.snapshot.root.identity,
              candidate.snapshot.root.links == 1, proof.keeperStamp.links == 1,
              try Files.stamp(proof.keeperPath) == proof.keeperStamp else {
            throw BleachError("The retained duplicate copy changed or is also selected; scan again.")
        }
        guard try Files.sha256(proof.keeperPath, expected: proof.keeperStamp) == proof.sha256,
              try Files.sha256(candidate.path, expected: candidate.snapshot.root) == proof.sha256 else {
            throw BleachError("Duplicate contents changed; files were retained.")
        }
    }

    private func validateUninstallSelection(_ plan: CleanupPlan, context: ScanContext) throws {
        let data = plan.candidates.filter { $0.rule == .appRelatedData }
        guard !data.isEmpty else { return }
        let apps = try installedApps(context: context)
        for item in data {
            guard let original = item.applicationPath,
                  plan.candidates.contains(where: { $0.rule == .application && $0.path == original && $0.ownerBundleID == item.ownerBundleID }),
                  !apps.contains(where: { $0.bundleID == item.ownerBundleID && $0.path != original }) else {
                throw BleachError("App data is shared with another install or its app is not selected; retain it.")
            }
        }
    }

    public func restore(batch id: UUID, context: ScanContext) throws -> RecoveryBatch {
        guard geteuid() != 0 else { throw BleachError("Run Bleach without sudo.") }
        let store = RecoveryStore(context: context)
        try store.ensureStorage()
        let lock = try store.lock()
        defer { bl_close(lock) }
        var batch = try store.load(id)
        let policy = CleanupPolicy(context: context, preferences: try PreferencesStore(context: context).load())
        for index in batch.items.indices.reversed() where [.moved, .conflict].contains(batch.items[index].state) {
            let item = batch.items[index]
            let source = store.itemURL(batch: id, slot: item.slot)
            do {
                guard item.candidate.path.hasPrefix("/"), Files.lexicalPath(item.candidate.path) == item.candidate.path,
                      policy.ruleMatches(item.candidate, restoring: true),
                      Files.pathIsWithin(item.candidate.path, context.home.path) || item.candidate.rule == .application || (item.candidate.rule == .clangModuleCache && item.candidate.path == context.compilerCache?.path),
                      try Files.stamp(source.path).identity == item.candidate.snapshot.root.identity else {
                    throw BleachError("Recovery identity or original path is invalid; inspect this item.")
                }
                guard try Files.optionalStamp(item.candidate.path) == nil else {
                    throw BleachError("Original path already exists. Kept in recovery; reveal it to choose a different destination.")
                }
                let parent = URL(fileURLWithPath: item.candidate.path).deletingLastPathComponent()
                try Files.makeDirectory(parent)
                batch.items[index].state = .restoring
                try store.save(batch)
                try discardStagedClone(item, batch: batch.id, store: store)
                batch.items[index].stagedClone = nil
                try store.save(batch)
                let stamp = item.candidate.snapshot.root
                try Files.require(bl_move_exclusive(source.path, item.candidate.path, stamp.device, stamp.inode), item.candidate.path)
                batch.items[index].state = .restored; batch.items[index].message = nil
            } catch {
                batch.items[index].state = .conflict; batch.items[index].message = error.localizedDescription
            }
            try store.save(batch)
        }
        return batch
    }

    public func erase(batch id: UUID, context: ScanContext) throws -> RecoveryBatch {
        guard geteuid() != 0 else { throw BleachError("Run Bleach without sudo.") }
        let store = RecoveryStore(context: context)
        try store.ensureStorage()
        let lock = try store.lock()
        defer { bl_close(lock) }
        var batch = try store.load(id)
        batch.availableBefore = SystemReader.disk(at: context.home).available
        for index in batch.items.indices where [.moved, .conflict, .eraseInterrupted].contains(batch.items[index].state) {
            try Task.checkCancellation()
            let item = batch.items[index]
            let path = store.itemURL(batch: id, slot: item.slot).path
            do {
                if let replacement = item.sharedReplacement {
                    guard try Files.stamp(item.candidate.path) == replacement.stamp,
                          try Files.sha256(item.candidate.path, expected: replacement.stamp) == replacement.sha256 else {
                        throw BleachError("Storage-sharing replacement changed; original retained in Recovery")
                    }
                }
                let snapshot = try FileWalker.completeSnapshot(path)
                guard snapshot.root.identity == item.candidate.snapshot.root.identity,
                      item.state == .eraseInterrupted || snapshot.fingerprint == item.candidate.snapshot.fingerprint else {
                    throw BleachError("Recovery contents changed; retained for inspection.")
                }
                batch.items[index].state = .erasing
                try store.save(batch)
                try discardStagedClone(item, batch: id, store: store)
                batch.items[index].stagedClone = nil
                try store.save(batch)
                try Files.require(bl_erase(path, snapshot.root.device, snapshot.root.inode), path)
                batch.items[index].state = .erased; batch.items[index].message = nil
            } catch is CancellationError { throw CancellationError() }
            catch {
                batch.items[index].state = batch.items[index].state == .erasing ? .eraseInterrupted : item.state == .eraseInterrupted ? .eraseInterrupted : .conflict
                batch.items[index].message = error.localizedDescription
            }
            try store.save(batch)
        }
        batch.availableAfter = SystemReader.disk(at: context.home).available
        try store.save(batch)
        return batch
    }

    private func discardStagedClone(_ item: RecoveryItem, batch: UUID, store: RecoveryStore) throws {
        guard let staged = item.stagedClone else { return }
        let path = store.itemURL(batch: batch, slot: staged.slot).path
        guard let stamp = try Files.optionalStamp(path) else { return }
        guard stamp.kind == 1, stamp.owner == getuid(), stamp.links == 1,
              staged.stamp == nil || staged.stamp?.identity == stamp.identity,
              let proof = item.candidate.duplicateProof,
              try Files.sha256(path, expected: stamp) == proof.sha256 else {
            throw BleachError("Unverified staged clone retained in this Recovery batch")
        }
        try Files.require(bl_erase(path, stamp.device, stamp.inode), path)
    }
}
