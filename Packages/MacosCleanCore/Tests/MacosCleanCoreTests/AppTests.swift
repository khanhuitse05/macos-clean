import Foundation
import Testing
@testable import MacosCleanCore

@Suite("AppCatalog")
struct AppCatalogTests {
    @Test func listsAppsWithMetadata() throws {
        let tree = try TempTree()
        _ = try tree.app("Apps/Zeta.app", bundleID: "com.example.zeta", name: "Zeta", version: "2.1")
        _ = try tree.app("Apps/alpha.app", bundleID: nil)
        _ = try tree.app("Apps/Suite/Tool.app", bundleID: "com.example.tool")
        _ = try tree.app("Sys/Clock.app", bundleID: "com.apple.clock")
        let catalog = AppCatalog(roots: [
            .init(url: tree.url("Apps"), isSystem: false),
            .init(url: tree.url("Sys"), isSystem: true),
        ], ownBundlePath: tree.url("Apps/Zeta.app").path)

        let apps = catalog.listApps()
        #expect(apps.map(\.name) == ["alpha", "Clock", "Tool", "Zeta"])
        let zeta = try #require(apps.last)
        #expect(zeta.version == "2.1")
        #expect(zeta.isSelf && !zeta.canUninstall)
        #expect(apps[0].hasRealBundleID == false)
        #expect(apps[1].isSystem && !apps[1].canUninstall)
        #expect(apps[2].canUninstall)
    }
}

@Suite("LeftoverScanner")
struct LeftoverScannerTests {
    @Test func groupsLeftoversInOrderAndDedupesDescendants() async throws {
        let tree = try TempTree()
        let app = try tree.app("Applications/Foo.app", bundleID: "com.example.foo", name: "Foo")
        try tree.file("Library/Preferences/com.example.foo.plist", bytes: 2_000)
        try tree.file("Library/Caches/com.example.foo/data.bin", bytes: 50_000)
        try tree.file("Library/Application Support/Foo/db.sqlite", bytes: 90_000)
        try tree.file("Library/Logs/Foo/log.txt", bytes: 5_000)
        try tree.file("Library/Application Support/Vendor/Foo/extra.bin", bytes: 5_000)
        try tree.file("Library/Application Support/Foo/Cache/inner.bin", bytes: 5_000) // under an accepted folder

        let database = JunkDatabase(apps: [
            .init(name: "Foo", match: ["com.example.*"],
                  leftovers: [["supporting", "~/Library/Application Support/Vendor/Foo"]],
                  safeCaches: ["~/Library/Application Support/Foo/Cache"]),
        ])
        let scanner = LeftoverScanner(expander: tree.expander, database: database, systemLibrary: tree.url("SystemLibrary").path)
        let result = await scanner.scan(bundleID: "com.example.foo", name: "Foo", appURL: app)

        #expect(result.groups.map(\.kind) == [.binaries, .logs, .preferences, .caches, .supporting])
        let supporting = try #require(result.groups.last)
        #expect(Set(supporting.entries.map(\.path)) == [
            tree.url("Library/Application Support/Foo").path,
            tree.url("Library/Application Support/Vendor/Foo").path,
        ])
        #expect(!result.allEntries.contains { $0.path.hasSuffix("Foo/Cache") })
        #expect(result.totalBytes > 150_000)
    }

    @Test func neverUsesEmptyOrPathLikeNames() throws {
        let tree = try TempTree()
        let scanner = LeftoverScanner(expander: tree.expander, database: JunkDatabase(apps: []), systemLibrary: "/nonexistent")
        let candidates = scanner.candidates(bundleID: "", name: "../..", appURL: nil)
        #expect(candidates.isEmpty)
        let noID = scanner.candidates(bundleID: "__no_bundle_id.X", name: "", appURL: nil)
        #expect(noID.isEmpty)
    }

    @Test func removedAppHasNoBinariesGroup() async throws {
        let tree = try TempTree()
        try tree.file("Library/Caches/com.example.gone/x.bin", bytes: 20_000)
        let scanner = LeftoverScanner(expander: tree.expander, database: JunkDatabase(apps: []), systemLibrary: "/nonexistent")
        let result = await scanner.scan(bundleID: "com.example.gone", name: "Gone", appURL: nil)
        #expect(result.groups.map(\.kind) == [.caches])
    }
}

@Suite("AppWatcher")
struct AppWatcherTests {
    func app(_ id: String, path: String? = nil, system: Bool = false) -> InstalledApp {
        InstalledApp(bundleID: id, name: id, path: path ?? "/Applications/\(id).app", version: nil, modified: .distantPast, isSystem: system)
    }

    @Test func diffCreatesTombstonesForVanishedApps() {
        let now = Date()
        let result = AppWatcher.updatedRemovals(
            previous: [app("a"), app("b"), app("sys", system: true), app("mine")],
            current: [app("a")], removed: [], ignoring: ["/Applications/mine.app"], now: now
        )
        #expect(result.map(\.bundleID) == ["b"])
    }

    @Test func reinstallAndExpiryClearTombstones() {
        let now = Date()
        let old = RemovedApp(bundleID: "old", name: "old", path: "/x", removedAt: now.addingTimeInterval(-31 * 86_400))
        let back = RemovedApp(bundleID: "back", name: "back", path: "/Applications/back.app", removedAt: now)
        let kept = RemovedApp(bundleID: "kept", name: "kept", path: "/y", removedAt: now)
        let result = AppWatcher.updatedRemovals(
            previous: [], current: [app("back", path: "/Users/me/Applications/back.app")],
            removed: [old, back, kept], ignoring: [], now: now
        )
        #expect(result.map(\.bundleID) == ["kept"])
    }

    @Test func persistsAcrossLaunchesAndDetectsOfflineRemoval() async throws {
        let tree = try TempTree()
        _ = try tree.app("Apps/One.app", bundleID: "com.example.one")
        let two = try tree.app("Apps/Two.app", bundleID: "com.example.two")
        let catalog = AppCatalog(roots: [.init(url: tree.url("Apps"), isSystem: false)], ownBundlePath: nil)
        let cache = tree.url("cache/apps.json")

        let first = AppWatcher(catalog: catalog, cacheURL: cache)
        #expect(await first.refresh().apps.count == 2)
        #expect(await first.cached().removed.isEmpty)

        try FileManager.default.removeItem(at: two)
        let second = AppWatcher(catalog: catalog, cacheURL: cache)
        #expect(await second.cached().apps.count == 2)
        let snapshot = await second.refresh()
        #expect(snapshot.apps.map(\.bundleID) == ["com.example.one"])
        #expect(snapshot.removed.map(\.bundleID) == ["com.example.two"])

        let dismissed = await second.dismiss(bundleID: "com.example.two")
        #expect(dismissed.removed.isEmpty)
        #expect(await AppWatcher(catalog: catalog, cacheURL: cache).cached().removed.isEmpty)
    }

    @Test func markHandledSuppressesTombstone() async throws {
        let tree = try TempTree()
        let one = try tree.app("Apps/One.app", bundleID: "com.example.one")
        let catalog = AppCatalog(roots: [.init(url: tree.url("Apps"), isSystem: false)], ownBundlePath: nil)
        let watcher = AppWatcher(catalog: catalog, cacheURL: nil)
        let listed = try #require(await watcher.refresh().apps.first)
        await watcher.markHandled(path: listed.path)
        try FileManager.default.removeItem(at: one)
        #expect(await watcher.refresh().removed.isEmpty)
    }
}
