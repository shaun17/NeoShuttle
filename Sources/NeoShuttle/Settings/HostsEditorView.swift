import SwiftUI
import NeoShuttleCore

struct HostsEditorView: View {
    @Bindable var store: ConfigEditorStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $store.hostSelection) {
                    OutlineGroup(rows, children: \.children) { row in
                        HostRowLabel(row: row)
                            .contextMenu { contextMenu(for: row) }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 4) {
                    Menu {
                        Button("新建条目") { store.addEntry() }
                        Button("新建分组") { store.addGroup() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("新建条目或分组，放在当前选中的分组里")
                    Button {
                        if let selection = store.hostSelection { store.delete(selection) }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(store.hostSelection.flatMap(store.document.node) == nil)
                    .help("删除选中项（~/.ssh/config 里的主机只能隐藏）")
                    Spacer()
                    Text(countSummary).font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            detail
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = store.hostSelection, let entry = store.entry(id) {
            EntryEditor(entry: entry, parent: store.parent(of: id), store: store)
                .id(id)
        } else if let id = store.hostSelection, let group = store.group(id) {
            GroupEditor(group: group, parent: store.parent(of: id), store: store)
                .id(id)
        } else if let id = store.hostSelection, let item = store.sshItem(id) {
            SSHHostDetail(item: item, store: store)
                .id(id)
        } else if let id = store.hostSelection, let row = find(id, in: rows), row.kind == .sshGroup {
            SSHGroupDetail(row: row, store: store)
        } else {
            ContentUnavailableView(
                "选择左侧的条目",
                systemImage: "sidebar.left",
                description: Text("也可以点左下角的 + 新建条目或分组。菜单按名称排序，分组在前。")
            )
        }
    }

    @ViewBuilder
    private func contextMenu(for row: HostRow) -> some View {
        switch row.kind {
        case .ssh:
            if let item = store.sshItem(row.id) {
                Button("运行") { store.runSSH(item) }
                Button("转为可编辑条目") { store.convertSSH(item) }
                Divider()
                Button("在菜单中隐藏") { store.hideSSH(item) }
            }
        case .sshGroup:
            Button("打开 ~/.ssh/config") { store.openSSHConfig() }
        case .entry, .group:
            if row.kind == .entry {
                Button("运行") { store.run(row.id) }
                Button("复制条目") { store.duplicate(row.id) }
                Divider()
            }
            Menu("移动到") {
                Button("顶层") { store.document.move(row.id, into: nil) }
                ForEach(store.document.groupPaths(excluding: row.id), id: \.id) { group in
                    Button(group.path) { store.document.move(row.id, into: group.id) }
                }
            }
            Divider()
            Button("删除", role: .destructive) { store.delete(row.id) }
        }
    }

    private var rows: [HostRow] { HostRow.build(store.document.hosts, ssh: store.visibleSSHHosts) }

    private var countSummary: String {
        let entries = ConfigGroup(name: "", children: store.document.hosts).entryCount
        let ssh = store.visibleSSHHosts.count
        return ssh > 0 ? "\(entries) 个条目 · \(ssh) 台 SSH 主机" : "\(entries) 个条目"
    }

    private func find(_ id: UUID, in rows: [HostRow]) -> HostRow? {
        for row in rows {
            if row.id == id { return row }
            if let found = find(id, in: row.children ?? []) { return found }
        }
        return nil
    }
}

/// The sidebar tree, in the order the menu shows it, ssh_config hosts included.
struct HostRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case entry
        case group
        /// A host from ~/.ssh/config (read-only).
        case ssh
        /// A group that exists only because an ssh_config host name contains `/`.
        case sshGroup
    }

    let id: UUID
    /// The raw name, which the menu sorts by.
    let sortName: String
    let title: String
    let detail: String?
    let kind: Kind
    let separatorAfter: Bool
    var children: [HostRow]?

    var isGroup: Bool { kind == .group || kind == .sshGroup }

    static func build(_ nodes: [ConfigNode], ssh: [SSHItem]) -> [HostRow] {
        var rows = nodes.map(row)
        for item in ssh {
            insert(item, path: item.groups[...], parentPath: "", into: &rows)
        }
        return sorted(rows)
    }

    private static func row(_ node: ConfigNode) -> HostRow {
        switch node {
        case .entry(let entry):
            let name = entry.menuName
            return HostRow(id: entry.id, sortName: entry.name, title: name.title.isEmpty ? "（未命名）" : name.title,
                           detail: entry.terminal, kind: .entry, separatorAfter: name.separatorAfter, children: nil)
        case .group(let group):
            let name = group.menuName
            return HostRow(id: group.id, sortName: group.name, title: name.title.isEmpty ? "（未命名分组）" : name.title,
                           detail: nil, kind: .group, separatorAfter: name.separatorAfter,
                           children: group.children.map(row))
        }
    }

    /// Mirrors how the menu merges ssh hosts: into a config group with the same raw name, or a new group.
    private static func insert(_ item: SSHItem, path: ArraySlice<String>, parentPath: String, into rows: inout [HostRow]) {
        guard let head = path.first else {
            rows.append(HostRow(id: item.id, sortName: item.leaf, title: item.leaf, detail: "ssh",
                                kind: .ssh, separatorAfter: false, children: nil))
            return
        }
        let groupPath = parentPath + "/" + head
        if let index = rows.firstIndex(where: { $0.isGroup && $0.sortName == head }) {
            var children = rows[index].children ?? []
            insert(item, path: path.dropFirst(), parentPath: groupPath, into: &children)
            rows[index].children = children
        } else {
            var children: [HostRow] = []
            insert(item, path: path.dropFirst(), parentPath: groupPath, into: &children)
            rows.append(HostRow(id: UUID.stable("ssh-group:\(groupPath)"), sortName: head, title: head,
                                detail: nil, kind: .sshGroup, separatorAfter: false, children: children))
        }
    }

    private static func sorted(_ rows: [HostRow]) -> [HostRow] {
        let byName: (HostRow, HostRow) -> Bool = {
            $0.sortName.localizedCaseInsensitiveCompare($1.sortName) == .orderedAscending
        }
        let groups = rows.filter(\.isGroup).sorted(by: byName).map { group in
            var group = group
            group.children = sorted(group.children ?? [])
            return group
        }
        return groups + rows.filter { !$0.isGroup }.sorted(by: byName)
    }
}

private struct HostRowLabel: View {
    let row: HostRow

    var body: some View {
        HStack(spacing: 6) {
            Label(row.title, systemImage: icon)
                .foregroundStyle(row.kind == .ssh || row.kind == .sshGroup ? .secondary : .primary)
            Spacer(minLength: 4)
            if let detail = row.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if row.separatorAfter {
                Image(systemName: "line.3.horizontal").font(.caption2).foregroundStyle(.tertiary)
                    .help("此项后有分隔线")
            }
        }
        .help(row.kind == .ssh ? "来自 ~/.ssh/config，只读" : "")
    }

    private var icon: String {
        switch row.kind {
        case .entry: "terminal"
        case .group: "folder"
        case .ssh: "network"
        case .sshGroup: "folder.badge.gearshape"
        }
    }
}

private struct EntryEditor: View {
    @Binding var entry: ConfigEntry
    @Binding var parent: UUID?
    let store: ConfigEditorStore

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $entry.menuName.title, prompt: Text("菜单里显示的名字"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("命令")
                    TextEditor(text: $entry.command)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 70, maxHeight: 160)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                    Text(commandHint).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("在哪里打开") {
                Picker("终端", selection: terminal) {
                    Text("跟随默认（\(store.canonicalTerminal(store.document.string("terminal")) ?? "Terminal")）")
                        .tag(String?.none)
                    Divider()
                    ForEach(store.terminalChoices, id: \.value) { choice in
                        Text(choice.label).tag(String?.some(choice.value))
                    }
                    if let unknown = unknownTerminal {
                        Text("\(unknown)（不支持）").tag(String?.some(unknown))
                    }
                }
                Picker("位置", selection: $entry.mode) {
                    Text("跟随默认（\(ModeChoice.label(store.document.string("open_in") == "new" ? "new" : "tab"))）")
                        .tag(String?.none)
                    Divider()
                    ForEach(ModeChoice.all, id: \.value) { choice in
                        Text(choice.label).tag(String?.some(choice.value))
                    }
                }
                ThemePicker(value: $entry.theme, terminals: themeTerminals,
                            noneLabel: inheritedTheme, store: store)
                if themeTerminals.isEmpty {
                    Text("\(effectiveTerminal) 不支持按名字切换外观，主题只对 Terminal 和 iTerm 有效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("窗口标题", text: $entry.title.orEmpty, prompt: Text(entry.menuName.title))
            }

            Section("菜单") {
                Picker("所在分组", selection: $parent) {
                    Text("顶层").tag(UUID?.none)
                    ForEach(store.document.groupPaths(), id: \.id) { group in
                        Text(group.path).tag(UUID?.some(group.id))
                    }
                }
                SortKeyField(value: $entry.menuName.sortKey)
                Toggle("在此项后加分隔线", isOn: $entry.menuName.separatorAfter)
            }

            Section {
                HStack {
                    Button("复制条目") { store.duplicate(entry.id) }
                    Spacer()
                    Button("运行测试") { store.run(entry.id) }
                        .disabled(entry.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("用当前（未保存的）设置运行一次")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var effectiveTerminal: String {
        store.canonicalTerminal(entry.terminal) ?? store.canonicalTerminal(store.document.string("terminal")) ?? "Terminal"
    }

    private var themeTerminals: [TerminalKind] {
        store.themeTerminal(entry.terminal).map { [$0] } ?? []
    }

    private var inheritedTheme: String {
        let global = store.document.string("default_theme").flatMap { $0.isEmpty ? nil : $0 }
        return global.map { "跟随默认（\($0)）" } ?? "跟随默认（终端自己的外观）"
    }

    private var commandHint: String {
        if entry.usesSeedmuxCommand {
            return "此条目来自旧的 Seedmux 转接配置，编辑的是 seedmux_command，原来的 cmd 链接保持不变。"
        }
        return "在终端里执行的命令；写成 https:// 之类的链接时会直接打开链接。"
    }

    /// Stored values like "Seedmux.app" are shown as the canonical "Seedmux".
    private var terminal: Binding<String?> {
        Binding(
            get: { store.canonicalTerminal(entry.terminal) },
            set: { entry.terminal = $0 }
        )
    }

    private var unknownTerminal: String? {
        guard let value = store.canonicalTerminal(entry.terminal),
              !store.terminalChoices.contains(where: { $0.value == value })
        else { return nil }
        return value
    }

}

private struct GroupEditor: View {
    @Binding var group: ConfigGroup
    @Binding var parent: UUID?
    let store: ConfigEditorStore

    var body: some View {
        Form {
            Section {
                TextField("分组名称", text: $group.menuName.title)
                LabeledContent("包含条目", value: "\(group.entryCount) 个")
            }
            Section("菜单") {
                Picker("所在分组", selection: $parent) {
                    Text("顶层").tag(UUID?.none)
                    ForEach(store.document.groupPaths(excluding: group.id), id: \.id) { candidate in
                        Text(candidate.path).tag(UUID?.some(candidate.id))
                    }
                }
                SortKeyField(value: $group.menuName.sortKey)
                Toggle("在此分组后加分隔线", isOn: $group.menuName.separatorAfter)
            }
            Section {
                HStack {
                    Button("在此分组中新建条目") {
                        store.hostSelection = group.id
                        store.addEntry()
                    }
                    Spacer()
                    Button("删除分组", role: .destructive) { store.delete(group.id) }
                }
            }
        }
        .formStyle(.grouped)
    }

}

/// Shuttle's `[abc]` sort key. Only 0 or 3 letters are committed, so typing
/// one letter at a time doesn't get wiped by the round trip through the raw name.
private struct SortKeyField: View {
    @Binding var value: String
    @State private var text = ""

    var body: some View {
        TextField("排序键", text: $text, prompt: Text("可选，三个小写字母，如 aaa"))
            .onAppear { text = value }
            .onChange(of: text) { _, newValue in
                let cleaned = String(newValue.lowercased().filter { $0.isASCII && $0.isLetter }.prefix(3))
                if cleaned != newValue { text = cleaned }
                if cleaned.isEmpty || cleaned.count == 3 { value = cleaned }
            }
            .help("菜单按名称排序；排序键会以 [abc] 的形式加在名称前，但不会显示")
    }
}

/// A host from ~/.ssh/config: shown as the menu will run it, edited in the ssh config itself.
private struct SSHHostDetail: View {
    let item: SSHItem
    let store: ConfigEditorStore

    var body: some View {
        Form {
            Section {
                LabeledContent("菜单名称", value: item.leaf)
                LabeledContent("菜单位置", value: item.groups.isEmpty ? "顶层" : item.groups.joined(separator: " / "))
                LabeledContent("执行命令") {
                    Text(item.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            } header: {
                Label("来自 ~/.ssh/config（只读）", systemImage: "network")
            } footer: {
                Text("名称和分组来自 Host 名（/ 会变成子菜单），也可以在 Host 下一行写 # shuttle.name 分组/名字 单独改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("连接信息") {
                LabeledContent("Host", value: item.host.alias)
                ForEach(Self.shownOptions, id: \.key) { option in
                    if let value = item.host.options[option.key] {
                        LabeledContent(option.label) {
                            Text(value).textSelection(.enabled)
                        }
                    }
                }
                LabeledContent("所在文件") {
                    Text(displayPath(item.host.file)).textSelection(.enabled)
                }
            }

            Section("打开方式") {
                LabeledContent("终端", value: "跟随默认（\(store.canonicalTerminal(store.document.string("terminal")) ?? "Terminal")）")
                LabeledContent("位置", value: "跟随默认（\(ModeChoice.label(store.document.string("open_in") == "new" ? "new" : "tab"))）")
                Text("想单独指定终端或位置，可以“转为可编辑条目”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("在编辑器中打开") {
                        store.openSSHConfig(file: item.host.file)
                    }
                    Button("在菜单中隐藏") { store.hideSSH(item) }
                        .help("加入“忽略这些主机”，保存后生效")
                    Button("转为可编辑条目") { store.convertSSH(item) }
                        .help("复制成普通条目，并隐藏 ssh 配置里的这一项，避免重复")
                    Spacer()
                    Button("运行测试") { store.runSSH(item) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static let shownOptions: [(key: String, label: String)] = [
        ("hostname", "HostName"), ("user", "User"), ("port", "Port"),
        ("identityfile", "IdentityFile"), ("proxyjump", "ProxyJump"),
    ]

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// A submenu that exists only because ssh_config host names contain `/`.
private struct SSHGroupDetail: View {
    let row: HostRow
    let store: ConfigEditorStore

    var body: some View {
        ContentUnavailableView {
            Label(row.title, systemImage: "folder.badge.gearshape")
        } description: {
            Text("这个子菜单来自 ~/.ssh/config 里带 / 的 Host 名，包含 \(row.children?.count ?? 0) 项。改名或调整要在 ssh 配置里改。")
        } actions: {
            Button("打开 ~/.ssh/config") { store.openSSHConfig() }
        }
    }
}
