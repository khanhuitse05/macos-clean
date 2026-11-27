import AppKit
import MacosCleanCore
import SwiftUI

/// Full Disk Access state plus the launch-time explainer.
@MainActor
@Observable
final class AccessModel {
    private(set) var hasFullDiskAccess = true
    var isShowingWelcome = false {
        didSet {
            guard !isShowingWelcome else { return }
            let waiting = dismissWaiters
            dismissWaiters.removeAll()
            waiting.forEach { $0.resume() }
        }
    }
    @ObservationIgnored private var dismissWaiters: [CheckedContinuation<Void, Never>] = []

    /// Set once the first-launch explainer has been shown; later launches only remind daily.
    private static let onboardedKey = "fdaOnboardingShown"
    private static let snoozeKey = "fdaWelcomeShownAt"
    private static let snoozeInterval: TimeInterval = 24 * 60 * 60

    func refresh() {
        let granted = AccessCheck.hasFullDiskAccess()
        if granted != hasFullDiskAccess { hasFullDiskAccess = granted }
    }

    /// Asks for Full Disk Access the first time the app opens, then at most once a day while
    /// access is still missing, and returns once the sheet is closed. Launch scans wait on
    /// this, so the request comes before macOS's own per-folder prompts (Downloads, Desktop…),
    /// which Full Disk Access makes unnecessary.
    ///
    /// Every caller waits on the same check, so sections that scan on first visit can call it
    /// too; only the first call may show the sheet.
    func showWelcomeIfNeeded() async {
        if launchCheck == nil {
            launchCheck = Task { await self.runLaunchCheck() }
        }
        await launchCheck?.value
    }

    @ObservationIgnored private var launchCheck: Task<Void, Never>?

    private func runLaunchCheck() async {
        refresh()
        guard !hasFullDiskAccess else { return }
        let defaults = UserDefaults.standard
        let isFirstLaunch = !defaults.bool(forKey: Self.onboardedKey)
        let last = defaults.double(forKey: Self.snoozeKey)
        guard isFirstLaunch || Date().timeIntervalSince1970 - last > Self.snoozeInterval else { return }
        // Waits a moment so the sheet attaches to a visible window.
        try? await Task.sleep(for: .milliseconds(350))
        defaults.set(true, forKey: Self.onboardedKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.snoozeKey)
        isShowingWelcome = true
        await waitUntilWelcomeCloses()
    }

    /// Returns at once when the sheet isn't showing.
    func waitUntilWelcomeCloses() async {
        guard isShowingWelcome else { return }
        await withCheckedContinuation { dismissWaiters.append($0) }
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
                    Text("Its contents aren't included. Give macOS Clean Full Disk Access in System Settings, reopen the app, then scan again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        // No vertical fixedSize: measured at a tiny width it wraps a word per
                        // line, which pushed the whole window's content taller than the window.
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
    /// Called after access turns on while the sheet is open, so sections can rescan.
    var onGranted: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: access.hasFullDiskAccess ? "checkmark.shield" : "lock.shield")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(access.hasFullDiskAccess ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            if access.hasFullDiskAccess {
                granted
            } else {
                request
            }
        }
        .padding(28)
        .frame(width: 460)
        .animation(.smooth, value: access.hasFullDiskAccess)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings: pick up the new permission without a relaunch when possible.
            access.refresh()
        }
    }

    private var request: some View {
        VStack(spacing: 18) {
            Text("Allow Full Disk Access")
                .font(.title2.weight(.semibold))
            Text("macOS hides many caches, logs and app leftovers from apps without Full Disk Access. Without it, macOS Clean can only show part of what can be cleaned.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Click Open System Settings.")
                step(2, "Turn on macOS Clean in the Full Disk Access list.")
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
                Button("Open System Settings") { access.openSettings() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private var granted: some View {
        VStack(spacing: 18) {
            Text("Full Disk Access is on")
                .font(.title2.weight(.semibold))
            Text("macOS Clean can now see every cache, log and leftover it knows how to clean.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Continue") {
                onGranted?()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.glassProminent)
        }
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
