import Foundation

/// A set of selected paths that answers the questions a file tree UI asks on every row in O(1)
/// (or O(depth)) instead of scanning the whole selection:
///
/// - is this path selected? (``contains(_:)``)
/// - is anything inside this folder selected? (``hasSelectedDescendant(_:)``)
/// - which selected paths are not covered by a selected ancestor? (``units``, the same set
///   ``PathDeduper/dedupe(_:)`` returns, kept up to date incrementally)
///
/// Paths must be absolute and standardized (no trailing slash, no `.`/`..`).
public struct PathSelection: Sendable, Equatable {
    public private(set) var paths: Set<String> = []
    /// Selected paths with no selected ancestor: what a trash operation acts on.
    public private(set) var units: Set<String> = []
    /// For each ancestor folder of a selected path, how many selected paths lie under it.
    private var descendantCounts: [String: Int] = [:]

    public init() {}

    public init<S: Sequence>(_ paths: S) where S.Element == String {
        formUnion(paths)
    }

    public var isEmpty: Bool { paths.isEmpty }
    public var count: Int { paths.count }

    public func contains(_ path: String) -> Bool { paths.contains(path) }

    public func hasSelectedDescendant(_ path: String) -> Bool { (descendantCounts[path] ?? 0) > 0 }

    public func hasSelectedAncestor(_ path: String) -> Bool {
        var found = false
        Self.forEachAncestor(of: path) { ancestor in
            if paths.contains(ancestor) { found = true }
            return !found
        }
        return found
    }

    public mutating func insert(_ path: String) {
        guard paths.insert(path).inserted else { return }
        Self.forEachAncestor(of: path) { ancestor in
            descendantCounts[ancestor, default: 0] += 1
            return true
        }
        guard !hasSelectedAncestor(path) else { return }
        // Units inside this folder are now covered by it.
        if hasSelectedDescendant(path) {
            let prefix = path + "/"
            units = units.filter { !$0.hasPrefix(prefix) }
        }
        units.insert(path)
    }

    public mutating func remove(_ path: String) {
        guard paths.remove(path) != nil else { return }
        Self.forEachAncestor(of: path) { ancestor in
            if let count = descendantCounts[ancestor], count > 1 {
                descendantCounts[ancestor] = count - 1
            } else {
                descendantCounts[ancestor] = nil
            }
            return true
        }
        guard units.remove(path) != nil, hasSelectedDescendant(path) else { return }
        // Selected paths inside it that nothing else covers become units of their own.
        let prefix = path + "/"
        for candidate in paths where candidate.hasPrefix(prefix) && !hasSelectedAncestor(candidate) {
            units.insert(candidate)
        }
    }

    public mutating func formUnion<S: Sequence>(_ other: S) where S.Element == String {
        for path in other { insert(path) }
    }

    public mutating func subtract<S: Sequence>(_ other: S) where S.Element == String {
        for path in other { remove(path) }
    }

    public mutating func removeAll() {
        paths.removeAll()
        units.removeAll()
        descendantCounts.removeAll()
    }

    /// Keeps only the paths `isIncluded` accepts.
    public mutating func keepOnly(where isIncluded: (String) -> Bool) {
        let dropped = paths.filter { !isIncluded($0) }
        if dropped.count == paths.count {
            removeAll()
        } else {
            subtract(dropped)
        }
    }

    /// Calls `body` with each ancestor of `path`, nearest first, until it returns false.
    public static func forEachAncestor(of path: String, _ body: (String) -> Bool) {
        var end = path.endIndex
        while let slash = path[path.startIndex..<end].lastIndex(of: "/") {
            let ancestor = slash == path.startIndex ? "/" : String(path[path.startIndex..<slash])
            if ancestor == path { return }
            guard body(ancestor) else { return }
            if slash == path.startIndex { return }
            end = slash
        }
    }
}
