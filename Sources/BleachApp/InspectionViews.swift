import BleachCore
import SwiftUI

struct SpaceView: View {
    @Bindable var model: AppModel
    @State private var showLargest = false

    var body: some View {
        if let report = model.disk {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(spacing: 10) {
                        Button("Back", systemImage: "chevron.left") { model.goBack() }.labelStyle(.iconOnly).disabled(model.diskBack.isEmpty || model.isBusy).help("Previous folder")
                        Text(Display.path(report.path, home: model.home)).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Choose Folder…") { model.chooseFolder(title: "Explore disk space") { model.analyze($0) } }.disabled(model.isBusy)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Display.bytes(report.allocatedBytes)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                        Text("allocated · \(report.fileCount.formatted()) files").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Picker("Display", selection: $showLargest) {
                        Text("Folders & Files").tag(false)
                        Text("Largest Files").tag(true)
                    }.pickerStyle(.segmented).frame(maxWidth: 300)
                }.padding(24)
                List(showLargest ? report.largestFiles : report.entries) { entry in
                    Button {
                        if entry.isDirectory && !showLargest { model.analyze(URL(fileURLWithPath: entry.path)) }
                        else { model.reveal(entry.path) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc").font(.title3.weight(.light)).foregroundStyle(.secondary).frame(width: 23).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(entry.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Spacer()
                                    Text(Display.bytes(entry.allocatedBytes)).font(.subheadline).monospacedDigit()
                                }
                                ProgressView(value: Double(entry.allocatedBytes), total: Double(max(1, (showLargest ? report.largestFiles : report.entries).first?.allocatedBytes ?? 1)))
                                    .tint(.secondary).accessibilityLabel("Relative allocated size")
                                if showLargest { Text(Display.path(entry.path, home: model.home)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            }
                            if entry.isDirectory && !showLargest { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true) }
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.isBusy)
                        .contextMenu { Button("Reveal in Finder") { model.reveal(entry.path) } }
                }.listStyle(.inset(alternatesRowBackgrounds: false))
                HStack {
                    Text("\(Display.bytes(report.logicalBytes)) logical · \(Display.duration(report.duration))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !report.complete { Label("Partial scan · \(report.issues.count) skipped", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary).help(report.issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")) }
                }.padding(.horizontal, 24).padding(.vertical, 14)
            }
        } else {
            EmptyState(symbol: "chart.bar.xaxis", title: "See where it goes.", message: "Explore folders by their actual disk allocation. Drill down to the files taking up room.") {
                HStack {
                    Button("Choose Folder…") { model.chooseFolder(title: "Explore disk space") { model.analyze($0) } }
                    Button("Explore Home") { model.analyze(model.home) }.buttonStyle(.borderedProminent)
                }.controlSize(.large).disabled(model.isBusy)
            }
        }
    }
}

struct DuplicatesView: View {
    @Bindable var model: AppModel
    var body: some View {
        if let report = model.duplicateReport {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("\(report.groups.count) duplicate groups").font(.title2.weight(.semibold))
                        Spacer()
                        Button("Choose Folder…") { chooseFolder() }.disabled(model.isBusy)
                    }
                    Text(Display.path(report.path, home: model.home)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Text("\(report.filesHashed) files hashed · \(Display.duration(report.plan.duration))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Select Extra Copies") { model.duplicateSelection = Set(report.plan.candidates.map(\.path)) }.buttonStyle(.borderless).font(.caption).disabled(model.isBusy)
                    }
                }.padding(24)
                if report.plan.candidates.isEmpty {
                    EmptyState(symbol: "square.on.square", title: report.groups.isEmpty ? "No duplicates found" : "No extra copies to review",
                        message: "Only files with matching full contents are grouped. Hard links, app data and cloud placeholders are excluded.") {
                        Button("Choose Another Folder…") { chooseFolder() }.disabled(model.isBusy)
                    }
                } else {
                    List(selection: $model.focusedCandidate) {
                        ForEach(report.groups.filter { group in report.plan.candidates.contains { $0.duplicateProof?.sha256 == group.sha256 } }) { group in
                            Section("\(Display.bytes(group.bytesPerFile)) each · \(group.files.count) identical copies") {
                                ForEach(group.files, id: \.self) { path in
                                    if path == group.files.first {
                                        HStack(spacing: 11) {
                                            Image(systemName: "checkmark").foregroundStyle(.secondary).frame(width: 17).accessibilityHidden(true)
                                            duplicateLabel(path)
                                            Spacer()
                                            Text("Kept").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                        }.padding(.vertical, 7)
                                    } else if let candidate = report.plan.candidates.first(where: { $0.path == path }) {
                                        HStack(spacing: 11) {
                                            Toggle("Select \(candidate.title)", isOn: Binding(get: { model.duplicateSelection.contains(path) }, set: { model.toggle(candidate, selected: $0) }))
                                                .labelsHidden().toggleStyle(.checkbox).disabled(model.isBusy)
                                            duplicateLabel(path)
                                            Spacer()
                                            Button("Keep This") { model.keepDuplicate(path) }.buttonStyle(.borderless).font(.caption).disabled(model.isBusy)
                                        }.padding(.vertical, 7).tag(path)
                                            .contextMenu { Button("Reveal in Finder") { model.reveal(path) } }
                                    }
                                }
                            }
                        }
                    }.listStyle(.inset)
                }
                SelectionBar(model: model)
            }
        } else {
            EmptyState(symbol: "square.on.square", title: "Same file. Less space.",
                message: "Compare complete file contents, keep the copy you want, and review the extras. Nothing is selected for you.") {
                Button("Choose Folder…") { chooseFolder() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isBusy)
            }
        }
    }
    private func chooseFolder() { model.chooseFolder(title: "Find duplicate files") { model.compare($0) } }
    private func duplicateLabel(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(URL(fileURLWithPath: path).lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(Display.path(path, home: model.home)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

struct ApplicationsView: View {
    @Bindable var model: AppModel
    private var visibleApps: [InstalledApp] {
        model.apps.filter { model.search.isEmpty || $0.name.localizedCaseInsensitiveContains(model.search) || $0.bundleID.localizedCaseInsensitiveContains(model.search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            if let plan = model.uninstall {
                VStack(alignment: .leading, spacing: 13) {
                    Button("Applications", systemImage: "chevron.left") { model.uninstall = nil; model.focusedCandidate = nil }.buttonStyle(.borderless)
                    Text(plan.candidates.first(where: { $0.rule == .application })?.title ?? "Review removal").font(.title2.weight(.semibold))
                    Text("The app is selected. Personal data is a separate choice; keep it to preserve your setup.").font(.subheadline).foregroundStyle(.secondary)
                    if let issue = plan.issues.first { Text(issue.message).font(.caption).foregroundStyle(.secondary) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                CandidateTable(model: model, candidates: plan.candidates.sorted(using: model.sortOrder))
                SelectionBar(model: model)
            } else {
                HStack {
                    Text("\(model.apps.count) applications").font(.title2.weight(.semibold))
                    Spacer()
                    if let path = model.appSelection, let app = model.apps.first(where: { $0.path == path }) {
                        Button("Review Removal…") { model.previewApp(path) }
                            .buttonStyle(.borderedProminent).disabled(!app.removable || app.running || model.isBusy)
                            .help(app.running ? "Quit the app before removing it" : "Review app and exact related files")
                    }
                }.padding(24)
                Table(visibleApps, selection: $model.appSelection) {
                    TableColumn("Application") { app in
                        HStack(spacing: 12) {
                            Image(systemName: "app").font(.title2.weight(.ultraLight)).foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name).font(.subheadline.weight(.medium))
                                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 7).contextMenu { Button("Reveal in Finder") { model.reveal(app.path) } }
                    }.width(min: 220, ideal: 350)
                    TableColumn("Version") { Text($0.version).font(.subheadline).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                    TableColumn("State") { app in Text(app.running ? "Running" : app.removable ? "" : "Protected").font(.caption).foregroundStyle(.secondary) }.width(90)
                }.tableStyle(.inset(alternatesRowBackgrounds: true))
                    .searchable(text: $model.search, placement: .toolbar, prompt: "Find an app")
                HStack {
                    Text("System apps and shared app-group data are protected.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 24).padding(.vertical, 15)
            }
        }
    }
}
