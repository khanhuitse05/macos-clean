import Darwin
import Foundation

/// Full Disk Access detection and permission-error helpers.
public enum AccessCheck {
    /// Files that only a process with Full Disk Access can open.
    static let protectedProbes = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        "~/Library/Application Support/com.apple.TCC/TCC.db",
        "~/Library/Safari/Bookmarks.plist",
    ]

    /// System Settings › Privacy & Security › Full Disk Access.
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    /// True when this process can read TCC-protected files.
    public static func hasFullDiskAccess(expander: PathExpander = PathExpander()) -> Bool {
        var sawPermissionError = false
        for probe in protectedProbes {
            let path = expander.expand(probe).path
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if isPermissionErrno(errno) { sawPermissionError = true }
        }
        // No probe exists at all: we can't prove a denial, so don't nag.
        return !sawPermissionError
    }

    public static func isPermissionErrno(_ code: Int32) -> Bool {
        code == EPERM || code == EACCES
    }

    /// True for Foundation/POSIX errors that mean "macOS blocked this", not "missing".
    public static func isPermissionError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, isPermissionErrno(Int32(nsError.code)) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }
}
