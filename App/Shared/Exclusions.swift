import AppKit
import MacosCleanCore
import SwiftUI

/// The user's excluded folders: never scanned, never suggested for cleaning. Shared by the main
/// window and the Settings window; saved in `UserDefaults`.
@MainActor
@Observable
final class ExclusionStore {
    static let shared = ExclusionStore()

    /// `UserDefaults` key holding the folder paths (absolute, standardized).
    static let defaultsKey = "excludedFolders"

    /// Sorted for display.
    private(set) var paths: [String]
    private(set) var list: ExclusionList

    @ObservationIgnored private var observers: [@MainActor (ExclusionList) -> Void] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        let initial = ExclusionList(stored)
        list = initial
        paths = initial.paths.sorted()
    }

    /// Called with the new list after every change.
    func observe(_ handler: @escaping @MainActor (ExclusionList) -> Void) {
        observers.append(handler)
    }

    func contains(_ path: String) -> Bool {
        ExclusionList.normalize(path).map { list.paths.contains($0) } ?? false
    }

    func add(_ path: String) {
        guard let normalized = ExclusionList.normalize(path), !list.paths.contains(normalized) else { return }
        update(paths + [normalized])
    }

    func remove(_ path: String) {
        update(paths.filter { $0 != path })
    }

    /// Lets the user pick folders to exclude.
    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Exclude")
        panel.message = String(localized: "Choose folders macos-clean should never scan or suggest for cleaning.")
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { ExclusionList.normalize($0.path) }
        update(paths + added)
    }

    private func update(_ newPaths: [String]) {
        let newList = ExclusionList(newPaths)
        guard newList != list else { return }
        list = newList
        paths = newList.paths.sorted()
        defaults.set(paths, forKey: Self.defaultsKey)
        for observer in observers { observer(newList) }
    }
}

struct ExclusionSettingsSection: View {
    @State private var store = ExclusionStore.shared
    @State private var selection: String?

    var body: some View {
        Section {
            if store.paths.isEmpty {
                Text("No excluded folders")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.paths, id: \.self) { path in
                    HStack(spacing: 8) {
                        FileIcon(path: path, isDirectory: true)
                        Text(path.abbreviatingHome)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Remove", systemImage: "minus.circle") { store.remove(path) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Scan this folder again")
                    }
                    .contextMenu {
                        Button("Show in Finder", systemImage: "folder") { FileActions.reveal([path]) }
                        Button("Remove", systemImage: "minus.circle") { store.remove(path) }
                    }
                }
            }
            Button("Add Folder…", systemImage: "plus") { store.chooseFolders() }
        } header: {
            Text("Excluded Folders")
        } footer: {
            Text("These folders are never scanned and nothing in them is suggested for cleaning, in every section. A category or item that contains an excluded folder is hidden too, so cleaning it can't take the folder with it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
