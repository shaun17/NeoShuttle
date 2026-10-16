import AppKit
import NeoShuttleCore

/// Seedmux has no AppleScript or URL scheme; it is driven through its local team bridge
/// (`~/Library/Application Support/Seedmux/team-bridge.json`).
///
/// - `new` / `tab`: ⌘T opens a real tab, then the command is sent once its shell shows a prompt.
/// - `split`: the bridge's `/spawn` splits the focused tab (no Accessibility access needed).
/// - `current`: typed into the focused pane, unless an agent is running there.
@MainActor
final class SeedmuxLauncher {
    private let bundleIdentifier = TerminalKind.seedmux.bundleIdentifier
    private var busy = false

    func run(_ request: TerminalRequest) async throws {
        // Two overlapping ⌘T launches couldn't tell which new pane is theirs.
        guard !busy else { throw LaunchError.seedmux("上一个 Seedmux 启动还没完成，请稍后再试。") }
        busy = true
        defer { busy = false }

        let bridge = try await startAndConnect()
        switch request.mode {
        case .split:
            try await bridge.spawn(launch: request.command)
        case .current:
            let panes = try await bridge.panes()
            if let pane = panes.first(where: { $0.focused == true }), pane.agent == nil {
                activateSeedmux()
                try await bridge.send(request.command, to: pane.paneId)
            } else {
                try await openTab(bridge, command: request.command)
            }
        case .new, .tab:
            try await openTab(bridge, command: request.command)
        }
    }

    private func openTab(_ bridge: SeedmuxBridge, command: String) async throws {
        guard SystemInput.isTrusted(prompt: true) else {
            // Still run the command; a split is the best we can do without key events.
            try await bridge.spawn(launch: command)
            return
        }
        let before = Set(try await bridge.panes().map(\.paneId))
        guard await SystemInput.pressCommandT(in: bundleIdentifier) else {
            throw LaunchError.seedmux("Seedmux 没能切到前台，命令尚未发送。")
        }
        let pane = try await waitForNewPane(bridge, excluding: before)
        try await waitForPrompt(bridge, pane: pane)
        // Never retried: a send that timed out may already have started a login.
        try await bridge.send(command, to: pane)
    }

    private func startAndConnect() async throws -> SeedmuxBridge {
        activateSeedmux()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        while clock.now < deadline {
            if let bridge = try? SeedmuxBridge.load(), (try? await bridge.panes()) != nil {
                return bridge
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LaunchError.seedmux("Seedmux 本地控制接口未就绪。请确认 Seedmux 已启动，并在设置 › Agent Team 中保持本地桥开启。")
    }

    private func activateSeedmux() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func waitForNewPane(_ bridge: SeedmuxBridge, excluding before: Set<String>) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        while clock.now < deadline {
            let created = try await bridge.panes().map(\.paneId).filter { !before.contains($0) }
            if created.count == 1 { return created[0] }
            if created.count > 1 {
                throw LaunchError.seedmux("同时出现了多个新面板，无法确定哪个是本次 ⌘T 创建的；命令尚未发送。")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LaunchError.seedmux("⌘T 后 20 秒内没有出现新的 Seedmux 页签；命令尚未发送。")
    }

    private func waitForPrompt(_ bridge: SeedmuxBridge, pane: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        var answeredUpdate = false
        while clock.now < deadline {
            let screen = try await bridge.capture(pane: pane)
            if !answeredUpdate, ShellPrompt.isAskingToUpdate(screen) {
                try await bridge.send("n", to: pane)
                answeredUpdate = true
            } else if ShellPrompt.isReady(screen) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LaunchError.seedmux("Seedmux 新页签的 shell 在 20 秒内没有就绪；命令尚未发送。")
    }
}

struct SeedmuxBridge: Sendable {
    let port: Int
    let token: String

    struct Pane: Decodable, Sendable {
        let paneId: String
        let agent: String?
        let focused: Bool?
    }

    private struct BridgeFile: Decodable {
        let port: Int
        let token: String
        let pid: Int32?
    }

    private struct Reply: Decodable {
        let ok: Bool
        let panes: [Pane]?
        let text: String?
        let paneId: String?
        let error: String?
    }

    static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Seedmux/team-bridge.json")
    }

    static func load() throws -> SeedmuxBridge {
        let file = try JSONDecoder().decode(BridgeFile.self, from: Data(contentsOf: configURL))
        guard (1...65535).contains(file.port), !file.token.isEmpty, !file.token.contains(where: \.isNewline)
        else { throw LaunchError.seedmux("Seedmux 本地桥配置无效。") }
        // A stale file from a previous run points at a dead process.
        if let pid = file.pid, kill(pid, 0) != 0 {
            throw LaunchError.seedmux("Seedmux 本地桥未运行。")
        }
        return SeedmuxBridge(port: file.port, token: file.token)
    }

    func panes() async throws -> [Pane] {
        try await request("/panes").panes ?? []
    }

    func capture(pane: String) async throws -> String {
        var components = URLComponents()
        components.path = "/capture"
        components.queryItems = [URLQueryItem(name: "pane", value: pane), URLQueryItem(name: "lines", value: "40")]
        return try await request(components.string ?? "/capture").text ?? ""
    }

    func send(_ text: String, to pane: String) async throws {
        _ = try await request("/send", body: ["to": .string(pane), "text": .string(text), "enter": .bool(true)])
    }

    func spawn(launch command: String) async throws {
        _ = try await request("/spawn", body: [
            "direction": .string("right"), "launch": .string(command), "focus": .bool(true),
        ])
    }

    private enum Value: Encodable {
        case string(String)
        case bool(Bool)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            }
        }
    }

    private func request(_ path: String, body: [String: Value]? = nil) async throws -> Reply {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw LaunchError.seedmux("Seedmux 请求地址无效。")
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue(token, forHTTPHeaderField: "X-Token")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, _) = try await Self.session.data(for: request)
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.ok else {
            throw LaunchError.seedmux("Seedmux 拒绝了请求 \(path)：\(reply.error ?? "未知原因")")
        }
        return reply
    }

    /// The bridge token must never go through a configured HTTP proxy.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()
}
