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
            FullDiskAccessWelcome(access: state.access)
        }
        .task {
            state.trash.bin.start()
            state.access.showWelcomeIfNeeded()
            // Start watching Applications right away so removals are noticed in any section.
            state.uninstaller.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Full Disk Access may have been granted meanwhile.
            state.trash.bin.refresh()
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
                    Label(section.title, systemImage: section.systemImage)
                        .badge(badge(for: section))
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
