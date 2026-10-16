import AppKit
import NeoShuttleCore

/// Terminal.app: `do script` for windows; tabs need ⌘T because Terminal can't script them.
@MainActor
enum TerminalAppLauncher {
    static func run(_ request: TerminalRequest) async throws {
        switch request.mode {
        case .new:
            try AppleScriptRunner.run(script(request, inFrontTab: false), app: "Terminal")
        case .current:
            try AppleScriptRunner.run(script(request, inFrontTab: true), app: "Terminal")
        case .tab, .split:
            let count = try AppleScriptRunner.run(
                "tell application \"Terminal\"\nactivate\nreturn count of windows\nend tell", app: "Terminal")
            let hasWindow = count.int32Value > 0
            if hasWindow, SystemInput.isTrusted(prompt: true),
               await SystemInput.pressCommandT(in: TerminalKind.terminal.bundleIdentifier) {
                try await Task.sleep(for: .milliseconds(300))
                try AppleScriptRunner.run(script(request, inFrontTab: true), app: "Terminal")
            } else {
                // Without Accessibility access a new window is the closest we can get.
                try AppleScriptRunner.run(script(request, inFrontTab: false), app: "Terminal")
            }
        }
    }

    static func script(_ request: TerminalRequest, inFrontTab: Bool) -> String {
        let command = AppleScriptText.literal(request.command)
        var lines = [#"tell application "Terminal""#, "activate"]
        if inFrontTab {
            lines += [
                "if (count of windows) is 0 then",
                "set t to do script \(command)",
                "else",
                "set t to do script \(command) in selected tab of front window",
                "end if",
            ]
        } else {
            lines.append("set t to do script \(command)")
        }
        if let theme = request.theme {
            lines += ["try", "set current settings of t to settings set \(AppleScriptText.literal(theme))", "end try"]
        }
        lines += ["try", "set custom title of t to \(AppleScriptText.literal(request.title))", "end try"]
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }
}
