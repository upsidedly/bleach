import BleachFS
import CryptoKit
import Darwin
import Foundation

public struct ProjectEvidence: Codable, Sendable, Equatable {
    public var projectPath: String
    public var newestSourceActivity: Date
    public var minimumDays: Int
    public var reinstallCommand: String
    public var recipeFingerprint: String
}

enum ProjectReview {
    static let generated: Set<String> = ["node_modules", ".build", ".next", "target", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".turbo", ".cache", "coverage", "playwright-report", "test-results"]

    static func requireIdle(_ path: String, includeWorkingDirectory: Bool = true) throws {
        let result = bl_path_in_use(path, includeWorkingDirectory ? 1 : 0)
        if result > 0 { throw BleachError("A running process references this project or its files; retained: \(path)") }
        if result < 0 { throw BleachError("Process references could not be fully inspected; retained: \(path)") }
    }

    static func recipe(_ environment: URL) throws -> (command: String, fingerprint: String) {
        let parent = environment.deletingLastPathComponent()
        func read(_ name: String) throws -> Data { try Files.readPrivateFile(parent.appendingPathComponent(name), limit: 5_000_000) }
        let names: [String], command: String
        if environment.lastPathComponent == "node_modules" {
            let data = try read("package.json")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BleachError("Invalid package manifest") }
            let available = ["npm": "package-lock.json", "pnpm": "pnpm-lock.yaml", "bun": "bun.lock", "yarn": "yarn.lock"].filter { Files.exists(parent.appendingPathComponent($0.value).path) }
            let declared = (json["packageManager"] as? String)?.split(separator: "@").first.map(String.init)
            if let declared, available[declared] == nil { throw BleachError("Declared package manager has no matching lockfile; dependencies retained") }
            let manager = declared.flatMap { available[$0] == nil ? nil : $0 } ?? (available.count == 1 ? available.keys.first : nil)
            guard let manager, let lock = available[manager] else { throw BleachError("A single supported lockfile or matching packageManager is required; dependencies retained") }
            names = ["package.json", lock]
            if manager == "yarn" {
                command = String(decoding: try read(lock), as: UTF8.self).contains("# yarn lockfile v1") ? "yarn install --frozen-lockfile" : "yarn install --immutable"
            } else { command = ["npm": "npm ci", "pnpm": "pnpm install --frozen-lockfile", "bun": "bun install --frozen-lockfile"][manager] ?? "" }
        } else {
            guard [".venv", "venv"].contains(environment.lastPathComponent),
                  (try? Files.stamp(environment.appendingPathComponent("pyvenv.cfg").path).kind) == 1 else { throw BleachError("Not a recognized Python environment") }
            guard Files.exists(parent.appendingPathComponent("uv.lock").path) else { throw BleachError("Python environment has no supported locked reinstall recipe; retained") }
            names = ["pyproject.toml", "uv.lock"]; command = "uv sync --locked"
        }
        var hash = SHA256()
        for name in names { hash.update(data: Data(name.utf8)); hash.update(data: try read(name)) }
        return (command, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func owner(of project: URL, home: URL) throws -> URL {
        var cursor = project
        while Files.pathIsWithin(cursor.path, home.path), cursor != home {
            let git = cursor.appendingPathComponent(".git")
            if let stamp = try Files.optionalStamp(git.path) {
                guard stamp.kind == 2 else { throw BleachError("Linked Git worktree requires manual activity review; retained") }
                return cursor
            }
            cursor.deleteLastPathComponent()
        }
        return project
    }

    static func newestActivity(in project: URL) throws -> Date {
        let deadline = Date().addingTimeInterval(8)
        var visited = 0
        let walk = try FileWalker.walk(project.path, collect: true, fingerprint: false, deadline: deadline) { path, stamp in
            visited += 1
            let url = URL(fileURLWithPath: path)
            return visited > 100_000 || url.lastPathComponent == ".git" ||
                (stamp.kind == 2 && (generated.contains(url.lastPathComponent) || ProjectOutputs.matches(url)))
        }
        guard visited <= 100_000, walk.issues.isEmpty, !walk.snapshot.hasCloudPlaceholder,
              !walk.snapshot.hasForeignOwner, !walk.snapshot.hasOtherVolume else { throw BleachError("Incomplete source activity scan; project retained") }
        var newest = Date.distantPast
        for (path, stamp) in walk.records where stamp.kind == 1 {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let changed = Date(timeIntervalSince1970: Double(stamp.changedSeconds) + Double(stamp.changedNanoseconds) / 1e9)
            newest = max(newest, stamp.modified, changed, attributes[.creationDate] as? Date ?? stamp.modified)
        }
        for name in ["HEAD", "index", "logs/HEAD", "packed-refs"] {
            let path = project.appendingPathComponent(".git/" + name).path
            if let stamp = try Files.optionalStamp(path) { newest = max(newest, stamp.modified) }
        }
        guard newest != .distantPast else { throw BleachError("No source activity evidence; project retained") }
        return newest
    }

    static func evidence(for environment: URL, policy: CleanupPolicy) throws -> ProjectEvidence {
        let recipe = try recipe(environment)
        let project = try owner(of: environment.deletingLastPathComponent(), home: policy.context.home)
        guard !policy.protectedUserPath(project.path), policy.exclusionReason(project.path) == nil else { throw BleachError("Protected project retained") }
        let newest = try newestActivity(in: project)
        let days = max(30, policy.preferences.minimumAgeDays)
        guard policy.context.now.timeIntervalSince(newest) >= Double(days) * 86_400 else { throw BleachError("Project source or Git activity is within the last \(days) days; dependencies retained") }
        try requireIdle(project.path)
        return ProjectEvidence(projectPath: project.path, newestSourceActivity: newest, minimumDays: days,
            reinstallCommand: recipe.command, recipeFingerprint: recipe.fingerprint)
    }

    static func validate(_ candidate: CleanupCandidate, policy: CleanupPolicy) throws {
        guard let saved = candidate.projectEvidence else { throw BleachError("Missing project activity and reinstall evidence") }
        let current = try evidence(for: URL(fileURLWithPath: candidate.path), policy: policy)
        guard current.projectPath == saved.projectPath, current.recipeFingerprint == saved.recipeFingerprint,
              current.newestSourceActivity <= saved.newestSourceActivity.addingTimeInterval(1) else { throw BleachError("Project or reinstall recipe changed since preview; scan again") }
    }
}

extension BleachEngine {
    public func inactiveProjects(in folder: URL? = nil, context: ScanContext) throws -> CleanupPlan {
        let start = Date(), deadline = Date().addingTimeInterval(45)
        let preferences = try PreferencesStore(context: context).load()
        let policy = CleanupPolicy(context: context, preferences: preferences)
        let proposed = folder.map { [$0] } ?? (["Desktop/Projects", "Projects", "Developer", "Code", "Documents/code"].map(context.homeURL) + preferences.projectRoots.map { URL(fileURLWithPath: $0) })
        var roots: [URL] = [], issues: [ScanIssue] = [], candidates: [CleanupCandidate] = []
        for root in proposed.sorted(by: { $0.path.count < $1.path.count }) where Files.exists(root.path) {
            guard Files.pathIsWithin(root.path, context.home.path), !policy.protectedUserPath(root.path), policy.exclusionReason(root.path) == nil,
                  Files.canonicalURL(root).path == root.path else { issues.append(ScanIssue(path: root.path, message: "Protected or redirected project root retained")); continue }
            if !roots.contains(where: { Files.pathIsWithin(root.path, $0.path) }) { roots.append(root) }
        }
        var stack = roots.map { ($0, 0) }, directories = 0, entries = 0
        let device = try Files.stamp(context.home.path).device
        while let (directory, depth) = stack.popLast() {
            try Task.checkCancellation()
            guard Date() < deadline, directories < 20_000 else { issues.append(ScanIssue(path: directory.path, message: "Inactive-project scan limit reached; remaining projects retained")); break }
            directories += 1
            do {
                for child in try Files.children(directory.path) {
                    guard let stamp = try? Files.stamp(child.path), stamp.kind == 2, !stamp.dataless, stamp.device == device, stamp.owner == getuid(), policy.exclusionReason(child.path) == nil else { continue }
                    let name = child.lastPathComponent
                    if ["node_modules", ".venv", "venv"].contains(name) {
                        do {
                            let evidence = try ProjectReview.evidence(for: child, policy: policy)
                            let snapshot = try FileWalker.completeSnapshot(child.path, deadline: deadline)
                            guard snapshot.allocatedBytes > 0 else { continue }
                            candidates.append(CleanupCandidate(path: child.path, title: "\(directory.lastPathComponent) / \(name)", category: .builds, rule: .inactiveDependencies,
                                reason: "No observed source or Git activity for \(Int(context.now.timeIntervalSince(evidence.newestSourceActivity) / 86_400)) days; no visible live process references. Reinstall: \(evidence.reinstallCommand).",
                                consequence: "Source, Git, manifests and locks stay. Reinstall before returning to the project; local edits inside dependencies will be lost.", recommendation: .review, snapshot: snapshot, projectEvidence: evidence))
                            entries += snapshot.entryCount
                        } catch is CancellationError { throw CancellationError() }
                        catch { if issues.count < 200 { issues.append(ScanIssue(path: child.path, message: error.localizedDescription)) } }
                        continue
                    }
                    if depth < 12, !name.hasPrefix("."), !ProjectReview.generated.contains(name), !["build", "dist", "vendor", "Pods"].contains(name), !policy.protectedUserPath(child.path) { stack.append((child, depth + 1)) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { if issues.count < 200 { issues.append(ScanIssue(path: directory.path, message: error.localizedDescription)) } }
        }
        candidates.sort { $0.privateBytes == $1.privateBytes ? $0.path < $1.path : $0.privateBytes > $1.privateBytes }
        return CleanupPlan(createdAt: context.now, home: context.home.path, origin: "inactive", candidates: candidates, issues: issues, duration: Date().timeIntervalSince(start), scannedEntries: entries)
    }
}
