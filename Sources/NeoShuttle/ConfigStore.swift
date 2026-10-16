import Foundation
import NeoShuttleCore

/// Locates and loads `.shuttle.json` the way the original Shuttle did.
enum ConfigStore {
    static let home = URL(fileURLWithPath: NSHomeDirectory())

    /// `~/.shuttle.path` may hold the path to the real config file.
    static var configURL: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["NEOSHUTTLE_CONFIG"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        let pointer = home.appendingPathComponent(".shuttle.path")
        if let text = try? String(contentsOf: pointer, encoding: .utf8) {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
        }
        return home.appendingPathComponent(".shuttle.json")
    }

    static var alternateURL: URL { home.appendingPathComponent(".shuttle-alt.json") }
    static var sshConfigPath: String { home.appendingPathComponent(".ssh/config").path }

    static func load() throws -> ShuttleConfig {
        let url = configURL
        try createDefaultIfMissing(at: url)
        let data = try Data(contentsOf: url)
        let alternate = try? Data(contentsOf: alternateURL)
        return try ShuttleConfig.parse(data, alternate: alternate) {
            SSHConfig.hosts(atPath: sshConfigPath)
        }
    }

    /// Never touches an existing file.
    static func createDefaultIfMissing(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try Data(DefaultConfig.json.utf8).write(to: url, options: .withoutOverwriting)
    }
}

enum DefaultConfig {
    static let json = """
    {
      "_comments": [
        "terminal: Terminal | iTerm | Ghostty | Seedmux | Warp | kitty | WezTerm | Alacritty，或 custom_terminals 里的名字；单个条目也可以写 \\"terminal\\" 覆盖",
        "custom_terminals: launch 模板用 {cmd} / {title} 占位；没有命令行接口的终端可用 \\"keystroke\\": true 模拟按键（需辅助功能权限）",
        "inTerminal / open_in: new | tab | current | split",
        "editor: default 表示用系统默认应用打开；写应用名或 bundle id（如 Cursor、Zed、Visual Studio Code）就用该应用打开；写 vi、nano 等则在终端里编辑",
        "名称前缀 [aaa] 控制排序且不显示，[---] 会在该项后加分隔线"
      ],
      "editor": "default",
      "terminal": "Ghostty",
      "default_theme": "",
      "open_in": "tab",
      "show_ssh_config_hosts": true,
      "ssh_config_ignore_hosts": [],
      "ssh_config_ignore_keywords": [],
      "custom_terminals": {
        "Rio": { "launch": "open -na Rio --args -e /bin/zsh -lic {cmd}" }
      },
      "hosts": [
        {
          "Examples": [
            { "name": "List processes", "cmd": "ps aux | head" },
            { "name": "Open in Seedmux", "cmd": "uptime", "terminal": "Seedmux", "inTerminal": "tab" },
            { "name": "Split in Ghostty", "cmd": "top", "terminal": "Ghostty", "inTerminal": "split" }
          ]
        }
      ]
    }

    """
}
