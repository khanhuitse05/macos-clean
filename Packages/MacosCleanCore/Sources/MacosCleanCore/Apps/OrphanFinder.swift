import Foundation

/// Files in `~/Library` named after a bundle identifier that no app on this Mac has: most
/// likely left behind by an app deleted some time ago.
public struct OrphanApp: Identifiable, Hashable, Sendable, Codable {
    /// The identifier the files are named after, as found on disk.
    public let bundleID: String
    /// Absolute paths, deduped (none inside another).
    public let paths: [String]
    public let bytes: Int64

    public init(bundleID: String, paths: [String], bytes: Int64) {
        self.bundleID = bundleID
        self.paths = paths
        self.bytes = bytes
    }

    public var id: String { bundleID }
}

/// Finds ``OrphanApp``s. Deliberately conservative: anything that might belong to an app that
/// is still installed, or to its developer's other apps, is left out.
public struct OrphanFinder: Sendable {
    public let expander: PathExpander
    public let exclusions: ExclusionList

    /// First components a bundle identifier normally starts with.
    static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "app", "dev", "co", "me", "de", "uk", "fr", "jp", "cn", "ru", "nl",
        "ch", "se", "at", "it", "es", "ca", "au", "us", "info", "biz", "tv", "cc", "ly", "ai", "so",
        "sh", "xyz", "to", "im", "is", "eu", "pro", "studio", "tech", "fm", "be", "dk", "no", "pl",
    ]

    /// Folders only apps write to. Command-line tools (SwiftPM, Carthage, linters) leave caches
    /// and logs named like bundle identifiers too; a group needs one of these to count as an app.
    static let appFootprintFolders: Set<String> = [
        "Preferences", "Saved Application State", "Containers", "Group Containers",
        "Application Scripts", "HTTPStorages", "WebKit", "Cookies", "LaunchAgents",
    ]

    /// Identifier namespaces that belong to macOS itself.
    static let systemPrefixes = ["com.apple.", "systemgroup.", "com.crashreporter."]

    public init(expander: PathExpander = PathExpander(), exclusions: ExclusionList = .empty) {
        self.expander = expander
        self.exclusions = exclusions
    }

    /// - Parameters:
    ///   - installed: every installed app.
    ///   - isKnownApp: true when an app with this identifier exists anywhere on the Mac (Launch Services).
    ///   - ignoring: identifiers not to report (already listed, or dismissed by the user). Case-insensitive.
    @concurrent
    public func find(
        installed: InstalledAppIndex,
        isKnownApp: @Sendable (String) -> Bool = { _ in false },
        ignoring: Set<String> = []
    ) async -> [OrphanApp] {
        let library = (expander.home as NSString).appendingPathComponent("Library")
        let ignored = Set(ignoring.map { $0.lowercased() })

        // Identifier (lowercased) → its spelling on disk and the paths named after it.
        var found: [String: (spelling: String, paths: [String])] = [:]
        var footprint = Set<String>()
        for folder in LeftoverScanner.libraryFolders.keys.sorted() {
            let base = (library as NSString).appendingPathComponent(folder)
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            for child in children where !child.hasPrefix(".") {
                let id = LeftoverScanner.identifier(fromComponent: child, in: folder)
                guard Self.looksLikeBundleID(id) else { continue }
                let path = (base as NSString).appendingPathComponent(child)
                guard !exclusions.overlaps(path) else { continue }
                found[id.lowercased(), default: (id, [])].paths.append(path)
                if Self.appFootprintFolders.contains(folder) { footprint.insert(id.lowercased()) }
            }
        }

        // An app's helpers ("<id>.helper") are grouped under the shortest identifier found.
        var groups: [String: (spelling: String, paths: [String])] = [:]
        var groupFootprint = Set<String>()
        for key in found.keys.sorted(by: { $0.count < $1.count }) {
            let entry = found[key]!
            let root = Self.root(of: key, among: groups.keys) ?? key
            if groups[root] == nil { groups[root] = entry } else { groups[root]!.paths += entry.paths }
            if footprint.contains(key) { groupFootprint.insert(root) }
        }

        var candidates: [(String, [String])] = []
        for (key, entry) in groups {
            guard groupFootprint.contains(key),
                  !ignored.contains(key),
                  !Self.systemPrefixes.contains(where: key.hasPrefix),
                  !installed.claims(key),
                  !installed.sharesVendor(with: key),
                  !Self.namespacePrefixes(of: entry.spelling).contains(where: isKnownApp)
            else { continue }
            candidates.append((entry.spelling, PathDeduper.dedupe(entry.paths).sorted()))
        }

        let sizes = await SizeCalculator.measureAll(candidates.flatMap { $0.1.map { URL(fileURLWithPath: $0) } })
        var index = 0
        var result: [OrphanApp] = []
        for (id, paths) in candidates {
            let bytes = sizes[index..<index + paths.count].reduce(0) { $0 + $1.bytes }
            index += paths.count
            if bytes > 0 { result.append(OrphanApp(bundleID: id, paths: paths, bytes: bytes)) }
        }
        return result.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.bundleID < $1.bundleID }
    }

    /// Reverse-DNS with at least three parts ("com.example.app"), starting with a known domain.
    static func looksLikeBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, topLevelDomains.contains(parts[0].lowercased()) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    /// The group an identifier belongs to: itself, or an identifier it extends ("<root>.helper").
    static func root<S: Sequence>(of key: String, among roots: S) -> String? where S.Element == String {
        roots.first { key == $0 || key.hasPrefix($0 + ".") }
    }

    /// The identifier and each shorter prefix that still has three parts, longest first.
    static func namespacePrefixes(of id: String) -> [String] {
        let parts = id.split(separator: ".")
        guard parts.count >= 3 else { return [id] }
        return (3...parts.count).reversed().map { parts.prefix($0).joined(separator: ".") }
    }
}
