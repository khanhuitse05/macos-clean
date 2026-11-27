import Foundation

/// Asks git which files the person's repositories ignore: build output, compiled bundles,
/// dependency folders, local uploads, debug symbols. Those are made by tools, not kept by hand,
/// so copies among them aren't the person's duplicates.
///
/// Only a git that is already installed is used. `/usr/bin/git` is never run: without the
/// developer tools it asks to install them.
struct GitIgnoredFiles: Sendable {
    let git: String?
    let runner: any CommandRunning

    init(git: String? = GitIgnoredFiles.locateGit(), runner: any CommandRunning = ProcessRunner()) {
        self.git = git
        self.runner = runner
    }

    static func locateGit() -> String? {
        var candidates: [String] = []
        // The developer directory `xcode-select` points at, read without running anything.
        if let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append(developer + "/usr/bin/git")
        }
        candidates += [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The paths among `paths` that their repository ignores. Files outside a repository, tracked
    /// files, and everything when git is missing or fails, are kept (not returned).
    func ignored(_ paths: [String]) async -> Set<String> {
        guard let git, !paths.isEmpty else { return [] }
        var roots: [String: String?] = [:]
        var byRepository: [String: [String]] = [:]
        for path in paths {
            if let root = Self.repositoryRoot(of: path, cache: &roots) {
                byRepository[root, default: []].append(path)
            }
        }
        var result = Set<String>()
        for (root, files) in byRepository {
            if Task.isCancelled { break }
            for start in stride(from: 0, to: files.count, by: 200) {
                let chunk = Array(files[start..<min(start + 200, files.count)])
                let run = await runner.run(
                    git, ["-C", root, "-c", "core.quotePath=false", "check-ignore", "--"] + chunk,
                    timeout: .seconds(10)
                )
                // 0: some are ignored. 1: none are. Anything else: git couldn't tell.
                guard run.status == 0 else { continue }
                let listed = String(decoding: run.output, as: UTF8.self).split(separator: "\n").map(String.init)
                let asked = Set(chunk)
                for line in listed where asked.contains(line) { result.insert(line) }
            }
        }
        return result
    }

    /// The nearest folder above `path` holding a `.git` folder or file (worktrees, submodules).
    static func repositoryRoot(of path: String, cache: inout [String: String?]) -> String? {
        var folder = (path as NSString).deletingLastPathComponent
        var visited: [String] = []
        var found: String?
        while folder.count > 1 {
            if let known = cache[folder] {
                found = known
                break
            }
            visited.append(folder)
            if FileManager.default.fileExists(atPath: folder + "/.git") {
                found = folder
                break
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
        for folder in visited { cache[folder] = found }
        return found
    }
}
