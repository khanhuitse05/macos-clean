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
    public let exclusions: ExclusionList

    public init(root: URL, maxDepth: Int = 12, exclusions: ExclusionList = .empty) {
        self.root = root
        self.maxDepth = maxDepth
        self.exclusions = exclusions
    }

    /// Flagged folders, largest first. Descent stops at each flagged folder, so nested artifacts
    /// are never counted twice.
    @concurrent
    public func scan() async -> [FileEntry] {
        await scanDetailed().entries
    }

    /// Flagged folders plus the listings collected while measuring them.
    @concurrent
    func scanDetailed(progress: ScanProgress? = nil) async -> (entries: [FileEntry], listings: [String: [FileEntry]]) {
        var flagged: [String] = []
        var rootPath = root.path
        while rootPath.count > 1, rootPath.hasSuffix("/") { rootPath.removeLast() }
        guard !exclusions.isExcluded(rootPath) else { return ([], [:]) }
        collect(in: rootPath, depth: 0, inheritedIgnores: [], into: &flagged)
        let sizes = await SizeCalculator.measureAll(
            flagged.map { URL(fileURLWithPath: $0) }, listingDepth: CategoryScanner.prefetchDepth, progress: progress
        )
        var listings: [String: [FileEntry]] = [:]
        for size in sizes { listings.merge(size.listings) { $1 } }
        let entries = zip(flagged, sizes)
            .filter { $0.1.bytes > 0 }
            .map { FileEntry(path: $0.0, sizeBytes: $0.1.bytes, isDirectory: true) }
            .sortedBySizeDescending()
        return (entries, listings)
    }

    /// One bulk read per folder: names and types come back together, so there's no per-child
    /// `stat` or URL resource lookup while crawling the home folder.
    private func collect(in dir: String, depth: Int, inheritedIgnores: [String], into flagged: inout [String]) {
        guard depth <= maxDepth, !Task.isCancelled else { return }
        let listing = DirectoryWalker.children(of: dir)
        guard listing.error == nil else { return }

        let isProject = listing.children.contains { $0.name == ".git" || Self.isManifestName($0.name) }

        var ignores = inheritedIgnores
        if listing.children.contains(where: { $0.name == ".gitignore" }),
           let body = try? String(contentsOfFile: DirectoryWalker.join(dir, ".gitignore"), encoding: .utf8) {
            ignores += Self.parseGitignore(body)
        }

        for child in listing.children where child.kind == .directory {
            if exclusions.contains(folder: child.path) { continue }
            switch Self.classify(child.name, parentIsProject: isProject, ignores: ignores) {
            case .skip: continue
            case .flag: flagged.append(child.path)
            case .recurse: collect(in: child.path, depth: depth + 1, inheritedIgnores: ignores, into: &flagged)
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
