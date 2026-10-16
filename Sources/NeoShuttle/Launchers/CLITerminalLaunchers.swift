import AppKit
import NeoShuttleCore

/// Warp can't be scripted; it runs commands only from launch configurations,
/// which it looks up by `name` in ~/.warp/launch_configurations. Each launch writes a
/// throwaway config there. Warp always opens a launch configuration in a new window.
@MainActor
enum WarpLauncher {
    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".warp/launch_configurations")
    static let filePrefix = "neoshuttle-"

    static func run(_ request: TerminalRequest, app: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeStaleConfigs()

        let id = UUID().uuidString.prefix(8).lowercased()
        let name = "neoshuttle-\(id)"
        let file = directory.appendingPathComponent("\(filePrefix)\(id).yaml")
        let yaml = WarpLaunchConfig.yaml(
            name: name, title: request.title, command: request.command, directory: NSHomeDirectory())
        try Data(yaml.utf8).write(to: file)

        if AppLocator.isRunning(TerminalKind.warp.bundleIdentifier) {
            // Warp's config watcher picks new files up within a few hundred milliseconds.
            try await Task.sleep(for: .milliseconds(500))
        } else {
            // A link that arrives while Warp is still loading its configs is dropped.
            await AppLocator.activate(app)
            try await Task.sleep(for: .seconds(3))
        }
        guard let url = URL(string: "warp://launch/\(name)") else { return }
        NSWorkspace.shared.open(url)
        Task {
            try? await Task.sleep(for: .seconds(15))
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Configs are only needed until Warp has read them.
    private static func removeStaleConfigs() {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-60)
        let files = (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix(filePrefix) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? manager.removeItem(at: file) }
        }
    }
}

/// kitty: remote control (`kitty @`) when `allow_remote_control` and `listen_on` are set,
/// otherwise a new window from a new instance.
@MainActor
enum KittyLauncher {
    static func run(_ request: TerminalRequest, app: URL) async throws {
        let kitty = app.appendingPathComponent("Contents/MacOS/kitty").path
        let shellArgs = LoginShell.arguments(running: request.command, shell: AppLocator.loginShell)

        for socket in sockets() {
            let remote = ["@", "--to", "unix:\(socket)"]
            let result: CommandResult = switch request.mode {
            case .current:
                // --stdin keeps kitty from interpreting backslash escapes in the command.
                try await CommandRunner.run(kitty, remote + ["send-text", "--match", "state:focused", "--stdin"],
                                            input: request.command + "\r")
            case .new:
                try await CommandRunner.run(kitty, remote + ["launch", "--type=os-window",
                                                             "--title", request.title] + shellArgs)
            case .tab:
                try await CommandRunner.run(kitty, remote + ["launch", "--type=tab", "--tab-title", request.title,
                                                             "--title", request.title] + shellArgs)
            case .split:
                try await CommandRunner.run(kitty, remote + ["launch", "--type=window", "--location=vsplit",
                                                             "--title", request.title] + shellArgs)
            }
            if result.succeeded {
                await AppLocator.activate(app)
                return
            }
        }
        try await CommandRunner.openNewInstance(app, arguments: ["--title", request.title] + shellArgs)
    }

    /// kitty appends `-<pid>` to the `listen_on` path; newest first.
    static func sockets() -> [String] {
        let manager = FileManager.default
        let candidates = ["/tmp", NSTemporaryDirectory()].flatMap { directory in
            ((try? manager.contentsOfDirectory(atPath: directory)) ?? [])
                .filter { $0.lowercased().contains("kitty") }
                .map { (directory as NSString).appendingPathComponent($0) }
        }
        return candidates
            .compactMap { path -> (String, Date)? in
                guard let attributes = try? manager.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeSocket
                else { return nil }
                return (path, attributes[.modificationDate] as? Date ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

/// WezTerm: `wezterm cli` against the running GUI, otherwise `wezterm start` in a new instance.
@MainActor
enum WezTermLauncher {
    static func run(_ request: TerminalRequest, app: URL) async throws {
        let wezterm = app.appendingPathComponent("Contents/MacOS/wezterm").path
        let cli = ["cli", "--no-auto-start"]
        let shellArgs = LoginShell.arguments(running: request.command, shell: AppLocator.loginShell)

        if let pane = try await focusedPane(wezterm, cli: cli) {
            let result: CommandResult = switch request.mode {
            case .current:
                try await CommandRunner.run(wezterm, cli + ["send-text", "--pane-id", pane, "--no-paste"],
                                            input: request.command + "\r")
            case .new:
                try await CommandRunner.run(wezterm, cli + ["spawn", "--new-window", "--"] + shellArgs)
            case .tab:
                try await CommandRunner.run(wezterm, cli + ["spawn", "--pane-id", pane, "--"] + shellArgs)
            case .split:
                try await CommandRunner.run(wezterm, cli + ["split-pane", "--pane-id", pane, "--right", "--"]
                                            + shellArgs)
            }
            if result.succeeded {
                let newPane = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if request.mode == .new || request.mode == .tab, !newPane.isEmpty {
                    _ = try? await CommandRunner.run(
                        wezterm, cli + ["set-tab-title", "--pane-id", newPane, request.title])
                }
                await AppLocator.activate(app)
                return
            }
        }
        try await CommandRunner.openNewInstance(app, arguments: ["start", "--"] + shellArgs)
    }

    private struct Client: Decodable {
        let focused_pane_id: Int?
    }

    /// nil when no GUI is running.
    private static func focusedPane(_ wezterm: String, cli: [String]) async throws -> String? {
        let result = try await CommandRunner.run(wezterm, cli + ["list-clients", "--format", "json"])
        guard result.succeeded,
              let clients = try? JSONDecoder().decode([Client].self, from: Data(result.output.utf8)),
              let pane = clients.compactMap(\.focused_pane_id).first
        else { return nil }
        return String(pane)
    }
}

/// Alacritty has no tabs or splits: every mode opens a window, through the running
/// instance's IPC socket when possible.
@MainActor
enum AlacrittyLauncher {
    static func run(_ request: TerminalRequest, app: URL) async throws {
        let alacritty = app.appendingPathComponent("Contents/MacOS/alacritty").path
        let shellArgs = LoginShell.arguments(running: request.command, shell: AppLocator.loginShell)
        let window = ["--title", request.title, "-e"] + shellArgs

        if AppLocator.isRunning(TerminalKind.alacritty.bundleIdentifier),
           try await CommandRunner.run(alacritty, ["msg", "create-window"] + window).succeeded {
            await AppLocator.activate(app)
            return
        }
        try await CommandRunner.openNewInstance(app, arguments: window)
    }
}

/// Terminals from `custom_terminals`.
@MainActor
enum CustomLauncher {
    static func run(_ request: TerminalRequest, terminal: CustomTerminal) async throws {
        switch terminal.method {
        case .launch(let template):
            let line = CustomTerminal.expand(template, command: request.command, title: request.title)
            // A login shell, so templates find CLIs installed by Homebrew and the like.
            let result = try await CommandRunner.run(AppLocator.loginShell, ["-l", "-c", line], timeout: 20)
            guard result.succeeded else {
                let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LaunchError.commandFailed(terminal.name, detail.isEmpty ? "退出码 \(result.status)" : detail)
            }
        case .keystroke(let appName, let delay):
            guard let app = AppLocator.find(named: appName),
                  let bundleIdentifier = Bundle(url: app)?.bundleIdentifier
            else { throw LaunchError.notInstalled(appName) }
            guard SystemInput.isTrusted(prompt: true) else { throw LaunchError.accessibilityRequired(terminal.name) }

            let wasRunning = AppLocator.isRunning(bundleIdentifier)
            await AppLocator.activate(app)
            guard await SystemInput.waitUntilFrontmost(bundleIdentifier, timeout: .seconds(10)) else {
                throw LaunchError.commandFailed(terminal.name, "没能切到前台，命令尚未发送。")
            }
            // A freshly launched terminal already has an empty window to type into.
            if wasRunning {
                switch request.mode {
                case .new: SystemInput.press(.n, flags: .maskCommand)
                case .tab, .split: SystemInput.press(.t, flags: .maskCommand)
                case .current: break
                }
            }
            try await Task.sleep(for: .seconds(wasRunning ? delay : max(delay, 2)))
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier else {
                throw LaunchError.commandFailed(terminal.name, "等待期间焦点切走了，命令尚未发送。")
            }
            await SystemInput.type(request.command)
            SystemInput.press(.returnKey)
        }
    }
}
