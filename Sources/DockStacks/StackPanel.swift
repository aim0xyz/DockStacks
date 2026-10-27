import AppKit
import SwiftUI

// MARK: - Layout

/// Size and geometry of the grid for one stack.
struct PanelLayout: Equatable {
    var edge: DockEdge = .bottom
    var columns = 1
    var visibleRows = 1
    var totalRows = 1
    var iconSize: CGFloat = 64
    var arrowOffset: CGFloat = 0

    static let arrowDepth: CGFloat = 12
    static let arrowWidth: CGFloat = 30
    static let cornerRadius: CGFloat = 26
    static let headerHeight: CGFloat = 40
    static let footerHeight: CGFloat = 34
    static let sidePadding: CGFloat = 14
    /// Room around the glass for its shadow.
    static let margin: CGFloat = 36

    var cellWidth: CGFloat { max(iconSize + 42, 104) }
    var cellHeight: CGFloat { iconSize + 50 }

    var bodySize: CGSize {
        CGSize(width: CGFloat(columns) * cellWidth + Self.sidePadding * 2,
               height: Self.headerHeight + CGFloat(visibleRows) * cellHeight + Self.footerHeight)
    }

    /// Body plus the arrow that points at the Dock.
    var contentSize: CGSize {
        switch edge {
        case .bottom: CGSize(width: bodySize.width, height: bodySize.height + Self.arrowDepth)
        case .left, .right: CGSize(width: bodySize.width + Self.arrowDepth, height: bodySize.height)
        }
    }

    var windowSize: CGSize {
        CGSize(width: contentSize.width + Self.margin * 2, height: contentSize.height + Self.margin * 2)
    }

    /// Where the grid grows from when it opens.
    var growAnchor: UnitPoint {
        switch edge {
        case .bottom: UnitPoint(x: arrowOffset / contentSize.width, y: 1)
        case .left: UnitPoint(x: 0, y: arrowOffset / contentSize.height)
        case .right: UnitPoint(x: 1, y: arrowOffset / contentSize.height)
        }
    }

    var bodyInsets: EdgeInsets {
        switch edge {
        case .bottom: EdgeInsets(top: 0, leading: 0, bottom: Self.arrowDepth, trailing: 0)
        case .left: EdgeInsets(top: 0, leading: Self.arrowDepth, bottom: 0, trailing: 0)
        case .right: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: Self.arrowDepth)
        }
    }

    static func columns(for count: Int) -> Int {
        switch count {
        case ...3: max(count, 1)
        case 4: 4
        case 5...6: 3
        case 7...8: 4
        case 9...12: 4
        case 13...15: 5
        case 16...24: 6
        default: 7
        }
    }
}

/// Rounded body with a small arrow pointing at the stack's Dock icon.
struct CalloutShape: Shape {
    var edge: DockEdge
    var arrowOffset: CGFloat

    func path(in rect: CGRect) -> Path {
        let depth = PanelLayout.arrowDepth
        let half = PanelLayout.arrowWidth / 2
        let radius = PanelLayout.cornerRadius
        var body = rect
        var arrow = Path()
        switch edge {
        case .bottom:
            body.size.height -= depth
            let x = min(max(arrowOffset, radius + half), rect.width - radius - half)
            let base = body.maxY - 1
            arrow.move(to: CGPoint(x: x - half, y: base))
            arrow.addCurve(to: CGPoint(x: x - 3, y: rect.maxY - 2),
                           control1: CGPoint(x: x - half * 0.45, y: base), control2: CGPoint(x: x - 6, y: rect.maxY - 6))
            arrow.addQuadCurve(to: CGPoint(x: x + 3, y: rect.maxY - 2), control: CGPoint(x: x, y: rect.maxY + 1))
            arrow.addCurve(to: CGPoint(x: x + half, y: base),
                           control1: CGPoint(x: x + 6, y: rect.maxY - 6), control2: CGPoint(x: x + half * 0.45, y: base))
        case .left, .right:
            body.size.width -= depth
            if edge == .left { body.origin.x += depth }
            let y = min(max(arrowOffset, radius + half), rect.height - radius - half)
            let base = edge == .left ? body.minX + 1 : body.maxX - 1
            let tip = edge == .left ? rect.minX : rect.maxX
            let dir: CGFloat = edge == .left ? -1 : 1
            arrow.move(to: CGPoint(x: base, y: y - half))
            arrow.addCurve(to: CGPoint(x: tip - dir * 2, y: y - 3),
                           control1: CGPoint(x: base, y: y - half * 0.45), control2: CGPoint(x: tip - dir * 6, y: y - 6))
            arrow.addQuadCurve(to: CGPoint(x: tip - dir * 2, y: y + 3), control: CGPoint(x: tip + dir, y: y))
            arrow.addCurve(to: CGPoint(x: base, y: y + half),
                           control1: CGPoint(x: tip - dir * 6, y: y + 6), control2: CGPoint(x: base, y: y + half * 0.45))
        }
        arrow.closeSubpath()
        let rounded = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
        return rounded.union(arrow)
    }
}

// MARK: - Model

@MainActor
final class PanelModel: ObservableObject {
    @Published var stack: AppStack
    @Published var layout: PanelLayout
    @Published var presented = false
    @Published var selection: Int?
    let reorder = GridReorder()

    var onLaunch: ((StackItem) -> Void)?
    var onEdit: (() -> Void)?
    var onClose: (() -> Void)?

    private var typeAhead = ""
    private var typeAheadReset: DispatchWorkItem?

    init(stack: AppStack, layout: PanelLayout) {
        self.stack = stack
        self.layout = layout
    }

    var items: [StackItem] { stack.orderedItems }

    /// Saves the order after an app was dragged to a new place.
    func finishDrag() {
        guard let drop = reorder.end() else { return }
        StackStore.shared.move(itemID: drop.id, in: stack.id, to: drop.index)
        selection = items.firstIndex { $0.id == drop.id }
    }

    func launchSelected() {
        guard let selection, items.indices.contains(selection) else { return }
        onLaunch?(items[selection])
    }

    func moveSelection(dx: Int, dy: Int) {
        guard !items.isEmpty else { return }
        guard let current = selection else {
            selection = 0
            return
        }
        let columns = layout.columns
        var next = current + dx + dy * columns
        if dy != 0, !items.indices.contains(next) { next = current }
        selection = min(max(next, 0), items.count - 1)
    }

    /// Jumps to the first app whose name starts with the typed letters.
    func typeSelect(_ characters: String) {
        typeAhead += characters.lowercased()
        typeAheadReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.typeAhead = "" }
        typeAheadReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: reset)
        if let index = items.firstIndex(where: { AppCatalog.displayName(for: $0).lowercased().hasPrefix(typeAhead) }) {
            selection = index
        }
    }
}

// MARK: - Views

struct StackPanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var catalog = AppCatalog.shared
    @ObservedObject private var store = StackStore.shared

    private var layout: PanelLayout { model.layout }

    var body: some View {
        content
            .frame(width: layout.contentSize.width, height: layout.contentSize.height)
            .scaleEffect(model.presented ? 1 : 0.35, anchor: layout.growAnchor)
            .opacity(model.presented ? 1 : 0)
            .frame(width: layout.windowSize.width, height: layout.windowSize.height)
    }

    private var content: some View {
        VStack(spacing: 0) {
            Text(model.stack.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(height: PanelLayout.headerHeight)
                .padding(.horizontal, 20)

            if model.items.isEmpty {
                emptyState
            } else {
                grid
            }

            footer
        }
        .padding(layout.bodyInsets)
        .contentShape(CalloutShape(edge: layout.edge, arrowOffset: layout.arrowOffset))
        .glassEffect(.regular, in: CalloutShape(edge: layout.edge, arrowOffset: layout.arrowOffset))
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                PanelGrid(model: model, reorder: model.reorder)
                    .padding(.horizontal, PanelLayout.sidePadding)
            }
            .scrollIndicators(layout.totalRows > layout.visibleRows ? .automatic : .never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: CGFloat(layout.visibleRows) * layout.cellHeight)
            .onChange(of: model.selection) { _, newValue in
                guard let newValue, model.items.indices.contains(newValue) else { return }
                proxy.scrollTo(model.items[newValue].id)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("Zieh Apps auf das Stapel-Symbol im Dock")
                .font(.system(size: 12, weight: .medium))
            Text("oder füge sie unter „Stapel bearbeiten“ hinzu")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(layout.visibleRows) * layout.cellHeight)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                model.onEdit?()
            } label: {
                HStack(spacing: 2) {
                    Text("Stapel bearbeiten")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
        }
        .frame(height: PanelLayout.footerHeight)
    }
}

/// The apps of the grid. While one is dragged, the others make room for it.
struct PanelGrid: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var reorder: GridReorder
    @ObservedObject private var catalog = AppCatalog.shared
    @ObservedObject private var store = StackStore.shared

    private var layout: PanelLayout { model.layout }

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(layout.cellWidth), spacing: 0), count: layout.columns)
        let positions = Dictionary(uniqueKeysWithValues: model.items.enumerated().map { ($1.id, $0) })
        let showDots = store.prefs.showRunningIndicators && DockBridge.showsProcessIndicators
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(reorder.arranged(model.items)) { item in
                StackItemCell(model: model, item: item, index: positions[item.id] ?? 0,
                              running: catalog.isRunning(item),
                              showDot: showDots,
                              lifted: reorder.draggedID == item.id)
                    .id(item.id)
            }
        }
        .coordinateSpace(name: GridReorder.space)
        .overlay(alignment: .topLeading) {
            if let id = reorder.draggedID, let item = model.items.first(where: { $0.id == id }) {
                DraggedIcon(pointer: reorder.pointer, image: AppCatalog.shared.icon(for: item), size: layout.iconSize * 1.1)
            }
        }
    }
}

struct StackItemCell: View {
    @ObservedObject var model: PanelModel
    let item: StackItem
    let index: Int
    let running: Bool
    let showDot: Bool
    /// Being dragged: its place stays empty while the icon follows the pointer.
    let lifted: Bool

    @State private var pressed = false

    private var layout: PanelLayout { model.layout }
    private var selected: Bool { model.selection == index && !lifted }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: AppCatalog.shared.icon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: layout.iconSize, height: layout.iconSize)
                .scaleEffect(pressed ? 0.88 : 1)
            Circle()
                .fill(.primary.opacity(running && showDot ? 0.7 : 0))
                .frame(width: 4, height: 4)
            AppLabel(name: AppCatalog.displayName(for: item))
                .frame(width: layout.cellWidth - 14, height: 28, alignment: .top)
        }
        .frame(width: layout.cellWidth - 6, height: layout.cellHeight - 6)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.primary.opacity(selected ? 0.12 : 0))
        }
        .opacity(lifted ? 0 : 1)
        .frame(width: layout.cellWidth, height: layout.cellHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.selection = index } else if model.selection == index { model.selection = nil }
        }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.08)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                pressed = false
                model.onLaunch?(item)
            }
        }
        // Wins over the tap once the pointer moves a few points with the button down.
        .highPriorityGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(GridReorder.space))
                .onChanged { value in
                    model.reorder.drag(item.id, to: value.location, items: model.items, columns: layout.columns,
                                       cell: CGSize(width: layout.cellWidth, height: layout.cellHeight))
                }
                .onEnded { _ in model.finishDrag() }
        )
        .contextMenu { ItemMenu(model: model, item: item) }
        .help(AppCatalog.displayName(for: item))
    }
}

/// Right-click menu of an app in the grid, built like the Dock's own menu.
struct ItemMenu: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var catalog = AppCatalog.shared
    let item: StackItem

    var body: some View {
        let app = catalog.runningApp(for: item)
        Menu("Optionen") {
            Button("Im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                model.onClose?()
            }
            Divider()
            Button("Aus „\(model.stack.name)“ entfernen") {
                StackStore.shared.remove(itemID: item.id, from: model.stack.id)
            }
            Button("Stapel bearbeiten …") { model.onEdit?() }
        }
        Divider()
        if let app {
            if app.isHidden {
                Button("Einblenden") { app.unhide(); model.onClose?() }
            } else {
                Button("Ausblenden") { app.hide(); model.onClose?() }
            }
            Button("Beenden") { app.terminate(); model.onClose?() }
        } else {
            Button("Öffnen") { model.onLaunch?(item) }
        }
    }
}

/// App name under an icon: two lines for names with several words, one line (slightly tightened,
/// shortened in the middle) for a single long word, so words are never broken mid-way.
struct AppLabel: View {
    let name: String

    var body: some View {
        let singleWord = !name.contains(" ") && !name.contains("-")
        Text(name)
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(singleWord ? 1 : 2)
            .truncationMode(.middle)
            .minimumScaleFactor(singleWord ? 0.82 : 1)
            .allowsTightening(true)
    }
}

// MARK: - Window

final class StackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Shows the grid for a stack above its Dock icon, like a native Dock stack.
@MainActor
final class StackPanelController {
    static let shared = StackPanelController()

    private var panel: StackPanel?
    private var model: PanelModel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var lastDismissal: (stackID: UUID, date: Date)?
    private var shownAt = Date.distantPast
    private var closing = false
    private var openedFrom: CGPoint?
    private let shield: NSPanel
    private let shieldView = ShieldView()

    var onEditStack: ((UUID) -> Void)?

    private init() {
        shield = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        shield.isOpaque = false
        shield.backgroundColor = NSColor(white: 0, alpha: 0.004)
        shield.hasShadow = false
        shield.level = .popUpMenu
        // Makes the clear window solid for the mouse. The window server picks this up one run-loop turn
        // later, so it is set here, long before the shield first covers an icon.
        shield.ignoresMouseEvents = false
        shield.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        shield.isReleasedWhenClosed = false
        shield.animationBehavior = .none
        shield.contentView = shieldView
        shieldView.onClick = { [weak self] in self?.close() }
    }

    var visibleStackID: UUID? { panel?.isVisible == true && !closing ? model?.stack.id : nil }

    // MARK: Showing

    func toggle(_ stack: AppStack, stubURL: URL?, mouse: CGPoint?) {
        if visibleStackID == stack.id {
            close()
            return
        }
        // The click on the Dock icon that closed this grid also arrives here; don't reopen it.
        if let last = lastDismissal, last.stackID == stack.id, Date().timeIntervalSince(last.date) < 0.45 {
            lastDismissal = nil
            return
        }
        show(stack, stubURL: stubURL, mouse: mouse)
    }

    func show(_ stack: AppStack, stubURL: URL?, mouse: CGPoint?, animatedShow: Bool = true) {
        if panel != nil { close(animated: false, keepShield: !animatedShow) }

        let placement = place(stack, stubURL: stubURL, mouse: mouse)
        let model = PanelModel(stack: stack, layout: placement.layout)
        model.onLaunch = { [weak self] item in self?.launch(item) }
        model.onEdit = { [weak self] in
            self?.close()
            self?.onEditStack?(stack.id)
        }
        model.onClose = { [weak self] in self?.close() }
        self.model = model

        let panel = StackPanel(contentRect: placement.frame,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: StackPanelView(model: model))
        host.frame = NSRect(origin: .zero, size: placement.frame.size)
        panel.contentView = host
        panel.setFrame(placement.frame, display: false)
        self.panel = panel

        closing = false
        shownAt = Date()
        openedFrom = mouse ?? openedFrom
        panel.orderFrontRegardless()
        panel.makeKey()
        startMonitoring()
        if animatedShow { installShield(over: placement.dockTile) }

        guard animatedShow else {
            model.presented = true
            return
        }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) { model.presented = true }
        }
    }

    /// Keeps the grid in sync when the stack is edited while open.
    func stackDidChange(_ stack: AppStack) {
        guard let model, model.stack.id == stack.id, !closing else { return }
        model.stack = stack
        let stubURL = StubManager.shared.bundleURL(for: stack)
        let fresh = place(stack, stubURL: stubURL, mouse: openedFrom).layout
        if fresh.columns != model.layout.columns || fresh.visibleRows != model.layout.visibleRows {
            // Size changed: reopen in place without the grow animation.
            show(stack, stubURL: stubURL, mouse: openedFrom, animatedShow: false)
        } else if fresh.totalRows != model.layout.totalRows {
            model.layout.totalRows = fresh.totalRows
        }
    }

    func close(animated: Bool = true, keepShield: Bool = false) {
        if !keepShield { removeShield() }
        guard let panel, let model, !closing else { return }
        closing = true
        stopMonitoring()
        let finish = { [weak self] in
            panel.orderOut(nil)
            guard let self, self.panel === panel else { return }
            self.panel = nil
            self.model = nil
            self.closing = false
        }
        guard animated else {
            finish()
            return
        }
        withAnimation(.easeIn(duration: 0.13)) { model.presented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { finish() }
    }

    private func launch(_ item: StackItem) {
        let resolved = AppCatalog.resolve(item) ?? item
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: resolved.url, configuration: config) { _, error in
            if let error { NSLog("DockStacks: launch failed: \(error)") }
        }
        close()
    }

    // MARK: Placement

    private struct Placement {
        var frame: NSRect
        var layout: PanelLayout
        /// The stack's whole tile in the Dock, from the screen edge up to the arrow tip.
        var dockTile: CGRect
    }

    private func place(_ stack: AppStack, stubURL: URL?, mouse: CGPoint?) -> Placement {
        let edge = DockBridge.edge
        let iconFrame = stubURL.flatMap { DockBridge.iconFrame(forAppAt: $0, label: stack.name) }
        let reference = iconFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? mouse ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(reference) } ?? NSScreen.main ?? NSScreen.screens[0]
        let full = screen.frame, visible = screen.visibleFrame
        let gap: CGFloat = 6

        // Tip of the arrow: just outside the Dock, in line with the icon.
        var tip = reference
        switch edge {
        case .bottom:
            let dockTop = visible.minY - full.minY > 8 ? visible.minY : (iconFrame?.maxY ?? full.minY + 64) + 6
            tip.y = dockTop + gap
        case .left:
            let dockEdge = visible.minX - full.minX > 8 ? visible.minX : (iconFrame?.maxX ?? full.minX + 64) + 6
            tip.x = dockEdge + gap
        case .right:
            let dockEdge = full.maxX - visible.maxX > 8 ? visible.maxX : (iconFrame?.minX ?? full.maxX - 64) - 6
            tip.x = dockEdge - gap
        }

        var layout = PanelLayout()
        layout.edge = edge
        layout.iconSize = CGFloat(StackStore.shared.prefs.gridIconSize)
        let count = stack.items.count
        layout.columns = PanelLayout.columns(for: count)
        layout.totalRows = max(1, Int(ceil(Double(count) / Double(layout.columns))))

        // Rows that fit on screen (at most 5, then the grid scrolls).
        let fixedHeight = PanelLayout.headerHeight + PanelLayout.footerHeight + (edge == .bottom ? PanelLayout.arrowDepth : 0)
        let availableHeight = (edge == .bottom ? visible.maxY - tip.y : visible.height) - 16 - fixedHeight
        let fitRows = max(1, Int(availableHeight / layout.cellHeight))
        layout.visibleRows = min(layout.totalRows, 5, fitRows)

        // Fit the columns to the screen width as well.
        let availableWidth = (edge == .bottom ? visible.width : visible.maxX - visible.minX - 80) - 16
        while layout.columns > 1, layout.contentSize.width > availableWidth {
            layout.columns -= 1
            layout.totalRows = max(1, Int(ceil(Double(count) / Double(layout.columns))))
            layout.visibleRows = min(layout.totalRows, 5, fitRows)
        }

        let size = layout.contentSize
        var origin = CGPoint.zero
        switch edge {
        case .bottom:
            origin.x = min(max(tip.x - size.width / 2, visible.minX + 8), visible.maxX - 8 - size.width)
            origin.y = tip.y
            layout.arrowOffset = tip.x - origin.x
        case .left, .right:
            origin.x = edge == .left ? tip.x : tip.x - size.width
            origin.y = min(max(tip.y - size.height / 2, visible.minY + 8), visible.maxY - 8 - size.height)
            layout.arrowOffset = origin.y + size.height - tip.y
        }
        let frame = NSRect(x: origin.x - PanelLayout.margin, y: origin.y - PanelLayout.margin,
                           width: layout.windowSize.width, height: layout.windowSize.height)

        // Without Accessibility the icon is assumed to be centred on the click.
        let tile = DockBridge.tileSize
        let dockTile: CGRect
        switch edge {
        case .bottom:
            let x = iconFrame.map { ($0.minX, $0.width) } ?? (reference.x - tile / 2, tile)
            dockTile = CGRect(x: x.0, y: full.minY, width: x.1, height: tip.y - full.minY)
        case .left:
            let y = iconFrame.map { ($0.minY, $0.height) } ?? (reference.y - tile / 2, tile)
            dockTile = CGRect(x: full.minX, y: y.0, width: tip.x - full.minX, height: y.1)
        case .right:
            let y = iconFrame.map { ($0.minY, $0.height) } ?? (reference.y - tile / 2, tile)
            dockTile = CGRect(x: tip.x, y: y.0, width: full.maxX - tip.x, height: y.1)
        }
        return Placement(frame: frame, layout: layout, dockTile: dockTile)
    }

    // MARK: Dock label

    /// While the grid is open, a clear window lies over the stack's whole Dock tile, up to the arrow.
    /// The Dock no longer sees the pointer over the tile and fades out the stack's name, as it does for
    /// native stacks; the pointer can't touch the tile again on its way up to the grid. A second click
    /// on the icon lands here and closes the grid.
    /// Not with an auto-hiding Dock: it would slide away under the open grid.
    private func installShield(over tile: CGRect) {
        removeShield()
        guard !DockBridge.autohides else { return }
        shield.setFrame(tile, display: false)
        shield.orderFrontRegardless()
    }

    private func removeShield() {
        shield.orderOut(nil)
    }

    // MARK: Dismissal

    private func startMonitoring() {
        stopMonitoring()
        // Any click outside the grid closes it, like a native stack.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissFromOutside() }
        }) { monitors.append(global) }

        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleLocal(event) ?? false }
            return consumed ? nil : event
        }) { monitors.append(local) }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: false) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.otherAppActivated(note) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: false) }
        })
    }

    private func stopMonitoring() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers.removeAll()
    }

    private func dismissFromOutside() {
        guard let model else { return }
        lastDismissal = (model.stack.id, Date())
        close()
    }

    private func otherAppActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // Right after opening, the app that was in front gets its focus back from the stack app.
        // Keep the grid open and take the keyboard back.
        if Date().timeIntervalSince(shownAt) < 0.8 || AgentState.isOwnApp(app) {
            panel?.makeKey()
            return
        }
        close()
    }

    /// Returns true when the event was handled here and should not travel further.
    private func handleLocal(_ event: NSEvent) -> Bool {
        guard let panel, let model else { return false }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if event.window !== panel, event.window !== shield { dismissFromOutside() }
            return false
        }
        guard event.window === panel || event.window == nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: close(); return true                                 // Esc
        case 36, 76: model.launchSelected(); return true             // Return, Enter
        case 123: model.moveSelection(dx: -1, dy: 0); return true    // ←
        case 124: model.moveSelection(dx: 1, dy: 0); return true     // →
        case 125: model.moveSelection(dx: 0, dy: 1); return true     // ↓
        case 126: model.moveSelection(dx: 0, dy: -1); return true    // ↑
        default:
            if flags.contains(.command) {
                if event.charactersIgnoringModifiers == "," { model.onEdit?(); return true }
                // ⌘Q and ⌘H would otherwise reach DockStacks itself, not the app in front.
                if ["w", "q", "h"].contains(event.charactersIgnoringModifiers ?? "") { close(); return true }
                return false
            }
            if let chars = event.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " }) {
                model.typeSelect(chars)
                return true
            }
            return false
        }
    }
}

/// Clear view over the stack's Dock tile; see `installShield`.
final class ShieldView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
}
