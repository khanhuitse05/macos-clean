import Foundation
import Synchronization

/// A simulator runtime or simulator device, as Xcode's `simctl` reports it.
///
/// Neither can go to the Trash: runtimes are root-owned disk images managed by CoreSimulator,
/// and device folders are tracked in CoreSimulator's device set. They're removed with
/// `simctl` instead (see ``SimulatorRemover``), which can't be undone.
public struct SimulatorItem: Sendable, Equatable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case runtime, device
    }

    public let kind: Kind
    /// Runtime identifier (a UUID for `simctl runtime delete`) or device UDID.
    public let identifier: String
    /// "iOS 27.2" for a runtime, "iPhone 18 Pro" for a device.
    public let name: String
    /// "Simulator runtime · build 24B8117", "iOS 27.0".
    public let detail: String
    public let sizeBytes: Int64
    public let lastUsed: Date?
    /// False for a device whose runtime is gone (`simctl delete unavailable` would remove it).
    public let isAvailable: Bool
    /// Where it lives on disk. Unique; used as the row's identity.
    public let path: String

    public var id: String { path }

    public init(
        kind: Kind, identifier: String, name: String, detail: String, sizeBytes: Int64,
        lastUsed: Date?, isAvailable: Bool, path: String
    ) {
        self.kind = kind
        self.identifier = identifier
        self.name = name
        self.detail = detail
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.isAvailable = isAvailable
        self.path = path
    }

    public var entry: FileEntry {
        FileEntry(path: path, sizeBytes: sizeBytes, isDirectory: false, modified: lastUsed)
    }
}

/// Runs a command and collects its output. A protocol so tests never run `xcrun`.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: Duration) async -> CommandResult
}

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let output: Data
    public let error: String

    public init(status: Int32, output: Data, error: String) {
        self.status = status
        self.output = output
        self.error = error
    }

    public var succeeded: Bool { status == 0 }
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: Duration) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, output: Data(), error: error.localizedDescription))
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: deadline)
                // Read both pipes before waiting, so a full pipe buffer can't stall the child.
                let errorData = Mutex(Data())
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = err.fileHandleForReading.readDataToEndOfFile()
                    errorData.withLock { $0 = data }
                    group.leave()
                }
                let outputData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    output: outputData,
                    error: String(decoding: errorData.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
    }
}

/// Lists simulator runtimes and devices with `xcrun simctl`.
public struct SimulatorInventory: Sendable {
    let runner: any CommandRunning
    let timeout: Duration

    public init(runner: any CommandRunning = ProcessRunner(), timeout: Duration = .seconds(30)) {
        self.runner = runner
        self.timeout = timeout
    }

    /// True when the selected developer directory is inside a full Xcode. `xcrun` is never run
    /// otherwise: without Xcode it would ask to install the Command Line Tools.
    public func isXcodeAvailable() async -> Bool {
        let result = await runner.run("/usr/bin/xcode-select", ["-p"], timeout: .seconds(5))
        guard result.succeeded else { return false }
        let path = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isXcodeDeveloperDirectory(path)
    }

    static func isXcodeDeveloperDirectory(_ path: String) -> Bool {
        path.contains(".app/Contents/Developer") && FileManager.default.fileExists(atPath: path)
    }

    /// Deletable runtimes and every device, largest first. Empty without Xcode.
    public func list() async -> [SimulatorItem] {
        guard await isXcodeAvailable() else { return [] }
        async let runtimes = runner.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: timeout)
        async let devices = runner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: timeout)
        let (runtimeResult, deviceResult) = await (runtimes, devices)
        var items: [SimulatorItem] = []
        if runtimeResult.succeeded { items += Self.parseRuntimes(runtimeResult.output) }
        if deviceResult.succeeded { items += Self.parseDevices(deviceResult.output) }
        return items.sorted { $0.sizeBytes != $1.sizeBytes ? $0.sizeBytes > $1.sizeBytes : $0.path < $1.path }
    }

    // MARK: Parsing

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return try? Date(string, strategy: .iso8601)
    }

    private static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber: number.int64Value
        case let string as String: Int64(string) ?? 0
        default: 0
        }
    }

    /// "com.apple.platform.iphonesimulator" → "iOS".
    static func platformName(_ identifier: String) -> String {
        let lower = identifier.lowercased()
        if lower.contains("iphone") { return "iOS" }
        if lower.contains("watch") { return "watchOS" }
        if lower.contains("appletv") { return "tvOS" }
        if lower.contains("xr") || lower.contains("vision") { return "visionOS" }
        return "Simulator"
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0".
    static func runtimeName(_ key: String) -> String {
        guard let last = key.split(separator: ".").last else { return key }
        let parts = last.split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return String(last) }
        return "\(platform) " + parts.dropFirst().joined(separator: ".")
    }

    /// `simctl runtime list -j`: a dictionary keyed by runtime identifier.
    public static func parseRuntimes(_ data: Data) -> [SimulatorItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root.compactMap { key, value -> SimulatorItem? in
            guard let info = value as? [String: Any],
                  (info["deletable"] as? Bool) ?? false,
                  let path = info["path"] as? String, path.hasPrefix("/")
            else { return nil }
            let identifier = (info["identifier"] as? String) ?? key
            let platform = platformName((info["platformIdentifier"] as? String) ?? "")
            let version = (info["version"] as? String) ?? ""
            let build = (info["build"] as? String).map { " · build \($0)" } ?? ""
            let state = (info["state"] as? String).flatMap { $0 == "Ready" ? nil : " · \($0)" } ?? ""
            return SimulatorItem(
                kind: .runtime,
                identifier: identifier,
                name: "\(platform) \(version)".trimmingCharacters(in: .whitespaces),
                detail: "Simulator runtime\(build)\(state)",
                sizeBytes: int64(info["sizeBytes"]),
                lastUsed: date(info["lastUsedAt"]),
                isAvailable: true,
                path: path
            )
        }
    }

    /// `simctl list devices -j`: `{"devices": {runtimeKey: [device]}}`.
    public static func parseDevices(_ data: Data) -> [SimulatorItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: Any]
        else { return [] }
        var items: [SimulatorItem] = []
        for (runtimeKey, value) in byRuntime {
            guard let devices = value as? [[String: Any]] else { continue }
            for device in devices {
                guard let udid = device["udid"] as? String, let dataPath = device["dataPath"] as? String,
                      dataPath.hasPrefix("/")
                else { continue }
                let folder = (dataPath as NSString).deletingLastPathComponent
                let available = (device["isAvailable"] as? Bool) ?? true
                let state = (device["state"] as? String) ?? ""
                var detail = runtimeName(runtimeKey)
                if state == "Booted" { detail += " · Running" }
                items.append(SimulatorItem(
                    kind: .device,
                    identifier: udid,
                    name: (device["name"] as? String) ?? udid,
                    detail: detail,
                    sizeBytes: int64(device["dataPathSize"]),
                    lastUsed: date(device["lastUsedAt"] ?? device["lastBootedAt"]),
                    isAvailable: available,
                    path: folder
                ))
            }
        }
        return items
    }
}

/// Removes simulator runtimes and devices with `simctl`. Permanent: nothing goes to the Trash.
public struct SimulatorRemover: Sendable {
    let runner: any CommandRunning
    let timeout: Duration

    public init(runner: any CommandRunning = ProcessRunner(), timeout: Duration = .seconds(120)) {
        self.runner = runner
        self.timeout = timeout
    }

    /// The `xcrun` arguments that remove `item`.
    static func arguments(for item: SimulatorItem) -> [String] {
        switch item.kind {
        case .device: ["simctl", "delete", item.identifier]
        case .runtime: ["simctl", "runtime", "delete", item.identifier]
        }
    }

    /// - Throws: ``CleanerError/confirmationRequired`` — before running anything — unless `confirm` is true.
    public func remove(_ items: [SimulatorItem], confirm: Bool) throws -> AsyncStream<CleanEvent> {
        guard confirm else { throw CleanerError.confirmationRequired }
        let remover = self
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var outcomes: [DeleteOutcome] = []
                var freed: Int64 = 0
                for (index, item) in items.enumerated() {
                    if Task.isCancelled { break }
                    continuation.yield(.progress(CleanProgress(
                        current: index, total: items.count, path: item.name, bytesFreed: freed,
                        succeeded: outcomes.count(where: \.success), failed: outcomes.count { !$0.success }
                    )))
                    let result = await remover.runner.run("/usr/bin/xcrun", Self.arguments(for: item), timeout: remover.timeout)
                    if result.succeeded {
                        freed += item.sizeBytes
                        outcomes.append(DeleteOutcome(path: item.path, success: true, bytes: item.sizeBytes))
                    } else {
                        let message = result.error.isEmpty ? "simctl exited with status \(result.status)." : result.error
                        outcomes.append(DeleteOutcome(path: item.path, success: false, error: message))
                    }
                }
                continuation.yield(.progress(CleanProgress(
                    current: items.count, total: items.count, path: "", bytesFreed: freed,
                    succeeded: outcomes.count(where: \.success), failed: outcomes.count { !$0.success }
                )))
                continuation.yield(.finished(CleanSummary(outcomes: outcomes)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
