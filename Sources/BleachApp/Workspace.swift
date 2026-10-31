import AppKit
import BleachCore
import SwiftUI

struct Workspace: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 176, ideal: 202, max: 250)
        } detail: {
            VStack(spacing: 0) {
                if model.isBusy { workBar }
                Group {
                    switch model.destination ?? .clean {
                    case .clean: CleanupView(model: model)
                    case .space: SpaceView(model: model)
                    case .duplicates: DuplicatesView(model: model)
                    case .applications: ApplicationsView(model: model)
                    case .recovery: RecoveryView(model: model)
                    case .system: SystemView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle((model.destination ?? .clean).title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if [.clean, .duplicates, .applications].contains(model.destination ?? .clean), model.activePlan != nil {
                        Button("Export Preview", systemImage: "square.and.arrow.up") { model.exportPlan() }
                            .help("Export the exact cleanup preview as JSON")
                            .disabled(model.isBusy)
                        Button("Inspector", systemImage: "sidebar.right") { model.showInspector.toggle() }
                            .help("Show or hide item details (⌘I)")
                            .keyboardShortcut("i", modifiers: .command)
                    }
                    if model.destination != .system {
                        Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                            .help("Refresh (⌘R)")
                            .keyboardShortcut("r", modifiers: .command)
                            .disabled(model.isBusy)
                    }
                }
            }
            .inspector(isPresented: Binding(get: {
                model.showInspector && model.activePlan != nil && [.clean, .duplicates, .applications].contains(model.destination ?? .clean)
            }, set: { model.showInspector = $0 })) {
                CandidateInspector(model: model)
                    .inspectorColumnWidth(min: 230, ideal: 270, max: 340)
            }
        }
        .tint(Color.primary)
        .accentColor(Color(nsColor: .labelColor))
        .frame(minWidth: 880, minHeight: 580)
        .task { await model.load() }
        .onChange(of: model.destination) { _, destination in
            model.search = ""
            switch destination ?? .clean {
            case .applications: if model.apps.isEmpty { model.loadApps() }
            case .recovery: model.loadHistory()
            default: break
            }
        }
        .sheet(item: $model.review) { preview in ReviewSheet(model: model, plan: preview).tint(.primary).accentColor(Color(nsColor: .labelColor)) }
        .alert("Couldn’t finish", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("Delete this batch permanently?", isPresented: Binding(get: { model.eraseRequest != nil }, set: { if !$0 { model.eraseRequest = nil } }), titleVisibility: .visible) {
            if let batch = model.eraseRequest {
                Button("Delete Permanently", role: .destructive) { model.erase(batch) }
                Button("Cancel", role: .cancel) { model.eraseRequest = nil }
            }
        } message: {
            if let batch = model.eraseRequest {
                Text("Delete \(batch.recoverable.count + batch.interruptedDeletions.count) retained items in batch \(batch.shortID). This cannot be undone. Your Mac’s Trash is separate.")
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BleachMark().stroke(style: StrokeStyle(lineWidth: BleachMark.strokeWidth, lineCap: .round, lineJoin: .round))
                    .frame(width: 23, height: 23).accessibilityHidden(true)
                Text("Bleach").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 19).padding(.top, 17).padding(.bottom, 20)
            List(selection: $model.destination) {
                Section {
                    ForEach([Destination.clean, .space, .duplicates, .applications]) { destination in
                        Label(destination.title, systemImage: destination.symbol).tag(destination)
                            .padding(.vertical, 3)
                    }
                }
                Section {
                    HStack {
                        Label("Recovery", systemImage: Destination.recovery.symbol)
                        Spacer()
                        if model.recoverableCount > 0 { Text(model.recoverableCount.formatted()).font(.caption).foregroundStyle(.secondary) }
                    }.tag(Destination.recovery).padding(.vertical, 3)
                    Label("System", systemImage: Destination.system.symbol).tag(Destination.system).padding(.vertical, 3)
                }
            }.listStyle(.sidebar).listItemTint(.primary)
            Spacer(minLength: 8)
            if let system = model.system, system.diskTotal > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.fixtureMode ? "Fixture home" : "Storage").font(.subheadline.weight(.medium))
                    ProgressView(value: Double(system.diskTotal - system.diskAvailable), total: Double(system.diskTotal))
                        .tint(.secondary)
                        .accessibilityLabel("Disk space used")
                    Text("\(Display.bytes(system.diskAvailable)) available").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.bottom, 19)
            }
            HStack {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(.plain).font(.subheadline).foregroundStyle(.secondary)
                    .help("Settings (⌘,)")
                Spacer()
                Text(BleachVersion.current).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 18)
        }
    }

    private var workBar: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(model.work.label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            if model.work.cancellable { Button("Cancel", role: .cancel) { model.cancel() }.controlSize(.small).keyboardShortcut(.escape, modifiers: []) }
        }.padding(.horizontal, 24).padding(.vertical, 11).background(.bar)
    }
}

struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: 17) {
            Image(systemName: symbol).font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title).font(.title2.weight(.semibold))
                Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            actions().padding(.top, 5)
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SelectionBar: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.selectedCandidates.count) selected · \(Display.bytes(model.selectedBytes)) private")
                    .help(StorageUsage.explanation)
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Text("Recoverable until you delete the batch.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Review Cleanup…") { model.showReview() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.selectedCandidates.isEmpty || model.isBusy)
        }.padding(.horizontal, 23).padding(.vertical, 15).background(.bar)
    }
}
