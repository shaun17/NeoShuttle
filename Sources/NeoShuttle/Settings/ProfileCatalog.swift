import Foundation

/// The appearance profiles Terminal and iTerm know about, for the theme pickers.
enum ProfileCatalog {
    private static let terminalBuiltins =
        "/System/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings"

    /// Built-in profiles plus any the user created or changed; Terminal only stores the latter.
    static func terminalProfiles() -> [String] {
        var names = Set<String>()
        for file in (try? FileManager.default.contentsOfDirectory(atPath: terminalBuiltins)) ?? []
        where file.hasSuffix(".terminal") {
            names.insert(String(file.dropLast(".terminal".count)))
        }
        if let settings = preference("Window Settings", app: "com.apple.Terminal") as? [String: Any] {
            names.formUnion(settings.keys)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func terminalDefaultProfile() -> String? {
        preference("Default Window Settings", app: "com.apple.Terminal") as? String
    }

    /// Profiles from iTerm's preferences plus Dynamic Profiles, in iTerm's own order.
    static func iTermProfiles() -> [String] {
        var names: [String] = []
        if let bookmarks = preference("New Bookmarks", app: "com.googlecode.iterm2") as? [[String: Any]] {
            names += bookmarks.compactMap { $0["Name"] as? String }
        }
        let dynamic = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/iTerm2/DynamicProfiles")
        let files = (try? FileManager.default.contentsOfDirectory(at: dynamic, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file) else { continue }
            // Dynamic Profiles may be JSON or property lists.
            let object = (try? JSONSerialization.jsonObject(with: data))
                ?? (try? PropertyListSerialization.propertyList(from: data, format: nil))
            let profiles = (object as? [String: Any])?["Profiles"] as? [[String: Any]] ?? []
            names += profiles.compactMap { $0["Name"] as? String }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func preference(_ key: String, app: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, app as CFString)
    }
}
