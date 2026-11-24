import AppKit
import MacosCleanCore
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style actions for a file or folder.
@MainActor
enum FileActions {
    static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    static func openTrash() {
        NSWorkspace.shared.open(TrashEmptier.userTrashURL)
    }
}

/// Context-menu items shared by every file row.
struct FileContextMenu: View {
    let path: String
    var onQuickLook: ((URL) -> Void)?
    var onTrash: (() -> Void)?
    /// Offer "Never Scan" for this folder (or a file's enclosing folder).
    var canExclude = true
    var trashTitle: LocalizedStringKey = "Move to Trash…"

    var body: some View {
        Button("Show in Finder", systemImage: "folder") { FileActions.reveal([path]) }
        if let onQuickLook {
            Button("Quick Look", systemImage: "eye") { onQuickLook(URL(fileURLWithPath: path)) }
        }
        Button("Copy Path", systemImage: "doc.on.doc") { FileActions.copyPath(path) }
        if let folder = excludableFolder {
            Button("Never Scan “\((folder as NSString).lastPathComponent)”", systemImage: "eye.slash") {
                ExclusionStore.shared.add(folder)
            }
            .help("Add \(folder.abbreviatingHome) to the excluded folders in Settings")
        }
        if let onTrash {
            Divider()
            Button(trashTitle, systemImage: "trash", action: onTrash)
        }
    }
}

extension FileContextMenu {
    /// The folder "Never Scan" would add: the item itself when it's a folder, else its parent.
    /// Nil for the home folder, the disk root and folders already excluded.
    private var excludableFolder: String? {
        guard canExclude else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let folder = isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
        guard folder != "/", folder != NSHomeDirectory(), !ExclusionStore.shared.list.isExcluded(folder) else { return nil }
        return folder
    }
}

/// Finder icons, cached per file type so long lists stay fast.
@MainActor
enum IconCache {
    private static var byType: [String: NSImage] = [:]

    static func icon(forPath path: String, isDirectory: Bool) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        // Bundles (apps, packages) have their own icons; everything else shares one per type.
        if ext == "app" || ext == "bundle" || ext == "pkg" {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let key = isDirectory ? "/dir" : ext
        if let cached = byType[key] { return cached }
        let type: UTType = isDirectory ? .folder : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        byType[key] = image
        return image
    }

    static func appIcon(_ path: String) -> NSImage {
        if let cached = byType["app:" + path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        byType["app:" + path] = image
        return image
    }
}

struct FileIcon: View {
    let path: String
    let isDirectory: Bool
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: IconCache.icon(forPath: path, isDirectory: isDirectory))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

extension String {
    /// "/Users/me/Library" → "~/Library".
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}

extension Int64 {
    var fileSize: String { formatted(.byteCount(style: .file)) }
}
