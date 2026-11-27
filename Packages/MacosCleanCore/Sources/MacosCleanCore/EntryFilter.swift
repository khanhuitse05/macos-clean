import Foundation

/// Narrows and orders scan results for display: text search, a minimum size, a minimum age,
/// and a sort order. Filtering never changes what is selected; it only decides which rows show.
public struct EntryFilter: Sendable, Equatable {
    public enum MinimumSize: String, Sendable, CaseIterable, Identifiable {
        case any, tenMB, hundredMB, oneGB

        public var id: String { rawValue }

        public var bytes: Int64 {
            switch self {
            case .any: 0
            case .tenMB: 10_000_000
            case .hundredMB: 100_000_000
            case .oneGB: 1_000_000_000
            }
        }

        public var title: LocalizedStringResource {
            switch self {
            case .any: LocalizedStringResource("Any Size", bundle: #bundle)
            case .tenMB: LocalizedStringResource("10 MB or Larger", bundle: #bundle)
            case .hundredMB: LocalizedStringResource("100 MB or Larger", bundle: #bundle)
            case .oneGB: LocalizedStringResource("1 GB or Larger", bundle: #bundle)
            }
        }
    }

    public enum MinimumAge: String, Sendable, CaseIterable, Identifiable {
        case any, oneWeek, oneMonth, threeMonths, oneYear

        public var id: String { rawValue }

        /// Days since last modification an entry needs; nil for no limit.
        public var days: Int? {
            switch self {
            case .any: nil
            case .oneWeek: 7
            case .oneMonth: 30
            case .threeMonths: 90
            case .oneYear: 365
            }
        }

        public var title: LocalizedStringResource {
            switch self {
            case .any: LocalizedStringResource("Any Age", bundle: #bundle)
            case .oneWeek: LocalizedStringResource("Not Modified in a Week", bundle: #bundle)
            case .oneMonth: LocalizedStringResource("Not Modified in a Month", bundle: #bundle)
            case .threeMonths: LocalizedStringResource("Not Modified in 3 Months", bundle: #bundle)
            case .oneYear: LocalizedStringResource("Not Modified in a Year", bundle: #bundle)
            }
        }
    }

    public enum Sort: String, Sendable, CaseIterable, Identifiable {
        case size, name, oldest

        public var id: String { rawValue }

        public var title: LocalizedStringResource {
            switch self {
            case .size: LocalizedStringResource("Size", bundle: #bundle)
            case .name: LocalizedStringResource("Name", bundle: #bundle)
            case .oldest: LocalizedStringResource("Oldest First", bundle: #bundle)
            }
        }
    }

    public var query: String
    public var minimumSize: MinimumSize
    public var minimumAge: MinimumAge
    public var sort: Sort

    public init(query: String = "", minimumSize: MinimumSize = .any, minimumAge: MinimumAge = .any, sort: Sort = .size) {
        self.query = query
        self.minimumSize = minimumSize
        self.minimumAge = minimumAge
        self.sort = sort
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when some rows may be hidden. Sorting alone hides nothing.
    public var isActive: Bool { !trimmedQuery.isEmpty || minimumSize != .any || minimumAge != .any }

    /// Whether an entry passes the search, size and age limits.
    /// - Parameter label: extra text to search, such as a simulator's display name.
    public func matches(_ entry: FileEntry, label: String? = nil, now: Date = .now) -> Bool {
        if entry.sizeBytes < minimumSize.bytes { return false }
        if let days = minimumAge.days {
            // Unknown dates can't prove an item is old, so they are hidden by an age limit.
            guard let modified = entry.modified,
                  modified <= now.addingTimeInterval(-Double(days) * 86_400) else { return false }
        }
        let needle = trimmedQuery
        guard !needle.isEmpty else { return true }
        if entry.path.localizedStandardContains(needle) { return true }
        return label?.localizedStandardContains(needle) ?? false
    }

    /// The entries that pass, in the chosen order.
    public func apply(to entries: [FileEntry], label: (FileEntry) -> String? = { _ in nil }, now: Date = .now) -> [FileEntry] {
        let kept = isActive ? entries.filter { matches($0, label: label($0), now: now) } : entries
        return sorted(kept)
    }

    /// The entries in the chosen order, filter not applied.
    public func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        switch sort {
        case .size:
            return entries.sortedBySizeDescending()
        case .name:
            return entries.sorted {
                switch $0.name.localizedStandardCompare($1.name) {
                case .orderedSame: $0.path < $1.path
                case let order: order == .orderedAscending
                }
            }
        case .oldest:
            // Undated entries go last; ties keep size order.
            return entries.sorted { lhs, rhs in
                switch (lhs.modified, rhs.modified) {
                case let (l?, r?) where l != r: l < r
                case (.some, nil): true
                case (nil, .some): false
                default: lhs.sizeBytes != rhs.sizeBytes ? lhs.sizeBytes > rhs.sizeBytes : lhs.path < rhs.path
                }
            }
        }
    }
}
