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
    private(set) var hasScanned = false
    private(set) var scannedCount = 0
    private(set) var deniedPaths: [String] = []
    private(set) var totalBytes: Int64 = 0

    private(set) var checked: Set<String> = [] { didSet { recomputeChecked() } }
    private(set) var checkedBytes: Int64 = 0

    private var allRows: [LargeFileRow] = []
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    var rootDisplayName: String {
        root.path == NSHomeDirectory() ? "Home" : root.lastPathComponent
    }

    func scan() {
        stop()
        allRows = []
        checked = []
        deniedPaths = []
        scannedCount = 0
        isScanning = true
        hasScanned = true
        refreshVisible()

        let scanner = LargeFileScanner(root: root, minimumBytes: Int64(minimumMB) * 1_024 * 1_024)
        scanGeneration += 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            for await event in scanner.scan() {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .found(let batch): insert(batch)
                case .progress(let scanned): scannedCount = scanned
                case .denied(let path): deniedPaths.append(path)
                case .finished: break
                }
            }
            // A newer scan may have replaced this one; only the current scan ends the spinner.
            if let self, generation == scanGeneration { isScanning = false }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
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
    }
}
