import AppKit
import MacosCleanCore
import SwiftUI

/// Something shown in the Uninstaller list: an installed app, or one removed outside macos-clean
/// whose leftovers can still be cleaned up.
enum UninstallItem: Hashable, Identifiable {
    case app(InstalledApp)
    case removed(RemovedApp)

    var id: String {
        switch self {
        case .app(let app): "app:" + app.path
        case .removed(let removed): "removed:" + removed.bundleID
        }
    }

    var name: String {
        switch self {
        case .app(let app): app.name
        case .removed(let removed): removed.name
        }
    }

    var bundleID: String {
        switch self {
        case .app(let app): app.bundleID
        case .removed(let removed): removed.bundleID
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

    var searchText = "" { didSet { refreshVisible() } }
    var sortOrder: SortOrder = .name { didSet { refreshVisible() } }
    var selectedID: String?

    private(set) var sizes: [String: Int64] = [:]
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
        let liveIDs = Set(apps.map { UninstallItem.app($0).id } + removed.map { UninstallItem.removed($0).id })
        leftovers = leftovers.filter { liveIDs.contains($0.key) }
        checked = checked.filter { liveIDs.contains($0.key) }
        if let selectedID, !liveIDs.contains(selectedID) { self.selectedID = nil }
        refreshVisible()
        computeSizes()
    }

    private func refreshVisible() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        func matches(_ name: String, _ id: String) -> Bool {
            query.isEmpty || name.localizedStandardContains(query) || id.localizedStandardContains(query)
        }
        visibleRemoved = removed.filter { matches($0.name, $0.bundleID) }
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
        let result = await leftoverScanner.scan(bundleID: item.bundleID, name: item.name, appURL: item.appURL)
        loadingLeftovers.remove(item.id)
        leftovers[item.id] = result
        // Everything except Supporting Files (may hold the user's own documents) starts ticked.
        checked[item.id] = Set(result.groups.filter { !$0.kind.mayContainUserData }.flatMap { $0.entries.map(\.path) })
    }

    func rescanLeftovers(for item: UninstallItem) async {
        leftovers[item.id] = nil
        await loadLeftovers(for: item)
    }

    func isChecked(_ entry: FileEntry, in item: UninstallItem) -> Bool {
        checked[item.id]?.contains(entry.path) == true
    }

    func toggle(_ entry: FileEntry, in item: UninstallItem) {
        var set = checked[item.id] ?? []
        if set.remove(entry.path) == nil { set.insert(entry.path) }
        checked[item.id] = set
    }

    func state(of group: LeftoverGroup, in item: UninstallItem) -> CheckState {
        let set = checked[item.id] ?? []
        let count = group.entries.count { set.contains($0.path) }
        return count == 0 ? .off : (count == group.entries.count ? .on : .mixed)
    }

    func toggle(_ group: LeftoverGroup, in item: UninstallItem) {
        var set = checked[item.id] ?? []
        let paths = group.entries.map(\.path)
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
