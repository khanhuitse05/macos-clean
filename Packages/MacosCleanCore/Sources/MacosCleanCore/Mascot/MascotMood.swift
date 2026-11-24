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
}

/// The app state the mood is derived from.
public struct MascotInputs: Equatable, Sendable {
    public var isScanning: Bool
    public var hasResults: Bool
    public var foundBytes: Int64
    public var isTrashing: Bool
    public var isAccessBlocked: Bool

    public init(isScanning: Bool, hasResults: Bool, foundBytes: Int64, isTrashing: Bool, isAccessBlocked: Bool) {
        self.isScanning = isScanning
        self.hasResults = hasResults
        self.foundBytes = foundBytes
        self.isTrashing = isTrashing
        self.isAccessBlocked = isAccessBlocked
    }
}

public extension MascotMood {
    /// Below this, results count as "nothing to clean".
    static let nothingThreshold: Int64 = 50 * 1_000_000

    /// Junk sizes at which the puff starts and stops growing.
    static let puffRange: ClosedRange<Double> = 100e6...200e9
    /// Scale at the bottom and top of ``puffRange``.
    static let puffScaleRange: ClosedRange<Double> = 1.0...1.35

    /// Priority: cleaning › scanning › blocked (only while there's nothing to show) ›
    /// junk found / nothing to clean › idle.
    static func resolve(_ inputs: MascotInputs) -> MascotMood {
        if inputs.isTrashing { return .cleaning }
        if inputs.isScanning { return .scanning }
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
