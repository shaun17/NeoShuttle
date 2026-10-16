import SwiftUI
import NeoShuttleCore

struct SettingsView: View {
    @Bindable var store: ConfigEditorStore

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.loadError {
                LoadErrorView(message: error, store: store)
            } else {
                // Content fills the window; the tabs live in the title bar instead of a TabView box.
                PageSwitcher(store: store, tab: store.tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 540)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("页面", selection: $store.tab) {
                    Text("菜单条目").tag(SettingsTab.hosts)
                    Text("通用").tag(SettingsTab.general)
                    Text("自定义终端").tag(SettingsTab.terminals)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(store.loadError != nil)
            }
        }
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

/// Hosts each settings page in its own NSHostingView. All three are built when the window
/// opens and switching only toggles `isHidden`: nothing is rebuilt (rebuilding a page's list,
/// split view and form cost 20–115 ms, a visible stutter), and AppKit leaves hidden views out
/// of the key-view loop, so Tab can't move focus into a page you can't see.
private struct PageSwitcher: NSViewRepresentable {
    let store: ConfigEditorStore
    let tab: SettingsTab

    func makeNSView(context: Context) -> PageContainer {
        PageContainer(store: store)
    }

    func updateNSView(_ container: PageContainer, context: Context) {
        container.show(tab)
    }
}

private final class PageContainer: NSView {
    private var pages: [SettingsTab: NSView] = [:]

    init(store: ConfigEditorStore) {
        super.init(frame: .zero)
        let views: [(SettingsTab, NSView)] = [
            (.hosts, NSHostingView(rootView: HostsEditorView(store: store))),
            (.general, NSHostingView(rootView: GeneralSettingsView(store: store))),
            (.terminals, NSHostingView(rootView: CustomTerminalsView(store: store))),
        ]
        for (tab, page) in views {
            page.translatesAutoresizingMaskIntoConstraints = false
            page.isHidden = true
            addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: leadingAnchor),
                page.trailingAnchor.constraint(equalTo: trailingAnchor),
                page.topAnchor.constraint(equalTo: topAnchor),
                page.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            pages[tab] = page
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ tab: SettingsTab) {
        for (key, page) in pages {
            page.isHidden = key != tab
        }
    }
}
