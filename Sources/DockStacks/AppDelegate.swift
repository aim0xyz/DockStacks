import AppKit
import Shared

enum AgentState {
    /// DockStacks itself or one of its stack apps.
    static func isOwnApp(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return id == DS.agentBundleID || id.hasPrefix(DS.stubBundleIDPrefix)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StackStore.shared
    private var pendingSyncs: [UUID: DispatchWorkItem] = [:]
    private var didFinishLaunching = false
    private var queuedURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Listen as early as possible: a stack app may already be waiting for the grid.
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(showRequested(_:)), name: DS.showNotification, object: nil)
        center.addObserver(self, selector: #selector(addRequested(_:)), name: DS.addNotification, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        _ = AppCatalog.shared

        store.onStackChanged = { [weak self] stack in self?.stackChanged(stack) }
        store.onStackDeleted = { stack in
            StackPanelController.shared.close(animated: false)
            StubManager.shared.remove(stack)
        }
        StackPanelController.shared.onEditStack = { id in
            SettingsWindowController.shared.show(stackID: id)
        }

        // A click on a stack that started DockStacks is answered first; refreshing all stack apps can wait.
        didFinishLaunching = true
        handle(urls: queuedURLs)
        queuedURLs.removeAll()

        if store.loadFailed {
            // Never take stacks out of the Dock because their list could not be read.
            showLoadFailedAlert()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [store] in
                StubManager.shared.syncAll(store.stacks)
            }
            if !store.prefs.didOnboard {
                store.updatePrefs { $0.didOnboard = true }
                SettingsWindowController.shared.show()
            }
        }
    }

    private func showLoadFailedAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Deine Stapel konnten nicht gelesen werden"
        alert.informativeText = "Die Datei library.json ist beschädigt. Eine Kopie liegt im Ordner ~/Library/Application Support/DockStacks. Deine Stapel im Dock bleiben unverändert."
        alert.runModal()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // MARK: Requests from stack apps

    @objc private func showRequested(_ note: Notification) {
        guard let id = note.object as? String else { return }
        let x = note.userInfo?["x"] as? Double, y = note.userInfo?["y"] as? Double
        show(stackID: id, mouse: x.flatMap { x in y.map { CGPoint(x: x, y: $0) } })
    }

    @objc private func addRequested(_ note: Notification) {
        guard let id = note.object as? String, let paths = note.userInfo?["paths"] as? [String] else { return }
        add(paths: paths, to: id)
    }

    private func show(stackID: String, mouse: CGPoint?) {
        guard let stack = store.stack(id: stackID) else { return }
        StackPanelController.shared.toggle(stack, stubURL: StubManager.shared.bundleURL(for: stack), mouse: mouse)
    }

    private func add(paths: [String], to stackID: String) {
        guard let stack = store.stack(id: stackID) else { return }
        store.add(urls: paths.map { URL(fileURLWithPath: $0) }, to: stack.id)
    }

    // MARK: URL scheme (used when a stack app has to start DockStacks first)

    func application(_ application: NSApplication, open urls: [URL]) {
        guard didFinishLaunching else {
            queuedURLs += urls
            return
        }
        handle(urls: urls)
    }

    private func handle(urls: [URL]) {
        for url in urls where url.scheme == DS.urlScheme {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let id = query.first { $0.name == "id" }?.value ?? ""
            switch url.host {
            case "show":
                let x = query.first { $0.name == "x" }?.value.flatMap(Double.init)
                let y = query.first { $0.name == "y" }?.value.flatMap(Double.init)
                let mouse = x.flatMap { x in y.map { CGPoint(x: x, y: $0) } }
                // Give the freshly started stack apps a moment to settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.show(stackID: id, mouse: mouse) }
            case "add":
                add(paths: query.filter { $0.name == "path" }.compactMap(\.value), to: id)
            default:
                SettingsWindowController.shared.show(stackID: UUID(uuidString: id))
            }
        }
    }

    // MARK: Changes

    private func stackChanged(_ stack: AppStack) {
        StackPanelController.shared.stackDidChange(stack)
        // Coalesce quick edits before rebuilding the Dock app and its icon.
        pendingSyncs[stack.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.store.stack(stack.id) else { return }
            self.pendingSyncs[stack.id] = nil
            StubManager.shared.sync(current)
        }
        pendingSyncs[stack.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: Menu

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Über DockStacks", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Einstellungen …", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "DockStacks ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "DockStacks beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Bearbeiten")
        editMenu.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Fenster")
        windowMenu.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }
}
