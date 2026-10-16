import Foundation

/// A terminal application NeoShuttle has a dedicated adapter for.
public enum TerminalKind: String, Sendable, CaseIterable {
    case terminal = "Terminal"
    case iTerm = "iTerm"
    case ghostty = "Ghostty"
    case seedmux = "Seedmux"
    case warp = "Warp"
    case kitty = "kitty"
    case wezTerm = "WezTerm"
    case alacritty = "Alacritty"

    /// Accepts the spellings people actually put in `.shuttle.json`:
    /// "Terminal.app", "iTerm", "iTerm2", "Ghostty.app", "seedmux" …
    public init?(configValue: String) {
        switch TerminalName.normalize(configValue) {
        case "terminal", "apple terminal": self = .terminal
        case "iterm", "iterm2": self = .iTerm
        case "ghostty": self = .ghostty
        case "seedmux": self = .seedmux
        case "warp": self = .warp
        case "kitty": self = .kitty
        case "wezterm": self = .wezTerm
        case "alacritty": self = .alacritty
        default: return nil
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .seedmux: "com.xx.seedmux"
        case .warp: "dev.warp.Warp-Stable"
        case .kitty: "net.kovidgoyal.kitty"
        case .wezTerm: "com.github.wez.wezterm"
        case .alacritty: "org.alacritty"
        }
    }

    /// The `.app` bundle name, used when the bundle identifier isn't registered.
    public var appName: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        case .ghostty: "Ghostty"
        case .seedmux: "Seedmux"
        case .warp: "Warp"
        case .kitty: "kitty"
        case .wezTerm: "WezTerm"
        case .alacritty: "Alacritty"
        }
    }
}

/// A terminal described in `custom_terminals`, for apps without a dedicated adapter.
public struct CustomTerminal: Sendable, Equatable {
    public enum Method: Sendable, Equatable {
        /// A shell command line with `{cmd}` and `{title}` placeholders (shell-quoted on expansion).
        case launch(template: String)
        /// Bring `app` forward, press ⌘N / ⌘T, wait `delay` seconds, then type the command.
        case keystroke(app: String, delay: Double)
    }

    public var name: String
    public var method: Method

    public init(name: String, method: Method) {
        self.name = name
        self.method = method
    }

    /// Fills `{cmd}` and `{title}`, each as a single shell word.
    public static func expand(_ template: String, command: String, title: String) -> String {
        template
            .replacingOccurrences(of: "{cmd}", with: ShellQuote.quote(command))
            .replacingOccurrences(of: "{title}", with: ShellQuote.quote(title))
    }
}

/// What a request runs in: a built-in adapter or a user-defined terminal.
public enum TerminalTarget: Sendable, Equatable {
    case builtin(TerminalKind)
    case custom(CustomTerminal)

    public var displayName: String {
        switch self {
        case .builtin(let kind): kind.rawValue
        case .custom(let custom): custom.name
        }
    }
}

enum TerminalName {
    static func normalize(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix(".app") { value.removeLast(4) }
        return value
    }
}

/// Where a command opens, the original `inTerminal` / `open_in` values plus `split`.
public enum OpenMode: String, Sendable, CaseIterable {
    case new
    case tab
    case current
    case split

    public init?(configValue: String) {
        switch configValue.trimmingCharacters(in: .whitespaces).lowercased() {
        case "new", "window": self = .new
        case "tab": self = .tab
        case "current": self = .current
        case "split": self = .split
        default: return nil
        }
    }
}
