import MacosCleanCore
import QuickLook
import SwiftUI

struct LargeFilesView: View {
    @Bindable var model: LargeFilesModel
    let trash: TrashCoordinator
    let access: AccessModel

    @State private var tableSelection: Set<String> = []
    @State private var previewURL: URL?
    @State private var isChoosingFolder = false
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
                SelectionBar(
                    title: "\(model.checkedBytes.fileSize) selected",
                    detail: "\(model.checked.count.formatted()) \(model.checked.count == 1 ? "file" : "files") will move to the Trash"
                ) {
                    Button("Deselect All") { model.uncheckAll() }
                    Button("Move to Trash…", systemImage: "trash") {
                        if let request = model.trashRequest() { trash.request(request, from: trashButton.rect) }
                    }
                    .trashOrigin(trashButton)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(trash.isRunning)
                }
            }
        }
        .navigationTitle("Large Files")
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
        .task {
            // Scan on first visit; the model outlives the view, so returning keeps earlier results.
            if !model.hasScanned { model.scan() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasScanned {
            ContentUnavailableView {
                Label("Find large files", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Look for files bigger than \(model.minimumMB.formatted()) MB in your \(model.rootDisplayName) folder. Caches, app bundles, Photos libraries and .git folders are skipped.")
            } actions: {
                Button("Scan \(model.rootDisplayName)") { model.scan() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        } else if model.visibleRows.isEmpty, !model.isScanning {
            if model.searchText.isEmpty {
                ContentUnavailableView(
                    "No large files",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing bigger than \(model.minimumMB.formatted()) MB in \(model.rootDisplayName). Try a smaller size.")
                )
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(model.visibleRows, selection: $tableSelection, sortOrder: $model.sortOrder) {
            TableColumn("") { row in
                Toggle("Select \(row.name)", isOn: Binding(
                    get: { model.isChecked(row) },
                    set: { model.setChecked(row, $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
            .width(22)

            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    FileIcon(path: row.id, isDirectory: false, size: 16)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                }
                .help(row.id)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Size", value: \.sizeBytes) { row in
                Text(row.sizeBytes.fileSize).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            .alignment(.trailing)

            TableColumn("Kind", value: \.kind) { row in
                Text(row.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Modified", value: \.modified) { row in
                Text(row.modified, format: .dateTime.year().month(.abbreviated).day())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110)

            TableColumn("Location", value: \.location) { row in
                Text(row.location).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .width(min: 120, ideal: 260)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first {
                FileContextMenu(path: id, onQuickLook: { previewURL = $0 }) {
                    if let request = model.trashRequest(for: ids) { trash.request(request) }
                }
            } else if !ids.isEmpty {
                Button("Show in Finder", systemImage: "folder") { FileActions.reveal(Array(ids)) }
                Button("Tick \(ids.count) Files", systemImage: "checkmark.square") {
                    for row in model.visibleRows where ids.contains(row.id) { model.setChecked(row, true) }
                }
                Divider()
                Button("Move \(ids.count) Files to Trash…", systemImage: "trash") {
                    if let request = model.trashRequest(for: ids) { trash.request(request) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { previewURL = URL(fileURLWithPath: id) }
        }
        .onKeyPress(.space) {
            guard let id = tableSelection.first else { return .ignored }
            previewURL = previewURL == nil ? URL(fileURLWithPath: id) : nil
            return .handled
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Home Folder") {
                    model.root = URL(fileURLWithPath: NSHomeDirectory())
                    model.scan()
                }
                Button("Choose Folder…") { isChoosingFolder = true }
            } label: {
                Label(model.rootDisplayName, systemImage: "folder")
            }
            .help("Folder to search")

            Picker("Minimum size", selection: $model.minimumMB) {
                ForEach(LargeFilesModel.thresholds, id: \.self) { mb in
                    Text(mb >= 1_000 ? "\(mb / 1_000) GB" : "\(mb) MB").tag(mb)
                }
            }
            .pickerStyle(.menu)
            .help("Only show files at least this big")

            if model.isScanning {
                Button("Stop", systemImage: "stop.fill") { model.stop() }
            } else {
                Button(model.hasScanned ? "Scan Again" : "Scan", systemImage: "arrow.clockwise") { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private var subtitle: String {
        if model.isScanning {
            return "Scanning… \(model.scannedCount.formatted()) files checked, \(model.visibleRows.count.formatted()) found"
        }
        guard model.hasScanned else { return "Not scanned yet" }
        return "\(model.visibleRows.count.formatted()) files · \(model.totalBytes.fileSize)"
    }
}
