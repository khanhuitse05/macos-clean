import Foundation

/// Where a file lives, in the terms a person thinks of: their Downloads, iCloud Drive, an
/// external drive, or data an app keeps for itself.
public enum FileLocation: String, Sendable, CaseIterable {
    case desktop, documents, downloads, pictures, movies, music
    case iCloudDrive
    case externalDrive
    /// Files apps install and manage: `~/Library`, `/Applications`, `/Library`, system folders.
    case appData
    /// Elsewhere in the home folder (a projects folder, for example).
    case home
    case other

    public static func of(_ path: String, home: String = NSHomeDirectory()) -> FileLocation {
        var homeSlash = home
        if !homeSlash.hasSuffix("/") { homeSlash += "/" }
        if path.hasPrefix(homeSlash) {
            let rest = path.dropFirst(homeSlash.count)
            let first = rest.prefix { $0 != "/" }
            switch first {
            case "Desktop": return .desktop
            case "Documents": return .documents
            case "Downloads": return .downloads
            case "Pictures": return .pictures
            case "Movies": return .movies
            case "Music": return .music
            case "Library": return rest.hasPrefix("Library/Mobile Documents/") ? .iCloudDrive : .appData
            default: return .home
            }
        }
        if path.hasPrefix("/Volumes/") { return .externalDrive }
        if appDataPrefixes.contains(where: path.hasPrefix) { return .appData }
        return .other
    }

    static let appDataPrefixes = ["/Applications/", "/Library/", "/System/", "/opt/", "/usr/", "/private/"]
}

extension FileEntry {
    /// The name to show. Apps sometimes save a file under a percent-encoded URL
    /// (`file%3A%2F%2F…%2FSetup.zip`); that shows as the file name the URL points to.
    public var displayName: String {
        let raw = name
        guard raw.contains("%"), let decoded = raw.removingPercentEncoding, decoded != raw else { return raw }
        let last = (decoded as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? decoded : last
    }
}
