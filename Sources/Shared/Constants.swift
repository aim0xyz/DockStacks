import Foundation

/// Identifiers shared between the DockStacks agent and the small per-stack Dock apps ("stubs").
public enum DS {
    public static let agentBundleID = "local.dockstacks.app"
    public static let stubBundleIDPrefix = "local.dockstacks.stack."
    /// Info.plist key in every stub that names the stack it opens.
    public static let stackIDInfoKey = "DSStackID"
    /// Info.plist key that records which stub template build a stub was made from.
    public static let templateVersionInfoKey = "DSTemplateVersion"
    public static let urlScheme = "dockstacks"

    /// Stub → agent: open the grid for a stack. object = stack ID, userInfo = ["x": Double, "y": Double].
    public static let showNotification = Notification.Name("local.dockstacks.show")
    /// Stub → agent: apps were dropped on a stack's Dock icon. object = stack ID, userInfo = ["paths": [String]].
    public static let addNotification = Notification.Name("local.dockstacks.add")

    /// Passed by the agent when it starts a stub in the background, so the stub stays quiet.
    public static let backgroundLaunchArgument = "--dockstacks-background"

    public static func stubBundleID(for stackID: UUID) -> String {
        stubBundleIDPrefix + stackID.uuidString.lowercased()
    }
}
