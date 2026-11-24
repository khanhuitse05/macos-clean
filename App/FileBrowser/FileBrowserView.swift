import MacosCleanCore
import QuickLook
import SwiftUI

/// Finder-style column view where every item shows how much disk space it uses.
struct FileBrowserView: View {
    @Bindable var model: FileBrowserModel
    let trash: TrashCoordinator
    let access: AccessModel

    @State private var previewURL: URL?
    @State private var isChoosingFolder = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedColumn: Int?

    var body: some View {
        VStack(spacing: 0) {
            if !model.deniedPaths.isEmpty {
                FullDiskAccessBanner(deniedPaths: model.deniedPaths.sorted(), access: access) { model.reload() }
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 8)
            }
            columns
        }
        .safeAreaBar(edge: .bottom) { pathBar }
        .navigationTitle("File Browser")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.root = url }
        }
        .quickLookPreview($previewURL)
        .task { model.start() }
    }

    private var subtitle: String {
        let place = model.root.path.abbreviatingHome
        guard let bytes = model.rootBytes else { return place }
        return "\(place) · \(bytes.fileSize)"
    }

    private var columns: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(model.columns.enumerated()), id: \.element) { index, folder in
                        BrowserColumn(
                            index: index,
                            folder: folder,
                            model: model,
                            focus: $focusedColumn,
                            onQuickLook: { previewURL = $0 },
                            onTrash: { trash.request(model.trashRequest(for: $0), from: $1) }
                        )
                        .frame(width: 280)
                        .id(folder)
                        Divider()
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: model.columns) { _, columns in
                guard let last = columns.last else { return }
                withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(last, anchor: .trailing) }
            }
        }
    }

    private var pathBar: some View {
        let entry = model.selectedEntry
        return SelectionBar(
            title: entry?.name ?? model.rootDisplayName,
            detail: sizeDetail(entry)
        ) {
            Button("Show in Finder", systemImage: "folder") {
                FileActions.reveal([entry?.path ?? model.root.path])
            }
            if let entry {
                Button("Move to Trash…", systemImage: "trash") {
                    trash.request(model.trashRequest(for: entry))
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(trash.isRunning)
            }
        }
    }

    private func sizeDetail(_ entry: FileEntry?) -> String {
        guard let entry else {
            return model.rootBytes.map { "\($0.fileSize) · \(model.root.path.abbreviatingHome)" } ?? "Calculating sizes…"
        }
        let size = model.isMeasuring(entry) ? "Calculating…" : entry.sizeBytes.fileSize
        return "\(size) · \(entry.parentPath.abbreviatingHome)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.isHome {
                Button("Home", systemImage: "house") { model.root = URL(fileURLWithPath: NSHomeDirectory()) }
                    .help("Browse your Home folder")
            }
            Button("Choose Folder…", systemImage: "folder.badge.gearshape") { isChoosingFolder = true }
                .help("Browse another folder or drive")
            Toggle("Show Hidden Files", systemImage: "eye", isOn: $model.showHidden)
                .help("Show files and folders whose names start with a dot")
            Button("Reload", systemImage: "arrow.clockwise") { model.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .help("Measure the open folders again (⌘R)")
        }
    }
}

private struct BrowserColumn: View {
    let index: Int
    let folder: String
    let model: FileBrowserModel
    var focus: FocusState<Int?>.Binding
    let onQuickLook: (URL) -> Void
    let onTrash: (FileEntry, CGRect?) -> Void

    var body: some View {
        if let state = model.state(of: folder) {
            if state.isDenied {
                ContentUnavailableView {
                    Label("Can't open this folder", systemImage: "lock.fill")
                } description: {
                    Text("macOS blocked access. Grant Full Disk Access to see what's inside.")
                }
            } else if model.entries(in: folder).isEmpty {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            } else {
                list
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var list: some View {
        List(selection: selection) {
            ForEach(model.entries(in: folder)) { entry in
                TrashOriginReader { origin in
                    BrowserRow(entry: entry, isMeasuring: model.isMeasuring(entry))
                        .contextMenu {
                            FileContextMenu(path: entry.path, onQuickLook: onQuickLook, onTrash: { onTrash(entry, origin.rect) })
                        }
                }
                .tag(entry.path)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .focused(focus, equals: index)
        .onKeyPress(.rightArrow) {
            guard model.enterColumn(after: index) else { return .ignored }
            focus.wrappedValue = index + 1
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard index > 0 else { return .ignored }
            model.leaveColumn(index)
            focus.wrappedValue = index - 1
            return .handled
        }
        .onKeyPress(.space) {
            guard let path = model.selection(inColumn: index) else { return .ignored }
            onQuickLook(URL(fileURLWithPath: path))
            return .handled
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selection(inColumn: index) },
            set: { model.select($0, inColumn: index) }
        )
    }
}

private struct BrowserRow: View {
    let entry: FileEntry
    let isMeasuring: Bool

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(path: entry.path, isDirectory: entry.isDirectory, size: 20)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.name)
            Spacer(minLength: 8)
            if isMeasuring {
                ProgressView().controlSize(.mini)
            } else {
                Text(entry.sizeBytes.fileSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(entry.isDirectory ? 1 : 0)
        }
        .contentShape(.rect)
    }
}
