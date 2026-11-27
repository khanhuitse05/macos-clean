import Foundation
import Testing
@testable import MacosCleanCore

@Suite("EntryFilter")
struct EntryFilterTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func entry(_ path: String, _ bytes: Int64, daysOld: Double? = nil) -> FileEntry {
        FileEntry(
            path: path, sizeBytes: bytes, isDirectory: true,
            modified: daysOld.map { now.addingTimeInterval(-$0 * 86_400) }
        )
    }

    var sample: [FileEntry] {
        [
            entry("/Users/me/Library/Caches/com.apple.Safari", 50_000_000, daysOld: 2),
            entry("/Users/me/Library/Caches/Homebrew", 2_000_000_000, daysOld: 400),
            entry("/Users/me/Library/Caches/pip", 5_000_000, daysOld: 40),
            entry("/Users/me/Library/Caches/unknown", 200_000_000, daysOld: nil),
        ]
    }

    @Test func defaultFilterIsInactiveAndKeepsEverything() {
        let filter = EntryFilter()
        #expect(!filter.isActive)
        #expect(filter.apply(to: sample, now: now).count == sample.count)
    }

    @Test func sortAloneDoesNotCountAsActive() {
        #expect(!EntryFilter(sort: .name).isActive)
        #expect(!EntryFilter(query: "   ").isActive)
    }

    @Test func searchMatchesNameOrPathIgnoringCase() {
        let byName = EntryFilter(query: "homebrew").apply(to: sample, now: now)
        #expect(byName.map(\.name) == ["Homebrew"])
        let byPath = EntryFilter(query: "library/caches").apply(to: sample, now: now)
        #expect(byPath.count == sample.count)
        #expect(EntryFilter(query: "nothing-like-this").apply(to: sample, now: now).isEmpty)
    }

    @Test func searchAlsoMatchesTheDisplayLabel() {
        let device = entry("/Users/me/Library/Developer/CoreSimulator/Devices/AAA-111", 1_000)
        let filter = EntryFilter(query: "iPhone 18")
        #expect(filter.matches(device, label: "iPhone 18 Pro", now: now))
        #expect(!filter.matches(device, label: "iPad Air", now: now))
    }

    @Test func minimumSizeDropsSmallerEntries() {
        let kept = EntryFilter(minimumSize: .hundredMB).apply(to: sample, now: now)
        #expect(kept.map(\.name) == ["Homebrew", "unknown"])
        #expect(EntryFilter(minimumSize: .oneGB).apply(to: sample, now: now).map(\.name) == ["Homebrew"])
    }

    @Test func minimumAgeKeepsOnlyOldEnoughDatedEntries() {
        let month = EntryFilter(minimumAge: .oneMonth).apply(to: sample, now: now)
        #expect(Set(month.map(\.name)) == ["Homebrew", "pip"])
        let year = EntryFilter(minimumAge: .oneYear).apply(to: sample, now: now)
        #expect(year.map(\.name) == ["Homebrew"])
    }

    @Test func undatedEntriesAreHiddenByAnAgeLimit() {
        let kept = EntryFilter(minimumAge: .oneWeek).apply(to: sample, now: now)
        #expect(!kept.contains { $0.name == "unknown" })
    }

    @Test func sortsBySizeNameAndAge() {
        #expect(EntryFilter(sort: .size).apply(to: sample, now: now).map(\.name)
            == ["Homebrew", "unknown", "com.apple.Safari", "pip"])
        #expect(EntryFilter(sort: .name).apply(to: sample, now: now).map(\.name)
            == ["com.apple.Safari", "Homebrew", "pip", "unknown"])
        // Oldest first; undated last.
        #expect(EntryFilter(sort: .oldest).apply(to: sample, now: now).map(\.name)
            == ["Homebrew", "pip", "com.apple.Safari", "unknown"])
    }

    @Test func filtersCombine() {
        let filter = EntryFilter(query: "caches", minimumSize: .tenMB, minimumAge: .oneMonth)
        #expect(filter.apply(to: sample, now: now).map(\.name) == ["Homebrew"])
    }
}
