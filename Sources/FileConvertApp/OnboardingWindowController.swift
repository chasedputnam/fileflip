import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?

    func presentIfNeeded(model: FileConvertViewModel) {
        guard model.state.folders.isEmpty, model.state.status != .blocked, window == nil else { return }
        let root = OnboardingView().environment(model)
        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to FileFlip"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.setFrameAutosaveName("FileConvertOnboarding")
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
    }

    func dismissWhenAuthorized(model: FileConvertViewModel) {
        guard !model.state.folders.isEmpty else { return }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
