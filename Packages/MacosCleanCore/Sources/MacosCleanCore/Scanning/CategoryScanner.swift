import Darwin
import Foundation

public struct CategoryScanResult: Sendable, Equatable {
    public let categoryID: String
    /// Deletable units, largest first.
    public let entries: [FileEntry]
    /// Locations macOS refused to open (needs Full Disk Access).
    public let deniedPaths: [String]
    public let scannedAt: Date

    public var totalBytes: Int64 { entries.totalBytes }

    public init(categoryID: String, entries: [FileEntry], deniedPaths: [String], scannedAt: Date = .now) {
        self.categoryID = categoryID
        self.entries = entries
        self.deniedPaths = deniedPaths
        self.scannedAt = scannedAt
    }
}

public struct FolderListing: Sendable, Equatable {
    public let entries: [FileEntry]
    public let deniedPaths: [String]
}

/// Scans Storage Manager categories. Port of `scan_category` / `scan_path` in the reference.
public struct CategoryScanner: Sendable {
    public let expander: PathExpander
    public let database: JunkDatabase

    public init(expander: PathExpander = PathExpander(), database: JunkDatabase = .bundled) {
        self.expander = expander
        self.database = database
    }

    @concurrent
    public func scan(_ category: CleanupCategory) async -> CategoryScanResult {
        switch category.source {
        case .devProjects:
            let entries = await DevProjectScanner(root: URL(fileURLWithPath: expander.home)).scan()
            return CategoryScanResult(categoryID: category.id, entries: entries, deniedPaths: [])

        case .appCaches:
            let urls = database.safeCacheEntries(expander: expander)
            let measured = await measure(urls)
            return CategoryScanResult(
                categoryID: category.id,
                entries: measured.entries.filter { $0.sizeBytes > 0 }.sortedBySizeDescending(),
                deniedPaths: measured.deniedPaths
            )

        case .paths(let rawPaths):
            var entries: [FileEntry] = []
            var denied: [String] = []
            for raw in rawPaths {
                guard !Task.isCancelled else { break }
                let root = expander.expand(raw)
                let listing = await list(root)
                entries += listing.entries
                denied += listing.deniedPaths
            }
            return CategoryScanResult(categoryID: category.id, entries: entries, deniedPaths: denied)
        }
    }

    /// The children of a folder with their sizes, largest first. A file root returns itself.
    @concurrent
    public func list(_ root: URL) async -> FolderListing {
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            // Missing is normal (tool not installed); "not permitted" means macOS blocked us.
            return FolderListing(entries: [], deniedPaths: AccessCheck.isPermissionErrno(errno) ? [root.path] : [])
        }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        if !isDirectory {
            return await measure([root])
        }
        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: []
            )
            let measured = await measure(children)
            return FolderListing(entries: measured.entries.sortedBySizeDescending(), deniedPaths: measured.deniedPaths)
        } catch {
            return FolderListing(entries: [], deniedPaths: AccessCheck.isPermissionError(error) ? [root.path] : [])
        }
    }

    /// Size of a folder that ``shallowList(_:)`` hasn't measured yet.
    public static let unmeasured: Int64 = -1

    /// The children of a folder without walking subfolders, so it returns at once. Files carry
    /// their own allocated size; folders carry ``unmeasured``. Folders first, then by name.
    @concurrent
    public func shallowList(_ root: URL) async -> FolderListing {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey], options: []
            )
        } catch {
            return FolderListing(entries: [], deniedPaths: AccessCheck.isPermissionError(error) ? [root.path] : [])
        }
        let entries = children.map { url in
            var info = stat()
            let found = lstat(url.path, &info) == 0
            let isDirectory = found && info.st_mode & S_IFMT == S_IFDIR
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return FileEntry(
                path: url.path,
                sizeBytes: isDirectory ? Self.unmeasured : (found ? Int64(info.st_blocks) * 512 : 0),
                isDirectory: isDirectory,
                modified: modified
            )
        }
        .sorted { lhs, rhs in
            lhs.isDirectory != rhs.isDirectory ? lhs.isDirectory : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return FolderListing(entries: entries, deniedPaths: [])
    }

    private func measure(_ urls: [URL]) async -> FolderListing {
        let sizes = await SizeCalculator.measureAll(urls)
        var denied: [String] = []
        let entries = zip(urls, sizes).map { url, size in
            denied += size.deniedPaths
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            return FileEntry(
                path: url.path,
                sizeBytes: size.bytes,
                isDirectory: values?.isDirectory == true && values?.isSymbolicLink != true,
                modified: values?.contentModificationDate
            )
        }
        return FolderListing(entries: entries, deniedPaths: denied)
    }
}
