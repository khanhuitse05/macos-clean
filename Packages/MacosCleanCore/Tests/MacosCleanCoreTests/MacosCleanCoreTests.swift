import Foundation
import Synchronization
import Testing
@testable import MacosCleanCore

// MARK: - Categories

@Suite("Categories")
struct CategoryTests {
    @Test func hasAllCategoriesWithUniqueIDs() {
        let ids = CleanupCategory.all.map(\.id)
        #expect(ids.count == 26)
        #expect(Set(ids).count == ids.count)
    }

    @Test func cautionCategoriesMatchExpectedSet() {
        let caution = Set(CleanupCategory.all.filter { $0.safety == .caution }.map(\.id))
        #expect(caution == [
            "xcode-archives", "docker-data", "claude-data",
            "ios-backups", "dev-projects", "system-downloads", "simulators",
        ])
    }

    @Test func onlySafeCategoriesAreSelectedByDefault() {
        #expect(Safety.safe.selectedByDefault)
        #expect(!Safety.caution.selectedByDefault)
    }

    @Test func dynamicCategoriesHaveNoFixedPaths() {
        let byID = Dictionary(uniqueKeysWithValues: CleanupCategory.all.map { ($0.id, $0) })
        guard case .appCaches = byID["app-caches"]?.source else { Issue.record("app-caches"); return }
        guard case .devProjects = byID["dev-projects"]?.source else { Issue.record("dev-projects"); return }
    }

    @Test func bundledJunkDatabaseIsValidJSON() throws {
        let url = try #require(Bundle.module.url(forResource: "app_junk_db", withExtension: "json"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect((object?["apps"] as? [Any])?.isEmpty == false)
    }
}

// MARK: - Path expansion

@Suite("PathExpander")
struct PathExpanderTests {
    let expander = PathExpander(home: "/Users/test", environment: ["FOO": "bar"])

    @Test func expandsTilde() {
        #expect(expander.expand("~").path == "/Users/test")
        #expect(expander.expand("~/Library/Caches").path == "/Users/test/Library/Caches")
    }

    @Test func leavesAbsolutePathsAlone() {
        #expect(expander.expand("/Library/Caches/Homebrew").path == "/Library/Caches/Homebrew")
    }

    @Test func expandsEnvironmentVariables() {
        #expect(expander.expand("/x/$FOO/y").path == "/x/bar/y")
        #expect(expander.expand("/x/${FOO}/y").path == "/x/bar/y")
    }

    @Test func leavesUnknownVariablesUntouched() {
        #expect(expander.expand("/x/$NOPE").path == "/x/$NOPE")
    }
}

// MARK: - Dedupe

@Suite("PathDeduper")
struct PathDeduperTests {
    @Test func ancestorSwallowsDescendants() {
        let result = PathDeduper.dedupe(["/a/b/c.txt", "/a/b", "/a/b/d/e", "/z"])
        #expect(result == ["/a/b", "/z"])
    }

    @Test func siblingWithSharedPrefixIsNotSwallowed() {
        // "/a/bc" must not be treated as a descendant of "/a/b".
        #expect(PathDeduper.dedupe(["/a/b", "/a/bc"]) == ["/a/b", "/a/bc"])
    }

    @Test func removesExactDuplicatesAndKeepsOrder() {
        #expect(PathDeduper.dedupe(["/q", "/p", "/q"]) == ["/q", "/p"])
    }
}

// MARK: - Cleaner safety

private final class FakeTrasher: Trashing {
    let calls = Mutex<[String]>([])
    let failing: Set<String>

    init(failing: Set<String> = []) { self.failing = failing }

    func trash(_ url: URL) throws {
        calls.withLock { $0.append(url.path) }
        if failing.contains(url.path) {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}

@Suite("Cleaner")
struct CleanerTests {
    @Test func refusesWithoutConfirmationAndTouchesNothing() {
        let fake = FakeTrasher()
        let cleaner = Cleaner(trasher: fake, home: "/Users/test")
        #expect(throws: CleanerError.confirmationRequired) {
            try cleaner.moveToTrash(["/tmp/a"], confirm: false)
        }
        #expect(fake.calls.withLock { $0 }.isEmpty)
    }

    @Test func dedupesBeforeTrashing() throws {
        let fake = FakeTrasher()
        let cleaner = Cleaner(trasher: fake, home: "/Users/test")
        let outcomes = try cleaner.moveToTrash(["/tmp/a/b", "/tmp/a"], confirm: true)
        #expect(fake.calls.withLock { $0 } == ["/tmp/a"])
        #expect(outcomes == [DeleteOutcome(path: "/tmp/a", success: true)])
    }

    @Test func refusesRootAndHome() throws {
        let fake = FakeTrasher()
        let cleaner = Cleaner(trasher: fake, home: "/Users/test")
        let outcomes = try cleaner.moveToTrash(["/", "/Users/test/"], confirm: true)
        #expect(fake.calls.withLock { $0 }.isEmpty)
        #expect(outcomes.allSatisfy { !$0.success })
    }

    @Test func reportsPerItemFailureAndContinues() throws {
        let fake = FakeTrasher(failing: ["/tmp/bad"])
        let cleaner = Cleaner(trasher: fake, home: "/Users/test")
        let outcomes = try cleaner.moveToTrash(["/tmp/bad", "/tmp/good"], confirm: true)
        #expect(outcomes.map(\.success) == [false, true])
        #expect(outcomes[0].error != nil)
    }
}

@Suite("Cleaner progress and protection")
struct CleanerStreamTests {
    @Test func streamRequiresConfirmationBeforeTouchingAnything() {
        let fake = FakeTrasher()
        let cleaner = Cleaner(trasher: fake, home: "/Users/test", measuresSize: false)
        #expect(throws: CleanerError.confirmationRequired) {
            _ = try cleaner.trash(["/tmp/a"], confirm: false)
        }
        #expect(fake.calls.withLock { $0 }.isEmpty)
    }

    @Test func streamReportsProgressAndSummary() async throws {
        let tree = try TempTree()
        let a = try tree.file("a.bin", bytes: 200_000)
        let b = try tree.file("b.bin", bytes: 100_000)
        let fake = FakeTrasher(failing: [b.path])
        let cleaner = Cleaner(trasher: fake, home: "/Users/test")
        var progress: [CleanProgress] = []
        var summary: CleanSummary?
        for await event in try cleaner.trash([a.path, b.path], confirm: true) {
            switch event {
            case .progress(let value): progress.append(value)
            case .finished(let value): summary = value
            }
        }
        #expect(progress.map(\.current) == [0, 1, 2])
        #expect(progress.last?.succeeded == 1 && progress.last?.failed == 1)
        let result = try #require(summary)
        #expect(result.trashedPaths == [a.path])
        #expect(result.bytesFreed >= 200_000)
        #expect(result.failures.map(\.path) == [b.path])
    }

    @Test func refusesSystemTrashContentsAndOwnBundle() throws {
        let fake = FakeTrasher()
        let cleaner = Cleaner(trasher: fake, home: "/Users/test", ownBundlePath: "/Applications/macOS Clean.app")
        let paths = [
            "/System/Applications/Mail.app", "/Users/test/.Trash/old.zip", "/Users/test/.Trash",
            "/Applications/macOS Clean.app", "/Applications/macOS Clean.app/Contents",
            "/Users/test/Library", "/Users/test/Library/Caches", "/Users/test/Documents", "/Applications",
        ]
        let outcomes = try cleaner.moveToTrash(paths, confirm: true)
        #expect(outcomes.allSatisfy { !$0.success && $0.error == Cleaner.refusalMessage })
        #expect(fake.calls.withLock { $0 }.isEmpty)
        #expect(cleaner.refusalReason(for: "/Users/test/Library/Caches/com.example") == nil)
        #expect(cleaner.refusalReason(for: "/Applications/Other.app") == nil)
    }

    @Test func timesOutWedgedItems() async throws {
        let cleaner = Cleaner(trasher: SlowTrasher(), home: "/Users/test", itemTimeout: .milliseconds(100), measuresSize: false)
        var summary: CleanSummary?
        for await event in try cleaner.trash(["/tmp/wedged"], confirm: true) {
            if case .finished(let value) = event { summary = value }
        }
        #expect(summary?.failed == 1)
        #expect(summary?.failures.first?.error?.contains("Timed out") == true)
    }
}

private struct SlowTrasher: Trashing {
    func trash(_ url: URL) throws { Thread.sleep(forTimeInterval: 1) }
}
