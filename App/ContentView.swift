import SwiftUI

private enum AppTab: Hashable {
    case storage, largeFiles, uninstaller
}

/// The three tabs of the reference app: Storage Manager (with Disk Map), Large Files, Uninstaller.
struct ContentView: View {
    @State private var selection: AppTab = .storage

    var body: some View {
        TabView(selection: $selection) {
            Tab("Storage Manager", systemImage: "internaldrive", value: .storage) {
                StorageManagerView()
            }
            Tab("Large Files", systemImage: "doc.text.magnifyingglass", value: .largeFiles) {
                ComingSoonView(title: "Large Files", systemImage: "doc.text.magnifyingglass")
            }
            Tab("Uninstaller", systemImage: "trash", value: .uninstaller) {
                ComingSoonView(title: "Uninstaller", systemImage: "trash")
            }
        }
    }
}

private struct ComingSoonView: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text("Coming soon")
        }
    }
}

#Preview {
    ContentView()
}
