import Foundation
@testable import MacosCleanCore

/// A throwaway directory tree under the system temp folder, removed on deinit.
final class TempTree: Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macos-clean-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions so cleanup can't fail on a chmod-000 test folder.
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                chmod(root.appendingPathComponent(relative).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    var path: String { root.path }
    var expander: PathExpander { PathExpander(home: root.path, environment: [:]) }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    @discardableResult
    func dir(_ relative: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes real (non-sparse) bytes so allocated size ≈ `bytes`.
    @discardableResult
    func file(_ relative: String, bytes: Int = 16, contents: String? = nil) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = contents.map { Data($0.utf8) } ?? Data(repeating: 0xAB, count: bytes)
        try data.write(to: url)
        return url
    }

    func app(_ relative: String, bundleID: String?, name: String? = nil, version: String = "1.0") throws -> URL {
        let bundle = try dir(relative)
        var info: [String: Any] = ["CFBundleShortVersionString": version]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        if let name { info["CFBundleName"] = name }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try file("\(relative)/Contents/Info.plist", contents: String(decoding: data, as: UTF8.self))
        try file("\(relative)/Contents/MacOS/binary", bytes: 64 * 1024)
        return bundle
    }
}
