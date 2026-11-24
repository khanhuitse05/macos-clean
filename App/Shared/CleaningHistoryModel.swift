import MacosCleanCore
import SwiftUI

/// What macos-clean has cleaned over time (N2). Shared by the main window and Settings; saved in
/// `~/Library/Application Support/<bundle id>/cleaning_history.json`.
@MainActor
@Observable
final class CleaningHistoryModel {
    static let shared = CleaningHistoryModel()

    private(set) var history = CleaningHistory()
    @ObservationIgnored private let store = CleaningHistoryStore()
    @ObservationIgnored private var didLoad = false

    init() {
        Task { await load() }
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        let saved = await store.load()
        // A clean recorded before loading finished is kept on top of what was saved.
        var merged = saved
        for record in history.records { merged.record(record) }
        history = merged
    }

    /// Records a finished clean (no-op when nothing succeeded).
    func record(_ action: TrashCoordinator.Action, summary: CleanSummary, simulatorBytes: Int64 = 0, simulatorCount: Int = 0) {
        let date = Date.now
        let trashedCount = summary.succeeded - simulatorCount
        let trashedBytes = summary.bytesFreed - simulatorBytes
        if trashedCount > 0 {
            let kind: CleaningRecord.Kind = action.isPermanent ? .deletedForGood : .trashed
            history.record(CleaningRecord(date: date, kind: kind, bytes: trashedBytes, count: trashedCount))
        }
        if simulatorCount > 0 {
            history.record(CleaningRecord(date: date, kind: .simulatorRemoved, bytes: simulatorBytes, count: simulatorCount))
        }
        save()
    }

    func reset() {
        history = CleaningHistory()
        save()
    }

    private func save() {
        let snapshot = history
        Task { await store.save(snapshot) }
    }
}

actor CleaningHistoryStore {
    private struct Payload: Codable {
        var version = 1
        var history: CleaningHistory
    }

    private let url: URL?

    init() {
        url = AppWatcher.defaultCacheURL?.deletingLastPathComponent().appendingPathComponent("cleaning_history.json")
    }

    func load() -> CleaningHistory {
        guard let url, let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1
        else { return CleaningHistory() }
        return payload.history
    }

    func save(_ history: CleaningHistory) {
        guard let url, let data = try? JSONEncoder().encode(Payload(history: history)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// "Last cleaned 3 days ago · 42 GB cleaned with macos-clean so far."
struct CleaningHistoryLine: View {
    let history: CleaningHistory

    var body: some View {
        if let last = history.lastCleaned {
            Label {
                Text("Last cleaned \(last.formatted(.relative(presentation: .named))) · \(history.lifetimeCleanedBytes.fileSize) cleaned with macos-clean so far")
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
            .help("\(history.cleanCount.formatted()) cleans, \(history.lifetimeCleanedItems.formatted()) items. \(history.lifetimeEmptiedBytes.fileSize) deleted for good from the Trash.")
        }
    }
}

struct HistorySettingsSection: View {
    @State private var model = CleaningHistoryModel.shared
    @State private var isConfirmingReset = false

    var body: some View {
        let history = model.history
        Section {
            if history.isEmpty {
                Text("Nothing cleaned yet")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Cleaned all-time", value: history.lifetimeCleanedBytes.fileSize)
                LabeledContent("Items cleaned", value: history.lifetimeCleanedItems.formatted())
                LabeledContent("Deleted for good from the Trash", value: history.lifetimeEmptiedBytes.fileSize)
                if let last = history.lastCleaned {
                    LabeledContent("Last cleaned") {
                        Text(last, format: .dateTime.year().month().day().hour().minute())
                    }
                }
                Button("Reset History…", role: .destructive) { isConfirmingReset = true }
            }
        } header: {
            Text("Cleaning History")
        } footer: {
            Text("\"Cleaned\" counts items macos-clean moved to the Trash and simulators it removed. Emptying the Trash is counted apart, so nothing is counted twice.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Reset cleaning history?", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive) { model.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The totals and the last-cleaned date start again from zero. No files are touched.")
        }
    }
}
