import AppKit
import MacosCleanCore
import SwiftUI

/// A white symbol on a colored rounded square, the way System Settings draws its sidebar.
/// Keeps its own colors when the row is selected, so the tile reads the same either way.
struct SidebarIcon: View {
    let systemImage: String
    var tint: Color = .gray
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .overlay {
                // Fitted into a fixed box, so wide and tall symbols come out the same size and
                // centered on their drawn shape rather than on the font's baseline.
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.monochrome)
                    .frame(width: size * 0.64, height: size * 0.64)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

enum CheckState: Equatable {
    case off, on, mixed
}

/// A native AppKit checkbox that can show the mixed (–) state.
struct TriStateCheckbox: NSViewRepresentable {
    let state: CheckState
    var isEnabled = true
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = isEnabled
        button.state = switch state {
        case .off: .off
        case .on: .on
        case .mixed: .mixed
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void = {}
        @objc func clicked(_ sender: NSButton) { action() }
    }
}

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Text(safety.label)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(safety == .safe ? Color.green : Color.orange)
            .background((safety == .safe ? Color.green : Color.orange).opacity(0.15), in: .capsule)
    }
}

/// Floating glass bar pinned to the bottom of a feature: what's selected + the primary action.
struct SelectionBar<Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).monospacedDigit()
                    .contentTransition(.numericText())
                    .motionAnimation(.snappy, value: title)
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
                    .motionAnimation(.snappy, value: detail)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

// MARK: - Reduce Motion
//
// With System Settings › Accessibility › Display › Reduce motion on, the app drops movement
// (sliding, scaling, bouncing, rolling digits, animated scrolling) and keeps plain fades:
// - views: `.motionAnimation(_:value:)` and `.motionTransition(_:)` below;
// - SF Symbol effects: removed for the whole window by `.symbolEffectsRemoved` in ContentView;
// - models: `Motion.animate`.

extension View {
    /// `.animation(_:value:)` that turns into no animation when Reduce motion is on.
    func motionAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionAwareAnimation(animation: animation, value: value))
    }

    /// `.transition(_:)` that falls back to a plain fade when Reduce motion is on.
    func motionTransition(_ transition: AnyTransition) -> some View {
        modifier(MotionAwareTransition(transition: transition))
    }
}

private struct MotionAwareAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct MotionAwareTransition: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : transition)
    }
}

/// Animation helpers that respect System Settings › Accessibility › Display › Reduce motion,
/// for state changes made outside a view (models can't read the environment).
@MainActor
enum Motion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Runs `body` inside `withAnimation`, or without animation when Reduce motion is on.
    static func animate<Result>(_ animation: Animation = .snappy, _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(reduceMotion ? nil : animation, body)
    }
}

/// A byte count that counts up or down smoothly when `bytes` changes inside an animation.
@Animatable
struct CountingBytes: View {
    var bytes: Double

    var body: some View {
        Text(Int64(max(0, bytes)).fileSize)
            .monospacedDigit()
    }
}

/// A handful of sparkles that fly outward and fade each time `trigger` changes.
struct SparkleBurst: View {
    let trigger: Int
    var tint: Color = .yellow

    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                let angle = Self.angle(index)
                Image(systemName: "sparkle")
                    .font(.system(size: index.isMultiple(of: 2) ? 9 : 6, weight: .bold))
                    .foregroundStyle(tint)
                    .keyframeAnimator(initialValue: Spark(), trigger: trigger) { content, spark in
                        content
                            .offset(x: spark.distance * cos(angle), y: spark.distance * sin(angle))
                            .scaleEffect(spark.scale)
                            .opacity(spark.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.distance) { CubicKeyframe(22, duration: 0.7) }
                        KeyframeTrack(\.scale) {
                            SpringKeyframe(1.2, duration: 0.25)
                            CubicKeyframe(0.4, duration: 0.45)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(1, duration: 0.1)
                            LinearKeyframe(1, duration: 0.3)
                            LinearKeyframe(0, duration: 0.3)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func angle(_ index: Int) -> Double { -Double.pi / 2 + Double(index - 2) * 0.55 }

    private struct Spark {
        var distance: Double = 0
        var scale: Double = 0.2
        var opacity: Double = 0
    }
}

// MARK: - Fly-to-Trash origins

/// Remembers a view's frame in the window-wide ``TrashFlight/space`` without re-rendering
/// anything when it changes (scrolling moves it every frame).
final class FrameBox {
    var rect: CGRect?
}

extension View {
    /// Records this view's frame into `box`, so a move to the Trash can fly from here.
    func trashOrigin(_ box: FrameBox) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TrashFlight.space)) } action: { box.rect = $0 }
    }
}

/// Gives `content` its own ``FrameBox``, so an action in a row's context menu can fly from
/// that row.
struct TrashOriginReader<Content: View>: View {
    @State private var box = FrameBox()
    @ViewBuilder let content: (FrameBox) -> Content

    var body: some View {
        content(box).trashOrigin(box)
    }
}
