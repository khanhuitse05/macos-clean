import Foundation

/// Permanently removes one item. A protocol so tests never delete real files.
public protocol Removing: Sendable {
    func remove(_ url: URL) throws
}

public struct FileManagerRemover: Removing {
    public init() {}

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Empties the Trash, all of it or picked items. The only code path in the app that deletes
/// permanently, and it only ever touches items inside the Trash folder.
public struct TrashEmptier: Sendable {
    public static let refusalMessage = "Only items inside the Trash can be deleted permanently."

    /// The current user's Trash (`~/.Trash`).
    public static var userTrashURL: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true)
    }

    public let trashURL: URL
    private let root: String
    private let remover: any Removing
    private let measuresSize: Bool

    public init(trashURL: URL = TrashEmptier.userTrashURL, remover: any Removing = FileManagerRemover(), measuresSize: Bool = true) {
        self.trashURL = trashURL
        self.root = trashURL.standardizedFileURL.resolvingSymlinksInPath().path
        self.remover = remover
        self.measuresSize = measuresSize
    }

    /// Top-level items in the Trash, without Finder's `.DS_Store`.
    public func contents() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil, options: [])
            .filter { $0.lastPathComponent != ".DS_Store" }
    }

    /// Why `path` may not be deleted permanently, or nil when it may: it must be strictly inside
    /// the Trash, reached without following a symlink out of it.
    public func refusalReason(for path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Resolve the parent only: an item that is itself a symlink is removed as a link.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "..", name != "." else { return Self.refusalMessage }
        guard parent == root || parent.hasPrefix(root + "/") else { return Self.refusalMessage }
        return nil
    }

    /// Deletes `paths` (or, when nil, everything in the Trash) in the background, reporting
    /// progress after each item.
    ///
    /// - Throws: ``CleanerError/confirmationRequired`` — before touching anything — unless `confirm` is true.
    public func erase(_ paths: [String]?, confirm: Bool) throws -> AsyncStream<CleanEvent> {
        guard confirm else { throw CleanerError.confirmationRequired }
        let items = try paths.map(PathDeduper.dedupe) ?? contents().map(\.path)
        let emptier = self
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var outcomes: [DeleteOutcome] = []
                var freed: Int64 = 0
                continuation.yield(.progress(CleanProgress(current: 0, total: items.count, path: "", bytesFreed: 0, succeeded: 0, failed: 0)))
                for (index, path) in items.enumerated() {
                    // Cancelling stops before the next item; items already deleted are gone.
                    if Task.isCancelled { break }
                    let outcome = emptier.eraseOne(path)
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

    func eraseOne(_ path: String) -> DeleteOutcome {
        if let reason = refusalReason(for: path) {
            return DeleteOutcome(path: path, success: false, error: reason)
        }
        let url = URL(fileURLWithPath: path)
        let bytes = measuresSize ? SizeCalculator.allocatedSize(of: url) : 0
        do {
            try remover.remove(url)
            return DeleteOutcome(path: path, success: true, bytes: bytes)
        } catch {
            return DeleteOutcome(path: path, success: false, error: Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError {
            return "The item is locked or you don't have permission to delete it."
        }
        return error.localizedDescription
    }
}
