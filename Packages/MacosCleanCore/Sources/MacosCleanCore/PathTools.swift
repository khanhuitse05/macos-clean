import Foundation

/// Expands `~`, `$VAR` and `${VAR}` in category paths. Home and environment are injected so tests
/// never depend on the real machine.
public struct PathExpander: Sendable {
    public let home: String
    public let environment: [String: String]

    public init(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.home = home
        self.environment = environment
    }

    public func expand(_ path: String) -> URL {
        var result = path
        if result == "~" {
            result = home
        } else if result.hasPrefix("~/") {
            result = home + String(result.dropFirst(1))
        }
        result = expandVariables(in: result)
        return URL(fileURLWithPath: result)
    }

    private func expandVariables(in string: String) -> String {
        string.replacing(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/) { match in
            let name = String(match.output.1 ?? match.output.2 ?? "")
            // Unknown variables are left untouched rather than silently becoming "".
            return environment[name] ?? String(match.output.0)
        }
    }
}

/// Collapses a selection so an ancestor path swallows its descendants. Without this, trashing a
/// folder and then a file inside it would report a spurious failure for the second one.
public enum PathDeduper {
    public static func dedupe(_ paths: [String]) -> [String] {
        func components(_ path: String) -> [String] {
            URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        }

        let entries = paths.map { (original: $0, parts: components($0)) }
        var kept: [(original: String, parts: [String])] = []

        // Shortest paths first so every ancestor is considered before its descendants.
        for entry in entries.sorted(by: { $0.parts.count < $1.parts.count }) {
            let covered = kept.contains { ancestor in
                entry.parts.count >= ancestor.parts.count
                    && Array(entry.parts.prefix(ancestor.parts.count)) == ancestor.parts
            }
            if !covered { kept.append(entry) }
        }

        // Preserve the caller's order.
        let survivors = Set(kept.map(\.original))
        var seen = Set<String>()
        return paths.filter { survivors.contains($0) && seen.insert($0).inserted }
    }
}
