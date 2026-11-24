import MacosCleanCore
import QuickLook
import SwiftUI

struct StorageManagerView: View {
    let model: StorageModel
    let trash: TrashCoordinator
    let access: AccessModel

    @State private var expanded: Set<String> = []
    @State private var previewURL: URL?

    var body: some View {
        List {
            StorageSummaryHeader(
                foundBytes: model.foundBytes,
                hasResults: model.hasAnyResult,
                isScanning: model.isScanningAll
            )
            .listRowSeparator(.hidden)

            if !model.deniedPaths.isEmpty {
                FullDiskAccessBanner(deniedPaths: model.deniedPaths, access: access) {
                    Task { await model.scanAll() }
                }
                .listRowSeparator(.hidden)
                .padding(.bottom, 4)
            }

            ForEach(model.categories) { category in
                CategoryDisclosure(
                    category: category,
                    model: model,
                    expanded: $expanded,
                    onQuickLook: { previewURL = $0 },
                    onTrash: { trash.request(model.trashRequest(for: $0)) }
                )
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .safeAreaBar(edge: .bottom) {
            if model.selectedCount > 0 {
                SelectionBar(
                    title: "\(model.selectedBytes.fileSize) selected",
                    detail: "\(model.selectedCount.formatted()) \(model.selectedCount == 1 ? "item" : "items") will move to the Trash"
                ) {
                    Button("Deselect All") { model.selectNone() }
                    Button("Move to Trash…", systemImage: "trash") {
                        if let request = model.trashRequest() { trash.request(request) }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(trash.isRunning)
                }
            }
        }
        .navigationTitle("Storage Manager")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu("Select", systemImage: "checklist") {
                    Button("Select All Scanned Items") { model.selectAll() }
                    Button("Deselect All") { model.selectNone() }
                }
                .disabled(!model.hasAnyResult)
                Button {
                    Task { await model.scanAll() }
                } label: {
                    if model.isScanningAll {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Label(model.hasAnyResult ? "Rescan All" : "Scan All", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isScanningAll)
                .keyboardShortcut("r", modifiers: .command)
                .help(model.isScanningAll ? "Scanning…" : "Scan every category (⌘R)")
            }
        }
        .quickLookPreview($previewURL)
    }

    private var subtitle: String {
        guard model.hasAnyResult else { return "Not scanned yet" }
        let found = "\(model.foundBytes.fileSize) found"
        if !model.refreshing.isEmpty { return "\(found) · Updating…" }
        if let date = model.oldestScan, date.timeIntervalSinceNow < -60 {
            return "\(found) · Scanned \(date.formatted(.relative(presentation: .named)))"
        }
        return found
    }
}

private struct StorageSummaryHeader: View {
    let foundBytes: Int64
    let hasResults: Bool
    let isScanning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasResults {
                Text(foundBytes.fileSize)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Found in caches, logs, developer files and downloads. Safe items are ticked for you; review the ones marked Caution.")
                    .foregroundStyle(.secondary)
            } else {
                Text(isScanning ? "Scanning…" : "Find space you can free")
                    .font(.title2.weight(.semibold))
                Text("Scan all categories, or click a category to scan just that one. Nothing is removed until you confirm, and everything goes to the Trash.")
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .animation(.default, value: foundBytes)
    }
}

private struct CategoryDisclosure: View {
    let category: CleanupCategory
    let model: StorageModel
    @Binding var expanded: Set<String>
    let onQuickLook: (URL) -> Void
    let onTrash: (FileEntry) -> Void

    var body: some View {
        let phase = model.phase(of: category)
        DisclosureGroup(isExpanded: expansion) {
            switch phase {
            case .notScanned:
                Text("Not scanned yet").foregroundStyle(.secondary)
            case .scanning:
                HStack { ProgressView().controlSize(.small); Text("Scanning…").foregroundStyle(.secondary) }
            case .scanned(let result):
                if !result.deniedPaths.isEmpty {
                    Label("Some locations here are blocked by macOS. Grant Full Disk Access to see them.", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if result.entries.isEmpty {
                    Label("Nothing to clean here", systemImage: "sparkles").foregroundStyle(.secondary)
                } else {
                    ForEach(result.entries) { entry in
                        EntryRow(
                            entry: entry, model: model, isReadOnly: model.isReadOnly(category),
                            expanded: $expanded, onQuickLook: onQuickLook, onTrash: onTrash
                        )
                    }
                }
            }
        } label: {
            CategoryRow(category: category, phase: phase, model: model)
        }
        .onChange(of: expanded.contains(category.id)) { _, isOpen in
            if isOpen, phase == .notScanned { Task { await model.scan(category) } }
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { expanded.contains(category.id) },
            set: { open in
                if open { expanded.insert(category.id) } else { expanded.remove(category.id) }
            }
        )
    }
}

private struct CategoryRow: View {
    let category: CleanupCategory
    let phase: StorageModel.Phase
    let model: StorageModel

    var body: some View {
        HStack(spacing: 10) {
            if model.isReadOnly(category) {
                Color.clear.frame(width: 14, height: 14)
            } else {
                TriStateCheckbox(state: model.checkState(of: category), isEnabled: phase != .scanning) {
                    Task { await model.toggle(category) }
                }
                .help("Select everything in this category")
            }
            Image(systemName: CategoryStyle.symbol(for: category.id))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(category.name).font(.headline)
                    if !model.isReadOnly(category) {
                        SafetyBadge(safety: category.safety)
                    }
                }
                Text(category.details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(Text(category.details))
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var trailing: some View {
        switch phase {
        case .notScanned:
            Button("Scan") { Task { await model.scan(category) } }
                .controlSize(.small)
        case .scanning:
            ProgressView().controlSize(.small)
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
                        .help("macOS blocked some folders. Grant Full Disk Access to include them.")
                }
                if model.isReadOnly(category) {
                    Button("Open Trash", systemImage: "trash") { FileActions.openTrash() }
                        .controlSize(.small)
                        .help("Empty the Trash yourself in Finder. macos-clean never deletes files permanently.")
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(result.entries.isEmpty && !result.deniedPaths.isEmpty ? "Blocked" : result.totalBytes.fileSize)
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                    let selected = model.selectedBytes(in: category)
                    if selected > 0 {
                        Text("\(selected.fileSize) selected")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .monospacedDigit()
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
    let isReadOnly: Bool
    @Binding var expanded: Set<String>
    let onQuickLook: (URL) -> Void
    let onTrash: (FileEntry) -> Void

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: expansion) {
                if let kids = model.children[entry.path] {
                    if kids.isEmpty {
                        Text("Empty folder").foregroundStyle(.secondary)
                    }
                    ForEach(kids) { child in
                        EntryRow(entry: child, model: model, isReadOnly: isReadOnly,
                                 expanded: $expanded, onQuickLook: onQuickLook, onTrash: onTrash)
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
        HStack(spacing: 8) {
            if !isReadOnly {
                TriStateCheckbox(state: model.checkState(of: entry)) { model.toggle(entry) }
            }
            FileIcon(path: entry.path, isDirectory: entry.isDirectory)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Text(entry.parentPath.abbreviatingHome)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(entry.sizeBytes.fileSize)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .contextMenu {
            FileContextMenu(
                path: entry.path,
                onQuickLook: onQuickLook,
                onTrash: isReadOnly ? nil : { onTrash(entry) }
            )
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { expanded.contains(entry.path) },
            set: { open in
                if open {
                    // Prefetched children appear in the same frame, without a "Loading…" row.
                    model.expand(entry)
                    expanded.insert(entry.path)
                } else {
                    expanded.remove(entry.path)
                }
            }
        )
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
        case "spm-cache": "swift"
        case "homebrew-cache": "mug"
        case "docker-data": "cube"
        case "claude-data": "bubble.left.and.text.bubble.right"
        case "ios-backups": "externaldrive.badge.timemachine"
        case "app-caches": "square.stack.3d.up"
        case "dev-projects": "chevron.left.forwardslash.chevron.right"
        case "system-downloads": "arrow.down.circle"
        default: "shippingbox"
        }
    }
}
