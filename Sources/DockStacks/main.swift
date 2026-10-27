import AppKit

// Build helper: `DockStacks --export-iconset <folder>` writes the app's own icon as an .iconset.
if let flag = CommandLine.arguments.firstIndex(of: "--export-iconset"), flag + 1 < CommandLine.arguments.count {
    let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    MainActor.assumeIsolated {
        do {
            try IconRenderer.writeIconset(style: .folder, tint: .glass, icons: IconRenderer.sampleTiles(), to: folder)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
