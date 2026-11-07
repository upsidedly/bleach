import AppKit
import BleachCore
import SwiftUI

struct CommandPalette: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searching: Bool

    private struct Action: Identifiable {
        var id: String
        var title: String
        var symbol: String
        var enabled = true
        var perform: @MainActor () -> Void
    }
    private var actions: [Action] {
        var result: [Action] = [
            Action(id: "scan", title: "Scan for cleanup", symbol: "arrow.clockwise", enabled: !model.isBusy) { model.destination = .clean; model.scan() },
            Action(id: "discover", title: "Find more space", symbol: "sparkle.magnifyingglass", enabled: !model.isBusy) { model.destination = .clean; model.findMoreSpace() },
            Action(id: "inactive", title: "Review inactive projects", symbol: "shippingbox", enabled: !model.isBusy) { model.destination = .clean; model.reviewInactiveProjects() },
            Action(id: "review", title: "Review cleanup selection", symbol: "checklist", enabled: !model.isBusy && !model.selectedCandidates.isEmpty) { model.showReview() },
            Action(id: "copy", title: "Copy report for your agent", symbol: "doc.on.clipboard") { model.copyAgentReport() },
            Action(id: "memory", title: "Free memory · manage running apps", symbol: "memorychip") { model.resourceMetric = .memory; model.destination = .system },
            Action(id: "gpu", title: "Manage GPU · quit a running app", symbol: "cpu") { model.resourceMetric = .gpu; model.destination = .system },
            Action(id: "pause", title: "Pause automatic cleanup for one hour", symbol: "pause.circle", enabled: !model.isBusy && model.automaticSettings.enabled) { model.updateAutomatic { $0.pausedUntil = Date().addingTimeInterval(3600) } }
        ]
        result += Destination.allCases.map { destination in
            Action(id: "open-\(destination.id)", title: "Open \(destination.title)", symbol: destination.symbol) { model.destination = destination }
        }
        if query.count >= 2 {
            result += model.processes.filter { model.canQuit($0) }.map { process in
                Action(id: "quit-\(process.id)", title: "Quit \(process.name)", symbol: "stop.circle") { model.quit(process) }
            }
            result += model.processes.filter { model.canQuit($0) }.map { process in
                Action(id: "force-\(process.id)", title: "Force quit \(process.name)…", symbol: "xmark.octagon") { model.quitRequest = process }
            }
            result += model.apps.filter { $0.removable }.map { app in
                Action(id: "uninstall-\(app.path)", title: "Uninstall \(app.name)…", symbol: "trash", enabled: !model.isBusy && !app.running) {
                    model.destination = .applications; model.previewApp(app.path)
                }
            }
        }
        return result.filter { action in query.isEmpty || query.split(separator: " ").allSatisfy { action.title.localizedCaseInsensitiveContains($0) } }
    }
    private func run(_ action: Action) {
        guard action.enabled else { return }
        model.showCommands = false; action.perform()
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search actions, quit or uninstall an app…", text: $query).textFieldStyle(.plain).focused($searching)
                    .onSubmit { if let action = actions.first(where: { $0.id == selection }) ?? actions.first { run(action) } }
                Button("Close") { model.showCommands = false }.keyboardShortcut(.escape, modifiers: []).buttonStyle(.borderless)
            }.padding(18)
            Divider()
            if actions.isEmpty { ContentUnavailableView.search(text: query).frame(height: 260) }
            else {
                List(actions, selection: $selection) { action in
                    Button { run(action) } label: {
                        Label(action.title, systemImage: action.symbol).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!action.enabled).tag(action.id)
                }.listStyle(.inset).frame(height: 310)
            }
            Text("Local actions · ⌘K · Type “quit” or “uninstall” to find an app")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.frame(width: 540)
            .task { searching = true; await model.sampleProcesses(); if model.apps.isEmpty { model.loadApps() } }
            .onChange(of: query) { _, _ in selection = actions.first?.id }
    }
}

struct MenuBarPanel: View {
    @Bindable var model: AppModel
    let presentation: MenuBarPresentation
    let openMain: () -> Void
    let openSettings: () -> Void
    private func open(_ destination: Destination) {
        model.destination = destination; openMain()
    }
    var body: some View {
        Group {
            if model.reviewFromMenu, let preview = model.review {
                ReviewSheet(model: model, plan: preview)
            } else {
                VStack(alignment: .leading, spacing: 17) {
                    HStack {
                        BleachMark().fill(style: FillStyle(eoFill: true)).frame(width: 20, height: 20).accessibilityHidden(true)
                        Text("Bleach").font(.headline)
                        if model.fixtureMode { Text("Fixture").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Open") { open(.clean) }.buttonStyle(.borderless)
                    }
                    if let sample = model.system {
                        DiskSpaceMeter(total: sample.diskTotal, available: sample.diskAvailable)
                        HStack {
                            resource("Memory", value: "\(Int(100 * Double(sample.memoryUsed) / Double(max(1, sample.memoryTotal))))%")
                            Spacer()
                            resource("CPU", value: sample.cpuPercent.map { "\(Int($0))%" } ?? "—")
                            Spacer()
                            resource("GPU", value: sample.gpuPercent.map { "\(Int($0))%" } ?? "—")
                        }
                    }
                    Divider()
                    HStack {
                        Text("Cleanup").font(.subheadline.weight(.medium))
                        Spacer()
                        Menu(model.cleanupLevel.rawValue) {
                            ForEach([CleanupLevel.light, .balanced, .thorough], id: \.self) { level in Button(level.rawValue) { model.selectLevel(level) } }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                    if let plan = model.plan, !plan.candidates.isEmpty {
                        ScrollView {
                            VStack(spacing: 13) {
                                ForEach(CleanupKind.allCases.filter { kind in plan.candidates.contains { $0.kind == kind } }) { kind in
                                    let values = plan.candidates.filter { $0.kind == kind && $0.recommendation != .blocked }
                                    let bindings = values.map { item in Binding(get: { model.selectedPaths.contains(item.path) }, set: { model.destination = .clean; model.toggle(item, selected: $0) }) }
                                    HStack(spacing: 9) {
                                        Toggle("Select \(kind.title)", sources: bindings, isOn: \.self).labelsHidden().toggleStyle(.checkbox).disabled(values.isEmpty || model.isBusy)
                                        CleanupKindIcon(kind: kind, size: 16)
                                        Text(kind.title).font(.subheadline)
                                        Spacer()
                                        Text(Display.bytes(values.reduce(0) { $0 + $1.privateBytes })).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }
                            }.padding(.vertical, 3)
                        }.frame(height: min(205, CGFloat(Set(plan.candidates.map(\.kind)).count) * 36))
                        Text("\(Display.bytes(StorageUsage.sum(plan.candidates.filter { model.selectedPaths.contains($0.path) }.map(\.storage)).privateBytes)) private selected").font(.caption).foregroundStyle(.secondary)
                    } else { Text("Scan to find unused caches and old files.").font(.subheadline).foregroundStyle(.secondary) }
                    HStack {
                        Button("Scan") { model.destination = .clean; model.scan() }.disabled(model.isBusy)
                        Spacer()
                        Button("Review Cleanup…") { model.destination = .clean; model.showReview(fromMenu: true) }
                            .disabled(model.selectedPaths.isEmpty || model.isBusy)
                    }
                    if let batch = model.lastBatch, batch.movedCount > 0 {
                        HStack {
                            Text("\(Display.items(batch.movedCount)) in Recovery").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Undo") { model.restore(batch) }.controlSize(.small).disabled(model.isBusy).help("Restore this cleanup (⌘Z)")
                        }
                    } else if model.lastBatch?.items.contains(where: { $0.state == .restored }) == true {
                        Text("Cleanup undone. Scan to refresh.").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.isBusy {
                        HStack { ProgressView().controlSize(.small); Text(model.work.label).font(.caption); if model.work.cancellable { Button("Cancel") { model.cancel() } } }
                    } else if let message = model.statusMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    HStack {
                        Text(model.automaticSettings.enabled ? "Auto · \(model.autoStatus)" : "Auto cleanup off").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button(action: openSettings) { Image(systemName: "gearshape") }.buttonStyle(.plain).accessibilityLabel("Settings")
                        Button("Quit Bleach") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
                    }
                }.padding(20).frame(width: 360)
            }
        }.tint(.primary).accentColor(Color(nsColor: .labelColor)).task(id: model.menuBarPresentation) {
            guard model.menuBarPresentation == presentation else { return }
            await model.load()
            while !Task.isCancelled {
                await model.sampleSystem()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
            .onChange(of: model.review?.id) { _, _ in model.menuBar?.schedulePanelResize() }
            .onChange(of: model.lastBatch?.movedCount) { _, _ in model.menuBar?.schedulePanelResize() }
            .onExitCommand { model.menuBar?.dismiss() }
            .alert("Couldn’t finish", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }
    private func resource(_ title: String, value: String) -> some View {
        Button { model.resourceMetric = ResourceMetric(rawValue: title) ?? .memory; open(.system) } label: {
            VStack(alignment: .leading, spacing: 4) { Text(value).font(.title3.weight(.medium)).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }
        }.buttonStyle(.plain).accessibilityLabel("\(title), \(value). Open System")
    }
}
