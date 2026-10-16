import Foundation

/// `.shuttle.json`, read with the same rules as the original Shuttle plus a few
/// additions: more built-in terminals, `custom_terminals`, a per-entry `terminal`
/// override, `inTerminal: "split"`, and `seedmux_command` taking precedence over `cmd`.
public struct ShuttleConfig: Sendable {
    public var terminal: TerminalTarget
    public var customTerminals: [CustomTerminal]
    public var openIn: OpenMode
    public var defaultTheme: String?
    public var editor: String
    public var showSSHConfigHosts: Bool
    public var ignoreHosts: [String]
    public var ignoreKeywords: [String]
    public var menu: [MenuNode]
    /// Problems worth showing at the top of the menu; the config still loads.
    public var warnings: [String]

    public enum ParseError: Error, LocalizedError, Equatable {
        case invalidJSON(String)
        case notAnObject

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let reason): "JSON 格式错误：\(reason)"
            case .notAnObject: "顶层必须是 JSON 对象"
            }
        }
    }

    /// - Parameters:
    ///   - alternate: `~/.shuttle-alt.json`; only its `hosts` are used, appended to the main list.
    ///   - sshHosts: called only when `show_ssh_config_hosts` is on.
    public static func parse(
        _ data: Data,
        alternate: Data? = nil,
        sshHosts: () -> [SSHHost] = { [] }
    ) throws -> ShuttleConfig {
        let json = try object(from: data)
        var warnings: [String] = []

        let customTerminals = parseCustomTerminals(json["custom_terminals"], warnings: &warnings)
        let resolve = { (name: String) in resolveTerminal(name, customTerminals: customTerminals) }

        let terminalSetting = json["terminal"] as? String ?? "Terminal.app"
        let terminal: TerminalTarget
        if let resolved = resolve(terminalSetting) {
            terminal = resolved
        } else {
            // The original treated anything that wasn't iTerm as Terminal.app.
            terminal = .builtin(.terminal)
            warnings.append("不支持的终端 “\(terminalSetting)”，已改用 Terminal；可在 custom_terminals 中定义它")
        }
        // Like the original, only "tab" and "new" are valid defaults; anything else means "tab".
        let openIn: OpenMode = switch (json["open_in"] as? String).flatMap(OpenMode.init(configValue:)) {
        case .new: .new
        default: .tab
        }
        let editor = (json["editor"] as? String).flatMap(\.nonEmpty) ?? "default"
        let showSSH = json["show_ssh_config_hosts"] as? Bool ?? true
        let ignoreHosts = json["ssh_config_ignore_hosts"] as? [String] ?? []
        let ignoreKeywords = json["ssh_config_ignore_keywords"] as? [String] ?? []

        var nodes = parseNodes(json["hosts"] as? [Any] ?? [], resolve: resolve, warnings: &warnings)
        if let alternate, let altJSON = try? object(from: alternate) {
            nodes += parseNodes(altJSON["hosts"] as? [Any] ?? [], resolve: resolve, warnings: &warnings)
        }

        if showSSH {
            for host in sshHosts() {
                guard let placement = sshMenuPlacement(host, ignoreHosts: ignoreHosts, ignoreKeywords: ignoreKeywords)
                else { continue }
                let entry = HostEntry(name: placement.leaf, command: "ssh \(host.alias)")
                RawNode.insert(entry, rawName: placement.leaf, path: placement.groups[...], into: &nodes)
            }
        }

        return ShuttleConfig(
            terminal: terminal,
            customTerminals: customTerminals,
            openIn: openIn,
            defaultTheme: (json["default_theme"] as? String).flatMap(\.nonEmpty),
            editor: editor,
            showSSHConfigHosts: showSSH,
            ignoreHosts: ignoreHosts,
            ignoreKeywords: ignoreKeywords,
            menu: RawNode.build(nodes),
            warnings: warnings
        )
    }

    /// Where an ssh_config host appears in the menu: the group names from the `/`-separated
    /// name, then the item title. nil when the host is a pattern, hidden, or ignored.
    public static func sshMenuPlacement(
        _ host: SSHHost,
        ignoreHosts: [String],
        ignoreKeywords: [String]
    ) -> (groups: [String], leaf: String)? {
        let name = host.name
        guard !name.contains("*"), !name.contains("?"), !name.contains("!"),
              !name.hasPrefix("."),
              !ignoreHosts.contains(name),
              !ignoreKeywords.contains(where: { !$0.isEmpty && name.contains($0) })
        else { return nil }
        var groups = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let leaf = groups.popLast(), !leaf.isEmpty else { return nil }
        return (groups, leaf)
    }

    /// Custom terminals win over built-in adapters of the same name.
    public func resolveTerminal(_ name: String) -> TerminalTarget? {
        Self.resolveTerminal(name, customTerminals: customTerminals)
    }

    static func resolveTerminal(_ name: String, customTerminals: [CustomTerminal]) -> TerminalTarget? {
        if let custom = customTerminals.first(where: {
            TerminalName.normalize($0.name) == TerminalName.normalize(name)
        }) {
            return .custom(custom)
        }
        return TerminalKind(configValue: name).map(TerminalTarget.builtin)
    }

    private static func object(from data: Data) throws -> [String: Any] {
        let value: Any
        do {
            // JSON5 tolerates the trailing commas and comments hand-edited files tend to grow.
            value = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            throw ParseError.invalidJSON(reason ?? error.localizedDescription)
        }
        guard let object = value as? [String: Any] else { throw ParseError.notAnObject }
        return object
    }

    /// `"custom_terminals": { "Rio": { "launch": "…{cmd}…" }, "Hyper": { "app": "Hyper", "keystroke": true } }`
    private static func parseCustomTerminals(_ value: Any?, warnings: inout [String]) -> [CustomTerminal] {
        guard let value else { return [] }
        guard let table = value as? [String: Any] else {
            warnings.append("custom_terminals 必须是对象")
            return []
        }
        var result: [CustomTerminal] = []
        for name in table.keys.sorted() {
            let spec = table[name] as? [String: Any] ?? [:]
            if let template = (spec["launch"] as? String).flatMap(\.nonEmpty) {
                if !template.contains("{cmd}") {
                    warnings.append("自定义终端 “\(name)” 的 launch 里没有 {cmd}，命令不会被传入")
                }
                result.append(CustomTerminal(name: name, method: .launch(template: template)))
            } else if spec["keystroke"] as? Bool == true {
                let app = (spec["app"] as? String).flatMap(\.nonEmpty) ?? name
                let delay = (spec["delay"] as? Double).map { min(max($0, 0), 10) } ?? 0.8
                result.append(CustomTerminal(name: name, method: .keystroke(app: app, delay: delay)))
            } else {
                warnings.append("自定义终端 “\(name)” 需要 launch 模板，或 \"keystroke\": true")
            }
        }
        return result
    }

    private static func parseNodes(
        _ items: [Any],
        resolve: (String) -> TerminalTarget?,
        warnings: inout [String]
    ) -> [RawNode] {
        var nodes: [RawNode] = []
        for case let item as [String: Any] in items {
            if let name = item["name"] as? String, let cmd = item["cmd"] as? String {
                // seedmux_command is what the old shuttle-seedmux:// bridge really ran.
                let command = (item["seedmux_command"] as? String).flatMap(\.nonEmpty) ?? cmd
                var terminal: TerminalTarget?
                if let setting = (item["terminal"] as? String).flatMap(\.nonEmpty) {
                    terminal = resolve(setting)
                    if terminal == nil {
                        warnings.append("“\(name)” 的终端 “\(setting)” 不支持，已改用默认终端")
                    }
                }
                let entry = HostEntry(
                    name: name,
                    command: command,
                    mode: (item["inTerminal"] as? String).flatMap(OpenMode.init(configValue:)),
                    theme: (item["theme"] as? String).flatMap(\.nonEmpty),
                    title: (item["title"] as? String).flatMap(\.nonEmpty),
                    terminal: terminal
                )
                nodes.append(.leaf(rawName: name, entry: entry))
                continue
            }
            for key in item.keys.sorted() {
                guard let children = item[key] as? [Any] else { continue }
                nodes.append(.group(rawName: key, children: parseNodes(children, resolve: resolve, warnings: &warnings)))
            }
        }
        return nodes
    }
}

/// What clicking a host should do, with every default resolved.
public enum LaunchAction: Sendable, Equatable {
    case openURL(URL)
    case run(TerminalRequest)
}

public struct TerminalRequest: Sendable, Equatable {
    public var terminal: TerminalTarget
    public var command: String
    public var mode: OpenMode
    public var theme: String?
    public var title: String

    public init(terminal: TerminalTarget, command: String, mode: OpenMode, theme: String?, title: String) {
        self.terminal = terminal
        self.command = command
        self.mode = mode
        self.theme = theme
        self.title = title
    }
}

extension ShuttleConfig {
    public func action(for host: HostEntry) -> LaunchAction {
        let command = host.command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Like the original, a bare URL is opened instead of typed into a terminal.
        if command.wholeMatch(of: #/[A-Za-z][A-Za-z0-9+.\-]*:\/\/\S+/#) != nil,
           let url = URL(string: command) {
            return .openURL(url)
        }
        return .run(TerminalRequest(
            terminal: host.terminal ?? terminal,
            command: host.command,
            mode: host.mode ?? openIn,
            theme: host.theme ?? defaultTheme,
            title: host.title ?? host.name
        ))
    }
}

extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
