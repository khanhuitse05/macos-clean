import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Copies of the same file content.
public struct DuplicateGroup: Identifiable, Sendable, Equatable, Hashable, Codable {
    /// SHA-256 of the content, hex.
    public let id: String
    /// Logical length of each copy.
    public let fileBytes: Int64
    /// Every copy, newest first. Sizes are allocated bytes on disk.
    public let files: [FileEntry]
    /// Every copy is data an app keeps for itself (``FileLocation/appData``): removing one can
    /// break the app, or the app writes it again.
    public let isAppManaged: Bool

    public init(id: String, fileBytes: Int64, files: [FileEntry], isAppManaged: Bool = false) {
        self.id = id
        self.fileBytes = fileBytes
        self.files = files
        self.isAppManaged = isAppManaged
    }

    /// Disk space the extra copies take: everything except the largest single copy.
    public var wastedBytes: Int64 {
        files.totalBytes - (files.map(\.sizeBytes).max() ?? 0)
    }

    public var name: String { files.first?.name ?? "" }
    public var displayName: String { files.first?.displayName ?? "" }
}

public enum DuplicateEvent: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// Walking folders, collecting files of interesting sizes.
        case walking
        /// Hashing the first and last 64 KB of same-size files.
        case comparingStarts
        /// Hashing whole files that still match.
        case comparingContents
    }

    /// `done`/`total` are files for the hashing stages; for walking, `done` is files seen.
    case progress(stage: Stage, done: Int, total: Int)
    /// The folder being walked right now, a few times a second.
    case looking(String)
    /// A group confirmed while the search goes on. The biggest files are compared first.
    case found(DuplicateGroup)
    /// A folder macOS refused to open (usually needs Full Disk Access).
    case denied(String)
    /// Largest waste first.
    case finished([DuplicateGroup])
}

/// Finds files with identical content: group by size → hash of the first and last 64 KB →
/// full SHA-256. Only files that survive each stage are read further, so most files are never
/// opened.
///
/// Skips what Large Files skips (caches, containers, the Trash, Photos libraries, `.git`,
/// `node_modules`, app bundles), folders that developer tools generate (`.dart_tool`, `.gradle`,
/// `.idea`, `.vscode`, a project's `build`/`target`, …), app `Caches` folders anywhere in a
/// Library, files a git repository ignores (build output, bundles, local uploads), the Go
/// module cache, Unity's caches, plus excluded folders. `~/Library` and hidden folders (`~/.android`, `~/.rbenv`,
/// `~/.gemini`, …) are skipped unless a root is inside them: they hold app and tool data, not the
/// person's files. Hard links are one file. APFS clones of each other share
/// their blocks, so deleting one frees nothing: they count as one copy.
public struct DuplicateFinder: Sendable {
    /// Folders searched together; overlapping roots count each file once.
    public let roots: [URL]
    public let minimumBytes: Int64
    public let maxDepth: Int
    public let exclusions: ExclusionList
    /// The home folder whose `Library` is skipped and that ``FileLocation`` is measured from.
    public let home: String
    /// Leaves out files their git repository ignores.
    public let respectsGitignore: Bool
    /// Hashes from earlier scans; files that haven't changed aren't read again. Saved when a
    /// search ends (finished or stopped).
    public let hashCache: HashCache?

    public var root: URL { roots[0] }

    /// The home folder plus iCloud Drive (which lives in `~/Library` and would be skipped).
    public static func userRoots(home: String = NSHomeDirectory()) -> [URL] {
        var roots = [URL(fileURLWithPath: home)]
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: iCloud) { roots.append(URL(fileURLWithPath: iCloud)) }
        return roots
    }

    /// Folders that developer tools and IDEs create and fill with copies of the same files.
    /// Duplicates in them aren't worth cleaning one by one: the tools recreate them.
    static let developerFolderNames: Set<String> = DevProjectScanner.unmistakable.union([
        // IDE and editor settings
        ".idea", ".vscode", ".vs", ".fleet", ".history", "xcuserdata",
        // SwiftPM, Flutter/Dart, Android, Kotlin, CMake
        ".build", ".swiftpm", ".pub-cache", ".fvm", ".cxx", ".externalNativeBuild", ".kotlin",
        // Python, Ruby, JS tooling
        ".venv", ".eggs", ".hypothesis", ".ipynb_checkpoints", ".yarn", ".pnpm-store", ".bundle",
        "site-packages", "dist-packages", "anaconda3", "miniconda3", "miniforge3", "mambaforge",
        "Carthage",
    ])

    /// Packages: one unit to Finder, made and read by an app. Deleting a file inside breaks it.
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "xcframework", "plugin", "appex", "kext", "dSYM",
        "xcresult", "xcarchive", "docarchive", "fcpbundle", "imovielibrary", "logicx", "band",
        "lrdata", "lrlibrary", "musiclibrary", "tvlibrary", "photoslibrary", "sparsebundle",
        "vmwarevm", "pvm", "utm", "vbox",
    ]

    static let unityGeneratedNames: Set<String> = ["Library", "Temp", "Logs", "obj"]

    /// Generic names (`build`, `target`, …) that only mean generated output inside a project.
    static let projectOutputNames: Set<String> = DevProjectScanner.projectScoped
        .union(DevProjectScanner.ambiguous)

    static func isDeveloperFolder(name: String, path: String) -> Bool {
        if developerFolderNames.contains(name) || name.hasSuffix(".egg-info") { return true }
        // Go's module cache (`$GOPATH/pkg/mod`): read-only copies of every module version.
        if name == "mod", path.hasSuffix("/pkg/mod"),
           FileManager.default.fileExists(atPath: path + "/cache/download") {
            return true
        }
        // A Unity project's caches, next to its ProjectSettings.
        if unityGeneratedNames.contains(name) {
            let parent = (path as NSString).deletingLastPathComponent
            return FileManager.default.fileExists(atPath: parent + "/ProjectSettings/ProjectVersion.txt")
        }
        guard projectOutputNames.contains(name) else { return false }
        // `build` next to a pubspec.yaml / build.gradle / package.json / .git is generated output;
        // a `build` folder elsewhere may be the user's own.
        let parent = (path as NSString).deletingLastPathComponent
        guard let siblings = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return false }
        return siblings.contains { $0 == ".git" || DevProjectScanner.isManifestName($0) }
    }

    /// Bytes hashed at each end of a file in the partial stage.
    static let edgeBytes = 64 * 1024
    static let chunkBytes = 1024 * 1024

    public init(
        roots: [URL], minimumBytes: Int64, maxDepth: Int = 12, exclusions: ExclusionList = .empty,
        home: String = NSHomeDirectory(), respectsGitignore: Bool = true, hashCache: HashCache? = nil
    ) {
        precondition(!roots.isEmpty, "DuplicateFinder needs at least one root")
        self.respectsGitignore = respectsGitignore
        self.hashCache = hashCache
        self.roots = roots
        self.minimumBytes = max(1, minimumBytes)
        self.maxDepth = maxDepth
        self.exclusions = exclusions
        self.home = home
    }

    public init(
        root: URL, minimumBytes: Int64, maxDepth: Int = 12, exclusions: ExclusionList = .empty,
        home: String = NSHomeDirectory(), respectsGitignore: Bool = true, hashCache: HashCache? = nil
    ) {
        self.init(
            roots: [root], minimumBytes: minimumBytes, maxDepth: maxDepth, exclusions: exclusions, home: home,
            respectsGitignore: respectsGitignore, hashCache: hashCache
        )
    }

    /// Cancel the consuming task (or stop iterating) to stop.
    /// - Parameter priority: `.userInitiated` for a search the person started, `.utility` for
    ///   a refresh in the background.
    public func scan(priority: TaskPriority = .userInitiated) -> AsyncStream<DuplicateEvent> {
        let finder = self
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: priority) {
                let groups = await finder.run { continuation.yield($0) }
                if !Task.isCancelled { continuation.yield(.finished(groups)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole search, for callers that don't need progress.
    public func find() async -> [DuplicateGroup] {
        await run { _ in }
    }

    // MARK: Pipeline

    struct Candidate: Sendable, Hashable {
        let path: String
        let allocated: Int64
        let logical: Int64
        let modified: Date
        var inode: UInt64 = 0
    }

    private func run(_ emit: @escaping @Sendable (DuplicateEvent) -> Void) async -> [DuplicateGroup] {
        // Even a stopped search keeps the hashes it computed.
        defer { hashCache?.save() }
        let files = await collect(emit)
        guard !Task.isCancelled else { return [] }

        // Stage 1: same logical size.
        var bySize = Dictionary(grouping: files, by: \.logical).values.filter { $0.count > 1 }

        // Files a repository ignores are tool output (builds, bundles, uploads), not the person's.
        if respectsGitignore {
            let ignored = await GitIgnoredFiles().ignored(bySize.flatMap { $0.map(\.path) })
            guard !Task.isCancelled else { return [] }
            if !ignored.isEmpty {
                bySize = bySize.map { $0.filter { !ignored.contains($0.path) } }.filter { $0.count > 1 }
            }
        }

        // Stage 2: same start and end.
        let partialInput = bySize.flatMap { $0 }
        let partial = await hashAll(partialInput, stage: .comparingStarts, kind: .edge, emit: emit, hash: { Self.edgeHash(of: $0) })
        guard !Task.isCancelled else { return [] }
        var survivors: [[Candidate]] = []
        for group in bySize {
            let byEdge = Dictionary(grouping: group.filter { partial[$0] != nil }) { partial[$0]! }
            survivors += byEdge.values.filter { $0.count > 1 }
        }

        // Stage 3: same content. Small files were read whole in stage 2. Biggest files first,
        // each group's copies together, so groups are confirmed (and reported) as early as possible.
        survivors.sort { $0[0].logical > $1[0].logical }
        var groups: [DuplicateGroup] = []
        var full: [Candidate: String] = [:]
        var remaining: [Int] = []
        var groupOf: [Candidate: Int] = [:]
        var needsFull: [Candidate] = []
        for (index, group) in survivors.enumerated() {
            let big = group.filter { $0.logical > Int64(2 * Self.edgeBytes) }
            remaining.append(big.count)
            for candidate in big { groupOf[candidate] = index }
            needsFull += big
        }
        func confirm(_ index: Int) {
            let found = makeGroups(survivors[index], partial: partial, full: full)
            for group in found { emit(.found(group)) }
            groups += found
        }
        for index in survivors.indices where remaining[index] == 0 { confirm(index) }
        await hashAll(needsFull, stage: .comparingContents, kind: .full, emit: emit, hash: { Self.fullHash(of: $0) }) { candidate, value in
            if let value { full[candidate] = value }
            guard let index = groupOf[candidate] else { return }
            remaining[index] -= 1
            if remaining[index] == 0, !Task.isCancelled { confirm(index) }
        }
        guard !Task.isCancelled else { return [] }
        return groups.sorted { $0.wastedBytes != $1.wastedBytes ? $0.wastedBytes > $1.wastedBytes : $0.id < $1.id }
    }

    /// The groups of identical copies among candidates that share a size and edges.
    private func makeGroups(_ group: [Candidate], partial: [Candidate: String], full: [Candidate: String]) -> [DuplicateGroup] {
        let keyed = Dictionary(grouping: group.compactMap { candidate -> (String, Candidate)? in
            if candidate.logical <= Int64(2 * Self.edgeBytes) {
                return partial[candidate].map { ($0, candidate) }
            }
            return full[candidate].map { ($0, candidate) }
        }, by: \.0)
        var result: [DuplicateGroup] = []
        for (hash, pairs) in keyed {
            let copies = Self.collapsingClones(pairs.map(\.1))
            guard copies.count > 1 else { continue }
            let entries = copies
                .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
                .map { FileEntry(path: $0.path, sizeBytes: $0.allocated, isDirectory: false, modified: $0.modified) }
            let managed = entries.allSatisfy { FileLocation.of($0.path, home: home) == .appData }
            result.append(DuplicateGroup(id: hash, fileBytes: copies[0].logical, files: entries, isAppManaged: managed))
        }
        return result
    }

    /// Hashes candidates in parallel; files that can't be read are left out. `each` sees every
    /// result as it arrives (`nil` when the file couldn't be read). Hashes in ``hashCache``
    /// for an unchanged file are used without opening it.
    @discardableResult
    private func hashAll(
        _ candidates: [Candidate], stage: DuplicateEvent.Stage, kind: HashCache.Kind,
        emit: @escaping @Sendable (DuplicateEvent) -> Void,
        hash: @escaping @Sendable (String) -> String?,
        each: (Candidate, String?) -> Void = { _, _ in }
    ) async -> [Candidate: String] {
        guard !candidates.isEmpty else { return [:] }
        emit(.progress(stage: stage, done: 0, total: candidates.count))
        let width = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        var results: [Candidate: String] = [:]
        var done = 0
        let cache = hashCache
        await withTaskGroup(of: (Candidate, String?).self) { group in
            var next = 0
            func addNext() {
                let candidate = candidates[next]
                next += 1
                group.addTask {
                    guard !Task.isCancelled else { return (candidate, nil) }
                    if let cached = cache?.hash(
                        kind, path: candidate.path, size: candidate.logical, modified: candidate.modified, inode: candidate.inode
                    ) {
                        return (candidate, cached)
                    }
                    await ScanThrottle.shared.acquire()
                    let value = hash(candidate.path)
                    await ScanThrottle.shared.release()
                    if let value {
                        cache?.store(
                            value, kind, path: candidate.path, size: candidate.logical, modified: candidate.modified,
                            inode: candidate.inode
                        )
                    }
                    return (candidate, value)
                }
            }
            for _ in 0..<min(width, candidates.count) { addNext() }
            for await (candidate, value) in group {
                if let value { results[candidate] = value }
                each(candidate, value)
                done += 1
                if done & 0x3F == 0 || done == candidates.count {
                    emit(.progress(stage: stage, done: done, total: candidates.count))
                }
                if next < candidates.count, !Task.isCancelled { addNext() }
            }
        }
        return results
    }

    // MARK: Walking

    /// Regular files at or above the threshold, one per inode, with their logical size.
    private func collect(_ emit: @escaping @Sendable (DuplicateEvent) -> Void) async -> [Candidate] {
        let shared = Shared()
        for root in roots where !Task.isCancelled {
            await walk(root, shared: shared, emit: emit)
        }
        emit(.progress(stage: .walking, done: shared.scanned.load(ordering: .relaxed), total: 0))

        // Hard links (and files under overlapping roots): keep one path per inode. Logical
        // sizes and the dataless check need lstat.
        var seenInodes = Set<FileID>()
        var result: [Candidate] = []
        for found in shared.takeFound() where seenInodes.insert(FileID(device: found.device, inode: found.inode)).inserted {
            guard !Task.isCancelled else { return [] }
            var info = stat()
            guard lstat(found.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_flags & DirectoryWalker.datalessFlag == 0, info.st_size > 0
            else { continue }
            result.append(Candidate(
                path: found.path, allocated: found.allocated, logical: Int64(info.st_size), modified: found.modified,
                inode: found.inode
            ))
        }
        return result
    }

    private func walk(_ root: URL, shared: Shared, emit: @escaping @Sendable (DuplicateEvent) -> Void) async {
        var rootPath = root.standardizedFileURL.path
        while rootPath.count > 1, rootPath.hasSuffix("/") { rootPath.removeLast() }
        let rules = LargeFileScanner.skipSubstrings
            .filter { !(rootPath + "/").contains($0) }
            .map(LargeFileScanner.SkipRule.init)
        let exclusions = exclusions.applying(toRoot: rootPath)
        // ~/Library is app data; search it only when it was chosen (the root is inside it).
        var homePath = home
        while homePath.count > 1, homePath.hasSuffix("/") { homePath.removeLast() }
        let library = homePath + "/Library"
        let skipped: Set<String> = rootPath == library || rootPath.hasPrefix(library + "/") ? [] : [library]
        // Hidden folders are tool data; search them only when the root is inside one.
        let skipsHidden = !rootPath.split(separator: "/").contains { $0.hasPrefix(".") }

        func makeVisitor(depthOffset: Int, split: Int?) -> Visitor {
            Visitor(
                minimumBytes: minimumBytes, maxDepth: maxDepth, rules: rules, exclusions: exclusions,
                skippedFolders: skipped, skipsHidden: skipsHidden, depthOffset: depthOffset, splitDepth: split, shared: shared, emit: emit
            )
        }

        var top = makeVisitor(depthOffset: 0, split: maxDepth > LargeFileScanner.splitDepth ? LargeFileScanner.splitDepth : nil)
        DirectoryWalker.walk(root: rootPath, visitor: &top)
        top.flush()
        let work = top.workItems
        if !work.isEmpty, !Task.isCancelled {
            let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func addNext() {
                    let item = work[next]
                    next += 1
                    group.addTask {
                        await ScanThrottle.shared.acquire()
                        if !Task.isCancelled {
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
    }

    struct FileID: Hashable {
        let device: Int32
        let inode: UInt64
    }

    struct Found: Sendable {
        let path: String
        let allocated: Int64
        let device: Int32
        let inode: UInt64
        let modified: Date
    }

    final class Shared: Sendable {
        let scanned = Atomic<Int>(0)
        private let found = Mutex<[Found]>([])

        func append(_ batch: [Found]) {
            found.withLock { $0 += batch }
        }

        func takeFound() -> [Found] {
            found.withLock { value in
                defer { value = [] }
                return value
            }
        }
    }

    private struct Visitor: DirectoryWalker.Visitor {
        let minimumBytes: Int64
        let maxDepth: Int
        let rules: [LargeFileScanner.SkipRule]
        let exclusions: ExclusionList
        let skippedFolders: Set<String>
        let skipsHidden: Bool
        let depthOffset: Int
        let splitDepth: Int?
        let shared: Shared
        let emit: @Sendable (DuplicateEvent) -> Void

        var workItems: [(path: String, depth: Int)] = []
        var buffer: [Found] = []
        var unreported = 0
        var visited = 0
        var lastFlush = DispatchTime.now().uptimeNanoseconds
        var currentFolder = ""

        mutating func flush() {
            if !buffer.isEmpty {
                shared.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            let total = shared.scanned.add(unreported, ordering: .relaxed).newValue
            unreported = 0
            emit(.progress(stage: .walking, done: total, total: 0))
            if !currentFolder.isEmpty { emit(.looking(currentFolder)) }
            lastFlush = DispatchTime.now().uptimeNanoseconds
        }

        mutating func enter(_ path: String, depth: Int) { currentFolder = path }
        func leave(_ path: String, depth: Int) {}

        func denied(_ path: String, errno: Int32, depth: Int) {
            emit(.denied(path))
        }

        mutating func visit(_ entry: borrowing DirectoryWalker.Entry) -> DirectoryWalker.Decision {
            visited += 1
            if visited & 0xFF == 0 {
                if Task.isCancelled { return .stop }
                if DispatchTime.now().uptimeNanoseconds - lastFlush >= 250_000_000 { flush() }
            }
            let depth = entry.depth + depthOffset
            switch entry.kind {
            case .directory:
                if depth >= maxDepth { return .skipChildren }
                let name = entry.name
                if LargeFileScanner.skipNames.contains(name)
                    || rules.contains(where: { $0.matches(name: name, path: entry.path) })
                    || DuplicateFinder.isDeveloperFolder(name: name, path: entry.path)
                    || skippedFolders.contains(entry.path)
                    || (skipsHidden && name.hasPrefix(".")) {
                    return .skipChildren
                }
                // App caches outside ~/Library/Caches (`Application Support/Caches`, …).
                if name == "Caches", entry.path.contains("/Library/") { return .skipChildren }
                // Packages (apps, bundles, media libraries, disk images) are whole units, not loose files.
                if let dot = name.lastIndex(of: "."),
                   DuplicateFinder.packageExtensions.contains(String(name[name.index(after: dot)...])) {
                    return .skipChildren
                }
                if !exclusions.isEmpty, exclusions.contains(folder: entry.path) { return .skipChildren }
                if depth == splitDepth {
                    workItems.append((entry.path, depth))
                    return .skipChildren
                }
            case .file:
                unreported += 1
                guard entry.allocatedSize >= minimumBytes, depth <= maxDepth else { break }
                buffer.append(Found(
                    path: entry.path, allocated: entry.allocatedSize, device: entry.device,
                    inode: entry.inode, modified: entry.modified
                ))
                if buffer.count >= 256 { flush() }
            case .symlink, .other:
                break
            }
            return .proceed
        }
    }

    // MARK: Hashing

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the length plus the first and last ``edgeBytes`` (the whole file when it's
    /// at most twice that).
    static func edgeHash(of path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let size = Int(info.st_size)
        var hasher = SHA256()
        withUnsafeBytes(of: Int64(size).littleEndian) { hasher.update(bufferPointer: $0) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: edgeBytes, alignment: 16)
        defer { buffer.deallocate() }
        if size <= 2 * edgeBytes {
            guard hashRange(fd, from: 0, length: size, buffer: buffer, into: &hasher) else { return nil }
        } else {
            guard hashRange(fd, from: 0, length: edgeBytes, buffer: buffer, into: &hasher),
                  hashRange(fd, from: size - edgeBytes, length: edgeBytes, buffer: buffer, into: &hasher)
            else { return nil }
        }
        return hex(hasher.finalize())
    }

    /// SHA-256 of the length plus the whole content.
    static func fullHash(of path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        var hasher = SHA256()
        withUnsafeBytes(of: Int64(info.st_size).littleEndian) { hasher.update(bufferPointer: $0) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkBytes, alignment: 16)
        defer { buffer.deallocate() }
        var offset = 0
        while true {
            if Task.isCancelled { return nil }
            let count = pread(fd, buffer.baseAddress, chunkBytes, off_t(offset))
            if count < 0 { return nil }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            offset += count
        }
        return hex(hasher.finalize())
    }

    private static func hashRange(
        _ fd: Int32, from start: Int, length: Int, buffer: UnsafeMutableRawBufferPointer, into hasher: inout SHA256
    ) -> Bool {
        var offset = start
        var remaining = length
        while remaining > 0 {
            let want = min(remaining, buffer.count)
            let count = pread(fd, buffer.baseAddress, want, off_t(offset))
            if count < 0 { return false }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            offset += count
            remaining -= count
        }
        return true
    }

    // MARK: Clones

    /// Keeps one file per APFS clone family: clones share their blocks on disk.
    static func collapsingClones(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<UInt64>()
        return candidates.filter { candidate in
            guard let id = cloneID(of: candidate.path) else { return true }
            return seen.insert(id).inserted
        }
    }

    /// `ATTR_CMNEXT_CLONEID`: the same for files that are pure clones of each other.
    static func cloneID(of path: String) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        var buffer = [UInt8](repeating: 0, count: 32)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let length = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard length >= 12 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 4, as: UInt64.self)
        }
    }
}
