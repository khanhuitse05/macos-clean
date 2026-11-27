import Foundation
import Security

/// Reads what an app bundle declares about itself, without running it.
public enum BundleInspector {
    /// Folders inside `Contents` that hold nested bundles with their own identifiers.
    static let nestedFolders = [
        "PlugIns", "Library/LoginItems", "Library/LaunchServices", "Library/SystemExtensions",
        "Helpers", "XPCServices", "Frameworks",
    ]

    /// Bundle identifiers of the app's extensions, login items, helpers and XPC services.
    /// `.framework` bundles are skipped (they often carry a library vendor's identifier), but helper
    /// apps inside `Frameworks`, as Electron apps ship them, are included.
    public static func embeddedBundleIDs(in appURL: URL) -> [String] {
        let contents = appURL.appendingPathComponent("Contents")
        var result: [String] = []
        var seen = Set<String>()
        for folder in nestedFolders {
            let base = contents.appendingPathComponent(folder)
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { continue }
            for child in children.sorted() {
                let ext = (child as NSString).pathExtension.lowercased()
                guard ["app", "appex", "xpc", "systemextension"].contains(ext) else { continue }
                let info = base.appendingPathComponent(child).appendingPathComponent("Contents/Info.plist")
                guard let id = bundleID(atInfoPlist: info), seen.insert(id.lowercased()).inserted else { continue }
                result.append(id)
            }
        }
        return result
    }

    /// App groups the app is entitled to (`com.apple.security.application-groups`), read from
    /// its code signature. Empty for unsigned or ad-hoc signed apps.
    public static func appGroups(of appURL: URL) -> [String] {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return [] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return (entitlements["com.apple.security.application-groups"] as? [String] ?? []).filter { !$0.isEmpty }
    }

    static func bundleID(atInfoPlist url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty
        else { return nil }
        return id
    }
}
