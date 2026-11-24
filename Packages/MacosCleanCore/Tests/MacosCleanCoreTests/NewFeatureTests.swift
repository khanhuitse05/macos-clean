import Foundation
import Testing
@testable import MacosCleanCore

// MARK: - N4 Exclusions

@Suite("ExclusionList")
struct ExclusionListTests {
    let expander = PathExpander(home: "/Users/me", environment: [:])

    @Test func normalizesPaths() {
        let list = ExclusionList(["~/Projects/keep/", "/tmp/../Users/me/Music", "", "relative"], expander: expander)
        #expect(list.paths == ["/Users/me/Projects/keep", "/Users/me/Music"])
    }

    @Test func excludedMeansItselfOrInside() {
        let list = ExclusionList(["/Users/me/Projects/keep"], expander: expander)
        #expect(list.isExcluded("/Users/me/Projects/keep"))
        #expect(list.isExcluded("/Users/me/Projects/keep/node_modules"))
        #expect(!list.isExcluded("/Users/me/Projects/keeper"))
        #expect(!list.isExcluded("/Users/me/Projects"))
    }

    @Test func overlapsAlsoCoversContainingFolders() {
        let list = ExclusionList(["/Users/me/Downloads/stuff/keep"], expander: expander)
        #expect(list.overlaps("/Users/me/Downloads/stuff"))
        #expect(list.overlaps("/Users/me/Downloads/stuff/keep/a.zip"))
        #expect(!list.overlaps("/Users/me/Downloads/other"))
        #expect(!list.overlaps("/Users/me/Downloads/stuffing"))
    }

    @Test func chosenRootIgnoresSurroundingExclusion() {
        let list = ExclusionList(["/Users/me/Movies", "/Users/me/Movies/Old/skip"], expander: expander)
        let applied = list.applying(toRoot: "/Users/me/Movies/Old")
        #expect(applied.paths == ["/Users/me/Movies/Old/skip"])
    }

    @Test func categoryScanDropsOverlappingEntries() async throws {
        let tree = try TempTree()
        try tree.file("Downloads/keep-me/a.bin", bytes: 50_000)
        try tree.file("Downloads/mixed/inner-keep/b.bin", bytes: 50_000)
        try tree.file("Downloads/mixed/junk.bin", bytes: 50_000)
        try tree.file("Downloads/junk.bin", bytes: 50_000)
        let exclusions = ExclusionList(["~/Downloads/keep-me", "~/Downloads/mixed/inner-keep"], expander: tree.expander)
        let scanner = CategoryScanner(expander: tree.expander, database: JunkDatabase(apps: []), exclusions: exclusions)
        let category = CleanupCategory(id: "t", name: "T", details: "T", safety: .caution, source: .paths(["~/Downloads"]))
        let result = await scanner.scan(category)
        #expect(result.entries.map(\.name) == ["junk.bin"])
    }

    @Test func excludedRootIsNotWalked() async throws {
        let tree = try TempTree()
        try tree.file("Library/Caches/a/x.bin", bytes: 50_000)
        let exclusions = ExclusionList(["~/Library/Caches"], expander: tree.expander)
        let scanner = CategoryScanner(expander: tree.expander, database: JunkDatabase(apps: []), exclusions: exclusions)
        let category = CleanupCategory(id: "t", name: "T", details: "T", safety: .safe, source: .paths(["~/Library/Caches"]))
        #expect(await scanner.scan(category).entries.isEmpty)
    }

    @Test func devProjectScannerSkipsExcludedFolders() async throws {
        let tree = try TempTree()
        try tree.file("code/app/package.json", contents: "{}")
        try tree.file("code/app/node_modules/x/index.js", bytes: 20_000)
        try tree.file("code/kept/package.json", contents: "{}")
        try tree.file("code/kept/node_modules/y/index.js", bytes: 20_000)
        let exclusions = ExclusionList([tree.url("code/kept").path])
        let found = await DevProjectScanner(root: tree.root, exclusions: exclusions).scan()
        #expect(found.map(\.path) == [tree.url("code/app/node_modules").path])
    }

    @Test func largeFileScannerSkipsExcludedFolders() async throws {
        let tree = try TempTree()
        try tree.file("Movies/big.mov", bytes: 600_000)
        try tree.file("Movies/Private/secret.mov", bytes: 600_000)
        let exclusions = ExclusionList([tree.url("Movies/Private").path])
        var found: [String] = []
        for await event in LargeFileScanner(root: tree.root, minimumBytes: 500_000, exclusions: exclusions).scan() {
            if case .found(let batch) = event { found += batch.map(\.name) }
        }
        #expect(found == ["big.mov"])
    }
}

// MARK: - N2 Cleaning history

@Suite("CleaningHistory")
struct CleaningHistoryTests {
    @Test func totalsCountCleansButNotTrashEmptying() {
        var history = CleaningHistory()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 5_000)
        history.record(CleaningRecord(date: first, kind: .trashed, bytes: 3_000, count: 3))
        history.record(CleaningRecord(date: later, kind: .simulatorRemoved, bytes: 7_000, count: 1))
        history.record(CleaningRecord(date: later, kind: .deletedForGood, bytes: 3_000, count: 3))
        #expect(history.lifetimeCleanedBytes == 10_000)
        #expect(history.lifetimeCleanedItems == 4)
        #expect(history.lifetimeEmptiedBytes == 3_000)
        #expect(history.cleanCount == 2)
        #expect(history.lastCleaned == later)
        #expect(history.firstCleaned == first)
        #expect(history.cleanedBytes(since: Date(timeIntervalSince1970: 2_000)) == 7_000)
    }

    @Test func ignoresEmptyRecords() {
        var history = CleaningHistory()
        history.record(CleaningRecord(kind: .trashed, bytes: 0, count: 0))
        #expect(history.isEmpty)
    }

    @Test func capsRecordsButKeepsTotals() {
        var history = CleaningHistory()
        for index in 0..<(CleaningHistory.maxRecords + 50) {
            history.record(CleaningRecord(date: Date(timeIntervalSince1970: Double(index)), kind: .trashed, bytes: 10, count: 1))
        }
        #expect(history.records.count == CleaningHistory.maxRecords)
        #expect(history.lifetimeCleanedBytes == Int64(10 * (CleaningHistory.maxRecords + 50)))
        #expect(history.records.first?.date == Date(timeIntervalSince1970: 50))
    }

    @Test func roundTripsThroughJSON() throws {
        var history = CleaningHistory()
        history.record(CleaningRecord(kind: .trashed, bytes: 42, count: 2))
        let decoded = try JSONDecoder().decode(CleaningHistory.self, from: JSONEncoder().encode(history))
        #expect(decoded == history)
    }
}

// MARK: - N6 Simulators

@Suite("SimulatorInventory")
struct SimulatorInventoryTests {
    static let runtimesJSON = """
    {
      "1C05": {
        "build": "23F77", "deletable": true, "identifier": "1C05",
        "lastUsedAt": "2026-11-21T11:26:31Z",
        "path": "/System/Library/AssetsV2/x/AssetData/Restore/a.dmg",
        "platformIdentifier": "com.apple.platform.iphonesimulator",
        "sizeBytes": 8494282293, "state": "Ready", "version": "26.5"
      },
      "BUILTIN": {
        "deletable": false, "identifier": "BUILTIN", "path": "/Applications/Xcode.app/x",
        "platformIdentifier": "com.apple.platform.watchsimulator", "sizeBytes": 5, "version": "11.0"
      }
    }
    """

    static let devicesJSON = """
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
          {
            "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/AAA/data",
            "dataPathSize": 4044427264, "udid": "AAA", "lastUsedAt": "2026-11-24T07:29:49Z",
            "isAvailable": true, "state": "Shutdown", "name": "iPhone 18 Pro"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
          {
            "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/BBB/data",
            "udid": "BBB", "isAvailable": false, "state": "Shutdown", "name": "iPhone 15"
          }
        ]
      }
    }
    """

    @Test func parsesDeletableRuntimesOnly() throws {
        let items = SimulatorInventory.parseRuntimes(Data(Self.runtimesJSON.utf8))
        #expect(items.count == 1)
        let runtime = try #require(items.first)
        #expect(runtime.kind == .runtime)
        #expect(runtime.identifier == "1C05")
        #expect(runtime.name == "iOS 26.5")
        #expect(runtime.sizeBytes == 8_494_282_293)
        #expect(runtime.path == "/System/Library/AssetsV2/x/AssetData/Restore/a.dmg")
        #expect(runtime.lastUsed == (try Date("2026-11-21T11:26:31Z", strategy: .iso8601)))
    }

    @Test func parsesDevicesWithFolderPaths() {
        let items = SimulatorInventory.parseDevices(Data(Self.devicesJSON.utf8)).sorted { $0.identifier < $1.identifier }
        #expect(items.map(\.name) == ["iPhone 18 Pro", "iPhone 15"])
        #expect(items[0].path == "/Users/me/Library/Developer/CoreSimulator/Devices/AAA")
        #expect(items[0].detail == "iOS 27.0")
        #expect(items[0].sizeBytes == 4_044_427_264)
        #expect(!items[1].isAvailable)
        #expect(items[1].sizeBytes == 0)
    }

    @Test func garbageParsesToNothing() {
        #expect(SimulatorInventory.parseRuntimes(Data("nope".utf8)).isEmpty)
        #expect(SimulatorInventory.parseDevices(Data("{}".utf8)).isEmpty)
    }

    struct FakeRunner: CommandRunning {
        let developerDir: String
        let calls = Calls()

        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [[String]] = []
            func append(_ call: [String]) { lock.withLock { storage.append(call) } }
            var all: [[String]] { lock.withLock { storage } }
        }

        func run(_ executable: String, _ arguments: [String], timeout: Duration) async -> CommandResult {
            calls.append([executable] + arguments)
            if executable.hasSuffix("xcode-select") {
                return CommandResult(status: 0, output: Data(developerDir.utf8), error: "")
            }
            if arguments.contains("delete"), arguments.last == "FAIL" {
                return CommandResult(status: 1, output: Data(), error: "Unable to delete a device in the current state: Booted")
            }
            return CommandResult(status: 0, output: Data(), error: "")
        }
    }

    @Test func neverRunsXcrunWithoutXcode() async {
        let runner = FakeRunner(developerDir: "/Library/Developer/CommandLineTools")
        let items = await SimulatorInventory(runner: runner).list()
        #expect(items.isEmpty)
        #expect(runner.calls.all.allSatisfy { !$0[0].hasSuffix("xcrun") })
    }

    @Test func removerUsesSimctlAndReportsFailures() async throws {
        let runner = FakeRunner(developerDir: "")
        let ok = SimulatorItem(kind: .runtime, identifier: "R1", name: "iOS 26.5", detail: "", sizeBytes: 100, lastUsed: nil, isAvailable: true, path: "/a")
        let bad = SimulatorItem(kind: .device, identifier: "FAIL", name: "iPhone", detail: "", sizeBytes: 50, lastUsed: nil, isAvailable: true, path: "/b")
        var summary: CleanSummary?
        for await event in try SimulatorRemover(runner: runner).remove([ok, bad], confirm: true) {
            if case .finished(let result) = event { summary = result }
        }
        let result = try #require(summary)
        #expect(result.succeeded == 1)
        #expect(result.bytesFreed == 100)
        #expect(result.failures.first?.error?.contains("Booted") == true)
        #expect(runner.calls.all.contains(["/usr/bin/xcrun", "simctl", "runtime", "delete", "R1"]))
        #expect(runner.calls.all.contains(["/usr/bin/xcrun", "simctl", "delete", "FAIL"]))
    }

    @Test func removerRequiresConfirmation() {
        #expect(throws: CleanerError.confirmationRequired) {
            _ = try SimulatorRemover(runner: FakeRunner(developerDir: "")).remove([], confirm: false)
        }
    }

    @Test func scanResultKeepsSimulatorsThroughCoding() throws {
        let item = SimulatorItem(kind: .device, identifier: "A", name: "iPhone", detail: "iOS 27.0", sizeBytes: 9, lastUsed: nil, isAvailable: false, path: "/d/A")
        let result = CategoryScanResult(categoryID: "simulators", entries: [item.entry], deniedPaths: [], simulators: [item])
        let decoded = try JSONDecoder().decode(CategoryScanResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.simulators == [item])
        #expect(decoded.keeping([]).simulators.isEmpty)
    }
}

// MARK: - N1 Duplicates

@Suite("DuplicateFinder")
struct DuplicateFinderTests {
    func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    func write(_ data: Data, _ tree: TempTree, _ relative: String) throws {
        let url = tree.url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @Test func groupsIdenticalFiles() async throws {
        let tree = try TempTree()
        let content = bytes(300_000, seed: 1)
        try write(content, tree, "a/photo.jpg")
        try write(content, tree, "b/photo copy.jpg")
        try write(content, tree, "c/d/photo.jpg")
        try write(bytes(300_000, seed: 2), tree, "a/other.jpg")
        let groups = await DuplicateFinder(root: tree.root, minimumBytes: 100_000).find()
        #expect(groups.count == 1)
        #expect(groups[0].files.count == 3)
        #expect(groups[0].fileBytes == 300_000)
        #expect(groups[0].wastedBytes >= 2 * 300_000)
    }

    @Test func sameEdgesDifferentMiddleAreNotDuplicates() async throws {
        let tree = try TempTree()
        var one = bytes(1_000_000, seed: 3)
        var two = one
        one[500_000] = 0x01
        two[500_000] = 0x02
        try write(one, tree, "one.bin")
        try write(two, tree, "two.bin")
        #expect(await DuplicateFinder(root: tree.root, minimumBytes: 100_000).find().isEmpty)
    }

    @Test func smallIdenticalFilesUseTheEdgeHashAlone() async throws {
        let tree = try TempTree()
        let content = bytes(100_000, seed: 4)
        try write(content, tree, "x.bin")
        try write(content, tree, "y.bin")
        let groups = await DuplicateFinder(root: tree.root, minimumBytes: 50_000).find()
        #expect(groups.map(\.files.count) == [2])
    }

    @Test func hardLinksAndSmallFilesAreIgnored() async throws {
        let tree = try TempTree()
        try write(bytes(300_000, seed: 5), tree, "orig.bin")
        try FileManager.default.linkItem(at: tree.url("orig.bin"), to: tree.url("link.bin"))
        try write(bytes(10_000, seed: 6), tree, "s1.bin")
        try write(bytes(10_000, seed: 6), tree, "s2.bin")
        #expect(await DuplicateFinder(root: tree.root, minimumBytes: 100_000).find().isEmpty)
    }

    @Test func clonesCountAsOneCopy() async throws {
        let tree = try TempTree()
        try write(bytes(300_000, seed: 7), tree, "orig.bin")
        guard clonefile(tree.url("orig.bin").path, tree.url("clone.bin").path, 0) == 0 else { return } // not APFS
        #expect(await DuplicateFinder(root: tree.root, minimumBytes: 100_000).find().isEmpty)
    }

    @Test func skipsExcludedFoldersAndNoise() async throws {
        let tree = try TempTree()
        let content = bytes(300_000, seed: 8)
        try write(content, tree, "keep/a.bin")
        try write(content, tree, "private/a.bin")
        try write(content, tree, "node_modules/a.bin")
        try write(content, tree, "Thing.app/Contents/a.bin")
        let exclusions = ExclusionList([tree.url("private").path])
        #expect(await DuplicateFinder(root: tree.root, minimumBytes: 100_000, exclusions: exclusions).find().isEmpty)
    }

    @Test func streamsProgressAndFinishes() async throws {
        let tree = try TempTree()
        let content = bytes(300_000, seed: 9)
        try write(content, tree, "a.bin")
        try write(content, tree, "b.bin")
        var stages: Set<String> = []
        var finished: [DuplicateGroup]?
        for await event in DuplicateFinder(root: tree.root, minimumBytes: 100_000).scan() {
            switch event {
            case .progress(let stage, _, _): stages.insert("\(stage)")
            case .finished(let groups): finished = groups
            case .denied: break
            }
        }
        #expect(finished?.count == 1)
        #expect(stages.contains("walking"))
        #expect(stages.contains("comparingContents"))
    }
}

// MARK: - N7 Suggestions

@Suite("SuggestionEngine")
struct SuggestionEngineTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    func app(_ id: String, name: String, system: Bool = false) -> InstalledApp {
        InstalledApp(bundleID: id, name: name, path: "/Applications/\(name).app", version: "1", modified: daysAgo(400), isSystem: system)
    }

    @Test func unusedAppCountsRelatedData() {
        let xcode = app("com.apple.dt.Xcode", name: "Xcode")
        let derived = CategoryScanResult(
            categoryID: "xcode-derived", entries: [FileEntry(path: "/d", sizeBytes: 30_000_000_000, isDirectory: true)], deniedPaths: []
        )
        let inputs = SuggestionInputs(
            apps: [.init(app: xcode, bundleBytes: 10_000_000_000, lastUsed: daysAgo(120))],
            results: ["xcode-derived": derived]
        )
        let suggestions = SuggestionEngine.suggest(inputs, now: now)
        #expect(suggestions.count == 1)
        #expect(suggestions[0].kind == .unusedApp)
        #expect(suggestions[0].bytes == 40_000_000_000)
        #expect(suggestions[0].idleDays == 120)
        #expect(suggestions[0].appName == "Xcode")
        #expect(suggestions[0].action == .reviewApp(path: "/Applications/Xcode.app"))
    }

    @Test func noClaimWithoutEvidenceOrWhenRecentOrSmall() {
        let inputs = SuggestionInputs(apps: [
            .init(app: app("a", name: "NoDate"), bundleBytes: 5_000_000_000, lastUsed: nil),
            .init(app: app("b", name: "Recent"), bundleBytes: 5_000_000_000, lastUsed: daysAgo(10)),
            .init(app: app("c", name: "Small"), bundleBytes: 50_000_000, lastUsed: daysAgo(400)),
            .init(app: app("d", name: "System", system: true), bundleBytes: 5_000_000_000, lastUsed: daysAgo(400)),
        ])
        #expect(SuggestionEngine.suggest(inputs, now: now).isEmpty)
    }

    @Test func oldDownloadsSelectOnlyOldItems() {
        let downloads = CategoryScanResult(categoryID: "system-downloads", entries: [
            FileEntry(path: "/dl/old.dmg", sizeBytes: 800_000_000, isDirectory: false, modified: daysAgo(200)),
            FileEntry(path: "/dl/new.zip", sizeBytes: 900_000_000, isDirectory: false, modified: daysAgo(2)),
        ], deniedPaths: [])
        let suggestions = SuggestionEngine.suggest(SuggestionInputs(results: ["system-downloads": downloads]), now: now)
        #expect(suggestions.map(\.kind) == [.oldDownloads])
        #expect(suggestions[0].action == .select(categoryID: "system-downloads", paths: ["/dl/old.dmg"]))
        #expect(suggestions[0].bytes == 800_000_000)
    }

    @Test func simulatorSuggestions() {
        let old = SimulatorItem(kind: .runtime, identifier: "R", name: "iOS 17", detail: "", sizeBytes: 7_000_000_000, lastUsed: daysAgo(150), isAvailable: true, path: "/r")
        let fresh = SimulatorItem(kind: .runtime, identifier: "S", name: "iOS 27", detail: "", sizeBytes: 8_000_000_000, lastUsed: daysAgo(1), isAvailable: true, path: "/s")
        let orphan = SimulatorItem(kind: .device, identifier: "D", name: "iPhone", detail: "", sizeBytes: 300_000_000, lastUsed: nil, isAvailable: false, path: "/dev")
        let result = CategoryScanResult(
            categoryID: "simulators", entries: [old, fresh, orphan].map(\.entry), deniedPaths: [], simulators: [old, fresh, orphan]
        )
        let suggestions = SuggestionEngine.suggest(SuggestionInputs(results: ["simulators": result]), now: now)
        #expect(suggestions.map(\.kind) == [.unusedSimulatorRuntimes, .unavailableSimulators])
        #expect(suggestions[0].action == .select(categoryID: "simulators", paths: ["/r"]))
    }

    @Test func dismissedHiddenForThirtyDaysAndCappedAtThree() {
        var apps: [SuggestionInputs.AppUsage] = []
        for index in 0..<5 {
            apps.append(.init(app: app("id\(index)", name: "App\(index)"), bundleBytes: Int64(index + 2) * 1_000_000_000, lastUsed: daysAgo(100)))
        }
        var inputs = SuggestionInputs(apps: apps)
        #expect(SuggestionEngine.suggest(inputs, now: now).map(\.appName) == ["App4", "App3", "App2"])
        inputs.dismissed = ["unused-app:id4": daysAgo(5), "unused-app:id3": daysAgo(40)]
        #expect(SuggestionEngine.suggest(inputs, now: now).map(\.appName) == ["App3", "App2", "App1"])
    }
}
