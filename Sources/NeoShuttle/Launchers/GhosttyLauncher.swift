import AppKit
import NeoShuttleCore

/// Ghostty 1.3+ AppleScript. The command is typed into the user's shell via
/// `initial input`, so the shell stays open after the command exits, like Terminal.
@MainActor
enum GhosttyLauncher {
    static func run(_ request: TerminalRequest) throws {
        let wasRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: TerminalKind.ghostty.bundleIdentifier).isEmpty
        // A freshly launched Ghostty already opened a window; use it instead of adding another.
        var request = request
        if !wasRunning { request.mode = .current }
        try AppleScriptRunner.run(script(request), app: "Ghostty")
    }

    static func script(_ request: TerminalRequest) -> String {
        let command = AppleScriptText.literal(request.command)
        let newWindow = "new window with configuration cfg"
        let body: [String] = switch request.mode {
        case .new:
            [newWindow]
        case .tab:
            ["if (count of windows) is 0 then", newWindow, "else",
             "new tab in front window with configuration cfg", "end if"]
        case .split:
            ["if (count of windows) is 0 then", newWindow, "else",
             "split (focused terminal of selected tab of front window) direction right with configuration cfg",
             "end if"]
        case .current:
            // `input text` is a paste, so Return is sent as a separate key press.
            ["if (count of windows) is 0 then", newWindow, "else",
             "set t to focused terminal of selected tab of front window",
             "input text \(command) to t",
             #"send key "enter" to t"#,
             "end if"]
        }
        return ([
            #"tell application "Ghostty""#,
            "activate",
            "set cfg to new surface configuration",
            "set initial input of cfg to \(command) & linefeed",
        ] + body + ["end tell"]).joined(separator: "\n")
    }
}
