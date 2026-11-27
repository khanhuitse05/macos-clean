import AppKit
import MacosCleanCore
import SwiftUI

enum MonitorSettings {
    /// `UserDefaults` key: whether the monitor sits in the menu bar.
    static let showKey = "showMenuBarMonitor"
    /// `UserDefaults` key: which value the menu bar shows (``MenuBarMetric`` raw value).
    static let metricKey = "menuBarMetric"
}

/// The value shown next to the menu bar icon.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case disk, cpu, memory, iconOnly

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .disk: "Free Disk Space"
        case .cpu: "CPU Usage"
        case .memory: "Memory Used"
        case .iconOnly: "Icon Only"
        }
    }

    var symbol: String {
        switch self {
        case .disk, .iconOnly: "internaldrive"
        case .cpu: "cpu"
        case .memory: "memorychip"
        }
    }
}

/// Samples CPU, memory and disk every few seconds while someone is looking: the menu bar item is
/// shown, or its panel is open. Sampling is a few kernel calls, with no file walking.
@MainActor
@Observable
final class SystemMonitorModel {
    static let shared = SystemMonitorModel()

    private(set) var snapshot: SystemSnapshot?

    @ObservationIgnored private var sampler = SystemSampler()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var menuBarWatching = false

    /// Seconds between samples.
    static let interval: Duration = .seconds(3)

    /// Keeps sampling while the menu bar item is shown. Called by the app whenever the setting
    /// changes: a `MenuBarExtra` label never gets `onAppear`, so it can't start sampling itself.
    func setMenuBarShown(_ shown: Bool) {
        guard shown != menuBarWatching else { return }
        menuBarWatching = shown
        if shown { start() } else { stop() }
    }

    func start() {
        watchers += 1
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        task?.cancel()
        task = nil
    }

    private func tick() {
        let next = sampler.sample()
        // Keep the last CPU value until a new one exists, so the label never blanks out.
        var merged = next
        if merged.cpuUsage == nil { merged.cpuUsage = snapshot?.cpuUsage }
        if merged != snapshot { snapshot = merged }
    }
}

/// The icon and value in the menu bar.
struct MenuBarMonitorLabel: View {
    @AppStorage(MonitorSettings.metricKey) private var metric: MenuBarMetric = .disk
    private let model = SystemMonitorModel.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: metric.symbol)
            if let text = value {
                Text(text).monospacedDigit()
            }
        }
    }

    private var value: String? {
        guard let snapshot = model.snapshot else { return nil }
        switch metric {
        case .disk: return snapshot.diskAvailable.compactFileSize
        case .cpu: return snapshot.cpuUsage.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–"
        case .memory: return snapshot.memoryFraction.formatted(.percent.precision(.fractionLength(0)))
        case .iconOnly: return nil
        }
    }
}

/// The panel that opens from the menu bar item.
struct MenuBarMonitorPanel: View {
    private let model = SystemMonitorModel.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(.tint)
                Text("macOS Clean").font(.headline)
                Spacer()
            }
            if let snapshot = model.snapshot {
                MeterRow(
                    title: "CPU", symbol: "cpu",
                    fraction: snapshot.cpuUsage ?? 0,
                    detail: snapshot.cpuUsage.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Measuring…"
                )
                MeterRow(
                    title: "Memory", symbol: "memorychip",
                    fraction: snapshot.memoryFraction,
                    detail: "\(snapshot.memoryUsed.fileSize) of \(snapshot.memoryTotal.fileSize)"
                )
                MeterRow(
                    title: "Disk", symbol: "internaldrive",
                    fraction: snapshot.diskUsedFraction,
                    detail: "\(snapshot.diskAvailable.fileSize) free of \(snapshot.diskTotal.fileSize)"
                )
            } else {
                HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                Button("Open macOS Clean") {
                    NSApp.activate()
                    openWindow(id: "main")
                }
                .buttonStyle(.glassProminent)
                Spacer()
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
                    .help("Quit macOS Clean")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

private struct MeterRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let fraction: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            ProgressView(value: min(1, max(0, fraction)))
                .tint(fraction > 0.9 ? .orange : .accentColor)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Int64 {
    /// "123 GB", "8.4 GB" or "512 MB": at most three digits, short enough for the menu bar.
    var compactFileSize: String {
        let gigabytes = Double(self) / 1e9
        if gigabytes >= 1000 { return (gigabytes / 1000).formatted(.number.precision(.fractionLength(0...1))) + " TB" }
        if gigabytes >= 10 { return gigabytes.formatted(.number.precision(.fractionLength(0))) + " GB" }
        if gigabytes >= 1 { return gigabytes.formatted(.number.precision(.fractionLength(0...1))) + " GB" }
        return (Double(self) / 1e6).formatted(.number.precision(.fractionLength(0))) + " MB"
    }
}
