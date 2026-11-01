import BleachCore
import SwiftUI

struct GrowthView: View {
    @Bindable var model: AppModel

    private var folderActions: some View {
        HStack {
            Menu("Agent Storage") {
                Button("Codex") { model.measureGrowth(model.home.appendingPathComponent(".codex")) }
                Button("T3") { model.measureGrowth(model.home.appendingPathComponent(".t3")) }
            }
            Button("Choose Folder…") { model.chooseFolder(title: "Measure storage growth") { model.measureGrowth($0) } }
        }.disabled(model.isBusy)
    }

    var body: some View {
        if let report = model.growthReport {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(Display.path(report.path, home: model.home)).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        folderActions
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(report.privateChange.map { change($0) } ?? Display.bytes(report.storage.privateBytes)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                        Text(report.privateChange == nil ? "private baseline" : "private change").font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("\(Display.bytes(report.storage.privateBytes)) private · \(Display.bytes(report.availableOnVolume)) available on volume").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(report.previousDate == nil ? "Capture Again" : "Save New Baseline") {
                            if let root = model.growthRoot { model.measureGrowth(root) }
                        }.disabled(model.isBusy)
                    }
                    if report.path.contains("/.codex") || report.path.contains("/.t3") {
                        Text("Measurement only. Sessions, chat context and databases stay intact.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24)
                List(report.entries) { entry in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: entry.path).lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(entry.current?.details ?? "No longer present").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(Display.bytes(entry.current?.privateBytes ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                        Text(change(entry.privateChange)).monospacedDigit().frame(minWidth: 80, alignment: .trailing)
                    }.padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(URL(fileURLWithPath: entry.path).lastPathComponent), \(Display.bytes(entry.current?.privateBytes ?? 0)) private, \(entry.privateChange.map { change($0) + " change" } ?? "no previous measurement")")
                        .contextMenu { Button("Reveal in Finder") { model.reveal(entry.path) } }
                }.listStyle(.inset(alternatesRowBackgrounds: false))
                VStack(alignment: .leading, spacing: 5) {
                    Text(report.previousDate.map { "Compared with \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "First measurement. Capture again after working to see what grew.")
                    Text(report.recorded ? "Baseline saved locally. Up to 8 folders; metadata only." : "Baseline unchanged. Partial scans are never saved.")
                    if !report.issues.isEmpty { Label("Partial scan · \(report.issues.count) skipped", systemImage: "exclamationmark.circle").help(report.issues.map(\.message).joined(separator: "\n")) }
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
        } else {
            EmptyState(symbol: "chart.line.uptrend.xyaxis", title: "Find what grew.", message: "Capture a folder now, then compare after working. Private and shared storage are measured separately. File contents and chat history stay untouched.") {
                folderActions.controlSize(.large)
            }
        }
    }

    private func change(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return (bytes >= 0 ? "+" : "−") + Display.bytes(abs(bytes))
    }
}
