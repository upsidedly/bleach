import BleachFS
import Darwin
import Foundation

extension BleachEngine {
    public func export(_ plan: CleanupPlan, to url: URL) throws {
        try JSONCoding.encoder().encode(plan).write(to: url, options: .atomic)
    }
    public func analyze(_ url: URL, largestLimit: Int = 60) throws -> DiskReport {
        let start = Date()
        let path = Files.canonicalURL(url).path
        guard (0...1000).contains(largestLimit) else { throw BleachError("Largest-file limit must be between 0 and 1000") }
        try Files.ensureRealDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        var analysis = BLAnalysis()
        let code = bl_analyze(path, largestLimit, { _ in Task.isCancelled ? 1 : 0 }, nil, &analysis)
        defer { bl_free_analysis(&analysis) }
        if code == ECANCELED { throw CancellationError() }
        try Files.require(code, path)
        func convert(_ entry: BLAnalysisEntry) -> DiskEntry {
            let path = String(cString: entry.path)
            return DiskEntry(path: path, name: String(path.split(separator: "/").last ?? ""),
                isDirectory: entry.directory != 0, logicalBytes: entry.logical, allocatedBytes: entry.allocated,
                fileCount: Int(entry.files), storage: StorageUsage(entry.storage), isSymbolicLink: entry.symbolic_link != 0)
        }
        func ordered(_ lhs: DiskEntry, _ rhs: DiskEntry) -> Bool {
            if lhs.storage.privateBytes != rhs.storage.privateBytes { return lhs.storage.privateBytes > rhs.storage.privateBytes }
            return lhs.allocatedBytes == rhs.allocatedBytes ? lhs.path < rhs.path : lhs.allocatedBytes > rhs.allocatedBytes
        }
        let entries = (0..<analysis.entry_count).compactMap { index in analysis.entries[index].map { convert($0.pointee) } }.sorted(by: ordered)
        let largest = (0..<analysis.largest_count).map { convert(analysis.largest[$0]) }.sorted(by: ordered)
        let issues = (0..<analysis.issue_count).map { index in
            let issue = analysis.issues[index]
            return ScanIssue(path: String(cString: issue.path), message: String(cString: strerror(Int32(issue.code))))
        }
        return DiskReport(path: path, entries: entries, largestFiles: largest,
            logicalBytes: analysis.logical, allocatedBytes: analysis.allocated, fileCount: Int(analysis.files),
            entryCount: Int(analysis.nodes), issues: issues, duration: Date().timeIntervalSince(start), storage: StorageUsage(analysis.storage))
    }

    public func duplicates(in url: URL, context: ScanContext, minimumSize: Int64 = 1) throws -> DuplicateReport {
        let start = Date()
        let path = Files.canonicalURL(url).path
        let preferences = try PreferencesStore(context: context).load()
        let policy = CleanupPolicy(context: context, preferences: preferences)
        guard Files.pathIsWithin(path, context.home.path), !policy.protectedUserPath(path), policy.exclusionReason(path) == nil else {
            throw BleachError("Choose a local documents folder inside this home. App data, credentials and cloud folders are protected.")
        }
        let walked = try FileWalker.walk(path, collect: true, fingerprint: false) { file, stamp in
            policy.protectedUserPath(file) || policy.exclusionReason(file) != nil || stamp.dataless
        }
        var bySize: [Int64: [(String, FileStamp)]] = [:]
        var inspected = 0
        var seen: Set<String> = []
        for (file, stamp) in walked.records where stamp.kind == 1 && stamp.links == 1 && !stamp.dataless && stamp.owner == getuid() && stamp.size >= max(1, minimumSize) {
            guard seen.insert(stamp.identity).inserted else { continue }
            inspected += 1
            bySize[stamp.size, default: []].append((file, stamp))
        }
        var groups: [DuplicateGroup] = []
        var candidates: [CleanupCandidate] = []
        var issues = walked.issues
        var filesHashed = 0
        var bytesHashed: Int64 = 0
        for size in bySize.keys.sorted(by: >) {
            guard let files = bySize[size], files.count > 1 else { continue }
            var byHash: [String: [(String, FileStamp)]] = [:]
            for (file, stamp) in files {
                try Task.checkCancellation()
                do {
                    let hash = try Files.sha256(file, expected: stamp)
                    byHash[hash, default: []].append((file, stamp)); filesHashed += 1; bytesHashed += stamp.size
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append(ScanIssue(path: file, message: error.localizedDescription)) }
            }
            for hash in byHash.keys.sorted() {
                guard let matches = byHash[hash], matches.count > 1 else { continue }
                let ordered = matches.sorted { $0.0 < $1.0 }
                let keeper = ordered[0]
                groups.append(DuplicateGroup(sha256: hash, files: ordered.map(\.0), bytesPerFile: size))
                for (file, _) in ordered.dropFirst() {
                    do {
                        let snapshot = try FileWalker.completeSnapshot(file)
                        candidates.append(CleanupCandidate(path: file, title: URL(fileURLWithPath: file).lastPathComponent,
                            category: .duplicates, rule: .duplicate, reason: "Full SHA-256 matches \(keeper.0).",
                            consequence: "The copy at \(keeper.0) stays in place. APFS copies may share disk blocks.",
                            recommendation: .review, snapshot: snapshot,
                            duplicateProof: DuplicateProof(keeperPath: keeper.0, keeperStamp: keeper.1, sha256: hash)))
                    } catch is CancellationError { throw CancellationError() }
                    catch { issues.append(ScanIssue(path: file, message: error.localizedDescription)) }
                }
            }
        }
        let plan = CleanupPlan(createdAt: context.now, home: context.home.path, origin: "duplicates", candidates: candidates,
            issues: issues, duration: Date().timeIntervalSince(start), scannedEntries: walked.snapshot.entryCount)
        return DuplicateReport(path: path, groups: groups, plan: plan, filesInspected: inspected, filesHashed: filesHashed, bytesHashed: bytesHashed, shareablePaths: StorageSharing.eligiblePaths(in: plan))
    }

    public func retaining(_ path: String, in report: DuplicateReport) throws -> DuplicateReport {
        guard let group = report.groups.first(where: { $0.files.contains(path) }) else { throw BleachError("Choose a file from this duplicate group") }
        let keeperStamp = try Files.stamp(path)
        let snapshot = try FileWalker.completeSnapshot(path)
        guard try Files.sha256(path, expected: keeperStamp) == group.sha256 else { throw BleachError("Duplicate changed; scan again") }
        var result = report
        var templates = report.plan.candidates.filter { $0.duplicateProof?.sha256 == group.sha256 }
        guard let template = templates.first else { return report }
        if let oldKeeper = template.duplicateProof, oldKeeper.keeperPath != path {
            var candidate = template
            candidate.path = oldKeeper.keeperPath
            candidate.title = URL(fileURLWithPath: candidate.path).lastPathComponent
            candidate.snapshot = try FileWalker.completeSnapshot(candidate.path)
            templates.append(candidate)
        }
        result.plan.candidates.removeAll { $0.duplicateProof?.sha256 == group.sha256 }
        for var candidate in templates where candidate.path != path {
            candidate.duplicateProof = DuplicateProof(keeperPath: path, keeperStamp: keeperStamp, sha256: group.sha256)
            candidate.reason = "Full SHA-256 matches \(path)."
            candidate.consequence = "The copy at \(path) stays in place. APFS copies may share disk blocks."
            result.plan.candidates.append(candidate)
        }
        _ = snapshot
        if let index = result.groups.firstIndex(where: { $0.id == group.id }) {
            result.groups[index].files = [path] + group.files.filter { $0 != path }
        }
        result.shareablePaths = StorageSharing.eligiblePaths(in: result.plan)
        return result
    }

    public func installedApps(context: ScanContext) throws -> [InstalledApp] {
        var result: [InstalledApp] = []
        for root in [URL(fileURLWithPath: "/Applications"), context.homeURL("Applications")] {
            guard try Files.optionalStamp(root.path) != nil else { continue }
            for app in try Files.children(root.path) where app.pathExtension == "app" {
                guard let stamp = try? Files.stamp(app.path), stamp.kind == 2,
                      let info = CleanupPolicy.bundleInfo(at: app.path),
                      let id = info["CFBundleIdentifier"] as? String, CleanupPolicy.validBundleID(id) else { continue }
                result.append(InstalledApp(path: app.path,
                    name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent,
                    bundleID: id, version: info["CFBundleShortVersionString"] as? String ?? "—",
                    running: context.runningOwners.contains { $0.bundleID == id },
                    removable: !id.hasPrefix("com.apple.") && stamp.owner == getuid()))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func uninstallPlan(appPath: URL, context: ScanContext) throws -> CleanupPlan {
        let start = Date()
        let path = Files.canonicalURL(appPath).path
        guard let app = try installedApps(context: context).first(where: { $0.path == path }), app.removable else {
            throw BleachError("Choose a user-owned app in /Applications or ~/Applications. System apps are protected.")
        }
        let policy = CleanupPolicy(context: context, preferences: try PreferencesStore(context: context).load())
        var candidates: [CleanupCandidate] = []
        var issues: [ScanIssue] = []
        let appSnapshot = try FileWalker.completeSnapshot(path)
        var main = CleanupCandidate(path: path, title: app.name, category: .applications, rule: .application,
            reason: "The application bundle, identified by \(app.bundleID).", consequence: "The app will be unavailable until restored or reinstalled. Personal data is a separate choice.",
            recommendation: .review, snapshot: appSnapshot, ownerBundleID: app.bundleID)
        if let busy = policy.busyReason(main) { main.recommendation = .blocked; main.blockedReason = busy }
        if let excluded = policy.exclusionReason(path) { throw BleachError(excluded) }
        candidates.append(main)
        let siblings = try installedApps(context: context).filter { $0.bundleID == app.bundleID && $0.path != path }
        if siblings.isEmpty {
            for relative in ["Library/Caches/\(app.bundleID)", "Library/Preferences/\(app.bundleID).plist",
                "Library/Application Support/\(app.bundleID)", "Library/Saved Application State/\(app.bundleID).savedState"] {
                let url = context.homeURL(relative)
                guard try Files.optionalStamp(url.path) != nil else { continue }
                do {
                    if let exclusion = policy.exclusionReason(url.path) { throw BleachError(exclusion) }
                    let snapshot = try FileWalker.completeSnapshot(url.path)
                    var candidate = CleanupCandidate(path: url.path, title: url.lastPathComponent,
                        category: .appData, rule: .appRelatedData, reason: "Exact bundle identifier matches \(app.bundleID); choose this separately.",
                        consequence: "May remove settings, saved state or personal app data. Keep it to preserve your setup.",
                        recommendation: .review, snapshot: snapshot, ownerBundleID: app.bundleID, applicationPath: path)
                    if let busy = policy.busyReason(candidate) { candidate.recommendation = .blocked; candidate.blockedReason = busy }
                    candidates.append(candidate)
                } catch { issues.append(ScanIssue(path: url.path, message: error.localizedDescription)) }
            }
        } else { issues.append(ScanIssue(path: path, message: "Another copy shares this bundle identifier; all related data is retained.")) }
        return CleanupPlan(createdAt: context.now, home: context.home.path, origin: "uninstall", candidates: candidates,
            issues: issues, duration: Date().timeIntervalSince(start), scannedEntries: candidates.reduce(0) { $0 + $1.snapshot.entryCount })
    }
}
