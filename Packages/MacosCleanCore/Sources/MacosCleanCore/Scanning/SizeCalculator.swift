import Darwin
import Foundation
import Synchronization

/// Result of measuring a file or folder tree.
public struct SizeResult: Sendable, Equatable {
    public var bytes: Int64
    /// Folders inside the tree that macOS refused to open (usually missing Full Disk Access).
    public var deniedPaths: [String]
    /// Children of folders near the top of the tree, keyed by folder path, largest first.
    /// Collected during the same walk (see `listingDepth`) so a UI can expand those folders
    /// without walking them again. Folders with very many children are left out.
    public var listings: [String: [FileEntry]]

    public static let zero = SizeResult(bytes: 0, deniedPaths: [])

    public init(bytes: Int64, deniedPaths: [String], listings: [String: [FileEntry]] = [:]) {
        self.bytes = bytes
        self.deniedPaths = deniedPaths
        self.listings = listings
    }
}

/// Measures allocated disk usage: never follows symlinks, counts each hard-linked inode once,
/// and reports folders it can't read instead of failing. Built on ``DirectoryWalker``
/// (`getattrlistbulk`).
public enum SizeCalculator {
    /// Folders with more children than this get no prefetched listing (memory guard).
    static let maxListingCount = 5_000

    /// - Parameter listingDepth: also collect the children of folders less than this many
    ///   levels below `url` (1 = the root's own children, 2 = also its subfolders' children).
    public static func measure(_ url: URL, listingDepth: Int = 0, progress: ScanProgress? = nil) -> SizeResult {
        let path = url.path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return AccessCheck.isPermissionErrno(errno) ? SizeResult(bytes: 0, deniedPaths: [path]) : .zero
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            let bytes = Int64(info.st_blocks) * 512
            progress?.add(bytes: bytes, files: 1)
            return SizeResult(bytes: bytes, deniedPaths: [])
        }
        var visitor = SizeVisitor(listingDepth: listingDepth, splitDepth: nil, inodes: InodeSet(), progress: progress)
        DirectoryWalker.walk(root: path, visitor: &visitor)
        visitor.flushProgress()
        return visitor.result
    }

    public static func allocatedSize(of url: URL) -> Int64 { measure(url).bytes }

    /// Folders this many levels down are measured as separate, parallel walks.
    static let splitDepth = 2

    /// Same result as ``measure(_:listingDepth:)``, but a big tree is split: the top two
    /// levels are read first, then every folder below them is walked on its own task (bounded
    /// by ``ScanThrottle``) and the sizes are folded back up. A single large folder (a project
    /// tree, `~/Library`) then uses every core instead of one.
    @concurrent
    public static func measureParallel(_ url: URL, listingDepth: Int = 0, progress: ScanProgress? = nil) async -> SizeResult {
        let path = url.path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return AccessCheck.isPermissionErrno(errno) ? SizeResult(bytes: 0, deniedPaths: [path]) : .zero
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            let bytes = Int64(info.st_blocks) * 512
            progress?.add(bytes: bytes, files: 1)
            return SizeResult(bytes: bytes, deniedPaths: [])
        }
        let inodes = InodeSet()
        await ScanThrottle.shared.acquire()
        var top = SizeVisitor(listingDepth: listingDepth, splitDepth: splitDepth, inodes: inodes, progress: progress)
        DirectoryWalker.walk(root: path, visitor: &top)
        top.flushProgress()
        await ScanThrottle.shared.release()
        var result = top.result
        let work = top.workItems
        guard !work.isEmpty, !Task.isCancelled else { return result }

        // A permit is held only around each synchronous walk, never across an await, so
        // nested measurements can't deadlock on the throttle.
        let innerDepth = max(0, listingDepth - splitDepth)
        let parts = await withTaskGroup(of: (String, SizeResult).self) { group in
            var parts: [(String, SizeResult)] = []
            parts.reserveCapacity(work.count)
            var next = 0
            func addNext() {
                let item = work[next]
                next += 1
                group.addTask {
                    await ScanThrottle.shared.acquire()
                    var visitor = SizeVisitor(listingDepth: innerDepth, splitDepth: nil, inodes: inodes, progress: progress)
                    if !Task.isCancelled { DirectoryWalker.walk(root: item, visitor: &visitor) }
                    visitor.flushProgress()
                    await ScanThrottle.shared.release()
                    return (item, visitor.result)
                }
            }
            for _ in 0..<min(max(2, ProcessInfo.processInfo.activeProcessorCount), work.count) { addNext() }
            for await part in group {
                parts.append(part)
                if next < work.count, !Task.isCancelled { addNext() }
            }
            return parts
        }

        // Fold each part's bytes into the folders above it.
        let topListings = Set(result.listings.keys)
        var extra: [String: Int64] = [:]
        for (item, part) in parts {
            result.bytes += part.bytes
            result.deniedPaths += part.deniedPaths
            result.listings.merge(part.listings) { $1 }
            guard part.bytes > 0 else { continue }
            extra[item, default: 0] += part.bytes
            PathSelection.forEachAncestor(of: item) { ancestor in
                extra[ancestor, default: 0] += part.bytes
                return ancestor != path && ancestor.count > path.count
            }
        }
        for folder in topListings {
            guard let entries = result.listings[folder], entries.contains(where: { extra[$0.path] != nil }) else { continue }
            result.listings[folder] = entries.map { entry in
                guard entry.isDirectory, let added = extra[entry.path] else { return entry }
                return FileEntry(path: entry.path, sizeBytes: entry.sizeBytes + added, isDirectory: true, modified: entry.modified)
            }
            .sortedBySizeDescending()
        }
        return result
    }

    /// Measures many items in parallel; results keep the input order. `width` bounds this
    /// call's fan-out and ``ScanThrottle/shared`` bounds the walks running across the whole
    /// app, so nested scans (categories × items) never flood the disk.
    @concurrent
    public static func measureAll(
        _ urls: [URL], width: Int = 6, listingDepth: Int = 0, progress: ScanProgress? = nil
    ) async -> [SizeResult] {
        guard !urls.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, SizeResult).self) { group in
            var results = Array(repeating: SizeResult.zero, count: urls.count)
            var next = 0
            func addNext() {
                let index = next
                next += 1
                group.addTask {
                    let result = Task.isCancelled ? .zero : await measureParallel(urls[index], listingDepth: listingDepth, progress: progress)
                    return (index, result)
                }
            }
            for _ in 0..<min(width, urls.count) { addNext() }
            for await (index, result) in group {
                results[index] = result
                if next < urls.count, !Task.isCancelled { addNext() }
            }
            return results
        }
    }
}

/// Sums sizes bottom-up while the walker streams entries, and keeps child listings for the
/// top `listingDepth` levels.
private struct SizeVisitor: DirectoryWalker.Visitor {
    struct Frame {
        let path: String
        let depth: Int
        var bytes: Int64 = 0
        /// nil when this folder's listing isn't collected (too deep or too many children).
        var children: [FileEntry]?
        var folderDates: [String: Date] = [:]
    }

    let listingDepth: Int
    /// Folders at this depth are left for separate walks and recorded in `workItems`.
    let splitDepth: Int?
    let inodes: InodeSet
    let progress: ScanProgress?
    var pendingBytes: Int64 = 0
    var pendingFiles = 0
    var workItems: [String] = []
    var stack: [Frame] = []
    var total: Int64 = 0
    var denied: [String] = []
    var listings: [String: [FileEntry]] = [:]
    var visited = 0

    init(listingDepth: Int, splitDepth: Int?, inodes: InodeSet, progress: ScanProgress? = nil) {
        self.listingDepth = listingDepth
        self.splitDepth = splitDepth
        self.inodes = inodes
        self.progress = progress
    }

    /// Publishes the bytes counted since the last call to the shared live counter, and the
    /// folder being read now.
    mutating func flushProgress() {
        guard let progress, pendingFiles > 0 else { return }
        if let folder = stack.last?.path { progress.note(folder: folder) }
        progress.add(bytes: pendingBytes, files: pendingFiles)
        pendingBytes = 0
        pendingFiles = 0
    }

    var result: SizeResult {
        // A cancelled walk leaves frames open; report what was counted.
        let partial = stack.reduce(total) { $0 + $1.bytes }
        return SizeResult(bytes: partial, deniedPaths: denied, listings: listings)
    }

    mutating func enter(_ path: String, depth: Int) {
        stack.append(Frame(path: path, depth: depth, children: depth < listingDepth ? [] : nil))
    }

    mutating func visit(_ entry: borrowing DirectoryWalker.Entry) -> DirectoryWalker.Decision {
        visited += 1
        if visited & 0x3FF == 0 {
            if Task.isCancelled { return .stop }
            flushProgress()
        }
        let top = stack.count - 1
        if entry.kind == .directory {
            if let splitDepth, entry.depth == splitDepth {
                let path = entry.path
                workItems.append(path)
                // Listed now with size 0; measureParallel adds the size once its walk is done.
                if stack[top].children != nil {
                    append(FileEntry(path: path, sizeBytes: 0, isDirectory: true, modified: entry.modified), to: top)
                }
                return .skipChildren
            }
            if stack[top].children != nil { stack[top].folderDates[entry.path] = entry.modified }
            return .proceed
        }
        var size = entry.allocatedSize
        if entry.isRegularMultiLink, !inodes.insert(InodeKey(device: entry.device, inode: entry.inode)) {
            size = 0
        }
        stack[top].bytes += size
        pendingBytes += size
        pendingFiles += 1
        if stack[top].children != nil {
            append(FileEntry(path: entry.path, sizeBytes: size, isDirectory: false, modified: entry.modified), to: top)
        }
        return .proceed
    }

    mutating func denied(_ path: String, errno: Int32, depth: Int) {
        denied.append(path)
        // A subfolder we couldn't open still shows up in its parent's listing, empty.
        if let top = stack.indices.last, stack[top].depth == depth - 1, stack[top].children != nil {
            append(FileEntry(path: path, sizeBytes: 0, isDirectory: true, modified: stack[top].folderDates[path]), to: top)
        }
    }

    mutating func leave(_ path: String, depth: Int) {
        let frame = stack.removeLast()
        if let children = frame.children { listings[path] = children.sortedBySizeDescending() }
        guard let top = stack.indices.last else {
            total += frame.bytes
            return
        }
        stack[top].bytes += frame.bytes
        if stack[top].children != nil {
            append(FileEntry(path: path, sizeBytes: frame.bytes, isDirectory: true, modified: stack[top].folderDates[path]), to: top)
        }
    }

    private mutating func append(_ entry: FileEntry, to index: Int) {
        if stack[index].children!.count >= SizeCalculator.maxListingCount {
            stack[index].children = nil
            stack[index].folderDates = [:]
        } else {
            stack[index].children!.append(entry)
        }
    }
}

/// A live counter of what a scan has measured so far. Walks add to it in batches from any
/// thread; a UI reads it a few times a second to show running totals.
public final class ScanProgress: Sendable {
    private let byteCount = Atomic<Int64>(0)
    private let fileCount = Atomic<Int>(0)
    private let folder = Mutex<String?>(nil)

    public init() {}

    public var bytes: Int64 { byteCount.load(ordering: .relaxed) }
    public var files: Int { fileCount.load(ordering: .relaxed) }
    /// A folder one of the walks was reading at its last update; nil until the first one.
    public var currentFolder: String? { folder.withLock { $0 } }

    func note(folder path: String) {
        folder.withLock { $0 = path }
    }

    func add(bytes: Int64, files: Int) {
        byteCount.add(bytes, ordering: .relaxed)
        fileCount.add(files, ordering: .relaxed)
    }
}

struct InodeKey: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

/// Hard-linked inodes already counted, shared by the parallel walks of one measurement so a
/// file linked from two subfolders still counts once. Only multi-link files touch the lock.
final class InodeSet: Sendable {
    private let seen = Mutex(Set<InodeKey>())

    /// True if `key` wasn't counted yet.
    func insert(_ key: InodeKey) -> Bool {
        seen.withLock { $0.insert(key).inserted }
    }
}

/// App-wide cap on concurrent tree walks. More parallel walks than cores only adds seek
/// thrash on spinning and external disks without making SSDs faster.
public actor ScanThrottle {
    public static let shared = ScanThrottle(limit: max(4, ProcessInfo.processInfo.activeProcessorCount))

    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    public func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // Hand the slot straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}
