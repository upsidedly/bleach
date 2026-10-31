import Foundation

struct CandidateSeed: Sendable {
    var path: String
    var title: String
    var category: CleanupCategory
    var rule: RuleID
    var reason: String
    var consequence: String
    var review: Bool = false
    var owner: String?
    var application: String?
}

public actor BleachEngine {
    public init() {}

    public func scan(context: ScanContext, additionalProjectRoots: [URL] = []) async throws -> CleanupPlan {
        let start = Date()
        let preferences = try PreferencesStore(context: context).load()
        let policy = CleanupPolicy(context: context, preferences: preferences)
        var seeds: [CandidateSeed] = []
        var issues: [ScanIssue] = []
        var appNames: [String: String] = [:]
        do {
            for app in try installedApps(context: context) where appNames[app.bundleID] == nil { appNames[app.bundleID] = app.name }
        } catch { issues.append(ScanIssue(path: "/Applications", message: "App names unavailable; folder names are shown. \(error.localizedDescription)")) }

        func children(_ relative: String, build: (URL) -> CandidateSeed?) throws {
            let url = context.homeURL(relative)
            guard Files.exists(url.path) else { return }
            do {
                for child in try Files.children(url.path) {
                    try Task.checkCancellation()
                    if let seed = build(child) { seeds.append(seed) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append(ScanIssue(path: url.path, message: error.localizedDescription)) }
        }

        try children("Library/Caches") { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), !policy.isProtectedCache(name) else { return nil }
            let browser = ["Google", "Firefox", "com.google.Chrome", "com.microsoft.Edge", "com.brave.Browser", "company.thebrowser.Browser", "company.thebrowser.dia"].contains(name)
            return CandidateSeed(path: url.path, title: appNames[name] ?? name, category: browser ? .browsers : .caches,
                rule: name == "pip" ? .pipCache : .userCache,
                reason: "Regenerable data in your user cache folder.",
                consequence: browser ? "Websites may load more slowly while the cache rebuilds. History, passwords and browser profiles stay in place." : "The app may need to download or rebuild this cache.",
                owner: name.contains(".") ? name : nil)
        }
        try children("Library/Logs") { url in
            guard !url.lastPathComponent.hasPrefix("."), url.lastPathComponent != "DiagnosticReports" else { return nil }
            return CandidateSeed(path: url.path, title: url.lastPathComponent, category: .logs, rule: .log,
                reason: "Diagnostic logs, separate from app documents and preferences.", consequence: "These logs will no longer be available for troubleshooting.")
        }
        try children("Library/Logs/DiagnosticReports") { url in
            guard ["ips", "crash", "diag"].contains(url.pathExtension.lowercased()) else { return nil }
            return CandidateSeed(path: url.path, title: url.lastPathComponent, category: .logs, rule: .log,
                reason: "A saved crash or diagnostic report.", consequence: "The report will no longer be available for troubleshooting.")
        }
        try children("Library/Developer/Xcode/DerivedData") { url in
            guard !url.lastPathComponent.hasPrefix(".") else { return nil }
            return CandidateSeed(path: url.path, title: url.lastPathComponent, category: .developer,
                rule: .xcodeDerivedData, reason: "Xcode build products and indexes; not project source.",
                consequence: "The next Xcode build and indexing pass will take longer.", owner: "com.apple.dt.Xcode")
        }
        let known: [(String, String, RuleID, String)] = [
            (".npm/_cacache", "npm package cache", .npmCache, "npm will download packages again when needed."),
            (".cache/pip", "pip download cache", .pipCache, "pip will download packages again when needed."),
            (".gradle/caches", "Gradle caches", .gradleCache, "Gradle will download dependencies and rebuild caches."),
            (".cache/org.swift.swiftpm", "Swift package cache", .swiftPMCache, "Swift Package Manager will fetch packages again.")
        ]
        for (relative, title, rule, consequence) in known where Files.exists(context.homeURL(relative).path) {
            seeds.append(CandidateSeed(path: context.homeURL(relative).path, title: title, category: .developer,
                rule: rule, reason: "Downloaded package data; installed project dependencies are separate.", consequence: consequence, review: true))
        }
        try children("Downloads") { url in
            guard ["dmg", "pkg", "xip"].contains(url.pathExtension.lowercased()) else { return nil }
            return CandidateSeed(path: url.path, title: url.lastPathComponent, category: .installers, rule: .installer,
                reason: "A downloaded installer. Bleach cannot tell whether you still need it.",
                consequence: "Keep installers you need for offline use or older software.", review: true)
        }

        let configured = preferences.projectRoots.map { URL(fileURLWithPath: $0) }
        for suppliedRoot in configured + additionalProjectRoots {
            let root = Files.canonicalURL(suppliedRoot)
            guard Files.pathIsWithin(root.path, context.home.path),
                  !policy.protectedUserPath(root.path) else {
                issues.append(ScanIssue(path: root.path, message: "Project roots must be local folders inside this home")); continue
            }
            do { try discoverProjects(root: root, depth: 0, context: context, seeds: &seeds) }
            catch is CancellationError { throw CancellationError() }
            catch { issues.append(ScanIssue(path: root.path, message: error.localizedDescription)) }
        }

        var seen: Set<String> = []
        seeds = seeds.filter { seen.insert($0.path).inserted }
        // A candidate containing an exclusion is retained as a whole; moving
        // its parent must never bypass a protected descendant.
        seeds = seeds.filter { seed in
            if let reason = policy.exclusionReason(seed.path) {
                issues.append(ScanIssue(path: seed.path, message: reason)); return false
            }
            return true
        }
        var candidates: [CleanupCandidate] = []
        var scannedEntries = 0
        for chunk in stride(from: 0, to: seeds.count, by: 4) {
            let end = min(chunk + 4, seeds.count)
            let groupResults = try await withThrowingTaskGroup(of: (CleanupCandidate?, ScanIssue?).self) { group in
                for seed in seeds[chunk..<end] {
                    group.addTask {
                        try Task.checkCancellation()
                        do {
                            let snapshot = try FileWalker.completeSnapshot(seed.path)
                            guard snapshot.allocatedBytes > 0 || snapshot.fileCount > 0 else { return (nil, nil) }
                            let days = max(30, preferences.minimumAgeDays)
                            let stale = context.now.timeIntervalSince(snapshot.newestModification) >= Double(days) * 86_400
                            var candidate = CleanupCandidate(path: seed.path, title: seed.title, category: seed.category,
                                rule: seed.rule, reason: seed.reason, consequence: seed.consequence,
                                recommendation: seed.rule.isRebuildableCache || (stale && !seed.review) ? .suggested : .review,
                                snapshot: snapshot, ownerBundleID: seed.owner, applicationPath: seed.application)
                            if !stale && !seed.rule.isRebuildableCache { candidate.reason += " Modified within the last \(days) days; review before choosing." }
                            if let busy = policy.busyReason(candidate) { candidate.recommendation = .blocked; candidate.blockedReason = busy }
                            guard policy.ruleMatches(candidate) else { return (nil, ScanIssue(path: seed.path, message: "Unrecognized cleanup boundary")) }
                            return (candidate, nil)
                        } catch is CancellationError { throw CancellationError() }
                        catch { return (nil, ScanIssue(path: seed.path, message: error.localizedDescription)) }
                    }
                }
                var results: [(CleanupCandidate?, ScanIssue?)] = []
                for try await result in group { results.append(result) }
                return results
            }
            for (candidate, issue) in groupResults {
                if let candidate { candidates.append(candidate); scannedEntries += candidate.snapshot.entryCount }
                if let issue { issues.append(issue) }
            }
        }
        candidates.sort {
            if $0.privateBytes != $1.privateBytes { return $0.privateBytes > $1.privateBytes }
            return $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes
        }
        return CleanupPlan(createdAt: context.now, home: context.home.path, origin: "scan", candidates: candidates,
            issues: issues.sorted { $0.path < $1.path }, duration: Date().timeIntervalSince(start), scannedEntries: scannedEntries)
    }

    private func discoverProjects(root: URL, depth: Int, context: ScanContext, seeds: inout [CandidateSeed]) throws {
        try Task.checkCancellation()
        guard depth <= 6, !Files.pathIsWithin(root.path, context.state.path),
              !root.pathComponents.contains(".git") else { return }
        let ignored: Set<String> = [".git", ".hg", ".svn", ".venv", "venv", "Pods", "vendor", ".swiftpm", ".Trash", "Library", "build", "dist"]
        for child in try Files.children(root.path) {
            let name = child.lastPathComponent
            guard let stat = try? Files.stamp(child.path), stat.kind == 2, !stat.dataless else { continue }
            if ["node_modules", ".build", "target", ".next"].contains(name) {
                guard CleanupPolicy.projectArtifactMatches(child) else { continue }
                seeds.append(CandidateSeed(path: child.path,
                    title: "\(root.lastPathComponent) / \(name)", category: .builds, rule: .projectArtifact,
                    reason: "Generated dependencies or build output beside a matching project manifest.",
                    consequence: "Reinstall dependencies or rebuild before running this project again.", review: true))
                continue
            }
            if ignored.contains(name) || name.hasPrefix(".") { continue }
            try discoverProjects(root: child, depth: depth + 1, context: context, seeds: &seeds)
        }
    }
}
