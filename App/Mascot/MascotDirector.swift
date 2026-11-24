import AppKit
import MacosCleanCore

/// Everything Bubbl shows at one moment, read from the section on screen.
struct MascotScene: Equatable {
    var section: AppSection
    var mood: MascotMood
    /// Share (0…1) of what's on screen that is ticked: grows the bubble, gulps when it rises.
    var selectionShare: Double = 0
    /// Ticked items. Reactions fire on this, not on sizes, which live refresh nudges.
    var selectedCount = 0
    /// Open folder columns in File Browser: dives when it grows, surfaces when it shrinks.
    var depth = 0
    /// The single item in focus (a file in File Browser, an app in Uninstaller): glances on change.
    var focusID: String?
    /// The app being uninstalled right now, shown inside the bubble while it's carried away.
    var carriedAppPath: String?
    /// A bar is pinned to the bottom of the section; Bubbl sits above it.
    var hasBottomBar = false
}

/// Derives ``MascotScene`` from the app state. Reading happens inside the overlay's body, so
/// only the overlay re-renders when these values change.
@MainActor
enum MascotDirector {
    static func scene(for state: AppState) -> MascotScene {
        let section = state.section ?? .storage
        let trashing = state.trash.isRunning
        let blocked = !state.access.hasFullDiskAccess

        switch section {
        case .storage:
            let model = state.storage
            let mood = MascotMood.resolve(MascotInputs(
                isScanning: model.isScanningAll || model.categories.contains { model.phase(of: $0) == .scanning },
                hasResults: model.hasAnyResult,
                foundBytes: model.foundBytes,
                isTrashing: trashing,
                isAccessBlocked: blocked || !model.deniedPaths.isEmpty
            ))
            return MascotScene(
                section: section, mood: mood,
                selectionShare: share(model.selectedBytes, of: model.foundBytes),
                selectedCount: model.selectedCount,
                hasBottomBar: model.selectedCount > 0
            )

        case .largeFiles:
            let model = state.largeFiles
            let largest = model.hasScanned ? model.visibleRows.lazy.map(\.sizeBytes).max() ?? 0 : 0
            let mood = MascotMood.resolve(MascotInputs(
                isScanning: model.isScanning,
                hasResults: model.hasScanned,
                foundBytes: model.totalBytes,
                isTrashing: trashing,
                isAccessBlocked: blocked && !model.deniedPaths.isEmpty,
                largestItemBytes: largest
            ))
            return MascotScene(
                section: section, mood: mood,
                selectionShare: share(model.checkedBytes, of: model.totalBytes),
                selectedCount: model.checked.count,
                hasBottomBar: !model.checked.isEmpty
            )

        case .duplicates:
            let model = state.duplicates
            let mood = MascotMood.resolve(MascotInputs(
                isScanning: model.isScanning,
                hasResults: model.hasScanned,
                foundBytes: model.wastedBytes,
                isTrashing: trashing,
                isAccessBlocked: blocked && !model.deniedPaths.isEmpty
            ))
            return MascotScene(
                section: section, mood: mood,
                selectionShare: share(model.checkedBytes, of: model.wastedBytes),
                selectedCount: model.checked.count,
                hasBottomBar: !model.checked.isEmpty
            )

        case .fileBrowser:
            let model = state.fileBrowser
            let selected = model.selectedEntry
            let selectedBytes = selected.map { model.isMeasuring($0) ? 0 : $0.sizeBytes } ?? 0
            let mood = MascotMood.resolve(MascotInputs(
                isScanning: model.rootBytes == nil && model.state(of: model.root.path)?.isDenied != true,
                hasResults: false,
                foundBytes: 0,
                isTrashing: trashing,
                isAccessBlocked: false,
                largestItemBytes: selectedBytes
            ))
            return MascotScene(
                section: section, mood: mood,
                depth: model.columns.count,
                // Folders answer with a dive (a new column opens); files get a glance.
                focusID: selected.flatMap { $0.isDirectory ? nil : $0.path },
                hasBottomBar: true
            )

        case .trash:
            return trashScene(state, trashing: trashing)

        case .uninstaller:
            let model = state.uninstaller
            let item = model.selectedItem
            var appBytes: Int64 = 0
            if case .app(let app) = item { appBytes = model.sizes[app.path] ?? 0 }
            let leftovers = item.flatMap { model.leftovers[$0.id]?.totalBytes } ?? 0
            let checkedEntries = item.map { model.checkedEntries(for: $0) } ?? []
            let checked = checkedEntries.reduce(0) { $0 + $1.sizeBytes }
            let mood = MascotMood.resolve(MascotInputs(
                isScanning: model.isLoading || item.map { model.loadingLeftovers.contains($0.id) } ?? false,
                hasResults: item != nil && appBytes + leftovers > 0,
                foundBytes: appBytes + leftovers,
                isTrashing: trashing,
                isAccessBlocked: false,
                largestItemBytes: appBytes
            ))
            let carried = trashing ? item.flatMap { model.removesApp($0) ? $0.appURL?.path : nil } : nil
            return MascotScene(
                section: section, mood: mood,
                selectionShare: share(checked, of: appBytes + leftovers),
                selectedCount: checkedEntries.count,
                focusID: item?.id,
                carriedAppPath: carried,
                hasBottomBar: checked > 0
            )
        }
    }

    private static func trashScene(_ state: AppState, trashing: Bool) -> MascotScene {
        let bin = state.trash.bin
        let mood = MascotMood.resolve(MascotInputs(
            isScanning: !bin.isMeasured && !bin.isBlocked,
            hasResults: bin.isMeasured,
            foundBytes: bin.bytes,
            isTrashing: trashing,
            isAccessBlocked: bin.isBlocked,
            largestItemBytes: bin.items.lazy.map(\.sizeBytes).max() ?? 0
        ))
        return MascotScene(
            section: .trash, mood: mood,
            selectionShare: share(bin.pickedBytes, of: bin.bytes),
            selectedCount: bin.picks.count,
            hasBottomBar: !bin.picks.isEmpty
        )
    }

    private static func share(_ part: Int64, of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(part) / Double(total)))
    }

    /// The reaction to a scene change, if any. Switching sections never triggers one.
    static func reaction(from old: MascotScene, to new: MascotScene) -> MascotReaction? {
        guard old.section == new.section else { return nil }
        if let depth = MascotReaction.forDepth(from: old.depth, to: new.depth) { return depth }
        // A new focus (another app) re-ticks its own leftovers; that's a glance, not a gulp.
        if new.focusID != nil, new.focusID != old.focusID { return .glance }
        if new.selectedCount != old.selectedCount {
            if new.selectedCount < old.selectedCount { return .spit }
            return MascotReaction.forSelection(from: old.selectionShare, to: new.selectionShare) ?? .gulp
        }
        return nil
    }
}
