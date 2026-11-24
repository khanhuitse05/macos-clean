import SwiftUI

@main
struct MacosCleanApp: App {
    var body: some Scene {
        Window("macos-clean", id: "main") {
            ContentView()
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 740)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
