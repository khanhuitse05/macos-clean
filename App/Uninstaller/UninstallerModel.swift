import AppKit
import MacosCleanCore
import SwiftUI

/// Something shown in the Uninstaller list: an installed app, or one removed outside macos-clean
/// whose leftovers can still be cleaned up.
enum UninstallItem: Hashable, Identifiable {
    case app(InstalledApp)
    case removed(RemovedApp)
    /// Files named after an app that is no longer on this Mac (``OrphanFinder``).
    case orphan(OrphanApp)

    var id: String {
        switch self {
        case .app(let app): "app:" + app.path
        case .removed(let removed): "removed:" + removed.bundleID
        case .orphan(let orphan): "orphan:" + orphan.bundleID
        }
    }

    var name: String {
        switch self {
        case .app(let app): app.name
        case .removed(let removed): removed.name
        case .orphan(let orphan): orphan.bundleID
        }
    }

    var bundleID: String {
        switch self {
        case .app(let app): app.bundleID
        case .removed(let removed): removed.bundleID
        case .orphan(let orphan): orphan.bundleID
        }
    }

    var appURL: URL? {
        if case .app(let app) = self { app.url } else { nil }
    }
}

@MainActor
@Observable
final class UninstallerModel {
    enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Name", size = "Size", date = "Date Modified"
        var id: String { rawValue }
    }

    private(set) var apps: [InstalledApp] = []
    private(set) var removed: [RemovedApp] = []
    private(set) var visibleApps: [InstalledApp] = []
    private(set) var visibleRemoved: [RemovedApp] = []
    private(set) var isLoading = true
    /// Leftovers of apps deleted before macOS Clean was watching. Found once apps are listed.
    private(set) var orphans: [OrphanApp] = []
    private(set) var visibleOrphans: [OrphanApp] = []
    private(set) var isFindingOrphans = false

    /// Mirrors ``AccessModel/hasFullDiskAccess``. Without it macOS refuses to move other apps'
    /// containers, so leftovers there can't be removed.
    var hasFullDiskAccess = true {
        didSet {
            guard hasFullDiskAccess != oldValue else { return }
            // What can be removed changed: forget the ticks and failures based on the old state.
            blockedPaths = []
            for id in leftovers.keys where Self.isOrphanID(id) {
                leftovers[id] = nil
                checked[id] = nil
            }
            if let item = selectedItem, case .orphan = item { Task { await loadLeftovers(for: item) } }
        }
    }

    /// Leftover files macOS refused to move this session. They're treated as locked until
    /// Full Disk Access changes or the app is relaunched.
    private(set) var blockedPaths: Set<String> = []

    /// Leftovers smaller than this are folded into one row.
    static let smallOrphanLimit: Int64 = 1_000_000

    /// How widely leftovers are looked for. Changing it rescans the open app.
    var sensitivity: MatchSensitivity = UninstallerModel.savedSensitivity {
        didSet {
            guard sensitivity != oldValue else { return }
            UserDefaults.standard.set(sensitivity.rawValue, forKey: Self.sensitivityKey)
            leftovers = leftovers.filter { $0.key.hasPrefix("orphan:") }
            checked = checked.filter { $0.key.hasPrefix("orphan:") }
            if let item = selectedItem { Task { await loadLeftovers(for: item) } }
        }
    }

    var searchText = "" { didSet { refreshVisible() } }
    var sortOrder: SortOrder = .name { didSet { refreshVisible() } }

    /// The rows selected in the list. Several rows can be selected only among leftovers of
    /// deleted apps; picking an app or a removed app selects it alone.
    var selection: Set<String> = [] {
        didSet {
            guard selection != oldValue else { return }
            let normalized = Self.normalized(selection, previous: oldValue)
            if normalized != selection { selection = normalized }
        }
    }

    /// The single selected row, or nil when nothing or several rows are selected.
    var selectedID: String? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }

    private static func isOrphanID(_ id: String) -> Bool { id.hasPrefix("orphan:") }

    /// Keeps a multiple selection made of leftovers only. When an app joins several selected
    /// rows, the row just clicked wins; a Select All keeps just the leftovers.
    private static func normalized(_ selection: Set<String>, previous: Set<String>) -> Set<String> {
        guard selection.count > 1, !selection.allSatisfy(isOrphanID) else { return selection }
        let added = selection.subtracting(previous)
        if added.count == 1 { return added }
        let orphans = selection.filter(isOrphanID)
        if !orphans.isEmpty { return orphans }
        return (added.first ?? selection.first).map { [$0] } ?? []
    }

    private(set) var sizes: [String: Int64] = [:]
    /// When each app was last opened, from Spotlight, keyed by bundle path. Missing when
    /// Spotlight doesn't know (never opened, or not indexed).
    private(set) var lastUsed: [String: Date] = [:]
    private(set) var leftovers: [String: AppLeftovers] = [:]
    private(set) var loadingLeftovers: Set<String> = []
    private(set) var checked: [String: Set<String>] = [:]
    /// An app that just disappeared from /Applications (shown as a banner).
    private(set) var justRemoved: RemovedApp?
    var errorMessage: String?

    private let watcher = AppWatcher()
    private let leftoverScanner = LeftoverScanner()
    private let sizeCache = AppSizeCache()
    private var watchTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    private var knownRemovedIDs: Set<String>?
    private var appliedExclusions = ExclusionStore.shared.list
    private var orphanTask: Task<Void, Never>?
    /// The installed apps the last orphan search ran against.
    private var orphanSearchApps: [InstalledApp]?
    /// Orphans the user chose to forget. Persisted.
    private var ignoredOrphans = Set(UserDefaults.standard.stringArray(forKey: UninstallerModel.ignoredOrphansKey) ?? [])

    private static let sensitivityKey = "UninstallerMatchSensitivity"
    private static let ignoredOrphansKey = "UninstallerIgnoredOrphans"
    private static var savedSensitivity: MatchSensitivity {
        UserDefaults.standard.string(forKey: sensitivityKey).flatMap(MatchSensitivity.init(rawValue:)) ?? .strict
    }

    // MARK: Lifecycle

    func start() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            guard let self else { return }
            let cached = await watcher.cached()
            if !cached.apps.isEmpty { apply(cached) }
            for await snapshot in watcher.updates() {
                apply(snapshot)
            }
        }
    }

    func refresh() async {
        apply(await watcher.refresh())
    }

    private func apply(_ snapshot: AppsSnapshot) {
        let newIDs = Set(snapshot.removed.map(\.bundleID))
        if let known = knownRemovedIDs, let fresh = snapshot.removed.first(where: { !known.contains($0.bundleID) }) {
            justRemoved = fresh
        }
        knownRemovedIDs = newIDs
        if snapshot.apps != apps { apps = snapshot.apps }
        if snapshot.removed != removed { removed = snapshot.removed }
        isLoading = false
        // Drop leftovers of apps that changed so they're rescanned when next opened.
        let liveIDs = Set(apps.map { UninstallItem.app($0).id } + removed.map { UninstallItem.removed($0).id }
            + orphans.map { UninstallItem.orphan($0).id })
        leftovers = leftovers.filter { liveIDs.contains($0.key) }
        checked = checked.filter { liveIDs.contains($0.key) }
        if !selection.isSubset(of: liveIDs) { selection.formIntersection(liveIDs) }
        refreshVisible()
        computeSizes()
        loadLastUsedDates()
        findOrphansIfNeeded()
    }

    // MARK: Orphans

    /// Looks for orphans again when the set of installed apps changed since the last search.
    private func findOrphansIfNeeded() {
        guard orphanSearchApps != apps, !apps.isEmpty else { return }
        findOrphans()
    }

    func findOrphans() {
        orphanTask?.cancel()
        orphanSearchApps = apps
        let index = InstalledAppIndex(apps: apps)
        let ignoring = ignoredOrphans.union(removed.map(\.bundleID))
        let finder = OrphanFinder(exclusions: ExclusionStore.shared.list)
        isFindingOrphans = true
        orphanTask = Task { [weak self] in
            let found = await finder.find(installed: index, isKnownApp: Self.isKnownApp, ignoring: ignoring)
            guard !Task.isCancelled, let self else { return }
            orphans = found
            isFindingOrphans = false
            let live = Set(found.map { UninstallItem.orphan($0).id })
            leftovers = leftovers.filter { !$0.key.hasPrefix("orphan:") || live.contains($0.key) }
            let stale = selection.filter { Self.isOrphanID($0) && !live.contains($0) }
            if !stale.isEmpty { selection.subtract(stale) }
            refreshVisible()
        }
    }

    /// Launch Services knows an app with this identifier somewhere (outside the Trash).
    private nonisolated static func isKnownApp(_ bundleID: String) -> Bool {
        let trash = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash") + "/"
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .contains { !$0.path.hasPrefix(trash) && !$0.path.contains("/.Trashes/") }
    }

    /// Hides an orphan for good (until the user clears the list in a future version).
    func ignore(_ orphan: OrphanApp) {
        ignoredOrphans.insert(orphan.bundleID)
        UserDefaults.standard.set(Array(ignoredOrphans).sorted(), forKey: Self.ignoredOrphansKey)
        drop(orphan)
    }

    private func drop(_ orphan: OrphanApp) {
        orphans.removeAll { $0.bundleID == orphan.bundleID }
        let id = UninstallItem.orphan(orphan).id
        leftovers[id] = nil
        checked[id] = nil
        selection.remove(id)
        refreshVisible()
    }

    /// Reads `kMDItemLastUsedDate` for every app off the main thread.
    private func loadLastUsedDates() {
        let paths = apps.filter(\.canUninstall).map(\.path)
        Task { [weak self] in
            let dates = await Self.lastUsedDates(paths)
            guard let self, dates != lastUsed else { return }
            lastUsed = dates
        }
    }

    @concurrent
    private nonisolated static func lastUsedDates(_ paths: [String]) async -> [String: Date] {
        var result: [String: Date] = [:]
        for path in paths {
            guard let item = NSMetadataItem(url: URL(fileURLWithPath: path)),
                  let date = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
            else { continue }
            result[path] = date
        }
        return result
    }

    private func refreshVisible() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        func matches(_ name: String, _ id: String) -> Bool {
            query.isEmpty || name.localizedStandardContains(query) || id.localizedStandardContains(query)
        }
        visibleRemoved = removed.filter { matches($0.name, $0.bundleID) }
        visibleOrphans = orphans.filter { matches($0.bundleID, $0.bundleID) }
        var list = apps.filter { matches($0.name, $0.bundleID) }
        switch sortOrder {
        case .name: break // catalog order is already by name
        case .size: list.sort { (sizes[$0.path] ?? -1) > (sizes[$1.path] ?? -1) }
        case .date: list.sort { $0.modified > $1.modified }
        }
        // System apps can't be removed; keep them at the end.
        visibleApps = list.filter(\.canUninstall) + list.filter { !$0.canUninstall }
    }

    /// Measures bundle sizes in the background, a few at a time, reusing cached values for
    /// unchanged bundles.
    private func computeSizes() {
        sizeTask?.cancel()
        let targets = apps
        sizeTask = Task { [weak self, sizeCache] in
            var pending: [InstalledApp] = []
            for app in targets {
                if let cached = await sizeCache.size(for: app) {
                    self?.setSize(cached, for: app)
                } else {
                    pending.append(app)
                }
            }
            for chunk in stride(from: 0, to: pending.count, by: 6).map({ Array(pending[$0..<min($0 + 6, pending.count)]) }) {
                if Task.isCancelled { return }
                let results = await SizeCalculator.measureAll(chunk.map(\.url), width: 3)
                for (app, result) in zip(chunk, results) {
                    self?.setSize(result.bytes, for: app)
                    await sizeCache.store(result.bytes, for: app)
                }
            }
            await sizeCache.save()
            if self?.sortOrder == .size { self?.refreshVisible() }
        }
    }

    private func setSize(_ bytes: Int64, for app: InstalledApp) {
        if sizes[app.path] != bytes { sizes[app.path] = bytes }
    }

    // MARK: Selection

    var selectedItem: UninstallItem? {
        guard let selectedID else { return nil }
        if let app = apps.first(where: { UninstallItem.app($0).id == selectedID }) { return .app(app) }
        if let gone = removed.first(where: { UninstallItem.removed($0).id == selectedID }) { return .removed(gone) }
        if let orphan = orphans.first(where: { UninstallItem.orphan($0).id == selectedID }) { return .orphan(orphan) }
        return nil
    }

    func showJustRemoved() {
        guard let justRemoved else { return }
        searchText = ""
        selectedID = UninstallItem.removed(justRemoved).id
        self.justRemoved = nil
    }

    func dismissBanner() { justRemoved = nil }

    func loadLeftovers(for item: UninstallItem) async {
        if case .app(let app) = item, !app.canUninstall { return }
        guard leftovers[item.id] == nil, !loadingLeftovers.contains(item.id) else { return }
        loadingLeftovers.insert(item.id)
        let scanned: AppLeftovers
        if case .orphan(let orphan) = item {
            scanned = await leftoverScanner.leftovers(at: orphan.paths, bundleID: orphan.bundleID)
        } else {
            scanned = await leftoverScanner.scan(
                bundleID: item.bundleID, name: item.name, appURL: item.appURL,
                sensitivity: sensitivity, others: InstalledAppIndex(apps: apps, excluding: item.bundleID)
            )
        }
        loadingLeftovers.remove(item.id)
        let result = Self.removingExcluded(scanned, keeping: item.appURL, exclusions: ExclusionStore.shared.list)
        leftovers[item.id] = result
        // An orphan's files are all named after the deleted app, so they all start ticked.
        // Otherwise everything except Supporting Files (may hold the user's own documents) and
        // name-only matches starts ticked.
        if case .orphan = item {
            checked[item.id] = Set(result.allEntries.map(\.path).filter(canRemove))
        } else {
            checked[item.id] = Set(result.groups.filter { !$0.kind.startsUnchecked }.flatMap { $0.entries.map(\.path) })
        }
    }

    /// Leftovers that overlap an excluded folder are never offered. The app bundle itself stays.
    private static func removingExcluded(_ leftovers: AppLeftovers, keeping appURL: URL?, exclusions: ExclusionList) -> AppLeftovers {
        guard !exclusions.isEmpty else { return leftovers }
        let appPath = appURL?.standardizedFileURL.path
        let groups = leftovers.groups.compactMap { group -> LeftoverGroup? in
            let kept = group.entries.filter { $0.path == appPath || !exclusions.overlaps($0.path) }
            return kept.isEmpty ? nil : LeftoverGroup(kind: group.kind, entries: kept)
        }
        return AppLeftovers(bundleID: leftovers.bundleID, groups: groups, deniedPaths: leftovers.deniedPaths)
    }

    /// Re-filters loaded leftovers at once. When folders come off the list, cached leftovers are
    /// dropped (and the selected app's rescanned) so what was hidden comes back.
    func setExclusions(_ exclusions: ExclusionList) {
        let old = appliedExclusions
        appliedExclusions = exclusions
        if old.paths.isSubset(of: exclusions.paths) {
            for (id, current) in leftovers {
                let appURL = apps.first { UninstallItem.app($0).id == id }?.url
                let filtered = Self.removingExcluded(current, keeping: appURL, exclusions: exclusions)
                leftovers[id] = filtered
                checked[id] = checked[id]?.intersection(filtered.allEntries.map(\.path))
            }
        } else {
            for id in leftovers.keys where id != selectedID { leftovers[id] = nil; checked[id] = nil }
            if let item = selectedItem { Task { await rescanLeftovers(for: item) } }
        }
    }

    func rescanLeftovers(for item: UninstallItem) async {
        leftovers[item.id] = nil
        await loadLeftovers(for: item)
    }

    func isChecked(_ entry: FileEntry, in item: UninstallItem) -> Bool {
        checked[item.id]?.contains(entry.path) == true
    }

    func toggle(_ entry: FileEntry, in item: UninstallItem) {
        guard canCheck(entry, in: item) else { return }
        var set = checked[item.id] ?? []
        if set.remove(entry.path) == nil { set.insert(entry.path) }
        checked[item.id] = set
    }

    /// Whether the user can tick this file. Locked files of deleted apps can't be.
    func canCheck(_ entry: FileEntry, in item: UninstallItem) -> Bool {
        if case .orphan = item { canRemove(entry.path) } else { true }
    }

    func state(of group: LeftoverGroup, in item: UninstallItem) -> CheckState {
        let set = checked[item.id] ?? []
        let entries = group.entries.filter { canCheck($0, in: item) }
        let count = entries.count { set.contains($0.path) }
        return count == 0 ? .off : (count == entries.count ? .on : .mixed)
    }

    func toggle(_ group: LeftoverGroup, in item: UninstallItem) {
        var set = checked[item.id] ?? []
        let paths = group.entries.filter { canCheck($0, in: item) }.map(\.path)
        if state(of: group, in: item) == .on { set.subtract(paths) } else { set.formUnion(paths) }
        checked[item.id] = set
    }

    func checkedEntries(for item: UninstallItem) -> [FileEntry] {
        let set = checked[item.id] ?? []
        return leftovers[item.id]?.allEntries.filter { set.contains($0.path) } ?? []
    }

    func removesApp(_ item: UninstallItem) -> Bool {
        guard let url = item.appURL else { return false }
        return checked[item.id]?.contains(url.standardizedFileURL.path) == true
    }

    func isRunning(_ item: UninstallItem) -> Bool {
        guard case .app(let app) = item, app.hasRealBundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    // MARK: Leftovers of deleted apps, together

    /// The selected leftovers of deleted apps, in list order.
    var selectedOrphans: [OrphanApp] {
        orphans.filter { selection.contains(UninstallItem.orphan($0).id) }
    }

    /// Selects every leftover that can be removed now, small ones included.
    func selectAllOrphans() {
        selection = Set(visibleOrphans.filter { !isLocked($0) }.map { UninstallItem.orphan($0).id })
    }

    /// Visible leftovers that can be removed now, at least ``smallOrphanLimit`` in size.
    var largeOrphans: [OrphanApp] {
        visibleOrphans.filter { !isLocked($0) && $0.bytes >= Self.smallOrphanLimit }
    }

    /// Visible leftovers that can be removed now, below ``smallOrphanLimit``.
    var smallOrphans: [OrphanApp] {
        visibleOrphans.filter { !isLocked($0) && $0.bytes < Self.smallOrphanLimit }
    }

    /// Visible leftovers with files macOS won't let us move.
    var lockedOrphans: [OrphanApp] { visibleOrphans.filter(isLocked) }

    /// Inside another app's sandbox container, which macOS protects unless the app has Full
    /// Disk Access.
    nonisolated static func isProtectedContainer(_ path: String) -> Bool {
        let library = (NSHomeDirectory() as NSString).appendingPathComponent("Library")
        return ["Containers", "Group Containers"].contains {
            path.hasPrefix((library as NSString).appendingPathComponent($0) + "/")
        }
    }

    /// Whether a leftover file of a deleted app can be moved to the Trash right now.
    func canRemove(_ path: String) -> Bool {
        !blockedPaths.contains(path) && (hasFullDiskAccess || !Self.isProtectedContainer(path))
    }

    /// Some of the leftover's files can't be removed right now.
    func isLocked(_ orphan: OrphanApp) -> Bool {
        !orphan.paths.allSatisfy(canRemove)
    }

    /// What removing `orphan` together with others moves: the ticked files when it was opened,
    /// otherwise every file that can be removed.
    func pathsToRemove(_ orphan: OrphanApp) -> (paths: [String], bytes: Int64) {
        let item = UninstallItem.orphan(orphan)
        guard leftovers[item.id] != nil else {
            let paths = orphan.paths.filter(canRemove)
            // Per-file sizes come with the scan (started by the pane); until then, estimate.
            return (paths, paths.isEmpty ? 0 : orphan.bytes)
        }
        let entries = checkedEntries(for: item).filter { canRemove($0.path) }
        return (entries.map(\.path), entries.reduce(0) { $0 + $1.sizeBytes })
    }

    /// Records files macOS refused to move so their leftovers show as locked.
    private func noteFailures(_ summary: CleanSummary) {
        let failed = summary.failures.map(\.path)
        if !failed.isEmpty { blockedPaths.formUnion(failed) }
    }

    func orphansRequest(for targets: [OrphanApp]) -> TrashCoordinator.Request? {
        let parts = targets.map(pathsToRemove)
        let paths = parts.flatMap(\.paths)
        guard !paths.isEmpty else { return nil }
        let bytes = parts.reduce(0) { $0 + $1.bytes }
        let size = bytes.formatted(.byteCount(style: .file))
        let apps = targets.count { !pathsToRemove($0).paths.isEmpty }
        return TrashCoordinator.Request(
            paths: paths,
            title: "Move leftovers of \(apps) deleted \(apps == 1 ? "app" : "apps") (\(size)) to the Trash?",
            message: "\(paths.count) \(paths.count == 1 ? "item" : "items") will move to the Trash. You can restore them from the Trash until you empty it.",
            confirmTitle: "Move to Trash",
            bytes: bytes,
            onFinish: { [weak self] summary in
                self?.finishOrphans(targets, summary: summary)
            }
        )
    }

    private func finishOrphans(_ targets: [OrphanApp], summary: CleanSummary) {
        noteFailures(summary)
        let gone = summary.trashedPaths
        var anyLeft = false
        for orphan in targets {
            if orphan.paths.allSatisfy(gone.contains) {
                drop(orphan)
            } else if orphan.paths.contains(where: gone.contains) {
                let id = UninstallItem.orphan(orphan).id
                leftovers[id] = nil
                checked[id] = nil
                anyLeft = true
            }
        }
        // Sizes and item counts of partly removed leftovers are stale; look again.
        if anyLeft { findOrphans() }
    }

    // MARK: Uninstall

    func uninstallRequest(for item: UninstallItem) -> TrashCoordinator.Request? {
        let entries = checkedEntries(for: item)
        guard !entries.isEmpty else { return nil }
        let bytes = entries.reduce(0) { $0 + $1.sizeBytes }
        let size = bytes.formatted(.byteCount(style: .file))
        let includesApp = removesApp(item)
        let related = entries.count - (includesApp ? 1 : 0)
        let running = includesApp && isRunning(item)

        let title: String
        if includesApp {
            title = related > 0
                ? "Move \(item.name) and \(related) related \(related == 1 ? "item" : "items") (\(size)) to the Trash?"
                : "Move \(item.name) (\(size)) to the Trash?"
        } else {
            title = "Move \(entries.count) \(entries.count == 1 ? "leftover" : "leftovers") of \(item.name) (\(size)) to the Trash?"
        }
        var message = "You can restore them from the Trash until you empty it."
        if running { message = "\(item.name) is open. It will be quit first.\n\n" + message }

        let appPath = item.appURL?.path
        let bundleID = item.bundleID
        let watcher = watcher
        return TrashCoordinator.Request(
            paths: entries.map(\.path),
            title: title,
            message: message,
            confirmTitle: includesApp ? "Uninstall" : "Move to Trash",
            bytes: bytes,
            prepare: { [weak self] in
                if running, await Self.quit(bundleID: bundleID) == false {
                    self?.errorMessage = "\(item.name) didn't quit. Quit it yourself, then try again."
                    return false
                }
                // We're removing it on purpose; don't list it under "Recently Removed".
                if includesApp, let appPath { await watcher.markHandled(path: appPath) }
                return true
            },
            onFinish: { [weak self] summary in
                Task { await self?.finishUninstall(item, summary: summary) }
            }
        )
    }

    private func finishUninstall(_ item: UninstallItem, summary: CleanSummary) async {
        if case .orphan = item {
            noteFailures(summary)
            checked[item.id]?.subtract(summary.failures.map(\.path))
        }
        let gone = summary.trashedPaths
        if let current = leftovers[item.id] {
            let groups = current.groups.compactMap { group -> LeftoverGroup? in
                let kept = group.entries.filter { !gone.contains($0.path) }
                return kept.isEmpty ? nil : LeftoverGroup(kind: group.kind, entries: kept)
            }
            leftovers[item.id] = AppLeftovers(bundleID: current.bundleID, groups: groups, deniedPaths: current.deniedPaths)
            checked[item.id]?.subtract(gone)
            if case .removed(let gone) = item, groups.isEmpty {
                apply(await watcher.dismiss(bundleID: gone.bundleID))
            }
            if case .orphan(let orphan) = item, groups.isEmpty {
                drop(orphan)
            }
        }
        if removesApp(item) || item.appURL.map({ gone.contains($0.path) }) == true {
            await refresh()
        }
    }

    func dismiss(_ removedApp: RemovedApp) async {
        apply(await watcher.dismiss(bundleID: removedApp.bundleID))
    }

    /// Politely asks the app to quit, waiting up to 10 seconds.
    private static func quit(bundleID: String) async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        running.forEach { $0.terminate() }
        for _ in 0..<40 {
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return running.allSatisfy(\.isTerminated)
    }
}

/// Remembers bundle sizes by (path, modification date) so they're only measured once per version.
actor AppSizeCache {
    private struct Record: Codable {
        let modified: Date
        let bytes: Int64
    }

    private var records: [String: Record]
    private var dirty = false
    private let url: URL?

    init() {
        url = AppWatcher.defaultCacheURL?.deletingLastPathComponent().appendingPathComponent("app_sizes.json")
        records = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }

    func size(for app: InstalledApp) -> Int64? {
        guard let record = records[app.path], abs(record.modified.timeIntervalSince(app.modified)) < 1 else { return nil }
        return record.bytes
    }

    func store(_ bytes: Int64, for app: InstalledApp) {
        records[app.path] = Record(modified: app.modified, bytes: bytes)
        dirty = true
    }

    func save() {
        guard dirty, let url, let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        dirty = false
    }
}
