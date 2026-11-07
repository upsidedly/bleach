import BleachCore
import SwiftUI

struct AutomaticSettingsView: View {
    @Bindable var model: AppModel
    @State private var confirmEnable = false
    var body: some View {
        Section("Automatic cleanup") {
            Toggle("Keep free space above a threshold", isOn: Binding(get: { model.automaticSettings.enabled }, set: { value in
                if value { confirmEnable = true } else { model.updateAutomatic { $0.enabled = false } }
            })).disabled(!model.automaticSettings.packageDownloads && !model.automaticSettings.oldLogs)
            HStack {
                Stepper("Free below \(model.automaticSettings.threshold)", value: Binding(get: { model.automaticSettings.threshold }, set: { value in model.updateAutomatic { $0.threshold = value } }), in: 1...(model.automaticSettings.unit == .percent ? 30 : 100))
                Picker("Unit", selection: Binding(get: { model.automaticSettings.unit }, set: { value in
                    model.updateAutomatic { $0.unit = value; $0.threshold = min($0.threshold, value == .percent ? 30 : 100) }
                })) { ForEach(AutomaticCleanupSettings.Unit.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 80)
            }
            Toggle("Unused package download archives", isOn: Binding(get: { model.automaticSettings.packageDownloads }, set: { value in model.updateAutomatic { $0.packageDownloads = value; if !value && !$0.oldLogs { $0.enabled = false } } }))
            Toggle("Logs unchanged for at least 90 days", isOn: Binding(get: { model.automaticSettings.oldLogs }, set: { value in model.updateAutomatic { $0.oldLogs = value; if !value && !$0.packageDownloads { $0.enabled = false } } }))
            Text("Only raw npm/Cargo downloads, pip HTTP downloads and old logs qualify. In-use, shared and unverified files stay. No app/browser caches, project output, dependencies, installers, app data or chat history. Downloads may need an internet connection again.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Runs once a minute while Bleach is open, including in the menu bar. Eligible files are permanently deleted, not kept for Undo.")
                .font(.caption).foregroundStyle(.secondary)
            if model.automaticSettings.enabled {
                HStack {
                    Text(model.autoStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.automaticSettings.pausedUntil.map { $0 > Date() } == true ? "Resume" : "Pause for 1 Hour") {
                        model.updateAutomatic { $0.pausedUntil = $0.pausedUntil.map { $0 > Date() } == true ? nil : Date().addingTimeInterval(3600) }
                    }.controlSize(.small)
                }
            }
        }
        .confirmationDialog("Enable automatic permanent deletion?", isPresented: $confirmEnable, titleVisibility: .visible) {
            Button("Enable Auto Cleanup", role: .destructive) { model.updateAutomatic { $0.enabled = true; $0.pausedUntil = nil } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("When disk space is low, Bleach can permanently erase the checked download caches and old logs after rechecking them. This cannot be undone. Source, project environments, history and existing Recovery batches remain protected.") }
    }
}
