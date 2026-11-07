import AppKit
import BleachCore
import SwiftUI

@main struct BleachApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(BleachAppDelegate.self) private var appDelegate
    init() {
        NSApplication.shared.applicationIconImage = BleachIcon.image()
        if let index = CommandLine.arguments.firstIndex(of: "--appearance"), index + 1 < CommandLine.arguments.count {
            NSApplication.shared.appearance = NSAppearance(named: CommandLine.arguments[index + 1] == "dark" ? .darkAqua : .aqua)
        }
    }
    var body: some Scene {
        Window("Bleach", id: "main") { Workspace(model: model) }
            .defaultSize(width: 1100, height: 740)
            .windowToolbarStyle(.unifiedCompact)
            .commands {
                CommandGroup(replacing: .undoRedo) {
                    Button("Undo Cleanup") { if let batch = model.latestRecoverable { model.restore(batch) } }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(model.latestRecoverable == nil || model.isBusy)
                }
                CommandMenu("Cleanup") {
                    Button("Actions…") { model.showCommands = true }.keyboardShortcut("k", modifiers: .command)
                    Button("Menu Bar Cleanup") { model.menuBar?.show() }.keyboardShortcut("m", modifiers: [.command, .shift])
                    Button("Scan Your Mac") { model.destination = .clean; model.scan() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.isBusy)
                    Button("Find More Space") { model.destination = .clean; model.findMoreSpace() }
                        .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(model.isBusy)
                    Button("Inactive Projects") { model.destination = .clean; model.reviewInactiveProjects() }.disabled(model.isBusy)
                    Button("Growth") { model.destination = .growth }
                    Button("Review Selection…") { model.showReview() }.keyboardShortcut(.return, modifiers: .command).disabled(model.selectedCandidates.isEmpty || model.isBusy)
                    Button("Delete Selection Permanently…", role: .destructive) { model.showReview(permanently: true) }.disabled(model.selectedCandidates.isEmpty || model.isBusy)
                    Divider()
                    Button("Recovery") { model.destination = .recovery }.keyboardShortcut("2", modifiers: .command)
                    Button("Clean up") { model.destination = .clean }.keyboardShortcut("1", modifiers: .command)
                }
                if model.fixtureMode {
                    CommandMenu("Verification") {
                        Button("Measure Fixture Growth") { model.measureGrowth(model.home.appendingPathComponent("Projects")) }.disabled(model.isBusy)
                        Button("Compare Fixture Captures") { model.destination = .duplicates; model.compare(model.home.appendingPathComponent("Projects/Captures")) }.disabled(model.isBusy)
                        Button("Compact Window") { NSApp.keyWindow?.setContentSize(NSSize(width: 880, height: 580)) }
                            .keyboardShortcut("0", modifiers: [.command, .shift])
                        Button("Standard Window") { NSApp.keyWindow?.setContentSize(NSSize(width: 1100, height: 740)) }
                            .keyboardShortcut("9", modifiers: [.command, .shift])
                    }
                }
            }
        Settings { SettingsView(model: model).tint(.primary) }
    }
}

@MainActor final class BleachAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
