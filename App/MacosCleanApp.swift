import SwiftUI

@main
struct MacosCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(MonitorSettings.showKey) private var showMonitor = false

    var body: some Scene {
        Window("macOS Clean", id: "main") {
            ContentView()
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 740)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            MascotCommands()
            HelpCommands()
        }

        MenuBarExtra(isInserted: $showMonitor) {
            MenuBarMonitorPanel()
        } label: {
            MenuBarMonitorLabel()
        }
        .menuBarExtraStyle(.window)
        .onChange(of: showMonitor, initial: true) { _, shown in
            SystemMonitorModel.shared.setMenuBarShown(shown)
        }

        Settings {
            SettingsView()
        }
    }
}
