import MacosCleanCore
import QuickLook
import SwiftUI

struct DuplicatesView: View {
    @Bindable var model: DuplicatesModel
    let trash: TrashCoordinator
    let access: AccessModel

    @State private var previewURL: URL?
    @State private var isChoosingFolder = false
    @State private var showsManaged = false
    @State private var trashButton = FrameBox()

    var body: some View {
        VStack(spacing: 0) {
            if !model.deniedPaths.isEmpty {
                FullDiskAccessBanner(deniedPaths: model.deniedPaths, access: access) { model.scan() }
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 8)
            }
            content
        }
        .safeAreaBar(edge: .bottom) {
            if !model.checked.isEmpty {
                SelectionBar(title: "\(model.checkedBytes.fileSize) selected", detail: selectionDetail) {
                    Button("Deselect All") { model.uncheckAll() }
                    Button("Move to Trash…", systemImage: "trash") {
                        if let request = model.trashRequest() { trash.request(request, from: trashButton.rect) }
                    }
                    .trashOrigin(trashButton)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(trash.isRunning || !model.canTrash)
                    .help(model.canTrash ? "Move the ticked copies to the Trash" : "Keep at least one copy of every file")
                }
                .motionTransition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motionAnimation(.snappy, value: model.checked.isEmpty)
        .navigationTitle("Duplicates")
        .navigationSubtitle(subtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter by name or folder")
        .toolbar { toolbar }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.root = url
                model.scan()
            }
        }
        .quickLookPreview($previewURL)
    }

    private var emptyDescription: String {
        let scope = model.isHomeScope ? "your Home folder and iCloud Drive" : "your \(model.rootDisplayName) folder"
        let library = model.isHomeScope ? " App data in Library is skipped too: choose it from the folder menu to search it." : ""
        return "Look for identical files of \(model.minimumMB.formatted()) MB or more in \(scope). Files are compared by size, then by their first and last bytes, then byte for byte. Caches, app bundles, Photos libraries, folders that developer tools generate (like .dart_tool, .gradle, .idea or a project’s build folder) and excluded folders are skipped.\(library)"
    }

    private var selectionDetail: String {
        if !model.fullyCheckedGroups.isEmpty {
            let count = model.fullyCheckedGroups.count
            return "Every copy is ticked in \(count) \(count == 1 ? "group" : "groups"). Keep at least one."
        }
        return "\(model.checked.count.formatted()) \(model.checked.count == 1 ? "copy" : "copies") will move to the Trash"
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasScanned {
            ContentUnavailableView {
                Label("Find duplicate files", systemImage: "doc.on.doc")
            } description: {
                Text(emptyDescription)
            } actions: {
                Button("Scan \(model.rootDisplayName)") { model.scan() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        } else if model.isScanning, model.groups.isEmpty {
            ScanStageView(stage: model.stage, done: model.stageDone, total: model.stageTotal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleGroups.isEmpty {
            if model.searchText.isEmpty {
                ContentUnavailableView(
                    "No duplicates",
                    systemImage: "checkmark.circle",
                    description: Text("No identical files of \(model.minimumMB.formatted()) MB or more in \(model.rootDisplayName).")
                )
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(model.userGroups) { group in
                groupSection(group)
            }
            if !model.managedGroups.isEmpty {
                Section {
                    EmptyView()
                } header: {
                    ManagedGroupsHeader(groups: model.managedGroups, isExpanded: $showsManaged)
                }
                if showsManaged || model.userGroups.isEmpty {
                    ForEach(model.managedGroups) { group in
                        groupSection(group)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func groupSection(_ group: DuplicateGroup) -> some View {
        Section {
            ForEach(group.files) { file in
                DuplicateRow(file: file, model: model, trash: trash, onQuickLook: { previewURL = $0 })
            }
        } header: {
            DuplicateGroupHeader(group: group, model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Home and iCloud Drive") {
                    model.root = DuplicatesModel.homeURL
                    model.scan()
                }
                Button("App Data (Library)") {
                    model.root = DuplicatesModel.libraryURL
                    model.scan()
                }
                .help("Copies apps keep for themselves. Removing them can break an app, or the app makes them again.")
                Divider()
                Button("Choose Folder…") { isChoosingFolder = true }
            } label: {
                Label(model.rootDisplayName, systemImage: "folder")
            }
            .help("Folder to search")

            Picker("Minimum size", selection: $model.minimumMB) {
                ForEach(DuplicatesModel.thresholds, id: \.self) { mb in
                    Text("\(mb) MB").tag(mb)
                }
            }
            .pickerStyle(.menu)
            .help("Only compare files at least this big")

            Menu("Select", systemImage: "checklist") {
                ForEach(DuplicatesModel.KeepRule.allCases) { rule in
                    Button(rule.title) { model.selectDuplicates(keeping: rule) }
                }
                Divider()
                Button("Deselect All") { model.uncheckAll() }
            }
            .disabled(model.userGroups.isEmpty)
            .help("Tick every extra copy of your files, keeping one of each. Copies apps manage are left alone.")

            if model.isScanning {
                Button("Stop", systemImage: "stop.fill") { model.stop() }
            } else {
                Button(model.hasScanned ? "Scan Again" : "Scan", systemImage: "arrow.clockwise") { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private var subtitle: String {
        if model.isScanning { return ScanStageView.describe(model.stage, done: model.stageDone, total: model.stageTotal) }
        guard model.hasScanned else { return "Not scanned yet" }
        return "\(model.groups.count.formatted()) \(model.groups.count == 1 ? "file" : "files") with copies · \(model.wastedBytes.fileSize) in extra copies"
    }
}

private struct ScanStageView: View {
    let stage: DuplicateEvent.Stage
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 12) {
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .frame(width: 260)
            } else {
                ProgressView()
            }
            Text(Self.describe(stage, done: done, total: total))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    static func describe(_ stage: DuplicateEvent.Stage, done: Int, total: Int) -> String {
        switch stage {
        case .walking: "Looking through files… \(done.formatted()) checked"
        case .comparingStarts: "Comparing file starts… \(done.formatted()) of \(total.formatted())"
        case .comparingContents: "Comparing contents… \(done.formatted()) of \(total.formatted())"
        }
    }
}

private struct DuplicateGroupHeader: View {
    let group: DuplicateGroup
    let model: DuplicatesModel

    var body: some View {
        HStack(spacing: 8) {
            TriStateCheckbox(state: model.state(of: group)) { model.toggle(group) }
                .help("Tick every copy except the newest")
            FileIcon(path: group.files.first?.path ?? "", isDirectory: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                    .help(group.name)
                Text("\(group.files.count) copies · \(group.fileBytes.fileSize) each")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.fullyCheckedGroups.contains(group.id) {
                Label("Keep one copy", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("\(group.wastedBytes.fileSize) extra")
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .textCase(nil)
    }
}

private struct DuplicateRow: View {
    let file: FileEntry
    let model: DuplicatesModel
    let trash: TrashCoordinator
    let onQuickLook: (URL) -> Void

    @State private var origin = FrameBox()

    var body: some View {
        HStack(spacing: 8) {
            TriStateCheckbox(state: model.isChecked(file) ? .on : .off) { model.toggle(file) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    LocationBadge(location: FileLocation.of(file.path))
                    Text(file.parentPath.abbreviatingHome)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(file.path)
                }
                if let modified = file.modified {
                    Text("Modified \(modified.formatted(.dateTime.year().month(.abbreviated).day().hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(file.sizeBytes.fileSize)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 22)
        .contentShape(.rect)
        .trashOrigin(origin)
        .onTapGesture(count: 2) { onQuickLook(file.url) }
        .contextMenu {
            FileContextMenu(path: file.path, onQuickLook: onQuickLook) {
                if let request = model.trashRequest(for: [file.path]) { trash.request(request, from: origin.rect) }
            }
        }
    }
}

/// The collapsible header above groups that only apps own.
private struct ManagedGroupsHeader: View {
    let groups: [DuplicateGroup]
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            Motion.animate { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                Image(systemName: "shippingbox")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Managed by Apps").font(.headline)
                    Text("\(groups.count) \(groups.count == 1 ? "file" : "files") that apps keep for themselves. Removing a copy can break an app, or the app makes it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("\(groups.reduce(0) { $0 + $1.wastedBytes }.fileSize) extra")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .textCase(nil)
    }
}

/// Where a copy lives, as a small label in front of its folder.
private struct LocationBadge: View {
    let location: FileLocation

    var body: some View {
        if let title = location.title {
            Label(title, systemImage: location.symbol)
                .font(.caption2.weight(.medium))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(location == .appData ? Color.orange : Color.secondary)
                .background(.quaternary.opacity(0.6), in: .capsule)
                .fixedSize()
        }
    }
}

private extension FileLocation {
    /// Nil where the folder path already says it all.
    var title: LocalizedStringKey? {
        switch self {
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .downloads: "Downloads"
        case .pictures: "Pictures"
        case .movies: "Movies"
        case .music: "Music"
        case .iCloudDrive: "iCloud Drive"
        case .externalDrive: "External Drive"
        case .appData: "App Data"
        case .home, .other: nil
        }
    }

    var symbol: String {
        switch self {
        case .desktop: "menubar.dock.rectangle"
        case .documents: "doc"
        case .downloads: "arrow.down.circle"
        case .pictures: "photo"
        case .movies: "film"
        case .music: "music.note"
        case .iCloudDrive: "icloud"
        case .externalDrive: "externaldrive"
        case .appData: "shippingbox"
        case .home, .other: "folder"
        }
    }
}
