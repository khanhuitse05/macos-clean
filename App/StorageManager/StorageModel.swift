import MacosCleanCore
import SwiftUI

/// State of the Storage Manager: per-category scan results, lazily loaded subfolders, and the
/// selection of paths to move to the Trash.
@MainActor
@Observable
final class StorageModel {
    enum Phase: Equatable {
        case notScanned
        case scanning
        case scanned(CategoryScanResult)
    }

    /// Categories whose items are shown but can never be selected (emptying the Trash would be a
    /// hard delete; the user does that in Finder).
    static let readOnlyCategoryIDs: Set<String> = ["trash"]

    let categories = CleanupCategory.all
    private(set) var phases: [String: Phase] = [:]
    /// Children of folders the user expanded, keyed by folder path.
    private(set) var children: [String: [FileEntry]] = [:]
    private(set) var loadingChildren: Set<String> = []
    private(set) var isScanningAll = false

    /// Selected paths. May contain a folder and its loaded descendants; totals use the deduped set.
    private(set) var selection: Set<String> = [] {
        didSet { recomputeSelectionSummary() }
    }
    private(set) var selectedCount = 0
    private(set) var selectedBytes: Int64 = 0
    private(set) var foundBytes: Int64 = 0
    private(set) var deniedPaths: [String] = []

    private var sizes: [String: Int64] = [:]
    private var categoryOfPath: [String: String] = [:]
    private var hasDefaultSelection: Set<String> = []
    private var expansionDenied: Set<String> = []
    private let scanner = CategoryScanner()

    // MARK: Queries

    func phase(of category: CleanupCategory) -> Phase { phases[category.id] ?? .notScanned }

    func isReadOnly(_ category: CleanupCategory) -> Bool { Self.readOnlyCategoryIDs.contains(category.id) }

    var hasAnyResult: Bool {
        phases.values.contains { if case .scanned = $0 { true } else { false } }
    }

    func checkState(of entry: FileEntry) -> CheckState {
        if selection.contains(entry.path) { return .on }
        guard entry.isDirectory else { return .off }
        let prefix = entry.path + "/"
        return selection.contains { $0.hasPrefix(prefix) } ? .mixed : .off
    }

    func checkState(of category: CleanupCategory) -> CheckState {
        guard case .scanned(let result) = phase(of: category), !result.entries.isEmpty else { return .off }
        let states = result.entries.map(checkState(of:))
        if states.allSatisfy({ $0 == .on }) { return .on }
        if states.allSatisfy({ $0 == .off }) { return .off }
        return .mixed
    }

    func selectedBytes(in category: CleanupCategory) -> Int64 {
        PathDeduper.dedupe(Array(selection)).filter { categoryOfPath[$0] == category.id }.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    // MARK: Scanning

    func scanAll() async {
        guard !isScanningAll else { return }
        isScanningAll = true
        defer { isScanningAll = false }
        // A few at a time: each category already measures its children in parallel.
        await withTaskGroup(of: Void.self) { group in
            var pending = categories[...]
            func next() {
                guard let category = pending.popFirst() else { return }
                group.addTask { await self.scan(category) }
            }
            for _ in 0..<3 { next() }
            for await _ in group { next() }
        }
    }

    func scan(_ category: CleanupCategory) async {
        if phase(of: category) == .scanning { return }
        phases[category.id] = .scanning
        let result = await scanner.scan(category)
        apply(result, for: category)
    }

    func loadChildren(of entry: FileEntry) async {
        guard entry.isDirectory, children[entry.path] == nil, !loadingChildren.contains(entry.path) else { return }
        loadingChildren.insert(entry.path)
        let listing = await scanner.list(entry.url)
        loadingChildren.remove(entry.path)
        let owner = categoryOfPath[entry.path]
        for child in listing.entries {
            sizes[child.path] = child.sizeBytes
            categoryOfPath[child.path] = owner
        }
        children[entry.path] = listing.entries
        if !listing.deniedPaths.isEmpty {
            expansionDenied.formUnion(listing.deniedPaths)
            recomputeTotals()
        }
        // A selected folder's newly shown children inherit its tick.
        if selection.contains(entry.path) {
            selection.formUnion(listing.entries.map(\.path))
        }
    }

    private func apply(_ result: CategoryScanResult, for category: CleanupCategory) {
        // Forget stale selection and children for this category before replacing it.
        let stale = categoryOfPath.filter { $0.value == category.id }.map(\.key)
        for path in stale {
            categoryOfPath[path] = nil
            sizes[path] = nil
            children[path] = nil
        }
        let staleSet = Set(stale)
        let previouslySelected = selection.intersection(staleSet)
        expansionDenied = expansionDenied.filter { path in !stale.contains { path.hasPrefix($0 + "/") } }
        selection.subtract(staleSet)

        for entry in result.entries {
            sizes[entry.path] = entry.sizeBytes
            categoryOfPath[entry.path] = category.id
        }
        phases[category.id] = .scanned(result)

        if isReadOnly(category) {
            // never selectable
        } else if !hasDefaultSelection.contains(category.id) {
            // First scan: tick everything in a safe category, nothing in a caution one.
            hasDefaultSelection.insert(category.id)
            if category.safety.selectedByDefault {
                selection.formUnion(result.entries.map(\.path))
            }
        } else {
            // Rescan: keep ticks on items that still exist.
            selection.formUnion(previouslySelected.intersection(result.entries.map(\.path)))
        }
        recomputeTotals()
    }

    // MARK: Selection

    func toggle(_ entry: FileEntry) {
        if checkState(of: entry) == .on {
            deselect(entry.path)
        } else {
            select(entry.path)
        }
    }

    func toggle(_ category: CleanupCategory) async {
        guard !isReadOnly(category) else { return }
        if phase(of: category) == .notScanned {
            await scan(category)
        }
        guard case .scanned(let result) = phase(of: category) else { return }
        if checkState(of: category) == .on {
            for entry in result.entries { deselect(entry.path) }
        } else {
            for entry in result.entries { select(entry.path) }
        }
    }

    func selectAll() {
        for category in categories where !isReadOnly(category) {
            if case .scanned(let result) = phase(of: category) {
                for entry in result.entries { select(entry.path) }
            }
        }
    }

    func selectNone() { selection.removeAll() }

    private func select(_ path: String) {
        var added: Set<String> = [path]
        added.formUnion(loadedDescendants(of: path))
        selection.formUnion(added)
    }

    /// Unticks a path and its descendants. A ticked ancestor becomes partially ticked: it's
    /// unticked and its other loaded children stay ticked.
    private func deselect(_ path: String) {
        var updated = selection
        updated.remove(path)
        updated.subtract(loadedDescendants(of: path))
        var child = path
        var parent = (child as NSString).deletingLastPathComponent
        while parent != child, let siblings = children[parent] {
            if updated.remove(parent) != nil {
                updated.formUnion(siblings.map(\.path).filter { $0 != child })
            }
            child = parent
            parent = (child as NSString).deletingLastPathComponent
        }
        selection = updated
    }

    private func loadedDescendants(of path: String) -> [String] {
        guard let kids = children[path] else { return [] }
        return kids.flatMap { [$0.path] + loadedDescendants(of: $0.path) }
    }

    private func recomputeSelectionSummary() {
        let units = PathDeduper.dedupe(Array(selection))
        selectedCount = units.count
        selectedBytes = units.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    private func recomputeTotals() {
        var total: Int64 = 0
        var denied: [String] = []
        for phase in phases.values {
            if case .scanned(let result) = phase {
                if !Self.readOnlyCategoryIDs.contains(result.categoryID) { total += result.totalBytes }
                denied += result.deniedPaths
            }
        }
        foundBytes = total
        deniedPaths = Array(Set(denied).union(expansionDenied)).sorted()
    }

    // MARK: Trash

    func trashRequest() -> TrashCoordinator.Request? {
        let paths = PathDeduper.dedupe(Array(selection)).sorted()
        guard !paths.isEmpty else { return nil }
        let categoryCount = Set(paths.compactMap { categoryOfPath[$0] }).count
        return .items(
            paths, bytes: selectedBytes,
            extraMessage: categoryCount > 1 ? "From \(categoryCount) categories. Quit apps whose caches you're cleaning first." : nil
        ) { [weak self] summary in
            self?.removeTrashed(summary)
        }
    }

    func trashRequest(for entry: FileEntry) -> TrashCoordinator.Request {
        .single(entry) { [weak self] summary in
            self?.removeTrashed(summary)
        }
    }

    /// Updates results locally after a clean, without rescanning.
    private func removeTrashed(_ summary: CleanSummary) {
        let removed = summary.outcomes.filter(\.success)
        guard !removed.isEmpty else { return }
        let removedPaths = Set(removed.map(\.path))

        func isGone(_ path: String) -> Bool {
            removedPaths.contains(path) || removedPaths.contains { path.hasPrefix($0 + "/") }
        }
        func shrink(_ entry: FileEntry) -> FileEntry {
            let freed = removed.filter { $0.path.hasPrefix(entry.path + "/") }.reduce(0) { $0 + $1.bytes }
            guard freed > 0 else { return entry }
            let size = max(0, entry.sizeBytes - freed)
            sizes[entry.path] = size
            return FileEntry(path: entry.path, sizeBytes: size, isDirectory: entry.isDirectory, modified: entry.modified)
        }

        for (id, phase) in phases {
            guard case .scanned(let result) = phase else { continue }
            let entries = result.entries.filter { !isGone($0.path) }.map(shrink)
            phases[id] = .scanned(CategoryScanResult(
                categoryID: id, entries: entries, deniedPaths: result.deniedPaths, scannedAt: result.scannedAt
            ))
        }
        for (parent, kids) in children {
            if isGone(parent) { children[parent] = nil; continue }
            children[parent] = kids.filter { !isGone($0.path) }.map(shrink)
        }
        for path in Array(sizes.keys) where isGone(path) {
            sizes[path] = nil
            categoryOfPath[path] = nil
        }
        selection = selection.filter { !isGone($0) }
        recomputeTotals()
    }
}
