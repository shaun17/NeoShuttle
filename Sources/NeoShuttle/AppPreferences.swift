import AppKit

/// Per-Mac app preferences, kept out of .shuttle.json because they aren't about the menu.
@MainActor
enum AppPreferences {
    private static let showDockIconKey = "ShowDockIcon"

    /// Off: NeoShuttle lives in the menu bar and shows a Dock icon only while settings are open.
    static var showDockIcon: Bool {
        get { UserDefaults.standard.bool(forKey: showDockIconKey) }
        set { UserDefaults.standard.set(newValue, forKey: showDockIconKey) }
    }

    /// The settings window always gets a Dock icon so it can be found with ⌘Tab.
    static func applyActivationPolicy(settingsOpen: Bool) {
        NSApp.setActivationPolicy(showDockIcon || settingsOpen ? .regular : .accessory)
    }
}
