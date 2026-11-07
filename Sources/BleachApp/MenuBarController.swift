import AppKit
import SwiftUI

@MainActor final class MenuBarController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let model: AppModel
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var panel: CleanupPanel?
    private var resizeTask: Task<Void, Never>?
    private let openMain: () -> Void
    private let openSettings: () -> Void

    init(model: AppModel, openMain: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.model = model; self.openMain = openMain; self.openSettings = openSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = BleachIcon.menuBarImage()
            button.toolTip = "Bleach · storage and resources"
            button.setAccessibilityLabel("Bleach")
            button.target = self; button.action = #selector(togglePopover(_:))
        }
        popover.contentViewController = hosting(.popover)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    private func hosting(_ presentation: MenuBarPresentation) -> NSHostingController<MenuBarPanel> {
        let controller = NSHostingController(rootView: root(presentation))
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    private func root(_ presentation: MenuBarPresentation) -> MenuBarPanel {
        MenuBarPanel(model: model, presentation: presentation, openMain: { [weak self] in
            self?.dismiss(); self?.openMain()
        }, openSettings: { [weak self] in
            self?.dismiss(); self?.openSettings(); NSApp.activate(ignoringOtherApps: true)
        })
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown || panel?.isVisible == true { dismiss() } else { show() }
    }

    func show() {
        // A hidden/unavailable menu bar can give the status item a zero-height
        // anchor. Keep the same cleanup controls reachable through the menu.
        if let button = item.button, let window = button.window, window.frame.height > 1, button.bounds.height > 1 {
            model.menuBarPresentation = .popover
            if let view = popover.contentViewController?.view {
                view.layoutSubtreeIfNeeded()
                let size = view.fittingSize
                if size.width > 0 && size.height > 0 { popover.contentSize = size }
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if popover.isShown { recordFixtureState("popover"); return }
        }
        showPanel()
    }

    private func showPanel() {
        if panel == nil {
            let window = CleanupPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                                      styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            window.title = "Bleach menu bar"
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.level = .floating
            window.delegate = self
            let host = NSHostingView(rootView: root(.panel))
            // The panel owns its size. Do not feed SwiftUI's intrinsic-size
            // updates back into AppKit while swapping overview/review views.
            host.sizingOptions = []
            window.contentView = host
            panel = window
        }
        model.menuBarPresentation = .panel
        fitPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeMain()
        recordFixtureState("panel")
    }

    func fitPanel() {
        guard let panel else { return }
        let review = model.reviewFromMenu && model.review != nil
        let height: CGFloat = review ? 620 : (model.lastBatch == nil ? 600 : 640)
        let screen = panel.screen ?? NSScreen.main
        let target = NSSize(width: review ? 520 : 360, height: min(height, (screen?.visibleFrame.height ?? 900) - 60))
        if panel.contentView?.bounds.size != target { panel.setContentSize(target) }
        if let frame = screen?.visibleFrame {
            let origin = NSPoint(x: frame.maxX - panel.frame.width - 12, y: frame.maxY - panel.frame.height - 12)
            if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        } else { panel.center() }
    }

    func schedulePanelResize() {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.fitPanel()
        }
    }

    func dismiss() {
        popover.performClose(nil); panel?.close(); model.menuBarPresentation = .hidden
    }
    func popoverDidClose(_ notification: Notification) {
        if model.menuBarPresentation == .popover { model.menuBarPresentation = .hidden }
    }
    func windowWillClose(_ notification: Notification) {
        if model.menuBarPresentation == .panel { model.menuBarPresentation = .hidden }
    }
    private func recordFixtureState(_ stage: String) {
        guard model.fixtureMode else { return }
        let value: [String: Any] = ["stage": stage, "shown": popover.isShown,
            "buttonWindowVisible": item.button?.window?.isVisible ?? false,
            "buttonFrame": item.button?.window.map { NSStringFromRect($0.frame) } ?? "none",
            "windows": NSApp.windows.map { ["id": $0.windowNumber, "title": $0.title, "visible": $0.isVisible, "key": $0.isKeyWindow, "frame": NSStringFromRect($0.frame)] as [String: Any] }]
        do { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: model.state.appendingPathComponent("menu-bar-ui.json"), options: .atomic) }
        catch { FileHandle.standardError.write(Data("Could not record fixture menu-bar state: \(error.localizedDescription)\n".utf8)) }
    }
}

@MainActor private final class CleanupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
