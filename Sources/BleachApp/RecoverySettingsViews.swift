import BleachCore
import Charts
import SwiftUI

struct RecoveryView: View {
    @Bindable var model: AppModel
    private var selected: RecoveryBatch? { model.batches.first { $0.id == model.selectedBatch } }
    var body: some View {
        if model.batches.isEmpty {
            EmptyState(symbol: "clock.arrow.circlepath", title: "A way back.",
                message: "Cleanup batches appear here. Restore them, or delete a specific batch permanently when you are ready.") {
                Button("Clean up") { model.destination = .clean }
            }
        } else {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Display.bytes(model.recoverableBytes)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                    Text("allocated in recovery").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 24).padding(.top, 24)
                Text("Recovery keeps these files on disk. Allocation can include shared blocks. Restore files or delete a batch permanently.")
                    .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 7).padding(.bottom, 22)
                VSplitView {
                    Table(model.batches, selection: $model.selectedBatch) {
                        TableColumn("Batch") { batch in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(batch.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.medium))
                                Text(batch.shortID).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.padding(.vertical, 7)
                        }.width(min: 170, ideal: 220)
                        TableColumn("Allocated") { Text(Display.bytes($0.heldBytes)).font(.subheadline).monospacedDigit() }.width(95)
                        TableColumn("State") { batch in
                            Text(batch.problemCount > 0 ? "Needs review" : batch.recoverable.isEmpty ? "Finished" : "Recoverable")
                                .font(.caption).foregroundStyle(.secondary)
                        }.width(min: 90, ideal: 110)
                    }.tableStyle(.inset(alternatesRowBackgrounds: false)).frame(minHeight: 140)
                    if let batch = selected {
                        List(batch.items) { item in
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: symbol(item.state)).font(.subheadline).foregroundStyle(.secondary).frame(width: 19).padding(.top, 2).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.candidate.title).font(.subheadline.weight(.medium))
                                        Spacer()
                                        Text(stateLabel(item.state)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(Display.path(item.candidate.path, home: model.home)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    if let message = item.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                }
                            }.padding(.vertical, 6)
                        }.listStyle(.inset).frame(minHeight: 140)
                    }
                }
                HStack(spacing: 11) {
                    if let batch = selected {
                        Button("Reveal Files", systemImage: "folder") { model.revealRecovery(batch) }.buttonStyle(.borderless)
                        Spacer()
                        Button("Delete Permanently…", role: .destructive) { model.eraseRequest = batch }
                            .disabled((batch.recoverable.isEmpty && batch.interruptedDeletions.isEmpty) || model.isBusy)
                        Button { model.restore(batch) } label: { PrimaryButtonLabel(title: "Restore") }.buttonStyle(.borderedProminent)
                            .disabled(batch.recoverable.isEmpty || model.isBusy)
                            .accessibilityIdentifier("restore-batch")
                    } else {
                        Text("Select a batch to review its files.").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                    }
                }.padding(.horizontal, 24).padding(.vertical, 17).background(.bar)
            }
        }
    }
    private func symbol(_ state: RecoveryState) -> String {
        switch state { case .restored: "arrow.uturn.backward"; case .erased: "checkmark"; case .moved: "clock.arrow.circlepath"; default: "exclamationmark.circle" }
    }
    private func stateLabel(_ state: RecoveryState) -> String {
        switch state {
        case .prepared: "Pending"
        case .moved: "In recovery"
        case .restoring: "Restoring"
        case .restored: "Restored"
        case .erasing: "Deleting"
        case .eraseInterrupted: "Deletion interrupted"
        case .erased: "Deleted permanently"
        case .failed: "Kept in place"
        case .conflict: "Needs review"
        case .missing: "Unavailable"
        }
    }
}

struct CPUPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var excludedSelection: String?
    @State private var projectSelection: String?

    var body: some View {
        Form {
            Section("Cleanup suggestions") {
                Stepper("Suggest logs untouched for \(model.preferences.minimumAgeDays) days", value: Binding(get: { model.preferences.minimumAgeDays }, set: { value in
                    var updated = model.preferences; updated.minimumAgeDays = value; model.savePreferences(updated)
                }), in: 30...3650)
                Text("Rebuildable caches start selected, including recent caches. Known running app caches stay unselected. Recent logs, build artifacts and installers wait for your choice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AutomaticSettingsView(model: model)
            MCPSettingsView()
            Section("Project folders") {
                Text("Include generated dependencies and build output beside matching project manifests.").font(.caption).foregroundStyle(.secondary)
                List(model.preferences.projectRoots, id: \.self, selection: $projectSelection) { path in
                    Text(Display.path(path, home: model.home)).font(.subheadline).lineLimit(1).truncationMode(.middle).tag(path)
                }.frame(height: 82)
                HStack {
                    Button("Add Folder…", systemImage: "plus") {
                        model.chooseFolder(title: "Include project folder") { url in
                            var updated = model.preferences
                            if !updated.projectRoots.contains(url.path) { updated.projectRoots.append(url.path); model.savePreferences(updated) }
                        }
                    }
                    Button("Remove", systemImage: "minus") {
                        var updated = model.preferences; updated.projectRoots.removeAll { $0 == projectSelection }; model.savePreferences(updated); projectSelection = nil
                    }.disabled(projectSelection == nil)
                }.controlSize(.small)
            }
            Section("Excluded from cleanup") {
                List(model.preferences.excludedPaths, id: \.self, selection: $excludedSelection) { path in
                    Text(Display.path(path, home: model.home)).font(.subheadline).lineLimit(1).truncationMode(.middle).tag(path)
                }.frame(height: 82)
                HStack {
                    Button("Add Folder…", systemImage: "plus") { model.chooseFolder(title: "Exclude folder from cleanup") { model.protect($0.path) } }
                    Button("Remove", systemImage: "minus") {
                        var updated = model.preferences; updated.excludedPaths.removeAll { $0 == excludedSelection }; model.savePreferences(updated); excludedSelection = nil
                    }.disabled(excludedSelection == nil)
                }.controlSize(.small)
                Text("Excluding a file or folder also protects a cleanup candidate containing it. Built-in protections always apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Bleach works locally. No accounts, uploads or analytics. Automatic permanent deletion requires your explicit opt-in.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(10).frame(width: 580, height: 760).disabled(model.isBusy)
    }
}
