import AppKit
import Combine
import QuickLookThumbnailing

/// Names, icons and running state of the apps that live in stacks.
@MainActor
final class AppCatalog: ObservableObject {
    static let shared = AppCatalog()

    @Published private(set) var runningPaths: Set<String> = []

    private var iconCache: [String: NSImage] = [:]
    /// Large icons for drawing the stacks' Dock icons; see `loadFullIcons`.
    private var fullIcons: [String: NSImage] = [:]
    nonisolated(unsafe) private static var nameCache: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        refreshRunning()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
        // Menus offer "Ausblenden" or "Einblenden" depending on this.
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            })
        }
    }

    private func refreshRunning() {
        let paths = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path }
        let set = Set(paths)
        if set != runningPaths { runningPaths = set }
    }

    func isRunning(_ item: StackItem) -> Bool {
        runningPaths.contains(URL(fileURLWithPath: item.path).standardizedFileURL.path)
    }

    func runningApp(for item: StackItem) -> NSRunningApplication? {
        let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == path }
    }

    func icon(for item: StackItem) -> NSImage {
        icon(forPath: item.path)
    }

    func icon(forPath path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    func forgetIcon(forPath path: String) {
        iconCache[path] = nil
        fullIcons[path] = nil
    }

    /// The large icon of an app, once `loadFullIcons` has fetched it.
    func fullIcon(forPath path: String) -> NSImage? {
        fullIcons[path]
    }

    /// Fetches large icons through Quick Look and calls back once all are there. Quick Look waits until
    /// the system has really drawn an icon; a workspace icon drawn large right away can still be a
    /// grey placeholder.
    func loadFullIcons(_ paths: [String], completion: @escaping @MainActor () -> Void) {
        let missing = Set(paths).filter { fullIcons[$0] == nil }
        guard !missing.isEmpty else {
            completion()
            return
        }
        let group = DispatchGroup()
        for path in missing {
            group.enter()
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 512, height: 512),
                                                       scale: 2, representationTypes: .icon)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                let cgImage = representation?.cgImage
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let cgImage {
                            self.fullIcons[path] = NSImage(cgImage: cgImage, size: NSSize(width: 512, height: 512))
                        }
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                self.objectWillChange.send()
                completion()
            }
        }
    }

    nonisolated static func displayName(for item: StackItem) -> String {
        displayName(forPath: item.path)
    }

    nonisolated static func displayName(forPath path: String) -> String {
        if let cached = nameCache[path] { return cached }
        let url = URL(fileURLWithPath: path)
        var name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            ?? url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        nameCache[path] = name
        return name
    }

    /// Finds the app again if it was moved or renamed, using its bundle identifier.
    nonisolated static func resolve(_ item: StackItem) -> StackItem? {
        if FileManager.default.fileExists(atPath: item.path) { return item }
        guard let bundleID = item.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        var moved = item
        moved.path = url.path
        return moved
    }

    nonisolated static func makeItem(for url: URL) -> StackItem? {
        let url = url.standardizedFileURL
        guard url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return StackItem(path: url.path, bundleID: Bundle(url: url)?.bundleIdentifier)
    }
}
