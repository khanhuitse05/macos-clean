import MacosCleanCore
import SwiftUI

/// The single gate every removal goes through: a feature *requests* a move to the Trash (or a
/// permanent delete of items already in it), the user confirms in a dialog, and only then does
/// `Cleaner` / `TrashEmptier` run (with `confirm: true`). Progress and the result are shown in
/// one sheet for all features, and moved items fly into the sidebar's Trash bin.
@MainActor
@Observable
final class TrashCoordinator {
    enum Action: Equatable {
        /// Move `paths` to the Trash (restorable).
        case moveToTrash
        /// Delete `paths`, which are inside the Trash, for good.
        case erase
        /// Delete everything in the Trash for good.
        case emptyTrash

        var isPermanent: Bool { self != .moveToTrash }
    }

    struct Request: Identifiable {
        let id = UUID()
        var action: Action = .moveToTrash
        let paths: [String]
        let title: String
        let message: String
        let confirmTitle: String
        /// Best estimate of the bytes involved, for the fly-in chip and the bin.
        var bytes: Int64 = 0
        /// Where the fly-in animation starts, in the ``TrashFlight/space`` coordinate space.
        var origin: CGRect?
        /// Runs after the user confirms, before anything is moved. Return false to abort.
        var prepare: (@MainActor () async -> Bool)?
        let onFinish: @MainActor (CleanSummary) -> Void
    }

    enum Phase: Equatable {
        case idle
        case running(Action, CleanProgress?)
        case finished(Action, CleanSummary)
    }

    /// A clean that fully succeeded, shown as a short toast instead of a results sheet.
    struct Celebration: Identifiable, Equatable {
        let id = UUID()
        let bytes: Int64
        let count: Int
        var action: Action = .moveToTrash
    }

    /// Drives the confirmation dialog.
    var pending: Request?
    private(set) var phase: Phase = .idle
    var isShowingProgress = false
    private(set) var celebration: Celebration?
    /// Chips flying from where a move started to the Trash bin.
    private(set) var flights: [TrashFlight] = []
    /// Where flights land, reported by ``TrashBinView``. Not observed: read when a flight starts.
    @ObservationIgnored var binFrame: CGRect?
    /// Called after every permanent delete, so features showing Trash items can drop them.
    @ObservationIgnored var onErased: (@MainActor (CleanSummary) -> Void)?

    let bin: TrashBinModel

    /// Quick cleans finish before this, so they never flash a progress sheet.
    private static let sheetDelay: Duration = .milliseconds(450)
    private static let celebrationDuration: Duration = .seconds(5)

    private let cleaner: Cleaner
    private let emptier: TrashEmptier

    init(cleaner: Cleaner = Cleaner(), emptier: TrashEmptier = TrashEmptier()) {
        self.cleaner = cleaner
        self.emptier = emptier
        self.bin = TrashBinModel(trashURL: emptier.trashURL)
    }

    var isRunning: Bool {
        if case .running = phase { true } else { false }
    }

    /// Asks for confirmation. Nothing is touched until ``confirm(_:)``.
    func request(_ request: Request, from origin: CGRect? = nil) {
        guard request.action == .emptyTrash || !request.paths.isEmpty, !isRunning else { return }
        var request = request
        if let origin { request.origin = origin }
        pending = request
    }

    /// Asks to empty the whole Trash, using the bin's latest measurement for the wording.
    func requestEmptyTrash() {
        guard bin.itemCount > 0 else { return }
        request(.emptyTrash(bytes: bin.bytes, count: bin.itemCount))
    }

    /// Called only by the destructive button of the confirmation dialog.
    func confirm(_ request: Request) {
        pending = nil
        Task { await run(request) }
    }

    func dismissCelebration() {
        Motion.animate(.smooth) { celebration = nil }
    }

    func dismissProgress() {
        guard !isRunning else { return }
        isShowingProgress = false
        phase = .idle
    }

    /// A chip reached the bin: it disappears and the bin swallows its bytes.
    func flightLanded(_ flight: TrashFlight) {
        flights.removeAll { $0.id == flight.id }
        bin.receive(bytes: flight.bytes, count: flight.count)
    }

    private func run(_ request: Request) async {
        if let prepare = request.prepare, await prepare() == false { return }
        phase = .running(request.action, nil)
        celebration = nil
        let flew = request.action == .moveToTrash && launchFlight(for: request)
        if request.action.isPermanent { bin.beginEmptying() }
        let sheetTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sheetDelay)
            guard !Task.isCancelled, let self, isRunning else { return }
            isShowingProgress = true
        }
        let summary: CleanSummary
        do {
            let events = switch request.action {
            case .moveToTrash: try cleaner.trash(request.paths, confirm: true)
            case .erase: try emptier.erase(request.paths, confirm: true)
            case .emptyTrash: try emptier.erase(nil, confirm: true)
            }
            var last = CleanSummary(outcomes: [])
            for await event in events {
                switch event {
                case .progress(let progress):
                    phase = .running(request.action, progress)
                    if request.action.isPermanent { bin.emptying(freed: progress.bytesFreed) }
                case .finished(let result):
                    last = result
                }
            }
            summary = last
        } catch {
            summary = CleanSummary(outcomes: request.paths.map {
                DeleteOutcome(path: $0, success: false, error: error.localizedDescription)
            })
        }
        sheetTask.cancel()
        if request.action.isPermanent {
            bin.finishEmptying(summary)
        } else if !flew, summary.succeeded > 0 {
            // No flight (Reduce Motion): the bin still takes the bytes.
            bin.receive(bytes: summary.bytesFreed, count: summary.succeeded)
        }
        // Rows leave the lists with an animation in every feature.
        Motion.animate {
            request.onFinish(summary)
            if request.action.isPermanent { onErased?(summary) }
        }
        if summary.failed == 0, summary.succeeded > 0 {
            // Everything worked: close the sheet (if it opened) and celebrate instead.
            phase = .idle
            isShowingProgress = false
            let shown = Celebration(bytes: summary.bytesFreed, count: summary.succeeded, action: request.action)
            Motion.animate(.spring(duration: 0.5, bounce: 0.3)) { celebration = shown }
            Task { [weak self] in
                try? await Task.sleep(for: Self.celebrationDuration)
                guard let self, celebration?.id == shown.id else { return }
                dismissCelebration()
            }
        } else if summary.total == 0 {
            phase = .idle
            isShowingProgress = false
        } else {
            // Failures need reading: show the results sheet.
            phase = .finished(request.action, summary)
            isShowingProgress = true
        }
    }

    /// Starts a chip from the request's origin toward the bin. False when motion is reduced.
    private func launchFlight(for request: Request) -> Bool {
        guard !Motion.reduceMotion else { return false }
        let first = request.paths.first ?? ""
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: first, isDirectory: &isDirectory)
        bin.expectArrival()
        flights.append(TrashFlight(
            origin: request.origin, target: binFrame,
            iconPath: first, iconIsDirectory: isDirectory.boolValue,
            count: request.paths.count, bytes: request.bytes
        ))
        return true
    }
}

/// One chip flying into the Trash bin.
struct TrashFlight: Identifiable, Equatable {
    /// The window-wide coordinate space origins and the bin are measured in.
    static let space = "trashFlight"

    let id = UUID()
    let origin: CGRect?
    let target: CGRect?
    let iconPath: String
    let iconIsDirectory: Bool
    let count: Int
    let bytes: Int64
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
            title: "Move \(count.formatted()) \(thing) (\(bytes.fileSize)) to the Trash?",
            message: message,
            confirmTitle: "Move to Trash",
            bytes: bytes,
            onFinish: onFinish
        )
    }

    /// "Move “Big Movie.mov” (4.2 GB) to the Trash?"
    static func single(_ entry: FileEntry, onFinish: @escaping @MainActor (CleanSummary) -> Void) -> Self {
        .init(
            paths: [entry.path],
            title: "Move “\(entry.name)” (\(entry.sizeBytes.fileSize)) to the Trash?",
            message: "You can restore it from the Trash until you empty it.",
            confirmTitle: "Move to Trash",
            bytes: entry.sizeBytes,
            onFinish: onFinish
        )
    }

    /// "Delete 3 items (1.2 GB) permanently?" — for items already in the Trash.
    static func erase(
        _ paths: [String], bytes: Int64, name: String? = nil,
        onFinish: @escaping @MainActor (CleanSummary) -> Void = { _ in }
    ) -> Self {
        let count = paths.count
        let what = name.map { "“\($0)”" } ?? "\(count.formatted()) \(count == 1 ? "item" : "items")"
        return .init(
            action: .erase,
            paths: paths,
            title: "Delete \(what) (\(bytes.fileSize)) permanently?",
            message: "This can't be undone.",
            confirmTitle: "Delete Permanently",
            bytes: bytes,
            onFinish: onFinish
        )
    }

    /// "Empty the Trash?" — everything in it, for good.
    static func emptyTrash(bytes: Int64, count: Int) -> Self {
        .init(
            action: .emptyTrash,
            paths: [],
            title: "Empty the Trash?",
            message: "\(count.formatted()) \(count == 1 ? "item" : "items") (\(bytes.fileSize)) will be deleted permanently. This can't be undone.",
            confirmTitle: "Empty Trash",
            bytes: bytes,
            onFinish: { _ in }
        )
    }
}

/// Attaches the shared confirmation dialog, progress sheet, toast and fly-in layer.
struct TrashFlowModifier: ViewModifier {
    @Bindable var coordinator: TrashCoordinator

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(TrashFlight.space))
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
            .overlay {
                TrashFlightLayer(coordinator: coordinator)
            }
            .overlay(alignment: .top) {
                if let celebration = coordinator.celebration {
                    CelebrationToast(
                        celebration: celebration,
                        canEmptyTrash: coordinator.bin.itemCount > 0 && !coordinator.isRunning,
                        onEmptyTrash: { coordinator.dismissCelebration(); coordinator.requestEmptyTrash() },
                        onDismiss: { coordinator.dismissCelebration() }
                    )
                    .padding(.top, 12)
                    .motionTransition(.move(edge: .top).combined(with: .opacity))
                }
            }
    }
}

/// "4.2 GB moved to the Trash" / "12 GB freed" — counts up, the icon bounces and sparkles drift off.
struct CelebrationToast: View {
    let celebration: TrashCoordinator.Celebration
    var canEmptyTrash = false
    var onEmptyTrash: () -> Void = {}
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownBytes: Double = 0
    @State private var bounce = 0

    private var permanent: Bool { celebration.action.isPermanent }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permanent ? "sparkles" : "trash.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: bounce)
                .overlay(alignment: .topTrailing) {
                    if !reduceMotion { SparkleBurst(trigger: bounce).offset(x: 10, y: -10) }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    CountingBytes(bytes: shownBytes)
                        .font(.title3.weight(.semibold))
                    Text(permanent ? "freed" : "moved to the Trash").font(.title3.weight(.semibold))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !permanent, canEmptyTrash {
                Button("Empty Trash…", action: onEmptyTrash)
                    .controlSize(.small)
                    .buttonStyle(.glass)
                    .tint(.red)
            }
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .onAppear {
            if reduceMotion {
                shownBytes = Double(celebration.bytes)
            } else {
                withAnimation(.easeOut(duration: 1.1)) { shownBytes = Double(celebration.bytes) }
                bounce += 1
            }
        }
    }

    private var detail: String {
        let items = "\(celebration.count.formatted()) \(celebration.count == 1 ? "item" : "items")"
        return permanent
            ? "\(items) deleted permanently."
            : "\(items). Empty the Trash to get the space back."
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
            case .idle:
                header("Moving to Trash…", systemImage: "trash", tint: .secondary)
                ProgressView().progressViewStyle(.linear)
            case .running(let action, nil):
                header(runningTitle(action), systemImage: "trash", tint: .secondary)
                ProgressView().progressViewStyle(.linear)
            case .running(let action, let progress?):
                header(runningTitle(action), systemImage: "trash", tint: .secondary)
                ProgressView(value: Double(progress.current), total: Double(max(progress.total, 1)))
                Text(progress.path.isEmpty ? "Starting…" : progress.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(progress.current) of \(progress.total) · \(progress.bytesFreed.fileSize) freed")
                    .font(.callout)
                    .monospacedDigit()
            case .finished(let action, let summary):
                finished(action, summary)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func runningTitle(_ action: TrashCoordinator.Action) -> LocalizedStringKey {
        switch action {
        case .moveToTrash: "Moving to Trash…"
        case .erase: "Deleting…"
        case .emptyTrash: "Emptying the Trash…"
        }
    }

    private func header(_ title: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
    }

    @ViewBuilder
    private func finished(_ action: TrashCoordinator.Action, _ summary: CleanSummary) -> some View {
        let permanent = action.isPermanent
        if summary.failed == 0 {
            header(permanent ? "Deleted" : "Moved to Trash", systemImage: "checkmark.circle.fill", tint: .green)
        } else {
            header(permanent ? "Some items couldn't be deleted" : "Some items couldn't be moved",
                   systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
        Text("\(summary.succeeded) \(permanent ? "deleted" : "moved") · \(summary.failed) failed · \(summary.bytesFreed.fileSize) freed")
            .monospacedDigit()
        Text(permanent
             ? "Locked items stay in the Trash. Unlock them in Finder (Get Info) and try again."
             : "Items stay in the Trash until you empty it.")
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
