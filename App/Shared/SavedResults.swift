import Darwin
import Foundation
import MacosCleanCore

/// Saves one section's last results between launches, as JSON next to the other caches
/// (`~/Library/Application Support/<bundle id>/<fileName>`).
actor SavedResults<Payload: Codable & Sendable> {
    private let url: URL?

    init(fileName: String) {
        url = AppWatcher.defaultCacheURL?.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    func load() -> Payload? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    func save(_ payload: Payload) {
        guard let url, let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// A saved file as it is on disk now, or nil if it's gone or no longer a regular file.
struct FileStamp: Equatable {
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let modified: Date

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        logicalBytes = Int64(info.st_size)
        allocatedBytes = Int64(info.st_blocks) * 512
        modified = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        )
    }

    /// Same modification time as `date`, within a millisecond (saved dates are Doubles).
    func isModified(at date: Date?) -> Bool {
        guard let date else { return false }
        return abs(modified.timeIntervalSince(date)) < 0.001
    }
}
