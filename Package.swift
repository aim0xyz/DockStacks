// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockStacks",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "Shared", path: "Sources/Shared"),
        .executableTarget(
            name: "DockStacks",
            dependencies: ["Shared"],
            path: "Sources/DockStacks",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(
            name: "StackStub",
            dependencies: ["Shared"],
            path: "Sources/StackStub"
        ),
    ],
    swiftLanguageModes: [.v5]
)
