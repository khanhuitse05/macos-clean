import Foundation

/// Curated junk-path database for popular apps (`app_junk_db.json`, port of the reference `appdb.rs`).
///
/// - `leftovers`: extra paths removed together with an app when it is uninstalled.
/// - `safeCaches`: paths safe to clear while the app stays installed (powers "App Caches").
///
/// Paths support `~` and single-component `*` globs (`…/Chrome/*/Code Cache`).
public struct JunkDatabase: Sendable {
    public struct App: Decodable, Sendable {
        public let name: String
        /// Exact bundle id, exact app name (case-insensitive), or bundle-id prefix ending in `*`.
        public let match: [String]
        /// `[category, path]` pairs. Category is logs | preferences | caches | supporting.
        public let leftovers: [[String]]
        public let safeCaches: [String]

        enum CodingKeys: String, CodingKey {
            case name, match, leftovers
            case safeCaches = "safe_caches"
        }

        public init(name: String, match: [String], leftovers: [[String]] = [], safeCaches: [String] = []) {
            self.name = name
            self.match = match
            self.leftovers = leftovers
            self.safeCaches = safeCaches
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            match = try container.decodeIfPresent([String].self, forKey: .match) ?? []
            leftovers = try container.decodeIfPresent([[String]].self, forKey: .leftovers) ?? []
            safeCaches = try container.decodeIfPresent([String].self, forKey: .safeCaches) ?? []
        }

        public func matches(bundleID: String, name appName: String) -> Bool {
            match.contains { key in
                if key.hasSuffix("*") {
                    let prefix = key.dropLast()
                    return !prefix.isEmpty && bundleID.lowercased().hasPrefix(prefix.lowercased())
                }
                return key.caseInsensitiveCompare(bundleID) == .orderedSame
                    || key.caseInsensitiveCompare(appName) == .orderedSame
            }
        }
    }

    private struct File: Decodable { let apps: [App] }

    public let apps: [App]

    public init(apps: [App]) { self.apps = apps }

    public init(data: Data) throws {
        apps = try JSONDecoder().decode(File.self, from: data).apps
    }

    /// The database shipped inside this package.
    public static let bundled: JunkDatabase = {
        guard let url = Bundle.module.url(forResource: "app_junk_db", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let database = try? JunkDatabase(data: data)
        else { return JunkDatabase(apps: []) }
        return database
    }()

    /// Curated leftover paths (that exist) for an app being uninstalled. Includes its safe caches,
    /// which are junk by definition once the app is gone.
    public func extraLeftovers(bundleID: String, name: String, expander: PathExpander) -> [(LeftoverKind, URL)] {
        var result: [(LeftoverKind, URL)] = []
        for app in apps where app.matches(bundleID: bundleID, name: name) {
            for pair in app.leftovers where pair.count == 2 {
                let kind = LeftoverKind(rawValue: pair[0]) ?? .supporting
                for url in Self.globExpand(pair[1], expander: expander) {
                    result.append((kind == .binaries ? .supporting : kind, url))
                }
            }
            for pattern in app.safeCaches {
                for url in Self.globExpand(pattern, expander: expander) {
                    result.append((.caches, url))
                }
            }
        }
        return result
    }

    /// Every existing safe-cache path across the database, deduped, in database order.
    public func safeCacheEntries(expander: PathExpander) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for app in apps {
            for pattern in app.safeCaches {
                for url in Self.globExpand(pattern, expander: expander) where seen.insert(url.path).inserted {
                    result.append(url)
                }
            }
        }
        return result
    }

    /// Case-insensitive match where `*` matches any run of characters.
    public static func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())
        var pi = 0, ti = 0
        var starIndex: Int?
        var matchIndex = 0
        while ti < t.count {
            if pi < p.count, p[pi] != "*", p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starIndex = pi; matchIndex = ti; pi += 1
            } else if let star = starIndex {
                pi = star + 1; matchIndex += 1; ti = matchIndex
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Expands `~` and single-component `*` globs into existing paths.
    public static func globExpand(_ pattern: String, expander: PathExpander) -> [URL] {
        let expanded = expander.expand(pattern).path
        var frontier = ["/"]
        for component in (expanded as NSString).pathComponents where component != "/" {
            if component.contains("*") {
                frontier = frontier.flatMap { base -> [String] in
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                    return names.sorted()
                        .filter { wildcardMatch(component, $0) }
                        .map { (base as NSString).appendingPathComponent($0) }
                }
            } else {
                frontier = frontier.map { ($0 as NSString).appendingPathComponent(component) }
            }
            if frontier.isEmpty { break }
        }
        return frontier
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
