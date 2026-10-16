import Foundation

/// An editable view of `.shuttle.json` for the settings window. Unlike `ShuttleConfig`
/// it keeps the file's structure and every unknown key, so saving changes only what was edited.
public struct ConfigDocument: Sendable, Equatable {
    /// Top-level keys other than `hosts` and `custom_terminals`.
    public var settings: [String: JSONValue]
    public var hosts: [ConfigNode]
    public var customTerminals: [CustomTerminalSpec]

    public init(settings: [String: JSONValue] = [:], hosts: [ConfigNode] = [], customTerminals: [CustomTerminalSpec] = []) {
        self.settings = settings
        self.hosts = hosts
        self.customTerminals = customTerminals
    }

    public init(data: Data) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            throw ShuttleConfig.ParseError.invalidJSON(reason ?? error.localizedDescription)
        }
        guard case .object(var root) = JSONValue(any: value) else { throw ShuttleConfig.ParseError.notAnObject }
        hosts = Self.nodes(from: root.removeValue(forKey: "hosts")?.arrayValue ?? [])
        customTerminals = (root.removeValue(forKey: "custom_terminals")?.objectValue ?? [:])
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { CustomTerminalSpec(name: $0.key, object: $0.value.objectValue ?? [:]) }
        settings = root
    }

    public func serialized() -> Data {
        var root = settings
        root["hosts"] = .array(hosts.map(\.json))
        if !customTerminals.isEmpty {
            var table: [String: JSONValue] = [:]
            for terminal in customTerminals { table[terminal.name] = .object(terminal.json) }
            root["custom_terminals"] = .object(table)
        }
        return Data(JSONWriter.write(.object(root)).utf8)
    }

    private static func nodes(from items: [JSONValue]) -> [ConfigNode] {
        var nodes: [ConfigNode] = []
        for item in items {
            guard let object = item.objectValue else { continue }
            if object["name"]?.stringValue != nil, object["cmd"]?.stringValue != nil {
                nodes.append(.entry(ConfigEntry(object: object)))
                continue
            }
            for key in object.keys.sorted() {
                guard let children = object[key]?.arrayValue else { continue }
                nodes.append(.group(ConfigGroup(name: key, children: Self.nodes(from: children))))
            }
        }
        return nodes
    }

    // MARK: Settings

    public func string(_ key: String) -> String? { settings[key]?.stringValue }

    /// Empty strings remove the key, so untouched files don't grow empty fields.
    public mutating func setString(_ key: String, _ value: String?) {
        if let value, !value.isEmpty { settings[key] = .string(value) } else { settings[key] = nil }
    }

    public func bool(_ key: String) -> Bool? { settings[key]?.boolValue }

    public mutating func setBool(_ key: String, _ value: Bool) { settings[key] = .bool(value) }

    public func strings(_ key: String) -> [String] {
        settings[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    public mutating func setStrings(_ key: String, _ values: [String]) {
        settings[key] = .array(values.map(JSONValue.string))
    }

    // MARK: Tree

    public func node(_ id: UUID) -> ConfigNode? {
        Self.find(id, in: hosts)
    }

    public func entry(_ id: UUID) -> ConfigEntry? {
        if case .entry(let entry) = node(id) { entry } else { nil }
    }

    public func group(_ id: UUID) -> ConfigGroup? {
        if case .group(let group) = node(id) { group } else { nil }
    }

    /// `nil` for top-level nodes; `.none` when `id` doesn't exist is folded into `nil` too.
    public func parentGroup(of id: UUID) -> UUID? {
        Self.parent(of: id, in: hosts, parent: nil) ?? nil
    }

    public mutating func updateEntry(_ id: UUID, _ change: (inout ConfigEntry) -> Void) {
        Self.update(id, in: &hosts) { node in
            if case .entry(var entry) = node {
                change(&entry)
                node = .entry(entry)
            }
        }
    }

    public mutating func updateGroup(_ id: UUID, _ change: (inout ConfigGroup) -> Void) {
        Self.update(id, in: &hosts) { node in
            if case .group(var group) = node {
                change(&group)
                node = .group(group)
            }
        }
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> ConfigNode? {
        Self.remove(id, from: &hosts)
    }

    /// Appends `node` to a group, or to the top level when `groupID` is nil or unknown.
    public mutating func insert(_ node: ConfigNode, into groupID: UUID?) {
        if let groupID, group(groupID) != nil {
            updateGroup(groupID) { $0.children.append(node) }
        } else {
            hosts.append(node)
        }
    }

    /// Refuses to move a group into itself or one of its descendants.
    public mutating func move(_ id: UUID, into groupID: UUID?) {
        guard let node = node(id) else { return }
        if let groupID {
            if groupID == id { return }
            if case .group(let group) = node, Self.find(groupID, in: group.children) != nil { return }
        }
        remove(id)
        insert(node, into: groupID)
    }

    /// Every group with its path ("Work / Servers"), in menu order, for "move to" pickers.
    public func groupPaths(excluding excluded: UUID? = nil) -> [(id: UUID, path: String)] {
        var result: [(UUID, String)] = []
        func walk(_ nodes: [ConfigNode], prefix: String) {
            for case .group(let group) in ConfigNode.menuOrder(nodes) where group.id != excluded {
                let path = prefix.isEmpty ? group.menuName.title : "\(prefix) / \(group.menuName.title)"
                result.append((group.id, path))
                walk(group.children, prefix: path)
            }
        }
        walk(hosts, prefix: "")
        return result.map { (id: $0.0, path: $0.1) }
    }

    /// Every entry in every group, in file order.
    public var allEntries: [ConfigEntry] {
        func collect(_ nodes: [ConfigNode]) -> [ConfigEntry] {
            nodes.flatMap { node -> [ConfigEntry] in
                switch node {
                case .entry(let entry): [entry]
                case .group(let group): collect(group.children)
                }
            }
        }
        return collect(hosts)
    }

    public mutating func updateAllEntries(_ change: (inout ConfigEntry) -> Void) {
        Self.forEachEntry(in: &hosts, change)
    }

    /// Renames a custom terminal and every reference to it.
    public mutating func renameCustomTerminal(_ id: UUID, to newName: String) {
        guard let index = customTerminals.firstIndex(where: { $0.id == id }) else { return }
        let old = TerminalName.normalize(customTerminals[index].name)
        customTerminals[index].name = newName
        if let current = string("terminal"), TerminalName.normalize(current) == old {
            setString("terminal", newName)
        }
        Self.forEachEntry(in: &hosts) { entry in
            if let terminal = entry.terminal, TerminalName.normalize(terminal) == old {
                entry.terminal = newName
            }
        }
    }

    private static func find(_ id: UUID, in nodes: [ConfigNode]) -> ConfigNode? {
        for node in nodes {
            if node.id == id { return node }
            if case .group(let group) = node, let found = find(id, in: group.children) { return found }
        }
        return nil
    }

    private static func parent(of id: UUID, in nodes: [ConfigNode], parent: UUID?) -> UUID?? {
        for node in nodes {
            if node.id == id { return .some(parent) }
            if case .group(let group) = node, let found = self.parent(of: id, in: group.children, parent: group.id) {
                return found
            }
        }
        return nil
    }

    private static func update(_ id: UUID, in nodes: inout [ConfigNode], _ change: (inout ConfigNode) -> Void) {
        for index in nodes.indices {
            if nodes[index].id == id {
                change(&nodes[index])
                return
            }
            if case .group(var group) = nodes[index], find(id, in: group.children) != nil {
                update(id, in: &group.children, change)
                nodes[index] = .group(group)
                return
            }
        }
    }

    private static func remove(_ id: UUID, from nodes: inout [ConfigNode]) -> ConfigNode? {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            return nodes.remove(at: index)
        }
        for index in nodes.indices {
            guard case .group(var group) = nodes[index], let removed = remove(id, from: &group.children) else { continue }
            nodes[index] = .group(group)
            return removed
        }
        return nil
    }

    private static func forEachEntry(in nodes: inout [ConfigNode], _ change: (inout ConfigEntry) -> Void) {
        for index in nodes.indices {
            switch nodes[index] {
            case .entry(var entry):
                change(&entry)
                nodes[index] = .entry(entry)
            case .group(var group):
                forEachEntry(in: &group.children, change)
                nodes[index] = .group(group)
            }
        }
    }
}

public enum ConfigNode: Sendable, Equatable, Identifiable {
    case entry(ConfigEntry)
    case group(ConfigGroup)

    public var id: UUID {
        switch self {
        case .entry(let entry): entry.id
        case .group(let group): group.id
        }
    }

    public var rawName: String {
        switch self {
        case .entry(let entry): entry.name
        case .group(let group): group.name
        }
    }

    var json: JSONValue {
        switch self {
        case .entry(let entry): .object(entry.json)
        case .group(let group): .object([group.name: .array(group.children.map(\.json))])
        }
    }

    /// Groups first, then entries, each by raw name: the order the menu shows.
    public static func menuOrder(_ nodes: [ConfigNode]) -> [ConfigNode] {
        let byName: (ConfigNode, ConfigNode) -> Bool = {
            $0.rawName.localizedCaseInsensitiveCompare($1.rawName) == .orderedAscending
        }
        let groups = nodes.filter { if case .group = $0 { true } else { false } }.sorted(by: byName)
        let entries = nodes.filter { if case .entry = $0 { true } else { false } }.sorted(by: byName)
        return groups + entries
    }
}

public struct ConfigEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Raw name, including any `[aaa]` / `[---]` markers; see `menuName`.
    public var name: String
    public var command: String
    /// Entries migrated by the old shuttle-seedmux bridge keep their real command in
    /// `seedmux_command`; edits go there so `cmd` (the bridge URL) stays valid for old Shuttle.
    public let commandKey: String
    public var terminal: String?
    public var mode: String?
    public var theme: String?
    public var title: String?
    var extra: [String: JSONValue]

    public init(name: String, command: String) {
        id = UUID()
        self.name = name
        self.command = command
        commandKey = "cmd"
        extra = [:]
    }

    init(object: [String: JSONValue]) {
        var rest = object
        id = UUID()
        name = rest.removeValue(forKey: "name")?.stringValue ?? ""
        if let seedmux = rest["seedmux_command"]?.stringValue, !seedmux.trimmingCharacters(in: .whitespaces).isEmpty {
            commandKey = "seedmux_command"
            command = seedmux
            rest["seedmux_command"] = nil
        } else {
            commandKey = "cmd"
            command = rest.removeValue(forKey: "cmd")?.stringValue ?? ""
        }
        terminal = rest.removeValue(forKey: "terminal")?.stringValue
        mode = rest.removeValue(forKey: "inTerminal")?.stringValue
        theme = rest.removeValue(forKey: "theme")?.stringValue
        title = rest.removeValue(forKey: "title")?.stringValue
        extra = rest
    }

    public var usesSeedmuxCommand: Bool { commandKey == "seedmux_command" }

    public var menuName: MenuName {
        get { MenuName(raw: name) }
        set { name = newValue.raw }
    }

    var json: [String: JSONValue] {
        var object = extra
        object["name"] = .string(name)
        object[commandKey] = .string(command)
        for (key, value) in [("terminal", terminal), ("inTerminal", mode), ("theme", theme), ("title", title)] {
            if let value, !value.isEmpty { object[key] = .string(value) } else { object[key] = nil }
        }
        return object
    }
}

public struct ConfigGroup: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var children: [ConfigNode]

    public init(name: String, children: [ConfigNode] = []) {
        id = UUID()
        self.name = name
        self.children = children
    }

    public var menuName: MenuName {
        get { MenuName(raw: name) }
        set { name = newValue.raw }
    }

    public var entryCount: Int {
        children.reduce(0) { count, node in
            switch node {
            case .entry: count + 1
            case .group(let group): count + group.entryCount
            }
        }
    }
}

public struct CustomTerminalSpec: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case launch
        case keystroke
    }

    public let id: UUID
    public var name: String
    public var kind: Kind
    public var launch: String
    public var app: String
    public var delay: Double
    var extra: [String: JSONValue]

    public init(name: String, kind: Kind = .launch, launch: String = "", app: String = "", delay: Double = 0.8) {
        id = UUID()
        self.name = name
        self.kind = kind
        self.launch = launch
        self.app = app
        self.delay = delay
        extra = [:]
    }

    init(name: String, object: [String: JSONValue]) {
        var rest = object
        id = UUID()
        self.name = name
        launch = rest.removeValue(forKey: "launch")?.stringValue ?? ""
        app = rest.removeValue(forKey: "app")?.stringValue ?? ""
        let keystroke = rest.removeValue(forKey: "keystroke")?.boolValue ?? false
        delay = rest.removeValue(forKey: "delay")?.numberValue ?? 0.8
        // Mirrors ShuttleConfig: a launch template wins over keystroke.
        kind = launch.trimmingCharacters(in: .whitespaces).isEmpty && keystroke ? .keystroke : .launch
        extra = rest
    }

    var json: [String: JSONValue] {
        var object = extra
        switch kind {
        case .launch:
            object["launch"] = .string(launch)
        case .keystroke:
            object["keystroke"] = .bool(true)
            if !app.isEmpty { object["app"] = .string(app) }
            object["delay"] = .number(delay)
        }
        return object
    }
}

/// A menu name split into the parts Shuttle encodes in it: `[abc]` sort key,
/// `[---]` separator marker and the visible title.
public struct MenuName: Sendable, Equatable {
    public var sortKey: String
    public var separatorAfter: Bool
    public var title: String

    public init(sortKey: String = "", separatorAfter: Bool = false, title: String) {
        self.sortKey = sortKey
        self.separatorAfter = separatorAfter
        self.title = title
    }

    public init(raw: String) {
        let decoded = MenuTitle.decode(raw)
        title = decoded.title
        separatorAfter = decoded.separatorAfter
        sortKey = raw.firstMatch(of: #/\[([a-z]{3})\]/#).map { String($0.1) } ?? ""
    }

    /// Only a valid three-letter key is written.
    public var raw: String {
        let key = sortKey.wholeMatch(of: #/[a-z]{3}/#) != nil ? "[\(sortKey)]" : ""
        return key + (separatorAfter ? "[---]" : "") + title
    }
}
