import Foundation
import Testing
@testable import MacosCleanCore

@Suite("SizeCalculator")
struct SizeCalculatorTests {
    @Test func measuresAllocatedBytesOfTree() throws {
        let tree = try TempTree()
        try tree.file("a/one.bin", bytes: 100_000)
        try tree.file("a/b/two.bin", bytes: 300_000)
        let size = SizeCalculator.measure(tree.url("a"))
        #expect(size.bytes >= 400_000)
        #expect(size.bytes < 500_000)
        #expect(size.deniedPaths.isEmpty)
    }

    @Test func doesNotFollowSymlinks() throws {
        let tree = try TempTree()
        try tree.file("big/data.bin", bytes: 1_000_000)
        try tree.dir("links")
        try FileManager.default.createSymbolicLink(at: tree.url("links/big"), withDestinationURL: tree.url("big"))
        #expect(SizeCalculator.measure(tree.url("links")).bytes < 100_000)
    }

    @Test func countsHardLinksOnce() throws {
        let tree = try TempTree()
        let original = try tree.file("h/original.bin", bytes: 500_000)
        try FileManager.default.linkItem(at: original, to: tree.url("h/link.bin"))
        #expect(SizeCalculator.measure(tree.url("h")).bytes < 700_000)
    }

    @Test func reportsUnreadableFolder() throws {
        let tree = try TempTree()
        try tree.file("locked/secret.bin", bytes: 10)
        chmod(tree.url("locked").path, 0o000)
        let size = SizeCalculator.measure(tree.root)
        #expect(size.deniedPaths == [tree.url("locked").path])
    }

    @Test func missingPathIsZero() {
        #expect(SizeCalculator.measure(URL(fileURLWithPath: "/nope/\(UUID())")) == .zero)
    }

    @Test func measureAllKeepsOrder() async throws {
        let tree = try TempTree()
        let small = try tree.file("s.bin", bytes: 10_000)
        let large = try tree.file("l.bin", bytes: 900_000)
        let sizes = await SizeCalculator.measureAll([large, small, large], width: 2)
        #expect(sizes.count == 3)
        #expect(sizes[0].bytes > sizes[1].bytes)
        #expect(sizes[0] == sizes[2])
    }
}

@Suite("CategoryScanner")
struct CategoryScannerTests {
    func category(_ paths: [String]) -> CleanupCategory {
        CleanupCategory(id: "test", name: "Test", details: "Test", safety: .safe, source: .paths(paths))
    }

    @Test func listsTopLevelChildrenLargestFirst() async throws {
        let tree = try TempTree()
        try tree.file("Library/Caches/small/a.bin", bytes: 10_000)
        try tree.file("Library/Caches/large/b.bin", bytes: 800_000)
        try tree.file("Library/Caches/file.bin", bytes: 200_000)
        let scanner = CategoryScanner(expander: tree.expander, database: JunkDatabase(apps: []))
        let result = await scanner.scan(category(["~/Library/Caches", "~/does-not-exist"]))
        #expect(result.entries.map(\.name) == ["large", "file.bin", "small"])
        #expect(result.entries[0].isDirectory)
        #expect(!result.entries[1].isDirectory)
        #expect(result.deniedPaths.isEmpty)
        #expect(result.totalBytes == result.entries.map(\.sizeBytes).reduce(0, +))
    }

    @Test func reportsBlockedRoot() async throws {
        let tree = try TempTree()
        try tree.file("Locked/x.bin")
        chmod(tree.url("Locked").path, 0o000)
        let scanner = CategoryScanner(expander: tree.expander, database: JunkDatabase(apps: []))
        let result = await scanner.scan(category(["~/Locked"]))
        #expect(result.entries.isEmpty)
        #expect(result.deniedPaths == [tree.url("Locked").path])
    }

    @Test func appCachesComeFromDatabaseGlobs() async throws {
        let tree = try TempTree()
        try tree.file("Library/Application Support/Fake/Profile 1/Code Cache/x.bin", bytes: 50_000)
        try tree.file("Library/Application Support/Fake/Default/Code Cache/y.bin", bytes: 90_000)
        try tree.dir("Library/Application Support/Fake/Empty/Code Cache")
        let database = JunkDatabase(apps: [
            .init(name: "Fake", match: ["com.fake"], safeCaches: ["~/Library/Application Support/Fake/*/Code Cache"]),
        ])
        let scanner = CategoryScanner(expander: tree.expander, database: database)
        let appCaches = try #require(CleanupCategory.all.first { $0.id == "app-caches" })
        let result = await scanner.scan(appCaches)
        #expect(result.entries.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["Default", "Profile 1"])
    }

    @Test func shallowListSizesFilesButNotFolders() async throws {
        let tree = try TempTree()
        try tree.file("Root/b.bin", bytes: 200_000)
        try tree.file("Root/a.bin", bytes: 10_000)
        try tree.file("Root/Zed/deep.bin", bytes: 800_000)
        try tree.dir("Root/Alpha")
        let scanner = CategoryScanner(expander: tree.expander, database: JunkDatabase(apps: []))
        let listing = await scanner.shallowList(tree.url("Root"))
        #expect(listing.entries.map(\.name) == ["Alpha", "Zed", "a.bin", "b.bin"])
        #expect(listing.entries[0].isDirectory && listing.entries[0].sizeBytes == CategoryScanner.unmeasured)
        #expect(listing.entries[1].sizeBytes == CategoryScanner.unmeasured)
        #expect(listing.entries[3].sizeBytes >= 200_000)
        #expect(listing.deniedPaths.isEmpty)
    }

    @Test func shallowListReportsBlockedAndMissingRoots() async throws {
        let tree = try TempTree()
        try tree.file("Locked/x.bin")
        chmod(tree.url("Locked").path, 0o000)
        let scanner = CategoryScanner(expander: tree.expander, database: JunkDatabase(apps: []))
        let blocked = await scanner.shallowList(tree.url("Locked"))
        #expect(blocked.entries.isEmpty)
        #expect(blocked.deniedPaths == [tree.url("Locked").path])
        let missing = await scanner.shallowList(tree.url("nope"))
        #expect(missing == FolderListing(entries: [], deniedPaths: []))
    }
}

@Suite("DevProjectScanner")
struct DevProjectScannerTests {
    @Test func classifiesByConfidenceTier() {
        typealias S = DevProjectScanner
        #expect(S.classify("node_modules", parentIsProject: false, ignores: []) == .flag)
        #expect(S.classify("target", parentIsProject: false, ignores: []) == .recurse)
        #expect(S.classify("target", parentIsProject: true, ignores: []) == .flag)
        #expect(S.classify("build", parentIsProject: true, ignores: []) == .recurse)
        #expect(S.classify("build", parentIsProject: true, ignores: ["build"]) == .flag)
        #expect(S.classify("build", parentIsProject: false, ignores: ["build"]) == .recurse)
        #expect(S.classify("Library", parentIsProject: true, ignores: []) == .skip)
        #expect(S.classify(".git", parentIsProject: true, ignores: []) == .skip)
    }

    @Test func parsesGitignoreSegments() {
        let parsed = DevProjectScanner.parseGitignore("# c\n/build/\n!keep\napp/dist\n*.log\n\n")
        #expect(parsed == ["build", "dist", "*.log"])
        #expect(DevProjectScanner.segmentMatches("dist*", "dist-prod"))
        #expect(DevProjectScanner.segmentMatches("*.log", "debug.log"))
        #expect(!DevProjectScanner.segmentMatches("bin", "binary"))
    }

    @Test func findsLeftoversInsideProjects() async throws {
        let tree = try TempTree()
        try tree.file("Code/web/package.json", contents: "{}")
        try tree.file("Code/web/node_modules/lib/index.js", bytes: 40_000)
        try tree.file("Code/web/node_modules/nested/node_modules/x.js", bytes: 40_000)
        try tree.file("Code/rust/Cargo.toml", contents: "")
        try tree.file("Code/rust/target/debug/app", bytes: 40_000)
        try tree.file("Code/site/.gitignore", contents: "dist/\n")
        try tree.file("Code/site/package.json", contents: "{}")
        try tree.file("Code/site/dist/bundle.js", bytes: 40_000)
        try tree.file("Code/site/build/keep.js", bytes: 40_000) // not ignored → kept
        try tree.file("Notes/target/plan.txt", bytes: 40_000)    // not a project → kept
        try tree.file("Library/Caches/node_modules/x.js", bytes: 40_000) // Library skipped

        let found = await DevProjectScanner(root: tree.root).scan()
        let relative = Set(found.map { path in String(path.path[path.path.range(of: "/Code/")!.lowerBound...].dropFirst()) })
        #expect(relative == ["Code/web/node_modules", "Code/rust/target", "Code/site/dist"])
    }
}

@Suite("JunkDatabase")
struct JunkDatabaseTests {
    @Test func bundledDatabaseIsSubstantialAndValid() {
        let apps = JunkDatabase.bundled.apps
        #expect(apps.count >= 40)
        for app in apps {
            #expect(!app.match.isEmpty, "\(app.name) has no match keys")
            for pair in app.leftovers {
                #expect(pair.count == 2)
                #expect(["logs", "preferences", "caches", "supporting"].contains(pair.first ?? ""))
            }
        }
    }

    @Test func wildcardBasics() {
        #expect(JunkDatabase.wildcardMatch("Code Cache", "code cache"))
        #expect(JunkDatabase.wildcardMatch("AndroidStudio*", "AndroidStudio2024.1"))
        #expect(JunkDatabase.wildcardMatch("*", "anything"))
        #expect(JunkDatabase.wildcardMatch("a*c*e", "abcde"))
        #expect(!JunkDatabase.wildcardMatch("abc", "abd"))
        #expect(!JunkDatabase.wildcardMatch("a*z", "abc"))
    }

    @Test func matchesPrefixAndName() {
        let app = JunkDatabase.App(name: "Adobe", match: ["com.adobe.*", "Adobe Photoshop"])
        #expect(app.matches(bundleID: "com.adobe.Photoshop", name: "Photoshop"))
        #expect(app.matches(bundleID: "unknown", name: "adobe photoshop"))
        #expect(!app.matches(bundleID: "com.apple.Safari", name: "Safari"))
    }

    @Test func globExpandsSingleComponents() throws {
        let tree = try TempTree()
        try tree.dir("A/p1/Cache")
        try tree.dir("A/p2/Cache")
        try tree.dir("A/p3/Other")
        let urls = JunkDatabase.globExpand("~/A/*/Cache", expander: tree.expander)
        #expect(urls.map(\.path) == [tree.url("A/p1/Cache").path, tree.url("A/p2/Cache").path])
    }
}

@Suite("LargeFileScanner")
struct LargeFileScannerTests {
    func collect(_ scanner: LargeFileScanner) async -> (files: [FileEntry], denied: [String]) {
        var files: [FileEntry] = []
        var denied: [String] = []
        for await event in scanner.scan() {
            switch event {
            case .found(let batch): files += batch
            case .denied(let path): denied.append(path)
            case .progress, .finished: break
            }
        }
        return (files, denied)
    }

    @Test func findsFilesAboveThresholdAndSkipsNoise() async throws {
        let tree = try TempTree()
        try tree.file("Movies/big.mov", bytes: 600_000)
        try tree.file("Docs/small.txt", bytes: 1_000)
        try tree.file("Code/app/node_modules/huge.bin", bytes: 600_000)
        try tree.file("Library/Caches/huge.bin", bytes: 600_000)
        try tree.file("repo/.git/objects/pack.bin", bytes: 600_000)
        try tree.file(".Trash/old.bin", bytes: 600_000)

        let scanner = LargeFileScanner(root: tree.root, minimumBytes: 500_000)
        let result = await collect(scanner)
        #expect(result.files.map(\.name) == ["big.mov"])
        #expect(result.files.first?.modified != nil)
    }

    @Test func respectsMaxResultsAndDepth() async throws {
        let tree = try TempTree()
        for index in 0..<5 { try tree.file("f\(index).bin", bytes: 200_000) }
        try tree.file("a/b/c/deep.bin", bytes: 200_000)
        let capped = await collect(LargeFileScanner(root: tree.root, minimumBytes: 100_000, maxResults: 3))
        #expect(capped.files.count == 3)
        let shallow = await collect(LargeFileScanner(root: tree.root, minimumBytes: 100_000, maxDepth: 2))
        #expect(shallow.files.count == 5)
    }

    @Test func reportsBlockedFolders() async throws {
        let tree = try TempTree()
        try tree.file("Private/x.bin", bytes: 10)
        chmod(tree.url("Private").path, 0o000)
        let result = await collect(LargeFileScanner(root: tree.root, minimumBytes: 1))
        #expect(result.denied == [tree.url("Private").path])
    }
}

@Suite("LargeFileScanner explicit roots")
struct LargeFileScannerRootTests {
    @Test func skipRuleMatchingTheRootIsIgnored() async throws {
        let tree = try TempTree()
        try tree.file("Library/Caches/app/big.bin", bytes: 600_000)
        try tree.file("Library/Other/Caches/fine.bin", bytes: 600_000)
        var names: [String] = []
        for await event in LargeFileScanner(root: tree.url("Library/Caches"), minimumBytes: 500_000).scan() {
            if case .found(let batch) = event { names += batch.map(\.name) }
        }
        #expect(names == ["big.bin"])

        names = []
        for await event in LargeFileScanner(root: tree.url("Library"), minimumBytes: 500_000).scan() {
            if case .found(let batch) = event { names += batch.map(\.name) }
        }
        #expect(names == ["fine.bin"])
    }
}
