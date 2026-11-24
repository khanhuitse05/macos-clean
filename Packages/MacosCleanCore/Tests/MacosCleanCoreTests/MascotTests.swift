import Testing
@testable import MacosCleanCore

@Suite("MascotMood")
struct MascotMoodTests {
    private func inputs(
        scanning: Bool = false, results: Bool = false, found: Int64 = 0,
        trashing: Bool = false, blocked: Bool = false
    ) -> MascotInputs {
        MascotInputs(isScanning: scanning, hasResults: results, foundBytes: found, isTrashing: trashing, isAccessBlocked: blocked)
    }

    @Test func idleBeforeAnyScan() {
        #expect(MascotMood.resolve(inputs()) == .idle)
    }

    @Test func trashingBeatsEverything() {
        #expect(MascotMood.resolve(inputs(scanning: true, results: true, found: 5_000_000_000, trashing: true, blocked: true)) == .cleaning)
    }

    @Test func scanningBeatsResultsAndBlocked() {
        #expect(MascotMood.resolve(inputs(scanning: true, results: true, found: 5_000_000_000, blocked: true)) == .scanning)
    }

    @Test func blockedOnlyWithoutResults() {
        #expect(MascotMood.resolve(inputs(blocked: true)) == .blocked)
        #expect(MascotMood.resolve(inputs(results: true, found: 2_000_000_000, blocked: true)) == .junkFound(2_000_000_000))
    }

    @Test func nothingToCleanThreshold() {
        let edge = MascotMood.nothingThreshold
        #expect(MascotMood.resolve(inputs(results: true, found: 0)) == .nothingToClean)
        #expect(MascotMood.resolve(inputs(results: true, found: edge - 1)) == .nothingToClean)
        #expect(MascotMood.resolve(inputs(results: true, found: edge)) == .junkFound(edge))
    }

    @Test func puffScaleIsClampedAndMonotonic() {
        let range = MascotMood.puffScaleRange
        #expect(MascotMood.puffScale(for: 0) == range.lowerBound)
        #expect(MascotMood.puffScale(for: -5) == range.lowerBound)
        #expect(MascotMood.puffScale(for: 10_000_000_000_000) == range.upperBound)
        var last = 0.0
        for exponent in 6...13 {
            var bytes: Int64 = 1
            for _ in 0..<exponent { bytes *= 10 }
            let scale = MascotMood.puffScale(for: bytes)
            #expect(scale >= last)
            #expect(range.contains(scale))
            last = scale
        }
        #expect(MascotMood.puffScale(for: 10_000_000_000) > MascotMood.puffScale(for: 1_000_000_000))
    }
}
