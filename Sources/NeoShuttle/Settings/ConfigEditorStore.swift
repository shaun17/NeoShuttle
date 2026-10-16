import AppKit
import CryptoKit
import UniformTypeIdentifiers
import Observation
import SwiftUI
import NeoShuttleCore

/// State behind the settings window: the document being edited and the last saved copy.
@MainActor
@Observable
final class ConfigEditorStore {
    var document = ConfigDocument()
    private(set) var saved = ConfigDocument()
    /// Set when the file can't be parsed; editing is disabled so a save can't destroy it.
    private(set) var loadError: String?
    private(set) var status: String?
    var hostSelection: UUID?
    var terminalSelection: UUID?
    var tab: SettingsTab = .hosts

    /// Set by the window controller; the Save button closes the window after a successful save.
    @ObservationIgnored var closeWindow: (() -> Void)?
    @ObservationIgnored private let launcher: Launcher
    @ObservationIgnored private var loadedModification: Date?
    @ObservationIgnored private var backedUp = false

    init(launcher: Launcher) {
        self.launcher = launcher
        reload()
    }

    var isDirty: Bool { loadError == nil && document != saved }
    var configPath: String { ConfigStore.configURL.path }

    func reload() {
        let url = ConfigStore.configURL
        do {
            try ConfigStore.createDefaultIfMissing(at: url)
            let parsed = try ConfigDocument(data: Data(contentsOf: url))
            document = parsed
            saved = parsed
            loadError = nil
            loadedModification = Self.modificationDate(url)
            status = nil
            refreshSSHHosts()
            refreshProfiles()
            if let selection = hostSelection, parsed.node(selection) == nil, sshItem(selection) == nil {
                hostSelection = nil
            }
            if let selection = terminalSelection, !parsed.customTerminals.contains(where: { $0.id == selection }) {
                terminalSelection = nil
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func revert() {
        document = saved
        status = "已放弃未保存的修改"
    }

    @discardableResult
    func save() -> Bool {
        guard loadError == nil else { return false }
        let url = ConfigStore.configURL
        if let loaded = loadedModification, let current = Self.modificationDate(url), current > loaded {
            let alert = NSAlert()
            alert.messageText = "配置文件在别处被修改过"
            alert.informativeText = "保存会覆盖那些修改。也可以先放弃这里的编辑，重新载入文件。"
            alert.addButton(withTitle: "覆盖保存")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        do {
            // One backup per session, taken before the first write: the file as the user left it.
            if !backedUp, FileManager.default.fileExists(atPath: url.path) {
                let backup = url.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: url, to: backup)
                backedUp = true
            }
            try document.serialized().write(to: url, options: .atomic)
            saved = document
            loadedModification = Self.modificationDate(url)
            status = "已保存 \(Date().formatted(date: .omitted, time: .standard))"
            return true
        } catch {
            Launcher.present(error)
            return false
        }
    }

    // MARK: Entries

    /// New nodes go into the selected group, or next to the selected entry.
    private var insertionGroup: UUID? {
        guard let selection = hostSelection else { return nil }
        return document.group(selection) != nil ? selection : document.parentGroup(of: selection)
    }

    func addEntry() {
        let entry = ConfigEntry(name: "新条目", command: "")
        document.insert(.entry(entry), into: insertionGroup)
        hostSelection = entry.id
    }

    func addGroup() {
        let group = ConfigGroup(name: "新分组")
        document.insert(.group(group), into: insertionGroup)
        hostSelection = group.id
    }

    func duplicate(_ id: UUID) {
        guard let source = document.entry(id) else { return }
        var name = source.menuName
        name.title += " 副本"
        name.separatorAfter = false
        let copy = ConfigEntry(name: name.raw, command: source.command, from: source)
        document.insert(.entry(copy), into: document.parentGroup(of: id))
        hostSelection = copy.id
    }

    func delete(_ id: UUID) {
        guard document.node(id) != nil else { return }
        if case .group(let group) = document.node(id), group.entryCount > 0 {
            let alert = NSAlert()
            alert.messageText = "删除分组“\(group.menuName.title)”？"
            alert.informativeText = "分组里的 \(group.entryCount) 个条目会一起删除。保存前都可以放弃修改。"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let parent = document.parentGroup(of: id)
        document.remove(id)
        hostSelection = parent
    }

    func entry(_ id: UUID) -> Binding<ConfigEntry>? {
        guard let current = document.entry(id) else { return nil }
        return Binding(
            get: { self.document.entry(id) ?? current },
            set: { value in self.document.updateEntry(id) { $0 = value } }
        )
    }

    func group(_ id: UUID) -> Binding<ConfigGroup>? {
        guard let current = document.group(id) else { return nil }
        return Binding(
            get: { self.document.group(id) ?? current },
            set: { value in self.document.updateGroup(id) { $0 = value } }
        )
    }

    func parent(of id: UUID) -> Binding<UUID?> {
        Binding(
            get: { self.document.parentGroup(of: id) },
            set: { self.document.move(id, into: $0) }
        )
    }

    /// Runs an entry with the unsaved edits, so it can be tried before saving.
    func run(_ id: UUID) {
        guard let entry = document.entry(id) else { return }
        do {
            let config = try ShuttleConfig.parse(document.serialized())
            let host = HostEntry(
                name: entry.menuName.title,
                command: entry.command,
                mode: entry.mode.flatMap(OpenMode.init(configValue:)),
                theme: entry.theme.flatMap { $0.isEmpty ? nil : $0 },
                title: entry.title.flatMap { $0.isEmpty ? nil : $0 },
                terminal: entry.terminal.flatMap(config.resolveTerminal)
            )
            launcher.launch(config.action(for: host))
        } catch {
            Launcher.present(error)
        }
    }

    // MARK: Themes

    private(set) var terminalProfiles: [String] = []
    private(set) var terminalDefaultProfile: String?
    private(set) var iTermProfiles: [String] = []

    /// Assigns only what changed, so a no-op refresh doesn't re-render the window.
    func refreshProfiles() {
        let terminal = ProfileCatalog.terminalProfiles()
        if terminal != terminalProfiles { terminalProfiles = terminal }
        let terminalDefault = ProfileCatalog.terminalDefaultProfile()
        if terminalDefault != terminalDefaultProfile { terminalDefaultProfile = terminalDefault }
        let iTerm = ProfileCatalog.iTermProfiles()
        if iTerm != iTermProfiles { iTermProfiles = iTerm }
    }

    /// The built-in terminal a terminal name runs in, when that terminal uses themes.
    /// A custom terminal with the same name wins, as it does when launching.
    func themeTerminal(_ name: String?) -> TerminalKind? {
        let name = canonicalTerminal(name) ?? canonicalTerminal(document.string("terminal")) ?? TerminalKind.terminal.rawValue
        guard !document.customTerminals.contains(where: { $0.name == name }),
              let kind = TerminalKind(configValue: name), kind == .terminal || kind == .iTerm
        else { return nil }
        return kind
    }

    // MARK: SSH hosts

    /// Everything in ~/.ssh/config, before the show/ignore settings are applied.
    private(set) var sshHosts: [SSHHost] = []

    func refreshSSHHosts() {
        let hosts = SSHConfig.hosts(atPath: ConfigStore.sshConfigPath)
        if hosts != sshHosts {
            withAnimation(.snappy) { sshHosts = hosts }
        }
    }

    var showsSSHHosts: Bool { document.bool("show_ssh_config_hosts") ?? true }

    /// Hosts the menu will show, with where they go. Follows unsaved edits to the settings.
    var visibleSSHHosts: [SSHItem] {
        guard showsSSHHosts else { return [] }
        let ignoreHosts = document.strings("ssh_config_ignore_hosts")
        let ignoreKeywords = document.strings("ssh_config_ignore_keywords")
        return sshHosts.compactMap { host in
            ShuttleConfig.sshMenuPlacement(host, ignoreHosts: ignoreHosts, ignoreKeywords: ignoreKeywords)
                .map { SSHItem(host: host, groups: $0.groups, leaf: $0.leaf) }
        }
    }

    func sshItem(_ id: UUID) -> SSHItem? {
        visibleSSHHosts.first { $0.id == id }
    }

    func runSSH(_ item: SSHItem) {
        do {
            let config = try ShuttleConfig.parse(document.serialized())
            launcher.launch(config.action(for: HostEntry(name: item.leaf, command: item.command)))
        } catch {
            Launcher.present(error)
        }
    }

    /// Adds the host to ssh_config_ignore_hosts (takes effect on save).
    func hideSSH(_ item: SSHItem) {
        var ignored = document.strings("ssh_config_ignore_hosts")
        if !ignored.contains(item.host.name) { ignored.append(item.host.name) }
        document.setStrings("ssh_config_ignore_hosts", ignored)
        if hostSelection == item.id { hostSelection = nil }
    }

    /// Copies the host into an editable entry (in the same group, when that group exists
    /// in the config) and hides the ssh_config copy so it isn't listed twice.
    func convertSSH(_ item: SSHItem) {
        var groupID: UUID?
        var level = document.hosts
        for name in item.groups {
            guard let group = level.compactMap({ node -> ConfigGroup? in
                if case .group(let group) = node, group.name == name { group } else { nil }
            }).first else {
                groupID = nil
                break
            }
            groupID = group.id
            level = group.children
        }
        let entry = ConfigEntry(name: item.leaf, command: item.command)
        document.insert(.entry(entry), into: groupID)
        hideSSH(item)
        hostSelection = entry.id
    }

    /// Why a host is or isn't in the menu, for the list in the General tab.
    func sshStatus(_ host: SSHHost) -> SSHHostStatus {
        let name = host.name
        if name.contains("*") || name.contains("?") || name.contains("!") || name.hasPrefix(".") {
            return .pattern
        }
        if document.strings("ssh_config_ignore_hosts").contains(name) { return .hiddenByName }
        if let keyword = document.strings("ssh_config_ignore_keywords").first(where: { !$0.isEmpty && name.contains($0) }) {
            return .hiddenByKeyword(keyword)
        }
        return .shown
    }

    func setSSHHidden(_ host: SSHHost, hidden: Bool) {
        var ignored = document.strings("ssh_config_ignore_hosts").filter { $0 != host.name }
        if hidden { ignored.append(host.name) }
        document.setStrings("ssh_config_ignore_hosts", ignored)
    }

    /// Opens ~/.ssh/config (or an Include'd file), creating an empty, private one if needed.
    func openSSHConfig(file: String? = nil) {
        let path = (file?.isEmpty == false ? file : nil) ?? ConfigStore.sshConfigPath
        let url = URL(fileURLWithPath: path)
        let manager = FileManager.default
        if !manager.fileExists(atPath: path) {
            do {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                // ssh refuses config files other users can write; keep it owner-only.
                manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            } catch {
                Launcher.present(error)
                return
            }
        }
        openInEditor(url)
    }

    /// Opens a file with the configured editor; plain-text default otherwise, since
    /// ~/.ssh/config has no extension to pick an app by.
    func openInEditor(_ url: URL) {
        let editor = document.string("editor") ?? "default"
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if editor != "default", AppLocator.find(named: editor) == nil {
            let terminal = (try? ShuttleConfig.parse(document.serialized()))?.terminal ?? .builtin(.terminal)
            launcher.launch(.run(TerminalRequest(
                terminal: terminal, command: "\(editor) \(ShellQuote.quote(url.path))",
                mode: .new, theme: nil, title: url.lastPathComponent)))
            return
        }
        // "default": the file's own default app, else the plain-text editor.
        let app = editor == "default"
            ? NSWorkspace.shared.urlForApplication(toOpen: url) ?? NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            : AppLocator.find(named: editor)
        guard let app else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
    }

    // MARK: Custom terminals

    func addTerminal() {
        var name = "新终端"
        var number = 2
        while document.customTerminals.contains(where: { $0.name == name }) {
            name = "新终端 \(number)"
            number += 1
        }
        let terminal = CustomTerminalSpec(name: name, launch: "open -na 应用名 --args -e /bin/zsh -lic {cmd}")
        document.customTerminals.append(terminal)
        terminalSelection = terminal.id
    }

    func deleteTerminal(_ id: UUID) {
        document.customTerminals.removeAll { $0.id == id }
        terminalSelection = nil
    }

    func terminal(_ id: UUID) -> Binding<CustomTerminalSpec>? {
        guard let current = document.customTerminals.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.document.customTerminals.first { $0.id == id } ?? current },
            set: { value in
                guard let index = self.document.customTerminals.firstIndex(where: { $0.id == id }) else { return }
                let oldName = self.document.customTerminals[index].name
                self.document.customTerminals[index] = value
                if value.name != oldName {
                    // Restore then rename, so references to the old name follow.
                    self.document.customTerminals[index].name = oldName
                    self.document.renameCustomTerminal(id, to: value.name)
                }
            }
        )
    }

    func testTerminal(_ name: String) {
        do {
            let config = try ShuttleConfig.parse(document.serialized())
            guard let target = config.resolveTerminal(name) else { return }
            let request = TerminalRequest(
                terminal: target, command: "echo NeoShuttle 测试成功", mode: .tab, theme: nil, title: "NeoShuttle 测试")
            launcher.launch(.run(request))
        } catch {
            Launcher.present(error)
        }
    }

    // MARK: Pickers

    /// Built-in terminals plus custom ones, with what the menu shows for each.
    var terminalChoices: [(value: String, label: String)] {
        let builtin = TerminalKind.allCases.map { kind in
            (kind.rawValue, AppLocator.isInstalled(kind) ? kind.rawValue : "\(kind.rawValue)（未安装）")
        }
        let custom = document.customTerminals.map { ($0.name, "\($0.name)（自定义）") }
        return builtin + custom
    }

    /// Maps a stored terminal string onto one of `terminalChoices`, if it names one.
    func canonicalTerminal(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if let custom = document.customTerminals.first(where: {
            $0.name.lowercased() == value.lowercased().replacingOccurrences(of: ".app", with: "")
        }) {
            return custom.name
        }
        return TerminalKind(configValue: value)?.rawValue ?? value
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

enum SSHHostStatus: Equatable {
    case shown
    case hiddenByName
    case hiddenByKeyword(String)
    /// `Host *` and the like: settings for other hosts, never a menu item.
    case pattern
}

/// An ssh_config host as the menu shows it.
struct SSHItem: Identifiable {
    let host: SSHHost
    let groups: [String]
    let leaf: String

    /// Stable across reloads, so the selection survives re-reading ~/.ssh/config.
    var id: UUID { UUID.stable("ssh:\(host.alias)") }
    var command: String { "ssh \(host.alias)" }
}

extension UUID {
    /// A name-based UUID: the same key always gives the same UUID.
    static func stable(_ key: String) -> UUID {
        var bytes = Array(Insecure.MD5.hash(data: Data(key.utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

enum SettingsTab: Hashable {
    case hosts
    case general
    case terminals
}

private extension ConfigEntry {
    init(name: String, command: String, from source: ConfigEntry) {
        self.init(name: name, command: command)
        terminal = source.terminal
        mode = source.mode
        theme = source.theme
        title = source.title
    }
}
