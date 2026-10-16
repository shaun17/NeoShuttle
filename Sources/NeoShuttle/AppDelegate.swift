import AppKit
import NeoShuttleCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var config: ShuttleConfig?
    private let launcher = Launcher()
    private lazy var settings = SettingsWindowController(launcher: launcher)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: "NeoShuttle")
        image?.isTemplate = true
        item.button?.image = image
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        NSApp.mainMenu = Self.mainMenu()
        #if DEBUG
        // Lets tests open the settings window the way the menu does: while another app is frontmost.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("NeoShuttle.debug.openSettings"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }
        runDebugLaunchIfRequested()
        if CommandLine.arguments.contains("--debug-open-settings") {
            openSettings()
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--debug-tab"), args.count > index + 1 {
                settings.store.tab = ["general": .general, "terminals": .terminals][args[index + 1]] ?? .hosts
            }
            if args.contains("--debug-select-entry") {
                // The first top-level entry in menu order.
                settings.store.hostSelection = ConfigNode.menuOrder(settings.store.document.hosts)
                    .first { if case .entry = $0 { true } else { false } }?.id
            }
            if args.contains("--debug-add-terminal") { settings.store.addTerminal() }
            if let index = args.firstIndex(of: "--debug-window-height"), args.count > index + 1,
               let height = Double(args[index + 1]), let window = settings.window {
                window.setFrame(NSRect(x: window.frame.minX, y: 40, width: window.frame.width, height: height), display: true)
            }
            if let index = args.firstIndex(of: "--debug-select-ssh"), args.count > index + 1 {
                settings.store.hostSelection = settings.store.visibleSSHHosts.first { $0.host.alias == args[index + 1] }?.id
            }
            if args.contains("--debug-save-test") {
                // Edit through the same store calls the UI uses, save, then quit.
                // Never against the real config: it must point at a scratch file.
                guard ProcessInfo.processInfo.environment["NEOSHUTTLE_CONFIG"] != nil else {
                    print("debug-save-test refused: set NEOSHUTTLE_CONFIG to a scratch file")
                    NSApp.terminate(nil)
                    return
                }
                let store = settings.store
                store.addGroup()
                store.addEntry()
                if let id = store.hostSelection, let entry = store.entry(id) {
                    entry.wrappedValue.menuName.title = "GUI 新条目"
                    entry.wrappedValue.command = "echo saved"
                    entry.wrappedValue.mode = "split"
                }
                store.document.setString("terminal", "Ghostty")
                // Same path as the Save button.
                let ok = store.save()
                if ok { store.closeWindow?() }
                print("debug-save-test saved=\(ok) windowVisible=\(settings.window?.isVisible == true)")
                NSApp.terminate(nil)
            }
        }
        #endif
    }

    // Rebuilt on every open, so edits to the config show up without a reload command.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        do {
            let loaded = try ConfigStore.load()
            config = loaded
            for warning in loaded.warnings {
                menu.addItem(disabledItem("⚠️ " + warning))
            }
            if !loaded.warnings.isEmpty { menu.addItem(.separator()) }
            add(loaded.menu, to: menu)
            if loaded.menu.isEmpty {
                menu.addItem(disabledItem("配置中没有条目"))
            }
        } catch {
            config = nil
            menu.addItem(disabledItem("无法读取配置"))
            menu.addItem(disabledItem(error.localizedDescription))
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("设置…", #selector(openSettings), key: ","))
        menu.addItem(actionItem("编辑配置文件…", #selector(editConfig)))
        let login = actionItem("登录时启动", #selector(toggleLoginItem))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(actionItem("关于 NeoShuttle", #selector(showAbout)))
        menu.addItem(actionItem("退出 NeoShuttle", #selector(quit), key: "q"))
    }

    private func add(_ nodes: [MenuNode], to menu: NSMenu) {
        for node in nodes {
            let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
            switch node.kind {
            case .host(let host):
                item.action = #selector(openHost(_:))
                item.target = self
                item.representedObject = HostBox(host)
            case .group(let children):
                let submenu = NSMenu(title: node.title)
                submenu.autoenablesItems = false
                add(children, to: submenu)
                item.submenu = submenu
            }
            menu.addItem(item)
            if node.separatorAfter { menu.addItem(.separator()) }
        }
    }

    @objc private func openHost(_ sender: NSMenuItem) {
        guard let host = (sender.representedObject as? HostBox)?.host, let config else { return }
        launcher.launch(config.action(for: host))
    }

    @objc private func openSettings() {
        // Wait for the status menu to finish closing before taking focus.
        DispatchQueue.main.async { self.settings.show() }
    }

    /// Clicking the Dock icon while the settings window is open brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, settings.window?.isVisible == false, NSApp.activationPolicy() == .regular { settings.show() }
        return true
    }

    /// Menu-bar apps get no main menu, and without an Edit menu text fields lose
    /// ⌘C / ⌘V / ⌘Z. It is never visible while NeoShuttle runs as an accessory,
    /// and becomes the real menu bar while the settings window gives the app a Dock icon.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        submenu("NeoShuttle", [
            item("关于 NeoShuttle", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("隐藏 NeoShuttle", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("退出 NeoShuttle", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("编辑", [
            item("撤销", Selector(("undo:")), "z"),
            item("重做", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x"),
            item("拷贝", #selector(NSText.copy(_:)), "c"),
            item("粘贴", #selector(NSText.paste(_:)), "v"),
            item("全选", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("窗口", [
            item("关闭", #selector(NSWindow.performClose(_:)), "w"),
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }

    @objc private func editConfig() {
        let url = ConfigStore.configURL
        try? ConfigStore.createDefaultIfMissing(at: url)
        let editor = config?.editor ?? "default"
        if editor == "default" {
            NSWorkspace.shared.open(url)
            return
        }
        // An app name or bundle id ("Cursor", "Zed", "com.microsoft.VSCode") opens there;
        // anything else is a terminal editor command such as vi or nano.
        if let app = AppLocator.find(named: editor) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            Task {
                do {
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
                } catch {
                    Launcher.present(error)
                }
            }
            return
        }
        let request = TerminalRequest(
            terminal: config?.terminal ?? .builtin(.terminal),
            command: "\(editor) \(ShellQuote.quote(url.path))",
            mode: .new,
            theme: config?.defaultTheme,
            title: ".shuttle.json"
        )
        launcher.launch(.run(request))
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            Launcher.present(error)
        }
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    #if DEBUG
    /// `open NeoShuttle.app --args --debug-launch <terminal> <mode> <command>`
    /// exercises a launcher without clicking the menu.
    private func runDebugLaunchIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--debug-launch"), args.count > index + 3,
              let mode = OpenMode(configValue: args[index + 2])
        else { return }
        // `custom:<launch template>` exercises the custom_terminals path.
        let name = args[index + 1]
        let terminal: TerminalTarget
        if name.hasPrefix("custom:") {
            terminal = .custom(CustomTerminal(name: "debug", method: .launch(template: String(name.dropFirst(7)))))
        } else if let kind = TerminalKind(configValue: name) {
            terminal = .builtin(kind)
        } else {
            return
        }
        let request = TerminalRequest(
            terminal: terminal, command: args[index + 3], mode: mode, theme: nil, title: "NeoShuttle debug")
        launcher.launch(.run(request))
    }
    #endif
}

/// NSMenuItem.representedObject wants a class.
private final class HostBox {
    let host: HostEntry
    init(_ host: HostEntry) { self.host = host }
}
