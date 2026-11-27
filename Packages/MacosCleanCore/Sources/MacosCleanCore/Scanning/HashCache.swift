import Foundation
import Synchronization

/// Remembers the content hashes ``DuplicateFinder`` computed, so a rescan only reads files
/// that changed since (`~/Library/Application Support/<bundle id>/duplicate_hashes.json`).
///
/// A hash is reused only while the file keeps the same path, inode, logical size and
/// modification time; anything else and the file is read again. Records of files no scan
/// has looked at for ``retention`` are dropped when the cache is saved.
public final class HashCache: Sendable {
    public enum Kind: Sendable { case edge, full }

    struct Record: Codable, Equatable {
        /// Logical size.
        var s: Int64
        /// Modification time, seconds since 1970.
        var m: Double
        /// Inode.
        var i: UInt64
        /// Hash of the first and last 64 KB (see ``DuplicateFinder/edgeHash(of:)``).
        var e: String?
        /// Hash of the whole content.
        var f: String?
        /// When a scan last used this record, seconds since 1970.
        var u: Double
    }

    private struct Payload: Codable {
        var version = 1
        var records: [String: Record]
    }

    private struct State {
        var records: [String: Record] = [:]
        var loaded = false
        var dirty = false
    }

    /// Unused records older than this are dropped on save.
    public static let retention: TimeInterval = 60 * 24 * 60 * 60

    public static let shared = HashCache(url: AppWatcher.defaultCacheURL?
        .deletingLastPathComponent().appendingPathComponent("duplicate_hashes.json"))

    /// nil keeps the cache in memory only.
    public let url: URL?
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    public init(url: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    /// The hash saved for this exact version of the file, if any.
    func hash(_ kind: Kind, path: String, size: Int64, modified: Date, inode: UInt64) -> String? {
        let stamp = modified.timeIntervalSince1970
        let used = now().timeIntervalSince1970
        return withRecords { records in
            guard var record = records[path], record.s == size, record.m == stamp, record.i == inode else { return (nil, false) }
            let value = kind == .edge ? record.e : record.f
            if value != nil, used - record.u > 24 * 60 * 60 {
                // Refresh the "last used" time at most daily, so unchanged scans don't rewrite the file.
                record.u = used
                records[path] = record
                return (value, true)
            }
            return (value, false)
        }
    }

    func store(_ value: String, _ kind: Kind, path: String, size: Int64, modified: Date, inode: UInt64) {
        let stamp = modified.timeIntervalSince1970
        let used = now().timeIntervalSince1970
        withRecords { records -> (Void, Bool) in
            var record = records[path].flatMap { $0.s == size && $0.m == stamp && $0.i == inode ? $0 : nil }
                ?? Record(s: size, m: stamp, i: inode, e: nil, f: nil, u: used)
            record.u = used
            switch kind {
            case .edge: record.e = value
            case .full: record.f = value
            }
            records[path] = record
            return ((), true)
        }
    }

    /// Writes the cache to disk if anything changed, dropping records unused for ``retention``.
    public func save() {
        guard let url else { return }
        let cutoff = now().timeIntervalSince1970 - Self.retention
        let records: [String: Record]? = state.withLock { state in
            guard state.loaded, state.dirty else { return nil }
            state.records = state.records.filter { $0.value.u >= cutoff }
            state.dirty = false
            return state.records
        }
        guard let records, let data = try? JSONEncoder().encode(Payload(records: records)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Forgets every saved hash, on disk too.
    public func removeAll() {
        state.withLock { $0 = State(loaded: true) }
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    var count: Int { withRecords { ($0.count, false) } }

    /// Runs `body` on the records, loading them from disk the first time. `body` returns its
    /// result and whether it changed the records.
    private func withRecords<T>(_ body: (inout [String: Record]) -> (T, Bool)) -> T {
        state.withLock { state in
            if !state.loaded {
                state.loaded = true
                state.records = Self.read(url)
            }
            let (result, changed) = body(&state.records)
            if changed { state.dirty = true }
            return result
        }
    }

    private static func read(_ url: URL?) -> [String: Record] {
        guard let url, let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1
        else { return [:] }
        return payload.records
    }
}
