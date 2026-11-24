import AppKit
import MacosCleanCore
import SwiftUI

/// Full Disk Access state plus the launch-time explainer.
@MainActor
@Observable
final class AccessModel {
    private(set) var hasFullDiskAccess = true
    var isShowingWelcome = false

    private static let snoozeKey = "fdaWelcomeShownAt"
    private static let snoozeInterval: TimeInterval = 24 * 60 * 60

    func refresh() {
        hasFullDiskAccess = AccessCheck.hasFullDiskAccess()
    }

    /// Shows the explainer at launch when access is missing, at most once a day.
    func showWelcomeIfNeeded() {
        refresh()
        guard !hasFullDiskAccess else { return }
        let last = UserDefaults.standard.double(forKey: Self.snoozeKey)
        guard Date().timeIntervalSince1970 - last > Self.snoozeInterval else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.snoozeKey)
        isShowingWelcome = true
    }

    func openSettings() {
        NSWorkspace.shared.open(AccessCheck.fullDiskAccessSettingsURL)
    }
}

/// Shown above results whenever macOS blocked one or more folders.
struct FullDiskAccessBanner: View {
    let deniedPaths: [String]
    let access: AccessModel
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deniedPaths.count == 1
                         ? "macOS blocked access to 1 folder"
                         : "macOS blocked access to \(deniedPaths.count) folders")
                        .font(.headline)
                    Text("Its contents aren't included. Give macos-clean Full Disk Access in System Settings, reopen the app, then scan again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let onRetry {
                    Button("Scan Again", action: onRetry)
                }
                Button("Open System Settings") { access.openSettings() }
                    .buttonStyle(.glassProminent)
            }
            DisclosureGroup("Blocked folders") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(deniedPaths.prefix(50), id: \.self) { path in
                        Text(path.abbreviatingHome)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if deniedPaths.count > 50 {
                        Text("and \(deniedPaths.count - 50) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 14))
    }
}

struct FullDiskAccessWelcome: View {
    let access: AccessModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Allow Full Disk Access")
                .font(.title2.weight(.semibold))
            Text("macOS hides many caches, logs and app leftovers from apps without Full Disk Access. Without it, macos-clean can only show part of what can be cleaned.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Click Open System Settings.")
                step(2, "Turn on macos-clean in the Full Disk Access list.")
                step(3, "Choose Quit & Reopen when macOS asks.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
            Text("Nothing is removed until you confirm. Cleaned items go to the Trash; only emptying the Trash deletes them for good.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open System Settings") {
                    access.openSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .frame(width: 20, height: 20)
                .background(.tint.opacity(0.18), in: .circle)
            Text(text)
        }
    }
}
