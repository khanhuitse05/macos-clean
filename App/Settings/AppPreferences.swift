import AppKit
import SwiftUI

/// Light, dark, or whatever System Settings uses.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    /// `UserDefaults` key holding the raw value.
    static let key = "appearance"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var saved: AppAppearance {
        UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// Applies to every window, the Settings window and the menu bar monitor at once.
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }
}

/// Where the project lives, for the About tab and the Help menu.
enum AppLinks {
    static let repository = URL(string: "https://github.com/khanhuitse05/macos-clean")!
    static let releases = URL(string: "https://github.com/khanhuitse05/macos-clean/releases")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/khanhuitse05/macos-clean/releases/latest")!

    /// A new issue with the app and macOS versions filled in. Nothing else about the Mac is included.
    static var newIssue: URL {
        var components = URLComponents(string: "https://github.com/khanhuitse05/macos-clean/issues/new")!
        let body = """
        **What happened?**


        **What did you expect?**


        **Steps to reproduce**
        1.

        ---
        macOS Clean \(AppInfo.versionAndBuild) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url ?? repository
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var versionAndBuild: String { "\(version) (\(build))" }
}

/// Help menu: the project page and a prefilled issue.
struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Link("macOS Clean on GitHub", destination: AppLinks.repository)
            Link("Report an Issue…", destination: AppLinks.newIssue)
            Divider()
            Link("Release Notes", destination: AppLinks.releases)
        }
    }
}
