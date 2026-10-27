import AppKit
import Combine
import Shared

/// Owns the user's stacks and saves them to ~/Library/Application Support/DockStacks/library.json.
@MainActor
final class StackStore: ObservableObject {
    static let shared = StackStore()

    @Published private(set) var library = Library()
    /// library.json exists but could not be read. Nothing in the Dock is removed in that case.
    private(set) var loadFailed = false

    /// Called after a stack's name, apps or look changed, so its Dock app can be updated.
    var onStackChanged: ((AppStack) -> Void)?
    var onStackDeleted: ((AppStack) -> Void)?

    static let supportFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DockStacks", isDirectory: true)
    }()

    private var fileURL: URL { Self.supportFolder.appendingPathComponent("library.json") }
    private var saveWork: DispatchWorkItem?

    private init() {
        load()
    }

    var stacks: [AppStack] { library.stacks }
    var prefs: Preferences { library.prefs }

    func stack(_ id: UUID) -> AppStack? {
        library.stacks.first { $0.id == id }
    }

    func stack(id string: String) -> AppStack? {
        UUID(uuidString: string).flatMap(stack)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            library = try JSONDecoder().decode(Library.self, from: data)
            repairMovedApps()
        } catch {
            NSLog("DockStacks: could not read library: \(error)")
            loadFailed = true
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.copyItem(at: fileURL, to: Self.supportFolder.appendingPathComponent("library-unreadable-\(stamp).json"))
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        do {
            try FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(library).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("DockStacks: could not save library: \(error)")
        }
    }

    /// Apps that were moved or renamed are found again by bundle identifier.
    private func repairMovedApps() {
        for s in library.stacks.indices {
            library.stacks[s].items = library.stacks[s].items.map { AppCatalog.resolve($0) ?? $0 }
        }
    }

    // MARK: Stacks

    @discardableResult
    func createStack(name: String? = nil, items: [StackItem] = []) -> AppStack {
        let stack = AppStack(name: uniqueName(name ?? "Neuer Stapel"), items: items)
        library.stacks.append(stack)
        changed(stack.id)
        return stack
    }

    func deleteStack(_ id: UUID) {
        guard let index = library.stacks.firstIndex(where: { $0.id == id }) else { return }
        let removed = library.stacks.remove(at: index)
        scheduleSave()
        onStackDeleted?(removed)
    }

    func moveStacks(from source: IndexSet, to destination: Int) {
        library.stacks.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: id), library.stacks[index].name != trimmed else { return }
        library.stacks[index].name = uniqueName(trimmed, excluding: id)
        changed(id)
    }

    func setStyle(_ id: UUID, _ style: IconStyle) {
        update(id) { $0.iconStyle = style }
    }

    func setTint(_ id: UUID, _ tint: StackTint) {
        update(id) { $0.tint = tint }
    }

    func setSort(_ id: UUID, _ sort: StackSort) {
        update(id) { $0.sort = sort }
    }

    // MARK: Items

    /// Adds apps to a stack. Returns the items that were actually new.
    @discardableResult
    func add(urls: [URL], to id: UUID, at position: Int? = nil) -> [StackItem] {
        guard let index = index(of: id) else { return [] }
        let existing = Set(library.stacks[index].items.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        var seen = existing
        let newItems = urls.compactMap(AppCatalog.makeItem).filter { item in
            guard !Self.isOwnApp(item), !seen.contains(item.path) else { return false }
            seen.insert(item.path)
            return true
        }
        guard !newItems.isEmpty else { return [] }
        let insertAt = min(max(position ?? library.stacks[index].items.count, 0), library.stacks[index].items.count)
        library.stacks[index].items.insert(contentsOf: newItems, at: insertAt)
        changed(id)
        return newItems
    }

    func remove(itemID: UUID, from id: UUID) {
        update(id) { $0.items.removeAll { $0.id == itemID } }
    }

    /// Moves an item to a position in the order the user sees. A sorted stack switches to its own
    /// order, starting from the sorted one.
    func move(itemID: UUID, in id: UUID, to index: Int) {
        update(id) { stack in
            stack.items = stack.orderedItems
            stack.sort = .manual
            guard let from = stack.items.firstIndex(where: { $0.id == itemID }) else { return }
            let item = stack.items.remove(at: from)
            stack.items.insert(item, at: min(max(index, 0), stack.items.count))
        }
    }

    // MARK: Preferences

    func updatePrefs(_ change: (inout Preferences) -> Void) {
        change(&library.prefs)
        scheduleSave()
    }

    // MARK: Helpers

    private func index(of id: UUID) -> Int? {
        library.stacks.firstIndex { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout AppStack) -> Void) {
        guard let index = index(of: id) else { return }
        let before = library.stacks[index]
        change(&library.stacks[index])
        guard library.stacks[index] != before else { return }
        changed(id)
    }

    private func changed(_ id: UUID) {
        scheduleSave()
        if let stack = stack(id) { onStackChanged?(stack) }
    }

    private func uniqueName(_ base: String, excluding id: UUID? = nil) -> String {
        let clean = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        // Compared the way the file system compares names, so two stacks never share a bundle ("Straße" = "STRASSE").
        func key(_ name: String) -> String { name.folding(options: [.caseInsensitive], locale: nil) }
        let taken = Set(library.stacks.filter { $0.id != id }.map { key($0.name) })
        if !taken.contains(key(clean)) { return clean }
        var n = 2
        while taken.contains(key("\(clean) \(n)")) { n += 1 }
        return "\(clean) \(n)"
    }

    /// The agent itself and stack apps are never put into a stack.
    static func isOwnApp(_ item: StackItem) -> Bool {
        guard let id = item.bundleID else { return false }
        return id == DS.agentBundleID || id.hasPrefix(DS.stubBundleIDPrefix)
    }
}
