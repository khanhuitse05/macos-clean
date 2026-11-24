import CoreServices
import Foundation

/// A folder that changed on disk, from FSEvents.
public struct FileSystemChange: Sendable, Equatable {
    public let path: String
    /// FSEvents dropped detail (too many events, or a volume/root change): everything under
    /// `path` may have changed, not just its direct children.
    public let mustScanSubfolders: Bool

    public init(path: String, mustScanSubfolders: Bool) {
        self.path = path
        self.mustScanSubfolders = mustScanSubfolders
    }
}

/// Watches folder trees with FSEvents and reports which folders changed, coalesced over
/// `latency`. Changes made by this process (moving items to the Trash) are ignored; callers
/// update their own state for those.
public final class FileSystemWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([FileSystemChange]) -> Void

    public let paths: [String]
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.goldenowl.macos-clean.fsevents", qos: .utility)
    // Only touched on `queue`.
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: TimeInterval = 2, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit {
        // Synchronous on `queue`, so no callback can still be using `self` afterwards.
        stop()
    }

    public func start() {
        queue.sync {
            guard stream == nil, !paths.isEmpty else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagNoDefer
            )
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault, Self.callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
            ) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(rawPaths, to: NSArray.self)
        var changes: [FileSystemChange] = []
        changes.reserveCapacity(count)
        let rescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
        )
        for index in 0..<count {
            guard var path = paths[index] as? String else { continue }
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            changes.append(FileSystemChange(path: path, mustScanSubfolders: rawFlags[index] & rescan != 0))
        }
        if !changes.isEmpty { watcher.handler(changes) }
    }
}
