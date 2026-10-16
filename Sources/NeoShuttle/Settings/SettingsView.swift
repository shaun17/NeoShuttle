import SwiftUI
import NeoShuttleCore

struct SettingsView: View {
    @Bindable var store: ConfigEditorStore

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.loadError {
                LoadErrorView(message: error, store: store)
            } else {
                TabView(selection: $store.tab) {
                    HostsEditorView(store: store)
                        .tabItem { Label("菜单条目", systemImage: "list.bullet.indent") }
                        .tag(SettingsTab.hosts)
                    GeneralSettingsView(store: store)
                        .tabItem { Label("通用", systemImage: "gearshape") }
                        .tag(SettingsTab.general)
                    CustomTerminalsView(store: store)
                        .tabItem { Label("自定义终端", systemImage: "terminal") }
                        .tag(SettingsTab.terminals)
                }
                .padding([.horizontal, .top], 12)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 540)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if store.isDirty {
                Label("有未保存的修改", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            } else if let status = store.status {
                Text(status).foregroundStyle(.secondary)
            }
            Spacer()
            Button("放弃修改") { store.revert() }
                .disabled(!store.isDirty)
            Button("保存") {
                if store.save() { store.closeWindow?() }
            }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!store.isDirty)
        }
        .font(.callout)
        .padding(12)
    }
}

private struct LoadErrorView: View {
    let message: String
    let store: ConfigEditorStore

    var body: some View {
        ContentUnavailableView {
            Label("配置文件无法解析", systemImage: "exclamationmark.triangle")
        } description: {
            Text("\(message)\n修好之前这里不能编辑，以免保存时覆盖原文件。")
        } actions: {
            Button("用编辑器打开") { NSWorkspace.shared.open(ConfigStore.configURL) }
            Button("重新载入") { store.reload() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared pieces for the entry editor and the general settings.
enum ModeChoice {
    static let all: [(value: String, label: String)] = [
        ("new", "新窗口"), ("tab", "新标签页"), ("current", "当前窗口"), ("split", "分屏"),
    ]

    static func label(_ value: String) -> String {
        all.first { $0.value == value }?.label ?? value
    }
}

extension Binding where Value == String? {
    /// Treats nil and "" as the same thing for text fields.
    var orEmpty: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

/// Picks a Terminal profile or iTerm Profile by name instead of typing it from memory.
struct ThemePicker: View {
    @Binding var value: String?
    /// Which apps' profiles to offer; empty when the terminal in use has no themes.
    let terminals: [TerminalKind]
    /// The nil choice: "follow the default" for an entry, "none" for the global default.
    let noneLabel: String
    var subtitle: String?
    let store: ConfigEditorStore

    var body: some View {
        Picker(selection: selection) {
            Text(noneLabel).tag(String?.none)
            if terminals.contains(.terminal), !store.terminalProfiles.isEmpty {
                Section("Terminal 描述文件") {
                    ForEach(store.terminalProfiles, id: \.self) { name in
                        Text(name == store.terminalDefaultProfile ? "\(name)（Terminal 当前默认）" : name)
                            .tag(String?.some(name))
                    }
                }
            }
            if terminals.contains(.iTerm), !iTermOnly.isEmpty {
                Section("iTerm Profile") {
                    ForEach(iTermOnly, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }
            if let missing {
                Section {
                    // With no supporting terminal nothing is offered, so the name isn't "missing".
                    Text(terminals.isEmpty ? missing : "\(missing)（未找到）").tag(String?.some(missing))
                }
            }
        } label: {
            Text("主题")
            if let subtitle { Text(subtitle) }
        }
        .disabled(terminals.isEmpty)
    }

    /// "" in the file means the same as no theme.
    private var selection: Binding<String?> {
        Binding(
            get: { value.flatMap { $0.isEmpty ? nil : $0 } },
            set: { value = $0 }
        )
    }

    /// Names shown once even when both apps have them (tags must be unique).
    private var iTermOnly: [String] {
        let terminalNames = terminals.contains(.terminal) ? Set(store.terminalProfiles) : []
        return store.iTermProfiles.filter { !terminalNames.contains($0) }
    }

    /// A stored name that no longer exists stays visible instead of silently changing.
    private var missing: String? {
        guard let current = selection.wrappedValue else { return nil }
        let offered = (terminals.contains(.terminal) ? store.terminalProfiles : [])
            + (terminals.contains(.iTerm) ? store.iTermProfiles : [])
        return offered.contains(current) ? nil : current
    }
}
