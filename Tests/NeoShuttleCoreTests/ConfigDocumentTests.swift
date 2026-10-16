import XCTest
@testable import NeoShuttleCore

final class ConfigDocumentTests: XCTestCase {
    private let sample = """
    {
      // comment that JSON5 allows
      "_comments": ["keep me"],
      "terminal": "Seedmux.app",
      "iTerm_version": "nightly",
      "launch_at_login": false,
      "show_ssh_config_hosts": false,
      "ssh_config_ignore_hosts": [],
      "custom_terminals": { "Rio": { "launch": "rio {cmd}", "note": 1 } },
      "hosts": [
        { "name": "[aaa][---]Jump", "cmd": "shuttle-seedmux://run/1", "seedmux_id": "1",
          "seedmux_command": "expect ~/jump.exp", "inTerminal": "new", "theme": "basic" },
        { "Work": [
            { "name": "db", "cmd": "ssh db", "terminal": "rio" },
            { "Inner": [ { "name": "x", "cmd": "ls" } ] }
        ] },
      ]
    }
    """

    private func document() throws -> ConfigDocument {
        try ConfigDocument(data: Data(sample.utf8))
    }

    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? NSDictionary)
    }

    func testRoundTripKeepsEverything() throws {
        let original = try object(Data(sample.utf8))
        let saved = try object(try document().serialized())
        XCTAssertEqual(saved, original, "an unedited document must save to the same JSON")
    }

    func testSerializedOutputIsReadableAndOrdered() throws {
        let text = String(decoding: try document().serialized(), as: UTF8.self)
        let comments = try XCTUnwrap(text.range(of: "\"_comments\""))
        let hosts = try XCTUnwrap(text.range(of: "\"hosts\""))
        XCTAssertLessThan(comments.lowerBound, hosts.lowerBound)
        XCTAssertTrue(text.contains("\"ssh_config_ignore_hosts\": []"))
        XCTAssertTrue(text.contains("\"launch_at_login\": false"), "booleans must stay booleans")
        XCTAssertTrue(text.contains("\"note\": 1"), "integers must not gain a .0")
        // name comes before cmd inside an entry
        let name = try XCTUnwrap(text.range(of: "\"name\": \"db\""))
        let cmd = try XCTUnwrap(text.range(of: "\"cmd\": \"ssh db\""))
        XCTAssertLessThan(name.lowerBound, cmd.lowerBound)
    }

    func testSavedFileParsesToTheSameMenu() throws {
        let before = try ShuttleConfig.parse(Data(sample.utf8))
        let after = try ShuttleConfig.parse(try document().serialized())
        XCTAssertEqual(after.menu, before.menu)
        XCTAssertEqual(after.terminal, before.terminal)
        XCTAssertEqual(after.customTerminals, before.customTerminals)
    }

    func testSeedmuxEntriesEditTheRealCommand() throws {
        var doc = try document()
        let jump = try XCTUnwrap(doc.hosts.compactMap { if case .entry(let e) = $0 { e } else { nil } }.first)
        XCTAssertTrue(jump.usesSeedmuxCommand)
        XCTAssertEqual(jump.command, "expect ~/jump.exp")
        doc.updateEntry(jump.id) { $0.command = "expect ~/other.exp" }
        let saved = try object(doc.serialized())
        let entry = try XCTUnwrap((saved["hosts"] as? [NSDictionary])?.first)
        XCTAssertEqual(entry["seedmux_command"] as? String, "expect ~/other.exp")
        XCTAssertEqual(entry["cmd"] as? String, "shuttle-seedmux://run/1", "the bridge URL stays for old Shuttle")
        XCTAssertEqual(entry["seedmux_id"] as? String, "1")
    }

    func testMenuNameParts() {
        let name = MenuName(raw: "[aaa][---]Jump")
        XCTAssertEqual(name, MenuName(sortKey: "aaa", separatorAfter: true, title: "Jump"))
        XCTAssertEqual(name.raw, "[aaa][---]Jump")
        XCTAssertEqual(MenuName(sortKey: "AB", separatorAfter: false, title: "x").raw, "x", "invalid keys are dropped")
        XCTAssertEqual(MenuName(raw: "plain"), MenuName(title: "plain"))
    }

    func testClearingOptionalFieldsRemovesKeys() throws {
        var doc = try document()
        let jump = try XCTUnwrap(doc.hosts.first?.id)
        doc.updateEntry(jump) { $0.theme = ""; $0.mode = nil }
        let entry = try XCTUnwrap((try object(doc.serialized())["hosts"] as? [NSDictionary])?.first)
        XCTAssertNil(entry["theme"])
        XCTAssertNil(entry["inTerminal"])
    }

    func testInsertMoveAndRemove() throws {
        var doc = try document()
        let work = try XCTUnwrap(doc.groupPaths().first { $0.path == "Work" }?.id)
        let inner = try XCTUnwrap(doc.groupPaths().first { $0.path == "Work / Inner" }?.id)

        let added = ConfigEntry(name: "new", command: "uptime")
        doc.insert(.entry(added), into: inner)
        XCTAssertEqual(doc.parentGroup(of: added.id), inner)

        doc.move(added.id, into: nil)
        XCTAssertNil(doc.parentGroup(of: added.id))
        XCTAssertNotNil(doc.entry(added.id))

        doc.move(work, into: inner)
        XCTAssertEqual(doc.parentGroup(of: inner), work, "a group can't move into its own descendant")

        XCTAssertNotNil(doc.remove(work))
        XCTAssertNil(doc.node(inner))
        XCTAssertEqual(doc.groupPaths().count, 0)
    }

    func testRenamingCustomTerminalUpdatesReferences() throws {
        var doc = try document()
        doc.setString("terminal", "Rio")
        let rio = try XCTUnwrap(doc.customTerminals.first?.id)
        doc.renameCustomTerminal(rio, to: "RioTerm")
        XCTAssertEqual(doc.string("terminal"), "RioTerm")
        let config = try ShuttleConfig.parse(doc.serialized())
        XCTAssertEqual(config.terminal, .custom(CustomTerminal(name: "RioTerm", method: .launch(template: "rio {cmd}"))))
        let work = try XCTUnwrap(config.menu.first { $0.title == "Work" })
        guard case .group(let children) = work.kind, case .host(let db) = children.last?.kind else {
            return XCTFail("unexpected tree")
        }
        XCTAssertEqual(db.terminal, config.terminal, "the entry that pointed at rio follows the rename")
    }

    func testKeystrokeTerminalSerialization() throws {
        var doc = ConfigDocument()
        doc.customTerminals = [CustomTerminalSpec(name: "Hyper", kind: .keystroke, app: "Hyper", delay: 1.5)]
        let config = try ShuttleConfig.parse(doc.serialized())
        XCTAssertEqual(config.customTerminals, [CustomTerminal(name: "Hyper", method: .keystroke(app: "Hyper", delay: 1.5))])
    }
}
