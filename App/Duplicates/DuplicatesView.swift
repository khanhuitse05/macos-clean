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
        // Saved groups appear at once on the first visit and are checked again in the background.
        .task {
            await access.showWelcomeIfNeeded()
            await model.appear()
        }
    }

    private var emptyDescription: String {
        let size = "\(model.minimumMB.formatted()) MB"
        return model.isHomeScope
            ? "Find identical files of \(size) or more in your Home folder and iCloud Drive. App data, caches and developer folders are left out."
            : "Find identical files of \(size) or more in \(model.rootDisplayName). Caches and developer folders are left out."
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
            ScanStageView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
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
        VStack(spacing: 0) {
            if model.isScanning {
                LiveScanHeader(model: model)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .motionTransition(.move(edge: .top).combined(with: .opacity))
            }
            groupList
        }
        .motionAnimation(.snappy, value: model.isScanning)
    }

    private var groupList: some View {
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
        let summary = "\(model.groups.count.formatted()) \(model.groups.count == 1 ? "file" : "files") with copies · \(model.wastedBytes.fileSize) in extra copies"
        if model.isRefreshing { return "\(summary) · Updating…" }
        return summary
    }
}

// MARK: - Scanning

/// The search before anything is found: a radar sweeping the disk, a live count and the
/// folder being walked.
private struct ScanStageView: View {
    let model: DuplicatesModel

    var body: some View {
        VStack(spacing: 28) {
            ScanRadar(groups: model.groups, size: 196)

            VStack(spacing: 8) {
                Text("Searching \(model.isHomeScope ? "Home and iCloud Drive" : model.rootDisplayName)")
                    .font(.title2.weight(.semibold))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ScanStageView.headline(model.stage, done: model.stageDone, total: model.stageTotal))
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(ScanStageView.unit(model.stage))
                        .foregroundStyle(.secondary)
                }
                .motionAnimation(.snappy, value: model.stageDone)
                FolderTicker(path: model.stage == .walking ? model.currentFolder : "")
            }
        }
        .padding(24)
    }

    static func headline(_ stage: DuplicateEvent.Stage, done: Int, total: Int) -> String {
        stage == .walking || total == 0 ? done.formatted() : "\(done.formatted()) of \(total.formatted())"
    }

    static func unit(_ stage: DuplicateEvent.Stage) -> LocalizedStringResource {
        switch stage {
        case .walking: "files checked"
        case .comparingStarts: "look-alikes compared"
        case .comparingContents: "files compared"
        }
    }

    static func title(_ stage: DuplicateEvent.Stage) -> LocalizedStringResource {
        switch stage {
        case .walking: "Find large files"
        case .comparingStarts: "Compare first and last bytes"
        case .comparingContents: "Compare byte for byte"
        }
    }

    static func count(_ stage: DuplicateEvent.Stage, done: Int, total: Int) -> String {
        switch stage {
        case .walking: "\(done.formatted()) checked"
        case .comparingStarts, .comparingContents: "\(done.formatted()) of \(total.formatted())"
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

/// Above the list while groups stream in: a small radar, the step, a progress bar and what
/// has been found so far.
private struct LiveScanHeader: View {
    let model: DuplicatesModel

    var body: some View {
        HStack(spacing: 14) {
            ScanRadar(groups: model.groups, size: 46, showsIcon: false)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(ScanStageView.title(model.stage))
                        .font(.headline)
                    Text(ScanStageView.count(model.stage, done: model.stageDone, total: model.stageTotal))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                if model.stageTotal > 0 {
                    ProgressView(value: Double(min(model.stageDone, model.stageTotal)), total: Double(model.stageTotal))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                CountingBytes(bytes: Double(model.wastedBytes))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text("in \(model.groups.count.formatted()) \(model.groups.count == 1 ? "file" : "files") so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Button("Stop", systemImage: "stop.fill") { model.stop() }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .help("Stop searching. Copies found so far stay listed.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .motionAnimation(.snappy, value: model.stageDone)
        .motionAnimation(.snappy, value: model.groups.count)
    }
}

/// A radar sweeping round, rings pulsing outward, and a blip for each group found.
private struct ScanRadar: View {
    let groups: [DuplicateGroup]
    var size: CGFloat
    var showsIcon = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds per sweep.
    private static let period = 2.6

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let sweep = reduceMotion ? 0 : (time / Self.period).truncatingRemainder(dividingBy: 1) * 360
            ZStack {
                // Guide rings.
                ForEach([1.0, 0.66, 0.33], id: \.self) { scale in
                    Circle()
                        .strokeBorder(.tint.opacity(0.18), lineWidth: 1)
                        .frame(width: size * scale, height: size * scale)
                }
                // Pulses travelling outward.
                if !reduceMotion {
                    ForEach(0..<3, id: \.self) { index in
                        let phase = ((time / 2.4) + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(.tint.opacity(0.45 * (1 - phase)), lineWidth: 1.5)
                            .frame(width: size, height: size)
                            .scaleEffect(0.2 + 0.8 * phase)
                    }
                }
                // The sweep: a fading wedge trailing the beam.
                Circle()
                    .fill(AngularGradient(
                        stops: [
                            .init(color: .accentColor.opacity(0), location: 0.70),
                            .init(color: .accentColor.opacity(0.42), location: 0.995),
                            .init(color: .accentColor.opacity(0), location: 1),
                        ],
                        center: .center
                    ))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(sweep - 90))
                // Blips: one per group found, lit as the beam passes.
                ForEach(groups.prefix(14)) { group in
                    let spot = Self.spot(for: group.id)
                    let behind = (sweep - spot.angle + 360).truncatingRemainder(dividingBy: 360)
                    let glow = reduceMotion ? 1 : max(0.35, 1 - behind / 240)
                    Circle()
                        .fill(group.isAppManaged ? Color.secondary : Color.accentColor)
                        .frame(width: max(4, size * 0.045), height: max(4, size * 0.045))
                        .shadow(color: .accentColor.opacity(glow), radius: size * 0.03)
                        .opacity(glow)
                        .offset(
                            x: cos(spot.angle * .pi / 180) * spot.radius * size / 2,
                            y: sin(spot.angle * .pi / 180) * spot.radius * size / 2
                        )
                        .transition(.scale(scale: 3).combined(with: .opacity))
                }
                if showsIcon {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: size * 0.17, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: size * 0.34, height: size * 0.34)
                        .glassEffect(.regular, in: .circle)
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }

    /// A stable place on the radar for a group: angle in degrees, radius as a fraction.
    private static func spot(for id: String) -> (angle: Double, radius: Double) {
        let bytes = Array(id.utf8)
        let a = bytes.prefix(8).reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let angle = Double(a % 360)
        let radius = 0.42 + Double((a >> 16) % 48) / 100
        return (angle, radius)
    }
}

/// The folder being walked, sliding up as it changes.
private struct FolderTicker: View {
    let path: String

    var body: some View {
        ZStack {
            Text(Self.display(path))
                .font(.callout.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .id(path)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
        }
        .frame(maxWidth: 460)
        .frame(height: 18)
        .clipped()
        .motionAnimation(.smooth(duration: 0.3), value: path)
    }

    static func display(_ path: String) -> String {
        guard !path.isEmpty else { return " " }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
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
