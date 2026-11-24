import MacosCleanCore
import QuickLook
import SwiftUI

/// The Trash as its own section: what's in it, how big it is, and permanent deletion — of
/// everything or of picked items. Deliberately sober: red only where something is destroyed.
struct TrashView: View {
    @Bindable var bin: TrashBinModel
    let trash: TrashCoordinator
    let access: AccessModel

    @State private var tableSelection: Set<String> = []
    @State private var previewURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            TrashHeader(bin: bin, isBusy: trash.isRunning) { trash.requestEmptyTrash() }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Divider()
            content
        }
        .safeAreaBar(edge: .bottom) {
            if !bin.picks.isEmpty {
                SelectionBar(
                    title: "\(bin.pickedBytes.fileSize) selected",
                    detail: "\(bin.picks.count.formatted()) \(bin.picks.count == 1 ? "item" : "items") will be deleted permanently"
                ) {
                    Button("Deselect All") { bin.clearPicks() }
                    Button("Delete Permanently…", systemImage: "trash.slash") {
                        if let request = bin.eraseRequest() { trash.request(request) }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(trash.isRunning)
                }
                .motionTransition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motionAnimation(.snappy, value: bin.picks.isEmpty)
        .navigationTitle("Trash")
        .navigationSubtitle(subtitle)
        .searchable(text: $bin.searchText, placement: .toolbar, prompt: "Filter by name or kind")
        .toolbar { toolbar }
        .quickLookPreview($previewURL)
        .onAppear { bin.refresh() }
    }

    private var subtitle: String {
        if bin.isBlocked { return "No access" }
        guard bin.isMeasured else { return "Measuring…" }
        if bin.itemCount == 0 { return "Empty" }
        return "\(bin.itemCount.formatted()) \(bin.itemCount == 1 ? "item" : "items") · \(bin.bytes.fileSize)"
    }

    @ViewBuilder
    private var content: some View {
        if bin.isBlocked {
            ContentUnavailableView {
                Label("Can't see inside the Trash", systemImage: "lock.fill")
            } description: {
                Text("macOS only shows the Trash to apps with Full Disk Access. You can still empty it in Finder.")
            } actions: {
                Button("Allow Full Disk Access…") { access.isShowingWelcome = true }
                    .buttonStyle(.glassProminent)
                Button("Open Trash in Finder") { FileActions.openTrash() }
            }
            .frame(maxHeight: .infinity)
        } else if !bin.isMeasured {
            ProgressView("Measuring the Trash…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if bin.items.isEmpty {
            ContentUnavailableView {
                Label("The Trash is empty", systemImage: "trash")
                    .symbolEffect(.bounce, options: .nonRepeating, value: bin.emptied)
            } description: {
                Text("Items you move to the Trash from any section land here until you delete them for good.")
            }
            .frame(maxHeight: .infinity)
        } else if bin.visibleItems.isEmpty {
            ContentUnavailableView.search(text: bin.searchText)
                .frame(maxHeight: .infinity)
        } else {
            table
        }
    }

    private var table: some View {
        Table(bin.visibleItems, selection: $tableSelection, sortOrder: $bin.sortOrder) {
            TableColumn("") { item in
                Toggle("Select \(item.name)", isOn: Binding(
                    get: { bin.isPicked(item) },
                    set: { bin.setPicked(item, $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(bin.isEmptying)
            }
            .width(22)

            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    FileIcon(path: item.path, isDirectory: item.isDirectory, size: 16)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
                .help(item.name)
            }
            .width(min: 180, ideal: 300)

            TableColumn("Size", value: \.sizeBytes) { item in
                Text(item.sizeBytes.fileSize)
                    .monospacedDigit()
                    .foregroundStyle(bin.isPicked(item) ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
            .width(min: 70, ideal: 90)
            .alignment(.trailing)

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Date Trashed", value: \.dateTrashed) { item in
                Text(item.dateTrashed == .distantPast ? "—" : item.dateTrashed.formatted(.relative(presentation: .named)))
                    .foregroundStyle(.secondary)
                    .help(item.dateTrashed.formatted(date: .long, time: .shortened))
            }
            .width(min: 90, ideal: 130)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first { previewURL = URL(fileURLWithPath: id) }
        }
        .onKeyPress(.space) {
            guard let id = tableSelection.first else { return .ignored }
            previewURL = previewURL == nil ? URL(fileURLWithPath: id) : nil
            return .handled
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        if ids.count == 1, let id = ids.first {
            Button("Quick Look", systemImage: "eye") { previewURL = URL(fileURLWithPath: id) }
            Button("Show in Finder", systemImage: "folder") { FileActions.reveal([id]) }
            Button("Copy Path", systemImage: "doc.on.doc") { FileActions.copyPath(id) }
            Divider()
            Button("Delete Immediately…", systemImage: "trash.slash") {
                if let request = bin.eraseRequest(for: ids) { trash.request(request) }
            }
            .disabled(trash.isRunning)
        } else if !ids.isEmpty {
            Button("Show in Finder", systemImage: "folder") { FileActions.reveal(Array(ids)) }
            Button("Tick \(ids.count) Items", systemImage: "checkmark.square") { bin.pick(ids) }
            Divider()
            Button("Delete \(ids.count) Items Immediately…", systemImage: "trash.slash") {
                if let request = bin.eraseRequest(for: ids) { trash.request(request) }
            }
            .disabled(trash.isRunning)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu("Select", systemImage: "checklist") {
                Button("Select All") { bin.pickAllVisible() }
                Divider()
                Section("Trashed More Than") {
                    ForEach([7, 30, 90], id: \.self) { days in
                        Button("\(days) Days Ago") { bin.pick(ids { $0.dateTrashed != .distantPast && $0.dateTrashed < .now.addingTimeInterval(-Double(days) * 86_400) }) }
                    }
                }
                Section("Larger Than") {
                    Button("100 MB") { bin.pick(ids { $0.sizeBytes >= 100_000_000 }) }
                    Button("1 GB") { bin.pick(ids { $0.sizeBytes >= 1_000_000_000 }) }
                }
                Divider()
                Button("Deselect All") { bin.clearPicks() }
            }
            .disabled(bin.items.isEmpty || bin.isEmptying)

            Button("Open in Finder", systemImage: "folder") { FileActions.openTrash() }
                .help("Open the Trash in Finder, where Put Back restores items")
            Button("Refresh", systemImage: "arrow.clockwise") { bin.refresh() }
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func ids(where predicate: (TrashItem) -> Bool) -> Set<String> {
        Set(bin.visibleItems.lazy.filter(predicate).map(\.id))
    }
}

/// Size, count, a plain warning, and the one destructive button.
private struct TrashHeader: View {
    let bin: TrashBinModel
    let isBusy: Bool
    let onEmpty: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: bin.itemCount > 0 ? "trash.fill" : "trash")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(bin.isEmptying ? AnyShapeStyle(.white) : AnyShapeStyle(.red))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.wiggle, options: .repeat(.continuous), isActive: bin.isEmptying)
                    .frame(width: 58, height: 58)
                    .background(
                        bin.isEmptying ? AnyShapeStyle(.red) : AnyShapeStyle(.red.opacity(0.12)),
                        in: .rect(cornerRadius: 14)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if bin.isBlocked {
                            Text("Trash")
                        } else {
                            CountingBytes(bytes: Double(bin.bytes))
                        }
                    }
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text(caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 12)
                Button("Empty Trash…", systemImage: "trash.slash", action: onEmpty)
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(bin.itemCount == 0 || bin.isBlocked || isBusy)
                    .help("Delete everything in the Trash permanently (⇧⌘⌫)")
            }
            // No fixedSize here: in this VStack above a Table it sends layout into a loop that
            // leaves the window blank.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Deleting here is permanent and can't be undone. To get something back, use Put Back in Finder first.")
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 8))
        }
        .motionAnimation(.smooth, value: bin.isEmptying)
    }

    private var caption: String {
        if bin.isBlocked { return "macOS needs Full Disk Access to show the Trash" }
        if bin.isEmptying { return "Deleting…" }
        if bin.itemCount == 0 { return "Nothing in the Trash" }
        return "\(bin.itemCount.formatted()) \(bin.itemCount == 1 ? "item" : "items") in the Trash"
    }
}
