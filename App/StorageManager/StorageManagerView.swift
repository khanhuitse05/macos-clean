import MacosCleanCore
import QuickLook
import SwiftUI

struct StorageManagerView: View {
    let model: StorageModel
    let trash: TrashCoordinator
    let access: AccessModel
    let suggestions: SuggestionsModel
    let uninstaller: UninstallerModel
    /// Opens an app (by bundle path) in the Uninstaller.
    let onReviewApp: (String) -> Void
    /// The group picked in the sidebar; nil shows every group.
    var group: CleanupCategory.Group?

    @State private var expanded: Set<String> = []
    @State private var previewURL: URL?
    @State private var trashButton = FrameBox()
    /// A category a suggestion card pointed at; the list scrolls to it.
    @State private var scrollTarget: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    scrollTarget = nil
                }
        }
        // Emptying the Trash (here or in the Trash section) frees space: re-read the disk.
        .onChange(of: trash.bin.bytes) { old, new in
            if new < old { model.refreshVolume(settling: true) }
        }
        .task { model.refreshVolume() }
    }

    private var list: some View {
        @Bindable var model = model
        return List {
            StorageSummaryHeader(
                foundBytes: group.map(model.foundBytes(in:)) ?? model.foundBytes,
                selectedBytes: model.selectedBytes,
                trashBytes: trash.bin.isMeasured ? trash.bin.bytes : 0,
                volume: model.volume,
                hasResults: model.hasAnyResult,
                isScanning: model.isScanningAll,
                scanAllProgress: model.scanAllProgress,
                history: trash.history.history,
                liveBytes: { model.liveScannedBytes },
                liveFolder: { model.liveFolder }
            )
            .listRowSeparator(.hidden)

            if group == nil {
                SuggestionCards(
                    suggestions: suggestions.suggestions(storage: model, uninstaller: uninstaller),
                    onAction: perform,
                    onDismiss: { suggestions.dismiss($0) }
                )
                .listRowSeparator(.hidden)
            }

            if !model.deniedPaths.isEmpty {
                FullDiskAccessBanner(deniedPaths: model.deniedPaths, access: access) {
                    Task { await model.scanAll() }
                }
                .listRowSeparator(.hidden)
                .padding(.bottom, 4)
            }

            if model.filter.isActive, model.hasAnyResult {
                FilterStatusRow(counts: model.visibleCounts) { model.filter = EntryFilter(sort: model.filter.sort) }
                    .listRowSeparator(.hidden)
            }

            // Groups and their categories largest first, re-sorted as each scan finishes.
            ForEach(shownGroups) { group in
                let all = model.orderedCategories(in: group)
                let present = all.filter { !model.notOnThisMac.contains($0.id) && model.isVisible($0) }
                let missing = all.filter { model.notOnThisMac.contains($0.id) }
                Section {
                    ForEach(present) { category in
                        CategoryDisclosure(
                            category: category,
                            model: model,
                            trash: trash,
                            expanded: $expanded,
                            onQuickLook: { previewURL = $0 }
                        )
                        .id(category.id)
                    }
                    if !missing.isEmpty, !model.filter.isActive {
                        NotOnThisMacRow(categories: missing)
                    }
                } header: {
                    GroupHeader(group: group, model: model, trash: trash)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .safeAreaBar(edge: .bottom) {
            if model.selectedCount > 0 {
                SelectionBar(
                    title: "\(model.selectedBytes.fileSize) selected",
                    detail: selectionDetail
                ) {
                    Button("Deselect All") { model.selectNone() }
                    Button("Move to Trash…", systemImage: "trash") {
                        if let request = model.trashRequest() { trash.request(request, from: trashButton.rect) }
                    }
                    .trashOrigin(trashButton)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(trash.isRunning)
                }
                .motionTransition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motionAnimation(.snappy, value: model.selectedCount > 0)
        .navigationTitle(group.map { Text($0.title) } ?? Text("Storage Manager"))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                FilterMenu(filter: $model.filter)
                    .disabled(!model.hasAnyResult)
                Menu("Select", systemImage: "checklist") {
                    if model.filter.isActive {
                        Button("Select Visible Items") { model.setVisibleSelection(true) }
                        Button("Deselect Visible Items") { model.setVisibleSelection(false) }
                        Divider()
                    }
                    Button("Select All Scanned Items") { model.selectAll() }
                    Button("Deselect All") { model.selectNone() }
                }
                .disabled(!model.hasAnyResult)
                Button {
                    Task { await model.scanAll(in: group) }
                } label: {
                    Label(scanTitle, systemImage: "arrow.clockwise")
                        .symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: model.isScanningAll)
                }
                .disabled(model.isScanningAll)
                .keyboardShortcut("r", modifiers: .command)
                .help(model.isScanningAll ? "Scanning…" : group == nil ? "Scan every category (⌘R)" : "Scan this group (⌘R)")
            }
        }
        .quickLookPreview($previewURL)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search names and paths")
        .onChange(of: model.filter.query) { _, query in
            // Open the categories that have matches so they can be seen at once.
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            for category in model.categories where model.isVisible(category) { expanded.insert(category.id) }
        }
    }

    /// The group picked in the sidebar, or every group in size order (Personal Files last).
    private var shownGroups: [CleanupCategory.Group] {
        // Developer groups with nothing on this Mac are left out, as in the sidebar.
        let groups = group.map { [$0] } ?? model.groupOrder.filter { !model.isAbsent($0) }
        // While a search or filter narrows the list, drop groups left with no rows.
        guard model.filter.isActive else { return groups }
        return groups.filter { group in model.orderedCategories(in: group).contains(where: model.isVisible) }
    }

    private var scanTitle: String {
        let scanned = group.map(model.hasResult(in:)) ?? model.hasAnyResult
        if group == nil { return scanned ? "Rescan All" : "Scan All" }
        return scanned ? "Rescan" : "Scan"
    }

    private var selectionDetail: String {
        let items = "\(model.selectedCount.formatted()) \(model.selectedCount == 1 ? "item" : "items") will move to the Trash"
        let hidden = model.hiddenSelectedCount
        guard hidden > 0 else { return items }
        return "\(items) · \(hidden.formatted()) hidden by filters"
    }

    private func perform(_ suggestion: Suggestion) {
        switch suggestion.action {
        case .reviewApp(let path):
            onReviewApp(path)
        case .select(let categoryID, let paths):
            model.select(paths: paths)
            // Show what was ticked: open the category, bring it into view and make it glow.
            Motion.animate(.snappy(duration: 0.28)) { _ = expanded.insert(categoryID) }
            scrollTarget = categoryID
            model.highlight(categoryID)
        }
    }

    private var subtitle: String {
        let hasResult = group.map(model.hasResult(in:)) ?? model.hasAnyResult
        guard hasResult else { return "Not scanned yet" }
        let found = "\((group.map(model.foundBytes(in:)) ?? model.foundBytes).fileSize) found"
        if !model.refreshing.isEmpty { return "\(found) · Updating…" }
        if let date = model.oldestScan, date.timeIntervalSinceNow < -60 {
            return "\(found) · Scanned \(date.formatted(.relative(presentation: .named)))"
        }
        return found
    }
}

/// Toolbar menu for the size and age limits and the sort order of result rows.
private struct FilterMenu: View {
    @Binding var filter: EntryFilter

    var body: some View {
        Menu {
            Picker("Size", selection: $filter.minimumSize) {
                ForEach(EntryFilter.MinimumSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Age", selection: $filter.minimumAge) {
                ForEach(EntryFilter.MinimumAge.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Sort By", selection: $filter.sort) {
                ForEach(EntryFilter.Sort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Clear Filters") { filter = EntryFilter(query: filter.query, sort: filter.sort) }
                .disabled(filter.minimumSize == .any && filter.minimumAge == .any)
        } label: {
            Label("Filter", systemImage: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Filter results by size and age, and choose the sort order")
    }

    private var isFiltering: Bool { filter.minimumSize != .any || filter.minimumAge != .any }
}

/// Shown while a filter hides rows: how many rows are on screen, and a way back.
private struct FilterStatusRow: View {
    let counts: (shown: Int, total: Int)
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.tint)
            if counts.shown == 0 {
                Text("No items match the search or filters.")
            } else {
                Text("Showing \(counts.shown.formatted()) of \(counts.total.formatted()) items. Category checkboxes and Select Visible affect only these.")
            }
            Spacer(minLength: 8)
            Button("Clear", action: onClear)
                .controlSize(.small)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }
}

private struct StorageSummaryHeader: View {
    let foundBytes: Int64
    let selectedBytes: Int64
    /// What the Trash holds: still on disk until it's emptied.
    let trashBytes: Int64
    let volume: VolumeUsage?
    let hasResults: Bool
    let isScanning: Bool
    let scanAllProgress: (done: Int, total: Int)?
    let history: CleaningHistory
    /// Sampled while the first scan runs.
    let liveBytes: () -> Int64
    /// Sampled while a full scan runs.
    let liveFolder: () -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasResults {
                // Counts up as categories finish, and down as items leave for the Trash.
                CountingBytes(bytes: Double(foundBytes))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .motionAnimation(.smooth(duration: 0.9), value: foundBytes)
                Text("Found in caches, logs, developer files and downloads. Safe items are ticked for you; review the ones marked Caution.")
                    .foregroundStyle(.secondary)
            } else if isScanning {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let bytes = liveBytes()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Scanning…").font(.title2.weight(.semibold))
                        Text("\(bytes.fileSize) so far")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .motionAnimation(.snappy, value: bytes)
                    }
                }
                Text("Measuring every category. Results appear as each one finishes, largest first.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Find space you can free")
                    .font(.title2.weight(.semibold))
                Text("Scan all categories, or click a category to scan just that one. Nothing is removed until you confirm, and cleaned items go to the Trash first.")
                    .foregroundStyle(.secondary)
            }
            if let scanAllProgress {
                ScanAllProgressLine(progress: scanAllProgress, liveFolder: liveFolder)
                    .padding(.top, 6)
                    .motionTransition(.opacity.combined(with: .move(edge: .top)))
            }
            if let volume {
                StorageBar(
                    volume: volume, foundBytes: hasResults ? foundBytes : 0, selectedBytes: selectedBytes,
                    trashBytes: trashBytes
                )
                .padding(.top, 8)
            }
            CleaningHistoryLine(history: history)
                .padding(.top, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .motionAnimation(.default, value: foundBytes)
        .motionAnimation(.snappy, value: scanAllProgress == nil)
    }
}

/// "Scanning 12 of 38 categories", a thin bar, and the folder being read right now.
private struct ScanAllProgressLine: View {
    let progress: (done: Int, total: Int)
    let liveFolder: () -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .motionAnimation(.smooth(duration: 0.5), value: progress.done)
            HStack(spacing: 6) {
                Text("\(progress.done.formatted()) of \(progress.total.formatted()) categories")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .motionAnimation(.snappy, value: progress.done)
                FolderTicker(folder: liveFolder)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// The folder a scan is reading, sampled a few times a second; each new one slides in.
private struct FolderTicker: View {
    let folder: () -> String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { _ in
            let path = folder()?.abbreviatingHome
            ZStack(alignment: .leading) {
                if let path {
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.tertiary)
                        .id(path)
                        .motionTransition(.push(from: .bottom))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .motionAnimation(.snappy(duration: 0.25), value: path)
        }
        .accessibilityHidden(true)
    }
}

/// The home disk as one bar: other used space, junk found, the part of it selected, and free
/// space. Segment widths animate as scans finish and selections change.
private struct StorageBar: View {
    let volume: VolumeUsage
    let foundBytes: Int64
    let selectedBytes: Int64
    /// Moved to the Trash but still on disk: cleaned items slide here, and leave the bar
    /// (becoming free space) when the Trash is emptied.
    let trashBytes: Int64

    @State private var freedBurst = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let trashColor = Color.purple.opacity(0.45)

    var body: some View {
        let total = Double(volume.total)
        let used = Double(volume.used)
        let found = min(Double(foundBytes), used)
        let selected = min(Double(selectedBytes), found)
        let inTrash = min(Double(trashBytes), used - found)
        let other = used - found - inTrash
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                HStack(spacing: 0) {
                    Rectangle().fill(.gray.opacity(0.45)).frame(width: width * other / total)
                    Rectangle().fill(Self.trashColor).frame(width: width * inTrash / total)
                    Rectangle().fill(.orange.opacity(0.55)).frame(width: width * (found - selected) / total)
                    Rectangle().fill(.tint).frame(width: width * selected / total)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(.capsule)
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            HStack(spacing: 14) {
                LegendItem(color: .gray.opacity(0.45), label: "Used", bytes: Int64(other))
                if inTrash > 0 { LegendItem(color: Self.trashColor, label: "In Trash", bytes: Int64(inTrash)) }
                if found - selected > 0 { LegendItem(color: .orange.opacity(0.55), label: "Cleanable", bytes: Int64(found - selected)) }
                if selected > 0 { LegendItem(color: .accentColor, label: "Selected", bytes: Int64(selected)) }
                LegendItem(color: .secondary.opacity(0.25), label: "Free", bytes: volume.available)
                    // Space really coming back (the Trash emptied) gets a little burst.
                    .overlay(alignment: .leading) { SparkleBurst(trigger: freedBurst, tint: .green).offset(x: 4) }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .motionAnimation(.smooth(duration: 0.6), value: foundBytes)
        .motionAnimation(.smooth(duration: 0.4), value: selectedBytes)
        .motionAnimation(.smooth(duration: 0.6), value: trashBytes)
        .motionAnimation(.smooth(duration: 0.8), value: volume)
        .onChange(of: volume.available) { old, new in
            if !reduceMotion, new - old >= 10_000_000 { freedBurst += 1 }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LegendItem: View {
    let color: Color
    let label: LocalizedStringKey
    let bytes: Int64

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
            // Counts rather than swapping digits, so freed space visibly rolls up.
            CountingBytes(bytes: Double(bytes))
        }
    }
}

/// Bytes and files measured so far for one category, sampled four times a second. On a
/// rescan the ring fills toward the size found last time.
private struct ScanTicker: View {
    let progress: ScanProgress
    /// The category's size before this scan; nil on a first scan (spinner instead of a ring).
    let expected: Int64?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let bytes = progress.bytes
            let files = progress.files
            HStack(spacing: 8) {
                if let expected, expected > 0 {
                    // Never shows full: the folder may have grown since.
                    ProgressView(value: min(0.97, Double(bytes) / Double(expected)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .motionAnimation(.smooth(duration: 0.25), value: bytes)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(bytes.fileSize)
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("\(files.formatted()) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .frame(minWidth: 80, alignment: .trailing)
                .motionAnimation(.snappy, value: bytes)
            }
        }
    }
}

private struct CategoryDisclosure: View {
    let category: CleanupCategory
    let model: StorageModel
    let trash: TrashCoordinator
    @Binding var expanded: Set<String>
    let onQuickLook: (URL) -> Void

    var body: some View {
        let phase = model.phase(of: category)
        DisclosureGroup(isExpanded: expansion) {
            switch phase {
            case .notScanned:
                Text("Not scanned yet").foregroundStyle(.secondary)
            case .scanning:
                HStack { ProgressView().controlSize(.small); Text("Scanning…").foregroundStyle(.secondary) }
                    .transition(.opacity)
            case .scanned(let result):
                if !result.deniedPaths.isEmpty {
                    Label("Some locations here are blocked by macOS. Grant Full Disk Access to see them.", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if result.entries.isEmpty {
                    Label("Nothing to clean here", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                        .symbolEffect(.bounce, options: .nonRepeating, value: result.scannedAt)
                } else {
                    ForEach(model.visibleEntries(of: result)) { entry in
                        EntryRow(
                            entry: entry, model: model, trash: trash,
                            expanded: $expanded, onQuickLook: onQuickLook
                        )
                    }
                }
            }
        } label: {
            CategoryRow(category: category, phase: phase, model: model, trash: trash)
        }
        .onChange(of: expanded.contains(category.id)) { _, isOpen in
            if isOpen, phase == .notScanned { Task { await model.scan(category) } }
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { expanded.contains(category.id) },
            set: { open in
                // Rows slide open and closed together with the chevron.
                Motion.animate(.snappy(duration: 0.28)) {
                    if open { expanded.insert(category.id) } else { expanded.remove(category.id) }
                }
            }
        )
    }
}

private struct CategoryRow: View {
    let category: CleanupCategory
    let phase: StorageModel.Phase
    let model: StorageModel
    let trash: TrashCoordinator

    var body: some View {
        HStack(spacing: 10) {
            TriStateCheckbox(state: model.checkState(of: category), isEnabled: phase != .scanning) {
                Task { await model.toggle(category) }
            }
            .help("Select everything in this category")
            Image(systemName: CategoryStyle.symbol(for: category.id))
                .font(.title3)
                .foregroundStyle(.tint)
                // A little hop each time this category's results arrive.
                .symbolEffect(.bounce, options: .nonRepeating, value: scannedAt)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(category.name).font(.headline)
                    SafetyBadge(safety: category.safety)
                }
                Text(category.details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(Text(category.details))
                if phase == .scanning, let progress = model.liveProgress(of: category) {
                    FolderTicker(folder: { progress.currentFolder })
                        .font(.caption)
                        .motionTransition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .background { RowGlow(trigger: model.highlights[category.id] ?? 0) }
        .motionAnimation(.snappy, value: phase == .scanning)
    }

    private var scannedAt: Date? {
        if case .scanned(let result) = phase { result.scannedAt } else { nil }
    }

    @ViewBuilder
    private var trailing: some View {
        switch phase {
        case .notScanned:
            Button("Scan") { Task { await model.scan(category) } }
                .controlSize(.small)
        case .scanning:
            if let progress = model.liveProgress(of: category) {
                ScanTicker(progress: progress, expected: model.expectedBytes(of: category))
            } else {
                ProgressView().controlSize(.small)
            }
        case .scanned(let result):
            HStack(spacing: 8) {
                if model.isRefreshing(category) {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Updating the results saved last time…")
                }
                if !result.deniedPaths.isEmpty {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                        .symbolEffect(.wiggle, options: .nonRepeating, value: result.scannedAt)
                        .help("macOS blocked some folders. Grant Full Disk Access to include them.")
                }
                VStack(alignment: .trailing, spacing: 1) {
                    if result.entries.isEmpty && !result.deniedPaths.isEmpty {
                        Text("Blocked").font(.body.weight(.medium))
                    } else {
                        CountUpBytes(bytes: result.totalBytes, fromZero: model.isJustRevealed(category))
                            .font(.body.weight(.medium))
                    }
                    let selected = model.selectedBytes(in: category)
                    if selected > 0 {
                        Text("\(selected.fileSize) selected")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .motionTransition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                    }
                }
                .frame(minWidth: 80, alignment: .trailing)
            }
        }
    }
}

private struct EntryRow: View {
    let entry: FileEntry
    let model: StorageModel
    let trash: TrashCoordinator
    @Binding var expanded: Set<String>
    let onQuickLook: (URL) -> Void

    @State private var origin = FrameBox()

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: expansion) {
                if let kids = model.children[entry.path] {
                    if kids.isEmpty {
                        Text("Empty folder").foregroundStyle(.secondary)
                    }
                    ForEach(kids) { child in
                        EntryRow(entry: child, model: model, trash: trash,
                                 expanded: $expanded, onQuickLook: onQuickLook)
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
                        .task { await model.loadChildren(of: entry) }
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        let simulator = model.simulatorItem(at: entry.path)
        return HStack(spacing: 8) {
            TriStateCheckbox(state: model.checkState(of: entry)) { model.toggle(entry) }
            if let simulator {
                SimulatorLabel(item: simulator)
            } else {
                FileIcon(path: entry.path, isDirectory: entry.isDirectory)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                    Text(entry.parentPath.abbreviatingHome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            Text(entry.sizeBytes.fileSize)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .trashOrigin(origin)
        .contextMenu {
            FileContextMenu(
                path: entry.path,
                onQuickLook: simulator == nil ? onQuickLook : nil,
                onTrash: { trash.request(model.trashRequest(for: entry), from: origin.rect) },
                canExclude: simulator == nil,
                trashTitle: simulator == nil ? "Move to Trash…" : "Delete with simctl…"
            )
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { expanded.contains(entry.path) },
            set: { open in
                // Prefetched children appear in the same frame, without a "Loading…" row.
                if open { model.expand(entry) }
                Motion.animate(.snappy(duration: 0.28)) {
                    if open { expanded.insert(entry.path) } else { expanded.remove(entry.path) }
                }
            }
        )
    }
}

/// A simulator runtime or device row: what it is instead of a file name.
private struct SimulatorLabel: View {
    let item: SimulatorItem

    var body: some View {
        Image(systemName: item.kind == .runtime ? "shippingbox.fill" : "iphone")
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(item.name).lineLimit(1)
                if !item.isAvailable {
                    Text("Unavailable")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.2), in: .capsule)
                        .foregroundStyle(.orange)
                        .help("Its runtime is gone, so this device can't run anymore.")
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var subtitle: String {
        var parts = [item.detail]
        if let used = item.lastUsed {
            parts.append("last used \(used.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("never used")
        }
        return parts.joined(separator: " · ")
    }
}

/// A group's title with its checkbox, total, and "Clean Safe Items".
private struct GroupHeader: View {
    let group: CleanupCategory.Group
    let model: StorageModel
    let trash: TrashCoordinator

    var body: some View {
        let hasResult = model.hasResult(in: group)
        HStack(spacing: 8) {
            TriStateCheckbox(state: model.checkState(of: group), isEnabled: hasResult && !model.isScanning(group)) {
                model.toggle(group)
            }
            .help("Select everything in this group")
            Text(group.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if model.hasSafeItems(in: group) {
                TrashOriginReader { origin in
                    Button("Clean Safe Items…") {
                        if let request = model.safeItemsRequest(in: group) { trash.request(request, from: origin.rect) }
                    }
                        .controlSize(.small)
                        .disabled(trash.isRunning)
                        .help("Move every Safe item in \(String(localized: group.title)) to the Trash")
                }
            }
            if hasResult {
                CountingBytes(bytes: Double(model.foundBytes(in: group)))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .motionAnimation(.smooth(duration: 0.6), value: model.foundBytes(in: group))
                    .frame(minWidth: 80, alignment: .trailing)
            }
        }
        .textCase(nil)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

/// The group's categories whose tools aren't on this Mac, folded into one row.
private struct NotOnThisMacRow: View {
    let categories: [CleanupCategory]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(categories.map { String(localized: $0.name) }.formatted(.list(type: .and)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label("Not on this Mac (\(categories.count))", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .help("Nothing of these tools was found on this Mac. They're scanned again with every scan.")
        }
    }
}

/// A soft tinted wash that fades in and out behind a row each time `trigger` changes:
/// results just arrived, or a suggestion pointed here. Opacity only, so it stays with
/// Reduce motion on.
private struct RowGlow: View {
    let trigger: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.tint)
            .padding(.horizontal, -6)
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, opacity in
                content.opacity(opacity)
            } keyframes: { _ in
                CubicKeyframe(0.16, duration: 0.25)
                CubicKeyframe(0.16, duration: 0.35)
                CubicKeyframe(0, duration: 0.9)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A size that counts up from zero when it first appears right after a scan (`fromZero`),
/// and counts to each new value after that.
private struct CountUpBytes: View {
    let bytes: Int64
    let fromZero: Bool

    @State private var shown: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CountingBytes(bytes: shown ?? Double(bytes))
            .onAppear {
                guard fromZero, !reduceMotion, shown == nil else { return }
                shown = 0
                withAnimation(.smooth(duration: 0.9)) { shown = Double(bytes) }
            }
            .onChange(of: bytes) { _, new in
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.6)) { shown = Double(new) }
            }
    }
}

enum CategoryStyle {
    static func symbol(for id: String) -> String {
        switch id {
        case "user-caches": "archivebox"
        case "user-logs": "doc.plaintext"
        case "trash": "trash"
        case "xcode-derived": "hammer"
        case "xcode-archives": "tray.full"
        case "xcode-device-support": "iphone"
        case "simulator-caches": "ipad.and.iphone"
        case "simulators": "iphone.badge.play"
        case "xcode-previews": "eye.square"
        case "ios-updates": "arrow.down.app"
        case "spm-cache": "swift"
        case "homebrew-cache": "mug"
        case "docker-data": "cube"
        case "claude-data": "bubble.left.and.text.bubble.right"
        case "local-ai-logs": "doc.text.magnifyingglass"
        case "local-ai-history": "text.bubble"
        case "local-ai-models": "cpu"
        case "browser-test-downloads": "safari"
        case "electron-cache": "atom"
        case "maven-repository", "nuget-packages": "shippingbox.circle"
        case "ios-backups": "externaldrive.badge.timemachine"
        case "app-caches": "square.stack.3d.up"
        case "dev-projects": "chevron.left.forwardslash.chevron.right"
        case "system-downloads": "arrow.down.circle"
        default: "shippingbox"
        }
    }
}
