// Disposable app for verifying real Quit/Force Quit UI without touching user apps.
import AppKit
import Metal

@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var buffer: (any MTLBuffer)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        buffer = MTLCreateSystemDefaultDevice()?.makeBuffer(length: 32 * 1024 * 1024, options: .storageModeShared)
        if let buffer { memset(buffer.contents(), 37, buffer.length) }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 110), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Bleach Resource Probe · disposable"
        let label = NSTextField(wrappingLabelWithString: "Disposable verification app holding a 32 MB Metal buffer. Quit it from Bleach.")
        label.frame = NSRect(x: 20, y: 20, width: 320, height: 70)
        window.contentView?.addSubview(label)
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = ProbeDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
withExtendedLifetime(delegate) { application.run() }
