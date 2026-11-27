import AppKit
import Observation

/// Hands requests that arrive outside the window (the Finder Services menu) to the window.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    /// An app bundle the user chose "Uninstall with macOS Clean" for, not yet shown.
    var pendingUninstallPath: String?

    /// Opens the main window again after it was closed. Set by the window when it appears; the
    /// action stays valid after the window is gone.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    func requestUninstall(of path: String) {
        pendingUninstallPath = path
        NSApp.activate()
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !hasWindow { openMainWindow?() }
    }

    /// Returns the pending path once and clears it.
    func takePendingUninstall() -> String? {
        defer { pendingUninstallPath = nil }
        return pendingUninstallPath
    }
}

/// Receives the "Uninstall with macOS Clean" service declared in `Info.plist` (`NSServices`).
@MainActor
final class ServiceProvider: NSObject {
    /// `NSMessage` = `uninstallApp`. Finder sends the selected `.app` bundles as file URLs.
    @objc func uninstallApp(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let app = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            error.pointee = "Select an app in Finder to uninstall it with macOS Clean." as NSString
            return
        }
        AppRouter.shared.requestUninstall(of: app.standardizedFileURL.path)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private let services = ServiceProvider()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.saved.apply()
        NSApp.servicesProvider = services
        // Picks up the Services entry after an install or update without logging out.
        NSUpdateDynamicServices()
    }
}
