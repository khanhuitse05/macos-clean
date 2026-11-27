import MacosCleanCore
import SwiftUI

enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case storage, largeFiles, duplicates, fileBrowser, uninstaller, trash

    var id: String { rawValue }

    /// The sections listed under "Clean Up"; the Trash sits apart at the bottom of the sidebar.
    static let cleanUp: [AppSection] = [.storage, .largeFiles, .duplicates, .fileBrowser, .uninstaller]

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
        case .storage: "internaldrive"
        case .largeFiles: "doc.text.magnifyingglass"
        case .duplicates: "doc.on.doc"
        case .fileBrowser: "rectangle.split.3x1"
        case .uninstaller: "xmark.app"
        case .trash: "trash"
        }
    }
}

/// Owns every feature model for the window, so switching sections keeps results.
@MainActor
@Observable
final class AppState {
    var section: AppSection? = AppState.initialSection
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
            largeFiles.isScanning
        case .duplicates:
            duplicates.isScanning
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
                        onReviewApp: { state.reviewApp(at: $0) }
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
            state.trash.bin.start()
            // Start watching Applications right away so removals are noticed in any section.
            state.uninstaller.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Full Disk Access may have been granted meanwhile.
            state.trash.bin.refresh()
            state.access.refresh()
        }
        .task {
            await state.access.showWelcomeIfNeeded()
        }
        .task {
            // Finder's "Uninstall with macOS Clean" may arrive before or after the window opens.
            router.openMainWindow = { [openWindow] in openWindow(id: "main") }
            if let path = router.takePendingUninstall() { await state.reviewAppFromFinder(at: path) }
        }
        .onChange(of: router.pendingUninstallPath) { _, path in
            guard path != nil, let path = router.takePendingUninstall() else { return }
            Task { await state.reviewAppFromFinder(at: path) }
        }
        .task {
            // Last run's results appear at once; a background rescan then refreshes them.
            await state.storage.restoreAndRefresh()
        }
    }
}

private struct Sidebar: View {
    @Bindable var state: AppState

    var body: some View {
        List(selection: $state.section) {
            Section("Clean Up") {
                ForEach(AppSection.cleanUp) { section in
                    let scanning = state.isScanning(section)
                    HStack(spacing: 6) {
                        Label(section.title, systemImage: section.systemImage)
                        Spacer(minLength: 4)
                        if scanning {
                            ProgressView()
                                .controlSize(.mini)
                                .transition(.opacity)
                                .accessibilityLabel("Scanning")
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: scanning)
                    .badge(scanning ? nil : badge(for: section))
                    .tag(section)
                }
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

    private func badge(for section: AppSection) -> Text? {
        // Removed apps with leftovers waiting to be cleaned up.
        guard section == .uninstaller, !state.uninstaller.removed.isEmpty else { return nil }
        return Text("\(state.uninstaller.removed.count)")
    }
}

#Preview {
    ContentView()
}
