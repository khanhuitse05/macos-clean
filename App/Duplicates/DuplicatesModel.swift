import MacosCleanCore
import SwiftUI

/// State of the Duplicates section (N1): a search for identical files under one folder, the
/// groups found, and which copies are ticked for the Trash.
@MainActor
@Observable
final class DuplicatesModel {
    /// Minimum file sizes offered, in MB.
    static let thresholds: [Int] = [1, 10, 50, 100, 500]

    enum KeepRule: String, CaseIterable, Identifiable {
        case newest, oldest, shortestPath
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .newest: "Keep Newest Copy"
            case .oldest: "Keep Oldest Copy"
            case .shortestPath: "Keep Copy With Shortest Path"
            }
        }
    }

    var root: URL = URL(fileURLWithPath: NSHomeDirectory())
    var minimumMB: Int = {
        let stored = UserDefaults.standard.integer(forKey: "duplicatesMinimumMB")
        return stored > 0 ? stored : 10
    }() {
        didSet { UserDefaults.standard.set(minimumMB, forKey: "duplicatesMinimumMB") }
    }
    var searchText = "" { didSet { refreshVisible() } }

    private(set) var groups: [DuplicateGroup] = []
    private(set) var visibleGroups: [DuplicateGroup] = []
    /// Visible groups with at least one copy among the person's own files.
    private(set) var userGroups: [DuplicateGroup] = []
    /// Visible groups whose copies all belong to apps (only found when ~/Library is searched).
    private(set) var managedGroups: [DuplicateGroup] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var stage: DuplicateEvent.Stage = .walking
    private(set) var stageDone = 0
    private(set) var stageTotal = 0
    private(set) var deniedPaths: [String] = []
    private(set) var wastedBytes: Int64 = 0
    /// The folder the search is walking through, while it looks for files.
    private(set) var currentFolder = ""
    /// The group found most recently while scanning.
    private(set) var latestFound: DuplicateGroup?

    private(set) var checked: Set<String> = [] { didSet { recomputeChecked() } }
    private(set) var checkedBytes: Int64 = 0
    /// Groups with every copy ticked: trashing them would lose the content.
    private(set) var fullyCheckedGroups: Set<String> = []

    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    /// Groups found but not shown yet: they join the list a few times a second, not one by one.
    private var pendingFound: [DuplicateGroup] = []
    private var pendingFlush: Task<Void, Never>?
    private var folderShownAt = ContinuousClock.now

    static let homeURL = URL(fileURLWithPath: NSHomeDirectory())
    static let libraryURL = homeURL.appendingPathComponent("Library", isDirectory: true)

    var isHomeScope: Bool { root.standardizedFileURL.path == Self.homeURL.standardizedFileURL.path }

    var rootDisplayName: String {
        isHomeScope ? "Home" : root.lastPathComponent
    }

    /// Home also searches iCloud Drive; ~/Library is skipped unless it is the chosen folder.
    private var searchRoots: [URL] {
        isHomeScope ? DuplicateFinder.userRoots() : [root]
    }

    var canTrash: Bool { !checked.isEmpty && fullyCheckedGroups.isEmpty }

    // MARK: Scanning

    func scan() {
        stop()
        groups = []
        checked = []
        deniedPaths = []
        stage = .walking
        stageDone = 0
        stageTotal = 0
        currentFolder = ""
        latestFound = nil
        isScanning = true
        hasScanned = true
        refreshVisible()

        let finder = DuplicateFinder(
            roots: searchRoots, minimumBytes: Int64(minimumMB) * 1_024 * 1_024, exclusions: ExclusionStore.shared.list
        )
        scanGeneration += 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            for await event in finder.scan() {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .progress(let stage, let done, let total):
                    self.stage = stage
                    stageDone = done
                    stageTotal = total
                case .looking(let folder):
                    // Several walkers report at once; show a new folder a couple of times a second.
                    let now = ContinuousClock.now
                    if now - folderShownAt >= .milliseconds(450) {
                        folderShownAt = now
                        currentFolder = folder
                    }
                case .found(let group):
                    pendingFound.append(group)
                    scheduleFoundFlush()
                case .denied(let path):
                    deniedPaths.append(path)
                case .finished(let found):
                    pendingFlush?.cancel()
                    pendingFlush = nil
                    pendingFound = []
                    Motion.animate {
                        groups = found
                        refreshVisible()
                    }
                }
            }
            if let self, generation == scanGeneration { isScanning = false }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        pendingFlush?.cancel()
        pendingFlush = nil
        pendingFound = []
        isScanning = false
    }

    private func scheduleFoundFlush() {
        guard pendingFlush == nil else { return }
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            pendingFlush = nil
            let batch = pendingFound
            pendingFound = []
            guard !batch.isEmpty else { return }
            Motion.animate(.snappy) {
                for group in batch {
                    let index = groups.firstIndex { $0.wastedBytes < group.wastedBytes } ?? groups.endIndex
                    groups.insert(group, at: index)
                }
                latestFound = batch.last
                refreshVisible()
            }
        }
    }

    /// Hides groups in folders the user just excluded (the chosen root itself never counts).
    func setExclusions(_ exclusions: ExclusionList) {
        let effective = exclusions.applying(toRoot: root.standardizedFileURL.path)
        guard !effective.isEmpty else { return }
        let hidden = Set(groups.flatMap(\.files).lazy.filter { effective.isExcluded($0.path) }.map(\.path))
        guard !hidden.isEmpty else { return }
        Motion.animate { drop(hidden) }
    }

    private func refreshVisible() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        visibleGroups = query.isEmpty ? groups : groups.filter { group in
            group.files.contains {
                $0.displayName.localizedStandardContains(query) || $0.path.localizedStandardContains(query)
            }
        }
        userGroups = visibleGroups.filter { !$0.isAppManaged }
        managedGroups = visibleGroups.filter(\.isAppManaged)
        wastedBytes = groups.reduce(0) { $0 + $1.wastedBytes }
    }

    // MARK: Selection

    func isChecked(_ entry: FileEntry) -> Bool { checked.contains(entry.path) }

    func toggle(_ entry: FileEntry) {
        if checked.remove(entry.path) == nil { checked.insert(entry.path) }
    }

    func state(of group: DuplicateGroup) -> CheckState {
        let count = group.files.count { checked.contains($0.path) }
        return count == 0 ? .off : (count == group.files.count ? .on : .mixed)
    }

    /// Ticks every copy but one in `group` (or clears it when it's already ticked that way).
    func toggle(_ group: DuplicateGroup, keeping rule: KeepRule = .newest) {
        let paths = group.files.map(\.path)
        if paths.contains(where: checked.contains) {
            checked.subtract(paths)
        } else {
            let keep = Self.keeper(of: group, rule: rule)
            checked.formUnion(paths.filter { $0 != keep })
        }
    }

    /// Ticks the extra copies in every visible group of the person's own files, keeping one per
    /// group by `rule`. App-managed groups are left alone: they're ticked only by hand.
    func selectDuplicates(keeping rule: KeepRule) {
        var next = checked
        for group in userGroups {
            let keep = Self.keeper(of: group, rule: rule)
            for file in group.files {
                if file.path == keep { next.remove(file.path) } else { next.insert(file.path) }
            }
        }
        checked = next
    }

    func uncheckAll() { checked.removeAll() }

    static func keeper(of group: DuplicateGroup, rule: KeepRule) -> String? {
        let files = group.files
        let pick: FileEntry? = switch rule {
        case .newest: files.max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        case .oldest: files.min { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        case .shortestPath: files.min { $0.path.count != $1.path.count ? $0.path.count < $1.path.count : $0.path < $1.path }
        }
        return pick?.path
    }

    private func recomputeChecked() {
        var bytes: Int64 = 0
        var full = Set<String>()
        for group in groups {
            var ticked = 0
            for file in group.files where checked.contains(file.path) {
                ticked += 1
                bytes += file.sizeBytes
            }
            if ticked == group.files.count { full.insert(group.id) }
        }
        if checkedBytes != bytes { checkedBytes = bytes }
        if fullyCheckedGroups != full { fullyCheckedGroups = full }
    }

    // MARK: Trash

    func trashRequest(for paths: Set<String>? = nil) -> TrashCoordinator.Request? {
        let target = paths ?? checked
        let files = groups.flatMap(\.files).filter { target.contains($0.path) }
        guard !files.isEmpty else { return nil }
        let finish: @MainActor (CleanSummary) -> Void = { [weak self] summary in self?.removeTrashed(summary) }
        if files.count == 1 { return .single(files[0], onFinish: finish) }
        return .items(
            files.map(\.path), bytes: files.totalBytes, noun: "duplicate copies",
            extraMessage: "One copy of each file stays where it is.", onFinish: finish
        )
    }

    private func removeTrashed(_ summary: CleanSummary) {
        drop(summary.trashedPaths)
    }

    /// Removes `paths` from the groups; a group left with one copy has no duplicates anymore.
    private func drop(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        groups = groups.compactMap { group in
            let kept = group.files.filter { !paths.contains($0.path) }
            guard kept.count > 1 else { return nil }
            return kept.count == group.files.count ? group : DuplicateGroup(id: group.id, fileBytes: group.fileBytes, files: kept, isAppManaged: group.isAppManaged)
        }
        let live = Set(groups.flatMap(\.files).map(\.path))
        checked = checked.intersection(live)
        refreshVisible()
    }
}
