import Foundation

/// Where an uninstall leftover lives. Order of cases = display order.
public enum LeftoverKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case binaries, logs, preferences, caches, supporting

    public var id: String { rawValue }

    public var title: LocalizedStringResource {
        switch self {
        case .binaries: LocalizedStringResource("Application", bundle: #bundle)
        case .logs: LocalizedStringResource("Logs", bundle: #bundle)
        case .preferences: LocalizedStringResource("Preferences", bundle: #bundle)
        case .caches: LocalizedStringResource("Caches", bundle: #bundle)
        case .supporting: LocalizedStringResource("Supporting Files", bundle: #bundle)
        }
    }

    public var systemImage: String {
        switch self {
        case .binaries: "app"
        case .logs: "doc.text"
        case .preferences: "gearshape"
        case .caches: "archivebox"
        case .supporting: "folder"
        }
    }

    /// Application Support / containers can hold the user's own documents, so they start unticked.
    public var mayContainUserData: Bool { self == .supporting }
}

public struct LeftoverGroup: Sendable, Equatable, Identifiable {
    public let kind: LeftoverKind
    public let entries: [FileEntry]
    public var id: LeftoverKind { kind }
    public var totalBytes: Int64 { entries.totalBytes }

    public init(kind: LeftoverKind, entries: [FileEntry]) {
        self.kind = kind
        self.entries = entries
    }
}

public struct AppLeftovers: Sendable, Equatable {
    public let bundleID: String
    public let groups: [LeftoverGroup]
    public let deniedPaths: [String]
    public var totalBytes: Int64 { groups.reduce(0) { $0 + $1.totalBytes } }

    public init(bundleID: String, groups: [LeftoverGroup], deniedPaths: [String]) {
        self.bundleID = bundleID
        self.groups = groups
        self.deniedPaths = deniedPaths
    }
    public var allEntries: [FileEntry] { groups.flatMap(\.entries) }
}

/// Finds leftover files an app leaves behind in Library folders.
public struct LeftoverScanner: Sendable {
    public let expander: PathExpander
    public let database: JunkDatabase
    /// `/Library` normally; injectable so tests never look at the real system folders.
    public let systemLibrary: String

    public init(expander: PathExpander = PathExpander(), database: JunkDatabase = .bundled, systemLibrary: String = "/Library") {
        self.expander = expander
        self.database = database
        self.systemLibrary = systemLibrary
    }

    /// - Parameter appURL: the `.app` bundle (listed under "Application"), or nil for an app that's already gone.
    @concurrent
    public func scan(bundleID: String, name: String, appURL: URL?) async -> AppLeftovers {
        let candidates = candidates(bundleID: bundleID, name: name, appURL: appURL)

        // Keep existing paths, drop exact duplicates, then drop anything inside an already-kept folder
        // (trashing the parent removes it anyway; listing both would double-count).
        var seen = Set<String>()
        var denied: [String] = []
        var existing: [(LeftoverKind, URL, Bool)] = []
        for (kind, url) in candidates {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if AccessCheck.isPermissionErrno(errno) { denied.append(url.path) }
                continue
            }
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            existing.append((kind, url.standardizedFileURL, info.st_mode & S_IFMT == S_IFDIR))
        }
        existing.sort { $0.1.pathComponents.count < $1.1.pathComponents.count }

        var accepted: [(LeftoverKind, URL, Bool)] = []
        for item in existing {
            let parts = item.1.pathComponents
            let covered = accepted.contains { kept in
                kept.2 && parts.count > kept.1.pathComponents.count
                    && Array(parts.prefix(kept.1.pathComponents.count)) == kept.1.pathComponents
            }
            if !covered { accepted.append(item) }
        }

        let sizes = await SizeCalculator.measureAll(accepted.map(\.1))
        var byKind: [LeftoverKind: [FileEntry]] = [:]
        for (item, size) in zip(accepted, sizes) {
            denied += size.deniedPaths
            if size.bytes == 0, !item.2 { continue }
            byKind[item.0, default: []].append(FileEntry(path: item.1.path, sizeBytes: size.bytes, isDirectory: item.2))
        }
        let groups = LeftoverKind.allCases.compactMap { kind in
            byKind[kind].map { LeftoverGroup(kind: kind, entries: $0.sortedBySizeDescending()) }
        }
        return AppLeftovers(bundleID: bundleID, groups: groups, deniedPaths: denied)
    }

    func candidates(bundleID: String, name: String, appURL: URL?) -> [(LeftoverKind, URL)] {
        let home = expander.home
        let library = (home as NSString).appendingPathComponent("Library")
        var result: [(LeftoverKind, URL)] = []

        func add(_ kind: LeftoverKind, _ base: String, _ relative: String) {
            result.append((kind, URL(fileURLWithPath: base).appendingPathComponent(relative)))
        }

        if let appURL, FileManager.default.fileExists(atPath: appURL.path) {
            result.append((.binaries, appURL))
        }

        // A name or id used as a path component must be one plain component, or "~/Library/Logs/"
        // + "" would point at the whole Logs folder.
        let id = Self.isSafeComponent(bundleID) && !bundleID.hasPrefix(AppCatalog.missingBundleIDPrefix) ? bundleID : nil
        let appName = Self.isSafeComponent(name) ? name : nil

        if let id {
            add(.preferences, library, "Preferences/\(id).plist")
            add(.preferences, library, "Preferences/\(id).plist.lockfile")
            add(.preferences, library, "Preferences/ByHost/\(id).plist")
            add(.preferences, systemLibrary, "Preferences/\(id).plist")
            add(.logs, library, "Logs/\(id)")
            add(.caches, library, "Caches/\(id)")
            add(.caches, library, "Caches/com.apple.helpd/Generated/\(id)")
            add(.caches, systemLibrary, "Caches/\(id)")
            add(.caches, library, "HTTPStorages/\(id)")
            add(.caches, library, "HTTPStorages/\(id).binarycookies")
            add(.caches, library, "Cookies/\(id).binarycookies")
            add(.caches, library, "WebKit/\(id)")
            add(.caches, library, "Saved Application State/\(id).savedState")
            add(.supporting, library, "Application Support/\(id)")
            add(.supporting, systemLibrary, "Application Support/\(id)")
            add(.supporting, library, "Containers/\(id)")
            add(.supporting, library, "Group Containers/group.\(id)")
            add(.supporting, library, "LaunchAgents/\(id).plist")
            add(.supporting, systemLibrary, "LaunchAgents/\(id).plist")
            add(.supporting, systemLibrary, "LaunchDaemons/\(id).plist")
        }
        if let appName {
            add(.logs, library, "Logs/\(appName)")
            add(.logs, systemLibrary, "Logs/\(appName)")
            add(.logs, library, "Logs/DiagnosticReports/\(appName).diag")
            add(.caches, library, "Caches/\(appName)")
            add(.supporting, library, "Application Support/\(appName)")
            add(.supporting, systemLibrary, "Application Support/\(appName)")
        }

        result += database.extraLeftovers(bundleID: bundleID, name: name, expander: expander)
        return result
    }

    static func isSafeComponent(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !value.contains("/") && !value.contains("\0")
    }
}
