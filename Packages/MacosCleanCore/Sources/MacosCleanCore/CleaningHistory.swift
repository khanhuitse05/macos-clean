import Foundation

/// One finished clean.
public struct CleaningRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Moved to the Trash by macos-clean (restorable until the Trash is emptied).
        case trashed
        /// Deleted for good from the Trash (emptying it, or erasing picked items).
        case deletedForGood
        /// Simulator runtimes or devices removed through `simctl` (no Trash involved).
        case simulatorRemoved
    }

    public var id: Date { date }
    public let date: Date
    public let kind: Kind
    public let bytes: Int64
    public let count: Int

    public init(date: Date = .now, kind: Kind, bytes: Int64, count: Int) {
        self.date = date
        self.kind = kind
        self.bytes = bytes
        self.count = count
    }
}

/// Running totals of everything macos-clean has cleaned, plus the most recent records.
///
/// "Cleaned" counts what macos-clean took away from where it was: items moved to the Trash and
/// simulators removed. Emptying the Trash is counted apart (``lifetimeEmptiedBytes``), so a file
/// moved to the Trash and then emptied isn't counted twice.
public struct CleaningHistory: Codable, Sendable, Equatable {
    /// Records older than the newest ``maxRecords`` are dropped; the totals keep them.
    public static let maxRecords = 200

    public private(set) var lifetimeCleanedBytes: Int64 = 0
    public private(set) var lifetimeCleanedItems: Int = 0
    public private(set) var lifetimeEmptiedBytes: Int64 = 0
    /// Cleans that removed something (Trash emptying not included).
    public private(set) var cleanCount: Int = 0
    public private(set) var lastCleaned: Date?
    public private(set) var firstCleaned: Date?
    /// Newest last.
    public private(set) var records: [CleaningRecord] = []

    public init() {}

    public var isEmpty: Bool { records.isEmpty && cleanCount == 0 && lifetimeEmptiedBytes == 0 }

    public mutating func record(_ record: CleaningRecord) {
        guard record.count > 0 else { return }
        switch record.kind {
        case .trashed, .simulatorRemoved:
            lifetimeCleanedBytes += max(0, record.bytes)
            lifetimeCleanedItems += record.count
            cleanCount += 1
            lastCleaned = max(lastCleaned ?? record.date, record.date)
            firstCleaned = min(firstCleaned ?? record.date, record.date)
        case .deletedForGood:
            lifetimeEmptiedBytes += max(0, record.bytes)
        }
        records.append(record)
        if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
    }

    /// Bytes cleaned (not emptied) since `date`.
    public func cleanedBytes(since date: Date) -> Int64 {
        records.lazy.filter { $0.kind != .deletedForGood && $0.date >= date }.reduce(0) { $0 + $1.bytes }
    }
}
