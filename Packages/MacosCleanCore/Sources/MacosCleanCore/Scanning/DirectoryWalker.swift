import Darwin
import Foundation

/// Fast recursive directory walker built on `getattrlistbulk(2)`.
///
/// One system call returns the name, type, allocated size, link count, inode and modification
/// time of hundreds of entries at once, so there's no per-file `lstat` and no path lookup per
/// file. Swift strings are only built for folders and for entries a visitor asks for, which
/// keeps the per-file cost to a few loads from a buffer.
///
/// Order of events for each folder: ``Visitor/enter(_:depth:)``, then ``Visitor/visit(_:)`` for
/// every entry in it, then the same recursively for each subfolder the visitor kept, then
/// ``Visitor/leave(_:depth:)``. Never follows symlinks. Falls back to `readdir` + `fstatat` on
/// file systems that don't support bulk attributes.
struct DirectoryWalker {
    enum Kind: Equatable { case file, directory, symlink, other }

    enum Decision { case proceed, skipChildren, stop }

    /// One directory entry. `nameBytes` points into the walker's buffer and is only valid
    /// during the ``Visitor/visit(_:)`` call.
    struct Entry {
        let parentPath: String
        let nameBytes: UnsafeBufferPointer<UInt8>
        let kind: Kind
        /// Bytes allocated on disk (all forks); 0 for folders.
        let allocatedSize: Int64
        let linkCount: UInt32
        let device: Int32
        let inode: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        /// Depth below the walk root: the root's children are at depth 1.
        let depth: Int

        var name: String { String(decoding: nameBytes, as: UTF8.self) }
        var path: String { DirectoryWalker.join(parentPath, name) }
        var modified: Date {
            Date(timeIntervalSince1970: TimeInterval(modifiedSeconds) + TimeInterval(modifiedNanoseconds) / 1e9)
        }
        var isRegularMultiLink: Bool { kind == .file && linkCount > 1 }
    }

    protocol Visitor {
        /// A folder is about to be read. The root arrives at depth 0.
        mutating func enter(_ path: String, depth: Int)
        /// Return `.skipChildren` for a folder to keep the walker out of it.
        mutating func visit(_ entry: borrowing Entry) -> Decision
        /// A folder (or the root) macOS refused to open or read.
        mutating func denied(_ path: String, errno: Int32, depth: Int)
        /// Every entry of the folder and its kept subfolders has been visited.
        mutating func leave(_ path: String, depth: Int)
    }

    static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// Walks the folder at `root`. Returns false if the visitor stopped the walk.
    @discardableResult
    static func walk<V: Visitor>(root: String, visitor: inout V) -> Bool {
        var walker = DirectoryWalker()
        defer { walker.buffer.deallocate() }
        var normalized = root
        while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        return walker.walkDirectory(normalized, depth: 0, parentDevice: nil, visitor: &visitor)
    }

    /// File systems the walker never crosses into from a parent on another device: network
    /// shares, devices exposed as folders (a connected iPhone under
    /// ~/Library/Developer/CoreDevice/DeviceFS), FUSE and auto-mounts. Reading them is slow
    /// (often over USB or the network) and nothing in them is this Mac's disk usage.
    static let foreignFileSystems: Set<String> = [
        "devfs", "devicefs", "autofs", "nfs", "smbfs", "afpfs", "webdav", "ftp", "cddafs",
        "macfuse", "osxfuse", "fuse-t", "fusefs",
    ]

    /// `SF_DATALESS`: a cloud placeholder (iCloud Drive, File Provider). Its contents aren't on
    /// disk, and listing them can make the provider download the listing.
    static let datalessFlag: UInt32 = 0x4000_0000

    static func isForeignMount(_ fd: Int32) -> Bool {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { return false }
        if info.f_flags & UInt32(MNT_LOCAL) == 0 { return true }
        let type = withUnsafeBytes(of: &info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return foreignFileSystems.contains(type)
    }

    // MARK: - Implementation

    private static let bufferSize = 256 * 1024
    private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16)

    private struct Pending {
        let path: String
    }

    /// Reads one folder completely (closing it right away so deep trees never pile up open
    /// descriptors), then descends into the subfolders the visitor kept.
    private mutating func walkDirectory<V: Visitor>(
        _ path: String, depth: Int, parentDevice: dev_t?, visitor: inout V
    ) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            if AccessCheck.isPermissionErrno(code) { visitor.denied(path, errno: code, depth: depth) }
            return true
        }
        var info = stat()
        let device = fstat(fd, &info) == 0 ? info.st_dev : (parentDevice ?? 0)
        visitor.enter(path, depth: depth)
        // A mount point inside the tree: report it as an empty folder unless it's local disk.
        if let parentDevice, device != parentDevice, Self.isForeignMount(fd) {
            close(fd)
            visitor.leave(path, depth: depth)
            return true
        }
        var subfolders: [Pending] = []
        let outcome = readEntries(fd: fd, path: path, depth: depth, subfolders: &subfolders, visitor: &visitor)
        close(fd)
        switch outcome {
        case .stopped:
            return false
        case .failed(let code):
            if AccessCheck.isPermissionErrno(code) { visitor.denied(path, errno: code, depth: depth) }
        case .finished:
            break
        }
        for sub in subfolders {
            guard walkDirectory(sub.path, depth: depth + 1, parentDevice: device, visitor: &visitor) else { return false }
        }
        visitor.leave(path, depth: depth)
        return true
    }

    private enum ReadOutcome { case finished, stopped, failed(Int32) }

    private func readEntries<V: Visitor>(
        fd: Int32, path: String, depth: Int, subfolders: inout [Pending], visitor: inout V
    ) -> ReadOutcome {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_DEVID)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(truncatingIfNeeded: ATTR_FILE_LINKCOUNT)
            | attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)

        let childDepth = depth + 1
        while true {
            let count = getattrlistbulk(fd, &request, buffer.baseAddress, buffer.count, 0)
            if count == 0 { return .finished }
            if count < 0 {
                let code = errno
                if code == ENOTSUP || code == EINVAL {
                    return readEntriesFallback(fd: fd, path: path, depth: depth, subfolders: &subfolders, visitor: &visitor)
                }
                if code == EINTR { continue }
                return .failed(code)
            }
            var cursor = buffer.baseAddress!
            for _ in 0..<count {
                let entryStart = cursor
                let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                cursor = entryStart + MemoryLayout<UInt32>.size
                defer { cursor = entryStart + length }

                let returned = cursor.loadUnaligned(as: attribute_set_t.self)
                cursor += MemoryLayout<attribute_set_t>.size

                var entryError: UInt32 = 0
                if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR) != 0 {
                    entryError = cursor.loadUnaligned(as: UInt32.self)
                    cursor += MemoryLayout<UInt32>.size
                }

                var nameBytes = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
                if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME) != 0 {
                    let reference = cursor.loadUnaligned(as: attrreference_t.self)
                    let start = (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
                    // attr_length counts the terminating NUL.
                    nameBytes = UnsafeBufferPointer(start: start, count: max(0, Int(reference.attr_length) - 1))
                    cursor += MemoryLayout<attrreference_t>.size
                }
                var device: Int32 = 0
                if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_DEVID) != 0 {
                    device = cursor.loadUnaligned(as: Int32.self)
                    cursor += MemoryLayout<dev_t>.size
                }
                var objectType: UInt32 = 0
                if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE) != 0 {
                    objectType = cursor.loadUnaligned(as: UInt32.self)
                    cursor += MemoryLayout<fsobj_type_t>.size
                }
                var modified = timespec()
                if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME) != 0 {
                    modified = cursor.loadUnaligned(as: timespec.self)
                    cursor += MemoryLayout<timespec>.size
                }
                var flags: UInt32 = 0
                if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS) != 0 {
                    flags = cursor.loadUnaligned(as: UInt32.self)
                    cursor += MemoryLayout<UInt32>.size
                }
                var inode: UInt64 = 0
                if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_FILEID) != 0 {
                    inode = cursor.loadUnaligned(as: UInt64.self)
                    cursor += MemoryLayout<UInt64>.size
                }
                var linkCount: UInt32 = 1
                if returned.fileattr & attrgroup_t(truncatingIfNeeded: ATTR_FILE_LINKCOUNT) != 0 {
                    linkCount = cursor.loadUnaligned(as: UInt32.self)
                    cursor += MemoryLayout<UInt32>.size
                }
                var allocated: Int64 = 0
                if returned.fileattr & attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE) != 0 {
                    allocated = cursor.loadUnaligned(as: Int64.self)
                    cursor += MemoryLayout<off_t>.size
                }

                guard nameBytes.count > 0 else { continue }
                let kind: Kind = switch objectType {
                case UInt32(VREG.rawValue): .file
                case UInt32(VDIR.rawValue): .directory
                case UInt32(VLNK.rawValue): .symlink
                default: .other
                }
                if entryError != 0 {
                    // Couldn't read this entry's attributes. Only a blocked folder is worth reporting.
                    if AccessCheck.isPermissionErrno(Int32(entryError)) {
                        let name = String(decoding: nameBytes, as: UTF8.self)
                        visitor.denied(Self.join(path, name), errno: Int32(entryError), depth: childDepth)
                    }
                    continue
                }
                let entry = Entry(
                    parentPath: path, nameBytes: nameBytes, kind: kind,
                    allocatedSize: kind == .directory ? 0 : allocated,
                    linkCount: linkCount, device: device, inode: inode,
                    modifiedSeconds: modified.tv_sec, modifiedNanoseconds: modified.tv_nsec,
                    depth: childDepth
                )
                switch visitor.visit(entry) {
                case .stop: return .stopped
                case .skipChildren: break
                case .proceed:
                    guard kind == .directory else { break }
                    if flags & Self.datalessFlag == 0 {
                        subfolders.append(Pending(path: entry.path))
                    } else {
                        // Cloud placeholder: an empty folder as far as this disk is concerned.
                        let childPath = entry.path
                        visitor.enter(childPath, depth: childDepth)
                        visitor.leave(childPath, depth: childDepth)
                    }
                }
            }
        }
    }

    /// `readdir` + `fstatat` for file systems without `getattrlistbulk` support.
    private func readEntriesFallback<V: Visitor>(
        fd: Int32, path: String, depth: Int, subfolders: inout [Pending], visitor: inout V
    ) -> ReadOutcome {
        let dupFD = dup(fd)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else {
            if dupFD >= 0 { close(dupFD) }
            return .failed(errno)
        }
        defer { closedir(dir) }
        let childDepth = depth + 1
        while let item = readdir(dir) {
            let nameLength = Int(item.pointee.d_namlen)
            let decision: Decision? = withUnsafeBytes(of: &item.pointee.d_name) { raw -> Decision? in
                let bytes = UnsafeBufferPointer(start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: nameLength)
                if (nameLength == 1 && bytes[0] == 0x2E) || (nameLength == 2 && bytes[0] == 0x2E && bytes[1] == 0x2E) {
                    return nil
                }
                var info = stat()
                guard fstatat(fd, raw.baseAddress!.assumingMemoryBound(to: CChar.self), &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    return nil
                }
                let kind: Kind = switch info.st_mode & S_IFMT {
                case S_IFREG: .file
                case S_IFDIR: .directory
                case S_IFLNK: .symlink
                default: .other
                }
                let entry = Entry(
                    parentPath: path, nameBytes: bytes, kind: kind,
                    allocatedSize: kind == .directory ? 0 : Int64(info.st_blocks) * 512,
                    linkCount: UInt32(info.st_nlink), device: info.st_dev, inode: info.st_ino,
                    modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                    depth: childDepth
                )
                let decision = visitor.visit(entry)
                if decision == .proceed, kind == .directory { subfolders.append(Pending(path: entry.path)) }
                return decision
            }
            if decision == .stop { return .stopped }
        }
        return .finished
    }
}

extension DirectoryWalker {
    /// One child from ``children(of:)``, with its attributes copied out of the walker buffer.
    struct Child {
        let path: String
        let name: String
        let kind: Kind
        let allocatedSize: Int64
        let modified: Date
    }

    struct Listing {
        var children: [Child] = []
        /// errno when the folder itself couldn't be opened or read.
        var error: Int32?
    }

    /// The direct children of a folder, without descending.
    static func children(of path: String) -> Listing {
        struct Collector: Visitor {
            var listing = Listing()
            func enter(_ path: String, depth: Int) {}
            func leave(_ path: String, depth: Int) {}
            mutating func denied(_ path: String, errno: Int32, depth: Int) {
                if depth == 0 { listing.error = errno }
            }
            mutating func visit(_ entry: borrowing Entry) -> Decision {
                let name = entry.name
                listing.children.append(Child(
                    path: DirectoryWalker.join(entry.parentPath, name), name: name, kind: entry.kind,
                    allocatedSize: entry.allocatedSize, modified: entry.modified
                ))
                return .skipChildren
            }
        }
        var collector = Collector()
        walk(root: path, visitor: &collector)
        return collector.listing
    }
}
