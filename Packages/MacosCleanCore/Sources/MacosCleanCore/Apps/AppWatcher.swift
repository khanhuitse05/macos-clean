import Darwin
import Dispatch
import Foundation

/// An app that disappeared from an Applications folder (for example dragged to the Trash in
/// Finder). Kept for 30 days so its leftovers can still be cleaned up.
public struct RemovedApp: Identifiable, Hashable, Sendable, Codable {
    public let bundleID: String
    public let name: String
    public let path: String
    public let removedAt: Date

    public init(bundleID: String, name: String, path: String, removedAt: Date) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.removedAt = removedAt
    }

    public var id: String { bundleID }
}

public struct AppsSnapshot: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var apps: [InstalledApp]
    /// Newest first.
    public var removed: [RemovedApp]

    public static let empty = AppsSnapshot(timestamp: .distantPast, apps: [], removed: [])

    public init(timestamp: Date, apps: [InstalledApp], removed: [RemovedApp]) {
        self.timestamp = timestamp
        self.apps = apps
        self.removed = removed
    }
}

/// Watches the Applications folders, records removed apps, and persists the list between launches.
/// Port of `start_uninstall_watcher` / apps cache in the reference `apps.rs`.
public actor AppWatcher {
    public static let tombstoneLifetime: TimeInterval = 30 * 24 * 60 * 60

    private let catalog: AppCatalog
    private let cacheURL: URL?
    private let pollInterval: Duration
    private let now: @Sendable () -> Date
    private var snapshot: AppsSnapshot
    private var hasListed = false
    /// Paths this app removed itself; their disappearance shouldn't create a "removed app" entry.
    private var handledPaths = Set<String>()

    public init(
        catalog: AppCatalog = .standard(),
        cacheURL: URL? = AppWatcher.defaultCacheURL,
        pollInterval: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.catalog = catalog
        self.cacheURL = cacheURL
        self.pollInterval = pollInterval
        self.now = now
        self.snapshot = Self.readCache(at: cacheURL) ?? .empty
    }

    public static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.goldenowl.macos-clean", isDirectory: true)
            .appendingPathComponent("apps_cache.json")
    }

    /// The last persisted snapshot (instant, may be stale).
    public func cached() -> AppsSnapshot { snapshot }

    /// Re-lists apps, records removals, prunes old entries, and saves.
    @discardableResult
    public func refresh() -> AppsSnapshot {
        let current = catalog.listApps()
        let date = now()
        // With no cached list there's nothing to diff against yet.
        let previous = (hasListed || snapshot.timestamp != .distantPast) ? snapshot.apps : current
        snapshot = AppsSnapshot(
            timestamp: date,
            apps: current,
            removed: Self.updatedRemovals(
                previous: previous, current: current, removed: snapshot.removed,
                ignoring: handledPaths, now: date
            )
        )
        handledPaths.removeAll()
        hasListed = true
        save()
        return snapshot
    }

    /// Call before trashing an app from inside macos-clean, so it isn't reported as "removed".
    public func markHandled(path: String) {
        handledPaths.insert(path)
    }

    /// Forget a removed-app entry (leftovers cleaned or dismissed).
    @discardableResult
    public func dismiss(bundleID: String) -> AppsSnapshot {
        snapshot.removed.removeAll { $0.bundleID == bundleID }
        save()
        return snapshot
    }

    /// Emits a fresh snapshot now, then whenever an Applications folder changes (debounced) or
    /// every `pollInterval`. Cancel the consuming task to stop.
    public nonisolated func updates() -> AsyncStream<AppsSnapshot> {
        AsyncStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ output: AsyncStream<AppsSnapshot>.Continuation) async {
        let (triggers, trigger) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let sources = catalog.watchedFolders.compactMap { Self.makeSource(for: $0, trigger: trigger) }
        let interval = pollInterval
        let timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                trigger.yield()
            }
        }
        defer {
            timer.cancel()
            sources.forEach { $0.cancel() }
            output.finish()
        }

        output.yield(refresh())
        for await _ in triggers {
            // Let a copy or move finish before re-listing.
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            output.yield(refresh())
        }
    }

    private static func makeSource(
        for folder: URL, trigger: AsyncStream<Void>.Continuation
    ) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .global(qos: .utility)
        )
        source.setEventHandler { trigger.yield() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// Pure diff: new tombstones for apps that vanished, minus reinstalled and expired ones.
    static func updatedRemovals(
        previous: [InstalledApp], current: [InstalledApp], removed: [RemovedApp],
        ignoring: Set<String>, now: Date
    ) -> [RemovedApp] {
        let currentPaths = Set(current.map(\.path))
        let currentIDs = Set(current.map(\.bundleID))
        var result = removed.filter {
            !currentIDs.contains($0.bundleID) && now.timeIntervalSince($0.removedAt) <= tombstoneLifetime
        }
        let known = Set(result.map(\.bundleID))
        for app in previous
        where app.canUninstall && !currentPaths.contains(app.path) && !currentIDs.contains(app.bundleID)
            && !known.contains(app.bundleID) && !ignoring.contains(app.path) {
            result.append(RemovedApp(bundleID: app.bundleID, name: app.name, path: app.path, removedAt: now))
        }
        return result.sorted { $0.removedAt > $1.removedAt }
    }

    private static func readCache(at url: URL?) -> AppsSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppsSnapshot.self, from: data)
    }

    private func save() {
        guard let cacheURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
