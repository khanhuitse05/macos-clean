import Foundation
import MacosCleanCore

/// Everything about Bubbl's look that depends on the mood. When the mood changes, the old and
/// new poses are blended over ``BubblPose/blendDuration`` inside the motion clock.
///
/// Speeds are shared by every mood (see ``BubblMotion``); only amplitudes change, so blending
/// never makes a wave jump phase.
struct BubblPose: Equatable {
    var scale = 1.0
    var squashX = 1.0
    var squashY = 1.0
    /// Horizontal resting offset (pt), used to press against the glass pane.
    var offsetX = 0.0
    var floatAmp = 3.0
    var wobbleAmp = 0.025
    var driftAmp = 0.0
    /// 0 clear … 1 cloudy grey (pulling dust inside).
    var cloud = 0.0
    /// Brighter rim and clearer fill (freshly clean, nothing to do).
    var clarity = 0.0
    /// Eye height: 1 open, above 1 wide, below 0.5 sleepy.
    var eyeOpen = 1.0
    var eyeLookX = 0.0
    /// Glass pane + padlock (Full Disk Access blocked).
    var pane = 0.0
    /// Magnifier glint sweeping across (scanning).
    var glint = 0.0
    // Particle layers, as opacity multipliers.
    var trail = 0.0
    var dust = 0.0
    var zzz = 0.0
    /// Open "O" mouth (whoa).
    var mouth = 0.0

    static let blendDuration = 0.6

    static func `for`(_ mood: MascotMood) -> BubblPose {
        var pose = BubblPose()
        switch mood {
        case .idle:
            break
        case .scanning:
            pose.driftAmp = 12
            pose.floatAmp = 2
            pose.glint = 1
            pose.trail = 1
            pose.wobbleAmp = 0.03
        case .junkFound(let bytes):
            pose.scale = MascotMood.puffScale(for: bytes)
            pose.eyeOpen = 1.1
            pose.wobbleAmp = 0.03
        case .cleaning:
            pose.scale = 0.95
            pose.cloud = 1
            pose.dust = 1
            pose.eyeOpen = 0.55
            pose.wobbleAmp = 0.045
        case .nothingToClean:
            pose.scale = 0.8
            pose.clarity = 1
            pose.eyeOpen = 0.3
            pose.floatAmp = 2
            pose.wobbleAmp = 0.012
            pose.zzz = 1
        case .blocked:
            pose.squashX = 1.12
            pose.squashY = 0.88
            pose.offsetX = -10
            pose.floatAmp = 1
            pose.wobbleAmp = 0.01
            pose.eyeLookX = 3
            pose.pane = 1
        case .whoa(let bytes):
            pose.scale = MascotMood.puffScale(for: bytes)
            pose.eyeOpen = 1.35
            pose.mouth = 1
            pose.wobbleAmp = 0.04
        }
        return pose
    }

    /// Linear blend: `fraction` 0 is `self`, 1 is `other`.
    func mixed(with other: BubblPose, _ fraction: Double) -> BubblPose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        return BubblPose(
            scale: mix(scale, other.scale),
            squashX: mix(squashX, other.squashX),
            squashY: mix(squashY, other.squashY),
            offsetX: mix(offsetX, other.offsetX),
            floatAmp: mix(floatAmp, other.floatAmp),
            wobbleAmp: mix(wobbleAmp, other.wobbleAmp),
            driftAmp: mix(driftAmp, other.driftAmp),
            cloud: mix(cloud, other.cloud),
            clarity: mix(clarity, other.clarity),
            eyeOpen: mix(eyeOpen, other.eyeOpen),
            eyeLookX: mix(eyeLookX, other.eyeLookX),
            pane: mix(pane, other.pane),
            glint: mix(glint, other.glint),
            trail: mix(trail, other.trail),
            dust: mix(dust, other.dust),
            zzz: mix(zzz, other.zzz),
            mouth: mix(mouth, other.mouth)
        )
    }
}

/// Shared wave speeds (radians per second) and small math helpers for the motion clock.
enum BubblMotion {
    static let floatSpeed = 1.1
    static let driftSpeed = 1.2
    static let wobbleSpeed = 2.0
    /// Degrees per second the iridescent shimmer turns.
    static let shimmerSpeed = 25.0
    static let glintPeriod = 1.8

    /// Stable pseudo-random value in 0..<1 for an index, so particles need no stored state.
    static func hash(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
    static func easeIn(_ x: Double) -> Double { pow(clamp(x), 2) }
    static func easeInOut(_ x: Double) -> Double {
        let x = clamp(x)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// Overshoots a little before settling at 1.
    static func backOut(_ x: Double) -> Double {
        let x = clamp(x)
        let c1 = 1.70158
        let c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    /// 0 open … 1 closed. One blink every 6–10 s, lasting 0.16 s.
    static func blink(at t: Double) -> Double {
        let period = 8.0
        let length = 0.16
        let cycle = Int(floor(t / period))
        for index in [cycle - 1, cycle] {
            let start = Double(index) * period + 1 + hash(index) * 2
            let elapsed = t - start
            if elapsed >= 0, elapsed < length { return sin(elapsed / length * .pi) }
        }
        return 0
    }
}

/// M5: inflate, pop into sparkles, then a fresh clear bubble reforms.
struct BubblPopPhase {
    static let duration = 1.3
    static let burstStart = 0.22
    static let reformStart = 0.7

    var scale = 1.0

    init(elapsed e: Double?) {
        guard let e, e < Self.duration else { return }
        switch e {
        case ..<0.18: scale = 1 + 0.15 * BubblMotion.easeOut(e / 0.18)
        case ..<0.26: scale = 1.15 * (1 - (e - 0.18) / 0.08)
        case ..<Self.reformStart: scale = 0
        default: scale = BubblMotion.backOut((e - Self.reformStart) / 0.55)
        }
    }
}

/// M9: splits into three mini bubbles that wobble and merge back.
struct BubblSplitPhase {
    static let duration = 1.7

    var mainScale = 1.0
    var miniScale = 0.0
    var distance = 0.0

    var isActive: Bool { miniScale > 0.001 }

    init(elapsed e: Double?) {
        guard let e, e < Self.duration else { return }
        switch e {
        case ..<0.2: mainScale = 1 - e / 0.2
        case ..<1.45: mainScale = 0
        default: mainScale = BubblMotion.backOut((e - 1.45) / 0.25)
        }
        switch e {
        case ..<0.1: miniScale = 0
        case ..<0.3: miniScale = BubblMotion.easeOut((e - 0.1) / 0.2)
        case ..<1.4: miniScale = 1
        case ..<1.5: miniScale = 1 - (e - 1.4) / 0.1
        default: miniScale = 0
        }
        let reach = 30.0
        switch e {
        case ..<0.15: distance = 0
        case ..<0.45: distance = reach * BubblMotion.easeOut((e - 0.15) / 0.3)
        case ..<1.15: distance = reach + 3 * sin((e - 0.45) * 14)
        default: distance = reach * (1 - BubblMotion.easeInOut((e - 1.15) / 0.3))
        }
    }
}

/// Short reactions to what the user just did (see ``MascotReaction``).
struct BubblReactionPhase {
    var scaleX = 1.0
    var scaleY = 1.0
    var offsetY = 0.0
    /// 0 open … 1 eyes squeezed shut.
    var squint = 0.0
    /// 0 … 1 toward the content (glance).
    var look = 0.0

    static func duration(of kind: MascotReaction) -> Double {
        switch kind {
        case .gulp: 0.45
        case .bigGulp: 0.8
        case .spit: 0.4
        case .dive, .surface: 0.7
        case .glance: 1.2
        }
    }

    init(kind: MascotReaction?, elapsed e: Double?) {
        guard let kind, let e, e >= 0 else { return }
        let length = Self.duration(of: kind)
        guard e < length else { return }
        let p = e / length
        let bump = sin(p * .pi)
        switch kind {
        case .gulp:
            scaleX = 1 + 0.10 * bump
            scaleY = 1 - 0.07 * bump
            squint = bump
        case .bigGulp:
            // Two swallows, the second smaller.
            let wave = abs(sin(p * .pi * 2)) * (1 - p * 0.5)
            scaleX = 1 + 0.2 * wave
            scaleY = 1 - 0.13 * wave
            squint = wave
        case .spit:
            scaleX = 1 - 0.08 * bump
            scaleY = 1 - 0.08 * bump
        case .dive:
            offsetY = 16 * bump
            scaleX = 1 - 0.05 * bump
            scaleY = 1 + 0.08 * bump
        case .surface:
            offsetY = -14 * bump
            scaleX = 1 - 0.04 * bump
            scaleY = 1 + 0.06 * bump
        case .glance:
            look = min(1, p * 5) * min(1, (1 - p) * 4)
        }
    }
}
