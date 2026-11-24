import Foundation

public enum CleanerError: Error, Equatable {
    /// `confirm` was false. Nothing was touched.
    case confirmationRequired
}

public struct DeleteOutcome: Sendable, Equatable {
    public let path: String
    public let success: Bool
    public let error: String?

    public init(path: String, success: Bool, error: String? = nil) {
        self.path = path
        self.success = success
        self.error = error
    }
}

/// Moves one item to the Trash. A protocol so tests never touch the real Trash.
public protocol Trashing: Sendable {
    func trash(_ url: URL) throws
}

public struct FileManagerTrasher: Trashing {
    public init() {}

    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// The only code path that removes files, and it only ever moves to the Trash — there is
/// deliberately no hard-delete. Mirrors `move_to_trash` / `clean_paths` in the reference `cleaner.rs`.
public struct Cleaner: Sendable {
    private let trasher: any Trashing
    private let protectedPaths: Set<String>

    public init(
        trasher: any Trashing = FileManagerTrasher(),
        home: String = NSHomeDirectory()
    ) {
        self.trasher = trasher
        self.protectedPaths = ["/", home]
    }

    /// - Throws: ``CleanerError/confirmationRequired`` — before touching anything — unless `confirm` is true.
    public func moveToTrash(_ paths: [String], confirm: Bool) throws -> [DeleteOutcome] {
        guard confirm else { throw CleanerError.confirmationRequired }

        return PathDeduper.dedupe(paths).map { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if protectedPaths.contains(standardized) {
                return DeleteOutcome(path: path, success: false, error: "Refusing to trash a protected path.")
            }
            do {
                try trasher.trash(URL(fileURLWithPath: path))
                return DeleteOutcome(path: path, success: true)
            } catch {
                return DeleteOutcome(path: path, success: false, error: error.localizedDescription)
            }
        }
    }
}
