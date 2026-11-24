import MacosCleanCore
import SwiftUI

/// The single gate every removal goes through: a feature *requests* a move to the Trash, the user
/// confirms in a dialog, and only then does `Cleaner` run (with `confirm: true`). Progress and the
/// result are shown in one sheet for all features.
@MainActor
@Observable
final class TrashCoordinator {
    struct Request: Identifiable {
        let id = UUID()
        let paths: [String]
        let title: String
        let message: String
        let confirmTitle: String
        /// Runs after the user confirms, before anything is moved. Return false to abort.
        var prepare: (@MainActor () async -> Bool)?
        let onFinish: @MainActor (CleanSummary) -> Void
    }

    enum Phase: Equatable {
        case idle
        case running(CleanProgress?)
        case finished(CleanSummary)
    }

    /// Drives the confirmation dialog.
    var pending: Request?
    private(set) var phase: Phase = .idle
    var isShowingProgress = false

    private let cleaner: Cleaner

    init(cleaner: Cleaner = Cleaner()) {
        self.cleaner = cleaner
    }

    var isRunning: Bool {
        if case .running = phase { true } else { false }
    }

    /// Asks for confirmation. Nothing is touched until ``confirm(_:)``.
    func request(_ request: Request) {
        guard !request.paths.isEmpty, !isRunning else { return }
        pending = request
    }

    /// Called only by the destructive button of the confirmation dialog.
    func confirm(_ request: Request) {
        pending = nil
        Task { await run(request) }
    }

    func dismissProgress() {
        guard !isRunning else { return }
        isShowingProgress = false
        phase = .idle
    }

    private func run(_ request: Request) async {
        if let prepare = request.prepare, await prepare() == false { return }
        phase = .running(nil)
        isShowingProgress = true
        let summary: CleanSummary
        do {
            var last = CleanSummary(outcomes: [])
            for await event in try cleaner.trash(request.paths, confirm: true) {
                switch event {
                case .progress(let progress): phase = .running(progress)
                case .finished(let result): last = result
                }
            }
            summary = last
        } catch {
            summary = CleanSummary(outcomes: request.paths.map {
                DeleteOutcome(path: $0, success: false, error: error.localizedDescription)
            })
        }
        phase = .finished(summary)
        request.onFinish(summary)
    }
}

extension TrashCoordinator.Request {
    /// Standard wording: "Move 12 items (3.4 GB) to the Trash?"
    static func items(
        _ paths: [String], bytes: Int64, noun: String? = nil, extraMessage: String? = nil,
        onFinish: @escaping @MainActor (CleanSummary) -> Void
    ) -> Self {
        let count = paths.count
        let thing = noun ?? (count == 1 ? "item" : "items")
        var message = "You can restore them from the Trash until you empty it."
        if let extraMessage { message = extraMessage + "\n\n" + message }
        return .init(
            paths: paths,
            title: "Move \(count.formatted()) \(thing) (\(bytes.formatted(.byteCount(style: .file)))) to the Trash?",
            message: message,
            confirmTitle: "Move to Trash",
            onFinish: onFinish
        )
    }
}

extension TrashCoordinator.Request {
    /// "Move “Big Movie.mov” (4.2 GB) to the Trash?"
    static func single(_ entry: FileEntry, onFinish: @escaping @MainActor (CleanSummary) -> Void) -> Self {
        .init(
            paths: [entry.path],
            title: "Move “\(entry.name)” (\(entry.sizeBytes.formatted(.byteCount(style: .file)))) to the Trash?",
            message: "You can restore it from the Trash until you empty it.",
            confirmTitle: "Move to Trash",
            onFinish: onFinish
        )
    }
}

/// Attaches the shared confirmation dialog and progress sheet.
struct TrashFlowModifier: ViewModifier {
    @Bindable var coordinator: TrashCoordinator

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                coordinator.pending?.title ?? "",
                isPresented: Binding(
                    get: { coordinator.pending != nil },
                    set: { if !$0 { coordinator.pending = nil } }
                ),
                titleVisibility: .visible,
                presenting: coordinator.pending
            ) { request in
                Button(request.confirmTitle, role: .destructive) { coordinator.confirm(request) }
                Button("Cancel", role: .cancel) { coordinator.pending = nil }
            } message: { request in
                Text(request.message)
            }
            .sheet(isPresented: $coordinator.isShowingProgress) {
                CleanProgressSheet(phase: coordinator.phase) { coordinator.dismissProgress() }
                    .interactiveDismissDisabled(coordinator.isRunning)
            }
    }
}

extension View {
    func trashFlow(_ coordinator: TrashCoordinator) -> some View {
        modifier(TrashFlowModifier(coordinator: coordinator))
    }
}

struct CleanProgressSheet: View {
    let phase: TrashCoordinator.Phase
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch phase {
            case .idle, .running(nil):
                header("Moving to Trash…", systemImage: "trash", tint: .secondary)
                ProgressView().progressViewStyle(.linear)
            case .running(let progress?):
                header("Moving to Trash…", systemImage: "trash", tint: .secondary)
                ProgressView(value: Double(progress.current), total: Double(max(progress.total, 1)))
                Text(progress.path.isEmpty ? "Starting…" : progress.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(progress.current) of \(progress.total) · \(progress.bytesFreed.formatted(.byteCount(style: .file))) freed")
                    .font(.callout)
                    .monospacedDigit()
            case .finished(let summary):
                finished(summary)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func header(_ title: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
    }

    @ViewBuilder
    private func finished(_ summary: CleanSummary) -> some View {
        if summary.failed == 0 {
            header("Moved to Trash", systemImage: "checkmark.circle.fill", tint: .green)
        } else {
            header("Some items couldn't be moved", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
        Text("\(summary.succeeded) moved · \(summary.failed) failed · \(summary.bytesFreed.formatted(.byteCount(style: .file))) freed")
            .monospacedDigit()
        Text("Items stay in the Trash until you empty it in Finder.")
            .font(.callout)
            .foregroundStyle(.secondary)
        if !summary.failures.isEmpty {
            DisclosureGroup("Show failures (\(summary.failures.count))") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.failures, id: \.path) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Text(failure.error ?? "Unknown error").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
        HStack {
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
        }
    }
}
