import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let store: ConfigEditorStore

    init(launcher: Launcher) {
        store = ConfigEditorStore(launcher: launcher)
        let hosting = NSHostingController(rootView: SettingsView(store: store))
        hosting.sizingOptions = [.minSize]
        // Lets the SwiftUI .toolbar (the page switcher) appear in the window's title bar.
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.title = "NeoShuttle 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.setContentSize(Self.defaultSize)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("NeoShuttleSettings")
        super.init(window: window)
        window.delegate = self
        store.closeWindow = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let defaultSize = NSSize(width: 900, height: 600)

    func show() {
        resetSizeIfOversized()
        // Pick up edits made in a text editor since the window was last open.
        if !store.isDirty { store.reload() } else { store.refreshSSHHosts() }
        AppPreferences.applyActivationPolicy(settingsOpen: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Under cooperative activation (macOS 14+) a menu-bar app's NSApp.activate() is
        // refused while another app is frontmost, and Stage Manager then parks the new
        // window in its side strip. Activation through LaunchServices is honoured.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, _ in
            Task { @MainActor in
                self?.window?.makeKeyAndOrderFront(nil)
                self?.clearInitialFocus()
            }
        }
        clearInitialFocus()
    }

    /// AppKit focuses the first text field of a newly key window and selects its text,
    /// so a stray key press would replace e.g. the default theme. Start with nothing focused.
    private func clearInitialFocus() {
        window?.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(nil)
        }
    }

    /// A remembered size taller than the screen (or nearly) comes back at the default size.
    private func resetSizeIfOversized() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        guard window.frame.height > visible.height * 0.9 || window.frame.width > visible.width * 0.95 else { return }
        window.setContentSize(Self.defaultSize)
        window.center()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard store.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "保存对配置的修改吗？"
        alert.informativeText = "不保存的话，这些修改会丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return store.save()
        case .alertSecondButtonReturn:
            store.revert()
            return true
        default: return false
        }
    }

    /// Coming back from editing ~/.ssh/config in another app shows the changes right away.
    func windowDidBecomeKey(_ notification: Notification) {
        // After the focus change settles, not while AppKit is mid-update.
        DispatchQueue.main.async { [store] in
            store.refreshSSHHosts()
            store.refreshProfiles()
        }
    }

    func windowWillClose(_ notification: Notification) {
        AppPreferences.applyActivationPolicy(settingsOpen: false)
    }
}
