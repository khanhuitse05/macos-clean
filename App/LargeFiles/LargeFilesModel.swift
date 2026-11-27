import MacosCleanCore
import SwiftUI
import UniformTypeIdentifiers

/// A large file as shown in the table, with display strings computed once.
struct LargeFileRow: Identifiable, Hashable, Sendable {
    let entry: FileEntry
    let name: String
    let kind: String
    let location: String

    init(_ entry: FileEntry) {
        self.entry = entry
        name = entry.name
        let ext = (entry.path as NSString).pathExtension
        kind = UTType(filenameExtension: ext)?.localizedDescription ?? (ext.isEmpty ? "Document" : ext.uppercased() + " file")
        location = entry.parentPath.abbreviatingHome
    }

    var id: String { entry.path }
    var sizeBytes: Int64 { entry.sizeBytes }
    var modified: Date { entry.modified ?? .distantPast }
}

@MainActor
@Observable
final class LargeFilesModel {
    static let thresholds: [Int] = [50, 100, 250, 500, 1_000, 5_000]
    /// Keep the largest files only; a home folder can have thousands above 50 MB.
    static let maxShown = 1_000

    var root: URL = URL(fileURLWithPath: NSHomeDirectory())
    var minimumMB: Int = {
        let stored = UserDefaults.standard.integer(forKey: "largeFilesMinimumMB")
        return stored > 0 ? stored : 100
    }() {
        didSet { UserDefaults.standard.set(minimumMB, forKey: "largeFilesMinimumMB") }
    }
    var searchText = "" { didSet { refreshVisible() } }
    var sortOrder: [KeyPathComparator<LargeFileRow>] = [KeyPathComparator(\.sizeBytes, order: .reverse)] {
        didSet { allRows.sort(using: sortOrder); refreshVisible() }
    }

    private(set) var visibleRows: [LargeFileRow] = []
    private(set) var isScanning = false
    /// Rescanning in the background while the saved or earlier results stay on screen.
    private(set) var isRefreshing = false
    private(set) var hasScanned = false
    /// When the results on screen were found; set for finished scans and restored results.
    private(set) var scannedAt: Date?
    private(set) var scannedCount = 0
    private(set) var deniedPaths: [String] = []
    private(set) var totalBytes: Int64 = 0

    private(set) var checked: Set<String> = [] { didSet { recomputeChecked() } }
    private(set) var checkedBytes: Int64 = 0

    private var allRows: [LargeFileRow] = []
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    @ObservationIgnored private var didAppear = false
    /// The folder and size the rows on screen were found with; nil while a scan replaces them.
    @ObservationIgnored private var resultsScope: Scope?

    struct Scope: Equatable {
        let root: String
        let minimumMB: Int
    }
    @ObservationIgnored private let store = SavedResults<Saved>(fileName: "large_files.json")

    /// The last finished scan, kept between launches.
    struct Saved: Codable, Sendable {
        var version = 1
        var root: String
        var minimumMB: Int
        var scannedAt: Date
        var files: [FileEntry]
        var deniedPaths: [String]
    }

    var rootDisplayName: String {
        root.path == NSHomeDirectory() ? "Home" : root.lastPathComponent
    }

    /// First visit this launch: shows the saved results and refreshes them in the
    /// background, or scans when there are none.
    func appear() async {
        if !didAppear {
            didAppear = true
            if !hasScanned, await restore() {
                refresh()
                return
            }
        }
        if !hasScanned { scan() }
    }

    func scan() {
        stop()
        allRows = []
        checked = []
        deniedPaths = []
        scannedCount = 0
        scannedAt = nil
        resultsScope = nil
        isScanning = true
        hasScanned = true
        refreshVisible()
        run(refreshing: false)
    }

    /// Rescans while the current rows stay on screen, then swaps in the new ones at once.
    func refresh() {
        stop()
        scannedCount = 0
        isRefreshing = true
        run(refreshing: true)
    }

    private func run(refreshing: Bool) {
        let scanner = LargeFileScanner(
            root: root, minimumBytes: Int64(minimumMB) * 1_024 * 1_024, exclusions: ExclusionStore.shared.list
        )
        let scope = Scope(root: root.path, minimumMB: minimumMB)
        scanGeneration += 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            var fresh: [FileEntry] = []
            var denied: [String] = []
            for await event in scanner.scan(priority: refreshing ? .utility : .userInitiated) {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .found(let batch):
                    if refreshing { fresh += batch } else { insert(batch) }
                case .progress(let scanned): scannedCount = scanned
                case .denied(let path):
                    if refreshing { denied.append(path) } else { deniedPaths.append(path) }
                case .finished:
                    if refreshing { replaceRows(with: fresh, denied: denied) }
                    scannedAt = Date()
                    resultsScope = scope
                    save()
                }
            }
            // A newer scan may have replaced this one; only the current scan ends the spinner.
            if let self, generation == scanGeneration {
                isScanning = false
                isRefreshing = false
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        isRefreshing = false
    }

    private func replaceRows(with files: [FileEntry], denied: [String]) {
        var rows = files.map(LargeFileRow.init)
        if rows.count > Self.maxShown {
            rows.sort { $0.sizeBytes > $1.sizeBytes }
            rows.removeLast(rows.count - Self.maxShown)
        }
        rows.sort(using: sortOrder)
        Motion.animate {
            allRows = rows
            deniedPaths = denied
            checked = checked.intersection(rows.map(\.id))
            refreshVisible()
        }
    }

    // MARK: Saved results

    /// Shows the last launch's results for the same folder and size, minus files that are gone,
    /// changed or now excluded. Returns false when there was nothing to show.
    private func restore() async -> Bool {
        guard let saved = await store.load(), saved.version == 1,
              saved.root == root.path, saved.minimumMB == minimumMB
        else { return false }
        let exclusions = ExclusionStore.shared.list.applying(toRoot: root.standardizedFileURL.path)
        let minimum = Int64(minimumMB) * 1_024 * 1_024
        let files = await Self.stillPresent(saved.files, exclusions: exclusions, minimumBytes: minimum)
        guard !hasScanned else { return false }
        allRows = files.map(LargeFileRow.init).sorted(using: sortOrder)
        deniedPaths = saved.deniedPaths
        scannedAt = saved.scannedAt
        resultsScope = Scope(root: saved.root, minimumMB: saved.minimumMB)
        hasScanned = true
        refreshVisible()
        return true
    }

    @concurrent
    private static func stillPresent(_ files: [FileEntry], exclusions: ExclusionList, minimumBytes: Int64) async -> [FileEntry] {
        files.compactMap { file in
            guard !exclusions.isExcluded(file.path), let stamp = FileStamp(path: file.path),
                  stamp.allocatedBytes >= minimumBytes
            else { return nil }
            return FileEntry(path: file.path, sizeBytes: stamp.allocatedBytes, isDirectory: false, modified: stamp.modified)
        }
    }

    /// Saves the rows on screen, once a scan has finished (never a partial one).
    private func save() {
        guard let scannedAt, let resultsScope else { return }
        let saved = Saved(
            root: resultsScope.root, minimumMB: resultsScope.minimumMB, scannedAt: scannedAt,
            files: allRows.map(\.entry), deniedPaths: deniedPaths
        )
        Task { await store.save(saved) }
    }

    private func insert(_ batch: [FileEntry]) {
        allRows += batch.map(LargeFileRow.init)
        if allRows.count > Self.maxShown {
            allRows.sort { $0.sizeBytes > $1.sizeBytes }
            allRows.removeLast(allRows.count - Self.maxShown)
        }
        allRows.sort(using: sortOrder)
        refreshVisible()
    }

    private func refreshVisible() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        visibleRows = query.isEmpty ? allRows : allRows.filter {
            $0.name.localizedStandardContains(query) || $0.location.localizedStandardContains(query)
        }
        totalBytes = allRows.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Drops files inside folders the user just excluded (the chosen root itself never counts).
    func setExclusions(_ exclusions: ExclusionList) {
        let effective = exclusions.applying(toRoot: root.standardizedFileURL.path)
        guard !effective.isEmpty else { return }
        let hidden = Set(allRows.lazy.filter { effective.isExcluded($0.id) }.map(\.id))
        guard !hidden.isEmpty else { return }
        Motion.animate {
            allRows.removeAll { hidden.contains($0.id) }
            checked.subtract(hidden)
            refreshVisible()
        }
        save()
    }

    // MARK: Selection

    func isChecked(_ row: LargeFileRow) -> Bool { checked.contains(row.id) }

    func setChecked(_ row: LargeFileRow, _ value: Bool) {
        if value { checked.insert(row.id) } else { checked.remove(row.id) }
    }

    func checkVisible() { checked.formUnion(visibleRows.map(\.id)) }
    func uncheckAll() { checked.removeAll() }

    private func recomputeChecked() {
        let sizes = Dictionary(allRows.map { ($0.id, $0.sizeBytes) }, uniquingKeysWith: { first, _ in first })
        checkedBytes = checked.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    // MARK: Trash

    func trashRequest(for ids: Set<String>? = nil) -> TrashCoordinator.Request? {
        let target = ids ?? checked
        let rows = allRows.filter { target.contains($0.id) }
        guard !rows.isEmpty else { return nil }
        let finish: @MainActor (CleanSummary) -> Void = { [weak self] summary in self?.removeTrashed(summary) }
        if rows.count == 1 { return .single(rows[0].entry, onFinish: finish) }
        return .items(rows.map(\.id), bytes: rows.reduce(0) { $0 + $1.sizeBytes },
                      noun: "files", onFinish: finish)
    }

    private func removeTrashed(_ summary: CleanSummary) {
        let gone = summary.trashedPaths
        allRows.removeAll { gone.contains($0.id) }
        checked.subtract(gone)
        refreshVisible()
        save()
    }
}
