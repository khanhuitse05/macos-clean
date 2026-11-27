import Foundation

/// Where an uninstall leftover lives. Order of cases = display order.
public enum LeftoverKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case binaries, logs, preferences, caches, supporting
    /// Found by name only (Deep matching). Might belong to something else.
    case possible

    public var id: String { rawValue }

    public var title: LocalizedStringResource {
        switch self {
        case .binaries: LocalizedStringResource("Application", bundle: #bundle)
        case .logs: LocalizedStringResource("Logs", bundle: #bundle)
        case .preferences: LocalizedStringResource("Preferences", bundle: #bundle)
        case .caches: LocalizedStringResource("Caches", bundle: #bundle)
        case .supporting: LocalizedStringResource("Supporting Files", bundle: #bundle)
        case .possible: LocalizedStringResource("Possible Matches", bundle: #bundle)
        }
    }

    public var systemImage: String {
        switch self {
        case .binaries: "app"
        case .logs: "doc.text"
        case .preferences: "gearshape"
        case .caches: "archivebox"
        case .supporting: "folder"
        case .possible: "questionmark.folder"
        }
    }

    /// Application Support / containers can hold the user's own documents, so they start unticked.
    public var mayContainUserData: Bool { self == .supporting }

    /// Groups the user must tick by hand: possible user data, and name-only matches.
    public var startsUnchecked: Bool { self == .supporting || self == .possible }
}

/// How widely the Uninstaller looks for an app's files.
public enum MatchSensitivity: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Exact bundle identifier and app name only.
    case strict
    /// Also the app's helpers, extensions and app groups, and files named `<bundle id>.<something>`.
    case enhanced
    /// Also folders whose name resembles the app or its developer. Shown as Possible Matches.
    case deep

    public var id: String { rawValue }

    public var title: LocalizedStringResource {
        switch self {
        case .strict: LocalizedStringResource("Strict", bundle: #bundle)
        case .enhanced: LocalizedStringResource("Enhanced", bundle: #bundle)
        case .deep: LocalizedStringResource("Deep", bundle: #bundle)
        }
    }

    public var details: LocalizedStringResource {
        switch self {
        case .strict:
            LocalizedStringResource("Only files named exactly after the app or its bundle identifier.", bundle: #bundle)
        case .enhanced:
            LocalizedStringResource("Also the app's helpers, extensions and shared app groups.", bundle: #bundle)
        case .deep:
            LocalizedStringResource("Also folders with a similar name. These may belong to something else and are never ticked for you.", bundle: #bundle)
        }
    }
}

/// What other installed apps own, so a scan never offers their files.
public struct InstalledAppIndex: Sendable, Equatable {
    /// Lowercased bundle identifiers.
    let bundleIDs: Set<String>
    /// Every dot-prefix of those identifiers ("com", "com.example"), so a vendor folder that
    /// another app still lives under isn't claimed.
    let namespaces: Set<String>
    /// ``LeftoverScanner/normalized(_:)`` app names.
    let names: Set<String>
    /// Second component of each identifier ("example" in "com.example.app").
    let vendors: Set<String>

    public static let empty = InstalledAppIndex(apps: [])

    /// - Parameter excluding: the app being scanned; its own identifier doesn't count.
    public init(apps: [InstalledApp], excluding bundleID: String? = nil) {
        let skip = bundleID?.lowercased()
        var ids = Set<String>()
        var namespaces = Set<String>()
        var names = Set<String>()
        var vendors = Set<String>()
        for app in apps where app.bundleID.lowercased() != skip {
            let name = LeftoverScanner.normalized(app.name)
            if !name.isEmpty { names.insert(name) }
            guard app.hasRealBundleID else { continue }
            let id = app.bundleID.lowercased()
            ids.insert(id)
            let parts = id.split(separator: ".")
            for count in 1..<max(parts.count, 1) { namespaces.insert(parts.prefix(count).joined(separator: ".")) }
            if parts.count >= 3 { vendors.insert(String(parts[1])) }
        }
        self.bundleIDs = ids
        self.namespaces = namespaces
        self.names = names
        self.vendors = vendors
    }

    /// True when `identifier` is another app's bundle identifier, sits inside one
    /// ("<their id>.helper"), or is a namespace one lives under ("com.example").
    public func claims(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        if bundleIDs.contains(id) || namespaces.contains(id) { return true }
        var prefix = Substring(id)
        while let dot = prefix.lastIndex(of: ".") {
            prefix = prefix[..<dot]
            if bundleIDs.contains(String(prefix)) { return true }
        }
        return false
    }

    /// True when another installed app comes from the same developer ("com.example.*").
    public func sharesVendor(with identifier: String) -> Bool {
        let parts = identifier.lowercased().split(separator: ".")
        return parts.count >= 3 && vendors.contains(String(parts[1]))
    }

    func claimsName(_ normalizedName: String) -> Bool { names.contains(normalizedName) }
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

    /// - Parameters:
    ///   - appURL: the `.app` bundle (listed under "Application"), or nil for an app that's already gone.
    ///   - sensitivity: how widely to look. Enhanced and Deep never offer files another installed app owns.
    ///   - others: the other installed apps.
    @concurrent
    public func scan(
        bundleID: String, name: String, appURL: URL?,
        sensitivity: MatchSensitivity = .strict, others: InstalledAppIndex = .empty
    ) async -> AppLeftovers {
        await measured(candidates(bundleID: bundleID, name: name, appURL: appURL, sensitivity: sensitivity, others: others), bundleID: bundleID)
    }

    /// Groups and measures paths found elsewhere (for example by ``OrphanFinder``).
    @concurrent
    public func leftovers(at paths: [String], bundleID: String) async -> AppLeftovers {
        let library = (expander.home as NSString).appendingPathComponent("Library")
        let candidates = paths.map { path -> (LeftoverKind, URL) in
            let parent = ((path as NSString).deletingLastPathComponent as NSString)
            let folder = parent.deletingLastPathComponent == library ? parent.lastPathComponent : ""
            return (Self.libraryFolders[folder] ?? .supporting, URL(fileURLWithPath: path))
        }
        return await measured(candidates, bundleID: bundleID)
    }

    private func measured(_ candidates: [(LeftoverKind, URL)], bundleID: String) async -> AppLeftovers {

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

    /// `~/Library` folders whose direct children are looked at by name, with what each holds.
    static let libraryFolders: [String: LeftoverKind] = [
        "Preferences": .preferences,
        "Caches": .caches,
        "HTTPStorages": .caches,
        "WebKit": .caches,
        "Cookies": .caches,
        "Saved Application State": .caches,
        "Logs": .logs,
        "Application Support": .supporting,
        "Containers": .supporting,
        "Group Containers": .supporting,
        "Application Scripts": .supporting,
        "LaunchAgents": .supporting,
    ]

    /// Developer names too broad to match a folder on (Deep matching).
    static let genericVendors: Set<String> = [
        "app", "apps", "mac", "macos", "osx", "inc", "llc", "ltd", "company", "software", "studio",
        "github", "google", "microsoft", "apple", "adobe", "electron", "developer", "example", "test",
    ]

    func candidates(
        bundleID: String, name: String, appURL: URL?,
        sensitivity: MatchSensitivity = .strict, others: InstalledAppIndex = .empty
    ) -> [(LeftoverKind, URL)] {
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

        func addExact(_ id: String) {
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
            add(.supporting, library, "Application Scripts/\(id)")
        }
        if let id { addExact(id) }
        if let appName {
            add(.logs, library, "Logs/\(appName)")
            add(.logs, systemLibrary, "Logs/\(appName)")
            add(.logs, library, "Logs/DiagnosticReports/\(appName).diag")
            add(.caches, library, "Caches/\(appName)")
            add(.supporting, library, "Application Support/\(appName)")
            add(.supporting, systemLibrary, "Application Support/\(appName)")
        }

        result += database.extraLeftovers(bundleID: bundleID, name: name, expander: expander)

        guard sensitivity != .strict else { return result }

        // Enhanced: the app's own helpers, extensions and app groups, read from the bundle.
        if let appURL {
            for embedded in BundleInspector.embeddedBundleIDs(in: appURL)
            where embedded.lowercased() != bundleID.lowercased() && Self.isSafeComponent(embedded) && !others.claims(embedded) {
                addExact(embedded)
            }
            for group in BundleInspector.appGroups(of: appURL)
            where Self.isSafeComponent(group) && !others.claims(Self.identifier(fromComponent: group, in: "Group Containers")) {
                add(.supporting, library, "Group Containers/\(group)")
            }
        }

        // Enhanced: "<bundle id>.<something>" in the Library folders (helpers, extensions, agents).
        let listings = Self.libraryFolders.keys.sorted().map { folder in
            (folder, (try? FileManager.default.contentsOfDirectory(atPath: (library as NSString).appendingPathComponent(folder))) ?? [])
        }
        if let id {
            let prefix = id.lowercased() + "."
            for (folder, children) in listings {
                for child in children {
                    let childID = Self.identifier(fromComponent: child, in: folder).lowercased()
                    guard childID.hasPrefix(prefix), !others.claims(childID) else { continue }
                    add(Self.libraryFolders[folder] ?? .supporting, library, "\(folder)/\(child)")
                }
            }
        }

        guard sensitivity == .deep else { return result }

        // Deep: folders named like the app or its developer. Listed as Possible Matches.
        let appKey = Self.normalized(name)
        let parts = bundleID.lowercased().split(separator: ".").map(String.init)
        let lastKey = id != nil && parts.count >= 2 ? Self.normalized(parts[parts.count - 1]) : ""
        let vendor = id != nil && parts.count >= 3 ? Self.normalized(parts[1]) : ""
        let vendorIsOnlyOurs = vendor.count >= 4 && !Self.genericVendors.contains(vendor) && !others.sharesVendor(with: bundleID)
        for (folder, children) in listings {
            for child in children where !child.hasPrefix(".") && !child.lowercased().hasPrefix("com.apple.") {
                let childID = Self.identifier(fromComponent: child, in: folder)
                let key = Self.normalized(childID)
                guard !key.isEmpty, !others.claims(childID), !others.claimsName(key) else { continue }
                let matches = (appKey.count >= 3 && key == appKey)
                    || (appKey.count >= 5 && key.contains(appKey))
                    || (lastKey.count >= 5 && key.contains(lastKey))
                    || (vendorIsOnlyOurs && key == vendor)
                if matches { add(.possible, library, "\(folder)/\(child)") }
            }
        }
        return result
    }

    /// Letters and digits only, lowercased: "Visual Studio Code" → "visualstudiocode".
    public static func normalized(_ value: String) -> String {
        String(String.UnicodeScalarView(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    /// The identifier a Library item is named after: the file extension and group prefixes removed.
    /// "com.example.app.plist" → "com.example.app"; "group.com.example.app" → "com.example.app".
    public static func identifier(fromComponent component: String, in folder: String) -> String {
        var value = component
        for suffix in [".plist.lockfile", ".plist", ".savedState", ".binarycookies", ".lockfile"]
        where value.lowercased().hasSuffix(suffix.lowercased()) {
            value = String(value.dropLast(suffix.count))
            break
        }
        if folder == "Group Containers" {
            if value.hasPrefix("group.") {
                value = String(value.dropFirst("group.".count))
            } else if let dot = value.firstIndex(of: "."),
                      value.distance(from: value.startIndex, to: dot) == 10,
                      value[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) {
                // Team-ID-prefixed group: "ABCDE12345.com.example.shared".
                value = String(value[value.index(after: dot)...])
            }
        }
        return value
    }

    static func isSafeComponent(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !value.contains("/") && !value.contains("\0")
    }
}
