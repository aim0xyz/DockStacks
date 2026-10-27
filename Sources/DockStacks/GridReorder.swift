import SwiftUI

/// Moving apps around in a grid by dragging them, while the other apps make room, like in Launchpad.
/// It runs entirely inside the window, without the system's drag and drop, so it also works in the
/// grid above the Dock, which belongs to an app that is not active.
@MainActor
final class GridReorder: ObservableObject {
    /// Coordinate space of the grid the drag positions refer to.
    static let space = "reorder-grid"

    @Published private(set) var order: [UUID]?
    @Published private(set) var draggedID: UUID?
    /// Where the pointer is. Kept apart, so following the pointer redraws only the dragged icon.
    let pointer = DragPointer()

    /// The items in the order shown right now (it changes while an app is dragged).
    func arranged(_ items: [StackItem]) -> [StackItem] {
        guard let order else { return items }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let arranged = order.compactMap { byID[$0] }
        return arranged.count == items.count ? arranged : items
    }

    func drag(_ id: UUID, to point: CGPoint, items: [StackItem], columns: Int, cell: CGSize) {
        if draggedID == nil {
            draggedID = id
            order = items.map(\.id)
        }
        pointer.location = point
        guard var order, let from = order.firstIndex(of: id) else { return }
        let to = min(Self.slot(at: point, columns: columns, cell: cell, count: order.count), order.count - 1)
        guard to != from else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { self.order = order }
    }

    /// Ends the drag and returns where the app was let go.
    func end() -> (id: UUID, index: Int)? {
        defer {
            order = nil
            draggedID = nil
        }
        guard let draggedID, let index = order?.firstIndex(of: draggedID) else { return nil }
        return (draggedID, index)
    }

    /// The grid position under a point, from 0 up to `count` (after the last app).
    static func slot(at point: CGPoint, columns: Int, cell: CGSize, count: Int) -> Int {
        let column = min(max(Int(point.x / cell.width), 0), columns - 1)
        let row = max(Int(point.y / cell.height), 0)
        return min(row * columns + column, count)
    }
}

@MainActor
final class DragPointer: ObservableObject {
    @Published var location: CGPoint = .zero
}

/// The icon of the app being dragged, under the pointer.
struct DraggedIcon: View {
    @ObservedObject var pointer: DragPointer
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            .position(pointer.location)
            .allowsHitTesting(false)
    }
}
