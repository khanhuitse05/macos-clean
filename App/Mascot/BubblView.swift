import AppKit
import MacosCleanCore
import SwiftUI

/// Bubbl, the macos-clean mascot: a soap bubble that reacts to scans, selections and cleanups.
/// Floats in a corner of every section (see ``MascotOverlay``).
///
/// One motion clock (`TimelineView`, 20 fps) drives float, wobble, shimmer, blinks and particles
/// from the time alone. Mood changes blend over 0.6 s; with Reduce motion on the clock is paused
/// and each mood is a still pose.
struct BubblView: View {
    let mood: MascotMood
    var celebration: TrashCoordinator.Celebration?
    var leftoverCount = 0
    var onBlockedTap: () -> Void = {}
    var onLeftoversTap: () -> Void = {}
    /// Share (0…1) of what's on screen that's ticked; the bubble grows with it.
    var selectionShare = 0.0
    /// The latest reaction to play; a new `id` starts it.
    var reaction: Reaction?
    /// An app being uninstalled, shown inside the bubble while it's cleaning.
    var carriedAppPath: String?
    /// Where the content is, seen from Bubbl (-1…1 each way): glances look there.
    var lookToward = CGVector(dx: -1, dy: -1)

    struct Reaction: Equatable {
        let id = UUID()
        let kind: MascotReaction
    }

    static let radius: CGFloat = 38
    static let stageSize = CGSize(width: 150, height: 124)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @AppStorage(MascotSettings.showKey) private var showMascot = true

    @State private var epoch = Date()
    @State private var blend: (from: BubblPose, at: Date)?
    @State private var pop: (id: UUID, at: Date)?
    @State private var splitAt: Date?
    @State private var pokeAt: Date?
    @State private var taps: [Date] = []
    @State private var playing: (kind: MascotReaction, at: Date)?
    @State private var shareBlend: (from: Double, at: Date)?

    var body: some View {
        VStack(spacing: 2) {
            // 20 fps is plenty for slow float and wobble. The clock stops while the window isn't
            // active, so a background window costs nothing.
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || !appearsActive)) { context in
                stage(at: reduceMotion ? epoch : context.date)
            }
            .frame(width: Self.stageSize.width, height: Self.stageSize.height)
            // Kept outside the clock so they aren't rebuilt every frame.
            .help(mood == .blocked
                ? "Full Disk Access is off. Click to see how to allow it."
                : "Drag Bubbl to another corner. Right-click to hide it.")
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(mood != .blocked)
            .accessibilityLabel("Full Disk Access is off. Show how to allow it.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onBlockedTap() }
            .contextMenu {
                Button("Hide Mascot", systemImage: "eye.slash") { showMascot = false }
            }

            if leftoverCount > 0 {
                leftoversChip
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: leftoverCount > 0)
        .onChange(of: mood) { old, _ in
            guard !reduceMotion else { return }
            let now = Date()
            // Start from wherever the previous blend had got to, so quick changes stay smooth.
            blend = (blendedPose(target: .for(old), at: now), now)
        }
        .onChange(of: celebration?.id) { _, id in
            guard let id, !reduceMotion else { return }
            pop = (id, Date())
        }
        .onChange(of: reaction) { _, reaction in
            guard let reaction, !reduceMotion else { return }
            playing = (reaction.kind, Date())
        }
        .onChange(of: selectionShare) { old, _ in
            guard !reduceMotion else { return }
            let now = Date()
            shareBlend = (displayedShare(target: old, at: now), now)
        }
    }

    // MARK: Stage

    private func stage(at date: Date) -> some View {
        let t = date.timeIntervalSince(epoch)
        let r = Self.radius
        let size = Self.stageSize
        let pose = blendedPose(target: .for(mood), at: date)

        let popElapsed = pop.map { date.timeIntervalSince($0.at) }
        let popPhase = BubblPopPhase(elapsed: popElapsed)
        let split = BubblSplitPhase(elapsed: splitAt.map { date.timeIntervalSince($0) })
        let poke = pokeAt.map { pokeAmount(date.timeIntervalSince($0)) } ?? 0
        let react = BubblReactionPhase(kind: playing?.kind, elapsed: playing.map { date.timeIntervalSince($0.at) })
        let grow = MascotReaction.selectionScale(displayedShare(target: selectionShare, at: date))

        let base = CGPoint(x: size.width / 2 + pose.offsetX, y: size.height / 2)
        let center = CGPoint(
            x: base.x + sin(t * BubblMotion.driftSpeed) * pose.driftAmp,
            y: base.y + sin(t * BubblMotion.floatSpeed) * pose.floatAmp + react.offsetY
        )
        let wobble = sin(t * BubblMotion.wobbleSpeed) * pose.wobbleAmp + poke
        let scale = pose.scale * popPhase.scale * split.mainScale * grow

        let labelProgress: Double? = {
            guard let celebration else { return nil }
            if reduceMotion { return 1 }
            guard let pop, pop.id == celebration.id, let popElapsed,
                  popElapsed >= BubblPopPhase.reformStart else { return nil }
            return BubblMotion.easeOut((popElapsed - BubblPopPhase.reformStart) / 1.1)
        }()

        let hasParticles = pose.trail > 0.01 || pose.dust > 0.01 || pose.zzz > 0.01
            || leftoverCount > 0 || (popElapsed.map { $0 < BubblPopPhase.duration } ?? false)

        return ZStack {
            if hasParticles && !reduceMotion {
                BubblParticles(
                    t: t, pose: pose, base: base, center: center, radius: r * pose.scale,
                    popElapsed: popElapsed, showsLeftovers: leftoverCount > 0
                )
            }

            if pose.pane > 0.01 {
                GlassPane(height: r * 2.3)
                    .opacity(pose.pane)
                    .position(x: size.width / 2 + pose.offsetX + r * pose.squashX + 7, y: size.height / 2)
            }

            if split.isActive {
                ForEach(0..<3, id: \.self) { index in
                    let angle = (-90 + Double(index) * 120) * .pi / 180
                    let jiggle = sin(t * 9 + Double(index) * 2) * 0.07
                    ZStack {
                        BubblBody(radius: r * 0.42, shimmer: t * BubblMotion.shimmerSpeed + Double(index) * 60)
                        BubblEyes(size: r * 0.84, open: 1, blink: 0, lookX: 0, happy: false)
                            .offset(y: -r * 0.06)
                    }
                    .scaleEffect(x: split.miniScale * (1 + jiggle), y: split.miniScale * (1 - jiggle))
                    .position(x: center.x + cos(angle) * split.distance, y: center.y + sin(angle) * split.distance)
                }
            }

            bubble(t: t, pose: pose, labelProgress: labelProgress, react: react)
                .scaleEffect(
                    x: max(0.001, scale * pose.squashX * react.scaleX * (1 + wobble)),
                    y: max(0.001, scale * pose.squashY * react.scaleY * (1 - wobble))
                )
                .position(center)
        }
        .frame(width: size.width, height: size.height)
    }

    private func bubble(t: Double, pose: BubblPose, labelProgress: Double?, react: BubblReactionPhase) -> some View {
        let r = Self.radius
        let happy = labelProgress != nil
        let glintPhase = (t.truncatingRemainder(dividingBy: BubblMotion.glintPeriod)) / BubblMotion.glintPeriod
        // Eyes follow the scanning drift, and glance toward the content after a selection.
        let look = pose.eyeLookX + (pose.driftAmp / 12) * 3 * cos(t * BubblMotion.driftSpeed)
            + react.look * lookToward.dx * 5
        let carrying = carriedAppPath != nil && mood == .cleaning && !happy
        let whoaBytes: Int64? = if case .whoa(let bytes) = mood, !happy, !carrying { bytes } else { nil }
        let eyesY = happy ? -r * 0.32 : (carrying ? -r * 0.5 : (pose.mouth > 0.5 ? -r * 0.28 : -r * 0.12))

        return ZStack {
            BubblBody(
                radius: r,
                shimmer: t * BubblMotion.shimmerSpeed,
                cloud: pose.cloud,
                clarity: pose.clarity,
                glint: pose.glint,
                glintX: glintPhase * 2 - 1
            )
            BubblEyes(
                size: r * 2,
                open: pose.eyeOpen,
                blink: reduceMotion ? 0 : max(BubblMotion.blink(at: t), react.squint * 0.85),
                lookX: look,
                happy: happy
            )
            .offset(y: eyesY + react.look * lookToward.dy * 3)

            if pose.mouth > 0.05, !happy, !carrying {
                Ellipse()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: r * 0.2, height: r * 0.26)
                    .scaleEffect(pose.mouth)
                    .offset(y: r * 0.04)
            }
            if let whoaBytes {
                Text(whoaBytes.fileSize)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: r * 1.3)
                    .offset(y: r * 0.42)
            }
            if carrying, let carriedAppPath {
                CarriedAppIcon(path: carriedAppPath)
                    .frame(width: r * 0.95, height: r * 0.95)
                    .offset(y: r * 0.18 + sin(t * 3) * 2)
                    .transition(.opacity)
            }

            if let labelProgress, let celebration {
                FreedLabel(
                    bytes: Int64(Double(celebration.bytes) * labelProgress),
                    // Once the count-up is done, the second line shows the lifetime total (N2).
                    lifetimeBytes: labelProgress >= 1 ? celebration.lifetimeBytes : 0
                )
                    .frame(width: r * 1.5)
                    .offset(y: r * 0.2)
                    .transition(.opacity)
            }
        }
        .frame(width: r * 2, height: r * 2)
        .contentShape(Circle())
        .onTapGesture(perform: tapped)
    }

    private var leftoversChip: some View {
        Button(action: onLeftoversTap) {
            Label(
                leftoverCount == 1
                    ? "1 removed app left files behind"
                    : "\(leftoverCount) removed apps left files behind",
                systemImage: "bubbles.and.sparkles"
            )
            .font(.caption)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .fixedSize()
        .help("Open the Uninstaller to review and clean up what those apps left behind")
    }

    // MARK: State

    /// The selection share shown right now, easing toward `target` after a change.
    private func displayedShare(target: Double, at date: Date) -> Double {
        guard !reduceMotion, let shareBlend else { return target }
        let fraction = BubblMotion.easeOut(date.timeIntervalSince(shareBlend.at) / 0.45)
        return shareBlend.from + (target - shareBlend.from) * fraction
    }

    private func blendedPose(target: BubblPose, at date: Date) -> BubblPose {
        guard !reduceMotion, let blend else { return target }
        let fraction = BubblMotion.easeInOut(date.timeIntervalSince(blend.at) / BubblPose.blendDuration)
        return fraction >= 1 ? target : blend.from.mixed(with: target, fraction)
    }

    /// A quick squish when clicked: squashes and springs back in 0.35 s.
    private func pokeAmount(_ elapsed: Double) -> Double {
        let length = 0.35
        guard elapsed >= 0, elapsed < length else { return 0 }
        return sin(elapsed / length * .pi * 2) * (1 - elapsed / length) * 0.08
    }

    private func tapped() {
        if mood == .blocked {
            onBlockedTap()
            return
        }
        guard !reduceMotion else { return }
        let now = Date()
        pokeAt = now
        taps = taps.filter { now.timeIntervalSince($0) < 2 } + [now]
        let splitIsOver = splitAt.map { now.timeIntervalSince($0) >= BubblSplitPhase.duration } ?? true
        if taps.count >= 5, splitIsOver {
            splitAt = now
            taps = []
        }
    }
}

// MARK: - Parts

/// The bubble itself: faint tinted fill, an iridescent band near the rim, highlights.
///
/// Each layer's content is fixed and rasterized once (`drawingGroup`); per frame only its
/// transform (rotation, offset) or opacity changes, which is cheap to composite.
struct BubblBody: View {
    let radius: CGFloat
    var shimmer: Double = 0
    var cloud: Double = 0
    var clarity: Double = 0
    var glint: Double = 0
    /// Glint position across the bubble, -1 (left) … 1 (right).
    var glintX: Double = 0

    var body: some View {
        let diameter = radius * 2
        ZStack {
            BubblFill(radius: radius)
            BubblIridescence(radius: radius, strength: 0.32)
                .rotationEffect(.degrees(shimmer))
            if clarity > 0.01 {
                BubblIridescence(radius: radius, strength: 0.18)
                    .rotationEffect(.degrees(shimmer))
                    .opacity(clarity)
            }
            if cloud > 0.01 {
                BubblCloud(radius: radius).opacity(cloud)
            }
            if glint > 0.01 {
                BubblGlint(radius: radius)
                    .offset(x: glintX * radius * 1.5)
                    .opacity(glint)
            }
            BubblRim(radius: radius)
                .rotationEffect(.degrees(-shimmer * 0.7))
            BubblHighlights(radius: radius)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}

private let bubblHues: [Color] = [.pink, .orange, .yellow, .mint, .cyan, .indigo, .purple, .pink]

private struct BubblFill: View {
    let radius: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color.cyan.opacity(0.03), Color.cyan.opacity(0.11)],
                center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: radius
            ))
            .frame(width: radius * 2, height: radius * 2)
            .drawingGroup()
    }
}

/// Coloured band near the edge. Round, so it can be rotated for the shimmer without redrawing.
private struct BubblIridescence: View {
    let radius: CGFloat
    let strength: Double

    var body: some View {
        Circle()
            .fill(AngularGradient(colors: bubblHues.map { $0.opacity(strength) }, center: .center))
            .mask(RadialGradient(
                stops: [.init(color: .clear, location: 0.55), .init(color: .white, location: 1)],
                center: .center, startRadius: 0, endRadius: radius
            ))
            .frame(width: radius * 2, height: radius * 2)
            .drawingGroup()
    }
}

private struct BubblCloud: View {
    let radius: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color.gray.opacity(0.42), Color.gray.opacity(0.22)],
                center: .center, startRadius: 0, endRadius: radius
            ))
            .frame(width: radius * 2, height: radius * 2)
            .drawingGroup()
    }
}

/// The magnifier glint: a slanted bright band that slides across while scanning.
private struct BubblGlint: View {
    let radius: CGFloat

    var body: some View {
        LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: radius * 0.45, height: radius * 2.8)
            .rotationEffect(.degrees(20))
            .drawingGroup()
    }
}

private struct BubblRim: View {
    let radius: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(AngularGradient(colors: bubblHues.map { $0.opacity(0.6) }, center: .center), lineWidth: 1.6)
            Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}

private struct BubblHighlights: View {
    let radius: CGFloat

    var body: some View {
        ZStack {
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: radius * 0.55, height: radius * 0.3)
                .rotationEffect(.degrees(-35))
                .offset(x: -radius * 0.4, y: -radius * 0.48)
            Circle()
                .fill(.white.opacity(0.8))
                .frame(width: radius * 0.1, height: radius * 0.1)
                .offset(x: radius * 0.52, y: radius * 0.5)
        }
        .frame(width: radius * 2, height: radius * 2)
        .drawingGroup()
    }
}

/// Two dot eyes; `happy` draws them as little arcs (^ ^).
struct BubblEyes: View {
    /// Width of the bubble the eyes sit in.
    let size: CGFloat
    let open: Double
    let blink: Double
    let lookX: Double
    let happy: Bool

    var body: some View {
        HStack(spacing: size * 0.16) {
            eye
            eye
        }
        .offset(x: lookX)
    }

    @ViewBuilder
    private var eye: some View {
        if happy {
            HappyArc()
                .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: max(1.2, size * 0.03), lineCap: .round))
                .frame(width: size * 0.12, height: size * 0.06)
        } else {
            Capsule()
                .fill(Color.primary.opacity(0.82))
                .frame(width: size * 0.085, height: size * 0.12)
                .scaleEffect(x: max(1, open), y: max(0.08, open * (1 - blink * 0.92)))
        }
    }

    private struct HappyArc: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height))
            return path
        }
    }
}

/// The app being uninstalled, inside the bubble as it's carried off to the Trash.
private struct CarriedAppIcon: View {
    let path: String
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) } else { Color.clear }
        }
        .task(id: path) { icon = NSWorkspace.shared.icon(forFile: path) }
    }
}

/// "4.2 GB freed", shown inside the reformed bubble.
private struct FreedLabel: View {
    let bytes: Int64
    var lifetimeBytes: Int64 = 0

    var body: some View {
        VStack(spacing: 0) {
            Text(bytes.fileSize)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(lifetimeBytes > bytes ? "\(lifetimeBytes.fileSize) in all" : "freed")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// M7: the pane of glass Bubbl is squished against, with a padlock on top.
private struct GlassPane: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.clear)
            .frame(width: 9, height: height)
            .glassEffect(.regular, in: .rect(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            }
            .overlay(alignment: .top) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(5)
                    .glassEffect(.regular, in: .circle)
                    .offset(y: -12)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("All moods") {
    let moods: [(String, MascotMood)] = [
        ("Idle", .idle),
        ("Scanning", .scanning),
        ("Junk 1 GB", .junkFound(1_000_000_000)),
        ("Junk 80 GB", .junkFound(80_000_000_000)),
        ("Cleaning", .cleaning),
        ("Nothing", .nothingToClean),
        ("Blocked", .blocked),
        ("Whoa 42 GB", .whoa(42_000_000_000)),
    ]
    return ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) {
            ForEach(moods, id: \.0) { name, mood in
                VStack {
                    BubblView(mood: mood, leftoverCount: name == "Junk 1 GB" ? 2 : 0)
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
    .frame(width: 720, height: 560)
}

#Preview("Celebration") {
    @Previewable @State var celebration: TrashCoordinator.Celebration?
    VStack {
        BubblView(mood: .junkFound(3_000_000_000), celebration: celebration)
        Button("Clean 4.2 GB") {
            celebration = .init(bytes: 4_200_000_000, count: 12)
        }
    }
    .padding()
}
