import AppKit
import MacosCleanCore
import SwiftUI
import UniformTypeIdentifiers

/// One top-level item in the Trash.
struct TrashItem: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let sizeBytes: Int64
    let isDirectory: Bool
    let kind: String
    /// When it was put in the Trash (the date it was added to the Trash folder).
    let dateTrashed: Date

    var id: String { path }
}

/// The user's Trash: its items, live size, and the items picked for permanent deletion.
/// Measured on start, re-measured whenever the Trash changes on disk (including from Finder),
/// and nudged optimistically while items fly in or are being deleted, so the numbers move
/// with the motion.
@MainActor
@Observable
final class TrashBinModel {
    private(set) var bytes: Int64 = 0
    private(set) var itemCount = 0
    private(set) var items: [TrashItem] = []
    private(set) var isMeasured = false
    /// macOS hides the Trash's contents without Full Disk Access.
    private(set) var isBlocked = false
    private(set) var isEmptying = false
    /// Bumps each time a flight lands: the bin's gulp.
    private(set) var arrivals = 0
    /// Bumps when a delete finishes: sparkles.
    private(set) var emptied = 0

    /// Items picked for permanent deletion.
    private(set) var picks: Set<String> = [] { didSet { recomputePicks() } }
    private(set) var pickedBytes: Int64 = 0

    var searchText = ""
    var sortOrder: [KeyPathComparator<TrashItem>] = [KeyPathComparator(\.sizeBytes, order: .reverse)] {
        didSet { items.sort(using: sortOrder) }
    }

    let trashURL: URL

    @ObservationIgnored private var watcher: FileSystemWatcher?
    @ObservationIgnored private var measureTask: Task<Void, Never>?
    @ObservationIgnored private var emptyingStart: (bytes: Int64, count: Int) = (0, 0)
    @ObservationIgnored private var emptyingSucceeded = 0
    /// Flights in the air. Measurements wait for them, so bytes aren't counted twice.
    @ObservationIgnored private var inFlight = 0

    init(trashURL: URL) {
        self.trashURL = trashURL
    }

    var visibleItems: [TrashItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.localizedStandardContains(query) || $0.kind.localizedStandardContains(query) }
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

    // MARK: Picks

    func isPicked(_ item: TrashItem) -> Bool { picks.contains(item.id) }

    func setPicked(_ item: TrashItem, _ picked: Bool) {
        if picked { picks.insert(item.id) } else { picks.remove(item.id) }
    }

    func pick(_ ids: Set<String>) { picks.formUnion(ids) }

    func pickAllVisible() { picks.formUnion(visibleItems.map(\.id)) }

    func clearPicks() { picks.removeAll() }

    /// Permanently deletes the picked items, or the given ones.
    func eraseRequest(for ids: Set<String>? = nil) -> TrashCoordinator.Request? {
        let chosen = items.filter { (ids ?? picks).contains($0.id) }
        guard !chosen.isEmpty else { return nil }
        let bytes = chosen.reduce(0) { $0 + $1.sizeBytes }
        return .erase(chosen.map(\.path), bytes: bytes, name: chosen.count == 1 ? chosen[0].name : nil)
    }

    private func recomputePicks() {
        let total = items.lazy.filter { self.picks.contains($0.id) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        if pickedBytes != total { pickedBytes = total }
    }

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
        emptyingSucceeded = 0
        Motion.animate { isEmptying = true }
    }

    /// Counts down and drops each row as soon as it's gone.
    func emptying(_ progress: CleanProgress) {
        let removedOne = progress.succeeded > emptyingSucceeded && !progress.path.isEmpty
        emptyingSucceeded = progress.succeeded
        Motion.animate(.smooth(duration: 0.35)) {
            bytes = max(0, emptyingStart.bytes - progress.bytesFreed)
            if removedOne {
                items.removeAll { $0.path == progress.path }
                picks.remove(progress.path)
                itemCount = max(0, emptyingStart.count - progress.succeeded)
            }
        }
    }

    func finishEmptying(_ summary: CleanSummary) {
        let gone = summary.trashedPaths
        Motion.animate(.smooth(duration: 0.5)) {
            bytes = max(0, emptyingStart.bytes - summary.bytesFreed)
            itemCount = max(0, emptyingStart.count - summary.succeeded)
            items.removeAll { gone.contains($0.path) }
            picks.subtract(gone)
            isEmptying = false
        }
        if summary.succeeded > 0 { emptied += 1 }
        scheduleMeasure(after: .milliseconds(800))
    }

    // MARK: Measuring

    private struct Measurement: Sendable {
        var items: [TrashItem] = []
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
        let urls: [URL]
        do {
            urls = try TrashEmptier(trashURL: url).contents()
        } catch {
            return Measurement(blocked: true)
        }
        let sizes = await SizeCalculator.measureAll(urls)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey, .contentModificationDateKey, .contentTypeKey]
        let items = zip(urls, sizes).map { url, size in
            let values = try? url.resourceValues(forKeys: keys)
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            return TrashItem(
                path: url.path,
                name: url.lastPathComponent,
                sizeBytes: size.bytes,
                isDirectory: isFolder,
                kind: isFolder ? "Folder" : Self.sentenceCase(values?.contentType?.localizedDescription ?? "Document"),
                dateTrashed: values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
            )
        }
        return Measurement(items: items)
    }

    /// "text" → "Text"; leaves "QuickTime movie" alone.
    private nonisolated static func sentenceCase(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private func apply(_ measurement: Measurement) {
        isMeasured = true
        if isBlocked != measurement.blocked { isBlocked = measurement.blocked }
        guard !measurement.blocked else { return }
        let sorted = measurement.items.sorted(using: sortOrder)
        let total = sorted.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard sorted != items || total != bytes || sorted.count != itemCount else { return }
        Motion.animate(.smooth(duration: 0.6)) {
            items = sorted
            bytes = total
            itemCount = sorted.count
            let present = Set(sorted.map(\.id))
            if !picks.isSubset(of: present) { picks.formIntersection(present) } else { recomputePicks() }
        }
    }
}

// MARK: - Sidebar entry

/// The Trash at the bottom of the sidebar: a selectable row that opens the Trash section,
/// shows its live size, and is the target moved items fly into.
struct TrashSidebarItem: View {
    let coordinator: TrashCoordinator
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        let bin = coordinator.bin
        HStack(spacing: 8) {
            BinIcon(
                isEmptying: bin.isEmptying,
                arrivals: bin.arrivals, emptied: bin.emptied
            )
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TrashFlight.space)) } action: {
                coordinator.binFrame = $0
            }
            Text("Trash")
                .lineLimit(1)
            Spacer(minLength: 6)
            badge(bin)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 34)
        .background(background, in: .rect(cornerRadius: 8))
        .contentShape(.rect(cornerRadius: 8))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open Trash in Finder", systemImage: "folder") { FileActions.openTrash() }
            Divider()
            Button("Empty Trash…", systemImage: "trash.slash") { coordinator.requestEmptyTrash() }
                .disabled(bin.itemCount == 0 || bin.isBlocked || coordinator.isRunning)
        }
        .help(help(bin))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.quaternary) }
        return AnyShapeStyle(isHovering ? Color.primary.opacity(0.06) : Color.clear)
    }

    /// Size in a small capsule; turns red and counts down while emptying.
    @ViewBuilder
    private func badge(_ bin: TrashBinModel) -> some View {
        if bin.isBlocked {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !bin.isMeasured {
            ProgressView().controlSize(.mini)
        } else if bin.itemCount > 0 || bin.isEmptying {
            CountingBytes(bytes: Double(bin.bytes))
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(bin.isEmptying ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(bin.isEmptying ? AnyShapeStyle(.red) : AnyShapeStyle(.quaternary), in: .capsule)
                .motionTransition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    private func help(_ bin: TrashBinModel) -> String {
        if bin.isBlocked { return "Grant Full Disk Access to see what's in the Trash" }
        if bin.itemCount == 0 { return "The Trash is empty" }
        return "\(bin.itemCount.formatted()) \(bin.itemCount == 1 ? "item" : "items") · \(bin.bytes.fileSize)"
    }
}

/// The bin itself: gulps when something lands, shakes while emptying, sparkles when done.
private struct BinIcon: View {
    let isEmptying: Bool
    let arrivals: Int
    let emptied: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Same gray tile as the rows above (the size badge shows whether it's full); red while emptying.
        SidebarIcon(systemImage: "trash.fill", tint: isEmptying ? .red : .gray)
            .animation(.easeInOut(duration: 0.2), value: isEmptying)
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
            .frame(width: 24, height: 24)
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
