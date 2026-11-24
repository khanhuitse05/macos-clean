import MacosCleanCore
import SwiftUI

/// State of the File Browser: a chain of columns (Finder column view) where each column lists a
/// folder's children with their sizes, largest first.
@MainActor
@Observable
final class FileBrowserModel {
    /// What's known about one folder. A folder with no entry here hasn't been listed yet.
    struct FolderState: Equatable {
        var entries: [FileEntry]
        /// False while subfolder sizes are still being measured.
        var isMeasured: Bool
        var isDenied: Bool
    }

    var root: URL = URL(fileURLWithPath: NSHomeDirectory()) {
        didSet {
            guard root != oldValue else { return }
            columns = [root.path]
            selected = []
            cancelLoads(keeping: [])
            ensureLoaded(root.path)
        }
    }

    var showHidden: Bool = UserDefaults.standard.bool(forKey: "fileBrowserShowHidden") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "fileBrowserShowHidden") }
    }

    /// Folder shown in each column. `columns[0]` is the root.
    private(set) var columns: [String] = [NSHomeDirectory()]
    /// The selected item in each column; `selected[i]` lives in `columns[i]`.
    /// When it's a folder, `columns[i + 1]` shows its contents.
    private(set) var selected: [String] = []
    private(set) var folders: [String: FolderState] = [:]
    private(set) var deniedPaths: Set<String> = []

    private var loadTasks: [String: Task<Void, Never>] = [:]
    private let scanner = CategoryScanner()

    // MARK: Queries

    var isHome: Bool { root.path == NSHomeDirectory() }
    var rootDisplayName: String { isHome ? "Home" : root.lastPathComponent }

    func state(of folder: String) -> FolderState? { folders[folder] }

    func entries(in folder: String) -> [FileEntry] {
        guard let entries = folders[folder]?.entries else { return [] }
        return showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    func selection(inColumn index: Int) -> String? {
        selected.indices.contains(index) ? selected[index] : nil
    }

    /// The deepest selected item, if any.
    var selectedEntry: FileEntry? {
        guard let path = selected.last else { return nil }
        return entry(at: path)
    }

    /// Total of the root folder, once every child has been measured.
    var rootBytes: Int64? {
        guard let state = folders[root.path], state.isMeasured else { return nil }
        return state.entries.totalBytes
    }

    func isMeasuring(_ entry: FileEntry) -> Bool { entry.sizeBytes == CategoryScanner.unmeasured }

    private func entry(at path: String) -> FileEntry? {
        let parent = (path as NSString).deletingLastPathComponent
        return folders[parent]?.entries.first { $0.path == path }
    }

    // MARK: Navigation

    func start() { ensureLoaded(root.path) }

    /// Selects `path` in column `index`; a folder opens a new column to its right.
    func select(_ path: String?, inColumn index: Int) {
        guard columns.indices.contains(index) else { return }
        guard let path, let entry = entry(at: path) else {
            selected = Array(selected.prefix(index))
            columns = Array(columns.prefix(index + 1))
            cancelLoads(keeping: Set(columns))
            return
        }
        guard selection(inColumn: index) != path else { return }
        selected = Array(selected.prefix(index)) + [path]
        columns = Array(columns.prefix(index + 1)) + (entry.isDirectory ? [path] : [])
        cancelLoads(keeping: Set(columns))
        if entry.isDirectory { ensureLoaded(path) }
    }

    /// Selects the first item in the column after `index`. Returns false when there's nothing to enter.
    @discardableResult
    func enterColumn(after index: Int) -> Bool {
        let next = index + 1
        guard columns.indices.contains(next), let first = entries(in: columns[next]).first else { return false }
        select(selection(inColumn: next) ?? first.path, inColumn: next)
        return true
    }

    /// Clears the selection in column `index` so focus can move back to its parent.
    func leaveColumn(_ index: Int) {
        guard index > 0 else { return }
        select(nil, inColumn: index)
    }

    /// Forgets every listing and reloads the open columns.
    func reload() {
        cancelLoads(keeping: [])
        folders = [:]
        deniedPaths = []
        for folder in columns { ensureLoaded(folder) }
    }

    // MARK: Loading

    private func ensureLoaded(_ folder: String) {
        if let state = folders[folder], state.isMeasured || state.isDenied { return }
        guard loadTasks[folder] == nil else { return }
        loadTasks[folder] = Task { [weak self] in
            await self?.load(folder)
        }
    }

    /// Lists names first so the column appears at once, then measures subfolders.
    private func load(_ folder: String) async {
        defer { loadTasks[folder] = nil }
        let url = URL(fileURLWithPath: folder)
        if folders[folder] == nil {
            let shallow = await scanner.shallowList(url)
            guard !Task.isCancelled else { return }
            folders[folder] = FolderState(entries: shallow.entries, isMeasured: false, isDenied: !shallow.deniedPaths.isEmpty)
            deniedPaths.formUnion(shallow.deniedPaths)
            if !shallow.deniedPaths.isEmpty { return }
        }
        let measured = await scanner.list(url)
        // A cancelled walk stops early, so its sizes are too small; keep the unmeasured listing.
        guard !Task.isCancelled else { return }
        folders[folder] = FolderState(entries: measured.entries, isMeasured: true, isDenied: false)
        deniedPaths.formUnion(measured.deniedPaths)
    }

    private func cancelLoads(keeping folders: Set<String>) {
        for (folder, task) in loadTasks where !folders.contains(folder) {
            task.cancel()
            loadTasks[folder] = nil
        }
    }

    // MARK: Trash

    func trashRequest(for entry: FileEntry) -> TrashCoordinator.Request {
        let finish: @MainActor (CleanSummary) -> Void = { [weak self] summary in self?.removeTrashed(summary) }
        guard isMeasuring(entry) else { return .single(entry, onFinish: finish) }
        return .init(
            paths: [entry.path],
            title: "Move “\(entry.name)” to the Trash?",
            message: "You can restore it from the Trash until you empty it.",
            confirmTitle: "Move to Trash",
            onFinish: finish
        )
    }

    /// Updates listings locally after a clean, without rescanning.
    private func removeTrashed(_ summary: CleanSummary) {
        let removed = summary.outcomes.filter(\.success)
        guard !removed.isEmpty else { return }
        let removedPaths = Set(removed.map(\.path))

        func isGone(_ path: String) -> Bool {
            removedPaths.contains(path) || removedPaths.contains { path.hasPrefix($0 + "/") }
        }
        func shrink(_ entry: FileEntry) -> FileEntry {
            guard !isMeasuring(entry) else { return entry }
            let freed = removed.filter { $0.path.hasPrefix(entry.path + "/") }.reduce(0) { $0 + $1.bytes }
            guard freed > 0 else { return entry }
            return FileEntry(path: entry.path, sizeBytes: max(0, entry.sizeBytes - freed),
                             isDirectory: entry.isDirectory, modified: entry.modified)
        }

        for (folder, var state) in folders {
            if isGone(folder) { folders[folder] = nil; continue }
            state.entries = state.entries.filter { !isGone($0.path) }.map(shrink)
            if state.isMeasured { state.entries = state.entries.sortedBySizeDescending() }
            folders[folder] = state
        }
        if let cut = selected.firstIndex(where: isGone) {
            selected = Array(selected.prefix(cut))
            columns = Array(columns.prefix(cut + 1))
            cancelLoads(keeping: Set(columns))
        }
    }
}
