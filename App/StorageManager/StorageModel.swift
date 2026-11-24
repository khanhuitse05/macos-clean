import MacosCleanCore
import SwiftUI

/// State of the Storage Manager: per-category scan results, lazily loaded subfolders, and the
/// selection of paths to move to the Trash.
///
/// Speed notes:
/// - Selection checks per row are O(1) through ``PathSelection``; totals are recomputed from
///   the deduped units only.
/// - Scans prefetch the listings of folders two levels deep, so expanding them is instant.
/// - Results are saved between launches and shown at once while a background rescan runs.
/// - FSEvents keeps sizes current: only the items that changed on disk are re-measured.
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
    /// Categories being rescanned in the background while their last results stay on screen.
    private(set) var refreshing: Set<String> = []

    /// Selected paths. May contain a folder and its loaded descendants; totals use `selection.units`.
    private(set) var selection = PathSelection()
    private(set) var selectedCount = 0
    private(set) var selectedBytes: Int64 = 0
    private(set) var selectedBytesByCategory: [String: Int64] = [:]
    private(set) var foundBytes: Int64 = 0
    private(set) var deniedPaths: [String] = []

    @ObservationIgnored private var sizes: [String: Int64] = [:]
    @ObservationIgnored private var categoryOfPath: [String: String] = [:]
    /// Folder listings collected while measuring, not yet shown. Keyed by folder path.
    @ObservationIgnored private var prefetched: [String: [FileEntry]] = [:]
    @ObservationIgnored private var prefetchOwner: [String: String] = [:]
    @ObservationIgnored private var hasDefaultSelection: Set<String> = []
    @ObservationIgnored private var expansionDenied: Set<String> = []
    @ObservationIgnored private let scanner = CategoryScanner()
    @ObservationIgnored private let store = ScanResultStore()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var watcher: FileSystemWatcher?
    @ObservationIgnored private var pendingChanges: [FileSystemChange] = []
    @ObservationIgnored private var changeTask: Task<Void, Never>?

    // MARK: Queries

    func phase(of category: CleanupCategory) -> Phase { phases[category.id] ?? .notScanned }

    func isReadOnly(_ category: CleanupCategory) -> Bool { Self.readOnlyCategoryIDs.contains(category.id) }

    func isRefreshing(_ category: CleanupCategory) -> Bool { refreshing.contains(category.id) }

    var hasAnyResult: Bool {
        phases.values.contains { if case .scanned = $0 { true } else { false } }
    }

    /// When the oldest result on screen was measured.
    var oldestScan: Date? {
        phases.values.compactMap { phase -> Date? in
            if case .scanned(let result) = phase { result.scannedAt } else { nil }
        }.min()
    }

    func checkState(of entry: FileEntry) -> CheckState {
        if selection.contains(entry.path) { return .on }
        return entry.isDirectory && selection.hasSelectedDescendant(entry.path) ? .mixed : .off
    }

    func checkState(of category: CleanupCategory) -> CheckState {
        guard case .scanned(let result) = phase(of: category), !result.entries.isEmpty else { return .off }
        var sawOn = false
        var sawOther = false
        for entry in result.entries {
            if checkState(of: entry) == .on { sawOn = true } else { sawOther = true }
            if sawOn, sawOther { return .mixed }
        }
        return sawOn ? .on : (result.entries.contains { checkState(of: $0) == .mixed } ? .mixed : .off)
    }

    func selectedBytes(in category: CleanupCategory) -> Int64 { selectedBytesByCategory[category.id] ?? 0 }

    // MARK: Scanning

    func scanAll() async {
        guard !isScanningAll else { return }
        isScanningAll = true
        defer { isScanningAll = false }
        // A few at a time; ScanThrottle caps the walks running underneath.
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
        refreshing.remove(category.id)
        let result = await scanner.scan(category)
        apply(result, for: category)
    }

    /// Shows the results saved by the last run at once, then rescans those categories in the
    /// background while they stay on screen. Runs once per launch.
    func restoreAndRefresh() async {
        guard !didRestore else { return }
        didRestore = true
        let saved = await store.load()
        var restored: [CleanupCategory] = []
        for category in categories {
            guard let result = saved[category.id], phase(of: category) == .notScanned else { continue }
            apply(result, for: category, persist: false)
            restored.append(category)
        }
        guard !restored.isEmpty else { return }
        refreshing.formUnion(restored.map(\.id))
        await withTaskGroup(of: Void.self) { group in
            var pending = restored[...]
            func next() {
                guard let category = pending.popFirst() else { return }
                group.addTask { await self.refreshInBackground(category) }
            }
            for _ in 0..<3 { next() }
            for await _ in group { next() }
        }
    }

    private func refreshInBackground(_ category: CleanupCategory) async {
        // A full scan started meanwhile takes over.
        guard refreshing.contains(category.id) else { return }
        let result = await scanner.scan(category)
        guard refreshing.remove(category.id) != nil, case .scanned = phase(of: category) else { return }
        apply(result, for: category)
    }

    /// Called when a folder row opens: shows prefetched children at once when the scan
    /// already walked them.
    func expand(_ entry: FileEntry) {
        guard entry.isDirectory, children[entry.path] == nil, let listing = prefetched[entry.path] else { return }
        install(listing, under: entry, denied: [])
    }

    func loadChildren(of entry: FileEntry) async {
        guard entry.isDirectory, children[entry.path] == nil, !loadingChildren.contains(entry.path) else { return }
        if prefetched[entry.path] != nil {
            expand(entry)
            return
        }
        loadingChildren.insert(entry.path)
        let listing = await scanner.list(entry.url)
        loadingChildren.remove(entry.path)
        // Trashed or rescanned while loading.
        guard children[entry.path] == nil, let owner = categoryOfPath[entry.path] else { return }
        addPrefetched(listing.prefetched, owner: owner)
        install(listing.entries, under: entry, denied: listing.deniedPaths)
    }

    private func install(_ kids: [FileEntry], under entry: FileEntry, denied: [String]) {
        let owner = categoryOfPath[entry.path]
        for child in kids {
            sizes[child.path] = child.sizeBytes
            categoryOfPath[child.path] = owner
        }
        children[entry.path] = kids
        if !denied.isEmpty {
            expansionDenied.formUnion(denied)
            recomputeTotals()
        }
        // A selected folder's newly shown children inherit its tick.
        if selection.contains(entry.path) { selection.formUnion(kids.map(\.path)) }
        recomputeSelectionSummary()
    }

    private func apply(_ result: CategoryScanResult, for category: CleanupCategory, persist: Bool = true) {
        // Forget stale selection and children for this category before replacing it.
        let stale = categoryOfPath.filter { $0.value == category.id }.map(\.key)
        for path in stale {
            categoryOfPath[path] = nil
            sizes[path] = nil
            children[path] = nil
        }
        let staleSet = Set(stale)
        let previouslySelected = selection.paths.intersection(staleSet)
        expansionDenied = expansionDenied.filter { !Self.isInside($0, anyOf: staleSet) }
        selection.subtract(previouslySelected)
        dropPrefetched(ownedBy: category.id)

        for entry in result.entries {
            sizes[entry.path] = entry.sizeBytes
            categoryOfPath[entry.path] = category.id
        }
        addPrefetched(result.prefetched, owner: category.id)
        phases[category.id] = .scanned(result.strippingPrefetched)

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
        recomputeSelectionSummary()
        if persist { scheduleSave() }
        updateWatcher()
    }

    private func addPrefetched(_ listings: [String: [FileEntry]], owner: String) {
        for (folder, entries) in listings {
            prefetched[folder] = entries
            prefetchOwner[folder] = owner
        }
    }

    private func dropPrefetched(ownedBy owner: String) {
        for (folder, folderOwner) in prefetchOwner where folderOwner == owner {
            prefetched[folder] = nil
            prefetchOwner[folder] = nil
        }
    }

    /// True when `path` is one of `folders` or inside one of them. O(depth).
    private static func isInside(_ path: String, anyOf folders: Set<String>) -> Bool {
        if folders.contains(path) { return true }
        var found = false
        PathSelection.forEachAncestor(of: path) { ancestor in
            found = folders.contains(ancestor)
            return !found
        }
        return found
    }

    // MARK: Selection

    func toggle(_ entry: FileEntry) {
        if checkState(of: entry) == .on {
            deselect(entry.path)
        } else {
            select(entry.path)
        }
        recomputeSelectionSummary()
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
        recomputeSelectionSummary()
    }

    func selectAll() {
        for category in categories where !isReadOnly(category) {
            if case .scanned(let result) = phase(of: category) {
                for entry in result.entries { select(entry.path) }
            }
        }
        recomputeSelectionSummary()
    }

    func selectNone() {
        selection.removeAll()
        recomputeSelectionSummary()
    }

    private func select(_ path: String) {
        selection.insert(path)
        selection.formUnion(loadedDescendants(of: path))
    }

    /// Unticks a path and its descendants. A ticked ancestor becomes partially ticked: it's
    /// unticked and its other loaded children stay ticked.
    private func deselect(_ path: String) {
        selection.remove(path)
        selection.subtract(loadedDescendants(of: path))
        var child = path
        var parent = (child as NSString).deletingLastPathComponent
        while parent != child, let siblings = children[parent] {
            if selection.contains(parent) {
                selection.remove(parent)
                selection.formUnion(siblings.lazy.map(\.path).filter { $0 != child })
            }
            child = parent
            parent = (child as NSString).deletingLastPathComponent
        }
    }

    private func loadedDescendants(of path: String) -> [String] {
        guard let kids = children[path] else { return [] }
        return kids.flatMap { [$0.path] + loadedDescendants(of: $0.path) }
    }

    /// O(selected units): sums only the paths a trash would act on.
    private func recomputeSelectionSummary() {
        var total: Int64 = 0
        var byCategory: [String: Int64] = [:]
        for unit in selection.units {
            let size = max(0, sizes[unit] ?? 0)
            total += size
            if let category = categoryOfPath[unit] { byCategory[category, default: 0] += size }
        }
        if selectedCount != selection.units.count { selectedCount = selection.units.count }
        if selectedBytes != total { selectedBytes = total }
        if selectedBytesByCategory != byCategory { selectedBytesByCategory = byCategory }
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
        if foundBytes != total { foundBytes = total }
        let sortedDenied = Array(Set(denied).union(expansionDenied)).sorted()
        if deniedPaths != sortedDenied { deniedPaths = sortedDenied }
    }

    // MARK: Trash

    func trashRequest() -> TrashCoordinator.Request? {
        let paths = selection.units.sorted()
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

    /// Updates results locally after a clean, without rescanning. O(items × depth).
    private func removeTrashed(_ summary: CleanSummary) {
        let removed = summary.outcomes.filter(\.success)
        guard !removed.isEmpty else { return }
        let removedPaths = Set(removed.map(\.path))
        // Bytes freed inside each folder that contained a removed item.
        var freedUnder: [String: Int64] = [:]
        for outcome in removed {
            PathSelection.forEachAncestor(of: outcome.path) { ancestor in
                freedUnder[ancestor, default: 0] += outcome.bytes
                return true
            }
        }
        func isGone(_ path: String) -> Bool { Self.isInside(path, anyOf: removedPaths) }
        func shrink(_ entry: FileEntry) -> FileEntry {
            guard let freed = freedUnder[entry.path], freed > 0 else { return entry }
            let size = max(0, entry.sizeBytes - freed)
            if sizes[entry.path] != nil { sizes[entry.path] = size }
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
        for (folder, kids) in prefetched {
            if isGone(folder) {
                prefetched[folder] = nil
                prefetchOwner[folder] = nil
                continue
            }
            prefetched[folder] = kids.filter { !isGone($0.path) }.map(shrink)
        }
        for path in Array(sizes.keys) where isGone(path) {
            sizes[path] = nil
            categoryOfPath[path] = nil
        }
        selection.keepOnly { !isGone($0) }
        recomputeTotals()
        recomputeSelectionSummary()
        scheduleSave()
        updateWatcher()
    }

    // MARK: Saved results

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            var results: [String: CategoryScanResult] = [:]
            for (id, phase) in phases {
                if case .scanned(let result) = phase { results[id] = result }
            }
            await store.save(results)
        }
    }

    // MARK: Live updates (FSEvents)

    /// Watches the folders behind the results on screen. Recreated only when that set changes.
    private func updateWatcher() {
        var roots = Set<String>()
        for category in categories {
            guard case .scanned(let result) = phase(of: category) else { continue }
            switch category.source {
            case .paths(let raw):
                for path in raw.map({ scanner.expander.expand($0).path }) where FileManager.default.fileExists(atPath: path) {
                    roots.insert(path)
                }
            case .appCaches, .devProjects:
                roots.formUnion(result.entries.map(\.path))
            }
        }
        let paths = roots.sorted()
        guard paths != watcher?.paths else { return }
        watcher?.stop()
        watcher = nil
        guard !paths.isEmpty else { return }
        let created = FileSystemWatcher(paths: paths, latency: 2) { [weak self] changes in
            Task { @MainActor in self?.noteChanges(changes) }
        }
        created.start()
        watcher = created
    }

    private func noteChanges(_ changes: [FileSystemChange]) {
        pendingChanges += changes
        guard changeTask == nil else { return }
        changeTask = Task { [weak self] in
            // Let bursts (a browser writing its cache) settle into one refresh.
            try? await Task.sleep(for: .seconds(3))
            await self?.applyPendingChanges()
        }
    }

    private func applyPendingChanges() async {
        let changes = pendingChanges
        pendingChanges = []
        if isScanningAll {
            // The running full scan will produce fresh numbers; check again afterwards.
            pendingChanges = changes
        } else {
            for category in categories where !refreshing.contains(category.id) {
                guard case .scanned(let result) = phase(of: category) else { continue }
                let plan = refreshPlan(for: category, result: result, changes: changes)
                if !plan.isEmpty { await refresh(category, plan: plan) }
            }
        }
        changeTask = nil
        if !pendingChanges.isEmpty { noteChanges([]) }
    }

    /// Drops every registration at or under `paths`: sizes, owners, listings and ticks.
    private func forget(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        for path in Array(categoryOfPath.keys) where Self.isInside(path, anyOf: paths) {
            categoryOfPath[path] = nil
            sizes[path] = nil
        }
        for folder in Array(children.keys) where Self.isInside(folder, anyOf: paths) { children[folder] = nil }
        for folder in Array(prefetched.keys) where Self.isInside(folder, anyOf: paths) {
            prefetched[folder] = nil
            prefetchOwner[folder] = nil
        }
        selection.keepOnly { !Self.isInside($0, anyOf: paths) }
    }

    private struct RefreshPlan {
        /// Result entries with something changed inside them.
        var entries: Set<String> = []
        /// Category roots whose direct children were added, removed or resized.
        var roots: Set<String> = []
        var isEmpty: Bool { entries.isEmpty && roots.isEmpty }
    }

    private func roots(of category: CleanupCategory) -> Set<String> {
        guard case .paths(let raw) = category.source else { return [] }
        return Set(raw.map { scanner.expander.expand($0).path })
    }

    private func refreshPlan(for category: CleanupCategory, result: CategoryScanResult, changes: [FileSystemChange]) -> RefreshPlan {
        let entryPaths = Set(result.entries.map(\.path))
        let roots = roots(of: category)
        var plan = RefreshPlan()
        for change in changes {
            if entryPaths.contains(change.path) {
                plan.entries.insert(change.path)
            } else {
                PathSelection.forEachAncestor(of: change.path) { ancestor in
                    guard entryPaths.contains(ancestor) else { return true }
                    plan.entries.insert(ancestor)
                    return false
                }
            }
            if roots.contains(change.path) { plan.roots.insert(change.path) }
            if change.mustScanSubfolders {
                let prefix = change.path + "/"
                plan.entries.formUnion(entryPaths.filter { $0.hasPrefix(prefix) })
                plan.roots.formUnion(roots.filter { $0 == change.path || $0.hasPrefix(prefix) })
            }
        }
        return plan
    }

    /// Re-measures only what changed: the dirty entries, plus new or vanished items directly
    /// inside a changed root.
    private func refresh(_ category: CleanupCategory, plan: RefreshPlan) async {
        var remeasure = plan.entries
        var vanished = Set<String>()
        var fileSizes: [String: FileEntry] = [:]

        guard case .scanned(let before) = phase(of: category) else { return }
        let known = Set(before.entries.map(\.path))
        for root in plan.roots {
            let listing = await scanner.shallowList(URL(fileURLWithPath: root))
            guard listing.deniedPaths.isEmpty else { continue }
            let present = Set(listing.entries.map(\.path))
            vanished.formUnion(known.filter { ($0 as NSString).deletingLastPathComponent == root && !present.contains($0) })
            for child in listing.entries {
                if child.isDirectory {
                    if !known.contains(child.path) { remeasure.insert(child.path) }
                } else {
                    fileSizes[child.path] = child
                }
            }
        }
        let targets = remeasure.subtracting(vanished).sorted()
        let measured = await scanner.measure(targets.map { URL(fileURLWithPath: $0) })

        // Merge into the current result: it may have changed (trash) while we measured.
        guard case .scanned(let current) = phase(of: category), current.scannedAt == before.scannedAt else { return }
        var updated: [String: FileEntry] = fileSizes
        for entry in measured.entries {
            if entry.modified == nil { vanished.insert(entry.path) } else { updated[entry.path] = entry }
        }
        let wasFullySelected = !isReadOnly(category) && checkState(of: category) == .on
        var entries: [FileEntry] = []
        var seen = Set<String>()
        for entry in current.entries where !vanished.contains(entry.path) {
            entries.append(updated[entry.path] ?? entry)
            seen.insert(entry.path)
        }
        let added = updated.values.filter { !seen.contains($0.path) && $0.sizeBytes > 0 }
        entries += added
        if case .appCaches = category.source { entries = entries.filter { $0.sizeBytes > 0 } }
        guard entries != current.entries || !vanished.isEmpty else { return }

        forget(vanished)
        for entry in entries {
            sizes[entry.path] = entry.sizeBytes
            categoryOfPath[entry.path] = category.id
        }
        // Re-measured folders bring fresh listings; expanded rows inside them switch to those.
        let remeasured = Set(measured.entries.filter { $0.modified != nil }.map(\.path))
        for folder in Array(prefetched.keys) where Self.isInside(folder, anyOf: remeasured) {
            prefetched[folder] = nil
            prefetchOwner[folder] = nil
        }
        addPrefetched(measured.prefetched, owner: category.id)
        for folder in Array(children.keys) where Self.isInside(folder, anyOf: remeasured) {
            guard let fresh = prefetched[folder] else { continue }
            let freshPaths = Set(fresh.map(\.path))
            let gone = Set((children[folder] ?? []).map(\.path)).subtracting(freshPaths)
            if !gone.isEmpty { forget(gone) }
            children[folder] = fresh
            for kid in fresh {
                sizes[kid.path] = kid.sizeBytes
                categoryOfPath[kid.path] = category.id
            }
            if selection.contains(folder) { selection.formUnion(freshPaths) }
        }
        if wasFullySelected, category.safety.selectedByDefault {
            selection.formUnion(added.map(\.path))
        }
        phases[category.id] = .scanned(CategoryScanResult(
            categoryID: category.id, entries: entries.sortedBySizeDescending(),
            deniedPaths: current.deniedPaths, scannedAt: current.scannedAt
        ))
        recomputeTotals()
        recomputeSelectionSummary()
        scheduleSave()
        updateWatcher()
    }
}

private extension CategoryScanResult {
    /// The listings live in the model's own cache; don't keep a second reference in the phase.
    var strippingPrefetched: CategoryScanResult {
        prefetched.isEmpty ? self : CategoryScanResult(
            categoryID: categoryID, entries: entries, deniedPaths: deniedPaths, scannedAt: scannedAt
        )
    }
}

/// Saves the Storage Manager's results between launches
/// (`~/Library/Application Support/<bundle id>/scan_results.json`).
actor ScanResultStore {
    private struct Payload: Codable {
        var version = 1
        var results: [String: CategoryScanResult]
    }

    private let url: URL?

    init() {
        url = AppWatcher.defaultCacheURL?.deletingLastPathComponent().appendingPathComponent("scan_results.json")
    }

    func load() -> [String: CategoryScanResult] {
        guard let url, let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1
        else { return [:] }
        return payload.results
    }

    func save(_ results: [String: CategoryScanResult]) {
        guard let url, let data = try? JSONEncoder().encode(Payload(results: results)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
