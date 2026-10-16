import Foundation

/// One runnable menu entry.
public struct HostEntry: Sendable, Equatable {
    public var name: String
    public var command: String
    public var mode: OpenMode?
    public var theme: String?
    public var title: String?
    public var terminal: TerminalTarget?

    public init(
        name: String,
        command: String,
        mode: OpenMode? = nil,
        theme: String? = nil,
        title: String? = nil,
        terminal: TerminalTarget? = nil
    ) {
        self.name = name
        self.command = command
        self.mode = mode
        self.theme = theme
        self.title = title
        self.terminal = terminal
    }
}

/// A menu row after sorting and decoration, ready to become an `NSMenuItem`.
public struct MenuNode: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case host(HostEntry)
        case group([MenuNode])
    }

    public var title: String
    public var separatorAfter: Bool
    public var kind: Kind

    public init(title: String, separatorAfter: Bool = false, kind: Kind) {
        self.title = title
        self.separatorAfter = separatorAfter
        self.kind = kind
    }
}

/// Shuttle's naming conventions: `[aaa]` sort prefixes are hidden and
/// `[---]` puts a separator after the item.
enum MenuTitle {
    static func decode(_ raw: String) -> (title: String, separatorAfter: Bool) {
        let separator = raw.contains(#/\[-{3}\]/#)
        let title = raw
            .replacing(#/\[[a-z]{3}\]/#, with: "")
            .replacing(#/\[-{3}\]/#, with: "")
        return (title, separator)
    }
}

/// The config tree before sorting, kept mutable so ssh_config hosts can be merged in.
enum RawNode {
    case leaf(rawName: String, entry: HostEntry)
    case group(rawName: String, children: [RawNode])

    var rawName: String {
        switch self {
        case .leaf(let name, _), .group(let name, _): name
        }
    }

    /// Inserts `entry` under the group path, creating groups as needed.
    static func insert(_ entry: HostEntry, rawName: String, path: ArraySlice<String>, into nodes: inout [RawNode]) {
        guard let head = path.first else {
            nodes.append(.leaf(rawName: rawName, entry: entry))
            return
        }
        for index in nodes.indices {
            guard case .group(let name, var children) = nodes[index], name == head else { continue }
            insert(entry, rawName: rawName, path: path.dropFirst(), into: &children)
            nodes[index] = .group(rawName: name, children: children)
            return
        }
        var children: [RawNode] = []
        insert(entry, rawName: rawName, path: path.dropFirst(), into: &children)
        nodes.append(.group(rawName: head, children: children))
    }

    /// Groups first, then leaves, each sorted case-insensitively by raw name,
    /// matching the original Shuttle. Same-named groups are merged.
    static func build(_ nodes: [RawNode]) -> [MenuNode] {
        var groupOrder: [String] = []
        var groups: [String: [RawNode]] = [:]
        var leaves: [(String, HostEntry)] = []
        for node in nodes {
            switch node {
            case .leaf(let name, let entry):
                leaves.append((name, entry))
            case .group(let name, let children):
                if groups[name] == nil { groupOrder.append(name) }
                groups[name, default: []].append(contentsOf: children)
            }
        }

        let byName: (String, String) -> Bool = { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var result: [MenuNode] = []
        for name in groupOrder.sorted(by: byName) {
            let decoded = MenuTitle.decode(name)
            result.append(MenuNode(
                title: decoded.title,
                separatorAfter: decoded.separatorAfter,
                kind: .group(build(groups[name] ?? []))
            ))
        }
        // Stable sort keeps duplicate names in file order.
        let sortedLeaves = leaves.enumerated().sorted { lhs, rhs in
            let order = lhs.element.0.localizedCaseInsensitiveCompare(rhs.element.0)
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }
        for (_, leaf) in sortedLeaves {
            let decoded = MenuTitle.decode(leaf.0)
            var entry = leaf.1
            entry.name = decoded.title
            result.append(MenuNode(title: decoded.title, separatorAfter: decoded.separatorAfter, kind: .host(entry)))
        }
        return result
    }
}
