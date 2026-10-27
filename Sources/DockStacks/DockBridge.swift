import AppKit
import ApplicationServices

enum DockEdge {
    case bottom, left, right
}

/// Everything that talks to the macOS Dock: its settings, its pinned apps and (with the
/// Accessibility permission) the exact on-screen position of an icon.
@MainActor
enum DockBridge {
    private static let domain = "com.apple.dock" as CFString

    // MARK: Settings

    private static func value(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    static var edge: DockEdge {
        switch value("orientation") as? String {
        case "left": .left
        case "right": .right
        default: .bottom
        }
    }

    static var autohides: Bool { (value("autohide") as? Bool) ?? false }
    static var showsProcessIndicators: Bool { (value("show-process-indicators") as? Bool) ?? true }
    /// Icon size in the Dock, in points.
    static var tileSize: CGFloat { CGFloat((value("tilesize") as? Double) ?? 48) }

    // MARK: Pinned apps

    static func persistentApps() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain)
        return value("persistent-apps") as? [[String: Any]] ?? []
    }

    static func bundleID(of tile: [String: Any]) -> String? {
        (tile["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
    }

    static func path(of tile: [String: Any]) -> String? {
        guard let fileData = (tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any],
              let string = fileData["_CFURLString"] as? String,
              let url = URL(string: string), url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }

    static func isPinned(bundleID: String) -> Bool {
        persistentApps().contains { Self.bundleID(of: $0) == bundleID }
    }

    static func pinnedPaths() -> Set<String> {
        Set(persistentApps().compactMap(path(of:)))
    }

    static func makeTile(url: URL, label: String, bundleID: String) -> [String: Any] {
        let url = URL(fileURLWithPath: url.path, isDirectory: true)
        var tileData: [String: Any] = [
            "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15],
            "file-label": label,
            "file-type": 41,
            "bundle-identifier": bundleID,
            "dock-extra": false,
            "is-beta": false,
        ]
        if let bookmark = try? url.bookmarkData() { tileData["book"] = bookmark }
        return ["tile-data": tileData, "tile-type": "file-tile", "GUID": Int.random(in: 1...Int(Int32.max))]
    }

    /// Changes the list of pinned apps and restarts the Dock once so it picks the change up.
    /// A copy of the previous list is kept in Application Support/DockStacks/Backups.
    @discardableResult
    static func modifyPinnedApps(_ change: (inout [[String: Any]]) -> Void) -> Bool {
        let before = persistentApps()
        var after = before
        change(&after)
        guard !(before as NSArray).isEqual(to: after) else { return false }
        backup(before)
        CFPreferencesSetAppValue("persistent-apps" as CFString, after as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        restartDock()
        return true
    }

    static func restartDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
    }

    private static func backup(_ tiles: [[String: Any]]) {
        let folder = StackStore.supportFolder.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
            .replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("persistent-apps-\(stamp).plist")
        if let data = try? PropertyListSerialization.data(fromPropertyList: tiles, format: .xml, options: 0) {
            try? data.write(to: file)
        }
        // Keep the 20 most recent automatic backups (the original backup is never touched).
        let backups = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("persistent-apps-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: Icon position (Accessibility)

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Dock items found before, by app path. They stay valid until the Dock restarts.
    private static var itemCache: [String: AXUIElement] = [:]

    /// Screen frame (Cocoa coordinates) of the Dock icon for the app at `url`.
    static func iconFrame(forAppAt url: URL, label: String) -> CGRect? {
        guard hasAccessibility,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let wanted = url.standardizedFileURL.path
        if let item = itemCache[wanted], path(of: item) == wanted, let frame = frame(of: item) {
            return cocoaRect(fromAX: frame)
        }
        itemCache[wanted] = nil

        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Matched by path. The name is only a fallback for items without a readable path, so a stack
        // named like an app in the Dock never points at that app.
        var byName: CGRect?
        for list in children(of: app) where string(list, kAXRoleAttribute) == kAXListRole {
            for item in children(of: list) {
                if let itemPath = path(of: item) {
                    guard itemPath == wanted, let frame = frame(of: item) else { continue }
                    AXUIElementSetMessagingTimeout(item, 0.25)
                    itemCache[wanted] = item
                    return cocoaRect(fromAX: frame)
                } else if byName == nil, string(item, kAXTitleAttribute) == label,
                          string(item, kAXSubroleAttribute) == "AXApplicationDockItem", let frame = frame(of: item) {
                    byName = cocoaRect(fromAX: frame)
                }
            }
        }
        return byName
    }

    private static func path(of item: AXUIElement) -> String? {
        guard let raw = attribute(item, kAXURLAttribute), CFGetTypeID(raw) == CFURLGetTypeID() else { return nil }
        return ((raw as! CFURL) as URL).standardizedFileURL.path
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let posValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Accessibility uses a top-left origin on the primary screen; AppKit a bottom-left one.
    private static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
