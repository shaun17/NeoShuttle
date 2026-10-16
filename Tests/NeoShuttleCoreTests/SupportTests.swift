import XCTest
@testable import NeoShuttleCore

final class SSHConfigTests: XCTestCase {
    func testParsesHostsNamesAndIncludes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let included = directory.appendingPathComponent("extra.conf")
        try "Host extra\n  HostName 10.0.0.2\n".write(to: included, atomically: true, encoding: .utf8)
        let main = directory.appendingPathComponent("config")
        try """
        Host *
          ServerAliveInterval 30
        Host box box-alias
          HostName 100.0.0.1
          User alice
          hostname ignored-second-value
          # shuttle.name Home/box
        host=lower
        Match host lower
          User not-for-lower
        Include \(directory.path)/*.conf
        Include \(main.path)
        """.write(to: main, atomically: true, encoding: .utf8)

        let hosts = SSHConfig.hosts(atPath: main.path)
        XCTAssertEqual(hosts.map(\.alias), ["*", "box", "lower", "extra"], "the self-include must not loop")
        XCTAssertEqual(hosts.map(\.name), ["*", "Home/box", "lower", "extra"])
        XCTAssertEqual(hosts[1].options, ["hostname": "100.0.0.1", "user": "alice"], "first value wins")
        XCTAssertEqual(hosts[2].options, [:], "options under Match don't belong to the previous Host")
        XCTAssertEqual(hosts[3].options["hostname"], "10.0.0.2")
        XCTAssertEqual(hosts[1].file, (main.path as NSString).standardizingPath)
        XCTAssertEqual(hosts[3].file, (included.path as NSString).standardizingPath)
    }

    func testMenuPlacement() {
        let place = { (name: String) in
            ShuttleConfig.sshMenuPlacement(SSHHost(alias: "a", name: name),
                                           ignoreHosts: ["skip"], ignoreKeywords: ["git"])
        }
        XCTAssertEqual(place("Work/db")?.groups, ["Work"])
        XCTAssertEqual(place("Work/db")?.leaf, "db")
        XCTAssertNil(place("*.corp"))
        XCTAssertNil(place(".hidden"))
        XCTAssertNil(place("skip"))
        XCTAssertNil(place("github.com"))
        XCTAssertNil(place("Work/"))
    }

    func testMissingFileYieldsNothing() {
        XCTAssertEqual(SSHConfig.hosts(atPath: "/nonexistent/ssh/config"), [])
    }
}

final class AppleScriptTextTests: XCTestCase {
    func testEscapesQuotesAndBackslashes() {
        XCTAssertEqual(AppleScriptText.literal(#"echo "a\b""#), #""echo \"a\\b\"""#)
        XCTAssertEqual(AppleScriptText.literal("plain"), "\"plain\"")
    }
}

final class ShellPromptTests: XCTestCase {
    func testRecognisesCommonPrompts() {
        XCTAssertTrue(ShellPrompt.isReady("Last login: today\n➜  ~ \n\n\n"))
        XCTAssertTrue(ShellPrompt.isReady("➜  QT-Projects git:(main)"))
        XCTAssertTrue(ShellPrompt.isReady("~/code ❯ "))
        XCTAssertTrue(ShellPrompt.isReady("user@mac ~ % "))
        XCTAssertTrue(ShellPrompt.isReady("bash-3.2$ "))
    }

    func testOnlyTheLastLineCounts() {
        XCTAssertFalse(ShellPrompt.isReady("➜  ~\nUpdating plugins..."))
        XCTAssertFalse(ShellPrompt.isReady("   \n\n"))
    }

    func testDetectsOhMyZshUpdateQuestion() {
        XCTAssertTrue(ShellPrompt.isAskingToUpdate("[oh-my-zsh] Would you like to update? [Y/n]"))
        XCTAssertFalse(ShellPrompt.isAskingToUpdate("➜  ~"))
    }
}

final class ShellCommandTests: XCTestCase {
    func testShellQuote() {
        XCTAssertEqual(ShellQuote.quote("it's"), #"'it'\''s'"#)
    }

    func testTemplateExpansionQuotesEachPlaceholder() {
        XCTAssertEqual(
            CustomTerminal.expand("open -na Rio --args --title {title} -e sh -c {cmd}",
                                  command: "ssh a; echo 'x'", title: "My box"),
            #"open -na Rio --args --title 'My box' -e sh -c 'ssh a; echo '\''x'\'''"#)
    }

    func testLoginShellRunsCommandThenStays() throws {
        let args = LoginShell.arguments(running: "echo NEO_OK # note", shell: "/bin/sh")
        XCTAssertEqual(args, ["/bin/sh", "-l", "-i", "-c", "echo NEO_OK # note\nexec '/bin/sh' -l"])

        // Really run it: the comment must not swallow the exec line, and the shell stays
        // (it reads "exit" from stdin, proving it's an interactive shell waiting for input).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data("echo STAYED\nexit\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("NEO_OK"), text)
        XCTAssertTrue(text.contains("STAYED"), text)
    }

    func testWarpYAMLEscapesValues() {
        let yaml = WarpLaunchConfig.yaml(name: "neoshuttle-1", title: #"T "q""#,
                                         command: "echo \"a\\b\"\nls /tmp", directory: "/Users/me")
        XCTAssertTrue(yaml.contains(#"name: "neoshuttle-1""#), yaml)
        XCTAssertTrue(yaml.contains(#"title: "T \"q\"""#), yaml)
        XCTAssertTrue(yaml.contains(#"- exec: "echo \"a\\b\"\nls /tmp""#), yaml)
        XCTAssertTrue(yaml.contains(#"cwd: "/Users/me""#), yaml)
    }
}
