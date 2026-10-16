import SwiftUI
import UniformTypeIdentifiers
import NeoShuttleCore

struct GeneralSettingsView: View {
    @Bindable var store: ConfigEditorStore
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var customEditor = false
    @State private var showIgnoreRules = false
    @State private var refreshTick = 0

    var body: some View {
        Form {
            openSection
            configFileSection
            sshSection
            systemSection
        }
        .formStyle(.grouped)
        .onAppear {
            // Open the rules when something is already ignored, so it isn't hidden away.
            showIgnoreRules = ignoredCount > 0 || !store.document.strings("ssh_config_ignore_keywords").isEmpty
        }
    }

    // MARK: Sections

    private var openSection: some View {
        Section("打开方式") {
            Picker(selection: terminal) {
                ForEach(store.terminalChoices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
                if let unknown = unknownTerminal {
                    Text("\(unknown)（不支持）").tag(unknown)
                }
            } label: {
                Text("默认终端")
                Text("点击菜单条目时，命令在这里执行")
            }
            Picker(selection: openIn) {
                Text("新标签页").tag("tab")
                Text("新窗口").tag("new")
            } label: {
                Text("打开位置")
                Text("每个条目还可以单独指定")
            }
            .pickerStyle(.segmented)
            ThemePicker(value: defaultTheme, terminals: [.terminal, .iTerm],
                        noneLabel: "不设置", subtitle: themeHint, store: store)
        }
    }

    private var configFileSection: some View {
        Section("配置文件") {
            LabeledContent {
                HStack(spacing: 8) {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.configURL])
                    }
                    Button("编辑…") { store.openInEditor(ConfigStore.configURL) }
                }
            } label: {
                Text(abbreviated(store.configPath)).textSelection(.enabled)
                Text("菜单条目和这里的设置都保存在这个文件里")
            }
            Picker(selection: editorSelection) {
                Text("系统默认（\(systemJSONEditor)）").tag(Self.systemEditor)
                Divider()
                ForEach(EditorChoice.installed, id: \.self) { name in
                    Text(name).tag(name)
                }
                Divider()
                Text("其他…").tag(Self.otherEditor)
            } label: {
                Text("编辑器")
                Text("“编辑…”和 ~/.ssh/config 用它打开")
            }
            if editorSelection.wrappedValue == Self.otherEditor {
                TextField(text: editorText, prompt: Text("应用名，或 vi、nano 等终端编辑器")) {
                    Text("编辑器名称")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var sshSection: some View {
        Section {
            Toggle(isOn: showSSH.animation(.snappy)) {
                Text("从 ~/.ssh/config 添加主机")
                Text(sshSummary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: sshSummary)
            }

            if showSSH.wrappedValue {
                if store.sshHosts.isEmpty {
                    Text("还没有主机。点下方“编辑”添加 Host，保存后切回这里会自动出现。")
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                ForEach(store.sshHosts, id: \.rowID) { host in
                    SSHHostRow(host: host, store: store)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack {
                    Button {
                        store.openSSHConfig()
                    } label: {
                        Label("编辑 ~/.ssh/config", systemImage: "square.and.pencil")
                    }
                    Spacer()
                    Button {
                        refreshTick += 1
                        store.refreshSSHHosts()
                    } label: {
                        Label("重新读取", systemImage: "arrow.clockwise")
                            .symbolEffect(.bounce, value: refreshTick)
                    }
                    .help("编辑后切回本窗口也会自动重新读取")
                }
                .transition(.opacity)

                DisclosureGroup(isExpanded: $showIgnoreRules.animation(.snappy)) {
                    TextField(text: list("ssh_config_ignore_hosts"), prompt: Text("完全匹配的名字，逗号分隔")) {
                        Text("忽略主机")
                    }
                    TextField(text: list("ssh_config_ignore_keywords"), prompt: Text("名字里包含的词，逗号分隔")) {
                        Text("忽略关键词")
                    }
                } label: {
                    Text(ignoredCount > 0 ? "忽略规则（\(ignoredCount) 台已隐藏）" : "忽略规则")
                        .contentTransition(.numericText())
                }
                .transition(.opacity)
            }
        } header: {
            Text("SSH 主机")
        } footer: {
            if showSSH.wrappedValue {
                Text("Host 名里的 / 会变成子菜单；隐藏和忽略规则在保存后生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemSection: some View {
        Section("系统") {
            Toggle(isOn: $launchAtLogin) {
                Text("登录时启动")
                Text("立即生效，不需要保存")
            }
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    try LoginItem.setEnabled(enabled)
                } catch {
                    launchAtLogin = LoginItem.isEnabled
                    Launcher.present(error)
                }
            }
        }
    }

    // MARK: Descriptions

    private var themeHint: String {
        guard store.themeTerminal(nil) == nil else { return "Terminal 描述文件或 iTerm Profile" }
        let current = store.canonicalTerminal(store.document.string("terminal")) ?? "Terminal"
        return "\(current) 不使用主题，只影响指定了 Terminal / iTerm 的条目"
    }

    private var sshSummary: String {
        let hosts = store.sshHosts.filter { store.sshStatus($0) != .pattern }
        guard store.showsSSHHosts else {
            return hosts.isEmpty ? "关闭" : "关闭（文件中有 \(hosts.count) 台主机）"
        }
        guard !hosts.isEmpty else { return "文件中还没有主机" }
        let shown = store.visibleSSHHosts.count
        return shown == hosts.count ? "\(shown) 台主机已加入菜单" : "\(shown) / \(hosts.count) 台主机已加入菜单"
    }

    private var ignoredCount: Int {
        store.sshHosts.filter {
            switch store.sshStatus($0) {
            case .hiddenByName, .hiddenByKeyword: true
            default: false
            }
        }.count
    }

    private var systemJSONEditor: String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: UTType.json) else { return "未设置" }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Bindings

    private static let systemEditor = "default"
    private static let otherEditor = "\u{1}other"

    private var defaultTheme: Binding<String?> {
        Binding(
            get: { store.document.string("default_theme") },
            set: { store.document.setString("default_theme", $0) }
        )
    }

    private var terminal: Binding<String> {
        Binding(
            get: { store.canonicalTerminal(store.document.string("terminal")) ?? TerminalKind.terminal.rawValue },
            set: { store.document.setString("terminal", $0) }
        )
    }

    private var unknownTerminal: String? {
        let value = terminal.wrappedValue
        return store.terminalChoices.contains { $0.value == value } ? nil : value
    }

    private var openIn: Binding<String> {
        Binding(
            get: { store.document.string("open_in") == "new" ? "new" : "tab" },
            set: { store.document.setString("open_in", $0) }
        )
    }

    /// "Other…" stays selected while the user types a name that isn't in the list.
    private var editorSelection: Binding<String> {
        Binding(
            get: {
                let value = store.document.string("editor") ?? Self.systemEditor
                if customEditor { return Self.otherEditor }
                if value == Self.systemEditor || EditorChoice.installed.contains(value) { return value }
                return Self.otherEditor
            },
            set: { choice in
                withAnimation(.snappy) {
                    customEditor = choice == Self.otherEditor
                    if choice != Self.otherEditor { store.document.setString("editor", choice) }
                }
            }
        )
    }

    private var editorText: Binding<String> {
        Binding(
            get: {
                let value = store.document.string("editor") ?? Self.systemEditor
                return value == Self.systemEditor ? "" : value
            },
            set: { store.document.setString("editor", $0.isEmpty ? Self.systemEditor : $0) }
        )
    }

    private var showSSH: Binding<Bool> {
        Binding(
            // The original Shuttle merged ssh_config hosts unless told not to.
            get: { store.document.bool("show_ssh_config_hosts") ?? true },
            set: { store.document.setBool("show_ssh_config_hosts", $0) }
        )
    }

    private func list(_ key: String) -> Binding<String> {
        Binding(
            get: { store.document.strings(key).joined(separator: ", ") },
            set: { text in
                let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                withAnimation(.snappy) {
                    store.document.setStrings(key, items.filter { !$0.isEmpty })
                }
            }
        )
    }
}

enum EditorChoice {
    private static let candidates = [
        ("Zed", "dev.zed.Zed"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Nova", "com.panic.Nova"),
        ("BBEdit", "com.barebones.bbedit"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("TextEdit", "com.apple.TextEdit"),
    ]

    @MainActor static var installed: [String] {
        candidates
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) != nil }
            .map(\.0)
    }
}

private extension SSHHost {
    /// Stable across re-reads, so list changes animate as insertions and removals.
    var rowID: String { "\(file)#\(alias)" }
}

/// One ssh_config host with its connection details and quick actions.
private struct SSHHostRow: View {
    let host: SSHHost
    let store: ConfigEditorStore

    var body: some View {
        let status = store.sshStatus(host)
        let shown = status == .shown
        HStack(spacing: 10) {
            Image(systemName: status == .pattern ? "asterisk" : "network")
                .foregroundStyle(shown ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.name)
                    if host.name != host.alias {
                        Text("Host \(host.alias)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let badge = badge(status) {
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                Text(connection)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .opacity(shown || status == .pattern ? 1 : 0.55)
            Spacer()
            if status == .shown || status == .hiddenByName {
                Button {
                    withAnimation(.snappy) { store.setSSHHidden(host, hidden: shown) }
                } label: {
                    Image(systemName: shown ? "eye" : "eye.slash")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 20)
                }
                .help(shown ? "在菜单中隐藏" : "重新在菜单中显示")
            }
            Button {
                store.openSSHConfig(file: host.file)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("打开所在文件编辑")
        }
        .buttonStyle(.borderless)
        .animation(.snappy, value: status)
        .padding(.vertical, 2)
    }

    /// user@hostname:port, as ssh would connect.
    private var connection: String {
        let options = host.options
        var text = options["hostname"] ?? host.alias
        if let user = options["user"] { text = "\(user)@\(text)" }
        if let port = options["port"], port != "22" { text += ":\(port)" }
        if let jump = options["proxyjump"] { text += "  经由 \(jump)" }
        return text
    }

    private func badge(_ status: SSHHostStatus) -> String? {
        switch status {
        case .shown: nil
        case .hiddenByName: "已隐藏"
        case .hiddenByKeyword(let keyword): "含“\(keyword)”"
        case .pattern: "通配规则"
        }
    }
}
