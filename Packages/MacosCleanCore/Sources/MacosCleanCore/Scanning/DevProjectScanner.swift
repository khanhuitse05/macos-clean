import Foundation

/// Finds regenerable build output and dependency folders inside code projects under the home
/// folder. Port of `collect_dev_junk` in the reference `scanner.rs`.
///
/// Three confidence tiers:
/// - unmistakable names (`node_modules`, `__pycache__`, `DerivedData`, …) anywhere;
/// - project-scoped names (`target`, `_build`, `coverage`) only directly inside a project;
/// - ambiguous names (`build`, `dist`, `vendor`, …) only inside a project whose `.gitignore` ignores them.
public struct DevProjectScanner: Sendable {
    static let unmistakable: Set<String> = [
        "node_modules", "bower_components", ".next", ".nuxt", ".svelte-kit", ".turbo",
        ".parcel-cache", ".vite", ".angular", "__pycache__", ".pytest_cache", ".mypy_cache",
        ".ruff_cache", ".tox", ".gradle", "DerivedData", "Pods", ".dart_tool", ".terraform",
        "elm-stuff", ".stack-work", ".sass-cache", ".nyc_output", ".docusaurus", ".expo", ".serverless",
    ]
    static let projectScoped: Set<String> = ["target", "_build", "coverage"]
    static let ambiguous: Set<String> = ["build", "dist", "out", "bin", "obj", "vendor", "deps", ".cache"]
    static let skipDescend: Set<String> = [".git", ".Trash", "Library", "Applications", "Pictures", "Music", "Movies"]
    static let manifests: Set<String> = [
        "package.json", "cargo.toml", "go.mod", "pom.xml", "build.gradle", "build.gradle.kts",
        "settings.gradle", "pyproject.toml", "setup.py", "requirements.txt", "podfile", "pubspec.yaml",
        "mix.exs", "composer.json", "gemfile", "package.swift", "deno.json", "build.sbt", "cmakelists.txt",
    ]

    enum Decision: Equatable { case flag, recurse, skip }

    public let root: URL
    public let maxDepth: Int

    public init(root: URL, maxDepth: Int = 12) {
        self.root = root
        self.maxDepth = maxDepth
    }

    /// Flagged folders, largest first. Descent stops at each flagged folder, so nested artifacts
    /// are never counted twice.
    @concurrent
    public func scan() async -> [FileEntry] {
        var flagged: [URL] = []
        collect(in: root, depth: 0, inheritedIgnores: [], into: &flagged)
        let sizes = await SizeCalculator.measureAll(flagged)
        return zip(flagged, sizes)
            .filter { $0.1.bytes > 0 }
            .map { FileEntry(path: $0.0.path, sizeBytes: $0.1.bytes, isDirectory: true) }
            .sortedBySizeDescending()
    }

    private func collect(in dir: URL, depth: Int, inheritedIgnores: [String], into flagged: inout [URL]) {
        guard depth <= maxDepth, !Task.isCancelled else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: []
        ) else { return }

        let names = children.map(\.lastPathComponent)
        let isProject = names.contains(".git") || names.contains(where: Self.isManifestName)

        var ignores = inheritedIgnores
        if let body = try? String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8) {
            ignores += Self.parseGitignore(body)
        }

        for child in children {
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true
            else { continue }
            switch Self.classify(child.lastPathComponent, parentIsProject: isProject, ignores: ignores) {
            case .skip: continue
            case .flag: flagged.append(child)
            case .recurse: collect(in: child, depth: depth + 1, inheritedIgnores: ignores, into: &flagged)
            }
        }
    }

    static func isManifestName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return manifests.contains(lower)
            || lower.hasSuffix(".csproj") || lower.hasSuffix(".sln")
            || lower.hasSuffix(".xcodeproj") || lower.hasSuffix(".xcworkspace")
    }

    static func classify(_ name: String, parentIsProject: Bool, ignores: [String]) -> Decision {
        if skipDescend.contains(name) { return .skip }
        if unmistakable.contains(name) { return .flag }
        if projectScoped.contains(name), parentIsProject { return .flag }
        if ambiguous.contains(name), parentIsProject, ignores.contains(where: { segmentMatches($0, name) }) {
            return .flag
        }
        return .recurse
    }

    /// Reduces each `.gitignore` rule to its last path segment, enough to answer "is a folder named X ignored?".
    static func parseGitignore(_ content: String) -> [String] {
        content.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { return nil }
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty else { return nil }
            let segment = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
            return segment.isEmpty ? nil : segment
        }
    }

    /// Exact match, or a single leading / trailing `*`.
    static func segmentMatches(_ pattern: String, _ name: String) -> Bool {
        if pattern == name || pattern == "*" { return true }
        if pattern.hasPrefix("*") {
            let suffix = pattern.dropFirst()
            if !suffix.isEmpty, !suffix.contains("*") { return name.hasSuffix(suffix) }
        }
        if pattern.hasSuffix("*") {
            let prefix = pattern.dropLast()
            if !prefix.isEmpty, !prefix.contains("*") { return name.hasPrefix(prefix) }
        }
        return false
    }
}
