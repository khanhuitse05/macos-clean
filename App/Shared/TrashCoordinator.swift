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

    /// A clean that fully succeeded, shown as a short toast instead of a results sheet.
    struct Celebration: Identifiable, Equatable {
        let id = UUID()
        let bytes: Int64
        let count: Int
    }

    /// Drives the confirmation dialog.
    var pending: Request?
    private(set) var phase: Phase = .idle
    var isShowingProgress = false
    private(set) var celebration: Celebration?

    /// Quick cleans finish before this, so they never flash a progress sheet.
    private static let sheetDelay: Duration = .milliseconds(450)
    private static let celebrationDuration: Duration = .seconds(4)

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


    func dismissCelebration() {
        Motion.animate(.smooth) { celebration = nil }
    }

    func dismissProgress() {
        guard !isRunning else { return }
        isShowingProgress = false
        phase = .idle
    }

    private func run(_ request: Request) async {
        if let prepare = request.prepare, await prepare() == false { return }
        phase = .running(nil)
        celebration = nil
        let sheetTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sheetDelay)
            guard !Task.isCancelled, let self, isRunning else { return }
            isShowingProgress = true
        }
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
        sheetTask.cancel()
        // Rows leave the lists with an animation in every feature.
        Motion.animate { request.onFinish(summary) }
        if summary.failed == 0, summary.succeeded > 0 {
            // Everything worked: close the sheet (if it opened) and celebrate instead.
            phase = .idle
            isShowingProgress = false
            let shown = Celebration(bytes: summary.bytesFreed, count: summary.succeeded)
            Motion.animate(.spring(duration: 0.5, bounce: 0.3)) { celebration = shown }
            Task { [weak self] in
                try? await Task.sleep(for: Self.celebrationDuration)
                guard let self, celebration?.id == shown.id else { return }
                dismissCelebration()
            }
        } else {
            // Failures need reading: show the results sheet.
            phase = .finished(summary)
            isShowingProgress = true
        }
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
            .overlay(alignment: .top) {
                if let celebration = coordinator.celebration {
                    CelebrationToast(celebration: celebration) { coordinator.dismissCelebration() }
                        .padding(.top, 12)
                        .motionTransition(.move(edge: .top).combined(with: .opacity))
                }
            }
    }
}

/// "4.2 GB cleaned" — counts up, the trash icon bounces and a few sparkles drift off.
struct CelebrationToast: View {
    let celebration: TrashCoordinator.Celebration
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownBytes: Double = 0
    @State private var bounce = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.fill")
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
                    Text("cleaned").font(.title3.weight(.semibold))
                }
                Text("\(celebration.count.formatted()) \(celebration.count == 1 ? "item" : "items") moved to the Trash. Empty it in Finder to get the space back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 440)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .onAppear {
            if reduceMotion {
                shownBytes = Double(celebration.bytes)
            } else {
                withAnimation(.easeOut(duration: 1.1)) { shownBytes = Double(celebration.bytes) }
                bounce += 1
            }
        }
    }
}

/// A handful of sparkles that fly outward and fade each time `trigger` changes.
private struct SparkleBurst: View {
    let trigger: Int

    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                let angle = Self.angle(index)
                Image(systemName: "sparkle")
                    .font(.system(size: index.isMultiple(of: 2) ? 9 : 6, weight: .bold))
                    .foregroundStyle(.yellow)
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
