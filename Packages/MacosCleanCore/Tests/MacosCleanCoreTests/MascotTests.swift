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

@Suite("MascotMood whoa")
struct MascotWhoaTests {
    private func inputs(results: Bool = true, found: Int64 = 1, largest: Int64, scanning: Bool = false, trashing: Bool = false) -> MascotInputs {
        MascotInputs(isScanning: scanning, hasResults: results, foundBytes: found, isTrashing: trashing,
                     isAccessBlocked: false, largestItemBytes: largest)
    }

    @Test func hugeItemGetsWhoa() {
        let edge = MascotMood.whoaThreshold
        #expect(MascotMood.resolve(inputs(largest: edge)) == .whoa(edge))
        #expect(MascotMood.resolve(inputs(found: edge * 2, largest: edge - 1)) == .junkFound(edge * 2))
        #expect(MascotMood.resolve(inputs(results: false, largest: edge)) == .whoa(edge))
    }

    @Test func scanningAndTrashingBeatWhoa() {
        #expect(MascotMood.resolve(inputs(largest: 50_000_000_000, scanning: true)) == .scanning)
        #expect(MascotMood.resolve(inputs(largest: 50_000_000_000, trashing: true)) == .cleaning)
    }
}

@Suite("MascotReaction")
struct MascotReactionTests {
    @Test func selectionReactions() {
        #expect(MascotReaction.forSelection(from: 0, to: 0) == nil)
        #expect(MascotReaction.forSelection(from: 0, to: 0.1) == .gulp)
        #expect(MascotReaction.forSelection(from: 0.1, to: 0.9) == .bigGulp)
        #expect(MascotReaction.forSelection(from: 0.9, to: 0.2) == .spit)
    }

    @Test func depthReactions() {
        #expect(MascotReaction.forDepth(from: 1, to: 2) == .dive)
        #expect(MascotReaction.forDepth(from: 3, to: 1) == .surface)
        #expect(MascotReaction.forDepth(from: 2, to: 2) == nil)
    }

    @Test func selectionScaleIsClamped() {
        #expect(MascotReaction.selectionScale(-1) == 1)
        #expect(MascotReaction.selectionScale(0.5) > 1)
        #expect(MascotReaction.selectionScale(5) == MascotReaction.selectionScale(1))
    }
}
