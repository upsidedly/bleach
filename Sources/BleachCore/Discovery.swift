import Darwin
import Foundation

extension BleachEngine {
    public func discover(in folder: URL? = nil, context: ScanContext) throws -> DiscoveryReport {
        try discover(in: folder, context: context, limits: DiscoveryLimits())
    }

    func discover(in folder: URL? = nil, context: ScanContext, limits: DiscoveryLimits) throws -> DiscoveryReport {
        let start = Date()
        let preferences = try PreferencesStore(context: context).load()
        let policy = CleanupPolicy(context: context, preferences: preferences)
        let defaults = ["Projects", "Developer", "Code", "code", "Dev", "src", "Desktop/Projects", "Documents/Projects", "Documents/code", "Downloads"]
        let proposed = folder.map { [$0] } ?? (defaults.map(context.homeURL) + preferences.projectRoots.map { URL(fileURLWithPath: $0) })
        var roots: [String] = [], issues: [ScanIssue] = []
        func issue(_ path: String, _ message: String) {
            if issues.count < 200 { issues.append(ScanIssue(path: path, message: message)) }
        }
        for root in proposed.map({ URL(fileURLWithPath: Files.lexicalPath($0.path)) }).sorted(by: { $0.path.count < $1.path.count }) {
            guard !roots.contains(where: { Files.pathIsWithin(root.path, $0) }) else { continue }
            guard Files.pathIsWithin(root.path, context.home.path), !policy.protectedUserPath(root.path), policy.exclusionReason(root.path) == nil else {
                issue(root.path, "Discovery root is outside this home, protected or excluded"); continue
            }
            guard Files.exists(root.path) else { continue }
            do { try Files.ensureRealDirectory(root.path); roots.append(root.path) }
            catch { issue(root.path, error.localizedDescription) }
        }
        let device = try Files.stamp(context.home.path).device
        let artifacts: Set<String> = ["node_modules", ".build", ".next", "target"]
        let manifests = ["node_modules": "package.json", ".next": "package.json", ".build": "Package.swift", "target": "Cargo.toml"]
        let ignored: Set<String> = ["vendor", "Pods", "build", "dist"]
        var stack = roots.map { (URL(fileURLWithPath: $0), 0) }
        var directories = 0, projects: Set<String> = [], candidates: [CleanupCandidate] = [], pairs: [URL] = []
        var installerZIPs: [URL] = [], diskImages: [URL] = []
        var seen: Set<String> = []
        var scannedEntries = 0
        while let (directory, depth) = stack.popLast() {
            try Task.checkCancellation()
            guard directories < limits.directories, Date().timeIntervalSince(start) < limits.seconds else {
                issue(directory.path, "Discovery work limit reached; remaining folders were not scanned"); break
            }
            guard let stamp = try? Files.stamp(directory.path), stamp.kind == 2, !stamp.dataless,
                  stamp.owner == getuid(), stamp.device == device, seen.insert(stamp.identity).inserted else { continue }
            directories += 1
            do {
                for seed in ProjectOutputs.processingSeeds(in: directory) where policy.exclusionReason(seed.path) == nil {
                    let snapshot = try FileWalker.completeSnapshot(seed.path, deadline: start.addingTimeInterval(limits.seconds))
                    guard snapshot.allocatedBytes > 0 else { continue }
                    var candidate = CleanupCandidate(path: seed.path, title: seed.title, category: seed.category, rule: seed.rule,
                        reason: seed.reason, consequence: seed.consequence, recommendation: .review, snapshot: snapshot)
                    if let busy = policy.busyReason(candidate) { candidate.recommendation = .blocked; candidate.blockedReason = busy }
                    candidates.append(candidate)
                    projects.insert(directory.path); scannedEntries += snapshot.entryCount
                }
                let swiftOutputs = ProjectOutputs.swiftOutputs(in: directory)
                for output in swiftOutputs where policy.exclusionReason(output.path) == nil {
                    let snapshot = try FileWalker.completeSnapshot(output.path, deadline: start.addingTimeInterval(limits.seconds))
                    if snapshot.allocatedBytes > 0 {
                        candidates.append(CleanupCandidate(path: output.path, title: "\(directory.lastPathComponent) / \(output.deletingLastPathComponent().lastPathComponent)", category: .builds, rule: .customBuildOutput,
                            reason: "Swift compiler output identified by its target triple, package manifest and build description.", consequence: "The next build takes longer. Source, package checkouts and packaged applications stay.", recommendation: .review, snapshot: snapshot))
                        projects.insert(directory.path); scannedEntries += snapshot.entryCount
                    }
                }
                let children = try Files.children(directory.path)
                for child in children {
                    try Task.checkCancellation()
                    let name = child.lastPathComponent
                    guard policy.exclusionReason(child.path) == nil,
                          let childStamp = try? Files.stamp(child.path), !childStamp.dataless,
                          childStamp.owner == getuid(), childStamp.device == device else { continue }
                    if artifacts.contains(name), childStamp.kind == 2 {
                        if name == ".build", swiftOutputs.contains(where: { Files.pathIsWithin($0.path, child.path) }) { continue }
                        guard CleanupPolicy.projectArtifactMatches(child) else { continue }
                        let snapshot = try FileWalker.completeSnapshot(child.path, deadline: start.addingTimeInterval(limits.seconds))
                        guard snapshot.allocatedBytes > 0 else { continue }
                        let manifest = manifests[name] ?? "project manifest"
                        let changed = (try? Files.stamp(directory.appendingPathComponent(manifest).path).modified) ?? context.now
                        candidates.append(CleanupCandidate(path: child.path, title: "\(directory.lastPathComponent) / \(name)",
                            category: .builds, rule: .projectArtifact,
                            reason: "Discovered beside \(manifest). That manifest changed \(Display.age(changed, now: context.now).lowercased()); this is context, not proof the project is unused.",
                            consequence: "Project source stays in place. Reinstall dependencies or rebuild before using this project again; locally edited generated files may be lost.",
                            recommendation: .review, snapshot: snapshot))
                        projects.insert(directory.path); scannedEntries += snapshot.entryCount
                        continue
                    }
                    if childStamp.kind == 2, let outputProject = ProjectOutputs.nextProject(for: child), Files.pathIsWithin(outputProject.path, context.home.path) {
                        let snapshot = try FileWalker.completeSnapshot(child.path, deadline: start.addingTimeInterval(limits.seconds))
                        candidates.append(CleanupCandidate(path: child.path, title: "\(directory.lastPathComponent) / \(name)", category: .builds, rule: .customBuildOutput,
                            reason: "Next.js output identified by BUILD_ID, build manifests, server and static folders beside a Next.js project.", consequence: "Rebuild before serving this output. Project source and dependencies stay.", recommendation: .review, snapshot: snapshot, outputProjectPath: outputProject.path))
                        projects.insert(ProjectOutputs.nextProject(for: child)?.path ?? directory.path); scannedEntries += snapshot.entryCount
                        continue
                    }
                    guard !name.hasPrefix("."), !policy.protectedUserPath(child.path), !ignored.contains(name) else { continue }
                    if childStamp.kind == 1, child.pathExtension.lowercased() == "zip" {
                        if pairs.count + installerZIPs.count < limits.archives {
                            if (try? Files.stamp(child.deletingPathExtension().path).kind) == 2 { pairs.append(child) }
                            else { installerZIPs.append(child) }
                        } else { issue(child.path, "ZIP comparison count limit reached") }
                    }
                    if childStamp.kind == 1, child.pathExtension.lowercased() == "dmg",
                       directory.path == context.homeURL("Downloads").path, diskImages.count < 64 {
                        diskImages.append(child)
                    }
                    if childStamp.kind == 2 {
                        if depth < limits.depth { stack.append((child, depth + 1)) }
                        else { issue(child.path, "Discovery depth limit reached; folder was not scanned") }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { issue(directory.path, error.localizedDescription) }
        }
        var compared = 0, matched = 0, verifiedFiles = 0
        var verifiedBytes: Int64 = 0, comparedBytes: Int64 = 0
        for pair in pairs.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(start) < limits.seconds, comparedBytes < limits.totalArchiveBytes else {
                issue(pair.path, "Discovery comparison budget reached; remaining ZIPs were not compared"); break
            }
            compared += 1
            do {
                let snapshot = try FileWalker.completeSnapshot(pair.path, deadline: start.addingTimeInterval(limits.seconds))
                var budget = limits
                budget.archiveBytes = min(budget.archiveBytes, limits.totalArchiveBytes - comparedBytes)
                budget.archiveSeconds = min(budget.archiveSeconds, limits.seconds - Date().timeIntervalSince(start))
                let proof = try ArchiveTwins.prove(pair, policy: policy, limits: budget) { amount in
                    guard amount <= limits.totalArchiveBytes - comparedBytes else { throw BleachError("Discovery expanded-byte budget reached") }
                    comparedBytes += amount
                }
                guard try FileWalker.completeSnapshot(pair.path).matchesFileState(snapshot) else { throw BleachError("ZIP changed during discovery") }
                candidates.append(CleanupCandidate(path: pair.path, title: pair.lastPathComponent,
                    category: .archives, rule: .expandedArchive,
                    reason: "All \(proof.fileCount) file contents match the expanded folder at \(proof.expandedPath), verified with full SHA-256. The folder stays.",
                    consequence: "Only the ZIP moves to recovery. File bytes were compared; archive metadata and its value as an offline backup may differ. Keep archives you still need.",
                    recommendation: .review, snapshot: snapshot, archiveProof: proof))
                matched += 1; verifiedFiles += proof.fileCount; verifiedBytes += proof.expandedBytes
                scannedEntries += snapshot.entryCount
            } catch is CancellationError { throw CancellationError() }
            catch { issue(pair.path, error.localizedDescription) }
        }
        let apps = try installedApps(context: context)
        var installedInstallers = 0
        func addInstaller(_ url: URL, snapshot: TreeSnapshot, proof: InstallerProof) throws {
            guard try FileWalker.completeSnapshot(url.path).matchesFileState(snapshot) else { throw BleachError("Installer changed during inspection") }
            let app = URL(fileURLWithPath: proof.installedPath).lastPathComponent
            let version = proof.version.isEmpty ? proof.build : proof.version
            candidates.append(CleanupCandidate(path: url.path, title: url.lastPathComponent,
                category: .installers, rule: url.pathExtension.lowercased() == "zip" ? .archivedInstaller : .installer,
                reason: "\(app) is already installed with the same bundle ID (\(proof.bundleID)), version \(version) and build \(proof.build.isEmpty ? "unspecified" : proof.build).",
                consequence: "The installed app stays in place. This matches identity and version, not every payload byte; keep the installer if you need an offline backup or reinstall copy.",
                recommendation: .review, snapshot: snapshot, installerProof: proof))
            installedInstallers += 1; scannedEntries += snapshot.entryCount
        }
        for zip in installerZIPs {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(start) < limits.seconds else { issue(zip.path, "Installer inspection time budget reached"); break }
            do {
                let snapshot = try FileWalker.completeSnapshot(zip.path)
                if let proof = try InstallerMatches.zip(zip, apps: apps, context: context, maximumEntries: limits.archiveEntries) {
                    try addInstaller(zip, snapshot: snapshot, proof: proof)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { issue(zip.path, error.localizedDescription) }
        }
        if !diskImages.isEmpty {
            do {
                let mounted = try InstallerMatches.mountedImages()
                for image in diskImages {
                    try Task.checkCancellation()
                    guard Date().timeIntervalSince(start) < limits.seconds else { issue(image.path, "Installer inspection time budget reached"); break }
                    let snapshot = try FileWalker.completeSnapshot(image.path)
                    if let proof = try InstallerMatches.diskImage(image, mounted: mounted, apps: apps, context: context) {
                        try addInstaller(image, snapshot: snapshot, proof: proof)
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { issue(context.homeURL("Downloads").path, error.localizedDescription) }
        }
        candidates.sort {
            if $0.privateBytes != $1.privateBytes { return $0.privateBytes > $1.privateBytes }
            return $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes
        }
        let plan = CleanupPlan(createdAt: context.now, home: context.home.path, origin: "discover", candidates: candidates,
            issues: issues.sorted { $0.path < $1.path }, duration: Date().timeIntervalSince(start), scannedEntries: scannedEntries)
        return DiscoveryReport(plan: plan, roots: roots.sorted(), directoriesVisited: directories, projectsFound: projects.count,
            archivesCompared: compared, archivesMatched: matched, verifiedArchiveFiles: verifiedFiles,
            verifiedExpandedBytes: verifiedBytes, expandedBytesRead: comparedBytes, installedInstallers: installedInstallers)
    }
}
