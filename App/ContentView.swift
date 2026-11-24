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
            switch state.section ?? .storage {
            case .storage:
                StorageManagerView(
                    model: state.storage, trash: state.trash, access: state.access,
                    leftoverAppCount: state.uninstaller.removed.count,
                    onShowLeftovers: { state.section = .uninstaller }
                )
            case .largeFiles:
                LargeFilesView(model: state.largeFiles, trash: state.trash, access: state.access)
            case .fileBrowser:
                FileBrowserView(model: state.fileBrowser, trash: state.trash, access: state.access)
            case .uninstaller:
                UninstallerView(model: state.uninstaller, trash: state.trash, access: state.access)
            }
        }
        .trashFlow(state.trash)
        // Bounce, wiggle and rotate effects everywhere are motion; drop them all at once.
        .symbolEffectsRemoved(reduceMotion)
        .sheet(isPresented: $access.isShowingWelcome) {
            FullDiskAccessWelcome(access: state.access)
        }
        .task {
            state.access.showWelcomeIfNeeded()
            // Start watching Applications right away so removals are noticed in any section.
            state.uninstaller.start()
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
            if !state.access.hasFullDiskAccess {
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
                .padding(12)
                .help("Some folders can't be scanned. Click to learn how to allow access.")
            }
        }
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
