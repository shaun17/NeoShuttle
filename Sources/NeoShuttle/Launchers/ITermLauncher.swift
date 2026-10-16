import Foundation
import NeoShuttleCore

/// iTerm2: windows, tabs and splits are all scriptable; `theme` selects a profile.
@MainActor
enum ITermLauncher {
    static func run(_ request: TerminalRequest) throws {
        try AppleScriptRunner.run(script(request), app: "iTerm")
    }

    static func script(_ request: TerminalRequest) -> String {
        let createWindow = withProfile(request.theme, "set w to (create window with %@)")
        let session: [String] = switch request.mode {
        case .new:
            createWindow + ["set s to current session of w"]
        case .tab:
            ["if (count of windows) is 0 then"] + createWindow + ["else", "tell current window"]
                + withProfile(request.theme, "create tab with %@")
                + ["end tell", "end if", "set s to current session of current window"]
        case .split:
            ["if (count of windows) is 0 then"] + createWindow
                + ["set s to current session of w", "else", "tell current session of current window"]
                + withProfile(request.theme, "set s to (split vertically with %@)")
                + ["end tell", "end if"]
        case .current:
            ["if (count of windows) is 0 then"] + createWindow
                + ["end if", "set s to current session of current window"]
        }
        return ([#"tell application "iTerm""#, "activate"] + session + [
            "tell s",
            "try",
            "set name to \(AppleScriptText.literal(request.title))",
            "end try",
            "write text \(AppleScriptText.literal(request.command))",
            "end tell",
            "end tell",
        ]).joined(separator: "\n")
    }

    /// Uses the named profile when it exists, otherwise the default profile.
    private static func withProfile(_ theme: String?, _ template: String) -> [String] {
        let fallback = template.replacingOccurrences(of: "%@", with: "default profile")
        guard let theme else { return [fallback] }
        let named = template.replacingOccurrences(of: "%@", with: "profile \(AppleScriptText.literal(theme))")
        return ["try", named, "on error", fallback, "end try"]
    }
}
