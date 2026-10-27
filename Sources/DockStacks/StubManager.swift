import AppKit
import CoreServices
import Shared

/// Creates, updates and removes the small per-stack apps that sit in the Dock.
///
/// Each stack gets its own app bundle in ~/Library/Application Support/DockStacks/Stacks, copied from
/// the StackStub template inside DockStacks.app. The bundle carries the stack's name, a unique bundle
/// identifier and the generated stack icon, so the Dock treats it like any other app.
@MainActor
final class StubManager {
    static let shared = StubManager()

    let folder = StackStore.supportFolder.appendingPathComponent("Stacks", isDirectory: true)

    private var templateURL: URL? { Bundle.main.url(forResource: "StackStub", withExtension: "app") }

    private lazy var templateVersion: String = {
        guard let url = templateURL,
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return "" }
        return info[DS.templateVersionInfoKey] as? String ?? ""
    }()

    /// What each stack's Dock icon was last drawn from, so an unchanged icon is not drawn again.
    private var iconKeys = UserDefaults.standard.dictionary(forKey: "iconKeys") as? [String: String] ?? [:]
    /// Counts icon updates per stack; only the latest one is written when several overlap.
    private var iconGeneration: [UUID: Int] = [:]
    /// Icons are drawn and written here one after another, in the order they were asked for.
    private let iconQueue = DispatchQueue(label: "local.dockstacks.icons", qos: .userInitiated)

    // MARK: Lookup

    /// Existing bundles by stack ID. Read from disk once, and again after this class changed the folder.
    private var bundleCache: [String: URL]?

    private func existingBundles() -> [String: URL] {
        if let bundleCache { return bundleCache }
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var result: [String: URL] = [:]
        for url in urls where url.pathExtension == "app" {
            if let id = info(of: url)?[DS.stackIDInfoKey] as? String { result[id.uppercased()] = url }
        }
        bundleCache = result
        return result
    }

    func bundleURL(for stack: AppStack) -> URL? {
        let id = stack.id.uuidString.uppercased()
        if let url = existingBundles()[id], FileManager.default.fileExists(atPath: url.path) { return url }
        bundleCache = nil  // changed behind our back: look again
        return existingBundles()[id]
    }

    private func info(of bundle: URL) -> NSMutableDictionary? {
        NSMutableDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    private func fileName(for stack: AppStack) -> String {
        stack.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".app"
    }

    // MARK: Sync

    /// Brings every stack app up to date. With `removeOthers`, stack apps that belong to no stack are deleted.
    func syncAll(_ stacks: [AppStack], removeOthers: Bool = true) {
        guard hasTemplate else { return }
        bundleCache = nil
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if removeOthers {
            let wanted = Set(stacks.map { $0.id.uuidString.uppercased() })
            for (id, url) in existingBundles() where !wanted.contains(id) {
                removeBundle(at: url, bundleID: info(of: url)?["CFBundleIdentifier"] as? String)
            }
        }
        for stack in stacks { sync(stack) }
    }

    /// Without the template (for example when run with `swift run`) the stack apps are left alone,
    /// instead of being treated as outdated and deleted.
    private var hasTemplate: Bool {
        guard templateURL != nil, !templateVersion.isEmpty else {
            NSLog("DockStacks: StackStub template missing, leaving stack apps untouched")
            return false
        }
        return true
    }

    /// Makes sure the stack's Dock app exists, has the right name and icon, and is running.
    func sync(_ stack: AppStack) {
        guard hasTemplate else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = bundleURL(for: stack)

        if let existing = url,
           (info(of: existing)?[DS.templateVersionInfoKey] as? String) != templateVersion {
            // Built from an older template: replace it, keeping the location.
            terminate(bundleID: stack.stubBundleID)
            try? FileManager.default.removeItem(at: existing)
            bundleCache = nil
            url = nil
        }

        let target = folder.appendingPathComponent(fileName(for: stack))
        var renamedFrom: URL?
        // configure() removes the icon, so it has to be drawn again.
        var iconRemoved = false
        if let existing = url, existing.lastPathComponent != target.lastPathComponent {
            terminate(bundleID: stack.stubBundleID)
            do {
                try FileManager.default.moveItem(at: existing, to: target)
                bundleCache = nil
                renamedFrom = existing
                url = target
                configure(bundle: target, for: stack)
                iconRemoved = true
            } catch {
                NSLog("DockStacks: rename failed: \(error)")
            }
        }

        if url == nil {
            guard let template = templateURL else {
                NSLog("DockStacks: StackStub template missing")
                return
            }
            do {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: template, to: target)
                bundleCache = nil
                configure(bundle: target, for: stack)
                iconRemoved = true
                url = target
            } catch {
                NSLog("DockStacks: could not create stack app: \(error)")
                return
            }
        }

        guard let bundle = url else { return }
        updateIcon(for: stack, bundle: bundle, force: iconRemoved)

        if renamedFrom != nil, DockBridge.isPinned(bundleID: stack.stubBundleID) {
            DockBridge.modifyPinnedApps { tiles in
                for i in tiles.indices where DockBridge.bundleID(of: tiles[i]) == stack.stubBundleID {
                    tiles[i] = DockBridge.makeTile(url: bundle, label: stack.name, bundleID: stack.stubBundleID)
                }
            }
        }
        launchInBackground(bundle: bundle, bundleID: stack.stubBundleID)
    }

    /// Writes the stack's identity into the bundle and signs it again.
    private func configure(bundle: URL, for stack: AppStack) {
        guard let info = info(of: bundle) else { return }
        info["CFBundleIdentifier"] = stack.stubBundleID
        info["CFBundleName"] = stack.name
        info["CFBundleDisplayName"] = stack.name
        info[DS.stackIDInfoKey] = stack.id.uuidString
        info.write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true)
        // The custom icon (the Icon\r file and the folder's Finder info) is not allowed in a signed
        // bundle; drop it before signing. updateIcon puts it back afterwards.
        try? FileManager.default.removeItem(at: bundle.appendingPathComponent("Icon\r"))
        _ = bundle.path.withCString { removexattr($0, "com.apple.FinderInfo", XATTR_NOFOLLOW) }
        removeQuarantine(from: bundle)
        sign(bundle)
    }

    /// A stack app copied out of a downloaded DockStacks.app inherits the download's quarantine flag,
    /// and Gatekeeper refuses to open it once it is signed ad hoc. DockStacks made it, so drop the flag.
    private func removeQuarantine(from bundle: URL) {
        let items = FileManager.default.enumerator(atPath: bundle.path)?.compactMap { $0 as? String } ?? []
        for path in [bundle.path] + items.map({ bundle.appendingPathComponent($0).path }) {
            _ = path.withCString { removexattr($0, "com.apple.quarantine", XATTR_NOFOLLOW) }
        }
    }

    private func sign(_ bundle: URL) {
        let task = Process()
        let errors = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--force", "--sign", "-", "--timestamp=none", bundle.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errors
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                NSLog("DockStacks: codesign failed for \(bundle.lastPathComponent): \(message)")
            }
        } catch {
            NSLog("DockStacks: codesign failed: \(error)")
        }
    }

    /// Draws the stack's Dock icon, once the large icons of its apps are loaded. Skipped when nothing
    /// the icon shows has changed since last time.
    private func updateIcon(for stack: AppStack, bundle: URL, force: Bool) {
        let apps = stack.orderedItems.prefix(9).map(\.path)
        let key = "\(IconRenderer.version)|\(stack.iconStyle.rawValue)|\(stack.tint.rawValue)|" + apps.joined(separator: "|")
        let id = stack.id.uuidString
        guard force || iconKeys[id] != key else { return }
        let generation = (iconGeneration[stack.id] ?? 0) + 1
        iconGeneration[stack.id] = generation

        AppCatalog.shared.loadFullIcons(apps) { [weak self] in
            guard let self, self.iconGeneration[stack.id] == generation else { return }
            let catalog = AppCatalog.shared
            let icons = stack.orderedItems.prefix(9).map { catalog.fullIcon(forPath: $0.path) ?? catalog.icon(for: $0) }
            let style = stack.iconStyle, tint = stack.tint
            // Drawing and writing the large icon takes a moment; keep it off the main thread.
            self.iconQueue.async {
                let image = IconRenderer.image(style: style, tint: tint, icons: Array(icons))
                NSWorkspace.shared.setIcon(image, forFile: bundle.path, options: [])
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // The Dock picks a new icon up quickly only when the bundle itself looks changed.
                        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: bundle.path)
                        NSWorkspace.shared.noteFileSystemChanged(bundle.path)
                        LSRegisterURL(bundle as CFURL, true)
                        self.iconKeys[id] = key
                        UserDefaults.standard.set(self.iconKeys, forKey: "iconKeys")
                    }
                }
            }
        }
    }

    // MARK: Processes

    func launchInBackground(bundle: URL, bundleID: String) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        config.arguments = [DS.backgroundLaunchArgument]
        NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, error in
            if let error { NSLog("DockStacks: could not start stack app: \(error)") }
        }
    }

    private func terminate(bundleID: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, running.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    // MARK: Removal

    func remove(_ stack: AppStack) {
        guard let url = bundleURL(for: stack) else {
            unpin(bundleID: stack.stubBundleID)
            return
        }
        removeBundle(at: url, bundleID: stack.stubBundleID)
    }

    private func removeBundle(at url: URL, bundleID: String?) {
        if let bundleID {
            terminate(bundleID: bundleID)
            unpin(bundleID: bundleID)
        }
        LSRegisterURL(url as CFURL, false)
        try? FileManager.default.removeItem(at: url)
        bundleCache = nil
    }

    private func unpin(bundleID: String) {
        guard DockBridge.isPinned(bundleID: bundleID) else { return }
        DockBridge.modifyPinnedApps { tiles in
            tiles.removeAll { DockBridge.bundleID(of: $0) == bundleID }
        }
    }

    // MARK: Dock

    func isPinned(_ stack: AppStack) -> Bool {
        DockBridge.isPinned(bundleID: stack.stubBundleID)
    }

    /// Puts the stack into the Dock. When `replacingApps` is set, the stack takes the place of the
    /// first of its apps in the Dock, and those apps are unpinned (they stay installed).
    /// A stack that is already in the Dock keeps its place.
    func pin(_ stack: AppStack, replacingApps: Bool) {
        sync(stack)
        guard let bundle = bundleURL(for: stack) else { return }
        let appPaths = Set(stack.items.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        DockBridge.modifyPinnedApps { tiles in
            let isStack = { (tile: [String: Any]) in DockBridge.bundleID(of: tile) == stack.stubBundleID }
            let isStackApp = { (tile: [String: Any]) in DockBridge.path(of: tile).map(appPaths.contains) ?? false }
            let anchor = tiles.firstIndex(where: isStack) ?? (replacingApps ? tiles.firstIndex(where: isStackApp) : nil)
            if let anchor {
                if !isStack(tiles[anchor]) {
                    tiles[anchor] = DockBridge.makeTile(url: bundle, label: stack.name, bundleID: stack.stubBundleID)
                }
            } else {
                tiles.append(DockBridge.makeTile(url: bundle, label: stack.name, bundleID: stack.stubBundleID))
            }
            let keep = anchor ?? tiles.count - 1
            tiles = tiles.enumerated()
                .filter { index, tile in index == keep || !(isStack(tile) || (replacingApps && isStackApp(tile))) }
                .map(\.element)
        }
    }

    /// Unpins the stack's apps from the Dock (the apps stay installed and stay in the stack).
    func unpinApps(of stack: AppStack) {
        let appPaths = Set(stack.items.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        DockBridge.modifyPinnedApps { tiles in
            tiles.removeAll { DockBridge.path(of: $0).map(appPaths.contains) ?? false }
        }
    }

    func unpinStack(_ stack: AppStack) {
        unpin(bundleID: stack.stubBundleID)
    }

    /// Apps of this stack that are also pinned on their own in the Dock.
    func appsAlsoInDock(_ stack: AppStack) -> [StackItem] {
        let pinned = DockBridge.pinnedPaths()
        return stack.items.filter { pinned.contains(URL(fileURLWithPath: $0.path).standardizedFileURL.path) }
    }
}
