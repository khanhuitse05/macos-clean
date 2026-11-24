import Darwin
import Foundation

/// Result of measuring a file or folder tree.
public struct SizeResult: Sendable, Equatable {
    public var bytes: Int64
    /// Folders inside the tree that macOS refused to open (usually missing Full Disk Access).
    public var deniedPaths: [String]

    public static let zero = SizeResult(bytes: 0, deniedPaths: [])

    public init(bytes: Int64, deniedPaths: [String]) {
        self.bytes = bytes
        self.deniedPaths = deniedPaths
    }
}

/// Measures allocated disk usage with `fts(3)`: never follows symlinks, counts each hard-linked
/// inode once, and reports folders it can't read instead of failing.
public enum SizeCalculator {
    public static func measure(_ url: URL) -> SizeResult {
        var total: Int64 = 0
        var denied: [String] = []
        var seenInodes = Set<InodeKey>()
        var visited = 0

        FTSWalker.walk(root: url.path) { entry in
            visited += 1
            if visited & 0xFFF == 0, Task.isCancelled { return .stop }
            switch entry.kind {
            case .file, .symlink:
                if let stat = entry.stat {
                    if stat.st_nlink > 1, stat.st_mode & S_IFMT == S_IFREG {
                        guard seenInodes.insert(InodeKey(device: stat.st_dev, inode: stat.st_ino)).inserted else {
                            return .proceed
                        }
                    }
                    total += Int64(stat.st_blocks) * 512
                }
            case .unreadableDirectory(let errno):
                if AccessCheck.isPermissionErrno(errno) { denied.append(entry.path) }
            case .directory, .other:
                break
            }
            return .proceed
        }
        return SizeResult(bytes: total, deniedPaths: denied)
    }

    public static func allocatedSize(of url: URL) -> Int64 { measure(url).bytes }

    /// Measures many items in parallel with bounded width; results keep the input order.
    @concurrent
    public static func measureAll(_ urls: [URL], width: Int = 6) async -> [SizeResult] {
        guard !urls.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, SizeResult).self) { group in
            var results = Array(repeating: SizeResult.zero, count: urls.count)
            var next = 0
            func addNext() {
                let index = next
                next += 1
                group.addTask { (index, measure(urls[index])) }
            }
            for _ in 0..<min(width, urls.count) { addNext() }
            for await (index, result) in group {
                results[index] = result
                if next < urls.count, !Task.isCancelled { addNext() }
            }
            return results
        }
    }

    private struct InodeKey: Hashable {
        let device: dev_t
        let inode: ino_t
    }
}

/// Thin Swift wrapper over `fts_open` / `fts_read`.
enum FTSWalker {
    enum Kind {
        case file, symlink, directory, other
        case unreadableDirectory(errno: Int32)
    }

    struct Entry {
        let path: String
        let kind: Kind
        let depth: Int
        let stat: stat?
    }

    enum Decision { case proceed, skipChildren, stop }

    static func walk(root: String, _ visit: (Entry) -> Decision) {
        root.withCString { cRoot in
            guard let copy = strdup(cRoot) else { return }
            defer { free(copy) }
            var paths: [UnsafeMutablePointer<CChar>?] = [copy, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
            defer { fts_close(fts) }

            while let pointer = fts_read(fts) {
                let ent = pointer.pointee
                let info = Int32(ent.fts_info)
                let kind: Kind
                switch info {
                case FTS_F: kind = .file
                case FTS_SL, FTS_SLNONE: kind = .symlink
                case FTS_D: kind = .directory
                case FTS_DP: continue // post-order visit of a directory; already handled
                case FTS_DNR: kind = .unreadableDirectory(errno: ent.fts_errno)
                case FTS_ERR, FTS_NS:
                    // A root we can't stat because of permissions is still a "blocked" folder.
                    if AccessCheck.isPermissionErrno(ent.fts_errno) {
                        kind = .unreadableDirectory(errno: ent.fts_errno)
                    } else {
                        continue
                    }
                default: kind = .other
                }
                let path = String(cString: ent.fts_path)
                let stat = ent.fts_statp.map(\.pointee)
                switch visit(Entry(path: path, kind: kind, depth: Int(ent.fts_level), stat: stat)) {
                case .proceed: break
                case .skipChildren: fts_set(fts, pointer, FTS_SKIP)
                case .stop: return
                }
            }
        }
    }
}
