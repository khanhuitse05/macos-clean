import Foundation

/// Folders the user never wants scanned or suggested for cleaning.
///
/// Paths are stored absolute and standardized (no `~`, no trailing slash). Every check is
/// O(depth) at most, so walkers can afford it per folder.
public struct ExclusionList: Sendable, Equatable, Hashable {
    public private(set) var paths: Set<String>

    public static let empty = ExclusionList()

    public init<S: Sequence>(_ paths: S = [String](), expander: PathExpander = PathExpander()) where S.Element == String {
        self.paths = Set(paths.compactMap { Self.normalize($0, expander: expander) })
    }

    public var isEmpty: Bool { paths.isEmpty }

    /// `~/Foo/` → `/Users/me/Foo`. Nil for an empty or relative path.
    public static func normalize(_ path: String, expander: PathExpander = PathExpander()) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") else { return nil }
        let expanded = expander.expand(trimmed).standardizedFileURL.path
        guard expanded.hasPrefix("/") else { return nil }
        var result = expanded
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result == "/" ? nil : result
    }

    /// The folder itself is excluded (no ancestor check): what a walker asks per folder, since
    /// it never descends into an excluded one.
    public func contains(folder path: String) -> Bool { paths.contains(path) }

    /// `path` is excluded, or lies inside an excluded folder.
    public func isExcluded(_ path: String) -> Bool {
        guard !paths.isEmpty else { return false }
        if paths.contains(path) { return true }
        var found = false
        PathSelection.forEachAncestor(of: path) { ancestor in
            found = paths.contains(ancestor)
            return !found
        }
        return found
    }

    /// `path` is excluded, inside an excluded folder, or **contains** one. Removing such a path
    /// would take an excluded folder with it, so it is never suggested.
    public func overlaps(_ path: String) -> Bool {
        guard !paths.isEmpty else { return false }
        if isExcluded(path) { return true }
        let prefix = path == "/" ? "/" : path + "/"
        return paths.contains { $0.hasPrefix(prefix) }
    }

    /// The same list without exclusions that contain `root` (or equal it): when the user picks
    /// a folder to scan on purpose, an exclusion around it does not apply.
    public func applying(toRoot root: String) -> ExclusionList {
        guard !paths.isEmpty else { return self }
        var copy = self
        copy.paths = paths.filter { excluded in
            !(root == excluded || root.hasPrefix(excluded + "/"))
        }
        return copy
    }

    /// Drops entries that overlap an exclusion.
    public func filter(_ entries: [FileEntry]) -> [FileEntry] {
        guard !paths.isEmpty else { return entries }
        return entries.filter { !overlaps($0.path) }
    }
}
