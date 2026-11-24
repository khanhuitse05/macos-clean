import AppKit
import MacosCleanCore
import SwiftUI

/// Live size of the user's Trash, for the bin at the bottom of the sidebar. Measured on start,
/// re-measured whenever the Trash changes on disk (including from Finder), and nudged
/// optimistically while items fly in or are being deleted so the numbers move with the motion.
@MainActor
@Observable
final class TrashBinModel {
    private(set) var bytes: Int64 = 0
    private(set) var itemCount = 0
    private(set) var isMeasured = false
    /// macOS hides the Trash's contents without Full Disk Access.
    private(set) var isBlocked = false
    private(set) var isEmptying = false
    /// Bumps each time a flight lands: the bin's gulp.
    private(set) var arrivals = 0
    /// Bumps when a delete finishes: sparkles.
    private(set) var emptied = 0

    let trashURL: URL

    @ObservationIgnored private var watcher: FileSystemWatcher?
    @ObservationIgnored private var measureTask: Task<Void, Never>?
    @ObservationIgnored private var emptyingStart: (bytes: Int64, count: Int) = (0, 0)
    /// Flights in the air. Measurements wait for them, so bytes aren't counted twice.
    @ObservationIgnored private var inFlight = 0

    init(trashURL: URL) {
        self.trashURL = trashURL
    }

    func start() {
        guard watcher == nil else { return }
        scheduleMeasure(after: .zero)
        let created = FileSystemWatcher(paths: [trashURL.path], latency: 1) { [weak self] _ in
            Task { @MainActor in self?.scheduleMeasure() }
        }
        created.start()
        watcher = created
    }

    /// Re-measures soon, e.g. when the app becomes active (Full Disk Access may have changed).
    func refresh() { scheduleMeasure() }

    // MARK: Moves

    func expectArrival() { inFlight += 1 }

    /// Items landed in the bin: count them in right away; the next measurement corrects it.
    func receive(bytes added: Int64, count: Int) {
        inFlight = max(0, inFlight - 1)
        Motion.animate(.easeOut(duration: 0.8)) {
            bytes += added
            itemCount += count
        }
        arrivals += 1
        scheduleMeasure(after: .seconds(1.5))
    }

    // MARK: Permanent deletes

    func beginEmptying() {
        measureTask?.cancel()
        emptyingStart = (bytes, itemCount)
        Motion.animate { isEmptying = true }
    }

    func emptying(freed: Int64) {
        Motion.animate(.smooth(duration: 0.4)) { bytes = max(0, emptyingStart.bytes - freed) }
    }

    func finishEmptying(_ summary: CleanSummary) {
        Motion.animate(.smooth(duration: 0.5)) {
            bytes = max(0, emptyingStart.bytes - summary.bytesFreed)
            itemCount = max(0, emptyingStart.count - summary.succeeded)
            isEmptying = false
        }
        if summary.succeeded > 0 { emptied += 1 }
        scheduleMeasure(after: .milliseconds(800))
    }

    // MARK: Measuring

    private struct Measurement: Sendable {
        var bytes: Int64 = 0
        var count = 0
        var blocked = false
    }

    private func scheduleMeasure(after delay: Duration = .milliseconds(300)) {
        measureTask?.cancel()
        let url = trashURL
        measureTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let result = await Self.measure(url)
            guard !Task.isCancelled, let self else { return }
            guard !isEmptying, inFlight == 0 else {
                // Busy animating: look again once things settle.
                scheduleMeasure(after: .seconds(1))
                return
            }
            apply(result)
        }
    }

    @concurrent
    private static func measure(_ url: URL) async -> Measurement {
        let items: [URL]
        do {
            items = try TrashEmptier(trashURL: url).contents()
        } catch {
            return Measurement(blocked: true)
        }
        let sizes = await SizeCalculator.measureAll(items)
        return Measurement(bytes: sizes.reduce(0) { $0 + $1.bytes }, count: items.count)
    }

    private func apply(_ measurement: Measurement) {
        isMeasured = true
        if isBlocked != measurement.blocked { isBlocked = measurement.blocked }
        guard !measurement.blocked, measurement.bytes != bytes || measurement.count != itemCount else { return }
        Motion.animate(.smooth(duration: 0.6)) {
            bytes = measurement.bytes
            itemCount = measurement.count
        }
    }
}

// MARK: - Sidebar bin

/// The Trash at the bottom of the sidebar: live size, an Empty button, and the target that
/// moved items fly into.
struct TrashBinView: View {
    let coordinator: TrashCoordinator
    let onReveal: () -> Void
    let onBlockedTap: () -> Void

    var body: some View {
        let bin = coordinator.bin
        HStack(spacing: 10) {
            BinIcon(
                isFull: bin.itemCount > 0, isEmptying: bin.isEmptying,
                arrivals: bin.arrivals, emptied: bin.emptied
            )
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TrashFlight.space)) } action: {
                coordinator.binFrame = $0
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Trash").font(.callout.weight(.medium))
                status(bin)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if bin.itemCount > 0, !bin.isBlocked {
                Button("Empty…") { coordinator.requestEmptyTrash() }
                    .controlSize(.small)
                    .buttonStyle(.glass)
                    .disabled(coordinator.isRunning)
                    .help("Delete everything in the Trash permanently")
                    .motionTransition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
        .onTapGesture { bin.isBlocked ? onBlockedTap() : onReveal() }
        .contextMenu {
            Button("Open Trash in Finder", systemImage: "folder") { FileActions.openTrash() }
            Button("Show in Storage Manager", systemImage: "internaldrive", action: onReveal)
            Divider()
            Button("Empty Trash…", systemImage: "trash.slash") { coordinator.requestEmptyTrash() }
                .disabled(bin.itemCount == 0 || bin.isBlocked || coordinator.isRunning)
        }
        .motionAnimation(.snappy, value: bin.itemCount > 0)
        .help(bin.isBlocked ? "Grant Full Disk Access to see what's in the Trash" : "Click to see what's in the Trash")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trash")
    }

    @ViewBuilder
    private func status(_ bin: TrashBinModel) -> some View {
        if bin.isBlocked {
            Label("No access", systemImage: "lock.fill")
        } else if !bin.isMeasured {
            Text("Measuring…")
        } else if bin.isEmptying {
            HStack(spacing: 3) {
                Text("Emptying…")
                CountingBytes(bytes: Double(bin.bytes))
            }
        } else if bin.itemCount == 0 {
            Text("Empty")
        } else {
            HStack(spacing: 3) {
                CountingBytes(bytes: Double(bin.bytes))
                Text("· \(bin.itemCount.formatted()) \(bin.itemCount == 1 ? "item" : "items")")
                    .contentTransition(.numericText())
            }
        }
    }
}

/// The bin itself: gulps when something lands, shakes while emptying, sparkles when done.
private struct BinIcon: View {
    let isFull: Bool
    let isEmptying: Bool
    let arrivals: Int
    let emptied: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: isFull ? "trash.fill" : "trash")
            .font(.title2)
            .foregroundStyle(isEmptying ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.wiggle, options: .repeat(.continuous), isActive: isEmptying)
            .keyframeAnimator(initialValue: Gulp(), trigger: reduceMotion ? 0 : arrivals) { content, gulp in
                content
                    .scaleEffect(gulp.scale, anchor: .bottom)
                    .rotationEffect(.degrees(gulp.angle), anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.24, duration: 0.14)
                    SpringKeyframe(0.9, duration: 0.14)
                    SpringKeyframe(1.0, duration: 0.32)
                }
                KeyframeTrack(\.angle) {
                    CubicKeyframe(-8, duration: 0.1)
                    CubicKeyframe(7, duration: 0.12)
                    CubicKeyframe(-3, duration: 0.12)
                    CubicKeyframe(0, duration: 0.16)
                }
            }
            .overlay(alignment: .top) {
                if !reduceMotion { SparkleBurst(trigger: emptied).offset(y: -2) }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }

    private struct Gulp {
        var scale = 1.0
        var angle = 0.0
    }
}

// MARK: - Fly-in

/// Chips flying from where a move started into the bin. Never takes clicks.
struct TrashFlightLayer: View {
    let coordinator: TrashCoordinator

    var body: some View {
        GeometryReader { proxy in
            // The layer's own origin in the shared space, so measured frames line up.
            let offset = proxy.frame(in: .named(TrashFlight.space)).origin
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                ForEach(coordinator.flights) { flight in
                    let from = flight.origin.map { CGPoint(x: $0.midX - offset.x, y: $0.midY - offset.y) }
                        ?? CGPoint(x: size.width * 0.62, y: size.height * 0.6)
                    let to = flight.target.map { CGPoint(x: $0.midX - offset.x, y: $0.midY - offset.y) }
                        ?? CGPoint(x: 36, y: size.height - 36)
                    FlightChip(flight: flight, from: from, to: to) { coordinator.flightLanded(flight) }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FlightChip: View {
    let flight: TrashFlight
    let from: CGPoint
    let to: CGPoint
    let onLanded: () -> Void

    @State private var launched = false
    private static let duration = 0.78

    var body: some View {
        let arc = min(140, 70 + abs(to.x - from.x) * 0.12)
        chip
            .keyframeAnimator(initialValue: Flight(), trigger: launched) { content, state in
                content
                    .scaleEffect(state.scale)
                    .rotationEffect(.degrees(state.spin))
                    .opacity(state.opacity)
                    .position(
                        x: from.x + (to.x - from.x) * state.progress,
                        y: from.y + (to.y - from.y) * state.progress + state.lift
                    )
            } keyframes: { _ in
                KeyframeTrack(\.progress) {
                    LinearKeyframe(0, duration: 0.08)
                    CubicKeyframe(0.45, duration: 0.3)
                    CubicKeyframe(1, duration: 0.4)
                }
                KeyframeTrack(\.lift) {
                    CubicKeyframe(-arc, duration: 0.34)
                    CubicKeyframe(0, duration: 0.44)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.1, duration: 0.14)
                    CubicKeyframe(0.75, duration: 0.3)
                    CubicKeyframe(0.22, duration: 0.34)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.06)
                    LinearKeyframe(1, duration: 0.56)
                    LinearKeyframe(0, duration: 0.16)
                }
                KeyframeTrack(\.spin) {
                    CubicKeyframe(-14, duration: 0.78)
                }
            }
            .onAppear { launched = true }
            .task {
                try? await Task.sleep(for: .seconds(Self.duration))
                onLanded()
            }
    }

    private var chip: some View {
        HStack(spacing: 6) {
            ZStack {
                if flight.count > 1 {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.background.secondary)
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(10))
                        .offset(x: 5, y: -3)
                }
                FileIcon(path: flight.iconPath, isDirectory: flight.iconIsDirectory, size: 22)
            }
            Text(label)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .fixedSize()
    }

    private var label: String {
        if flight.count > 1 { return "\(flight.count.formatted()) items" }
        return flight.bytes > 0 ? flight.bytes.fileSize : "1 item"
    }

    private struct Flight {
        var progress = 0.0
        var lift = 0.0
        var scale = 0.6
        var opacity = 0.0
        var spin = 0.0
    }
}
