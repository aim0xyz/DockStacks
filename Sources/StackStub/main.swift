import AppKit
import Shared

/// The tiny app that sits in the Dock for one stack.
///
/// It has no UI of its own (LSUIElement). A click on its Dock icon reaches it as a launch or a
/// "reopen" event, and apps dropped onto the icon arrive as "open documents". Both are handed to the
/// DockStacks agent, which draws the grid. The stub stays running so later clicks are instant.
final class StubDelegate: NSObject, NSApplicationDelegate {
    private let stackID = Bundle.main.object(forInfoDictionaryKey: DS.stackIDInfoKey) as? String ?? ""
    private let launchedQuietly = CommandLine.arguments.contains(DS.backgroundLaunchArgument)
    private var launchedWithDocuments = false
    /// The app the user was working in. A Dock click makes this stub active; it hands the focus straight back.
    private var previousApp: NSRunningApplication?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let me = NSRunningApplication.current
        if let front = NSWorkspace.shared.frontmostApplication, front != me { previousApp = front }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app != me else { return }
            MainActor.assumeIsolated { self?.previousApp = app }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate(from: NSRunningApplication.current, options: [])
        } else {
            NSApp.hide(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        launchedWithDocuments = true
        let paths = urls.filter { $0.pathExtension.lowercased() == "app" }.map(\.path)
        guard !paths.isEmpty else { return }
        send(DS.addNotification, userInfo: ["paths": paths])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !launchedQuietly, !launchedWithDocuments else { return }
        requestShow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        requestShow()
        return false
    }

    private func requestShow() {
        let mouse = NSEvent.mouseLocation
        send(DS.showNotification, userInfo: ["x": Double(mouse.x), "y": Double(mouse.y)])
    }

    private func send(_ name: Notification.Name, userInfo: [String: Any]) {
        guard !stackID.isEmpty else { return }
        // An agent that is still starting up may not listen yet; the URL waits for it.
        let agents = NSRunningApplication.runningApplications(withBundleIdentifier: DS.agentBundleID)
        if !agents.contains(where: \.isFinishedLaunching) {
            launchAgent(name, userInfo: userInfo)
        } else {
            DistributedNotificationCenter.default().postNotificationName(
                name, object: stackID, userInfo: userInfo, deliverImmediately: true)
        }
    }

    /// The agent is not running: start it through its URL scheme, which carries the request along.
    private func launchAgent(_ name: Notification.Name, userInfo: [String: Any]) {
        var components = URLComponents()
        components.scheme = DS.urlScheme
        components.host = name == DS.addNotification ? "add" : "show"
        var query = [URLQueryItem(name: "id", value: stackID)]
        if let paths = userInfo["paths"] as? [String] {
            query += paths.map { URLQueryItem(name: "path", value: $0) }
        }
        if let x = userInfo["x"] as? Double, let y = userInfo["y"] as? Double {
            query += [URLQueryItem(name: "x", value: String(x)), URLQueryItem(name: "y", value: String(y))]
        }
        components.queryItems = query
        guard let url = components.url else { return }
        // In the background: the app the user is working in keeps the focus.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if let error { NSLog("DockStacks stack app: could not start DockStacks: \(error)") }
        }
    }
}

let app = NSApplication.shared
let delegate = StubDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
