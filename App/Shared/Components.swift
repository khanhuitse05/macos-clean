import AppKit
import MacosCleanCore
import SwiftUI

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
