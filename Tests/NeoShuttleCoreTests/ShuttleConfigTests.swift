import XCTest
@testable import NeoShuttleCore

final class ShuttleConfigTests: XCTestCase {
    private func parse(_ json: String, ssh: [SSHHost] = []) throws -> ShuttleConfig {
        try ShuttleConfig.parse(Data(json.utf8)) { ssh }
    }

    private func titles(_ nodes: [MenuNode]) -> [String] { nodes.map(\.title) }

    private func children(_ node: MenuNode) -> [MenuNode] {
        guard case .group(let children) = node.kind else { XCTFail("\(node.title) is not a group"); return [] }
        return children
    }

    private func host(_ node: MenuNode) -> HostEntry? {
        guard case .host(let entry) = node.kind else { return nil }
        return entry
    }

    func testOriginalDefaultConfigParses() throws {
        let config = try parse("""
        {
          "editor": "default", "launch_at_login": false, "terminal": "Terminal.app",
          "iTerm_version": "nightly", "default_theme": "Homebrew", "open_in": "new",
          "show_ssh_config_hosts": false, "ssh_config_ignore_hosts": [  ], "ssh_config_ignore_keywords": [  ],
          "hosts": [
            { "cmd": "ps aux | grep defaults", "name": "Grep" },
            { "Spouses Servers": [
                { "cmd": "ps", "inTerminal": "current", "name": "Logs" },
                { "Jane’s Servers": [
                    { "cmd": "ssh username@blog2.example.com", "inTerminal": "tab", "name": "SSH blog", "theme": "basic", "title": "title of tab" }
                ] }
            ] }
          ]
        }
        """)
        XCTAssertEqual(config.terminal, .builtin(.terminal))
        XCTAssertEqual(config.openIn, .new)
        XCTAssertEqual(config.defaultTheme, "Homebrew")
        XCTAssertFalse(config.showSSHConfigHosts)
        XCTAssertEqual(titles(config.menu), ["Spouses Servers", "Grep"], "groups come before leaves")
        let spouses = children(config.menu[0])
        XCTAssertEqual(titles(spouses), ["Jane’s Servers", "Logs"])
        let blog = try XCTUnwrap(host(children(spouses[0])[0]))
        XCTAssertEqual(blog.mode, .tab)
        XCTAssertEqual(blog.theme, "basic")
        XCTAssertEqual(blog.title, "title of tab")
    }

    func testTrailingCommasAndCommentsAreTolerated() throws {
        let config = try parse("""
        {
          // hand-edited
          "terminal": "Ghostty",
          "hosts": [ { "name": "a", "cmd": "ls", }, ],
        }
        """)
        XCTAssertEqual(config.terminal, .builtin(.ghostty))
        XCTAssertEqual(titles(config.menu), ["a"])
    }

    func testInvalidJSONReportsError() {
        XCTAssertThrowsError(try parse("{ \"hosts\": [ }")) { error in
            guard case ShuttleConfig.ParseError.invalidJSON = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try parse("[]")) { error in
            XCTAssertEqual(error as? ShuttleConfig.ParseError, .notAnObject)
        }
    }

    func testSeedmuxCommandReplacesBridgeURL() throws {
        let config = try parse("""
        { "terminal": "Seedmux.app", "show_ssh_config_hosts": false, "hosts": [
          { "name": "jump", "cmd": "shuttle-seedmux://run/example-id", "seedmux_id": "example-id",
            "seedmux_command": "expect ~/bin/jump.exp", "inTerminal": "new" }
        ] }
        """)
        XCTAssertEqual(config.terminal, .builtin(.seedmux))
        let entry = try XCTUnwrap(host(config.menu[0]))
        XCTAssertEqual(config.action(for: entry), .run(TerminalRequest(
            terminal: .builtin(.seedmux), command: "expect ~/bin/jump.exp", mode: .new, theme: nil, title: "jump")))
    }

    func testURLCommandsOpenDirectly() throws {
        let config = try parse(#"{ "hosts": [ { "name": "docs", "cmd": "https://example.com/a?b=c" } ] }"#)
        let entry = try XCTUnwrap(host(config.menu[0]))
        XCTAssertEqual(config.action(for: entry), .openURL(URL(string: "https://example.com/a?b=c")!))
        let ssh = HostEntry(name: "s", command: "ssh user@host")
        guard case .run = config.action(for: ssh) else { return XCTFail("ssh must not be treated as a URL") }
    }

    func testDefaultsResolveLikeOriginal() throws {
        let config = try parse(#"{ "open_in": "current", "default_theme": "Pro", "hosts": [] }"#)
        XCTAssertEqual(config.openIn, .tab, "only tab/new are valid open_in values")
        let entry = HostEntry(name: "box", command: "ssh box", terminal: .builtin(.iTerm))
        XCTAssertEqual(config.action(for: entry), .run(TerminalRequest(
            terminal: .builtin(.iTerm), command: "ssh box", mode: .tab, theme: "Pro", title: "box")))
    }

    func testUnknownTerminalFallsBackToTerminalApp() throws {
        let config = try parse(#"{ "terminal": "Hyper", "hosts": [] }"#)
        XCTAssertEqual(config.terminal, .builtin(.terminal))
        XCTAssertEqual(config.warnings.count, 1)
    }

    func testSortPrefixesAndSeparators() throws {
        let config = try parse("""
        { "show_ssh_config_hosts": false, "hosts": [
          { "name": "[bbb]Second", "cmd": "2" },
          { "name": "[aaa][---]First", "cmd": "1" },
          { "name": "zeta", "cmd": "z" },
          { "name": "Alpha", "cmd": "a" }
        ] }
        """)
        // Sorting uses the raw name, so prefixed items come first, as in the original.
        XCTAssertEqual(titles(config.menu), ["First", "Second", "Alpha", "zeta"])
        XCTAssertEqual(config.menu.map(\.separatorAfter), [true, false, false, false])
        XCTAssertEqual(host(config.menu[0])?.name, "First")
    }

    func testSSHHostsMergeIntoGroupsAndRespectFilters() throws {
        let ssh = [
            SSHHost(alias: "web1", name: "Work/web1"),
            SSHHost(alias: "*", name: "*"),
            SSHHost(alias: ".hidden", name: ".hidden"),
            SSHHost(alias: "skipme", name: "skipme"),
            SSHHost(alias: "github.com", name: "github.com"),
            SSHHost(alias: "nas", name: "nas"),
        ]
        let config = try parse("""
        { "ssh_config_ignore_hosts": ["skipme"], "ssh_config_ignore_keywords": ["github"], "hosts": [
          { "Work": [ { "name": "db", "cmd": "ssh db" } ] }
        ] }
        """, ssh: ssh)
        XCTAssertEqual(titles(config.menu), ["Work", "nas"])
        let work = children(config.menu[0])
        XCTAssertEqual(titles(work), ["db", "web1"])
        XCTAssertEqual(host(work[1])?.command, "ssh web1")
    }

    func testSSHHostsSkippedWhenDisabled() throws {
        let config = try parse(#"{ "show_ssh_config_hosts": false, "hosts": [] }"#,
                               ssh: [SSHHost(alias: "nas", name: "nas")])
        XCTAssertTrue(config.menu.isEmpty)
    }

    func testPerEntryTerminalAndSplitMode() throws {
        let config = try parse("""
        { "terminal": "iTerm", "hosts": [ { "name": "x", "cmd": "top", "terminal": "ghostty", "inTerminal": "split" } ] }
        """)
        let entry = try XCTUnwrap(host(config.menu[0]))
        XCTAssertEqual(entry.terminal, .builtin(.ghostty))
        XCTAssertEqual(entry.mode, .split)
    }

    func testBuiltinTerminalNames() {
        XCTAssertEqual(TerminalKind(configValue: "WezTerm.app"), .wezTerm)
        XCTAssertEqual(TerminalKind(configValue: "kitty"), .kitty)
        XCTAssertEqual(TerminalKind(configValue: "Warp"), .warp)
        XCTAssertEqual(TerminalKind(configValue: "alacritty"), .alacritty)
        XCTAssertNil(TerminalKind(configValue: "Hyper"))
    }

    func testCustomTerminalsResolveBeforeBuiltins() throws {
        let config = try parse("""
        { "terminal": "Rio.app",
          "custom_terminals": {
            "Rio": { "launch": "open -na Rio --args -e /bin/zsh -lic {cmd}" },
            "Hyper": { "app": "Hyper", "keystroke": true, "delay": 1.5 },
            "kitty": { "launch": "my-kitty {cmd}" },
            "Broken": { "app": "X" },
            "NoCmd": { "launch": "open -a Tabby" }
          },
          "hosts": [
            { "name": "a", "cmd": "ls", "terminal": "hyper" },
            { "name": "b", "cmd": "ls", "terminal": "kitty" },
            { "name": "c", "cmd": "ls", "terminal": "Nope" }
          ] }
        """)
        XCTAssertEqual(config.terminal, .custom(CustomTerminal(
            name: "Rio", method: .launch(template: "open -na Rio --args -e /bin/zsh -lic {cmd}"))))
        XCTAssertEqual(host(config.menu[0])?.terminal,
                       .custom(CustomTerminal(name: "Hyper", method: .keystroke(app: "Hyper", delay: 1.5))))
        XCTAssertEqual(host(config.menu[1])?.terminal,
                       .custom(CustomTerminal(name: "kitty", method: .launch(template: "my-kitty {cmd}"))),
                       "a custom entry overrides the built-in adapter of the same name")
        XCTAssertNil(host(config.menu[2])?.terminal)
        XCTAssertEqual(config.warnings.count, 3, "Broken, NoCmd and the unknown per-entry terminal: \(config.warnings)")
    }
}
