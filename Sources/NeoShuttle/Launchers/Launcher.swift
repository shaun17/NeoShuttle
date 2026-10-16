import AppKit
import NeoShuttleCore

enum LaunchError: Error, LocalizedError {
    case notInstalled(String)
    case appleScript(app: String, message: String, code: Int)
    case accessibilityRequired(String)
    case commandFailed(String, String)
    case seedmux(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            "没有找到 \(name)，请先安装，或在配置中改用其他终端。"
        case .appleScript(let app, _, -1743):
            "macOS 未允许 NeoShuttle 控制 \(app)。请到 系统设置 › 隐私与安全性 › 自动化 中打开对应开关。"
        case .appleScript(let app, let message, let code):
            "\(app) 执行失败（\(code)）：\(message)"
        case .accessibilityRequired(let name):
            "\(name) 需要模拟按键。请到 系统设置 › 隐私与安全性 › 辅助功能 中允许 NeoShuttle，然后重试。"
        case .commandFailed(let name, let detail):
            "\(name) 启动失败：\(detail)"
        case .seedmux(let message):
            message
        }
    }
}

@MainActor
final class Launcher {
    private let seedmux = SeedmuxLauncher()

    func launch(_ action: LaunchAction) {
        Task {
            do {
                try await perform(action)
            } catch {
                Self.present(error)
            }
        }
    }

    private func perform(_ action: LaunchAction) async throws {
        switch action {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .run(let request):
            switch request.terminal {
            case .builtin(let kind):
                let app = try AppLocator.require(kind)
                switch kind {
                case .terminal: try await TerminalAppLauncher.run(request)
                case .iTerm: try ITermLauncher.run(request)
                case .ghostty: try GhosttyLauncher.run(request)
                case .seedmux: try await seedmux.run(request)
                case .warp: try await WarpLauncher.run(request, app: app)
                case .kitty: try await KittyLauncher.run(request, app: app)
                case .wezTerm: try await WezTermLauncher.run(request, app: app)
                case .alacritty: try await AlacrittyLauncher.run(request, app: app)
                }
            case .custom(let custom):
                try await CustomLauncher.run(request, terminal: custom)
            }
        }
    }

    static func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "NeoShuttle 无法执行命令"
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}

@MainActor
enum AppleScriptRunner {
    @discardableResult
    static func run(_ source: String, app: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw LaunchError.appleScript(app: app, message: "脚本无法创建", code: 0)
        }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            throw LaunchError.appleScript(
                app: app,
                message: info[NSAppleScript.errorMessage] as? String ?? "未知错误",
                code: info[NSAppleScript.errorNumber] as? Int ?? 0
            )
        }
        return result
    }
}

@MainActor
enum AppLocator {
    static func require(_ kind: TerminalKind) throws -> URL {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleIdentifier)
            ?? find(named: kind.appName) {
            return url
        }
        throw LaunchError.notInstalled(kind.rawValue)
    }

    /// `name` may be a bundle identifier or an app name such as "Hyper".
    static func find(named name: String) -> URL? {
        if name.contains("."), !name.hasSuffix(".app"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return url
        }
        let file = name.hasSuffix(".app") ? name : "\(name).app"
        let directories = ["/Applications", "\(NSHomeDirectory())/Applications",
                           "/System/Applications", "/System/Applications/Utilities"]
        return directories
            .map { URL(fileURLWithPath: $0).appendingPathComponent(file) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isInstalled(_ kind: TerminalKind) -> Bool {
        (try? require(kind)) != nil
    }

    static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func activate(_ url: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The user's login shell, which terminals are asked to run commands in.
    static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    let error: String

    var succeeded: Bool { status == 0 }
}

enum CommandRunner {
    /// Runs a CLI off the main thread. Output is expected to be small.
    static func run(
        _ executable: String,
        _ arguments: [String],
        input: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> CommandResult {
        try await Task.detached {
            try runBlocking(executable, arguments, input: input, timeout: timeout)
        }.value
    }

    private static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        input: String?,
        timeout: TimeInterval
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe(), error = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        let text = { (pipe: Pipe) in
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        return CommandResult(status: process.terminationStatus, output: text(output), error: text(error))
    }

    /// `open -na <app> --args …` starts a detached instance that outlives NeoShuttle.
    static func openNewInstance(_ app: URL, arguments: [String]) async throws {
        let result = try await run("/usr/bin/open", ["-na", app.path, "--args"] + arguments)
        guard result.succeeded else {
            throw LaunchError.commandFailed(app.deletingPathExtension().lastPathComponent, result.error)
        }
    }
}

/// Synthetic keyboard input for apps without a scriptable "new tab". Needs Accessibility access.
@MainActor
enum SystemInput {
    enum Key: CGKeyCode {
        case t = 0x11
        case n = 0x2D
        case returnKey = 0x24
    }

    /// Asks macOS to show the Accessibility prompt when not yet trusted.
    static func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    static func waitUntilFrontmost(_ bundleIdentifier: String, timeout: Duration = .seconds(3)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Brings the app forward and presses ⌘T in it.
    static func pressCommandT(in bundleIdentifier: String) async -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            app.activate()
        }
        guard await waitUntilFrontmost(bundleIdentifier) else { return false }
        press(.t, flags: .maskCommand)
        return true
    }

    static func press(_ key: Key, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Types text as Unicode key events, which bypasses the input method and the clipboard.
    static func type(_ text: String) async {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        // Key events carry at most 20 UTF-16 units each.
        for start in stride(from: 0, to: units.count, by: 20) {
            var chunk = Array(units[start..<min(start + 20, units.count)])
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
