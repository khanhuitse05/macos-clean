import Darwin
import Foundation
import Synchronization

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
                await scanner.walk { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The top two levels are read here; every folder at depth 2 then becomes its own walk,
    /// run in parallel (bounded by ``ScanThrottle``), so a home folder uses every core instead
    /// of one.
    private func walk(_ emit: @escaping @Sendable (LargeFileEvent) -> Void) async {
        var rootPath = root.standardizedFileURL.path
        while rootPath.count > 1, rootPath.hasSuffix("/") { rootPath.removeLast() }
        let rules = Self.skipSubstrings
            .filter { !(rootPath + "/").contains($0) }
            .map(SkipRule.init)
        let shared = SharedProgress()
        let splitDepth = maxDepth > Self.splitDepth ? Self.splitDepth : nil
        @Sendable func makeVisitor(depthOffset: Int, split: Int?) -> Visitor {
            Visitor(
                minimumBytes: minimumBytes, maxResults: maxResults, maxDepth: maxDepth, rules: rules,
                depthOffset: depthOffset, splitDepth: split, shared: shared, emit: emit
            )
        }

        var top = makeVisitor(depthOffset: 0, split: splitDepth)
        DirectoryWalker.walk(root: rootPath, visitor: &top)
        top.flush()
        let work = top.workItems

        if !work.isEmpty, !Task.isCancelled, !shared.isFull(maxResults) {
            let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func addNext() {
                    let item = work[next]
                    next += 1
                    group.addTask {
                        await ScanThrottle.shared.acquire()
                        if !Task.isCancelled, !shared.isFull(maxResults) {
                            var visitor = makeVisitor(depthOffset: item.depth, split: nil)
                            DirectoryWalker.walk(root: item.path, visitor: &visitor)
                            visitor.flush()
                        }
                        await ScanThrottle.shared.release()
                    }
                }
                for _ in 0..<min(width, work.count) { addNext() }
                for await _ in group where next < work.count && !Task.isCancelled { addNext() }
            }
        }
        emit(.progress(scanned: shared.scanned.load(ordering: .relaxed)))
        emit(.finished(found: min(shared.found.load(ordering: .relaxed), maxResults ?? .max)))
    }

    /// Folders at this depth are handed to parallel walks.
    static let splitDepth = 2

    /// Counters shared by the parallel walks.
    final class SharedProgress: Sendable {
        let scanned = Atomic<Int>(0)
        let found = Atomic<Int>(0)

        func isFull(_ maxResults: Int?) -> Bool {
            guard let maxResults else { return false }
            return found.load(ordering: .relaxed) >= maxResults
        }
    }

    /// A path-substring skip rule with a cheap test on the folder name first, so the full
    /// substring search runs only for the rare folders that could match.
    struct SkipRule {
        let pattern: String
        private let test: Test

        private enum Test {
            /// Rule has no "/", e.g. ".photoslibrary": the name must contain it.
            case nameContains(String)
            /// Rule ends with "/", e.g. "/.git/": the name must equal its last segment.
            case nameEquals(String)
            /// Otherwise the rule's last segment must start the name ("/Library/Caches" → "Caches…").
            case namePrefix(String)
        }

        init(_ pattern: String) {
            self.pattern = pattern
            if !pattern.contains("/") {
                test = .nameContains(pattern)
            } else if pattern.hasSuffix("/") {
                test = .nameEquals(pattern.split(separator: "/").last.map(String.init) ?? "")
            } else {
                test = .namePrefix(String(pattern[pattern.index(after: pattern.lastIndex(of: "/")!)...]))
            }
        }

        /// Same answer as `(path + "/").contains(pattern)` for a folder whose parent didn't match.
        func matches(name: String, path: @autoclosure () -> String) -> Bool {
            let candidate = switch test {
            case .nameContains(let part): name.contains(part)
            case .nameEquals(let part): name == part
            case .namePrefix(let part): name.hasPrefix(part)
            }
            return candidate && (path() + "/").contains(pattern)
        }
    }

    private struct Visitor: DirectoryWalker.Visitor {
        static let batchSize = 15
        static let interval: UInt64 = 250_000_000

        let minimumBytes: Int64
        let maxResults: Int?
        let maxDepth: Int
        let rules: [SkipRule]
        /// Depth of this walk's root below the scan root.
        let depthOffset: Int
        /// Folders at this depth are recorded in `workItems` instead of being walked here.
        let splitDepth: Int?
        let shared: SharedProgress
        let emit: @Sendable (LargeFileEvent) -> Void

        var workItems: [(path: String, depth: Int)] = []
        var buffer: [FileEntry] = []
        var unreportedScans = 0
        var visited = 0
        var lastFlush = DispatchTime.now().uptimeNanoseconds

        mutating func flush() {
            if !buffer.isEmpty {
                emit(.found(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
            let total = shared.scanned.add(unreportedScans, ordering: .relaxed).newValue
            unreportedScans = 0
            emit(.progress(scanned: total))
            lastFlush = DispatchTime.now().uptimeNanoseconds
        }

        func enter(_ path: String, depth: Int) {}
        func leave(_ path: String, depth: Int) {}

        func denied(_ path: String, errno: Int32, depth: Int) {
            emit(.denied(path))
        }

        mutating func visit(_ entry: borrowing DirectoryWalker.Entry) -> DirectoryWalker.Decision {
            visited += 1
            // Clock and cancellation checks are sampled, not paid per entry.
            if visited & 0xFF == 0 {
                if Task.isCancelled || shared.isFull(maxResults) { return .stop }
                if DispatchTime.now().uptimeNanoseconds - lastFlush >= Self.interval { flush() }
            }
            let depth = entry.depth + depthOffset
            switch entry.kind {
            case .directory:
                if depth >= maxDepth { return .skipChildren }
                let name = entry.name
                // A skip rule that already matches the chosen root is ignored, so picking
                // e.g. ~/Library/Caches on purpose still works.
                if LargeFileScanner.skipNames.contains(name)
                    || rules.contains(where: { $0.matches(name: name, path: entry.path) }) {
                    return .skipChildren
                }
                // App bundles and other packages are managed by the Uninstaller.
                if name.hasSuffix(".app") { return .skipChildren }
                if depth == splitDepth {
                    workItems.append((entry.path, depth))
                    return .skipChildren
                }
            case .file:
                unreportedScans += 1
                // Only files over the threshold ever get a path string.
                guard entry.allocatedSize >= minimumBytes, depth <= maxDepth else { break }
                let count = shared.found.add(1, ordering: .relaxed).newValue
                if let maxResults, count > maxResults { return .stop }
                buffer.append(FileEntry(
                    path: entry.path, sizeBytes: entry.allocatedSize, isDirectory: false, modified: entry.modified
                ))
                if let maxResults, count >= maxResults { return .stop }
                if buffer.count >= Self.batchSize { flush() }
            case .symlink, .other:
                break
            }
            return .proceed
        }
    }
}
