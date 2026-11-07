import AppKit
import BleachCore
import Observation
import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case clean, space, growth, duplicates, applications, recovery, system
    var id: String { rawValue }
    var title: String {
        switch self { case .clean: "Clean up"; case .space: "Space"; case .growth: "Growth"; case .duplicates: "Duplicates";
        case .applications: "Applications"; case .recovery: "Recovery"; case .system: "System" }
    }
    var symbol: String {
        switch self { case .clean: "sparkles"; case .space: "chart.bar.xaxis"; case .growth: "chart.line.uptrend.xyaxis"; case .duplicates: "square.on.square";
        case .applications: "square.grid.2x2"; case .recovery: "clock.arrow.circlepath"; case .system: "waveform.path.ecg" }
    }
}

enum Work: String {
    case idle, scanning, discovering, inactive, measuringGrowth, sharing, analyzing, comparing, loadingApps, planningRemoval, moving, restoring, erasing, saving
    var label: String {
        switch self {
        case .idle: ""
        case .scanning: "Scanning local files…"
        case .discovering: "Finding project artifacts, expanded ZIPs and installed-app installers…"
        case .inactive: "Checking project activity, process references and reinstall recipes…"
        case .measuringGrowth: "Measuring changes in private storage…"
        case .sharing: "Creating and verifying storage-sharing copies…"
        case .analyzing: "Measuring disk space…"
        case .comparing: "Comparing file contents…"
        case .loadingApps: "Reading applications…"
        case .planningRemoval: "Reviewing the app’s files…"
        case .moving: "Moving selected files to recovery…"
        case .restoring: "Restoring files…"
        case .erasing: "Deleting this recovery batch…"
        case .saving: "Saving…"
        }
    }
    var cancellable: Bool { [.scanning, .discovering, .inactive, .measuringGrowth, .analyzing, .comparing, .loadingApps, .planningRemoval].contains(self) }
}

enum CandidateFilter: String, CaseIterable { case all = "All", suggested = "Suggested", review = "Review", inUse = "In use" }

@MainActor @Observable final class AppModel {
    let engine = BleachEngine()
    let home: URL
    let state: URL
    let fixtureMode: Bool
    var destination: Destination? = .clean
    var work = Work.idle
    var errorMessage: String?
    var plan: CleanupPlan?
    var discovery: DiscoveryReport?
    var discoveredPaths: Set<String> = []
    var selectedPaths: Set<String> = []
    var focusedCandidate: String?
    var filter = CandidateFilter.all
    var search = ""
    var category: CleanupCategory?
    var showInspector = true
    var sortOrder = [KeyPathComparator(\CleanupCandidate.privateBytes, order: .reverse)]
    var review: CleanupPlan?
    var lastBatch: RecoveryBatch?
    var batches: [RecoveryBatch] = []
    var selectedBatch: UUID?
    var eraseRequest: RecoveryBatch?
    var preferences = Preferences()
    var disk: DiskReport?
    var diskRoot: URL?
    var diskBack: [URL] = []
    var diskSelection: String?
    var duplicateReport: DuplicateReport?
    var duplicateSelection: Set<String> = []
    var duplicateFolder: URL?
    var growthReport: GrowthReport?
    var growthRoot: URL?
    var sharingRequest: CleanupPlan?
    var sharingReceipt: SharingReceipt?
    var apps: [InstalledApp] = []
    var appSelection: String?
    var uninstall: CleanupPlan?
    var uninstallSelection: Set<String> = []
    var system: SystemSnapshot?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var revision = 0

    init() {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        let root = value("--root").map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        home = Files.canonicalURL(root)
        state = value("--state").map { URL(fileURLWithPath: Files.lexicalPath($0)) } ?? home.appendingPathComponent("Library/Application Support/Bleach")
        fixtureMode = args.contains("--fixture-mode") && args.contains("--root") && home != Files.canonicalURL(FileManager.default.homeDirectoryForCurrentUser)
    }

    var context: ScanContext { ScanContext(home: home, state: state, runningOwners: fixtureMode ? [] : RunningApplications.snapshot(), refreshRunningOwners: !fixtureMode) }
    var isBusy: Bool { work != .idle }
    var activePlan: CleanupPlan? {
        switch destination ?? .clean { case .duplicates: duplicateReport?.plan; case .applications: uninstall; default: plan }
    }
    var activeSelection: Set<String> {
        get { switch destination ?? .clean { case .duplicates: duplicateSelection; case .applications: uninstallSelection; default: selectedPaths } }
        set { switch destination ?? .clean { case .duplicates: duplicateSelection = newValue; case .applications: uninstallSelection = newValue; default: selectedPaths = newValue } }
    }
    var selectedCandidates: [CleanupCandidate] { activePlan?.candidates.filter { activeSelection.contains($0.path) } ?? [] }
    var selectedStorage: StorageUsage { .sum(selectedCandidates.map(\.storage)) }
    var selectedBytes: Int64 { selectedStorage.privateBytes }
    var discoveredCandidates: [CleanupCandidate] { plan?.candidates.filter { discoveredPaths.contains($0.path) } ?? [] }
    var discoveredBytes: Int64 { discoveredCandidates.reduce(0) { $0 + $1.privateBytes } }
    var visibleCandidates: [CleanupCandidate] {
        (plan?.candidates ?? []).filter { candidate in
            let matchesFilter = switch filter {
            case .all: true
            case .suggested: candidate.recommendation == .suggested
            case .review: candidate.recommendation == .review
            case .inUse: candidate.recommendation == .blocked
            }
            return matchesFilter && (category == nil || candidate.category == category) &&
                (search.isEmpty || candidate.title.localizedCaseInsensitiveContains(search) || candidate.path.localizedCaseInsensitiveContains(search))
        }.sorted(using: sortOrder)
    }
    var inspected: CleanupCandidate? { activePlan?.candidates.first { $0.path == focusedCandidate } }
    var recoverableBytes: Int64 { batches.reduce(0) { $0 + $1.heldBytes } }
    var recoverableCount: Int { batches.reduce(0) { $0 + $1.recoverable.count } }
    var latestRecoverable: RecoveryBatch? { batches.first { !$0.recoverable.isEmpty } }

    func load() async {
        do {
            preferences = try await engine.preferences(context: context)
            batches = try await engine.history(context: context)
            system = try await SystemReader.sample(at: home)
        } catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
        if CommandLine.arguments.contains("--auto-scan") { scan() }
    }

    private func perform(_ action: Work, _ body: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        revision += 1
        let current = revision
        work = action; errorMessage = nil
        job = Task { [weak self] in
            do { try await body() }
            catch is CancellationError { /* Cancellation is a user outcome, not an error. */ }
            catch { if self?.revision == current { self?.errorMessage = error.localizedDescription } }
            guard let self, self.revision == current else { return }
            self.work = .idle; self.job = nil
        }
    }

    func cancel() {
        guard work.cancellable else { return }
        job?.cancel(); job = nil; revision += 1; work = .idle
    }

    func scan() {
        perform(.scanning) { [self] in
            let result = try await engine.scan(context: context)
            try Task.checkCancellation()
            plan = result; selectedPaths = Set(result.suggested.map(\.path)); focusedCandidate = result.candidates.first?.path
            discovery = nil; discoveredPaths = []
            lastBatch = nil
            filter = .all; search = ""; category = nil
        }
    }

    func findMoreSpace() {
        perform(.discovering) { [self] in
            let result = try await engine.discover(context: context)
            try Task.checkCancellation()
            var combined = plan ?? result.plan.selecting([])
            for candidate in result.plan.candidates {
                if candidate.installerProof != nil, let index = combined.candidates.firstIndex(where: { $0.path == candidate.path }) {
                    combined.candidates[index] = candidate
                    continue
                }
                guard !combined.candidates.contains(where: {
                    Files.pathIsWithin(candidate.path, $0.path) || Files.pathIsWithin($0.path, candidate.path)
                }) else { continue }
                combined.candidates.append(candidate)
                discoveredPaths.insert(candidate.path)
            }
            combined.id = UUID(); combined.origin = "discover"
            combined.duration = (plan?.duration ?? 0) + result.plan.duration
            combined.scannedEntries = (plan?.scannedEntries ?? 0) + result.plan.scannedEntries
            combined.issues = Array(Dictionary(grouping: combined.issues + result.plan.issues, by: \.id).compactMap { $0.value.first }).sorted { $0.path < $1.path }
            combined.candidates.sort {
                if $0.privateBytes != $1.privateBytes { return $0.privateBytes > $1.privateBytes }
                return $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes
            }
            plan = combined; discovery = result
            lastBatch = nil; filter = .all; search = ""; category = nil
            if focusedCandidate == nil { focusedCandidate = combined.candidates.first?.path }
        }
    }

    func reviewInactiveProjects() {
        perform(.inactive) { [self] in
            let result = try await engine.inactiveProjects(context: context)
            try Task.checkCancellation()
            plan = result; selectedPaths = []; focusedCandidate = result.candidates.first?.path
            discovery = nil; discoveredPaths = []; lastBatch = nil
            filter = .all; search = ""; category = nil
        }
    }

    func measureGrowth(_ folder: URL, record: Bool = true) {
        perform(.measuringGrowth) { [self] in
            let result = try await engine.growth(in: folder, context: context, record: record)
            try Task.checkCancellation()
            growthReport = result; growthRoot = folder; destination = .growth
        }
    }

    var canShareSelection: Bool {
        !duplicateSelection.isEmpty && duplicateSelection.isSubset(of: Set(duplicateReport?.shareablePaths ?? []))
    }

    func shareStorage() {
        guard let preview = sharingRequest else { return }
        sharingRequest = nil; sharingReceipt = nil
        perform(.sharing) { [self] in
            let result = try await engine.shareDuplicateStorage(preview, context: context)
            sharingReceipt = result; batches = try await engine.history(context: context)
            duplicateSelection = []
            if let duplicateFolder { duplicateReport = try await engine.duplicates(in: duplicateFolder, context: context) }
            system = try await SystemReader.sample(at: home)
            if result.batch.problemCount > 0 { errorMessage = "Some originals remain in Recovery. Both paths may already exist; review the batch before retrying." }
        }
    }

    func refresh() {
        switch destination ?? .clean {
        case .clean: scan()
        case .space: analyze(diskRoot ?? home, remember: false)
        case .growth: if let growthRoot { measureGrowth(growthRoot, record: false) }
        case .duplicates: if let duplicateFolder { compare(duplicateFolder) }
        case .applications: loadApps()
        case .recovery: loadHistory()
        case .system: break
        }
    }

    func toggle(_ candidate: CleanupCandidate, selected: Bool) {
        guard candidate.recommendation != .blocked else { return }
        if selected { activeSelection.insert(candidate.path) } else { activeSelection.remove(candidate.path) }
    }

    func showReview() {
        guard let activePlan, !selectedCandidates.isEmpty else { return }
        review = activePlan.selecting(activeSelection)
    }

    func applyReview() {
        guard let preview = review else { return }
        review = nil
        perform(.moving) { [self] in
            let result = try await engine.apply(preview, context: context)
            let completed = Set(result.items.filter { $0.state == .moved }.map { $0.candidate.path })
            plan?.candidates.removeAll { completed.contains($0.path) }
            duplicateReport?.plan.candidates.removeAll { completed.contains($0.path) }
            uninstall?.candidates.removeAll { completed.contains($0.path) }
            apps.removeAll { completed.contains($0.path) }
            selectedPaths.subtract(completed); duplicateSelection.subtract(completed); uninstallSelection.subtract(completed)
            focusedCandidate = nil; lastBatch = result; selectedBatch = result.id
            batches = try await engine.history(context: context)
            system = try await SystemReader.sample(at: home)
        }
    }

    func loadHistory() {
        perform(.saving) { [self] in batches = try await engine.history(context: context) }
    }

    func restore(_ batch: RecoveryBatch) {
        perform(.restoring) { [self] in
            let result = try await engine.restore(batch: batch.id, context: context)
            batches = try await engine.history(context: context)
            lastBatch = result
            if result.problemCount > 0 { errorMessage = "Some items could not be restored. Their messages are listed in Recovery." }
        }
    }

    func erase(_ batch: RecoveryBatch) {
        eraseRequest = nil
        perform(.erasing) { [self] in
            let result = try await engine.erase(batch: batch.id, context: context)
            batches = try await engine.history(context: context)
            system = try await SystemReader.sample(at: home)
            if result.problemCount > 0 { errorMessage = "Some files remain in recovery. Review the item messages before retrying." }
        }
    }

    func analyze(_ url: URL, remember: Bool = true) {
        perform(.analyzing) { [self] in
            let result = try await engine.analyze(url)
            try Task.checkCancellation()
            if remember, let diskRoot { diskBack.append(diskRoot) }
            disk = result; diskRoot = url; diskSelection = nil
        }
    }

    func goBack() {
        guard let previous = diskBack.popLast() else { return }
        analyze(previous, remember: false)
    }

    func compare(_ folder: URL) {
        perform(.comparing) { [self] in
            sharingReceipt = nil
            let report = try await engine.duplicates(in: folder, context: context)
            try Task.checkCancellation()
            duplicateReport = report; duplicateFolder = folder; duplicateSelection = []; focusedCandidate = nil
        }
    }

    func keepDuplicate(_ path: String) {
        guard let duplicateReport else { return }
        perform(.comparing) { [self] in
            let report = try await engine.retaining(path, in: duplicateReport)
            try Task.checkCancellation()
            self.duplicateReport = report
            duplicateSelection.remove(path)
        }
    }

    func loadApps() {
        perform(.loadingApps) { [self] in
            let result = try await engine.installedApps(context: context)
            try Task.checkCancellation()
            apps = result
        }
    }

    func previewApp(_ path: String) {
        perform(.planningRemoval) { [self] in
            let result = try await engine.uninstallPlan(appPath: URL(fileURLWithPath: path), context: context)
            try Task.checkCancellation()
            uninstall = result
            uninstallSelection = Set(result.candidates.filter { $0.category == .applications && $0.recommendation != .blocked }.map(\.path))
            focusedCandidate = result.candidates.first?.path
        }
    }

    func savePreferences(_ value: Preferences) {
        perform(.saving) { [self] in
            let needsRescan = value.minimumAgeDays != preferences.minimumAgeDays || value.projectRoots != preferences.projectRoots
            try await engine.updatePreferences(value, context: context)
            preferences = value
            if needsRescan { plan = nil; selectedPaths = [] }
            else {
                plan?.candidates.removeAll { value.excludes($0.path) }
                selectedPaths = selectedPaths.intersection(Set(plan?.candidates.map(\.path) ?? []))
            }
            duplicateReport?.plan.candidates.removeAll { value.excludes($0.path) }
            duplicateSelection = duplicateSelection.intersection(Set(duplicateReport?.plan.candidates.map(\.path) ?? []))
            if uninstall?.candidates.contains(where: { $0.rule == .application && value.excludes($0.path) }) == true {
                uninstall = nil; uninstallSelection = []
            } else {
                uninstall?.candidates.removeAll { value.excludes($0.path) }
                uninstallSelection = uninstallSelection.intersection(Set(uninstall?.candidates.map(\.path) ?? []))
            }
            if let focusedCandidate, activePlan?.candidates.contains(where: { $0.path == focusedCandidate }) != true { self.focusedCandidate = nil }
        }
    }

    func protect(_ path: String) {
        var updated = preferences
        if !updated.excludedPaths.contains(path) { updated.excludedPaths.append(path); updated.excludedPaths.sort() }
        savePreferences(updated)
    }

    func chooseFolder(title: String, completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.directoryURL = home
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }

    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func revealRecovery(_ batch: RecoveryBatch) {
        NSWorkspace.shared.open(state.appendingPathComponent("Recovery/\(batch.id.uuidString.lowercased())/items"))
    }
    func exportPlan() {
        guard let activePlan else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Bleach-preview.json"
        if panel.runModal() == .OK, let url = panel.url {
            perform(.saving) { [self] in try await engine.export(activePlan, to: url) }
        }
    }
    func sampleSystem() async {
        do {
            let sample = try await SystemReader.sample(at: home)
            try Task.checkCancellation()
            system = sample
        } catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
    }
}
