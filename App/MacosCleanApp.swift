import SwiftUI

@main
struct MacosCleanApp: App {
    var body: some Scene {
        WindowGroup("macos-clean", id: "main") {
            ContentView()
                .frame(minWidth: 760, minHeight: 540)
        }
        .defaultSize(width: 1000, height: 720)
    }
}
