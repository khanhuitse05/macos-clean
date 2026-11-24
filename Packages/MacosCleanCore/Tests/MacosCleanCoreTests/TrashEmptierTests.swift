import Foundation
import Synchronization
import Testing
@testable import MacosCleanCore

/// Records removals instead of deleting; fails for names listed in `failing`.
private final class FakeRemover: Removing {
    private let removed = Mutex<[String]>([])
    let failing: Set<String>

    init(failing: Set<String> = []) { self.failing = failing }

    var paths: [String] { removed.withLock { $0 } }

    func remove(_ url: URL) throws {
        if failing.contains(url.lastPathComponent) {
            throw CocoaError(.fileWriteNoPermission)
        }
        removed.withLock { $0.append(url.path) }
    }
}

private func collect(_ stream: AsyncStream<CleanEvent>) async -> (progress: [CleanProgress], summary: CleanSummary?) {
    var progress: [CleanProgress] = []
    var summary: CleanSummary?
    for await event in stream {
        switch event {
        case .progress(let value): progress.append(value)
        case .finished(let value): summary = value
        }
    }
    return (progress, summary)
}

@Suite("Trash emptier")
struct TrashEmptierTests {
    @Test func requiresConfirmation() throws {
        let tree = try TempTree()
        let trash = try tree.dir(".Trash")
        try tree.file(".Trash/a.bin")
        let fake = FakeRemover()
        let emptier = TrashEmptier(trashURL: trash, remover: fake)
        #expect(throws: CleanerError.confirmationRequired) { try emptier.erase(nil, confirm: false) }
        #expect(fake.paths.isEmpty)
    }

    @Test func refusesAnythingOutsideTheTrash() throws {
        let tree = try TempTree()
        let trash = try tree.dir(".Trash")
        try tree.dir("Documents")
        try FileManager.default.createSymbolicLink(at: tree.url(".Trash/escape"), withDestinationURL: tree.url("Documents"))
        let emptier = TrashEmptier(trashURL: trash, remover: FakeRemover())

        #expect(emptier.refusalReason(for: trash.path) != nil)
        #expect(emptier.refusalReason(for: trash.path + "/") != nil)
        #expect(emptier.refusalReason(for: tree.url("Documents/report.pdf").path) != nil)
        #expect(emptier.refusalReason(for: trash.path + "/../Documents") != nil)
        #expect(emptier.refusalReason(for: trash.path + "/escape/report.pdf") != nil)
        #expect(emptier.refusalReason(for: "/") != nil)
        // The symlink itself is inside the Trash and is removed as a link.
        #expect(emptier.refusalReason(for: trash.path + "/escape") == nil)
        #expect(emptier.refusalReason(for: trash.path + "/a.bin") == nil)
        #expect(emptier.refusalReason(for: trash.path + "/folder/nested.bin") == nil)
    }

    @Test func refusedPathsAreReportedNotRemoved() async throws {
        let tree = try TempTree()
        let trash = try tree.dir(".Trash")
        let outside = try tree.file("Documents/keep.txt")
        let fake = FakeRemover()
        let emptier = TrashEmptier(trashURL: trash, remover: fake, measuresSize: false)
        let (_, summary) = await collect(try emptier.erase([outside.path], confirm: true))
        #expect(summary?.failed == 1)
        #expect(summary?.failures.first?.error == TrashEmptier.refusalMessage)
        #expect(fake.paths.isEmpty)
    }

    @Test func nilErasesEveryTopLevelItemExceptDSStore() async throws {
        let tree = try TempTree()
        let trash = try tree.dir(".Trash")
        try tree.file(".Trash/a.bin", bytes: 4096)
        try tree.file(".Trash/folder/b.bin", bytes: 8192)
        try tree.file(".Trash/.DS_Store")
        let fake = FakeRemover()
        let emptier = TrashEmptier(trashURL: trash, remover: fake)
        let (progress, summary) = await collect(try emptier.erase(nil, confirm: true))

        #expect(Set(fake.paths.map { URL(fileURLWithPath: $0).lastPathComponent }) == ["a.bin", "folder"])
        #expect(summary?.succeeded == 2)
        #expect(summary?.failed == 0)
        #expect((summary?.bytesFreed ?? 0) >= 12_288)
        #expect(progress.map(\.current) == [0, 1, 2])
        #expect(progress.last?.bytesFreed == summary?.bytesFreed)
    }

    @Test func oneFailureDoesNotStopTheRest() async throws {
        let tree = try TempTree()
        let trash = try tree.dir(".Trash")
        let locked = try tree.file(".Trash/locked.bin")
        let fine = try tree.file(".Trash/fine.bin")
        let fake = FakeRemover(failing: ["locked.bin"])
        let emptier = TrashEmptier(trashURL: trash, remover: fake, measuresSize: false)
        let (_, summary) = await collect(try emptier.erase([locked.path, fine.path], confirm: true))

        #expect(summary?.succeeded == 1)
        #expect(summary?.failed == 1)
        #expect(summary?.failures.first?.path == locked.path)
        #expect(summary?.failures.first?.error?.contains("locked") == true)
        #expect(fake.paths == [fine.path])
    }

    @Test func realRemoverDeletesForGood() async throws {
        let tree = try TempTree()
        let trash = try tree.dir(".Trash")
        let item = try tree.file(".Trash/gone/file.bin", bytes: 1024)
        let emptier = TrashEmptier(trashURL: trash)
        let (_, summary) = await collect(try emptier.erase([item.deletingLastPathComponent().path], confirm: true))
        #expect(summary?.succeeded == 1)
        #expect(!FileManager.default.fileExists(atPath: tree.url(".Trash/gone").path))
    }
}
