import Darwin
import Foundation

public struct CategoryScanResult: Sendable, Equatable, Codable {
    public let categoryID: String
    /// Deletable units, largest first.
    public let entries: [FileEntry]
    /// Locations macOS refused to open (needs Full Disk Access).
    public let deniedPaths: [String]
    public let scannedAt: Date
    /// Children of folders inside the entries, collected while measuring them, so expanding a
    /// folder needs no new walk. Keyed by folder path, largest first. Not persisted.
    public let prefetched: [String: [FileEntry]]
    /// For the simulators category: what each entry is (keyed the same as `entries`).
    public let simulators: [SimulatorItem]

    public var totalBytes: Int64 { entries.totalBytes }

    public init(
        categoryID: String, entries: [FileEntry], deniedPaths: [String], scannedAt: Date = .now,
        prefetched: [String: [FileEntry]] = [:], simulators: [SimulatorItem] = []
    ) {
        self.categoryID = categoryID
        self.entries = entries
        self.deniedPaths = deniedPaths
        self.scannedAt = scannedAt
        self.prefetched = prefetched
        self.simulators = simulators
    }

    private enum CodingKeys: String, CodingKey {
        case categoryID, entries, deniedPaths, scannedAt, simulators
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            categoryID: try container.decode(String.self, forKey: .categoryID),
            entries: try container.decode([FileEntry].self, forKey: .entries),
            deniedPaths: try container.decode([String].self, forKey: .deniedPaths),
            scannedAt: try container.decode(Date.self, forKey: .scannedAt),
            simulators: try container.decodeIfPresent([SimulatorItem].self, forKey: .simulators) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(entries, forKey: .entries)
        try container.encode(deniedPaths, forKey: .deniedPaths)
        try container.encode(scannedAt, forKey: .scannedAt)
        if !simulators.isEmpty { try container.encode(simulators, forKey: .simulators) }
    }

    /// The same result with only `entries` kept (and their simulator items).
    public func keeping(_ entries: [FileEntry]) -> CategoryScanResult {
        let paths = Set(entries.map(\.path))
        return CategoryScanResult(
            categoryID: categoryID, entries: entries, deniedPaths: deniedPaths, scannedAt: scannedAt,
            simulators: simulators.filter { paths.contains($0.path) }
        )
    }
}

public struct FolderListing: Sendable, Equatable {
    public let entries: [FileEntry]
    public let deniedPaths: [String]
    /// Children of subfolders, collected during the same walk (see ``CategoryScanner/prefetchDepth``).
    public let prefetched: [String: [FileEntry]]

    public init(entries: [FileEntry], deniedPaths: [String], prefetched: [String: [FileEntry]] = [:]) {
        self.entries = entries
        self.deniedPaths = deniedPaths
        self.prefetched = prefetched
    }
}

/// Scans Storage Manager categories.
public struct CategoryScanner: Sendable {
    /// How many levels below each measured item get their listings prefetched. 2 means a
    /// folder and its subfolders can be expanded instantly.
    public static let prefetchDepth = 2

    public let expander: PathExpander
    public let database: JunkDatabase
    /// Folders never scanned or suggested. Entries that overlap one are dropped.
    public let exclusions: ExclusionList
    public let simulatorInventory: SimulatorInventory

    public init(
        expander: PathExpander = PathExpander(), database: JunkDatabase = .bundled, exclusions: ExclusionList = .empty,
        simulatorInventory: SimulatorInventory = SimulatorInventory()
    ) {
        self.expander = expander
        self.database = database
        self.exclusions = exclusions
        self.simulatorInventory = simulatorInventory
    }

    /// - Parameter progress: receives running totals while the scan measures.
    @concurrent
    public func scan(_ category: CleanupCategory, progress: ScanProgress? = nil) async -> CategoryScanResult {
        switch category.source {
        case .devProjects:
            let found = await DevProjectScanner(root: URL(fileURLWithPath: expander.home), exclusions: exclusions)
                .scanDetailed(progress: progress)
            return CategoryScanResult(
                categoryID: category.id, entries: exclusions.filter(found.entries), deniedPaths: [], prefetched: found.listings
            )

        case .simulators:
            let items = await simulatorInventory.list().filter { !exclusions.overlaps($0.path) }
            progress?.add(bytes: items.reduce(0) { $0 + $1.sizeBytes }, files: items.count)
            return CategoryScanResult(
                categoryID: category.id, entries: items.map(\.entry), deniedPaths: [], simulators: items
            )

        case .appCaches:
            let urls = database.safeCacheEntries(expander: expander).filter { !exclusions.overlaps($0.path) }
            let measured = await measure(urls, progress: progress)
            return CategoryScanResult(
                categoryID: category.id,
                entries: measured.entries.filter { $0.sizeBytes > 0 }.sortedBySizeDescending(),
                deniedPaths: measured.deniedPaths,
                prefetched: measured.prefetched
            )

        case .paths(let rawPaths):
            var entries: [FileEntry] = []
            var denied: [String] = []
            var prefetched: [String: [FileEntry]] = [:]
            for raw in rawPaths {
                guard !Task.isCancelled else { break }
                let root = expander.expand(raw)
                // An excluded root (or one inside an excluded folder) isn't walked at all.
                guard !exclusions.isExcluded(root.standardizedFileURL.path) else { continue }
                let listing = await list(root, progress: progress)
                entries += exclusions.filter(listing.entries)
                denied += listing.deniedPaths
                prefetched.merge(listing.prefetched) { $1 }
            }
            return CategoryScanResult(categoryID: category.id, entries: entries, deniedPaths: denied, prefetched: prefetched)
        }
    }

    /// The children of a folder with their sizes, largest first. A file root returns itself.
    /// Files take their size from the listing; only subfolders are walked.
    @concurrent
    public func list(_ root: URL, progress: ScanProgress? = nil) async -> FolderListing {
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            // Missing is normal (tool not installed); "not permitted" means macOS blocked us.
            return FolderListing(entries: [], deniedPaths: AccessCheck.isPermissionErrno(errno) ? [root.path] : [])
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return await measure([root], progress: progress)
        }
        let listing = DirectoryWalker.children(of: root.path)
        if let error = listing.error {
            return FolderListing(entries: [], deniedPaths: AccessCheck.isPermissionErrno(error) ? [root.path] : [])
        }
        let folders = listing.children.filter { $0.kind == .directory }
        let looseFiles = listing.children.filter { $0.kind != .directory }
        progress?.add(bytes: looseFiles.reduce(0) { $0 + $1.allocatedSize }, files: looseFiles.count)
        let sizes = await SizeCalculator.measureAll(
            folders.map { URL(fileURLWithPath: $0.path) }, listingDepth: Self.prefetchDepth, progress: progress
        )
        var denied: [String] = []
        var prefetched: [String: [FileEntry]] = [:]
        var folderBytes: [String: Int64] = [:]
        for (folder, size) in zip(folders, sizes) {
            folderBytes[folder.path] = size.bytes
            denied += size.deniedPaths
            prefetched.merge(size.listings) { $1 }
        }
        let entries = listing.children.map { child in
            FileEntry(
                path: child.path,
                sizeBytes: child.kind == .directory ? folderBytes[child.path] ?? 0 : child.allocatedSize,
                isDirectory: child.kind == .directory,
                modified: child.modified
            )
        }
        return FolderListing(entries: entries.sortedBySizeDescending(), deniedPaths: denied, prefetched: prefetched)
    }

    /// Size of a folder that ``shallowList(_:)`` hasn't measured yet.
    public static let unmeasured: Int64 = -1

    /// The children of a folder without walking subfolders, so it returns at once. Files carry
    /// their own allocated size; folders carry ``unmeasured``. Folders first, then by name.
    @concurrent
    public func shallowList(_ root: URL) async -> FolderListing {
        let listing = DirectoryWalker.children(of: root.path)
        if let error = listing.error {
            return FolderListing(entries: [], deniedPaths: AccessCheck.isPermissionErrno(error) ? [root.path] : [])
        }
        let entries = listing.children.map { child in
            FileEntry(
                path: child.path,
                sizeBytes: child.kind == .directory ? Self.unmeasured : child.allocatedSize,
                isDirectory: child.kind == .directory,
                modified: child.modified
            )
        }
        .sorted { lhs, rhs in
            lhs.isDirectory != rhs.isDirectory ? lhs.isDirectory : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return FolderListing(entries: entries, deniedPaths: [])
    }

    /// Measures arbitrary items (files or folders), keeping their order. A missing item comes
    /// back with size 0 and `modified == nil`.
    @concurrent
    public func measure(_ urls: [URL], progress: ScanProgress? = nil) async -> FolderListing {
        let sizes = await SizeCalculator.measureAll(urls, listingDepth: Self.prefetchDepth, progress: progress)
        var denied: [String] = []
        var prefetched: [String: [FileEntry]] = [:]
        let entries = zip(urls, sizes).map { url, size in
            denied += size.deniedPaths
            prefetched.merge(size.listings) { $1 }
            var info = stat()
            let found = lstat(url.path, &info) == 0
            return FileEntry(
                path: url.path,
                sizeBytes: size.bytes,
                isDirectory: found && info.st_mode & S_IFMT == S_IFDIR,
                modified: found
                    ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
                    : nil
            )
        }
        return FolderListing(entries: entries, deniedPaths: denied, prefetched: prefetched)
    }
}
