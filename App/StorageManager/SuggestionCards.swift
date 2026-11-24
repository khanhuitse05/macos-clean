import MacosCleanCore
import SwiftUI

/// Smart suggestions (N7): derived on the fly from Storage Manager results and the Uninstaller's
/// app list, minus what the user dismissed in the last 30 days.
@MainActor
@Observable
final class SuggestionsModel {
    private static let defaultsKey = "dismissedSuggestions"

    private(set) var dismissed: [String: Date]

    init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        dismissed = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func suggestions(storage: StorageModel, uninstaller: UninstallerModel) -> [Suggestion] {
        let apps = uninstaller.apps.filter(\.canUninstall).map { app in
            SuggestionInputs.AppUsage(app: app, bundleBytes: uninstaller.sizes[app.path], lastUsed: uninstaller.lastUsed[app.path])
        }
        return SuggestionEngine.suggest(SuggestionInputs(apps: apps, results: storage.scannedResults, dismissed: dismissed))
    }

    func dismiss(_ suggestion: Suggestion) {
        Motion.animate(.smooth) { dismissed[suggestion.id] = .now }
        // Forget dismissals that have expired anyway.
        let live = dismissed.filter { Date.now.timeIntervalSince($0.value) < SuggestionEngine.dismissalPeriod }
        UserDefaults.standard.set(live.mapValues(\.timeIntervalSince1970), forKey: Self.defaultsKey)
    }
}

/// A row of cards above the categories. Each names a fact and offers one action.
struct SuggestionCards: View {
    let suggestions: [Suggestion]
    let onAction: (Suggestion) -> Void
    let onDismiss: (Suggestion) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Suggestions", systemImage: "lightbulb")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ForEach(suggestions) { suggestion in
                    SuggestionCard(suggestion: suggestion, onAction: { onAction(suggestion) }, onDismiss: { onDismiss(suggestion) })
                        .motionTransition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct SuggestionCard: View {
    let suggestion: Suggestion
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: onAction)
                .buttonStyle(.glass)
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Hide this suggestion for 30 days")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }

    private var symbol: String {
        switch suggestion.kind {
        case .unusedApp: "moon.zzz"
        case .oldDownloads: "arrow.down.circle"
        case .oldBackups: "externaldrive.badge.timemachine"
        case .unusedSimulatorRuntimes: "shippingbox"
        case .unavailableSimulators: "iphone.slash"
        }
    }

    /// "4 months", "5 weeks".
    private var idle: String {
        let days = suggestion.idleDays
        if days >= 730 { return "\(days / 365) years" }
        if days >= 60 { return "\(days / 30) months" }
        if days >= 14 { return "\(days / 7) weeks" }
        return "\(days) days"
    }

    private var size: String { suggestion.bytes.fileSize }
    private var count: String { suggestion.count.formatted() }

    private var title: String {
        switch suggestion.kind {
        case .unusedApp:
            "You haven't opened \(suggestion.appName ?? "this app") in \(idle) — it and its data use \(size)"
        case .oldDownloads:
            "\(count) \(suggestion.count == 1 ? "download hasn't" : "downloads haven't") been touched in \(idle) — \(size)"
        case .oldBackups:
            "\(count) device \(suggestion.count == 1 ? "backup is" : "backups are") over a year old — \(size)"
        case .unusedSimulatorRuntimes:
            "\(count) simulator \(suggestion.count == 1 ? "runtime hasn't" : "runtimes haven't") been used in \(idle) — \(size)"
        case .unavailableSimulators:
            "\(count) simulator \(suggestion.count == 1 ? "device can't" : "devices can't") run anymore — \(size)"
        }
    }

    private var detail: String {
        switch suggestion.kind {
        case .unusedApp: "Review it in the Uninstaller: the app, its caches and its data are listed together."
        case .oldDownloads: "Installers, archives and files you've probably dealt with already. Review before cleaning."
        case .oldBackups: "Newer backups of the same device may already exist. Check in Finder before deleting."
        case .unusedSimulatorRuntimes: "Xcode can download them again in Settings › Components when you need them."
        case .unavailableSimulators: "Their runtime was removed, so they only take space."
        }
    }

    private var actionTitle: LocalizedStringKey {
        switch suggestion.action {
        case .reviewApp: "Review"
        case .select: "Select These"
        }
    }
}
