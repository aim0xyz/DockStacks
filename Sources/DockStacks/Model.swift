import AppKit
import Shared

struct StackItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var path: String
    var bundleID: String?

    var url: URL { URL(fileURLWithPath: path) }
}

enum IconStyle: String, Codable, CaseIterable, Identifiable {
    /// Launchpad-style tile with a 3×3 grid of small app icons.
    case folder
    /// The look of a native Dock stack: the first apps piled on top of each other.
    case pile

    var id: String { rawValue }
    var title: String {
        switch self {
        case .folder: "Ordner"
        case .pile: "Stapel"
        }
    }
}

enum StackSort: String, Codable, CaseIterable, Identifiable {
    case manual, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: "Eigene Reihenfolge"
        case .name: "Alphabetisch"
        }
    }
}

enum StackTint: String, Codable, CaseIterable, Identifiable {
    case glass, graphite, blue, purple, pink, red, orange, yellow, green, teal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: "Glas"
        case .graphite: "Graphit"
        case .blue: "Blau"
        case .purple: "Lila"
        case .pink: "Pink"
        case .red: "Rot"
        case .orange: "Orange"
        case .yellow: "Gelb"
        case .green: "Grün"
        case .teal: "Türkis"
        }
    }

    /// Top and bottom colors of the folder tile.
    var gradient: (NSColor, NSColor) {
        func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
            NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
        }
        switch self {
        case .glass: return (c(250, 250, 252, 0.80), c(222, 224, 230, 0.72))
        case .graphite: return (c(110, 112, 120, 0.92), c(58, 60, 66, 0.92))
        case .blue: return (c(120, 186, 255), c(36, 120, 240))
        case .purple: return (c(196, 150, 255), c(128, 76, 228))
        case .pink: return (c(255, 152, 200), c(234, 72, 146))
        case .red: return (c(255, 136, 124), c(222, 52, 52))
        case .orange: return (c(255, 196, 112), c(244, 132, 30))
        case .yellow: return (c(255, 232, 120), c(240, 190, 20))
        case .green: return (c(140, 228, 140), c(46, 170, 80))
        case .teal: return (c(120, 226, 226), c(24, 160, 176))
        }
    }

    var swatch: NSColor { gradient.1 }
}

struct AppStack: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var items: [StackItem] = []
    var iconStyle: IconStyle = .folder
    var tint: StackTint = .glass
    var sort: StackSort = .manual

    var stubBundleID: String { DS.stubBundleID(for: id) }

    /// Items in display order.
    var orderedItems: [StackItem] {
        switch sort {
        case .manual: items
        case .name: items.sorted {
            AppCatalog.displayName(for: $0).localizedStandardCompare(AppCatalog.displayName(for: $1)) == .orderedAscending
        }
        }
    }
}

struct Preferences: Codable, Hashable {
    var gridIconSize: Double = 64
    var showRunningIndicators = true
    var removeAppsFromDockWhenStacked = true
    var didOnboard = false
}

extension Preferences {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        gridIconSize = try c.decodeIfPresent(Double.self, forKey: .gridIconSize) ?? gridIconSize
        showRunningIndicators = try c.decodeIfPresent(Bool.self, forKey: .showRunningIndicators) ?? showRunningIndicators
        removeAppsFromDockWhenStacked = try c.decodeIfPresent(Bool.self, forKey: .removeAppsFromDockWhenStacked) ?? removeAppsFromDockWhenStacked
        didOnboard = try c.decodeIfPresent(Bool.self, forKey: .didOnboard) ?? didOnboard
    }
}

struct Library: Codable {
    var version = 1
    var stacks: [AppStack] = []
    var prefs = Preferences()
}
