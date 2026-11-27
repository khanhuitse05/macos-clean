import MacosCleanCore
import Synchronization
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

    /// Every cleanup category except the Trash, which has its own section (``TrashView``).
    let categories = CleanupCategory.all.filter { $0.id != "trash" }
    private(set) var phases: [String: Phase] = [:] {
        didSet { clearVisibleCache() }
    }
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
    /// Capacity of the disk the home folder is on, for the header bar.
    private(set) var volume: VolumeUsage?

    /// Category ids in the order they're listed: found space largest first, then categories
    /// not scanned yet (in their usual order), then the ones with nothing to clean. Updated
    /// when a scan finishes, never by live updates, so rows don't jump while being read.
    private(set) var displayOrder: [String] = []
    /// Groups in the order they're listed: found space largest first, Personal Files last.
    /// Updated together with ``displayOrder``.
    private(set) var groupOrder: [CleanupCategory.Group] = CleanupCategory.Group.allCases
    /// Scanned categories whose folders don't exist on this Mac (the tool isn't installed):
    /// listed apart, in one "Not on this Mac" row at the bottom of their group.
    private(set) var notOnThisMac: Set<String> = []
    /// Categories done out of all of them, while ``scanAll()`` runs.
    private(set) var scanAllProgress: (done: Int, total: Int)?
    /// Bumped to make a category row glow briefly: when its scan finishes, or when a
    /// suggestion points at it.
    private(set) var highlights: [String: Int] = [:]
    /// When each category's last scan finished, so its total counts up only right after.
    @ObservationIgnored private var revealedAt: [String: ContinuousClock.Instant] = [:]
    /// The size each category had before the scan now running, to show how far along it is.
    @ObservationIgnored private var expectedBytes: [String: Int64] = [:]

    /// Running totals of scans in flight, keyed by category. Not observed: views sample it
    /// a few times a second with a `TimelineView` while a category shows `.scanning`.
    @ObservationIgnored private var liveProgress: [String: ScanProgress] = [:]

    @ObservationIgnored private var sizes: [String: Int64] = [:]
    @ObservationIgnored private var categoryOfPath: [String: String] = [:]
    /// Folder listings collected while measuring, not yet shown. Keyed by folder path.
    @ObservationIgnored private var prefetched: [String: [FileEntry]] = [:]
    @ObservationIgnored private var prefetchOwner: [String: String] = [:]
    @ObservationIgnored private var hasDefaultSelection: Set<String> = []
    @ObservationIgnored private var expansionDenied: Set<String> = []
    @ObservationIgnored private var scanner = CategoryScanner(exclusions: ExclusionStore.shared.list)
    @ObservationIgnored private let store = ScanResultStore()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var watcher: FileSystemWatcher?
    @ObservationIgnored private var pendingChanges: [FileSystemChange] = []
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    /// Earliest time each live-refreshed entry may be re-measured again.
    @ObservationIgnored private var nextRemeasure: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var cooledEntries: Set<String> = []
    @ObservationIgnored private var cooldownTask: Task<Void, Never>?
    /// The next live-refresh pass starts no earlier than this.
    @ObservationIgnored private var passQuietUntil: ContinuousClock.Instant?
    /// FSEvents event ID taken just before each category was last measured in full. Saved
    /// with the results, so the next launch can re-measure only what changed after it.
    @ObservationIgnored private var measuredSince: [String: UInt64] = [:]
    /// Replays the changes made while the app wasn't running (see ``catchUp(_:since:)``).
    @ObservationIgnored private var catchUpWatcher: FileSystemWatcher?

    /// Saved results older than this are rescanned in full at launch instead of caught up.
    static let catchUpMaxAge: TimeInterval = 7 * 24 * 60 * 60
    /// How long the FSEvents history replay may take before falling back to a full rescan.
    static let catchUpTimeout = Duration.seconds(20)

    /// After a live re-measure, the same entries wait this many times the CPU time it used.
    /// A folder that changes nonstop (a browser's 4 GB cache) then costs at most ~5% of one
    /// core on average, while small folders still update within seconds.
    private static let remeasureCostFactor = 20.0

    /// Runs scanner work at utility priority: background refreshes (launch catch-up, live
    /// updates) then never compete for CPU and disk with the UI or a scan the person started.
    private static func inBackground<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await Task.detached(priority: .utility, operation: work).value
    }

    /// CPU time used by the whole process so far (all threads, user + system).
    private static func processCPUTime() -> Duration {
        .nanoseconds(Int64(clamping: clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)))
    }

    init() {
        displayOrder = categories.map(\.id)
    }

    // MARK: Queries

    func phase(of category: CleanupCategory) -> Phase { phases[category.id] ?? .notScanned }

    /// ``categories`` in ``displayOrder``.
    var orderedCategories: [CleanupCategory] {
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        return displayOrder.compactMap { byID[$0] }
    }

    /// Categories of `group` in ``displayOrder`` (every category when `group` is nil).
    func orderedCategories(in group: CleanupCategory.Group?) -> [CleanupCategory] {
        guard let group else { return orderedCategories }
        return orderedCategories.filter { $0.group == group }
    }

    /// Space found in `group`'s categories so far.
    func foundBytes(in group: CleanupCategory.Group) -> Int64 {
        categories.reduce(0) { total, category in
            guard category.group == group, case .scanned(let result)? = phases[category.id] else { return total }
            return total + result.totalBytes
        }
    }

    func hasResult(in group: CleanupCategory.Group) -> Bool {
        categories.contains { category in
            guard category.group == group, case .scanned? = phases[category.id] else { return false }
            return true
        }
    }

    func isScanning(_ group: CleanupCategory.Group) -> Bool {
        categories.contains { $0.group == group && (phase(of: $0) == .scanning || refreshing.contains($0.id)) }
    }

    /// Whether something of `category` is on this Mac: its folders exist, or it found items.
    func isPresent(_ category: CleanupCategory) -> Bool {
        guard case .scanned(let result)? = phases[category.id], !notOnThisMac.contains(category.id) else { return false }
        if case .paths = category.source { return true }
        return !result.entries.isEmpty
    }

    /// A developer group whose categories were all scanned and none is on this Mac.
    func isAbsent(_ group: CleanupCategory.Group) -> Bool {
        guard group.isForDevelopers else { return false }
        let members = categories.filter { $0.group == group }
        return members.allSatisfy { category in
            guard case .scanned? = phases[category.id] else { return false }
            return !isPresent(category)
        }
    }

    /// Groups for the sidebar, in ``groupOrder``. Developer groups show only once a scan
    /// found something of theirs on this Mac.
    var sidebarGroups: [CleanupCategory.Group] {
        groupOrder.filter { group in
            !group.isForDevelopers || categories.contains { $0.group == group && isPresent($0) }
        }
    }

    /// The category's size before this scan began, if it had one.
    func expectedBytes(of category: CleanupCategory) -> Int64? { expectedBytes[category.id] }

    /// The folder a scan in flight is reading now, for the header.
    var liveFolder: String? { liveProgress.values.lazy.compactMap(\.currentFolder).first }

    /// True for a moment after the category's scan finished: its total counts up from zero.
    func isJustRevealed(_ category: CleanupCategory) -> Bool {
        guard let at = revealedAt[category.id] else { return false }
        return ContinuousClock.now - at < .seconds(1.5)
    }

    /// Makes a category row glow briefly (a suggestion pointing at it).
    func highlight(_ categoryID: String) {
        highlights[categoryID, default: 0] += 1
    }

    /// Sorts ``displayOrder`` by found space. Animated by the caller.
    private func reorder() {
        let original = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1.id, $0) })
        func rank(_ id: String) -> (Int, Int64, Int) {
            guard case .scanned(let result)? = phases[id] else { return (1, 0, original[id] ?? 0) }
            return result.totalBytes > 0 ? (0, -result.totalBytes, original[id] ?? 0) : (2, 0, original[id] ?? 0)
        }
        let sorted = categories.map(\.id).sorted { rank($0) < rank($1) }
        if sorted != displayOrder { displayOrder = sorted }

        let all = CleanupCategory.Group.allCases
        let groups = all.filter { $0 != .personal }
            .sorted { lhs, rhs in
                let (left, right) = (foundBytes(in: lhs), foundBytes(in: rhs))
                return left != right ? left > right : all.firstIndex(of: lhs)! < all.firstIndex(of: rhs)!
            } + [.personal]
        if groups != groupOrder { groupOrder = groups }
    }

    /// True when none of a scanned category's folders exist on this Mac.
    private func isMissing(_ category: CleanupCategory, result: CategoryScanResult) -> Bool {
        guard result.entries.isEmpty else { return false }
        switch category.source {
        case .paths(let raw):
            return !raw.contains { FileManager.default.fileExists(atPath: scanner.expander.expand($0).path) }
        case .simulators:
            return true
        case .appCaches, .devProjects:
            return false
        }
    }


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

    /// The category checkbox reflects the rows on screen, so a filter narrows it too.
    func checkState(of category: CleanupCategory) -> CheckState {
        guard case .scanned(let result) = phase(of: category) else { return .off }
        let entries = visibleEntries(of: result)
        guard !entries.isEmpty else { return .off }
        var sawOn = false
        var sawOther = false
        for entry in entries {
            if checkState(of: entry) == .on { sawOn = true } else { sawOther = true }
            if sawOn, sawOther { return .mixed }
        }
        return sawOn ? .on : (entries.contains { checkState(of: $0) == .mixed } ? .mixed : .off)
    }

    // MARK: Filtering

    /// Search, size and age limits and sort order for the result rows. Only a category's own
    /// rows are filtered; the contents of an expanded folder are always shown in full.
    var filter = EntryFilter() {
        didSet {
            clearVisibleCache()
            // "Clear" in the filter status row empties the search field too.
            if oldValue.query != filter.query, filter.query.isEmpty, !searchText.isEmpty { searchText = "" }
        }
    }

    /// The search field's text. Applied to ``filter`` after a short pause in typing, so a
    /// fast typist filters once instead of once per key; clearing applies at once.
    var searchText = "" { didSet { scheduleQuery() } }
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    static let searchDelay = Duration.milliseconds(150)

    private func scheduleQuery() {
        queryTask?.cancel()
        queryTask = nil
        let text = searchText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            if filter.query != text { filter.query = text }
            return
        }
        queryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled, let self, filter.query != text else { return }
            filter.query = text
        }
    }

    /// Rows after the filter, keyed by category id. A view asks for them many times per
    /// redraw (row list, checkbox, visibility, counts), so they're computed once per change
    /// of ``filter`` or ``phases``.
    @ObservationIgnored private var visibleCache: [String: [FileEntry]] = [:]
    /// Paths of every visible row, for ``hiddenSelectedCount``.
    @ObservationIgnored private var visiblePathsCache: Set<String>?

    private func clearVisibleCache() {
        visibleCache.removeAll(keepingCapacity: true)
        visiblePathsCache = nil
    }

    /// A result's rows after ``filter``. Without a filter or custom sort, the scan's own order.
    func visibleEntries(of result: CategoryScanResult) -> [FileEntry] {
        guard filter.isActive || filter.sort != .size else { return result.entries }
        let id = result.categoryID
        // Only results on screen are cached; a result passed in from elsewhere is filtered fresh.
        let isCurrent = if case .scanned(let current)? = phases[id] {
            current.scannedAt == result.scannedAt && current.entries.count == result.entries.count
        } else {
            false
        }
        if isCurrent, let cached = visibleCache[id] { return cached }
        let entries: [FileEntry]
        if result.simulators.isEmpty {
            entries = filter.apply(to: result.entries)
        } else {
            let names = Dictionary(result.simulators.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first })
            entries = filter.apply(to: result.entries) { names[$0.path] }
        }
        if isCurrent { visibleCache[id] = entries }
        return entries
    }

    /// Whether a category has a row to show. Every category shows while no filter is active.
    func isVisible(_ category: CleanupCategory) -> Bool {
        guard filter.isActive else { return true }
        guard case .scanned(let result) = phase(of: category) else { return false }
        return !visibleEntries(of: result).isEmpty
    }

    /// Rows on screen and rows found, across every scanned category.
    var visibleCounts: (shown: Int, total: Int) {
        var shown = 0
        var total = 0
        for case .scanned(let result) in phases.values {
            total += result.entries.count
            shown += filter.isActive ? visibleEntries(of: result).count : result.entries.count
        }
        return (shown, total)
    }

    /// Selected items a filter currently hides: neither a visible row nor inside one.
    var hiddenSelectedCount: Int {
        guard filter.isActive, !selection.units.isEmpty else { return 0 }
        let visible: Set<String>
        if let cached = visiblePathsCache {
            visible = cached
        } else {
            var paths = Set<String>()
            for case .scanned(let result) in phases.values {
                paths.formUnion(visibleEntries(of: result).lazy.map(\.path))
            }
            visiblePathsCache = paths
            visible = paths
        }
        return selection.units.reduce(0) { count, unit in
            if visible.contains(unit) { return count }
            var insideVisible = false
            PathSelection.forEachAncestor(of: unit) { ancestor in
                insideVisible = visible.contains(ancestor)
                return !insideVisible
            }
            return insideVisible ? count : count + 1
        }
    }

    /// Ticks (or unticks) only the rows the filter shows, in every scanned category.
    func setVisibleSelection(_ isSelected: Bool) {
        for category in categories {
            guard case .scanned(let result) = phase(of: category) else { continue }
            for entry in visibleEntries(of: result) {
                if isSelected { select(entry.path) } else { deselect(entry.path) }
            }
        }
        recomputeSelectionSummary()
    }

    func selectedBytes(in category: CleanupCategory) -> Int64 { selectedBytesByCategory[category.id] ?? 0 }

    func liveProgress(of category: CleanupCategory) -> ScanProgress? { liveProgress[category.id] }

    /// Bytes measured so far by every scan in flight.
    var liveScannedBytes: Int64 { liveProgress.values.reduce(0) { $0 + $1.bytes } }

    /// Reads the home volume's capacity off the main thread. With `settling`, reads it again
    /// a few seconds later too: APFS reports space freed by emptying the Trash with a delay.
    func refreshVolume(settling: Bool = false) {
        Task {
            let usage = await VolumeUsage.read()
            if usage != volume { Motion.animate(.smooth(duration: 0.6)) { volume = usage } }
            guard settling else { return }
            for delay in [2, 5] {
                try? await Task.sleep(for: .seconds(delay))
                let later = await VolumeUsage.read()
                if later != volume { Motion.animate(.smooth(duration: 0.8)) { volume = later } }
            }
        }
    }

    // MARK: Scanning

    /// Scans every category, or only `group`'s.
    func scanAll(in group: CleanupCategory.Group? = nil) async {
        guard !isScanningAll else { return }
        let categories = group.map { group in self.categories.filter { $0.group == group } } ?? self.categories
        isScanningAll = true
        scanAllProgress = (0, categories.count)
        defer {
            isScanningAll = false
            scanAllProgress = nil
        }
        // A few at a time; ScanThrottle caps the walks running underneath.
        await withTaskGroup(of: Void.self) { group in
            var pending = categories[...]
            func next() {
                guard let category = pending.popFirst() else { return }
                group.addTask { await self.scan(category) }
            }
            for _ in 0..<3 { next() }
            for await _ in group {
                if let progress = scanAllProgress { scanAllProgress = (progress.done + 1, progress.total) }
                next()
            }
        }
    }

    func scan(_ category: CleanupCategory) async {
        if phase(of: category) == .scanning { return }
        if case .scanned(let previous) = phase(of: category), previous.totalBytes > 0 {
            expectedBytes[category.id] = previous.totalBytes
        } else {
            expectedBytes[category.id] = nil
        }
        Motion.animate { phases[category.id] = .scanning }
        refreshing.remove(category.id)
        let progress = ScanProgress()
        liveProgress[category.id] = progress
        let since = FileSystemWatcher.currentEventID
        let result = await scanner.scan(category, progress: progress)
        liveProgress[category.id] = nil
        measuredSince[category.id] = since
        expectedBytes[category.id] = nil
        revealedAt[category.id] = .now
        Motion.animate(.spring(duration: 0.55, bounce: 0.2)) {
            apply(result, for: category)
            reorder()
        }
        highlight(category.id)
    }

    /// Shows the results saved by the last run at once, then brings them up to date in the
    /// background while they stay on screen. Runs once per launch.
    ///
    /// Categories of plain folders are caught up from FSEvents' history: only the items that
    /// changed since they were measured are measured again. The rest (app caches, code
    /// projects, simulators), results that are old or empty, and every result when the
    /// history can't be trusted are rescanned in full.
    func restoreAndRefresh() async {
        guard !didRestore else { return }
        didRestore = true
        refreshVolume()
        let saved = await store.load()
        var restored: [CleanupCategory] = []
        let exclusions = scanner.exclusions
        for category in categories {
            guard let result = saved.results[category.id], phase(of: category) == .notScanned else { continue }
            // Folders excluded since the last run stay hidden.
            apply(result.keeping(exclusions.filter(result.entries)), for: category, persist: false)
            if let since = saved.eventIDs[category.id] { measuredSince[category.id] = since }
            restored.append(category)
        }
        reorder()
        let sameHistory = saved.historyID != nil && saved.historyID == Self.historyID
        let caughtUp = sameHistory ? restored.filter(canCatchUp) : []
        if let since = caughtUp.compactMap({ measuredSince[$0.id] }).min() {
            catchUp(caughtUp, since: since)
        }
        let caughtUpIDs = Set(caughtUp.map(\.id))
        await refreshAllInBackground(restored.filter { !caughtUpIDs.contains($0.id) })
    }

    /// FSEvents' history of the home volume; saved event IDs only apply while it's the same.
    private static let historyID = FileSystemWatcher.historyID(ofVolumeAt: NSHomeDirectory())

    /// Whether a restored result can be brought up to date from FSEvents' history alone.
    private func canCatchUp(_ category: CleanupCategory) -> Bool {
        // Only plain folders are watched as a whole; other sources find new items elsewhere.
        guard case .paths = category.source, measuredSince[category.id] != nil,
              case .scanned(let result) = phase(of: category)
        else { return false }
        // An empty result may be a tool installed since: its folder isn't watched yet.
        return !result.entries.isEmpty && Date().timeIntervalSince(result.scannedAt) < Self.catchUpMaxAge
    }

    /// Replays the changes FSEvents recorded under `categories`' folders since `since`, then
    /// re-measures just those items through the live-update path. Falls back to a full
    /// background rescan if the history reports dropped detail or doesn't arrive in time.
    private func catchUp(_ categories: [CleanupCategory], since: UInt64) {
        let paths = watchedRoots(of: categories)
        guard !paths.isEmpty else { return }
        let buffer = ChangeBuffer()
        // Changes and the end of the history arrive in order on the watcher's queue; the
        // buffer hands them over together.
        let watcher = FileSystemWatcher(paths: paths, latency: 0.3, since: since, onHistoryDone: { [weak self] in
            let changes = buffer.take()
            Task { @MainActor in self?.finishCatchUp(categories, changes: changes) }
        }) { changes in
            buffer.append(changes)
        }
        catchUpWatcher = watcher
        watcher.start()
        Task { [weak self] in
            try? await Task.sleep(for: Self.catchUpTimeout)
            guard let self, catchUpWatcher === watcher else { return }
            finishCatchUp(categories, changes: nil)
        }
    }

    /// `changes` is nil when the history didn't arrive in time.
    private func finishCatchUp(_ categories: [CleanupCategory], changes: [FileSystemChange]?) {
        guard catchUpWatcher != nil else { return }
        catchUpWatcher?.stop()
        catchUpWatcher = nil
        guard let changes, !changes.contains(where: \.mustScanSubfolders) else {
            let scanned = categories.filter { if case .scanned = phase(of: $0) { true } else { false } }
            Task { await refreshAllInBackground(scanned) }
            return
        }
        if !changes.isEmpty { noteChanges(changes) }
    }

    /// Rescans `categories` while their current results stay on screen.
    private func refreshAllInBackground(_ categories: [CleanupCategory]) async {
        guard !categories.isEmpty else { return }
        refreshing.formUnion(categories.map(\.id))
        await withTaskGroup(of: Void.self) { group in
            var pending = categories[...]
            func next() {
                guard let category = pending.popFirst() else { return }
                group.addTask { await self.refreshInBackground(category) }
            }
            for _ in 0..<3 { next() }
            for await _ in group { next() }
        }
    }

    // MARK: Exclusions

    /// Hides everything that overlaps a newly excluded folder at once; folders taken off the
    /// list come back with a background rescan.
    func setExclusions(_ exclusions: ExclusionList) {
        let old = scanner.exclusions
        guard exclusions != old else { return }
        scanner = CategoryScanner(exclusions: exclusions)
        var hidden = Set<String>()
        for category in categories {
            guard case .scanned(let result) = phase(of: category) else { continue }
            let kept = exclusions.filter(result.entries)
            guard kept.count != result.entries.count else { continue }
            hidden.formUnion(result.entries.lazy.filter { exclusions.overlaps($0.path) }.map(\.path))
            Motion.animate { phases[category.id] = .scanned(result.keeping(kept)) }
        }
        if !hidden.isEmpty {
            forget(hidden)
            recomputeTotals()
            recomputeSelectionSummary()
            scheduleSave()
            updateWatcher()
        }
        if !old.paths.subtracting(exclusions.paths).isEmpty {
            let scanned = categories.filter { if case .scanned = phase(of: $0) { true } else { false } }
            Task { await refreshAllInBackground(scanned) }
        }
    }

    private func refreshInBackground(_ category: CleanupCategory) async {
        // A full scan started meanwhile takes over.
        guard refreshing.contains(category.id) else { return }
        let since = FileSystemWatcher.currentEventID
        let result = await Self.inBackground { [scanner] in await scanner.scan(category) }
        guard refreshing.remove(category.id) != nil, case .scanned = phase(of: category) else { return }
        measuredSince[category.id] = since
        Motion.animate {
            apply(result, for: category)
            reorder()
        }
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
        if isMissing(category, result: result) {
            notOnThisMac.insert(category.id)
        } else {
            notOnThisMac.remove(category.id)
        }

        if !hasDefaultSelection.contains(category.id) {
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
        refreshVolume()
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
        if phase(of: category) == .notScanned {
            await scan(category)
        }
        guard case .scanned(let result) = phase(of: category) else { return }
        // Acts on the rows on screen: with a filter active, hidden rows keep their state.
        let entries = visibleEntries(of: result)
        if checkState(of: category) == .on {
            for entry in entries { deselect(entry.path) }
        } else {
            for entry in entries { select(entry.path) }
        }
        recomputeSelectionSummary()
    }

    /// The group checkbox: the visible rows of the group's scanned categories.
    func checkState(of group: CleanupCategory.Group) -> CheckState {
        let states = categories.filter { $0.group == group && isScannedNonEmpty($0) }.map { checkState(of: $0) }
        guard !states.isEmpty else { return .off }
        if states.allSatisfy({ $0 == .on }) { return .on }
        return states.allSatisfy({ $0 == .off }) ? .off : .mixed
    }

    /// Ticks (or, when all are ticked, unticks) the visible rows of the group's scanned categories.
    func toggle(_ group: CleanupCategory.Group) {
        let select = checkState(of: group) != .on
        for category in categories where category.group == group {
            guard case .scanned(let result) = phase(of: category) else { continue }
            for entry in visibleEntries(of: result) {
                if select { self.select(entry.path) } else { deselect(entry.path) }
            }
        }
        recomputeSelectionSummary()
    }

    private func isScannedNonEmpty(_ category: CleanupCategory) -> Bool {
        guard case .scanned(let result) = phase(of: category) else { return false }
        return !visibleEntries(of: result).isEmpty
    }

    func selectAll() {
        for category in categories {
            if case .scanned(let result) = phase(of: category) {
                for entry in result.entries { select(entry.path) }
            }
        }
        recomputeSelectionSummary()
    }

    /// Ticks `paths` (a suggestion's items); paths no longer on screen are ignored.
    func select(paths: [String]) {
        for path in paths where categoryOfPath[path] != nil { select(path) }
        recomputeSelectionSummary()
    }

    /// Every finished result, keyed by category id.
    var scannedResults: [String: CategoryScanResult] {
        phases.compactMapValues { if case .scanned(let result) = $0 { result } else { nil } }
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
                total += result.totalBytes
                denied += result.deniedPaths
            }
        }
        if foundBytes != total { foundBytes = total }
        let sortedDenied = Array(Set(denied).union(expansionDenied)).sorted()
        if deniedPaths != sortedDenied { deniedPaths = sortedDenied }
    }

    // MARK: Trash

    func trashRequest() -> TrashCoordinator.Request? {
        let units = selection.units.sorted()
        guard !units.isEmpty else { return nil }
        let categoryCount = Set(units.compactMap { categoryOfPath[$0] }).count
        // Simulators are removed with simctl; everything else goes to the Trash.
        let simulators = units.compactMap(simulatorItem(at:))
        let simulatorPaths = Set(simulators.map(\.path))
        let paths = units.filter { !simulatorPaths.contains($0) }
        let simulatorBytes = simulators.reduce(0) { $0 + $1.sizeBytes }
        return .cleaning(
            paths, bytes: max(0, selectedBytes - simulatorBytes), simulators: simulators,
            extraMessage: categoryCount > 1 ? "From \(categoryCount) categories. Quit apps whose caches you're cleaning first." : nil
        ) { [weak self] summary in
            self?.removeTrashed(summary)
        }
    }

    /// Whether `group` has Safe items "Clean Safe Items" would move.
    func hasSafeItems(in group: CleanupCategory.Group) -> Bool {
        categories.contains { category in
            guard category.group == group, category.safety == .safe, !category.isRemovedWithSimctl,
                  case .scanned(let result)? = phases[category.id]
            else { return false }
            return result.totalBytes > 0
        }
    }

    /// Everything in `group`'s Safe categories, for "Clean Safe Items". Leaves the current
    /// selection alone; nil when there's nothing to clean.
    func safeItemsRequest(in group: CleanupCategory.Group) -> TrashCoordinator.Request? {
        var paths: [String] = []
        var bytes: Int64 = 0
        for category in categories where category.group == group && category.safety == .safe && !category.isRemovedWithSimctl {
            guard case .scanned(let result) = phase(of: category) else { continue }
            for entry in result.entries where entry.sizeBytes > 0 {
                paths.append(entry.path)
                bytes += entry.sizeBytes
            }
        }
        guard !paths.isEmpty else { return nil }
        return .cleaning(
            paths, bytes: bytes, simulators: [],
            extraMessage: "Every Safe item in \(String(localized: group.title)). Quit apps whose caches you're cleaning first."
        ) { [weak self] summary in
            self?.removeTrashed(summary)
        }
    }

    func trashRequest(for entry: FileEntry) -> TrashCoordinator.Request {
        if let item = simulatorItem(at: entry.path) {
            return .cleaning([], bytes: 0, simulators: [item]) { [weak self] summary in
                self?.removeTrashed(summary)
            }
        }
        return .single(entry) { [weak self] summary in
            self?.removeTrashed(summary)
        }
    }

    /// The simulator runtime or device shown at `path`, if that row is one.
    func simulatorItem(at path: String) -> SimulatorItem? {
        guard let id = categoryOfPath[path], case .scanned(let result)? = phases[id], !result.simulators.isEmpty else { return nil }
        return result.simulators.first { $0.path == path }
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
            phases[id] = .scanned(result.keeping(entries))
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
        refreshVolume()
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
            let eventIDs = measuredSince.filter { results[$0.key] != nil }
            await store.save(ScanResultStore.Saved(results: results, eventIDs: eventIDs, historyID: Self.historyID))
        }
    }

    // MARK: Live updates (FSEvents)

    /// Watches the folders behind the results on screen. Recreated only when that set changes.
    private func updateWatcher() {
        let paths = watchedRoots(of: categories)
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

    /// The folders whose changes can affect `categories`' results on screen, sorted.
    private func watchedRoots(of categories: [CleanupCategory]) -> [String] {
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
            case .simulators:
                break
            }
        }
        return roots.sorted()
    }

    private func noteChanges(_ changes: [FileSystemChange]) {
        pendingChanges += changes
        guard changeTask == nil else { return }
        // Let bursts (a browser writing its cache) settle into one refresh, and keep all live
        // refreshes together within the same CPU budget as a single entry.
        let due = max(ContinuousClock.now + .seconds(3), passQuietUntil ?? .now)
        changeTask = Task { [weak self] in
            try? await Task.sleep(until: due)
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
            let now = ContinuousClock.now
            let cpuBefore = Self.processCPUTime()
            defer { passQuietUntil = .now + (Self.processCPUTime() - cpuBefore) * Self.remeasureCostFactor }
            // Simulators aren't on the watched folders; they change only with a rescan.
            for category in categories where !refreshing.contains(category.id) && !category.isRemovedWithSimctl {
                guard case .scanned(let result) = phase(of: category) else { continue }
                var plan = refreshPlan(for: category, result: result, changes: changes)
                let cooling = plan.entries.filter { (nextRemeasure[$0] ?? now) > now }
                if !cooling.isEmpty {
                    plan.entries.subtract(cooling)
                    deferUntilCooled(cooling)
                }
                if !plan.isEmpty { await refresh(category, plan: plan) }
            }
        }
        changeTask = nil
        if !pendingChanges.isEmpty { noteChanges([]) }
    }

    /// Re-checks `entries` once their cool-down (see ``remeasureCostFactor``) is over.
    private func deferUntilCooled(_ entries: Set<String>) {
        cooledEntries.formUnion(entries)
        guard cooldownTask == nil else { return }
        let now = ContinuousClock.now
        let due = cooledEntries.compactMap { nextRemeasure[$0] }.min() ?? now
        cooldownTask = Task { [weak self] in
            try? await Task.sleep(until: due)
            guard let self else { return }
            let entries = cooledEntries
            cooledEntries = []
            cooldownTask = nil
            // Entries still cooling are deferred again by applyPendingChanges.
            noteChanges(entries.map { FileSystemChange(path: $0, mustScanSubfolders: false) })
        }
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
            let listing = await Self.inBackground { [scanner] in await scanner.shallowList(URL(fileURLWithPath: root)) }
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
        // Cost is CPU time, not wall time: the walk runs on every core at once.
        let cpuBefore = Self.processCPUTime()
        let measured = await Self.inBackground { [scanner] in await scanner.measure(targets.map { URL(fileURLWithPath: $0) }) }
        let cost = Self.processCPUTime() - cpuBefore
        let quietUntil = ContinuousClock.now + cost * Self.remeasureCostFactor
        for target in targets { nextRemeasure[target] = quietUntil }

        // Merge into the current result: it may have changed (trash) while we measured.
        guard case .scanned(let current) = phase(of: category), current.scannedAt == before.scannedAt else { return }
        var updated: [String: FileEntry] = fileSizes
        for entry in measured.entries {
            if entry.modified == nil { vanished.insert(entry.path) } else { updated[entry.path] = entry }
        }
        let wasFullySelected = checkState(of: category) == .on
        var entries: [FileEntry] = []
        var seen = Set<String>()
        for entry in current.entries where !vanished.contains(entry.path) {
            entries.append(updated[entry.path] ?? entry)
            seen.insert(entry.path)
        }
        let added = updated.values.filter {
            !seen.contains($0.path) && $0.sizeBytes > 0 && !scanner.exclusions.overlaps($0.path)
        }
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
        Motion.animate {
            phases[category.id] = .scanned(CategoryScanResult(
                categoryID: category.id, entries: entries.sortedBySizeDescending(),
                deniedPaths: current.deniedPaths, scannedAt: current.scannedAt
            ))
        }
        recomputeTotals()
        recomputeSelectionSummary()
        scheduleSave()
        updateWatcher()
    }
}

/// Capacity of the volume that holds the home folder.
struct VolumeUsage: Equatable, Sendable {
    let total: Int64
    let available: Int64
    var used: Int64 { max(0, total - available) }

    @concurrent
    static func read() async -> VolumeUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return VolumeUsage(total: Int64(total), available: min(available, Int64(total)))
    }
}

private extension CategoryScanResult {
    /// The listings live in the model's own cache; don't keep a second reference in the phase.
    var strippingPrefetched: CategoryScanResult {
        prefetched.isEmpty ? self : keeping(entries)
    }
}

/// Saves the Storage Manager's results between launches
/// (`~/Library/Application Support/<bundle id>/scan_results.json`).
actor ScanResultStore {
    struct Saved: Sendable {
        var results: [String: CategoryScanResult] = [:]
        /// FSEvents event ID taken before each category was measured in full.
        var eventIDs: [String: UInt64] = [:]
        /// ``FileSystemWatcher/historyID(ofVolumeAt:)`` of the home volume when saved.
        var historyID: String?
    }

    private struct Payload: Codable {
        var version = 1
        var results: [String: CategoryScanResult]
        // Optional: files written before these existed still load.
        var eventIDs: [String: UInt64]?
        var historyID: String?
    }

    private let url: URL?

    init() {
        url = AppWatcher.defaultCacheURL?.deletingLastPathComponent().appendingPathComponent("scan_results.json")
    }

    func load() -> Saved {
        guard let url, let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1
        else { return Saved() }
        return Saved(results: payload.results, eventIDs: payload.eventIDs ?? [:], historyID: payload.historyID)
    }

    func save(_ saved: Saved) {
        let payload = Payload(results: saved.results, eventIDs: saved.eventIDs, historyID: saved.historyID)
        guard let url, let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Changes a watcher delivered, kept until the code that asked for them takes them all.
private final class ChangeBuffer: Sendable {
    private let changes = Mutex<[FileSystemChange]>([])

    func append(_ batch: [FileSystemChange]) {
        changes.withLock { $0 += batch }
    }

    func take() -> [FileSystemChange] {
        changes.withLock { value in
            defer { value = [] }
            return value
        }
    }
}
