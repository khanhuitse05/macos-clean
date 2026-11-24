import MacosCleanCore
import SwiftUI

enum MascotSettings {
    /// `UserDefaults` key: whether Bubbl appears in the Storage Manager header.
    static let showKey = "showMascot"
}

struct MascotSettingsSection: View {
    @AppStorage(MascotSettings.showKey) private var showMascot = true

    var body: some View {
        Section {
            Toggle("Show Bubbl in Storage Manager", isOn: $showMascot)
        } header: {
            Text("Mascot")
        } footer: {
            Text("Bubbl reacts to scans and cleanups. When Reduce motion is on in System Settings › Accessibility, Bubbl holds still.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Bubbl as it sits in a header: hidden when the user turned the mascot off.
struct MascotSlot: View {
    let mood: MascotMood
    let celebration: TrashCoordinator.Celebration?
    let leftoverAppCount: Int
    let onBlockedTap: () -> Void
    let onShowLeftovers: () -> Void

    @AppStorage(MascotSettings.showKey) private var showMascot = true

    var body: some View {
        Group {
            if showMascot {
                BubblView(
                    mood: mood,
                    celebration: celebration,
                    leftoverCount: leftoverAppCount,
                    onBlockedTap: onBlockedTap,
                    onLeftoversTap: onShowLeftovers
                )
                .transition(.opacity)
            }
        }
        .motionAnimation(.smooth, value: showMascot)
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            MascotSettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
