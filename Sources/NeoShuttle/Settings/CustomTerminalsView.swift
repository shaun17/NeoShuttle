import SwiftUI
import NeoShuttleCore

struct CustomTerminalsView: View {
    @Bindable var store: ConfigEditorStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $store.terminalSelection) {
                    ForEach(store.document.customTerminals) { terminal in
                        Label(terminal.name, systemImage: terminal.kind == .launch ? "chevron.left.forwardslash.chevron.right" : "keyboard")
                            .tag(terminal.id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 4) {
                    Button { store.addTerminal() } label: { Image(systemName: "plus") }
                        .help("新建自定义终端")
                    Button {
                        if let selection = store.terminalSelection { store.deleteTerminal(selection) }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(store.terminalSelection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)

            detail
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = store.terminalSelection, let terminal = store.terminal(id) {
            TerminalEditor(terminal: terminal, store: store)
                .id(id)
        } else {
            ContentUnavailableView {
                Label("自定义终端", systemImage: "terminal")
            } description: {
                Text("内置 8 种终端以外的应用可以在这里接入：能用命令行启动的写启动模板，完全没有接口的用模拟按键。定义好之后，在条目或通用设置里就能选它。")
            } actions: {
                Button("新建自定义终端") { store.addTerminal() }
            }
        }
    }
}

private struct TerminalEditor: View {
    @Binding var terminal: CustomTerminalSpec
    let store: ConfigEditorStore
    @State private var name = ""

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name)
                    .onAppear { name = terminal.name }
                    .onSubmit(commitName)
                    .onChange(of: name) { _, _ in commitName() }
                if let problem = nameProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                Picker("方式", selection: $terminal.kind) {
                    Text("启动命令").tag(CustomTerminalSpec.Kind.launch)
                    Text("模拟按键").tag(CustomTerminalSpec.Kind.keystroke)
                }
                .pickerStyle(.segmented)
            }

            switch terminal.kind {
            case .launch:
                Section {
                    TextField("启动模板", text: $terminal.launch, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...5)
                    if !terminal.launch.contains("{cmd}") {
                        Text("模板里没有 {cmd}，命令不会被传给终端。").font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("在登录 shell 里执行。{cmd} 和 {title} 会替换成已加好引号的参数，不要再给它们加引号。例如：open -na Rio --args -e /bin/zsh -lic {cmd}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .keystroke:
                Section {
                    TextField("应用", text: $terminal.app, prompt: Text("应用名或 bundle id，留空则用名称"))
                    LabeledContent("等待时间") {
                        HStack {
                            Slider(value: $terminal.delay, in: 0.2...5, step: 0.1)
                            Text(terminal.delay.formatted(.number.precision(.fractionLength(1))) + " 秒")
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                } footer: {
                    Text("把应用切到前台，按 ⌘N（新窗口）或 ⌘T（标签），等待上面的时间后输入命令并回车。需要在 系统设置 › 隐私与安全性 › 辅助功能 中允许 NeoShuttle。等待期间焦点被切走会放弃发送。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Text("被 \(usageCount) 个条目使用").foregroundStyle(.secondary)
                    Spacer()
                    Button("测试") { store.testTerminal(terminal.name) }
                        .help("用当前（未保存的）设置在新标签执行 echo")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "名称不能为空" }
        if store.document.customTerminals.contains(where: { $0.id != terminal.id && $0.name.lowercased() == trimmed.lowercased() }) {
            return "已有同名的自定义终端"
        }
        if TerminalKind(configValue: trimmed) != nil {
            return "与内置终端同名：使用这个名字的地方会改用这里的定义"
        }
        return nil
    }

    /// Renames propagate to every entry using this terminal, so only valid names are committed.
    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != terminal.name,
              !store.document.customTerminals.contains(where: { $0.id != terminal.id && $0.name.lowercased() == trimmed.lowercased() })
        else { return }
        terminal.name = trimmed
    }

    private var usageCount: Int {
        func count(_ nodes: [ConfigNode]) -> Int {
            nodes.reduce(0) { total, node in
                switch node {
                case .entry(let entry):
                    total + (entry.terminal?.lowercased() == terminal.name.lowercased() ? 1 : 0)
                case .group(let group):
                    total + count(group.children)
                }
            }
        }
        return count(store.document.hosts)
    }
}
