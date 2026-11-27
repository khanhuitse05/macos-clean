import Foundation
import MacosCleanCore
import Observation

/// Asks GitHub for the latest release, only when the user clicks Check for Updates. Nothing is
/// downloaded or installed; a newer release is offered as a link to its page.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, page: URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: UpdateChecker.lastCheckedKey) as? Date

    private static let lastCheckedKey = "updateLastChecked"

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        state = await Self.fetchState(current: AppInfo.version)
        if case .failed = state { return }
        let now = Date()
        lastChecked = now
        UserDefaults.standard.set(now, forKey: Self.lastCheckedKey)
    }

    @concurrent
    private nonisolated static func fetchState(current: String) async -> State {
        var request = URLRequest(url: AppLinks.latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("macOS-Clean-update-check", forHTTPHeaderField: "User-Agent")
        // Ephemeral: no cookies or cache are kept from the request.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .failed("No release has been published yet.") }
            guard status == 200 else { return .failed("GitHub answered with status \(status). Try again later.") }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let latest = AppVersion(release.tagName) else {
                return .failed("The latest release (\(release.tagName)) has no version number.")
            }
            guard let installed = AppVersion(current) else { return .available(version: latest.description, page: release.htmlURL) }
            return latest > installed ? .available(version: latest.description, page: release.htmlURL) : .upToDate
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .failed("You're offline. Connect to the internet and try again.")
        } catch {
            return .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }
}
