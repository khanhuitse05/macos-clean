import Darwin
import Foundation

public enum LargeFileEvent: Sendable, Equatable {
    /// Newly found files (unsorted), sent in small batches so the list fills in live.
    case found([FileEntry])
    /// Files looked at so far.
    case progress(scanned: Int)
    /// A folder macOS refused to open (usually needs Full Disk Access).
    case denied(String)
    case finished(found: Int)
}

/// Streams files at or above a size threshold. Port of `scan_large_files` in the reference.
///
/// Skips caches, containers, the Trash, Photos libraries, `.git` and `node_modules`: those are
/// either managed elsewhere (Storage Manager) or dangerous to remove file by file.
public struct LargeFileScanner: Sendable {
    static let skipSubstrings = [
        "/Library/Caches", "/Library/Application Support/MobileSync", "/.Trash",
        "/Library/Containers", "/Library/Group Containers", "/node_modules", "/.git/",
        ".photoslibrary", "/.cache", "/Library/Mobile Documents",
    ]
    static let skipNames: Set<String> = [".git", "node_modules", ".Trash"]

    public let root: URL
    public let minimumBytes: Int64
    public let maxResults: Int?
    public let maxDepth: Int

    public init(root: URL, minimumBytes: Int64, maxResults: Int? = nil, maxDepth: Int = 8) {
        self.root = root
        self.minimumBytes = minimumBytes
        self.maxResults = maxResults
        self.maxDepth = maxDepth
    }

    /// Cancel the consuming task (or stop iterating) to stop the walk.
    public func scan() -> AsyncStream<LargeFileEvent> {
        let scanner = self
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .utility) {
                scanner.walk { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func walk(_ emit: (LargeFileEvent) -> Void) {
        let batchSize = 15
        let interval: TimeInterval = 0.25
        var buffer: [FileEntry] = []
        var lastFlush = Date()
        var scanned = 0
        var found = 0
        let rootPath = root.standardizedFileURL.path
        let activeSkips = Self.skipSubstrings.filter { !(rootPath + "/").contains($0) }

        func flush() {
            if !buffer.isEmpty {
                emit(.found(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
            emit(.progress(scanned: scanned))
            lastFlush = Date()
        }

        FTSWalker.walk(root: rootPath) { entry in
            if scanned & 0x3FF == 0, Task.isCancelled { return .stop }
            switch entry.kind {
            case .directory:
                if entry.depth >= maxDepth { return .skipChildren }
                if entry.depth > 0 {
                    let name = (entry.path as NSString).lastPathComponent
                    // A skip rule that already matches the chosen root is ignored, so picking
                    // e.g. ~/Library/Caches on purpose still works.
                    if Self.skipNames.contains(name)
                        || activeSkips.contains(where: { (entry.path + "/").contains($0) }) {
                        return .skipChildren
                    }
                    // App bundles and other packages are managed by the Uninstaller.
                    if name.hasSuffix(".app") { return .skipChildren }
                }
            case .unreadableDirectory(let code):
                if AccessCheck.isPermissionErrno(code) { emit(.denied(entry.path)) }
            case .file:
                scanned += 1
                guard let stat = entry.stat, entry.depth <= maxDepth else { break }
                let size = Int64(stat.st_blocks) * 512
                guard size >= minimumBytes else { break }
                let modified = Date(
                    timeIntervalSince1970: TimeInterval(stat.st_mtimespec.tv_sec)
                        + TimeInterval(stat.st_mtimespec.tv_nsec) / 1e9
                )
                buffer.append(FileEntry(path: entry.path, sizeBytes: size, isDirectory: false, modified: modified))
                found += 1
                if let maxResults, found >= maxResults { return .stop }
            case .symlink, .other:
                break
            }
            if buffer.count >= batchSize || Date().timeIntervalSince(lastFlush) >= interval { flush() }
            return .proceed
        }
        flush()
        emit(.finished(found: found))
    }
}
