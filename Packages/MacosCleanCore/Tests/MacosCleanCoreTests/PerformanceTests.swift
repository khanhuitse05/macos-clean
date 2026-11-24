import Foundation
import Testing
@testable import MacosCleanCore

@Suite("PathSelection")
struct PathSelectionTests {
    @Test func unitsMatchPathDeduper() {
        var generator = SystemRandomNumberGenerator()
        let pool = [
            "/r/a", "/r/a/b", "/r/a/b/c", "/r/a/b/d", "/r/a/e", "/r/ab", "/r/ab/x", "/r/z", "/r/z/y/x", "/q",
        ]
        for _ in 0..<300 {
            var selection = PathSelection()
            var mirror = Set<String>()
            for _ in 0..<12 {
                let path = pool.randomElement(using: &generator)!
                if Bool.random(using: &generator) {
                    selection.insert(path)
                    mirror.insert(path)
                } else {
                    selection.remove(path)
                    mirror.remove(path)
                }
                #expect(selection.paths == mirror)
                #expect(selection.units == Set(PathDeduper.dedupe(Array(mirror))))
                for folder in pool {
                    #expect(selection.hasSelectedDescendant(folder) == mirror.contains { $0.hasPrefix(folder + "/") })
                }
            }
        }
    }

    @Test func removingAFolderPromotesItsSelectedChildren() {
        var selection = PathSelection(["/a", "/a/b", "/a/c"])
        #expect(selection.units == ["/a"])
        selection.remove("/a")
        #expect(selection.units == ["/a/b", "/a/c"])
        #expect(selection.hasSelectedDescendant("/a"))
        selection.keepOnly { $0 != "/a/b" }
        #expect(selection.units == ["/a/c"])
    }

    @Test func ancestorsStopAtRoot() {
        var seen: [String] = []
        PathSelection.forEachAncestor(of: "/x/y/z") { seen.append($0); return true }
        #expect(seen == ["/x/y", "/x", "/"])
    }
}

@Suite("Prefetched listings")
struct PrefetchTests {
    @Test func measureCollectsListingsToTheRequestedDepth() throws {
        let tree = try TempTree()
        try tree.file("root/a/one.bin", bytes: 100_000)
        try tree.file("root/a/deep/two.bin", bytes: 200_000)
        try tree.file("root/top.bin", bytes: 50_000)
        let root = tree.url("root")

        let result = SizeCalculator.measure(root, listingDepth: 2)
        let rootListing = try #require(result.listings[root.path])
        #expect(rootListing.map(\.name) == ["a", "top.bin"])
        #expect(rootListing[0].isDirectory)
        #expect(rootListing.totalBytes == result.bytes)

        let aListing = try #require(result.listings[tree.url("root/a").path])
        #expect(aListing.map(\.name) == ["deep", "one.bin"])
        // Depth 2 (root/a/deep) is not listed.
        #expect(result.listings[tree.url("root/a/deep").path] == nil)
        #expect(SizeCalculator.measure(root).listings.isEmpty)
    }

    @Test func parallelMeasureMatchesSerial() async throws {
        let tree = try TempTree()
        for a in 0..<3 {
            for b in 0..<3 {
                try tree.file("r/a\(a)/b\(b)/c/deep.bin", bytes: 20_000 * (a + 1))
                try tree.file("r/a\(a)/b\(b)/f.bin", bytes: 5_000)
            }
            try tree.file("r/a\(a)/top.bin", bytes: 1_000)
        }
        let root = tree.url("r")

        for depth in [0, 1, 2, 3] {
            let serial = SizeCalculator.measure(root, listingDepth: depth)
            let parallel = await SizeCalculator.measureParallel(root, listingDepth: depth)
            #expect(parallel.bytes == serial.bytes)
            #expect(Set(parallel.listings.keys) == Set(serial.listings.keys))
            for (folder, entries) in serial.listings {
                let fromParallel = parallel.listings[folder] ?? []
                #expect(Dictionary(uniqueKeysWithValues: fromParallel.map { ($0.path, $0.sizeBytes) })
                    == Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.sizeBytes) }), "\(folder) @ \(depth)")
            }
        }

        // One inode linked from two parallel subtrees counts once. Which folder it's
        // attributed to depends on which walk reaches it first, so only totals are compared.
        let original = try tree.file("r/a0/b0/c/linked.bin", bytes: 300_000)
        try FileManager.default.linkItem(at: original, to: tree.url("r/a1/b1/c/linked.bin"))
        let serial = SizeCalculator.measure(root)
        #expect(await SizeCalculator.measureParallel(root).bytes == serial.bytes)
        #expect(serial.bytes < SizeCalculator.measure(tree.url("r/a0")).bytes + SizeCalculator.measure(tree.url("r/a1")).bytes
            + SizeCalculator.measure(tree.url("r/a2")).bytes + 3 * 4096)
    }

    @Test func listPrefetchesChildFolders() async throws {
        let tree = try TempTree()
        try tree.file("Caches/app/data.bin", bytes: 100_000)
        try tree.file("Caches/app/sub/more.bin", bytes: 100_000)
        try tree.file("Caches/loose.bin", bytes: 10_000)
        let listing = await CategoryScanner().list(tree.url("Caches"))
        #expect(listing.entries.map(\.name) == ["app", "loose.bin"])
        let app = try #require(listing.prefetched[tree.url("Caches/app").path])
        #expect(app.map(\.name) == ["sub", "data.bin"] || app.map(\.name) == ["data.bin", "sub"])
        #expect(listing.prefetched[tree.url("Caches/app/sub").path]?.map(\.name) == ["more.bin"])
        #expect(listing.entries[0].sizeBytes == app.totalBytes)
    }

    @Test func childrenReportsKindsAndBlockedRoot() throws {
        let tree = try TempTree()
        try tree.file("d/file.txt", bytes: 10)
        try tree.dir("d/folder")
        try FileManager.default.createSymbolicLink(at: tree.url("d/link"), withDestinationURL: tree.url("d/folder"))
        let listing = DirectoryWalker.children(of: tree.url("d").path)
        let kinds = Dictionary(uniqueKeysWithValues: listing.children.map { ($0.name, $0.kind) })
        #expect(kinds == ["file.txt": .file, "folder": .directory, "link": .symlink])
        #expect(listing.error == nil)

        chmod(tree.url("d/folder").path, 0o000)
        #expect(DirectoryWalker.children(of: tree.url("d/folder").path).error == EACCES)
    }

    @Test func codableResultDropsPrefetched() throws {
        let entry = FileEntry(path: "/x/a", sizeBytes: 10, isDirectory: true, modified: Date(timeIntervalSince1970: 5))
        let result = CategoryScanResult(categoryID: "c", entries: [entry], deniedPaths: ["/x/b"], prefetched: ["/x/a": [entry]])
        let decoded = try JSONDecoder().decode(CategoryScanResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.entries == [entry])
        #expect(decoded.deniedPaths == ["/x/b"])
        #expect(decoded.prefetched.isEmpty)
    }
}

@Suite("LargeFileScanner skip rules")
struct SkipRuleTests {
    /// The name pre-check must never change the answer of the plain substring test.
    @Test func nameTestAgreesWithSubstringSearch() {
        let parents = ["/Users/me", "/Users/me/Library", "/Users/me/Library/Application Support", "/Users/me/code/app"]
        let names = [
            "Caches", "CachesOld", "Caches2", "MobileSync", "Containers", "Group Containers", ".git", ".gitx",
            "node_modules", "Photos Library.photoslibrary", ".cache", ".cached", "Docs", ".Trash", "Mobile Documents",
        ]
        for pattern in LargeFileScanner.skipSubstrings {
            let rule = LargeFileScanner.SkipRule(pattern)
            for parent in parents {
                // Only folders whose parent doesn't already match are ever tested.
                guard !(parent + "/").contains(pattern) else { continue }
                for name in names {
                    let path = parent + "/" + name
                    #expect(rule.matches(name: name, path: path) == (path + "/").contains(pattern), "\(pattern) vs \(path)")
                }
            }
        }
    }
}
