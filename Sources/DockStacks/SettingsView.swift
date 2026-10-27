import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case stack(UUID)
    case general
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SidebarItem?
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    let navigation = SettingsNavigation()

    func show(stackID: UUID? = nil) {
        if let stackID {
            navigation.selection = .stack(stackID)
        } else if navigation.selection == nil {
            navigation.selection = StackStore.shared.stacks.first.map { .stack($0.id) }
        }

        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(navigation: navigation))
            let window = NSWindow(contentViewController: controller)
            window.title = "DockStacks"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 820, height: 600))
            window.minSize = NSSize(width: 680, height: 460)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("DockStacksSettings")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.orderFrontRegardless()
        window?.makeKey()
        bringToFront()
    }

    private var lastOpenRequest = Date.distantPast

    /// macOS often refuses to let a background app push itself in front of the app the user works in.
    /// If asking nicely did not work, DockStacks opens itself through LaunchServices, like a click on
    /// its icon would; that is always allowed. The resulting "reopen" shows this window again.
    private func bringToFront() {
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !NSApp.isActive, Date().timeIntervalSince(self.lastOpenRequest) > 2 else { return }
            self.lastOpenRequest = Date()
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
                if let error { NSLog("DockStacks: could not bring the settings to the front: \(error)") }
            }
        }
    }

    /// Ends text editing first, so a name typed without Return is saved.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            // Let the window and its views go, so their timers stop; the next show builds a fresh one.
            self.window = nil
            // Back to a background helper without its own Dock icon.
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var store = StackStore.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section("Stapel") {
                    ForEach(store.stacks) { stack in
                        StackRow(stack: stack)
                            .tag(SidebarItem.stack(stack.id))
                            .contextMenu {
                                Button("Stapel löschen", role: .destructive) { delete(stack) }
                            }
                    }
                    .onMove { store.moveStacks(from: $0, to: $1) }
                }
                Section {
                    Label("Allgemein", systemImage: "gearshape")
                        .tag(SidebarItem.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem {
                    Button {
                        let stack = store.createStack()
                        navigation.selection = .stack(stack.id)
                    } label: {
                        Label("Neuer Stapel", systemImage: "plus")
                    }
                    .help("Neuer Stapel")
                }
            }
        } detail: {
            switch navigation.selection {
            case .stack(let id) where store.stack(id) != nil:
                StackDetailView(stackID: id).id(id)
            case .general:
                GeneralSettingsView()
            default:
                WelcomeView {
                    let stack = store.createStack()
                    navigation.selection = .stack(stack.id)
                }
            }
        }
    }

    private func delete(_ stack: AppStack) {
        if navigation.selection == .stack(stack.id) { navigation.selection = nil }
        store.deleteStack(stack.id)
    }
}

struct StackRow: View {
    let stack: AppStack
    @ObservedObject private var catalog = AppCatalog.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconRenderer.image(for: stack, pixels: 96))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(stack.name).lineLimit(1)
                Text(stack.items.count == 1 ? "1 App" : "\(stack.items.count) Apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .loadsFullIcons(of: stack)
    }
}

struct WelcomeView: View {
    var create: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: IconRenderer.image(style: .folder, tint: .glass, icons: [], pixels: 256))
                .resizable()
                .frame(width: 110, height: 110)
            Text("Stapel für dein Dock")
                .font(.title2.weight(.semibold))
            Text("Fasse Apps zu Stapeln zusammen. Jeder Stapel bekommt ein eigenes Symbol im Dock und klappt beim Klick ein Raster auf, genau wie Downloads oder Dokumente.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Ersten Stapel anlegen", action: create)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Stack detail

struct StackDetailView: View {
    let stackID: UUID
    @ObservedObject private var store = StackStore.shared
    @ObservedObject private var catalog = AppCatalog.shared
    @State private var name = ""
    @State private var dockState = DockState()
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    private var stack: AppStack? { store.stack(stackID) }

    struct DockState: Equatable {
        var pinned = false
        var duplicates: [StackItem] = []
        var dockApps: [String] = []
    }

    var body: some View {
        if let stack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(stack)
                    dockBox(stack)
                    appsSection(stack)
                    suggestions(stack)
                    appearance(stack)
                    HStack {
                        Spacer()
                        Button("Stapel löschen …", role: .destructive) { confirmDelete = true }
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                name = stack.name
                refreshDock()
            }
            .onDisappear(perform: commitName)
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refreshDock() }
            .onChange(of: stack.items) { _, _ in refreshDock() }
            .confirmationDialog("„\(stack.name)“ löschen?", isPresented: $confirmDelete) {
                Button("Stapel löschen", role: .destructive) { store.deleteStack(stack.id) }
            } message: {
                Text("Der Stapel verschwindet aus dem Dock. Die Apps selbst bleiben installiert.")
            }
            .loadsFullIcons(of: stack)
        }
    }

    private func commitName() {
        store.rename(stackID, to: name)
        name = store.stack(stackID)?.name ?? name
    }

    private func refreshDock() {
        guard let stack else { return }
        let paths = DockBridge.persistentApps().compactMap(DockBridge.path(of:))
        let pinnedSet = Set(paths)
        var state = DockState()
        state.pinned = StubManager.shared.isPinned(stack)
        state.duplicates = stack.items.filter { pinnedSet.contains(URL(fileURLWithPath: $0.path).standardizedFileURL.path) }
        state.dockApps = paths.filter { $0.hasSuffix(".app") && !$0.contains("/DockStacks/Stacks/") }
        if state != dockState { dockState = state }
    }

    // MARK: Sections

    private func header(_ stack: AppStack) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: IconRenderer.image(for: stack, pixels: 256))
                .resizable()
                .frame(width: 92, height: 92)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .semibold))
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                Text(stack.items.count == 1 ? "1 App" : "\(stack.items.count) Apps")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dockBox(_ stack: AppStack) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if dockState.pinned {
                    HStack {
                        Label("Liegt im Dock", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Aus dem Dock nehmen") {
                            StubManager.shared.unpinStack(stack)
                            refreshDockSoon()
                        }
                    }
                    if !dockState.duplicates.isEmpty {
                        Divider()
                        HStack(alignment: .firstTextBaseline) {
                            Text(dockState.duplicates.count == 1
                                 ? "1 App aus diesem Stapel liegt zusätzlich einzeln im Dock."
                                 : "\(dockState.duplicates.count) Apps aus diesem Stapel liegen zusätzlich einzeln im Dock.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Dock aufräumen") {
                                StubManager.shared.unpinApps(of: stack)
                                refreshDockSoon()
                            }
                        }
                    }
                } else {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Noch nicht im Dock").font(.headline)
                            Text("Der Stapel bekommt ein eigenes Symbol zwischen deinen Apps.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Ins Dock legen") {
                            StubManager.shared.pin(stack, replacingApps: store.prefs.removeAppsFromDockWhenStacked)
                            refreshDockSoon()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Toggle("Apps aus diesem Stapel dabei aus dem Dock nehmen", isOn: Binding(
                        get: { store.prefs.removeAppsFromDockWhenStacked },
                        set: { value in store.updatePrefs { $0.removeAppsFromDockWhenStacked = value } }))
                        .toggleStyle(.checkbox)
                }
                Text("Das Dock lädt dafür einmal kurz neu. Deine Apps bleiben installiert.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(6)
        }
    }

    private func appsSection(_ stack: AppStack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Apps").font(.headline)
                Spacer()
                Picker("", selection: Binding(get: { stack.sort }, set: { store.setSort(stack.id, $0) })) {
                    ForEach(StackSort.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    chooseApps(for: stack)
                } label: {
                    Label("Apps hinzufügen …", systemImage: "plus")
                }
            }

            EditableAppGrid(stack: stack)
        }
    }

    private func suggestions(_ stack: AppStack) -> some View {
        let inStack = Set(stack.items.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let candidates = dockState.dockApps.filter { !inStack.contains($0) }
        return Group {
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Aus deinem Dock").font(.headline)
                    Text("Klick auf eine App, um sie in diesen Stapel zu legen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(candidates, id: \.self) { path in
                                Button {
                                    store.add(urls: [URL(fileURLWithPath: path)], to: stack.id)
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(nsImage: AppCatalog.shared.icon(forPath: path))
                                            .resizable()
                                            .frame(width: 44, height: 44)
                                        Text(AppCatalog.displayName(forPath: path))
                                            .font(.system(size: 10))
                                            .lineLimit(1)
                                            .frame(width: 70)
                                    }
                                    .padding(6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Zu „\(stack.name)“ hinzufügen")
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
    }

    private func appearance(_ stack: AppStack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Symbol im Dock").font(.headline)
            HStack(spacing: 18) {
                ForEach(IconStyle.allCases) { style in
                    Button {
                        store.setStyle(stack.id, style)
                    } label: {
                        VStack(spacing: 6) {
                            Image(nsImage: previewIcon(stack, style: style))
                                .resizable()
                                .frame(width: 64, height: 64)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(stack.iconStyle == style ? Color.accentColor : .clear, lineWidth: 2))
                            Text(style.title).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                ForEach(StackTint.allCases) { tint in
                    Button {
                        store.setTint(stack.id, tint)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: tint.swatch))
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                            .frame(width: 22, height: 22)
                            .padding(3)
                            .overlay(Circle().strokeBorder(stack.tint == tint ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(tint.title)
                }
            }
        }
    }

    // MARK: Actions

    private func previewIcon(_ stack: AppStack, style: IconStyle) -> NSImage {
        var preview = stack
        preview.iconStyle = style
        return IconRenderer.image(for: preview, pixels: 192)
    }

    private func refreshDockSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { refreshDock() }
    }

    private func chooseApps(for stack: AppStack) {
        let panel = NSOpenPanel()
        panel.title = "Apps zu „\(stack.name)“ hinzufügen"
        panel.prompt = "Hinzufügen"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        store.add(urls: panel.urls, to: stack.id)
    }
}

/// The apps of a stack in the settings window. Sorted by dragging; apps from the Finder can be dropped
/// in. Kept in its own view, so a drag redraws only this grid and not the rest of the window.
struct EditableAppGrid: View {
    let stack: AppStack
    @ObservedObject private var store = StackStore.shared
    @StateObject private var reorder = GridReorder()
    @State private var gridWidth: CGFloat = 600

    var body: some View {
        // Fixed columns that fill the width, so every point maps to exactly one place.
        let columnCount = max(1, Int(gridWidth / 100))
        let cell = CGSize(width: gridWidth / CGFloat(columnCount), height: 102)
        let order = stack.orderedItems
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell.width), spacing: 0), count: columnCount), spacing: 0) {
            ForEach(reorder.arranged(order)) { item in
                EditableAppTile(item: item) {
                    store.remove(itemID: item.id, from: stack.id)
                }
                .frame(width: cell.width, height: cell.height)
                .contentShape(Rectangle())
                .opacity(reorder.draggedID == item.id ? 0 : 1)
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(GridReorder.space))
                        .onChanged { reorder.drag(item.id, to: $0.location, items: order, columns: columnCount, cell: cell) }
                        .onEnded { _ in
                            if let drop = reorder.end() { store.move(itemID: drop.id, in: stack.id, to: drop.index) }
                        }
                )
            }
        }
        .coordinateSpace(name: GridReorder.space)
        .overlay(alignment: .topLeading) {
            if let id = reorder.draggedID, let item = order.first(where: { $0.id == id }) {
                DraggedIcon(pointer: reorder.pointer, image: AppCatalog.shared.icon(for: item), size: 56)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 20 } action: { gridWidth = max($0, 100) }
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
        .overlay {
            if stack.items.isEmpty {
                Text("Zieh Apps aus dem Finder hierher oder wähle unten welche aus deinem Dock.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers, location in
            let point = CGPoint(x: location.x - 10, y: location.y - 10)
            addDropped(providers, to: stack.id,
                       at: GridReorder.slot(at: point, columns: columnCount, cell: cell, count: order.count))
            return true
        }
    }

    /// Apps dragged in from the Finder, kept in the order they were dragged.
    private func addDropped(_ providers: [NSItemProvider], to stackID: UUID, at index: Int) {
        var urls = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        let lock = NSLock()
        for (i, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                lock.lock(); urls[i] = url; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { _ = StackStore.shared.add(urls: urls.compactMap { $0 }, to: stackID, at: index) }
        }
    }
}

struct EditableAppTile: View {
    let item: StackItem
    var remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: AppCatalog.shared.icon(for: item))
                .resizable()
                .frame(width: 52, height: 52)
            AppLabel(name: AppCatalog.displayName(for: item))
                .frame(width: 84, height: 28, alignment: .top)
        }
        .frame(width: 92)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(hovering ? 0.06 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .gray)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Aus dem Stapel entfernen")
                .offset(x: -6, y: 2)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Aus dem Stapel entfernen", action: remove)
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject private var store = StackStore.shared
    @State private var loginStatus = SMAppService.Status.notRegistered
    @State private var trusted = DockBridge.hasAccessibility

    var body: some View {
        Form {
            Section {
                // Bound straight to the system's status: no onChange that could undo a fresh registration.
                Toggle("Beim Anmelden starten", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { setLaunchAtLogin($0) }))
                if loginStatus == .requiresApproval {
                    LabeledContent("Wartet auf deine Freigabe") {
                        Button("Anmeldeobjekte öffnen …") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } footer: {
                Text("Damit deine Stapel nach einem Neustart sofort reagieren.")
            }

            Section("Raster") {
                LabeledContent("Symbolgröße") {
                    Slider(value: Binding(get: { store.prefs.gridIconSize },
                                          set: { v in store.updatePrefs { $0.gridIconSize = v } }),
                           in: 48...96, step: 8)
                        .frame(width: 220)
                }
                Toggle("Punkt unter laufenden Apps", isOn: Binding(
                    get: { store.prefs.showRunningIndicators },
                    set: { v in store.updatePrefs { $0.showRunningIndicators = v } }))
            }

            Section {
                LabeledContent("Genaue Position") {
                    if trusted {
                        Label("Aktiv", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Bedienungshilfen freigeben …") {
                            DockBridge.requestAccessibility()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } header: {
                Text("Position über dem Dock")
            } footer: {
                Text("Mit der Freigabe zeigt der Pfeil des Rasters genau auf das Stapel-Symbol, auch wenn das Dock vergrößert. Ohne Freigabe richtet sich das Raster nach dem Mauszeiger. DockStacks liest dabei nur die Position der Dock-Symbole.")
            }

            Section("DockStacks") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Button("Dock-Sicherungen im Finder zeigen") {
                    let folder = StackStore.supportFolder.appendingPathComponent("Backups")
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                Button("DockStacks beenden") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            trusted = DockBridge.hasAccessibility
            loginStatus = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("DockStacks: login item: \(error)")
        }
        loginStatus = SMAppService.mainApp.status
    }
}

extension View {
    /// Loads the large icons a stack's icon is drawn from; the icon is drawn again once they are there.
    func loadsFullIcons(of stack: AppStack) -> some View {
        let paths = stack.orderedItems.prefix(9).map(\.path)
        return task(id: paths) { AppCatalog.shared.loadFullIcons(paths) {} }
    }
}
