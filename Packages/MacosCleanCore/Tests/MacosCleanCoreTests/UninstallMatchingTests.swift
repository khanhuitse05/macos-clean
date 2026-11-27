import Foundation
import Testing
@testable import MacosCleanCore

@Suite("Match sensitivity")
struct MatchSensitivityTests {
    func scanner(_ tree: TempTree) -> LeftoverScanner {
        LeftoverScanner(expander: tree.expander, database: JunkDatabase(apps: []), systemLibrary: "/nonexistent")
    }

    func installed(_ ids: [(String, String)]) -> [InstalledApp] {
        ids.map { InstalledApp(bundleID: $0.0, name: $0.1, path: "/Applications/\($0.1).app", version: nil, modified: .now, isSystem: false) }
    }

    func paths(_ result: AppLeftovers, _ kind: LeftoverKind? = nil) -> Set<String> {
        Set(result.groups.filter { kind == nil || $0.kind == kind }.flatMap(\.entries).map(\.path))
    }

    @Test func strictIgnoresHelpersAndSimilarNames() async throws {
        let tree = try TempTree()
        try tree.file("Library/Preferences/com.example.foo.plist")
        try tree.file("Library/Caches/com.example.foo.ShipIt/update.bin", bytes: 1_000)
        try tree.file("Library/Application Support/FooApp/data.bin", bytes: 1_000)
        let result = await scanner(tree).scan(bundleID: "com.example.foo", name: "Foo", appURL: nil)
        #expect(paths(result) == [tree.url("Library/Preferences/com.example.foo.plist").path])
    }

    @Test func enhancedAddsPrefixedItemsButNotOtherInstalledApps() async throws {
        let tree = try TempTree()
        try tree.file("Library/Caches/com.example.foo.ShipIt/update.bin", bytes: 1_000)
        try tree.file("Library/Preferences/com.example.foo.helper.plist")
        try tree.file("Library/Containers/com.example.foo.share-extension/data.bin", bytes: 1_000)
        // Another installed app whose identifier extends ours: never offered.
        try tree.file("Library/Preferences/com.example.foo.pro.plist")
        try tree.file("Library/Caches/com.example.foo.pro.helper/x.bin", bytes: 1_000)
        let others = InstalledAppIndex(apps: installed([("com.example.foo.pro", "Foo Pro")]))
        let result = await scanner(tree).scan(bundleID: "com.example.foo", name: "Foo", appURL: nil, sensitivity: .enhanced, others: others)
        #expect(paths(result) == [
            tree.url("Library/Caches/com.example.foo.ShipIt").path,
            tree.url("Library/Preferences/com.example.foo.helper.plist").path,
            tree.url("Library/Containers/com.example.foo.share-extension").path,
        ])
        #expect(paths(result, .caches).count == 1)
        #expect(paths(result, .preferences).count == 1)
    }

    @Test func enhancedAddsEmbeddedHelperIdentifiers() async throws {
        let tree = try TempTree()
        let app = try tree.app("Applications/Foo.app", bundleID: "com.example.foo", name: "Foo")
        _ = try tree.app("Applications/Foo.app/Contents/Library/LoginItems/Launcher.app", bundleID: "com.othervendor.foolauncher")
        _ = try tree.app("Applications/Foo.app/Contents/PlugIns/Widget.appex", bundleID: "com.example.widget")
        try tree.file("Library/Preferences/com.othervendor.foolauncher.plist")
        try tree.file("Library/Containers/com.example.widget/data.bin", bytes: 1_000)

        let strict = await scanner(tree).scan(bundleID: "com.example.foo", name: "Foo", appURL: app)
        #expect(!paths(strict).contains(tree.url("Library/Containers/com.example.widget").path))

        let enhanced = await scanner(tree).scan(bundleID: "com.example.foo", name: "Foo", appURL: app, sensitivity: .enhanced)
        #expect(paths(enhanced).isSuperset(of: [
            tree.url("Library/Preferences/com.othervendor.foolauncher.plist").path,
            tree.url("Library/Containers/com.example.widget").path,
        ]))
    }

    @Test func deepAddsSimilarNamesAsUncheckedPossibleMatches() async throws {
        let tree = try TempTree()
        try tree.file("Library/Application Support/FooStudio Data/db.sqlite", bytes: 1_000)
        try tree.file("Library/Caches/foostudio-updater/x.bin", bytes: 1_000)
        try tree.file("Library/Application Support/Unrelated/x.bin", bytes: 1_000)
        let result = await scanner(tree).scan(bundleID: "com.acme.foostudio", name: "FooStudio", appURL: nil, sensitivity: .deep)
        #expect(paths(result, .possible) == [
            tree.url("Library/Application Support/FooStudio Data").path,
            tree.url("Library/Caches/foostudio-updater").path,
        ])
        #expect(LeftoverKind.possible.startsUnchecked)
        #expect(LeftoverKind.supporting.startsUnchecked)
        #expect(!LeftoverKind.caches.startsUnchecked)
    }

    @Test func deepMatchesTheDeveloperFolderOnlyWhenNoOtherAppSharesIt() async throws {
        let tree = try TempTree()
        try tree.file("Library/Application Support/Acmesoft/settings.json", bytes: 1_000)
        let alone = await scanner(tree).scan(bundleID: "com.acmesoft.editor", name: "Editor", appURL: nil, sensitivity: .deep)
        #expect(paths(alone, .possible) == [tree.url("Library/Application Support/Acmesoft").path])

        let others = InstalledAppIndex(apps: installed([("com.acmesoft.viewer", "Viewer")]))
        let shared = await scanner(tree).scan(bundleID: "com.acmesoft.editor", name: "Editor", appURL: nil, sensitivity: .deep, others: others)
        #expect(paths(shared, .possible).isEmpty)
    }

    @Test func deepSkipsFoldersNamedAfterAnotherInstalledApp() async throws {
        let tree = try TempTree()
        try tree.file("Library/Application Support/Notion Calendar/db", bytes: 1_000)
        let others = InstalledAppIndex(apps: installed([("com.cron.electron", "Notion Calendar")]))
        let result = await scanner(tree).scan(bundleID: "notion.id", name: "Notion", appURL: nil, sensitivity: .deep, others: others)
        #expect(paths(result, .possible).isEmpty)
    }

    @Test func identifierFromComponentStripsExtensionsAndGroupPrefixes() {
        #expect(LeftoverScanner.identifier(fromComponent: "com.example.app.plist", in: "Preferences") == "com.example.app")
        #expect(LeftoverScanner.identifier(fromComponent: "com.example.app.savedState", in: "Saved Application State") == "com.example.app")
        #expect(LeftoverScanner.identifier(fromComponent: "group.com.example.app", in: "Group Containers") == "com.example.app")
        #expect(LeftoverScanner.identifier(fromComponent: "ABCDE12345.com.example.shared", in: "Group Containers") == "com.example.shared")
        #expect(LeftoverScanner.identifier(fromComponent: "group.com.example.app", in: "Caches") == "group.com.example.app")
    }

    @Test func installedIndexClaimsIdentifiersHelpersAndNamespaces() {
        let index = InstalledAppIndex(apps: installed([("com.example.app", "App")]))
        #expect(index.claims("com.example.app"))
        #expect(index.claims("COM.EXAMPLE.APP.helper"))
        #expect(index.claims("com.example"))
        #expect(!index.claims("com.example.other"))
        #expect(index.sharesVendor(with: "com.example.other"))
        #expect(!index.sharesVendor(with: "com.elsewhere.other"))
        #expect(!InstalledAppIndex(apps: installed([("com.example.app", "App")]), excluding: "com.example.app").claims("com.example.app"))
    }
}

@Suite("OrphanFinder")
struct OrphanFinderTests {
    func installed(_ ids: [String]) -> InstalledAppIndex {
        InstalledAppIndex(apps: ids.map {
            InstalledApp(bundleID: $0, name: $0, path: "/Applications/\($0).app", version: nil, modified: .now, isSystem: false)
        })
    }

    @Test func groupsFilesOfADeletedAppAndItsHelpers() async throws {
        let tree = try TempTree()
        try tree.file("Library/Preferences/com.gone.editor.plist", bytes: 2_000)
        try tree.file("Library/Caches/com.gone.editor/cache.bin", bytes: 10_000)
        try tree.file("Library/Caches/com.gone.editor.ShipIt/update.bin", bytes: 5_000)
        try tree.file("Library/Saved Application State/com.gone.editor.savedState/window.data", bytes: 1_000)

        let orphans = await OrphanFinder(expander: tree.expander).find(installed: .empty)
        #expect(orphans.map(\.bundleID) == ["com.gone.editor"])
        let orphan = try #require(orphans.first)
        #expect(orphan.paths.count == 4)
        #expect(orphan.bytes >= 18_000)
    }

    @Test func skipsInstalledAppsTheirHelpersAndTheirDevelopers() async throws {
        let tree = try TempTree()
        // Each one has a preferences file, so only the rule under test keeps it out.
        for id in ["com.live.app", "com.live.app.helper", "com.live.updater", "com.apple.Safari",
                   "com.known.elsewhere", "com.dismissed.app", "NotAnIdentifier", "com.twoparts"] {
            try tree.file("Library/Preferences/\(id).plist", bytes: 2_000)
        }

        let orphans = await OrphanFinder(expander: tree.expander).find(
            installed: installed(["com.live.app"]),
            isKnownApp: { $0 == "com.known.elsewhere" },
            ignoring: ["COM.DISMISSED.APP"]
        )
        #expect(orphans.isEmpty)
    }

    @Test func skipsCommandLineToolCachesWithoutAnAppFootprint() async throws {
        let tree = try TempTree()
        try tree.file("Library/Caches/org.swift.swiftpm/repositories/x.bin", bytes: 20_000)
        try tree.file("Library/Caches/org.carthage.CarthageKit/x.bin", bytes: 20_000)
        try tree.file("Library/Logs/dev.example.linter/run.log", bytes: 2_000)
        // A helper's preferences count for the whole group.
        try tree.file("Library/Caches/com.gone.player/x.bin", bytes: 20_000)
        try tree.file("Library/Preferences/com.gone.player.helper.plist", bytes: 2_000)
        let orphans = await OrphanFinder(expander: tree.expander).find(installed: .empty)
        #expect(orphans.map(\.bundleID) == ["com.gone.player"])
    }

    @Test func skipsExcludedFoldersAndEmptyItems() async throws {
        let tree = try TempTree()
        try tree.file("Library/Preferences/com.gone.kept.plist", bytes: 2_000)
        try tree.dir("Library/Containers/com.gone.empty")
        let exclusions = ExclusionList([tree.url("Library/Preferences/com.gone.kept.plist").path], expander: tree.expander)
        let orphans = await OrphanFinder(expander: tree.expander, exclusions: exclusions).find(installed: .empty)
        #expect(orphans.isEmpty)
    }

    @Test func leftoversAtPathsAreGroupedByLibraryFolder() async throws {
        let tree = try TempTree()
        let prefs = try tree.file("Library/Preferences/com.gone.editor.plist", bytes: 2_000)
        let cache = try tree.file("Library/Caches/com.gone.editor/x.bin", bytes: 2_000).deletingLastPathComponent()
        let support = try tree.file("Library/Application Support/com.gone.editor/x.bin", bytes: 2_000).deletingLastPathComponent()
        let scanner = LeftoverScanner(expander: tree.expander, database: JunkDatabase(apps: []), systemLibrary: "/nonexistent")
        let result = await scanner.leftovers(at: [prefs.path, cache.path, support.path], bundleID: "com.gone.editor")
        #expect(result.groups.map(\.kind) == [.preferences, .caches, .supporting])
    }

    @Test func bundleIdentifierShape() {
        #expect(OrphanFinder.looksLikeBundleID("com.example.app"))
        #expect(OrphanFinder.looksLikeBundleID("io.github.some-tool_x"))
        #expect(!OrphanFinder.looksLikeBundleID("com.example"))
        #expect(!OrphanFinder.looksLikeBundleID("Example.App.Name"))
        #expect(!OrphanFinder.looksLikeBundleID("com..app"))
        #expect(!OrphanFinder.looksLikeBundleID("com.example.my app"))
    }
}
