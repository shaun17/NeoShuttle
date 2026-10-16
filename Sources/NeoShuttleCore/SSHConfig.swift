import Foundation

/// A `Host` entry from ssh_config. `name` comes from a `# shuttle.name` comment when present.
public struct SSHHost: Sendable, Equatable {
    public var alias: String
    public var name: String
    /// Options set inside this Host block, keyed by lowercased keyword; the first value wins, as in ssh.
    public var options: [String: String]
    /// The file the Host line is in (it may come from an `Include`).
    public var file: String

    public init(alias: String, name: String, options: [String: String] = [:], file: String = "") {
        self.alias = alias
        self.name = name
        self.options = options
        self.file = file
    }
}

public enum SSHConfig {
    /// Reads `path` and any `Include`d files. Missing files yield no hosts.
    public static func hosts(atPath path: String) -> [SSHHost] {
        var visited = Set<String>()
        return hosts(atPath: (path as NSString).expandingTildeInPath, visited: &visited)
    }

    static func hosts(atPath path: String, visited: inout Set<String>) -> [SSHHost] {
        let standardized = (path as NSString).standardizingPath
        guard visited.insert(standardized).inserted,
              let text = try? String(contentsOfFile: standardized, encoding: .utf8)
        else { return [] }
        return parse(text, file: standardized, includeBase: sshDirectory, visited: &visited)
    }

    /// ssh resolves relative `Include` paths in the user config against ~/.ssh.
    static var sshDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
    }

    static func parse(_ text: String, file: String = "", includeBase: String, visited: inout Set<String>) -> [SSHHost] {
        var hosts: [SSHHost] = []
        // Index of the Host block options currently apply to; nil before the first Host and inside Match.
        var current: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = trimmed.wholeMatch(of: #/(#?)[ \t]*([^ \t=]+)[ \t=]+(.*)/#) else { continue }
            let isComment = !match.1.isEmpty
            let keyword = String(match.2)
            let value = String(match.3).trimmingCharacters(in: .whitespaces)

            if isComment {
                if keyword == "shuttle.name", !value.isEmpty, let current {
                    hosts[current].name = value
                }
                continue
            }

            switch keyword.lowercased() {
            case "host":
                let aliases = value.split(whereSeparator: \.isWhitespace)
                if let first = aliases.first {
                    hosts.append(SSHHost(alias: String(first), name: String(first), file: file))
                    current = hosts.count - 1
                } else {
                    current = nil
                }
            case "match":
                current = nil
            case "include":
                for pattern in value.split(whereSeparator: \.isWhitespace) {
                    var expanded = (String(pattern) as NSString).expandingTildeInPath
                    if !expanded.hasPrefix("/") {
                        expanded = (includeBase as NSString).appendingPathComponent(expanded)
                    }
                    for path in glob(expanded) {
                        hosts += Self.hosts(atPath: path, visited: &visited)
                    }
                }
            default:
                if let current, hosts[current].options[keyword.lowercased()] == nil {
                    hosts[current].options[keyword.lowercased()] = value
                }
            }
        }
        return hosts
    }

    static func glob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { String(cString: $0) }
        }
    }
}
