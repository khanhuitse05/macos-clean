import Dispatch
import Foundation
import Synchronization

public enum CleanerError: Error, Equatable {
    /// `confirm` was false. Nothing was touched.
    case confirmationRequired
}

public struct DeleteOutcome: Sendable, Equatable {
    public let path: String
    public let success: Bool
    public let error: String?
    /// Bytes the item used before it was moved (0 when it failed).
    public let bytes: Int64

    public init(path: String, success: Bool, error: String? = nil, bytes: Int64 = 0) {
        self.path = path
        self.success = success
        self.error = error
        self.bytes = bytes
    }
}

public struct CleanProgress: Sendable, Equatable {
    public let current: Int
    public let total: Int
    public let path: String
    public let bytesFreed: Int64
    public let succeeded: Int
    public let failed: Int
}

public struct CleanSummary: Sendable, Equatable {
    public let outcomes: [DeleteOutcome]
    public init(outcomes: [DeleteOutcome]) { self.outcomes = outcomes }
    public var total: Int { outcomes.count }
    public var succeeded: Int { outcomes.count { $0.success } }
    public var failed: Int { outcomes.count { !$0.success } }
    public var bytesFreed: Int64 { outcomes.reduce(0) { $0 + $1.bytes } }
    public var trashedPaths: Set<String> { Set(outcomes.filter(\.success).map(\.path)) }
    public var failures: [DeleteOutcome] { outcomes.filter { !$0.success } }
}

public enum CleanEvent: Sendable, Equatable {
    case progress(CleanProgress)
    case finished(CleanSummary)
}

/// Moves one item to the Trash. A protocol so tests never touch the real Trash.
public protocol Trashing: Sendable {
    func trash(_ url: URL) throws
}

public struct FileManagerTrasher: Trashing {
    public init() {}

    /// `NSFileManager.trashItem` moves the item into the Trash of its volume. It never deletes.
    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Moves files to the Trash; it never deletes. Permanent deletion happens only in
/// ``TrashEmptier``, and only for items already in the Trash. Mirrors `move_to_trash` /
/// `clean_paths` in the reference `cleaner.rs`.
public struct Cleaner: Sendable {
    public static let refusalMessage = "Refusing to trash a protected path."

    private let trasher: any Trashing
    private let protectedExact: Set<String>
    private let protectedTrees: [String]
    private let itemTimeout: Duration
    private let measuresSize: Bool

    public init(
        trasher: any Trashing = FileManagerTrasher(),
        home: String = NSHomeDirectory(),
        ownBundlePath: String? = Bundle.main.bundlePath,
        itemTimeout: Duration = .seconds(20),
        measuresSize: Bool = true
    ) {
        func std(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        let home = std(home)
        func inHome(_ relative: String) -> String { std((home as NSString).appendingPathComponent(relative)) }

        self.trasher = trasher
        self.itemTimeout = itemTimeout
        self.measuresSize = measuresSize
        // These folders themselves are never trashed (their contents may be).
        self.protectedExact = [
            "/", "/Users", "/Applications", "/Library", "/System", "/private", "/usr", "/bin", "/sbin",
            "/opt", "/Volumes", home, inHome("Library"), inHome("Applications"), inHome("Desktop"),
            inHome("Documents"), inHome("Downloads"), inHome("Pictures"), inHome("Movies"), inHome("Music"),
            inHome(".Trash"), inHome("Library/Caches"), inHome("Library/Logs"),
            inHome("Library/Application Support"), inHome("Library/Preferences"),
        ]
        // Nothing inside these is ever touched: the read-only system, items already in the
        // Trash (moving them to the Trash does nothing; ``TrashEmptier`` deletes those), and
        // this app itself.
        var trees = ["/System", inHome(".Trash")]
        if let ownBundlePath, ownBundlePath.hasSuffix(".app") { trees.append(std(ownBundlePath)) }
        self.protectedTrees = trees
    }

    /// Why `path` may not be trashed, or nil when it may.
    public func refusalReason(for path: String) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if protectedExact.contains(standardized) { return Self.refusalMessage }
        for tree in protectedTrees where standardized == tree || standardized.hasPrefix(tree + "/") {
            return Self.refusalMessage
        }
        return nil
    }

    /// - Throws: ``CleanerError/confirmationRequired`` — before touching anything — unless `confirm` is true.
    public func moveToTrash(_ paths: [String], confirm: Bool) throws -> [DeleteOutcome] {
        guard confirm else { throw CleanerError.confirmationRequired }
        return PathDeduper.dedupe(paths).map(trashOne)
    }

    /// Moves `paths` to the Trash in the background, reporting progress after each item.
    ///
    /// - Throws: ``CleanerError/confirmationRequired`` — before touching anything — unless `confirm` is true.
    public func trash(_ paths: [String], confirm: Bool) throws -> AsyncStream<CleanEvent> {
        guard confirm else { throw CleanerError.confirmationRequired }
        let items = PathDeduper.dedupe(paths)
        let cleaner = self
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var outcomes: [DeleteOutcome] = []
                var freed: Int64 = 0
                continuation.yield(.progress(CleanProgress(current: 0, total: items.count, path: "", bytesFreed: 0, succeeded: 0, failed: 0)))
                for (index, path) in items.enumerated() {
                    // Cancelling stops before the next item; items already moved stay in the Trash.
                    if Task.isCancelled { break }
                    let outcome = await cleaner.trashOneWithTimeout(path)
                    outcomes.append(outcome)
                    freed += outcome.bytes
                    continuation.yield(.progress(CleanProgress(
                        current: index + 1, total: items.count, path: path, bytesFreed: freed,
                        succeeded: outcomes.count { $0.success }, failed: outcomes.count { !$0.success }
                    )))
                }
                continuation.yield(.finished(CleanSummary(outcomes: outcomes)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func trashOne(_ path: String) -> DeleteOutcome {
        if let reason = refusalReason(for: path) {
            return DeleteOutcome(path: path, success: false, error: reason)
        }
        let bytes = measuresSize ? SizeCalculator.allocatedSize(of: URL(fileURLWithPath: path)) : 0
        do {
            try trasher.trash(URL(fileURLWithPath: path))
            return DeleteOutcome(path: path, success: true, bytes: bytes)
        } catch {
            return DeleteOutcome(path: path, success: false, error: error.localizedDescription)
        }
    }

    /// A wedged item (locked file, dead network volume) is reported as failed after `itemTimeout`
    /// so it can't stall the whole batch.
    private func trashOneWithTimeout(_ path: String) async -> DeleteOutcome {
        let seconds = Double(itemTimeout.components.seconds) + Double(itemTimeout.components.attoseconds) / 1e18
        let once = Once()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = self.trashOne(path)
                if once.claim() { continuation.resume(returning: outcome) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() {
                    continuation.resume(returning: DeleteOutcome(
                        path: path, success: false,
                        error: "Timed out. The item may be locked, in use, or on an unresponsive volume."
                    ))
                }
            }
        }
    }
}

private final class Once: Sendable {
    private let claimed = Mutex(false)
    func claim() -> Bool {
        claimed.withLock { value in
            defer { value = true }
            return !value
        }
    }
}
