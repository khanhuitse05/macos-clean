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
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
