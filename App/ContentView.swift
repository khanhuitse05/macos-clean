import MacosCleanCore
import SwiftUI

enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case storage, largeFiles, duplicates, fileBrowser, uninstaller, trash

    var id: String { rawValue }

    /// The sections listed under "Clean Up"; the Trash sits apart at the bottom of the sidebar.
    static let cleanUp: [AppSection] = [.storage, .fileBrowser, .largeFiles, .duplicates, .uninstaller]

    var title: LocalizedStringKey {
        switch self {
        case .storage: "Storage Manager"
        case .largeFiles: "Large Files"
        case .duplicates: "Duplicates"
        case .fileBrowser: "File Browser"
        case .uninstaller: "Uninstaller"
        case .trash: "Trash"
        }
    }

    var systemImage: String {
        switch self {
        case .storage: "internaldrive.fill"
        case .largeFiles: "scalemass.fill"
        case .duplicates: "doc.on.doc.fill"
        case .fileBrowser: "folder.fill"
        case .uninstaller: "square.grid.2x2.fill"
        case .trash: "trash.fill"
        }
    }
}

/// A selectable sidebar row: a section, or one of Storage Manager's groups.
enum SidebarItem: Hashable {
    case section(AppSection)
    case storageGroup(CleanupCategory.Group)
}

/// Owns every feature model for the window, so switching sections keeps results.
@MainActor
@Observable
final class AppState {
    var section: AppSection? = AppState.initialSection {
        didSet { if section != .storage { storageGroup = nil } }
    }
    /// The Storage Manager group picked in the sidebar; nil shows every group.
    var storageGroup: CleanupCategory.Group?

    /// The sidebar's selection: a group row means Storage Manager narrowed to that group.
    var sidebarSelection: SidebarItem? {
        get {
            guard let section else { return nil }
            if section == .storage, let storageGroup { return .storageGroup(storageGroup) }
            return .section(section)
        }
        set {
            switch newValue {
            case .storageGroup(let group):
                section = .storage
                storageGroup = group
            case .section(let picked):
                section = picked
                storageGroup = nil
            case nil:
                break
            }
        }
    }
    let storage = StorageModel()
    let largeFiles = LargeFilesModel()
    let duplicates = DuplicatesModel()
    let fileBrowser = FileBrowserModel()
    let uninstaller = UninstallerModel()
    let trash = TrashCoordinator()
    let access = AccessModel()
    let suggestions = SuggestionsModel()

    /// Shows an installed app (by bundle path) in the Uninstaller.
    func reviewApp(at path: String) {
        guard let app = uninstaller.apps.first(where: { $0.path == path }) else { return }
        uninstaller.searchText = ""
        uninstaller.selectedID = UninstallItem.app(app).id
        section = .uninstaller
    }

    /// "Uninstall with macOS Clean" from Finder: opens the app in the Uninstaller, re-listing
    /// apps first if it was just installed or the list hasn't loaded yet.
    func reviewAppFromFinder(at path: String) async {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        func find() -> InstalledApp? {
            uninstaller.apps.first { $0.path == path || URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolved }
        }
        section = .uninstaller
        if find() == nil { await uninstaller.refresh() }
        guard let app = find() else {
            let name = (path as NSString).lastPathComponent
            uninstaller.errorMessage = "macOS Clean lists apps in /Applications and ~/Applications. Move \(name) there to uninstall it here, or drag it to the Trash."
            return
        }
        reviewApp(at: app.path)
    }

    /// True while a section is scanning or measuring, so its sidebar row can show a spinner.
    func isScanning(_ section: AppSection) -> Bool {
        switch section {
        case .storage:
            storage.isScanningAll || !storage.refreshing.isEmpty
                || storage.categories.contains { storage.phase(of: $0) == .scanning }
        case .largeFiles:
            largeFiles.isScanning || largeFiles.isRefreshing
        case .duplicates:
            duplicates.isScanning || duplicates.isRefreshing
        case .fileBrowser:
            // Only once browsing started; an untouched File Browser isn't measuring anything.
            fileBrowser.state(of: fileBrowser.root.path).map { !$0.isMeasured && !$0.isDenied } ?? false
        case .uninstaller:
            uninstaller.isLoading || !uninstaller.loadingLeftovers.isEmpty
        case .trash:
            !trash.bin.isMeasured && !trash.bin.isBlocked
        }
    }

    init() {
        // Excluded folders disappear from every section at once.
        ExclusionStore.shared.observe { [storage, largeFiles, duplicates, uninstaller] list in
            storage.setExclusions(list)
            largeFiles.setExclusions(list)
            duplicates.setExclusions(list)
            uninstaller.setExclusions(list)
        }
    }

    /// Debug builds accept `-StartSection <name>` (e.g. `trash`) to open on a section, for screenshots.
    private static var initialSection: AppSection {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "StartSection"), let section = AppSection(rawValue: raw) {
            return section
        }
        #endif
        return .storage
    }
}

struct ContentView: View {
    @State private var state = AppState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private let router = AppRouter.shared

    var body: some View {
        @Bindable var access = state.access
        NavigationSplitView {
            Sidebar(state: state)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            Group {
                switch state.section ?? .storage {
                case .storage:
                    StorageManagerView(
                        model: state.storage, trash: state.trash, access: state.access,
                        suggestions: state.suggestions, uninstaller: state.uninstaller,
                        onReviewApp: { state.reviewApp(at: $0) },
                        group: state.storageGroup
                    )
                case .largeFiles:
                    LargeFilesView(model: state.largeFiles, trash: state.trash, access: state.access)
                case .duplicates:
                    DuplicatesView(model: state.duplicates, trash: state.trash, access: state.access)
                case .fileBrowser:
                    FileBrowserView(model: state.fileBrowser, trash: state.trash, access: state.access)
                case .uninstaller:
                    UninstallerView(model: state.uninstaller, trash: state.trash, access: state.access)
                case .trash:
                    TrashView(bin: state.trash.bin, trash: state.trash, access: state.access)
                }
            }
            // Bubbl floats over every section, in a corner the user can change by dragging.
            .overlay { MascotOverlay(state: state) }
        }
        .trashFlow(state.trash)
        // Bounce, wiggle and rotate effects everywhere are motion; drop them all at once.
        .symbolEffectsRemoved(reduceMotion)
        .sheet(isPresented: $access.isShowingWelcome) {
            FullDiskAccessWelcome(access: state.access) {
                state.trash.bin.refresh()
                Task { await state.storage.scanAll() }
            }
        }
        .task {
            // Ask for Full Disk Access before touching the disk: without it, the first scan
            // sets off macOS's per-folder prompts (Downloads, Desktop…) over the request.
            await state.access.showWelcomeIfNeeded()
            state.trash.bin.start()
            // Start watching Applications right away so removals are noticed in any section.
            state.uninstaller.start()
            // Last run's results appear at once; a background rescan then refreshes them.
            await state.storage.restoreAndRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Full Disk Access may have been granted meanwhile.
            state.trash.bin.refresh()
            state.access.refresh()
        }
        #if DEBUG
        .task {
            // `-OpenSettings YES` (with `-settingsTab about` etc.) opens Settings at launch, for screenshots.
            if UserDefaults.standard.bool(forKey: "OpenSettings") { openSettings() }
        }
        #endif
        .task {
            // Finder's "Uninstall with macOS Clean" may arrive before or after the window opens.
            router.openMainWindow = { [openWindow] in openWindow(id: "main") }
            if let path = router.takePendingUninstall() { await state.reviewAppFromFinder(at: path) }
        }
        .onChange(of: router.pendingUninstallPath) { _, path in
            guard path != nil, let path = router.takePendingUninstall() else { return }
            Task { await state.reviewAppFromFinder(at: path) }
        }
    }
}

private struct Sidebar: View {
    @Bindable var state: AppState

    var body: some View {
        List(selection: $state.sidebarSelection) {
            Section("Clean Up") {
                ForEach(AppSection.cleanUp) { section in
                    SidebarRow(
                        title: Text(section.title), systemImage: section.systemImage,
                        isScanning: state.isScanning(section), trailing: trailing(for: section)
                    )
                    .tag(SidebarItem.section(section))
                    if section == .storage {
                        // Storage Manager's groups, largest first; developer groups only when
                        // something of theirs is on this Mac.
                        ForEach(state.storage.sidebarGroups) { group in
                            groupRow(group)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let volume = state.storage.volume {
                SidebarDiskBar(
                    volume: volume,
                    foundBytes: state.storage.hasAnyResult ? state.storage.foundBytes : 0,
                    trashBytes: state.trash.bin.isMeasured ? state.trash.bin.bytes : 0
                ) {
                    state.sidebarSelection = .section(.storage)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 6)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if !state.access.hasFullDiskAccess {
                    fullDiskAccessButton.padding(.horizontal, 8)
                }
                Divider().padding(.horizontal, 6)
                TrashSidebarItem(
                    coordinator: state.trash,
                    isSelected: state.section == .trash,
                    onSelect: { state.section = .trash }
                )
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    private func groupRow(_ group: CleanupCategory.Group) -> some View {
        let storage = state.storage
        return SidebarRow(
            title: Text(group.title), systemImage: GroupStyle.symbol(for: group), iconSize: 16,
            isScanning: storage.isScanning(group),
            trailing: storage.hasResult(in: group) ? .bytes(storage.foundBytes(in: group)) : nil
        )
        .padding(.leading, 14)
        .tag(SidebarItem.storageGroup(group))
        .contextMenu {
            Button("Clean Safe Items…", systemImage: "sparkles") {
                if let request = storage.safeItemsRequest(in: group) { state.trash.request(request) }
            }
            .disabled(!storage.hasSafeItems(in: group) || state.trash.isRunning)
            Button("Rescan Group", systemImage: "arrow.clockwise") {
                state.sidebarSelection = .storageGroup(group)
                Task { await storage.scanAll(in: group) }
            }
            .disabled(storage.isScanningAll)
        }
    }

    /// What a section's row shows on the right once it has results.
    private func trailing(for section: AppSection) -> SidebarRow.Trailing? {
        switch section {
        case .storage:
            state.storage.hasAnyResult ? .bytes(state.storage.foundBytes) : nil
        case .largeFiles:
            state.largeFiles.hasScanned ? .bytes(state.largeFiles.totalBytes) : nil
        case .duplicates:
            state.duplicates.hasScanned ? .bytes(state.duplicates.wastedBytes) : nil
        case .uninstaller:
            // Removed apps with leftovers waiting to be cleaned up.
            state.uninstaller.removed.isEmpty ? nil : .count(state.uninstaller.removed.count)
        case .fileBrowser, .trash:
            nil
        }
    }

    private var fullDiskAccessButton: some View {
        Button {
            state.access.isShowingWelcome = true
        } label: {
            Label("Full Disk Access is off", systemImage: "lock.trianglebadge.exclamationmark")
                .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 10)))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
        .help("Some folders can't be scanned. Click to learn how to allow access.")
    }
}

/// One sidebar row: icon tile, title, and a spinner while scanning or what it found.
private struct SidebarRow: View {
    enum Trailing: Equatable {
        case bytes(Int64)
        case count(Int)
    }

    let title: Text
    let systemImage: String
    var iconSize: CGFloat = 20
    let isScanning: Bool
    let trailing: Trailing?

    var body: some View {
        HStack(spacing: 6) {
            Label {
                title.lineLimit(1)
            } icon: {
                SidebarIcon(systemImage: systemImage, size: iconSize)
            }
            Spacer(minLength: 4)
            if isScanning {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.opacity)
                    .accessibilityLabel("Scanning")
            } else if let trailing {
                Group {
                    switch trailing {
                    case .bytes(let bytes):
                        // Counts up and down as results arrive and items leave for the Trash.
                        CountingBytes(bytes: Double(bytes))
                            .motionAnimation(.smooth(duration: 0.6), value: bytes)
                    case .count(let count):
                        Text(count.formatted()).monospacedDigit()
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isScanning)
    }
}

/// The home disk in one thin bar above the sidebar: used space, junk found, what's in the
/// Trash, and free space. Clicking it opens Storage Manager.
private struct SidebarDiskBar: View {
    let volume: VolumeUsage
    let foundBytes: Int64
    let trashBytes: Int64
    let onOpen: () -> Void

    var body: some View {
        let total = Double(max(1, volume.total))
        let used = Double(volume.used)
        let found = min(Double(foundBytes), used)
        let inTrash = min(Double(trashBytes), used - found)
        let other = used - found - inTrash
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    HStack(spacing: 0) {
                        Rectangle().fill(.gray.opacity(0.45)).frame(width: width * other / total)
                        Rectangle().fill(Color.purple.opacity(0.45)).frame(width: width * inTrash / total)
                        Rectangle().fill(.orange.opacity(0.6)).frame(width: width * found / total)
                        Spacer(minLength: 0)
                    }
                    .background(.quaternary)
                    .clipShape(.capsule)
                }
                .frame(height: 6)
                HStack(spacing: 4) {
                    CountingBytes(bytes: Double(volume.available))
                    Text("free")
                    Spacer(minLength: 4)
                    if found > 0 {
                        CountingBytes(bytes: found).foregroundStyle(.orange)
                        Text("cleanable")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .motionAnimation(.smooth(duration: 0.6), value: volume)
        .motionAnimation(.smooth(duration: 0.6), value: foundBytes)
        .motionAnimation(.smooth(duration: 0.6), value: trashBytes)
        .help("\(volume.available.fileSize) free of \(volume.total.fileSize). Click to open Storage Manager.")
        .accessibilityLabel("\(volume.available.fileSize) free of \(volume.total.fileSize)")
    }
}

enum GroupStyle {
    static func symbol(for group: CleanupCategory.Group) -> String {
        switch group {
        case .systemApps: "macwindow"
        case .xcode: "hammer.fill"
        case .developer: "shippingbox.fill"
        case .aiContainers: "cpu.fill"
        case .personal: "person.crop.square.fill"
        }
    }
}

#Preview {
    ContentView()
}
