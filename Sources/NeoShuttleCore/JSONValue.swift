import Foundation

/// A JSON value that survives a read–edit–write cycle, so keys the editor doesn't
/// know about (`seedmux_id`, `iTerm_version`, `_comments` …) are written back untouched.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// Converts a `JSONSerialization` result.
    public init(any value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    public var numberValue: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }
}

/// Pretty-prints with a stable, human-friendly key order: well-known keys first
/// (`name` before `cmd`, `hosts` last), everything else alphabetically.
enum JSONWriter {
    static let keyPriority = [
        "_comments", "name", "cmd", "editor", "launch_at_login", "terminal", "iTerm_version",
        "default_theme", "open_in", "show_ssh_config_hosts", "ssh_config_ignore_hosts",
        "ssh_config_ignore_keywords", "custom_terminals", "launch", "app", "keystroke", "delay",
        "inTerminal", "theme", "title",
    ]

    static func write(_ value: JSONValue) -> String {
        var output = ""
        write(value, indent: 0, into: &output)
        return output + "\n"
    }

    static func orderedKeys(_ keys: some Collection<String>) -> [String] {
        keys.sorted { lhs, rhs in
            if lhs == "hosts" || rhs == "hosts" { return rhs == "hosts" && lhs != "hosts" }
            let left = keyPriority.firstIndex(of: lhs) ?? Int.max
            let right = keyPriority.firstIndex(of: rhs) ?? Int.max
            return left == right ? lhs < rhs : left < right
        }
    }

    private static func write(_ value: JSONValue, indent: Int, into output: inout String) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closingPad = String(repeating: "  ", count: indent)
        switch value {
        case .string(let string):
            output += quoted(string)
        case .number(let number):
            if number.rounded() == number, abs(number) < 1e15 {
                output += String(Int64(number))
            } else {
                output += String(number)
            }
        case .bool(let bool):
            output += bool ? "true" : "false"
        case .null:
            output += "null"
        case .array(let items):
            guard !items.isEmpty else { output += "[]"; return }
            output += "[\n"
            for (index, item) in items.enumerated() {
                output += pad
                write(item, indent: indent + 1, into: &output)
                output += index < items.count - 1 ? ",\n" : "\n"
            }
            output += closingPad + "]"
        case .object(let object):
            guard !object.isEmpty else { output += "{}"; return }
            output += "{\n"
            let keys = orderedKeys(object.keys)
            for (index, key) in keys.enumerated() {
                output += pad + quoted(key) + ": "
                write(object[key] ?? .null, indent: indent + 1, into: &output)
                output += index < keys.count - 1 ? ",\n" : "\n"
            }
            output += closingPad + "}"
        }
    }

    static func quoted(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(string), let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }
}
