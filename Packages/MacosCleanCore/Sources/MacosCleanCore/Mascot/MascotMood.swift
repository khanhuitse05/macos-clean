import Foundation

/// What the mascot (Bubbl) is feeling, derived from the app's state.
///
/// One-shot moments (the pop after a clean, the 5-click easter egg) and accessories
/// (the leftovers chip) are layered on top by the view; they are not moods.
public enum MascotMood: Equatable, Sendable {
    /// Nothing scanned yet: gentle float, slow wobble, blinks.
    case idle
    /// A scan is running: drifts left and right with a magnifier glint.
    case scanning
    /// Results are in: puffs up in proportion to the junk found.
    case junkFound(Int64)
    /// Items are moving to the Trash: pulls dust specks inside and turns cloudy.
    case cleaning
    /// Results are in, but there is (almost) nothing to clean: small, clear and sleepy.
    case nothingToClean
    /// Full Disk Access is missing and nothing could be shown: squished against a glass pane.
    case blocked
    /// One single item is huge (see ``MascotMood/whoaThreshold``): wide eyes, open mouth.
    case whoa(Int64)
}

/// The app state the mood is derived from.
public struct MascotInputs: Equatable, Sendable {
    public var isScanning: Bool
    public var hasResults: Bool
    public var foundBytes: Int64
    public var isTrashing: Bool
    public var isAccessBlocked: Bool
    /// The biggest single item in view (a large file, the selected app). 0 when unknown.
    public var largestItemBytes: Int64

    public init(
        isScanning: Bool, hasResults: Bool, foundBytes: Int64, isTrashing: Bool, isAccessBlocked: Bool,
        largestItemBytes: Int64 = 0
    ) {
        self.isScanning = isScanning
        self.hasResults = hasResults
        self.foundBytes = foundBytes
        self.isTrashing = isTrashing
        self.isAccessBlocked = isAccessBlocked
        self.largestItemBytes = largestItemBytes
    }
}

public extension MascotMood {
    /// Below this, results count as "nothing to clean".
    static let nothingThreshold: Int64 = 50 * 1_000_000

    /// Junk sizes at which the puff starts and stops growing.
    static let puffRange: ClosedRange<Double> = 100e6...200e9
    /// Scale at the bottom and top of ``puffRange``.
    static let puffScaleRange: ClosedRange<Double> = 1.0...1.35

    /// A single item at least this big gets a "whoa".
    static let whoaThreshold: Int64 = 10 * 1_000_000_000

    /// Priority: cleaning › scanning › whoa (one huge item) › blocked (only while there's
    /// nothing to show) › junk found / nothing to clean › idle.
    static func resolve(_ inputs: MascotInputs) -> MascotMood {
        if inputs.isTrashing { return .cleaning }
        if inputs.isScanning { return .scanning }
        if inputs.largestItemBytes >= whoaThreshold { return .whoa(inputs.largestItemBytes) }
        if inputs.hasResults {
            return inputs.foundBytes < nothingThreshold ? .nothingToClean : .junkFound(inputs.foundBytes)
        }
        if inputs.isAccessBlocked { return .blocked }
        return .idle
    }

    /// How much the bubble puffs up for `bytes` of junk: log-scaled, clamped to ``puffScaleRange``.
    static func puffScale(for bytes: Int64) -> Double {
        let low = log(puffRange.lowerBound)
        let high = log(puffRange.upperBound)
        let value = log(max(Double(bytes), puffRange.lowerBound))
        let fraction = min(1, max(0, (value - low) / (high - low)))
        return puffScaleRange.lowerBound + fraction * (puffScaleRange.upperBound - puffScaleRange.lowerBound)
    }
}

/// A short one-off animation in answer to something the user just did.
public enum MascotReaction: Equatable, Sendable {
    /// Something was selected: a quick swallow.
    case gulp
    /// Most of what's on screen was selected at once (Select All): a big swallow.
    case bigGulp
    /// Something was deselected: a small shrink and puff out.
    case spit
    /// Went one folder deeper: dips down and comes back.
    case dive
    /// Went back up a folder: bobs up.
    case surface
    /// Looked at a newly selected item.
    case glance
}

public extension MascotReaction {
    /// A jump in selected share at least this big counts as a big gulp.
    static let bigGulpJump = 0.5

    /// The reaction to the selected share going from `old` to `new` (both 0…1, or bytes
    /// compared against the same total).
    static func forSelection(from old: Double, to new: Double) -> MascotReaction? {
        guard old != new else { return nil }
        if new < old { return .spit }
        return new - old >= bigGulpJump ? .bigGulp : .gulp
    }

    /// The reaction to the browsing depth (number of open folder columns) changing.
    static func forDepth(from old: Int, to new: Int) -> MascotReaction? {
        if new > old { return .dive }
        if new < old { return .surface }
        return nil
    }

    /// How much the bubble grows with the selected share (0…1) of what's on screen.
    static func selectionScale(_ share: Double) -> Double {
        1 + 0.12 * min(1, max(0, share))
    }
}
