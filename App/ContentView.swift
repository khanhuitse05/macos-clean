import MacosCleanCore
import SwiftUI

enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case storage, largeFiles, fileBrowser, uninstaller

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .storage: "Storage Manager"
        case .largeFiles: "Large Files"
        case .fileBrowser: "File Browser"
        case .uninstaller: "Uninstaller"
        }
    }

    var systemImage: String {
        switch self {
        case .storage: "internaldrive"
        case .largeFiles: "doc.text.magnifyingglass"
        case .fileBrowser: "rectangle.split.3x1"
        case .uninstaller: "xmark.app"
        }
    }
}

/// Owns every feature model for the window, so switching sections keeps results.
@MainActor
@Observable
final class AppState {
    var section: AppSection? = .storage
    let storage = StorageModel()
    let largeFiles = LargeFilesModel()
    let fileBrowser = FileBrowserModel()
    let uninstaller = UninstallerModel()
    let trash = TrashCoordinator()
    let access = AccessModel()

    /// Opens Storage Manager with the Trash category expanded.
    func revealTrash() {
        section = .storage
        storage.reveal(categoryID: "trash")
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
                    StorageManagerView(model: state.storage, trash: state.trash, access: state.access)
                case .largeFiles:
                    LargeFilesView(model: state.largeFiles, trash: state.trash, access: state.access)
                case .fileBrowser:
                    FileBrowserView(model: state.fileBrowser, trash: state.trash, access: state.access)
                case .uninstaller:
                    UninstallerView(model: state.uninstaller, trash: state.trash, access: state.access)
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
            state.trash.onErased = { [storage = state.storage] summary in storage.noteErased(summary) }
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
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .badge(badge(for: section))
                        .tag(section)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                TrashBinView(
                    coordinator: state.trash,
                    onReveal: { state.revealTrash() },
                    onBlockedTap: { state.access.isShowingWelcome = true }
                )
                if !state.access.hasFullDiskAccess { fullDiskAccessButton }
            }
            .padding(12)
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
