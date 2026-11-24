import Foundation

/// An application bundle found in an Applications folder.
public struct InstalledApp: Identifiable, Hashable, Sendable, Codable {
    public let bundleID: String
    public let name: String
    public let path: String
    public let version: String?
    /// Modification date of the bundle (≈ install or update date).
    public let modified: Date
    /// Lives on the read-only system volume (`/System/Applications`, Safari…). Never removable.
    public let isSystem: Bool
    /// This app (macos-clean) itself. Never removable from inside itself.
    public let isSelf: Bool

    public init(bundleID: String, name: String, path: String, version: String?, modified: Date, isSystem: Bool, isSelf: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.version = version
        self.modified = modified
        self.isSystem = isSystem
        self.isSelf = isSelf
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var canUninstall: Bool { !isSystem && !isSelf }
    /// False when the bundle had no `CFBundleIdentifier` and we made one up.
    public var hasRealBundleID: Bool { !bundleID.hasPrefix(AppCatalog.missingBundleIDPrefix) }
}

/// Lists installed apps. Port of `list_installed_apps` in the reference `apps.rs`.
public struct AppCatalog: Sendable {
    public struct Root: Sendable, Hashable {
        public let url: URL
        public let isSystem: Bool
        public init(url: URL, isSystem: Bool) {
            self.url = url
            self.isSystem = isSystem
        }
    }

    static let missingBundleIDPrefix = "__no_bundle_id."

    public let roots: [Root]
    public let ownBundlePath: String?

    public init(roots: [Root], ownBundlePath: String? = Bundle.main.bundlePath) {
        self.roots = roots
        self.ownBundlePath = ownBundlePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    public static func standard(home: String = NSHomeDirectory()) -> AppCatalog {
        AppCatalog(roots: [
            Root(url: URL(fileURLWithPath: "/Applications"), isSystem: false),
            Root(url: URL(fileURLWithPath: "/System/Applications"), isSystem: true),
            Root(url: URL(fileURLWithPath: "/System/Applications/Utilities"), isSystem: true),
            Root(url: URL(fileURLWithPath: home).appendingPathComponent("Applications"), isSystem: false),
        ])
    }

    /// Folders worth watching for apps appearing or disappearing.
    public var watchedFolders: [URL] { roots.filter { !$0.isSystem }.map(\.url) }

    /// Apps directly inside each root, plus one level of plain subfolders (e.g. `/Applications/Adobe Photoshop/`).
    /// Sorted by name. Cheap: reads only `Info.plist`, never walks the bundle.
    public func listApps() -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for root in roots {
            for bundle in bundles(in: root.url, depth: 0) where seen.insert(bundle.path).inserted {
                apps.append(makeApp(bundle, rootIsSystem: root.isSystem))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func bundles(in folder: URL, depth: Int) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for child in children {
            if child.pathExtension == "app" {
                result.append(child)
            } else if depth == 0,
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                result += bundles(in: child, depth: 1)
            }
        }
        return result
    }

    private func makeApp(_ bundle: URL, rootIsSystem: Bool) -> InstalledApp {
        let info = (try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let stem = bundle.deletingPathExtension().lastPathComponent
        let bundleID = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.missingBundleIDPrefix + stem
        let name = [info["CFBundleDisplayName"], info["CFBundleName"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty } ?? stem
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        let attributes = try? FileManager.default.attributesOfItem(atPath: bundle.path)
        let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
        let resolved = bundle.resolvingSymlinksInPath().path
        return InstalledApp(
            bundleID: bundleID,
            name: name,
            path: bundle.path,
            version: version,
            modified: modified,
            isSystem: rootIsSystem || resolved.hasPrefix("/System/"),
            isSelf: ownBundlePath == resolved
        )
    }
}
