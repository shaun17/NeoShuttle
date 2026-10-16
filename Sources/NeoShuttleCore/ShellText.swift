import Foundation

public enum AppleScriptText {
    /// A quoted AppleScript string literal for arbitrary text.
    public static func literal(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

public enum ShellQuote {
    /// One POSIX shell word, safe for any content.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum LoginShell {
    /// argv that runs `command` in an interactive login shell and then stays in that shell,
    /// for terminals that take a program to run rather than text to type.
    /// A newline (not `;`) separates the two so a trailing `# comment` can't swallow the `exec`.
    public static func arguments(running command: String, shell: String) -> [String] {
        [shell, "-l", "-i", "-c", "\(command)\nexec \(ShellQuote.quote(shell)) -l"]
    }
}

/// Warp only runs commands through launch configurations, opened by their `name`.
public enum WarpLaunchConfig {
    public static func yaml(name: String, title: String, command: String, directory: String) -> String {
        """
        ---
        name: \(scalar(name))
        windows:
          - tabs:
              - title: \(scalar(title))
                layout:
                  cwd: \(scalar(directory))
                  commands:
                    - exec: \(scalar(command))

        """
    }

    /// A JSON string is a valid YAML double-quoted scalar.
    static func scalar(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(text), let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }
}

/// Reads a captured terminal screen to decide when a fresh shell can take input.
/// Ported from the shuttle-seedmux helper, which learned these cases the hard way.
public enum ShellPrompt {
    /// True when the last non-blank line looks like an idle prompt
    /// (oh-my-zsh `➜ dir`, starship `❯`, or anything ending in `$ # % > ~`).
    public static func isReady(_ capture: String) -> Bool {
        guard let line = lastLine(capture) else { return false }
        return line.wholeMatch(of: #/(?:[ \t]*(?:➜|❯)(?:[ \t]+[^\n]*)?|[^\n]*(?:[$#%>❯]\s*|~\s*))/#) != nil
    }

    /// oh-my-zsh's update question would swallow the first byte of the command.
    public static func isAskingToUpdate(_ capture: String) -> Bool {
        capture.contains(#/(?i)Would you like to\s+update\?\s*\[Y\/n\]/#)
    }

    static func lastLine(_ capture: String) -> String? {
        var text = Substring(capture)
        while let last = text.last, last.isWhitespace { text.removeLast() }
        guard !text.isEmpty else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init)
    }
}
