import Darwin
import Foundation

/// CPU, memory and disk usage at one moment, for the menu bar monitor.
public struct SystemSnapshot: Sendable, Equatable {
    /// Share of total CPU capacity in use since the previous sample, 0...1. Nil on the first sample.
    public var cpuUsage: Double?
    /// Memory in use as Activity Monitor counts "Memory Used": app memory, wired and compressed.
    public var memoryUsed: Int64
    public var memoryTotal: Int64
    /// Free space on the home volume, counting space macOS can free for important use.
    public var diskAvailable: Int64
    public var diskTotal: Int64

    public init(cpuUsage: Double?, memoryUsed: Int64, memoryTotal: Int64, diskAvailable: Int64, diskTotal: Int64) {
        self.cpuUsage = cpuUsage
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.diskAvailable = diskAvailable
        self.diskTotal = diskTotal
    }

    public var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    public var diskUsedFraction: Double { diskTotal > 0 ? Double(diskTotal - diskAvailable) / Double(diskTotal) : 0 }
}

/// CPU tick counters for every core added together (user, system, idle, nice).
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Busy share of the ticks elapsed since `earlier`, 0...1. Nil when no time passed or a
    /// counter went backwards (it wrapped or the machine woke from sleep).
    public func usage(since earlier: CPUTicks) -> Double? {
        guard user >= earlier.user, system >= earlier.system, idle >= earlier.idle, nice >= earlier.nice else { return nil }
        let busy = (user - earlier.user) + (system - earlier.system) + (nice - earlier.nice)
        let total = busy + (idle - earlier.idle)
        guard total > 0 else { return nil }
        return min(1, max(0, Double(busy) / Double(total)))
    }
}

/// Reads ``SystemSnapshot``s. Cheap: a few kernel calls, no file walking. Keeps the previous CPU
/// ticks so each sample reports usage since the last one.
public struct SystemSampler: Sendable {
    private var previousTicks: CPUTicks?
    private let volume: URL

    public init(volume: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.volume = volume
    }

    public mutating func sample() -> SystemSnapshot {
        let ticks = Self.cpuTicks()
        var cpu: Double?
        if let ticks, let previousTicks { cpu = ticks.usage(since: previousTicks) }
        if let ticks { previousTicks = ticks }
        let disk = Self.disk(volume)
        return SystemSnapshot(
            cpuUsage: cpu,
            memoryUsed: Self.memoryUsed() ?? 0,
            memoryTotal: Int64(clamping: ProcessInfo.processInfo.physicalMemory),
            diskAvailable: disk.available,
            diskTotal: disk.total
        )
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(
            user: UInt64(ticks.0), system: UInt64(ticks.1), idle: UInt64(ticks.2), nice: UInt64(ticks.3)
        )
    }

    static func memoryUsed() -> Int64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        // App memory (anonymous pages minus purgeable) + wired + compressed, as Activity Monitor shows.
        let appPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let pages = max(0, appPages) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return pages * Int64(pageSize)
    }

    static func disk(_ volume: URL) -> (available: Int64, total: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0
        else { return (0, 0) }
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        return (min(available, Int64(total)), Int64(total))
    }
}

/// A release version such as "1.2.0" or "v1.2", compared part by part ("1.10" > "1.9").
public struct AppVersion: Sendable, Comparable, CustomStringConvertible {
    public let parts: [Int]

    /// Accepts an optional leading "v" and ignores a pre-release or build suffix ("1.2.0-beta" → 1.2.0).
    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        if let cut = value.firstIndex(where: { $0 == "-" || $0 == "+" || $0 == " " }) { value = String(value[..<cut]) }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = pieces.compactMap { Int($0) }
        guard !pieces.isEmpty, numbers.count == pieces.count else { return nil }
        parts = numbers
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}
