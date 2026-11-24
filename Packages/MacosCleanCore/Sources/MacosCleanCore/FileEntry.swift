import Foundation

/// One file or folder found by a scan. Identified by its absolute path.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public let path: String
    /// Bytes actually used on disk (allocated size), not the logical length. Cloud placeholders
    /// (iCloud, OneDrive, Dropbox) report ~0, which is what deleting them would free.
    public let sizeBytes: Int64
    public let isDirectory: Bool
    public let modified: Date?

    public init(path: String, sizeBytes: Int64, isDirectory: Bool, modified: Date? = nil) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.modified = modified
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
    public var parentPath: String { (path as NSString).deletingLastPathComponent }
}

extension Array where Element == FileEntry {
    public var totalBytes: Int64 { reduce(0) { $0 + $1.sizeBytes } }

    /// Largest first, then by path so the order is stable.
    public func sortedBySizeDescending() -> [FileEntry] {
        sorted { $0.sizeBytes != $1.sizeBytes ? $0.sizeBytes > $1.sizeBytes : $0.path < $1.path }
    }
}
