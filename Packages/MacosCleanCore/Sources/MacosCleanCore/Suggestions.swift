import Foundation

/// A nudge toward space worth reviewing, e.g. "You haven't opened Xcode in 4 months — it and
/// its data use 40 GB". Built only from facts already measured; wording lives in the app.
public struct Suggestion: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// An app not opened for a long time that, with its data, uses a lot of space.
        case unusedApp
        /// Items in Downloads nobody touched for months.
        case oldDownloads
        /// Device backups older than a year.
        case oldBackups
        /// Simulator runtimes not used for months.
        case unusedSimulatorRuntimes
        /// Simulator devices whose runtime is gone.
        case unavailableSimulators
    }

    public enum Action: Sendable, Equatable {
        /// Open the app in the Uninstaller.
        case reviewApp(path: String)
        /// Tick these items in a Storage Manager category.
        case select(categoryID: String, paths: [String])
    }

    /// Stable across launches, so a dismissal sticks.
    public let id: String
    public let kind: Kind
    public let bytes: Int64
    /// Items involved (files, backups, runtimes); 1 for an app.
    public let count: Int
    /// Days since last use (apps, runtimes) or since the newest item was touched.
    public let idleDays: Int
    /// The app's name, for ``Kind/unusedApp``.
    public let appName: String?
    public let action: Action

    public init(id: String, kind: Kind, bytes: Int64, count: Int, idleDays: Int, appName: String? = nil, action: Action) {
        self.id = id
        self.kind = kind
        self.bytes = bytes
        self.count = count
        self.idleDays = idleDays
        self.appName = appName
        self.action = action
    }
}

public struct SuggestionInputs: Sendable {
    public struct AppUsage: Sendable {
        public let app: InstalledApp
        /// Bundle size; nil while it's still being measured.
        public let bundleBytes: Int64?
        /// From Spotlight (`kMDItemLastUsedDate`). Apps without one are never suggested: we
        /// don't claim "not opened" without evidence.
        public let lastUsed: Date?

        public init(app: InstalledApp, bundleBytes: Int64?, lastUsed: Date?) {
            self.app = app
            self.bundleBytes = bundleBytes
            self.lastUsed = lastUsed
        }
    }

    public var apps: [AppUsage]
    /// Storage Manager results, keyed by category id.
    public var results: [String: CategoryScanResult]
    /// Suggestion id → when it was dismissed.
    public var dismissed: [String: Date]

    public init(apps: [AppUsage] = [], results: [String: CategoryScanResult] = [:], dismissed: [String: Date] = [:]) {
        self.apps = apps
        self.results = results
        self.dismissed = dismissed
    }
}

public enum SuggestionEngine {
    public static let maxShown = 3
    /// A dismissed suggestion comes back after this long (if it still applies).
    public static let dismissalPeriod: TimeInterval = 30 * 86_400

    static let idleDays = 90
    static let backupAgeDays = 365
    static let minimumAppBytes: Int64 = 1_000_000_000
    static let minimumDownloadBytes: Int64 = 500_000_000
    static let minimumRuntimeBytes: Int64 = 1_000_000_000
    static let minimumUnavailableBytes: Int64 = 100_000_000
    static let minimumBackupBytes: Int64 = 1_000_000_000

    /// Storage Manager categories that hold an app's data, by bundle id. Their sizes count
    /// toward "it and its data use…".
    public static let relatedCategories: [String: [String]] = [
        "com.apple.dt.Xcode": [
            "xcode-derived", "xcode-archives", "xcode-device-support", "simulator-caches", "simulators", "xcode-previews",
        ],
        "com.docker.docker": ["docker-data"],
        "com.anthropic.claudefordesktop": ["claude-data"],
    ]

    public static func suggest(_ inputs: SuggestionInputs, now: Date = .now) -> [Suggestion] {
        var all: [Suggestion] = []
        all += unusedApps(inputs, now: now)
        if let downloads = oldDownloads(inputs.results["system-downloads"], now: now) { all.append(downloads) }
        if let backups = oldBackups(inputs.results["ios-backups"], now: now) { all.append(backups) }
        all += simulators(inputs.results["simulators"], now: now)
        let visible = all.filter { suggestion in
            guard let dismissedAt = inputs.dismissed[suggestion.id] else { return true }
            return now.timeIntervalSince(dismissedAt) >= dismissalPeriod
        }
        return Array(visible.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }.prefix(maxShown))
    }

    static func days(from date: Date, to now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    static func unusedApps(_ inputs: SuggestionInputs, now: Date) -> [Suggestion] {
        inputs.apps.compactMap { usage in
            let app = usage.app
            guard app.canUninstall, let bundleBytes = usage.bundleBytes, let lastUsed = usage.lastUsed else { return nil }
            let idle = days(from: lastUsed, to: now)
            guard idle >= idleDays else { return nil }
            let related = (relatedCategories[app.bundleID] ?? []).reduce(Int64(0)) { total, id in
                total + (inputs.results[id]?.totalBytes ?? 0)
            }
            let bytes = bundleBytes + related
            guard bytes >= minimumAppBytes else { return nil }
            return Suggestion(
                id: "unused-app:\(app.bundleID)", kind: .unusedApp, bytes: bytes, count: 1, idleDays: idle,
                appName: app.name, action: .reviewApp(path: app.path)
            )
        }
    }

    static func oldDownloads(_ result: CategoryScanResult?, now: Date) -> Suggestion? {
        guard let result else { return nil }
        let old = result.entries.filter { entry in
            guard let modified = entry.modified else { return false }
            return days(from: modified, to: now) >= idleDays
        }
        let bytes = old.totalBytes
        guard bytes >= minimumDownloadBytes, let newest = old.compactMap(\.modified).max() else { return nil }
        return Suggestion(
            id: "old-downloads", kind: .oldDownloads, bytes: bytes, count: old.count,
            idleDays: days(from: newest, to: now), action: .select(categoryID: result.categoryID, paths: old.map(\.path))
        )
    }

    static func oldBackups(_ result: CategoryScanResult?, now: Date) -> Suggestion? {
        guard let result else { return nil }
        let old = result.entries.filter { entry in
            guard let modified = entry.modified else { return false }
            return days(from: modified, to: now) >= backupAgeDays
        }
        let bytes = old.totalBytes
        guard bytes >= minimumBackupBytes, let newest = old.compactMap(\.modified).max() else { return nil }
        return Suggestion(
            id: "old-backups", kind: .oldBackups, bytes: bytes, count: old.count,
            idleDays: days(from: newest, to: now), action: .select(categoryID: result.categoryID, paths: old.map(\.path))
        )
    }

    static func simulators(_ result: CategoryScanResult?, now: Date) -> [Suggestion] {
        guard let result else { return [] }
        var suggestions: [Suggestion] = []
        let runtimes = result.simulators.filter { item in
            guard item.kind == .runtime, let used = item.lastUsed else { return false }
            return days(from: used, to: now) >= idleDays
        }
        let runtimeBytes = runtimes.reduce(Int64(0)) { $0 + $1.sizeBytes }
        if runtimeBytes >= minimumRuntimeBytes, let newest = runtimes.compactMap(\.lastUsed).max() {
            suggestions.append(Suggestion(
                id: "unused-runtimes", kind: .unusedSimulatorRuntimes, bytes: runtimeBytes, count: runtimes.count,
                idleDays: days(from: newest, to: now),
                action: .select(categoryID: result.categoryID, paths: runtimes.map(\.path))
            ))
        }
        let unavailable = result.simulators.filter { $0.kind == .device && !$0.isAvailable }
        let unavailableBytes = unavailable.reduce(Int64(0)) { $0 + $1.sizeBytes }
        if unavailableBytes >= minimumUnavailableBytes {
            suggestions.append(Suggestion(
                id: "unavailable-simulators", kind: .unavailableSimulators, bytes: unavailableBytes,
                count: unavailable.count, idleDays: 0,
                action: .select(categoryID: result.categoryID, paths: unavailable.map(\.path))
            ))
        }
        return suggestions
    }
}
