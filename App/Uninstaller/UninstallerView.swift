import MacosCleanCore
import QuickLook
import SwiftUI

struct UninstallerView: View {
    @Bindable var model: UninstallerModel
    let trash: TrashCoordinator
    let access: AccessModel

    var body: some View {
        HSplitView {
            AppListPane(model: model)
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
            Group {
                if let item = model.selectedItem {
                    AppDetailPane(item: item, model: model, trash: trash, access: access)
                        .id(item.id)
                } else {
                    ContentUnavailableView(
                        "Select an App",
                        systemImage: "xmark.app",
                        description: Text("Choose an app to see the files it keeps on your Mac, then move them to the Trash together.")
                    )
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Uninstaller")
        .navigationSubtitle("\(model.apps.count { $0.canUninstall }) apps")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search apps")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Matching", selection: $model.sensitivity) {
                        ForEach(MatchSensitivity.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Text(model.sensitivity.details)
                } label: {
                    Label("Matching: \(String(localized: model.sensitivity.title))", systemImage: "scope")
                }
                .help("How widely to look for an app's files: Strict, Enhanced or Deep")
                Picker("Sort By", selection: $model.sortOrder) {
                    ForEach(UninstallerModel.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .alert("Couldn't Continue", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { model.start() }
    }
}

private struct AppListPane: View {
    @Bindable var model: UninstallerModel

    var body: some View {
        List(selection: $model.selectedID) {
            if let gone = model.justRemoved {
                RemovedBanner(name: gone.name, onShow: model.showJustRemoved, onDismiss: model.dismissBanner)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            if !model.visibleRemoved.isEmpty {
                Section("Recently Removed") {
                    ForEach(model.visibleRemoved) { gone in
                        RemovedAppRow(name: gone.name, removedAt: gone.removedAt)
                            .tag(UninstallItem.removed(gone).id)
                            .contextMenu {
                                Button("Forget This App", systemImage: "xmark") { Task { await model.dismiss(gone) } }
                            }
                    }
                }
            }
            if !model.visibleOrphans.isEmpty || model.isFindingOrphans {
                Section {
                    if model.isFindingOrphans && model.visibleOrphans.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Looking for leftovers…").foregroundStyle(.secondary) }
                            .selectionDisabled()
                    }
                    ForEach(model.visibleOrphans) { orphan in
                        OrphanRow(orphan: orphan)
                            .tag(UninstallItem.orphan(orphan).id)
                            .contextMenu {
                                Button("Show in Finder", systemImage: "folder") { FileActions.reveal(orphan.paths) }
                                Button("Ignore", systemImage: "eye.slash") { model.ignore(orphan) }
                            }
                    }
                } header: {
                    Text("Leftovers of Deleted Apps")
                        .help("Files named after apps that are no longer on this Mac. Review each one: nothing is ticked for you.")
                }
            }
            Section("Applications") {
                if model.isLoading && model.visibleApps.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Loading apps…").foregroundStyle(.secondary) }
                }
                ForEach(model.visibleApps) { app in
                    AppRow(
                        name: app.name,
                        path: app.path,
                        version: app.version,
                        size: model.sizes[app.path],
                        isLocked: !app.canUninstall
                    )
                    .tag(UninstallItem.app(app).id)
                    .contextMenu {
                        Button("Show in Finder", systemImage: "folder") { FileActions.reveal([app.path]) }
                        Button("Copy Bundle ID", systemImage: "doc.on.doc") { FileActions.copyPath(app.bundleID) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if !model.isLoading, model.visibleApps.isEmpty, model.visibleRemoved.isEmpty, model.visibleOrphans.isEmpty, !model.searchText.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }
}

private struct RemovedBanner: View {
    let name: String
    let onShow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(name) was removed", systemImage: "trash")
                .font(.headline)
            Text("It may have left files behind.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Clean Up Leftovers", action: onShow).buttonStyle(.glassProminent)
                Button("Dismiss", action: onDismiss)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.accentColor.opacity(0.12)), in: .rect(cornerRadius: 12))
    }
}

private struct AppRow: View {
    let name: String
    let path: String
    let version: String?
    let size: Int64?
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.appIcon(path))
                .resizable()
                .frame(width: 28, height: 28)
                .saturation(isLocked ? 0 : 1)
                .opacity(isLocked ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(version.map { "Version \($0)" } ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if isLocked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("System app. It can't be removed.")
            } else if let size {
                Text(size.fileSize)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct OrphanRow: View {
    let orphan: OrphanApp

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.app.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(orphan.bundleID).lineLimit(1).truncationMode(.middle)
                Text("\(orphan.paths.count) \(orphan.paths.count == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(orphan.bytes.fileSize)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

private struct RemovedAppRow: View {
    let name: String
    let removedAt: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text("Removed \(removedAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AppDetailPane: View {
    let item: UninstallItem
    let model: UninstallerModel
    let trash: TrashCoordinator
    let access: AccessModel

    @State private var expanded: Set<LeftoverKind> = []
    @State private var previewURL: URL?
    @State private var trashButton = FrameBox()

    var body: some View {
        List {
            AppHeader(item: item, size: item.appURL.flatMap { model.sizes[$0.path] }, isRunning: model.isRunning(item))
                .listRowSeparator(.hidden)

            if case .app(let app) = item, !app.canUninstall {
                Label(app.isSelf ? "macOS Clean can't remove itself. Drag it to the Trash in Finder."
                                 : "This app is part of macOS and can't be removed.",
                      systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            } else if let leftovers = model.leftovers[item.id] {
                if !leftovers.deniedPaths.isEmpty {
                    FullDiskAccessBanner(deniedPaths: leftovers.deniedPaths, access: access) {
                        Task { await model.rescanLeftovers(for: item) }
                    }
                    .listRowSeparator(.hidden)
                }
                if leftovers.groups.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No leftover files found", systemImage: "sparkles")
                        if case .removed(let gone) = item {
                            Button("Remove from List") { Task { await model.dismiss(gone) } }
                        }
                        if case .orphan(let orphan) = item {
                            Button("Remove from List") { model.ignore(orphan) }
                        }
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(leftovers.groups) { group in
                        groupSection(group)
                    }
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Looking for related files…").foregroundStyle(.secondary) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .safeAreaBar(edge: .bottom) { bottomBar }
        .task { await model.loadLeftovers(for: item) }
        .quickLookPreview($previewURL)
    }

    @ViewBuilder
    private func groupSection(_ group: LeftoverGroup) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(group.kind) },
            set: { if $0 { expanded.insert(group.kind) } else { expanded.remove(group.kind) } }
        )) {
            ForEach(group.entries) { entry in
                HStack(spacing: 8) {
                    TriStateCheckbox(state: model.isChecked(entry, in: item) ? .on : .off) {
                        model.toggle(entry, in: item)
                    }
                    FileIcon(path: entry.path, isDirectory: entry.isDirectory)
                    Text(entry.path.abbreviatingHome)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.path)
                    Spacer(minLength: 8)
                    Text(entry.sizeBytes.fileSize).foregroundStyle(.secondary).monospacedDigit()
                }
                .contextMenu {
                    FileContextMenu(path: entry.path, onQuickLook: { previewURL = $0 })
                }
            }
        } label: {
            HStack(spacing: 10) {
                TriStateCheckbox(state: model.state(of: group, in: item)) { model.toggle(group, in: item) }
                Image(systemName: group.kind.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.kind.title).font(.headline)
                    if group.kind.mayContainUserData {
                        Label("May contain your documents or settings. Review before removing.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if group.kind == .possible {
                        Label("Matched by a similar name only. These may belong to another app.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                Text("\(group.entries.count) \(group.entries.count == 1 ? "item" : "items") · \(group.totalBytes.fileSize)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        let entries = model.checkedEntries(for: item)
        if !entries.isEmpty {
            let bytes = entries.reduce(0) { $0 + $1.sizeBytes }
            let removesApp = model.removesApp(item)
            SelectionBar(
                title: "\(bytes.fileSize) selected",
                detail: "\(entries.count) \(entries.count == 1 ? "item" : "items") will move to the Trash"
            ) {
                Button(removesApp ? "Uninstall…" : "Remove Leftovers…", systemImage: "trash") {
                    if let request = model.uninstallRequest(for: item) { trash.request(request, from: trashButton.rect) }
                }
                .trashOrigin(trashButton)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(trash.isRunning)
            }
        }
    }
}

private struct AppHeader: View {
    let item: UninstallItem
    let size: Int64?
    let isRunning: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let url = item.appURL {
                    Image(nsImage: IconCache.appIcon(url.path)).resizable()
                } else if case .orphan = item {
                    Image(systemName: "questionmark.app.dashed").resizable().foregroundStyle(.secondary)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.title2.weight(.semibold))
                    if isRunning {
                        Text("Open")
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(.green)
                            .background(.green.opacity(0.15), in: .capsule)
                    }
                }
                switch item {
                case .app(let app):
                    Text([app.version.map { "Version \($0)" }, app.hasRealBundleID ? app.bundleID : nil, size?.fileSize]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    Text(app.path.abbreviatingHome)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                case .removed(let gone):
                    Text("\(gone.bundleID) · removed \(gone.removedAt, format: .relative(presentation: .named))")
                        .foregroundStyle(.secondary)
                    Text("The app is gone, but these files were left behind.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                case .orphan(let orphan):
                    Text("\(orphan.bytes.fileSize) · no app on this Mac uses this identifier")
                        .foregroundStyle(.secondary)
                    Text("Probably left by an app deleted earlier. Nothing is ticked: check each item before removing it.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 8)
    }
}
